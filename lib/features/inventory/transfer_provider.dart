import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/data/production_data_layer.dart';
import '../../core/services/repositories.dart';
import '../../core/widgets/sync_status_widget.dart';
import '../../models/medicine.dart';
import '../../models/stock_transfer.dart';
import '../authentication/auth_state.dart';
import '../dashboard/dashboard_screen.dart';
import '../orders/orders_provider.dart';
import 'inventory_logic.dart';
import 'inventory_provider.dart';

/// Stock transfer state (Week 4 Day 2, D118).
///
/// [TransferNotifier] owns the in-memory transfer list for the
/// session: it loads from the (mock) repository once, and every
/// lifecycle step — request, approve, reject, cancel, dispatch,
/// receive — writes through the production data layer and then
/// refreshes its own state, so the new status shows immediately.
/// Week 2 swaps the repository for Firestore behind the same
/// interface; the screens do not change.
///
/// Dispatch / receive move real stock, so after those steps the
/// inventory, dashboard and order-form providers are invalidated
/// too (the same dependents the inventory notifier invalidates).
class TransferNotifier extends AsyncNotifier<List<StockTransfer>> {
  @override
  Future<List<StockTransfer>> build() async {
    final repo = ref.read(stockTransferRepositoryProvider);
    return repo.getTransfers();
  }

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(
      () => ref.read(stockTransferRepositoryProvider).getTransfers(),
    );
  }

  void _invalidateDependents() {
    ref.invalidate(inventoryProvider);
    ref.invalidate(dashboardKpisProvider);
    ref.invalidate(dashboardAlertsProvider);
    ref.invalidate(branchComparisonProvider);
    ref.invalidate(orderInventoryProvider);
  }

  Future<StockTransfer> createTransfer({
    required String fromBranchId,
    required String toBranchId,
    required List<TransferItem> items,
    String? note,
    String? idempotencyKey,
  }) async {
    final user = ref.read(authProvider);
    final result = await ref
        .read(productionDataLayerProvider)
        .createTransfer(
          fromBranchId: fromBranchId,
          toBranchId: toBranchId,
          items: items,
          note: note,
          idempotencyKey: idempotencyKey,
          actorId: user?.uid ?? demoActorId,
          actorName: user?.displayName ?? demoActorName,
        );
    await refresh();
    ref.invalidate(syncStatusProvider);
    return result.transfer;
  }

  Future<StockTransfer> approveTransfer(StockTransfer transfer) async {
    final user = ref.read(authProvider);
    final updated = await ref
        .read(productionDataLayerProvider)
        .approveTransfer(
          transfer.id,
          actorId: user?.uid ?? demoActorId,
          actorName: user?.displayName ?? demoActorName,
        );
    await refresh();
    ref.invalidate(syncStatusProvider);
    return updated;
  }

  Future<StockTransfer> rejectTransfer(StockTransfer transfer) async {
    final user = ref.read(authProvider);
    final updated = await ref
        .read(productionDataLayerProvider)
        .rejectTransfer(
          transfer.id,
          actorId: user?.uid ?? demoActorId,
          actorName: user?.displayName ?? demoActorName,
        );
    await refresh();
    ref.invalidate(syncStatusProvider);
    return updated;
  }

  Future<StockTransfer> cancelTransfer(StockTransfer transfer) async {
    final user = ref.read(authProvider);
    final updated = await ref
        .read(productionDataLayerProvider)
        .cancelTransfer(
          transfer.id,
          actorId: user?.uid ?? demoActorId,
          actorName: user?.displayName ?? demoActorName,
        );
    await refresh();
    ref.invalidate(syncStatusProvider);
    return updated;
  }

  /// Dispatches an Approved transfer. Returns the updated transfer,
  /// or `null` when the layer rejects the dispatch (e.g. a line
  /// exceeds sellable source stock) — the detail screen turns that
  /// into the error it already shows.
  Future<StockTransfer?> dispatchTransfer(
    StockTransfer transfer, {
    String? idempotencyKey,
  }) async {
    try {
      final user = ref.read(authProvider);
      final result = await ref
          .read(productionDataLayerProvider)
          .dispatchTransfer(
            transferId: transfer.id,
            idempotencyKey: idempotencyKey,
            actorId: user?.uid ?? demoActorId,
            actorName: user?.displayName ?? demoActorName,
          );
      await refresh();
      _invalidateDependents();
      ref.invalidate(syncStatusProvider);
      return result.transfer;
    } on ArgumentError {
      return null;
    }
  }

  /// Receives a Dispatched transfer at the destination. Returns the
  /// updated transfer, or `null` when the layer rejects the receive.
  Future<StockTransfer?> receiveTransfer(
    StockTransfer transfer, {
    String? idempotencyKey,
  }) async {
    try {
      final user = ref.read(authProvider);
      final result = await ref
          .read(productionDataLayerProvider)
          .receiveTransfer(
            transferId: transfer.id,
            idempotencyKey: idempotencyKey,
            actorId: user?.uid ?? demoActorId,
            actorName: user?.displayName ?? demoActorName,
          );
      await refresh();
      _invalidateDependents();
      ref.invalidate(syncStatusProvider);
      return result.transfer;
    } on ArgumentError {
      return null;
    }
  }
}

final transferProvider =
    AsyncNotifierProvider<TransferNotifier, List<StockTransfer>>(
      TransferNotifier.new,
    );

/// One transfer by id, from the list (refreshes when the list does).
final transferByIdProvider = Provider.family<StockTransfer?, String>((
  ref,
  id,
) {
  final transfers = ref.watch(transferProvider).asData?.value ?? const [];
  for (final transfer in transfers) {
    if (transfer.id == id) return transfer;
  }
  return null;
});

/// Medicine catalogue for the transfer form's picker.
final transferMedicinesProvider = FutureProvider<List<Medicine>>((
  ref,
) async {
  return ref.read(medicineRepositoryProvider).getMedicines();
});

/// On-hand units per medicine in one branch, from the inventory
/// list — the transfer form shows it next to each medicine so the
/// requester can see what the source branch actually holds.
final transferSourceStockProvider =
    Provider.family<Map<String, int>, String>((ref, branchId) {
      final items = ref.watch(inventoryProvider).asData?.value ?? const [];
      final onHand = <String, int>{};
      for (final item in items) {
        if (item.branchId != branchId) continue;
        onHand[item.medicineId] =
            (onHand[item.medicineId] ?? 0) + item.quantity;
      }
      return onHand;
    });

/// Sellable on-hand units per medicine in one branch (expired /
/// quarantined batches excluded — the same Day 5 guard the POS
/// uses, so the form's figure matches what dispatch can actually
/// pick). Kept separate from [transferSourceStockProvider] because
/// the list screen wants the plain total and the form wants the
/// dispatchable figure.
final transferSellableStockProvider =
    Provider.family<Map<String, int>, String>((ref, branchId) {
      final items = ref.watch(branchInventoryProvider(branchId));
      final sellable = <String, int>{};
      for (final item in items) {
        if (!isBatchSellable(item)) continue;
        sellable[item.medicineId] =
            (sellable[item.medicineId] ?? 0) + item.quantity;
      }
      return sellable;
    });
