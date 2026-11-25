import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/data/audit_log.dart';
import '../../core/data/auth_repository.dart';
import '../../core/data/permission_service.dart';
import '../../core/data/production_data_layer.dart';
import '../../core/services/repositories.dart';
import '../../models/customer_ledger.dart';
import '../../models/sale.dart';
import '../../models/sale_return.dart';
import '../dashboard/dashboard_screen.dart';
import '../inventory/inventory_provider.dart';
import 'billing_provider.dart';
import 'returns_logic.dart';

/// Sale returns state (Week 2 Day 4, FR-POS-08).
///
/// [SaleReturnsNotifier.createReturn] records one approved return
/// end to end, in this order:
///
/// 1. **Permission:** the approver must hold `posRefund` in the
///    sale's branch (permission service, D70 — the matrix governs:
///    Owner / HO Admin everywhere, Branch Manager / Cashier in their
///    own branch, Pharmacist not at all).
/// 2. **Validation:** [validateReturn] — reason required, quantities
///    within what is still returnable.
/// 3. **Restock:** every returned chunk goes back into its batch
///    ([restockTarget], D78) through the production data layer, so
///    the stock ledger + audit entries are written with the movement.
/// 4. **Sale status:** the sale moves to `partiallyReturned` /
///    `returned` ([returnStatusAfter]).
/// 5. **Khata:** when the original sale was credit, the refund is
///    taken off the customer's outstanding (a negative `adjustment`
///    entry — the customer owes less). Cash / card refunds are handed
///    back at the counter and touch no ledger.
/// 6. **Record + audit:** the return is saved and an audit entry
///    (`sale.returned`) is written.
///
/// A failure part-way leaves the earlier steps done — the same
/// trade-off the Day 1 layer documents for ledgers (no cross-repo
/// transaction in the mock; the Firestore implementation batches
/// these writes). The validation + permission steps run first, so
/// the common failures happen before anything is written.
class SaleReturnsNotifier extends AsyncNotifier<List<SaleReturn>> {
  @override
  Future<List<SaleReturn>> build() async {
    final repo = ref.read(saleReturnRepositoryProvider);
    return repo.getReturns();
  }

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(
      () => ref.read(saleReturnRepositoryProvider).getReturns(),
    );
  }

  /// Records a return against [sale]. [quantities] maps chunk keys
  /// ([returnChunkKey]) to the units being returned. Returns the
  /// saved return, or `null` return + an error message when the
  /// permission, validation or restock forbids it.
  Future<({SaleReturn? saleReturn, String? error})> createReturn({
    required Sale sale,
    required Map<String, int> quantities,
    required String reason,
    required AppUser? approver,
  }) async {
    if (!permissionService.canWrite(
      approver,
      'posRefund',
      sale.branchId,
    )) {
      return (
        saleReturn: null,
        error:
            'Returns need the POS refund permission in this branch — '
            'ask a branch manager or the owner to approve this return.',
      );
    }
    final returnsRepo = ref.read(saleReturnRepositoryProvider);
    final existing = await returnsRepo.getReturnsForSale(sale.id);
    final errors = validateReturn(
      sale: sale,
      existingReturns: existing,
      quantities: quantities,
      reason: reason,
    );
    if (errors.isNotEmpty) {
      return (saleReturn: null, error: errors.first);
    }

    final inventory = await ref
        .read(inventoryRepositoryProvider)
        .getInventory(branchId: sale.branchId);
    final refund = computeRefundMinor(sale: sale, quantities: quantities);

    // Build the return items with their restock targets first: a
    // chunk with nowhere to restock rejects the whole return before
    // any stock moves.
    final items = <SaleReturnItem>[];
    for (final item in sale.items) {
      final qty =
          quantities[returnChunkKey(item.medicineId, item.batchId)] ?? 0;
      if (qty <= 0) continue;
      final target = restockTarget(
        inventory: inventory,
        medicineId: item.medicineId,
        originalBatchId: item.batchId,
      );
      if (target == null) {
        return (
          saleReturn: null,
          error:
              '${item.medicineName}: no batch of this medicine exists to '
              'restock into — receive stock first, then record the return.',
        );
      }
      items.add(
        SaleReturnItem(
          medicineId: item.medicineId,
          medicineName: item.medicineName,
          quantity: qty,
          unitPriceMinor: item.unitPriceMinor,
          lineDiscountMinor:
              item.lineDiscountMinor * qty ~/ item.quantity,
          refundMinor: chunkRefundMinor(item: item, quantity: qty),
          saleBatchId: item.batchId,
          restockBatchId: target.id,
          restockBatchNo: target.batchNo,
        ),
      );
    }

    final layer = ref.read(productionDataLayerProvider);
    final actorId = approver?.uid ?? demoActorId;
    final actorName = approver?.name ?? 'Counter Staff';
    final trimmedReason = reason.trim();

    // Restock each chunk through the layer (stock ledger + audit).
    for (final item in items) {
      await layer.adjustStock(
        batchId: item.restockBatchId!,
        deltaQty: item.quantity,
        reason: 'Sale return ${sale.invoiceNumber} — $trimmedReason',
        actorId: actorId,
        actorName: actorName,
        referenceId: sale.id,
      );
    }

    // Sale status after this return.
    final saved = await returnsRepo.createReturn(
      SaleReturn(
        id: '',
        branchId: sale.branchId,
        saleId: sale.id,
        invoiceNumber: sale.invoiceNumber,
        items: items,
        reason: trimmedReason,
        refundedAmountMinor: refund,
        approvedBy: actorId,
        approvedByName: actorName,
      ),
    );
    final newStatus = returnStatusAfter(
      sale: sale,
      allReturns: [...existing, saved],
    );
    await ref
        .read(saleRepositoryProvider)
        .updateSale(sale.copyWith(status: newStatus));
    // The sale status changed in the repository — reload the
    // in-memory sale list, or every sale lookup (receipt, history,
    // returns list) keeps showing the old status.
    await ref.read(salesProvider.notifier).refresh();

    // Credit sale: the refund comes off the customer's khata.
    if (sale.isCredit && sale.customerId != null) {
      await ref.read(customerRepositoryProvider).addLedgerEntry(
        LedgerEntry(
          id: '',
          customerId: sale.customerId!,
          kind: LedgerEntryKind.adjustment,
          amountMinor: -refund,
          reason: 'Return on ${sale.invoiceNumber} — $trimmedReason',
          referenceId: sale.id,
          balanceAfterMinor: 0, // set by the repository
          createdAt: DateTime.now(),
        ),
      );
    }

    await layer.audit.write(
      AuditLogEntry.create(
        organizationId: layer.organizationId,
        branchId: sale.branchId,
        userId: actorId,
        actorName: actorName,
        action: 'sale.returned',
        entityType: 'saleReturn',
        entityId: saved.id,
        summary:
            'Return on ${sale.invoiceNumber}: ${items.length} item(s), '
            'refund $refund paisa',
        before: 'sale ${saleStatusLabel(sale.status)}',
        after: 'sale ${saleStatusLabel(newStatus)}',
      ),
    );

    await refresh();
    ref.invalidate(branchSalesProvider(sale.branchId));
    ref.invalidate(saleByIdProvider(sale.id));
    ref.invalidate(inventoryProvider);
    ref.invalidate(dashboardKpisProvider);
    ref.invalidate(branchComparisonProvider);
    ref.invalidate(ownerLiveKpisProvider);
    return (saleReturn: saved, error: null);
  }
}

final saleReturnsProvider =
    AsyncNotifierProvider<SaleReturnsNotifier, List<SaleReturn>>(
      SaleReturnsNotifier.new,
    );

/// Returns for one branch, newest first.
final branchSaleReturnsProvider = Provider.family<List<SaleReturn>, String>((
  ref,
  branchId,
) {
  final returns = ref.watch(saleReturnsProvider).asData?.value ?? const [];
  final scoped = returns.where((r) => r.branchId == branchId).toList()
    ..sort(
      (a, b) =>
          (b.createdAt ?? DateTime(0)).compareTo(a.createdAt ?? DateTime(0)),
    );
  return scoped;
});

/// Returns recorded against one sale, oldest first.
final saleReturnsForSaleProvider = Provider.family<List<SaleReturn>, String>((
  ref,
  saleId,
) {
  final returns = ref.watch(saleReturnsProvider).asData?.value ?? const [];
  final scoped = returns.where((r) => r.saleId == saleId).toList()
    ..sort(
      (a, b) =>
          (a.createdAt ?? DateTime(0)).compareTo(b.createdAt ?? DateTime(0)),
    );
  return scoped;
});
