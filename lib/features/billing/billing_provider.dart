import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/data/production_data_layer.dart';
import '../../core/data/sync_queue.dart';
import '../../core/services/repositories.dart';
import '../../core/widgets/sync_status_widget.dart';
import '../../features/authentication/auth_state.dart';
import '../../models/customer_ledger.dart';
import '../../models/sale.dart';
import '../customers/customer_logic.dart';
import '../dashboard/dashboard_screen.dart';
import '../inventory/inventory_logic.dart';
import '../inventory/inventory_provider.dart';
import '../orders/orders_provider.dart';
import 'billing_logic.dart';

/// Day 6 POS state.
///
/// [SaleNotifier] owns the in-memory sale list for the session and
/// completes sales end to end:
///
/// 1. Re-reads the branch inventory and validates the cart against
///    live sellable stock ([validateSale] + the Day 5 shared guard).
/// 2. Allocates FEFO batches ([allocateFefo]) and commits through the
///    production data layer ([ProductionDataLayer.commitSale]): reserve
///    → save → confirm (stock decrement + ledger + audit) → sync
///    enqueue, with idempotency dedupe on the sale key.
/// 3. For a credit sale, the layer appends the khata entry.
/// 4. Refreshes its own state and invalidates the inventory +
///    dashboard providers, so stock, alerts and daily figures update
///    immediately.
///
/// A double-tap / retried completion can never create a duplicate
/// sale: [_completing] blocks a second run while one is in flight, and
/// every sale carries a client-generated idempotency key (SRS
/// FR-POS-11) that the data layer uses as the Firestore document id.
/// The key is minted once per cart ([pendingSaleKey], D54) and held
/// across retries: a failed attempt keeps the key, so the retry
/// dedupes against the original commit instead of minting a new key
/// and double-charging stock. A successful sale clears it.
class SaleNotifier extends AsyncNotifier<List<Sale>> {
  bool _completing = false;

  /// Idempotency key for the cart currently being completed, minted
  /// on the first attempt and held until the sale succeeds (D54).
  /// `null` when no completion is in progress.
  String? _pendingSaleKey;

  /// The key a retry would reuse (`null` when no completion is in
  /// progress). Test seam for the D54 guarantee.
  String? get pendingSaleKey => _pendingSaleKey;

  @override
  Future<List<Sale>> build() async {
    final repo = ref.read(saleRepositoryProvider);
    return repo.getSales();
  }

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(
      () => ref.read(saleRepositoryProvider).getSales(),
    );
  }

  /// Completes a sale from the POS cart. Returns the saved sale, or
  /// `null` sale + an error message when validation, stock or the
  /// credit limit forbids it. On failure nothing is saved and no
  /// stock is decremented.
  ///
  /// [idempotencyKey] mints the held key when none is held yet
  /// (tests / callers that mint their own). A key already held from
  /// an earlier attempt wins — the retry must reuse it (D54).
  Future<({Sale? sale, String? error})> completeSale({
    required String branchId,
    String? customerId,
    required String cashierName,
    required List<CartLine> lines,
    int billDiscountMinor = 0,
    int taxRatePercent = 0,
    required SalePaymentMethod paymentMethod,
    int cashReceivedMinor = 0,
    String? idempotencyKey,
  }) async {
    if (_completing) {
      return (sale: null, error: 'Sale already in progress — please wait.');
    }
    _completing = true;
    // Mint once per cart, hold across retries (D54): a retry after a
    // failed attempt reuses this key, so the layer dedupes instead
    // of committing a second sale.
    _pendingSaleKey ??= idempotencyKey ?? newIdempotencyKey('sale-$branchId');
    try {
      // Live stock for this branch, grouped per medicine.
      final inventory = await ref
          .read(inventoryRepositoryProvider)
          .getInventory(branchId: branchId);
      final batchesByMedicine = groupBatchesByMedicine(inventory);
      final sellableByMedicine = {
        for (final entry in batchesByMedicine.entries)
          entry.key: sellableStockFor(entry.value),
      };

      // Live khata state for a credit sale.
      var outstanding = 0;
      var creditLimit = 0;
      if (customerId != null) {
        final entries = await ref
            .read(customerRepositoryProvider)
            .getLedgerEntries(customerId);
        outstanding = outstandingMinor(entries);
        final customer = await ref
            .read(customerRepositoryProvider)
            .getById(customerId);
        creditLimit = customer?.creditLimitMinor ?? 0;
      }

      final errors = validateSale(
        lines: lines,
        billDiscountMinor: billDiscountMinor,
        taxRatePercent: taxRatePercent,
        paymentMethod: paymentMethod,
        cashReceivedMinor: cashReceivedMinor,
        customerId: customerId,
        outstandingMinor: outstanding,
        creditLimitMinor: creditLimit,
        sellableStockByMedicine: sellableByMedicine,
      );
      if (errors.isNotEmpty) {
        return (sale: null, error: errors.first);
      }

      final allocation = allocateFefo(
        lines: lines,
        batchesByMedicine: batchesByMedicine,
      );
      final sale = buildSale(
        branchId: branchId,
        customerId: customerId,
        cashierName: cashierName,
        items: allocation.items,
        billDiscountMinor: billDiscountMinor,
        taxRatePercent: taxRatePercent,
        paymentMethod: paymentMethod,
        cashReceivedMinor: cashReceivedMinor,
        idempotencyKey: _pendingSaleKey,
      );

      // Commit through the production data layer (Week 2 Day 1):
      // reserve the FEFO batches → save the sale → confirm the
      // reservation (stock decrement + ledger + audit) → enqueue the
      // sync op. A retried commit with the same idempotency key
      // returns the original sale and moves no stock twice.
      final layer = ref.read(productionDataLayerProvider);
      LedgerEntry? creditEntry;
      if (sale.isCredit && customerId != null) {
        creditEntry = LedgerEntry(
          id: '',
          customerId: customerId,
          kind: LedgerEntryKind.creditSale,
          amountMinor: sale.totalMinor,
          reason: 'Credit sale',
          referenceId: '',
          balanceAfterMinor: 0, // set by the repository
          createdAt: DateTime.now(),
        );
      }
      final commit = await layer.commitSale(
        sale: sale,
        decrements: allocation.decrements,
        actorId: ref.read(authProvider)?.uid ?? demoActorId,
        actorName: cashierName,
        creditLedgerEntry: creditEntry,
      );
      final Sale saved = commit.sale;

      // The sale committed (or was a duplicate of an earlier commit
      // with the same key): the held key is spent.
      _pendingSaleKey = null;
      await refresh();
      _invalidateDependents();
      return (sale: saved, error: null);
    } on ArgumentError catch (error) {
      return (sale: null, error: error.message?.toString());
    } finally {
      _completing = false;
    }
  }

  /// A sale changes stock and daily figures, so the inventory list,
  /// the dashboard KPIs / alerts / branch performance and the order
  /// form's batch info all refresh without a restart.
  void _invalidateDependents() {
    ref.invalidate(inventoryProvider);
    ref.invalidate(dashboardKpisProvider);
    ref.invalidate(dashboardAlertsProvider);
    ref.invalidate(branchComparisonProvider);
    ref.invalidate(orderInventoryProvider);
    // A completed sale enqueues one sync op (D103/D108) — the sync
    // chip on the POS screen re-reads the queue.
    ref.invalidate(syncStatusProvider);
  }
}

final salesProvider = AsyncNotifierProvider<SaleNotifier, List<Sale>>(
  SaleNotifier.new,
);

/// Sales for one branch, newest first (sales history is branch-scoped).
final branchSalesProvider = Provider.family<List<Sale>, String>((
  ref,
  branchId,
) {
  final sales = ref.watch(salesProvider).asData?.value ?? const [];
  final scoped = sales.where((sale) => sale.branchId == branchId).toList()
    ..sort(
      (a, b) =>
          (b.createdAt ?? DateTime(0)).compareTo(a.createdAt ?? DateTime(0)),
    );
  return scoped;
});

/// One sale by id, from the sale list (refreshes when it does).
final saleByIdProvider = Provider.family<Sale?, String>((ref, id) {
  final sales = ref.watch(salesProvider).asData?.value ?? const [];
  for (final sale in sales) {
    if (sale.id == id) return sale;
  }
  return null;
});
