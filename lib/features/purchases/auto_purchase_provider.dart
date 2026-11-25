import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/branch_context.dart';
import '../../models/purchase_order.dart';
import '../../models/supplier.dart';
import '../inventory/inventory_provider.dart';
import '../suppliers/suppliers_provider.dart';
import 'auto_purchase_logic.dart';
import 'purchases_provider.dart';

/// Week 2 Day 2 — Auto Purchase List state.
///
/// [AutoPurchaseListNotifier] owns the editable suggested list for
/// the active branch: it loads inventory + catalogue + POs +
/// suppliers, computes the suggestions through the pure logic, and
/// holds the staff's edits (quantity, supplier, removed lines) until
/// approval. Approval groups the lines by supplier and creates one
/// Draft PO per supplier through [PurchaseOrdersNotifier.createOrder],
/// so the POs appear in the Purchases module at once and follow the
/// normal Draft → Approved → receiving flow.
///
/// Idempotency (D54/D65): approval is guarded two ways — the approve
/// button is disabled while an approval is in flight (`isApproving`),
/// and every approval carries a client-generated key
/// (`auto-po-<branch>-<supplier>-<approvalKey>`). A completed key is
/// remembered for the session and returns the already-created POs
/// instead of creating duplicates, and the mock PO repository itself
/// dedupes on a non-empty client id. A retry after a failed attempt
/// reuses the screen's key, so it can never double-order.

class AutoPurchaseListState {
  const AutoPurchaseListState({
    this.branchId = '',
    this.branchName = '',
    this.loading = true,
    this.lines = const [],
    this.excluded = const [],
    this.generatedAt,
    this.isApproving = false,
    this.error,
    this.lastCreated = const [],
  });

  final String branchId;
  final String branchName;
  final bool loading;
  final List<AutoPurchaseLine> lines;
  final List<AutoPurchaseSuggestion> excluded;
  final DateTime? generatedAt;
  final bool isApproving;
  final String? error;

  /// POs created by the most recent approval (empty until one runs).
  final List<PurchaseOrder> lastCreated;

  int get excludedCount => excluded.length;

  int get totalMinor => autoPurchaseTotalMinor(lines);

  int get orderableCount =>
      lines.where((line) => line.quantity > 0).length;

  AutoPurchaseListState copyWith({
    String? branchId,
    String? branchName,
    bool? loading,
    List<AutoPurchaseLine>? lines,
    List<AutoPurchaseSuggestion>? excluded,
    DateTime? generatedAt,
    bool? isApproving,
    String? error,
    bool clearError = false,
    List<PurchaseOrder>? lastCreated,
  }) {
    return AutoPurchaseListState(
      branchId: branchId ?? this.branchId,
      branchName: branchName ?? this.branchName,
      loading: loading ?? this.loading,
      lines: lines ?? this.lines,
      excluded: excluded ?? this.excluded,
      generatedAt: generatedAt ?? this.generatedAt,
      isApproving: isApproving ?? this.isApproving,
      error: clearError ? null : (error ?? this.error),
      lastCreated: lastCreated ?? this.lastCreated,
    );
  }
}

class AutoPurchaseListNotifier extends Notifier<AutoPurchaseListState> {
  bool _approving = false;

  /// Approval keys already completed this session → the POs they
  /// created. A retry with the same key returns these, never new POs.
  final Map<String, List<PurchaseOrder>> _completedApprovals = {};

  int _approvalCounter = 0;

  @override
  AutoPurchaseListState build() => const AutoPurchaseListState();

  /// Loads (or reloads) the list for [branchId]: recomputes the
  /// suggestions from current inventory, so a refresh picks up
  /// receiving, sales and PO changes. Staff edits are discarded on
  /// reload — the screen says so on the Refresh button.
  Future<void> load(String branchId) async {
    final branch = demoBranches
        .where((b) => b.id == branchId)
        .firstOrNull;
    state = state.copyWith(
      branchId: branchId,
      branchName: branch?.name ?? branchId,
      loading: true,
      clearError: true,
    );
    try {
      final inventory = await ref.read(inventoryProvider.future);
      final medicines = await ref.read(medicinesProvider.future);
      final orders = await ref.read(purchaseOrdersProvider.future);
      final suppliers = await ref.read(suppliersProvider.future);
      final branchOrders = orders
          .where((po) => po.branchId == branchId)
          .toList();
      final result = computeAutoPurchaseList(
        medicines: medicines,
        inventory: inventory,
        branchOrders: branchOrders,
        suppliers: suppliers,
        branchId: branchId,
      );
      state = state.copyWith(
        loading: false,
        lines: [
          for (final suggestion in result.suggestions)
            AutoPurchaseLine(
              suggestion: suggestion,
              quantity: suggestion.suggestedQuantity,
              supplierId: suggestion.supplierId,
            ),
        ],
        excluded: result.excluded,
        generatedAt: DateTime.now(),
        lastCreated: const [],
      );
    } catch (error) {
      state = state.copyWith(
        loading: false,
        error: 'The auto purchase list could not load: $error',
      );
    }
  }

  /// Recomputes from current inventory for the loaded branch.
  Future<void> refresh() async {
    if (state.branchId.isEmpty) return;
    await load(state.branchId);
  }

  /// Sets a line's quantity. Returns an error message when the
  /// quantity is invalid (the old quantity is kept); `null` on
  /// success. Quantities are integers ≥ 0 — 0 means "do not order
  /// this line".
  String? setQuantity(String medicineId, int quantity) {
    if (quantity < 0) {
      return 'Quantity cannot be negative.';
    }
    final index = state.lines.indexWhere(
      (line) => line.suggestion.medicineId == medicineId,
    );
    if (index == -1) return 'That line is no longer on the list.';
    final lines = List<AutoPurchaseLine>.of(state.lines);
    lines[index] = lines[index].copyWith(quantity: quantity);
    state = state.copyWith(lines: lines, clearError: true);
    return null;
  }

  /// Removes a line from the list. Refresh recomputes from inventory
  /// and brings it back.
  void removeLine(String medicineId) {
    state = state.copyWith(
      lines: state.lines
          .where((line) => line.suggestion.medicineId != medicineId)
          .toList(),
      clearError: true,
    );
  }

  /// Changes a line's supplier (approval groups by this value).
  /// Returns an error message when the supplier is not active, or
  /// `null` on success.
  String? setSupplier(String medicineId, String supplierId) {
    final index = state.lines.indexWhere(
      (line) => line.suggestion.medicineId == medicineId,
    );
    if (index == -1) return 'That line is no longer on the list.';
    final lines = List<AutoPurchaseLine>.of(state.lines);
    lines[index] = lines[index].copyWith(supplierId: supplierId);
    state = state.copyWith(lines: lines, clearError: true);
    return null;
  }

  /// Approves the list: one Draft PO per supplier, through the
  /// normal purchases flow.
  ///
  /// Pass [idempotencyKey] to make a retry dedupe — the screen mints
  /// one key per approval tap and reuses it on retry. Returns the
  /// created POs, or an empty list + an error message when validation
  /// or the repository rejects the approval. While an approval is in
  /// flight a second call returns an "already in progress" error
  /// immediately (the button is disabled at the same time, so a
  /// double-tap can never reach here twice).
  Future<({List<PurchaseOrder> orders, String? error})> approve({
    String? idempotencyKey,
  }) async {
    if (_approving) {
      return (
        orders: const <PurchaseOrder>[],
        error: 'Approval is already in progress.',
      );
    }
    final key =
        idempotencyKey ??
        'auto-po-${state.branchId}-${DateTime.now().millisecondsSinceEpoch}-${++_approvalCounter}';
    final alreadyCreated = _completedApprovals[key];
    if (alreadyCreated != null) {
      return (orders: alreadyCreated, error: null);
    }
    final errors = validateAutoPurchaseLines(state.lines);
    if (errors.isNotEmpty) {
      state = state.copyWith(error: errors.first);
      return (orders: const <PurchaseOrder>[], error: errors.first);
    }
    _approving = true;
    state = state.copyWith(isApproving: true, clearError: true);
    try {
      final grouped = groupLinesBySupplier(state.lines);
      final created = <PurchaseOrder>[];
      for (final entry in grouped.entries) {
        final supplierId = entry.key;
        final poKey = '$key-$supplierId';
        final result = await ref
            .read(purchaseOrdersProvider.notifier)
            .createOrder(
              branchId: state.branchId,
              supplierId: supplierId,
              items: entry.value,
              notes: 'Created from the Auto Purchase List.',
              idempotencyKey: poKey,
            );
        if (result.error != null || result.order == null) {
          state = state.copyWith(
            error: result.error ?? 'A purchase order could not be created.',
          );
          return (orders: created, error: state.error);
        }
        created.add(result.order!);
      }
      _completedApprovals[key] = List.unmodifiable(created);
      final approvedIds = {
        for (final line in state.lines)
          if (line.quantity > 0) line.suggestion.medicineId,
      };
      state = state.copyWith(
        lines: state.lines
            .where(
              (line) => !approvedIds.contains(line.suggestion.medicineId),
            )
            .toList(),
        lastCreated: created,
      );
      // Approved medicines are now covered by open Draft POs, so a
      // recompute excludes them; the remaining lines stay as edited.
      await refresh();
      state = state.copyWith(lastCreated: created);
      return (orders: created, error: null);
    } finally {
      _approving = false;
      if (state.isApproving) {
        state = state.copyWith(isApproving: false);
      }
    }
  }
}

final autoPurchaseListProvider =
    NotifierProvider<AutoPurchaseListNotifier, AutoPurchaseListState>(
      AutoPurchaseListNotifier.new,
    );

/// Active suppliers, in directory order (for the per-line picker).
final autoPurchaseSuppliersProvider = Provider<List<Supplier>>((ref) {
  final suppliers = ref.watch(suppliersProvider).asData?.value ?? const [];
  return suppliers.where((s) => s.isActive).toList();
});
