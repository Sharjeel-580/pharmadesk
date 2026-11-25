import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/data/production_data_layer.dart';
import '../../core/services/repositories.dart';
import '../../core/widgets/sync_status_widget.dart';
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
    ref.invalidate(branchComparisonProvider);
    ref.invalidate(orderInventoryProvider);
    ref.invalidate(notificationsProvider);
  }

  /// Creates a draft PO after validation. Returns the saved PO, or
  /// `null` PO + an error message when validation rejects it.
  /// [idempotencyKey] is a client-generated id (auto purchase
  /// approval, D65): the repository returns the already-created PO
  /// instead of a duplicate when the same key is submitted again.
  Future<({PurchaseOrder? order, String? error})> createOrder({
    required String branchId,
    required String supplierId,
    required List<PurchaseOrderItem> items,
    String? notes,
    String? idempotencyKey,
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
            id: idempotencyKey ?? '',
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
  /// The write runs through the production data layer (D103): one
  /// `goodsReceipts` document for the delivery, batches into
  /// inventory (batch number, mfg/expiry, cost from the PO line),
  /// the received value charged to the supplier ledger, and the PO
  /// moved to Partially received / Received — with idempotency, so
  /// a retried submit with the same [idempotencyKey] returns the
  /// original receipt and moves nothing twice. The receiving dialog
  /// mints the key once per dialog and passes it on every submit,
  /// so a retry after a failed attempt reuses it (D54/D65 pattern).
  /// Returns the updated PO, or `null` PO + an error message when
  /// validation or the layer rejects the receive (nothing is
  /// partially applied — validation runs first).
  Future<({PurchaseOrder? order, String? error})> receiveOrder(
    PurchaseOrder order,
    List<ReceivingLine> lines, {
    String? idempotencyKey,
  }) async {
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
      final result = await ref
          .read(productionDataLayerProvider)
          .receiveGoods(
            order: order,
            lines: lines,
            idempotencyKey: idempotencyKey,
          );
      await refresh();
      _invalidateDependents();
      // Receiving enqueues one sync payload (D103/D108) — the sync
      // chip on the purchases screen re-reads the queue.
      ref.invalidate(syncStatusProvider);
      return (order: result.order, error: null);
    } on ArgumentError catch (error) {
      return (order: null, error: error.message?.toString());
    } on StateError catch (error) {
      return (order: null, error: error.message);
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
