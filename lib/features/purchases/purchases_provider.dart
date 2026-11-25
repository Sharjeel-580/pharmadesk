import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/repositories.dart';
import '../../models/purchase_order.dart';
import '../../models/supplier_ledger.dart';
import '../dashboard/dashboard_screen.dart';
import '../inventory/inventory_provider.dart';
import '../notifications/notifications_provider.dart';
import '../orders/orders_provider.dart';
import '../suppliers/suppliers_provider.dart';
import 'purchases_logic.dart';

/// Day 7 purchase order state.
///
/// [PurchaseOrdersNotifier] owns the in-memory PO list for the
/// session: it loads from the (mock) repository once, and every
/// mutation — create / approve / receive / cancel — writes through to
/// the repository and refreshes, so the list, detail and supplier
/// history share one source of truth.
///
/// Goods receiving is the coordination point (SRS FR-PUR-02/03):
/// receiving a line adds a batch to inventory (via the inventory
/// repository), charges the received value to the supplier ledger,
/// and moves the PO to Partially received / Received. The inventory
/// and dashboard providers are invalidated after every receive, so
/// the new stock is visible in inventory immediately.

class PurchaseOrdersNotifier extends AsyncNotifier<List<PurchaseOrder>> {
  @override
  Future<List<PurchaseOrder>> build() async {
    final repo = ref.read(purchaseOrderRepositoryProvider);
    return repo.getPurchaseOrders();
  }

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(
      () => ref.read(purchaseOrderRepositoryProvider).getPurchaseOrders(),
    );
  }

  void _invalidateDependents() {
    ref.invalidate(inventoryProvider);
    ref.invalidate(dashboardKpisProvider);
    ref.invalidate(dashboardAlertsProvider);
    ref.invalidate(branchPerformanceProvider);
    ref.invalidate(orderInventoryProvider);
    ref.invalidate(notificationsProvider);
  }

  /// Creates a draft PO after validation. Returns the saved PO, or
  /// `null` PO + an error message when validation rejects it.
  Future<({PurchaseOrder? order, String? error})> createOrder({
    required String branchId,
    required String supplierId,
    required List<PurchaseOrderItem> items,
    String? notes,
  }) async {
    final errors = validatePurchaseOrderForm(
      supplierId: supplierId,
      items: items,
    );
    if (errors.isNotEmpty) {
      return (order: null, error: errors.first);
    }
    final saved = await ref
        .read(purchaseOrderRepositoryProvider)
        .createPurchaseOrder(
          buildNewPurchaseOrder(
            branchId: branchId,
            supplierId: supplierId,
            items: items,
            notes: notes,
          ),
        );
    await refresh();
    ref.invalidate(notificationsProvider);
    return (order: saved, error: null);
  }

  /// Approves a draft PO. Returns `false` when the guard forbids it
  /// (only Draft POs can be approved).
  Future<bool> approveOrder(PurchaseOrder order, {String? approvedBy}) async {
    if (!canApprovePo(order.status)) return false;
    await ref
        .read(purchaseOrderRepositoryProvider)
        .updatePurchaseOrder(
          order.copyWith(
            status: PurchaseOrderStatus.approved,
            approvedBy: approvedBy ?? 'Branch Manager',
          ),
        );
    await refresh();
    ref.invalidate(notificationsProvider);
    return true;
  }

  /// Cancels a PO. Returns `false` when the guard forbids it (only
  /// Draft / Approved POs with nothing received can be cancelled).
  Future<bool> cancelOrder(PurchaseOrder order) async {
    if (!canCancelPo(order)) return false;
    await ref
        .read(purchaseOrderRepositoryProvider)
        .updatePurchaseOrder(
          order.copyWith(status: PurchaseOrderStatus.cancelled),
        );
    await refresh();
    ref.invalidate(notificationsProvider);
    return true;
  }

  /// Receives goods against a PO (SRS FR-PUR-02/03).
  ///
  /// For every line receiving units: a batch is added to inventory
  /// (batch number, mfg/expiry, cost from the PO line) and the
  /// received value is charged to the supplier ledger as a purchase
  /// entry. Returns the updated PO, or `null` PO + an error message
  /// when validation or the inventory repository rejects the receive
  /// (nothing is partially applied — validation runs first).
  Future<({PurchaseOrder? order, String? error})> receiveOrder(
    PurchaseOrder order,
    List<ReceivingLine> lines,
  ) async {
    if (!canReceivePo(order)) {
      return (
        order: null,
        error: 'This purchase order cannot receive goods in its current state.',
      );
    }
    final errors = validateReceiving(lines);
    if (errors.isNotEmpty) {
      return (order: null, error: errors.first);
    }
    try {
      var receivedValueMinor = 0;
      for (final line in lines) {
        if (line.quantityReceivedNow <= 0) continue;
        await ref
            .read(inventoryRepositoryProvider)
            .receiveStock(
              branchId: order.branchId,
              medicineId: line.item.medicineId,
              batchNo: line.batchNo.trim(),
              mfgDate: line.mfgDate!,
              expiryDate: line.expiryDate!,
              quantity: line.quantityReceivedNow,
              costMinor: line.item.unitCostMinor,
            );
        receivedValueMinor +=
            line.quantityReceivedNow * line.item.unitCostMinor;
      }
      final updatedItems = applyReceiving(order.items, lines);
      final updated = order.copyWith(
        items: updatedItems,
        status: statusAfterReceiving(order.copyWith(items: updatedItems)),
      );
      await ref
          .read(purchaseOrderRepositoryProvider)
          .updatePurchaseOrder(updated);
      if (receivedValueMinor > 0) {
        await ref
            .read(supplierRepositoryProvider)
            .addLedgerEntry(
              SupplierLedgerEntry(
                id: '',
                supplierId: order.supplierId,
                kind: SupplierLedgerEntryKind.purchase,
                amountMinor: receivedValueMinor,
                reason: 'Goods received — ${order.poNumber}',
                referenceId: order.id,
                balanceAfterMinor: 0, // set by the repository
                createdAt: DateTime.now(),
              ),
            );
      }
      await refresh();
      _invalidateDependents();
      return (order: updated, error: null);
    } on ArgumentError catch (error) {
      return (order: null, error: error.message?.toString());
    }
  }

  /// Records a payment to the supplier against their outstanding
  /// payable. Returns `false` when the payment exceeds the
  /// outstanding balance. The supplier ledger provider is refreshed
  /// so the supplier detail updates immediately.
  Future<bool> recordSupplierPayment({
    required String supplierId,
    required int amountMinor,
    String reason = '',
  }) async {
    final ledger = await ref
        .read(supplierRepositoryProvider)
        .getLedgerEntries(supplierId);
    final outstanding = ledger.fold(
      0,
      (sum, entry) => sum + entry.amountMinor,
    );
    if (amountMinor <= 0 || amountMinor > outstanding) return false;
    await ref
        .read(supplierRepositoryProvider)
        .addLedgerEntry(
          SupplierLedgerEntry(
            id: '',
            supplierId: supplierId,
            kind: SupplierLedgerEntryKind.payment,
            amountMinor: -amountMinor,
            reason: reason.trim().isEmpty ? 'Payment made' : reason.trim(),
            balanceAfterMinor: 0, // set by the repository
            createdAt: DateTime.now(),
          ),
        );
    // The supplier detail reads the ledger through its own notifier.
    ref.invalidate(supplierLedgerProvider(supplierId));
    return true;
  }
}

final purchaseOrdersProvider =
    AsyncNotifierProvider<PurchaseOrdersNotifier, List<PurchaseOrder>>(
      PurchaseOrdersNotifier.new,
    );

/// One PO by id, from the list (refreshes when the list does).
final purchaseOrderByIdProvider = Provider.family<PurchaseOrder?, String>((
  ref,
  id,
) {
  final orders = ref.watch(purchaseOrdersProvider).asData?.value ?? const [];
  for (final order in orders) {
    if (order.id == id) return order;
  }
  return null;
});

/// POs for one supplier, newest first (supplier detail history).
final purchaseOrdersBySupplierProvider =
    Provider.family<List<PurchaseOrder>, String>((ref, supplierId) {
      final orders =
          ref.watch(purchaseOrdersProvider).asData?.value ?? const [];
      final scoped = orders
          .where((po) => po.supplierId == supplierId)
          .toList();
      scoped.sort((a, b) {
        final aTime = a.createdAt;
        final bTime = b.createdAt;
        if (aTime == null && bTime == null) return 0;
        if (aTime == null) return 1;
        if (bTime == null) return -1;
        return bTime.compareTo(aTime);
      });
      return scoped;
    });
