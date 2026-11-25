import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/repositories.dart';
import '../../models/inventory_item.dart';
import '../../models/medicine.dart';
import '../dashboard/dashboard_screen.dart';
import '../orders/orders_provider.dart';

/// Day 5 inventory state.
///
/// [InventoryNotifier] owns the in-memory batch list for the session:
/// it loads from the (mock) repository once, and every stock operation
/// — receive, adjust, count — writes through to the repository and
/// then refreshes its own state, so the new stock shows immediately in
/// the inventory screen, the medicine detail and (via invalidation)
/// the dashboard figures and the order form's batch info. Week 2 swaps
/// the repository for Firestore behind the same interface; the screens
/// do not change.
///
/// The list holds all branches (like the order queue); screens scope
/// to the active branch with [branchInventoryProvider].

class InventoryNotifier extends AsyncNotifier<List<InventoryItem>> {
  @override
  Future<List<InventoryItem>> build() async {
    final repo = ref.read(inventoryRepositoryProvider);
    return repo.getInventory();
  }

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(
      () => ref.read(inventoryRepositoryProvider).getInventory(),
    );
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
  Future<InventoryItem> receiveStock({
    required String branchId,
    required String medicineId,
    required String batchNo,
    required DateTime mfgDate,
    required DateTime expiryDate,
    required int quantity,
    required int costMinor,
  }) async {
    final created = await ref
        .read(inventoryRepositoryProvider)
        .receiveStock(
          branchId: branchId,
          medicineId: medicineId,
          batchNo: batchNo,
          mfgDate: mfgDate,
          expiryDate: expiryDate,
          quantity: quantity,
          costMinor: costMinor,
        );
    await refresh();
    _invalidateDependents();
    return created;
  }

  /// Adjusts one batch's quantity. Returns the updated row, or `null`
  /// when the repository rejects the adjustment (e.g. removing more
  /// than is on hand, or a missing reason).
  Future<InventoryItem?> adjustStock({
    required String batchId,
    required int deltaQty,
    required String reason,
  }) async {
    try {
      final updated = await ref
          .read(inventoryRepositoryProvider)
          .adjustStock(
            batchId: batchId,
            deltaQty: deltaQty,
            reason: reason,
          );
      await refresh();
      _invalidateDependents();
      return updated;
    } on ArgumentError {
      return null;
    }
  }

  /// Records a physical count for one batch. Returns the updated row
  /// plus the variance (counted − system), or `null` when the
  /// repository rejects the count.
  Future<({InventoryItem item, int variance})?> recordStockCount({
    required String batchId,
    required int countedQty,
    String? note,
  }) async {
    final current = state.asData?.value ?? const <InventoryItem>[];
    final before = current
        .where((item) => item.id == batchId)
        .firstOrNull;
    if (before == null) return null;
    try {
      final updated = await ref
          .read(inventoryRepositoryProvider)
          .recordStockCount(
            batchId: batchId,
            countedQty: countedQty,
            note: note,
          );
      await refresh();
      _invalidateDependents();
      return (item: updated, variance: countedQty - before.quantity);
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
