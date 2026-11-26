import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/data/production_data_layer.dart';
import '../../core/services/repositories.dart';
import '../../core/widgets/sync_status_widget.dart';
import '../../models/branch_inventory_location.dart';
import '../../models/inventory_item.dart';
import '../../models/medicine.dart';
import '../authentication/auth_state.dart';
import '../dashboard/dashboard_screen.dart';
import '../orders/orders_provider.dart';

/// Day 5 inventory state.
///
/// [InventoryNotifier] owns the in-memory batch list for the session:
/// it loads from the (mock) repository once, and every stock operation
/// — receive, adjust, count — writes through and then refreshes its
/// own state, so the new stock shows immediately in the inventory
/// screen, the medicine detail and (via invalidation) the dashboard
/// figures and the order form's batch info. Week 2 swaps the
/// repository for Firestore behind the same interface; the screens
/// do not change.
///
/// Receive and adjust write through the production data layer (Week 3
/// Day 4, D111 — closes D109), and stock count does too (Week 3 Day 5,
/// D114 — closes the D111 follow-up): the layer books the engine
/// ledger + audit AND enqueues one sync payload per write, so the
/// sync-status chip on the inventory screen moves for stock work.
///
/// The list holds all branches (like the order queue); screens scope
/// to the active branch with [branchInventoryProvider].

class InventoryNotifier extends AsyncNotifier<List<InventoryItem>> {
  @override
  Future<List<InventoryItem>> build() async {
    final repo = ref.read(inventoryRepositoryProvider);
    return repo.getInventory();
  }

  /// Quarantines one batch through the layer (status + audit +
  /// sync). Returns `null` when the transition is not allowed
  /// (e.g. the batch is already quarantined or expired).
  Future<InventoryItem?> quarantineBatch({
    required String batchId,
    required String reason,
    String? idempotencyKey,
  }) async {
    try {
      final updated = await ref
          .read(productionDataLayerProvider)
          .quarantineBatch(
            batchId: batchId,
            reason: reason,
            idempotencyKey: idempotencyKey,
          );
      await refresh();
      _invalidateDependents();
      ref.invalidate(syncStatusProvider);
      return updated;
    } on ArgumentError {
      return null;
    }
  }

  /// Restores a quarantined batch to `available` through the layer.
  /// Returns `null` when the batch is not quarantined.
  Future<InventoryItem?> unquarantineBatch({
    required String batchId,
    required String reason,
    String? idempotencyKey,
  }) async {
    try {
      final updated = await ref
          .read(productionDataLayerProvider)
          .unquarantineBatch(
            batchId: batchId,
            reason: reason,
            idempotencyKey: idempotencyKey,
          );
      await refresh();
      _invalidateDependents();
      ref.invalidate(syncStatusProvider);
      return updated;
    } on ArgumentError {
      return null;
    }
  }

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(
      () => ref.read(inventoryRepositoryProvider).getInventory(),
    );
  }

  /// Saves a per-branch rack / shelf override (Week 5 Day 3, D152)
  /// and refreshes the locations provider, so the detail screen and
  /// the inventory screen show the new shelf at once. Saving with
  /// both fields empty clears the override (the repo returns the
  /// empty record).
  Future<BranchInventoryLocation> saveBranchLocation(
    BranchInventoryLocation location,
  ) async {
    final saved = await ref
        .read(inventoryRepositoryProvider)
        .saveBranchLocation(location);
    ref.invalidate(branchLocationsProvider(location.branchId));
    return saved;
  }

  /// Dashboard figures and the order form read the same inventory
  /// through their own providers — invalidate them after every stock
  /// change so low-stock / near-expiry figures and batch info update
  /// without a restart.
  void _invalidateDependents() {
    ref.invalidate(dashboardKpisProvider);
    ref.invalidate(dashboardAlertsProvider);
    ref.invalidate(branchComparisonProvider);
    ref.invalidate(orderInventoryProvider);
  }

  /// Receives new stock: adds a batch row. Returns the created row.
  /// Writes through the production data layer (D111): the engine
  /// books the receive (ledger + audit) and one sync payload is
  /// enqueued, so the sync-status chip moves.
  ///
  /// [idempotencyKey] is the dialog-held key (D115): the receive
  /// dialog mints it once and reuses it on a retried submit, so a
  /// retry after a failed submit dedupes instead of creating a
  /// second batch. When omitted the layer mints a fresh key.
  Future<InventoryItem> receiveStock({
    required String branchId,
    required String medicineId,
    required String batchNo,
    required DateTime mfgDate,
    required DateTime expiryDate,
    required int quantity,
    required int costMinor,
    String? idempotencyKey,
  }) async {
    final user = ref.read(authProvider);
    final result = await ref
        .read(productionDataLayerProvider)
        .receiveStock(
          branchId: branchId,
          medicineId: medicineId,
          batchNo: batchNo,
          mfgDate: mfgDate,
          expiryDate: expiryDate,
          quantity: quantity,
          costMinor: costMinor,
          idempotencyKey: idempotencyKey,
          actorId: user?.uid ?? demoActorId,
          actorName: user?.name ?? demoActorName,
        );
    await refresh();
    _invalidateDependents();
    ref.invalidate(syncStatusProvider);
    return result.batch;
  }

  /// Adjusts one batch's quantity. Returns the updated row, or `null`
  /// when the layer rejects the adjustment (e.g. removing more than
  /// is on hand, or a missing reason). Writes through the production
  /// data layer (D111): the engine books the adjustment (ledger +
  /// audit) and one sync payload is enqueued, so the sync-status
  /// chip moves.
  ///
  /// [idempotencyKey] is the dialog-held key (D115) — same contract
  /// as [receiveStock].
  Future<InventoryItem?> adjustStock({
    required String batchId,
    required int deltaQty,
    required String reason,
    String? idempotencyKey,
  }) async {
    try {
      final user = ref.read(authProvider);
      await ref
          .read(productionDataLayerProvider)
          .adjustStock(
            batchId: batchId,
            deltaQty: deltaQty,
            reason: reason,
            actorId: user?.uid ?? demoActorId,
            actorName: user?.name ?? demoActorName,
            idempotencyKey: idempotencyKey,
          );
      await refresh();
      _invalidateDependents();
      ref.invalidate(syncStatusProvider);
      return state.asData?.value
          .where((item) => item.id == batchId)
          .firstOrNull;
    } on ArgumentError {
      return null;
    }
  }

  /// Records a physical count for one batch. Returns the updated row
  /// plus the variance (counted − system), or `null` when the
  /// layer rejects the count. Writes through the production data
  /// layer (D114): the engine books the correction (ledger + audit)
  /// and one sync payload is enqueued for a non-zero correction, so
  /// the sync-status chip moves for stock counts too.
  ///
  /// [idempotencyKey] is the dialog-held key (D115) — same contract
  /// as [receiveStock].
  Future<({InventoryItem item, int variance})?> recordStockCount({
    required String batchId,
    required int countedQty,
    String? note,
    String? idempotencyKey,
  }) async {
    final current = state.asData?.value ?? const <InventoryItem>[];
    final before = current
        .where((item) => item.id == batchId)
        .firstOrNull;
    if (before == null) return null;
    try {
      final user = ref.read(authProvider);
      final result = await ref
          .read(productionDataLayerProvider)
          .recordStockCount(
            batchId: batchId,
            countedQty: countedQty,
            note: note,
            idempotencyKey: idempotencyKey,
            actorId: user?.uid ?? demoActorId,
            actorName: user?.name ?? demoActorName,
          );
      await refresh();
      _invalidateDependents();
      ref.invalidate(syncStatusProvider);
      return (item: result.item, variance: result.variance);
    } on ArgumentError {
      return null;
    }
  }
}

final inventoryProvider =
    AsyncNotifierProvider<InventoryNotifier, List<InventoryItem>>(
      InventoryNotifier.new,
    );

/// Batch rows for one branch, in seed order (screens sort FEFO).
final branchInventoryProvider =
    Provider.family<List<InventoryItem>, String>((ref, branchId) {
      final items = ref.watch(inventoryProvider).asData?.value ?? const [];
      return items.where((item) => item.branchId == branchId).toList();
    });

/// Per-branch rack / shelf overrides for one branch (Week 5 Day 3,
/// D152). Screens read the override through this and fall back to
/// the master medicine location when it is absent.
final branchLocationsProvider =
    FutureProvider.family<List<BranchInventoryLocation>, String>((
      ref,
      branchId,
    ) async {
      return ref
          .read(inventoryRepositoryProvider)
          .getBranchLocations(branchId: branchId);
    });

/// Full medicine catalogue (180 medicines, Day 5).
final medicinesProvider = FutureProvider<List<Medicine>>((ref) async {
  return ref.read(medicineRepositoryProvider).getMedicines();
});

/// One medicine by id, from the catalogue (refreshes when it does).
final medicineByIdProvider = Provider.family<Medicine?, String>((ref, id) {
  final medicines = ref.watch(medicinesProvider).asData?.value ?? const [];
  for (final medicine in medicines) {
    if (medicine.id == id) return medicine;
  }
  return null;
});
