import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/data/production_data_layer.dart';
import '../../core/widgets/sync_status_widget.dart';
import '../../models/stock_adjustment_request.dart';
import '../authentication/auth_state.dart';
import 'inventory_provider.dart';
import 'stock_adjustment_logic.dart';

/// The stock-adjustment approval queue (Week 4 Day 5, D141 — SRS
/// D-14 / FR-INV-08, §5.2.4; persisted Week 5 Day 1, D146).
///
/// Requests are filed through the production data layer
/// ([ProductionDataLayer.fileAdjustmentRequest]) and stored under
/// `branches/{branchId}/stockAdjustments/{id}` (mock now, Firestore
/// when the bundle switches), so a request survives a notifier
/// rebuild and an app restart. The notifier re-reads the persisted
/// requests on start ([refresh], kicked off from [build]) and
/// resumes the `adj-N` sequence past them, so a re-filed id can
/// never collide with a persisted one.
///
/// Flow: the Adjust dialog files a request ([requestAdjustment]);
/// an approver (a role the §5.1 matrix allows to approve, other
/// than the requester) approves ([approveAdjustment]) or rejects
/// ([rejectAdjustment]). Approval applies the adjustment through
/// the layer — ledger + audit + sync, exactly like the old direct
/// adjust — and records the ledger movement id on the request. The
/// decision is persisted to the same document before the state
/// updates, so the persisted queue never lags the screen.
final stockAdjustmentQueueProvider =
    NotifierProvider<StockAdjustmentQueueNotifier, List<StockAdjustmentRequest>>(
      StockAdjustmentQueueNotifier.new,
    );

class StockAdjustmentQueueNotifier
    extends Notifier<List<StockAdjustmentRequest>> {
  int _sequence = 0;

  /// The in-flight initial load, started by [build]: mutating
  /// methods await it before minting an id or deciding a request,
  /// so they always see the persisted queue first.
  Future<void>? _loadFuture;

  @override
  List<StockAdjustmentRequest> build() {
    _loadFuture = refresh();
    return const [];
  }

  Future<void> _ensureLoaded() => _loadFuture ?? Future.value();

  /// Re-reads the persisted requests from the layer and merges them
  /// into the state. Persisted requests win, except for one
  /// interleave: a decision that is already in memory but not yet
  /// persisted (the persist runs just before the state update, so
  /// this only happens if that persist failed) is kept over a
  /// still-pending persisted copy — the next decision write repairs
  /// the persisted copy. Also resumes [_sequence] past the highest
  /// persisted `adj-N` id.
  Future<void> refresh() async {
    final persisted = await ref
        .read(productionDataLayerProvider)
        .loadAdjustmentRequests();
    final mergedById = <String, StockAdjustmentRequest>{
      for (final request in persisted) request.id: request,
    };
    for (final current in state) {
      final kept = mergedById[current.id];
      if (kept == null) {
        mergedById[current.id] = current;
      } else if (!current.isPending && kept.isPending) {
        mergedById[current.id] = current;
      }
    }
    state = mergedById.values.toList();
    for (final request in state) {
      final match = RegExp(r'^adj-(\d+)$').firstMatch(request.id);
      if (match != null) {
        final number = int.tryParse(match.group(1) ?? '') ?? 0;
        if (number > _sequence) _sequence = number;
      }
    }
  }

  /// Files a new adjustment request. Persists it through the layer
  /// first, then adds it to the state. Returns the request, or
  /// `null` when the requester is signed out or the request is
  /// invalid (zero quantity, missing reason, decrease above
  /// [onHandQty]).
  Future<StockAdjustmentRequest?> requestAdjustment({
    required String batchId,
    required String batchNo,
    required String medicineId,
    required String medicineName,
    required String branchId,
    required int deltaQty,
    required String reason,
    required int onHandQty,
  }) async {
    await _ensureLoaded();
    final requester = ref.read(authProvider);
    if (requester == null) return null;
    final error = validateAdjustmentRequest(
      deltaQty: deltaQty,
      reason: reason,
      onHandQty: onHandQty,
    );
    if (error != null) return null;
    _sequence++;
    final request = StockAdjustmentRequest(
      id: 'adj-$_sequence',
      batchId: batchId,
      batchNo: batchNo,
      medicineId: medicineId,
      medicineName: medicineName,
      branchId: branchId,
      deltaQty: deltaQty,
      reason: reason.trim(),
      requesterId: requester.uid,
      requesterName: requester.name,
      requestedAt: DateTime.now(),
    );
    final saved = await ref
        .read(productionDataLayerProvider)
        .fileAdjustmentRequest(request);
    state = [...state, saved];
    return saved;
  }

  /// Approves a pending request and applies it through the layer.
  /// Returns the approved request, or `null` when the request is
  /// not pending, the caller may not approve it (wrong role, or the
  /// requester themself — §5.2.4), or the layer rejects the apply
  /// (e.g. stock moved since the request was filed — the request
  /// stays pending, and the approver can try again or reject it).
  ///
  /// The idempotency key is the request id, so a double-tap on
  /// Approve applies the adjustment once. The decision is persisted
  /// before the state updates; a retry after a failed persist
  /// replays the apply as a duplicate (no second stock move, D111)
  /// and then persists the decision.
  Future<StockAdjustmentRequest?> approveAdjustment({
    required String requestId,
    String? note,
  }) async {
    await _ensureLoaded();
    final index = state.indexWhere((item) => item.id == requestId);
    if (index == -1) return null;
    final request = state[index];
    if (!request.isPending) return null;
    final approver = ref.read(authProvider);
    if (!canApproveAdjustment(approver: approver, request: request)) {
      return null;
    }
    try {
      final movement = await ref
          .read(productionDataLayerProvider)
          .adjustStock(
            batchId: request.batchId,
            deltaQty: request.deltaQty,
            reason: request.reason,
            actorId: approver!.uid,
            actorName: approver.name,
            idempotencyKey: 'stock-adjust-${request.id}',
          );
      final approved = request.copyWith(
        status: StockAdjustmentStatus.approved,
        decidedById: approver.uid,
        decidedByName: approver.name,
        decidedAt: DateTime.now(),
        decisionNote: note?.trim().isEmpty ?? true ? null : note!.trim(),
        movementId: movement.id,
      );
      await ref
          .read(productionDataLayerProvider)
          .updateAdjustmentRequest(approved);
      state = [
        for (var i = 0; i < state.length; i++)
          if (i == index) approved else state[i],
      ];
      ref.invalidate(inventoryProvider);
      ref.invalidate(syncStatusProvider);
      return approved;
    } on ArgumentError {
      return null;
    }
  }

  /// Rejects a pending request. Only an approver (same gate as
  /// approve — a role that may approve, other than the requester)
  /// may reject. The decision is persisted before the state
  /// updates. Returns the rejected request, or `null` when the
  /// request is not pending or the caller may not decide it.
  Future<StockAdjustmentRequest?> rejectAdjustment({
    required String requestId,
    String? note,
  }) async {
    await _ensureLoaded();
    final index = state.indexWhere((item) => item.id == requestId);
    if (index == -1) return null;
    final request = state[index];
    if (!request.isPending) return null;
    final approver = ref.read(authProvider);
    if (!canApproveAdjustment(approver: approver, request: request)) {
      return null;
    }
    final rejected = request.copyWith(
      status: StockAdjustmentStatus.rejected,
      decidedById: approver!.uid,
      decidedByName: approver.name,
      decidedAt: DateTime.now(),
      decisionNote: note?.trim().isEmpty ?? true ? null : note!.trim(),
    );
    await ref
        .read(productionDataLayerProvider)
        .updateAdjustmentRequest(rejected);
    state = [
      for (var i = 0; i < state.length; i++)
        if (i == index) rejected else state[i],
    ];
    return rejected;
  }
}
