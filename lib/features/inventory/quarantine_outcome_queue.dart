import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/data/production_data_layer.dart';
import '../../core/widgets/sync_status_widget.dart';
import '../../models/inventory_item.dart';
import '../../models/quarantine_outcome_request.dart';
import '../authentication/auth_state.dart';
import 'inventory_provider.dart';
import 'quarantine_outcome_logic.dart';

/// The quarantine return / disposal approval queue (Week 5 Day 4,
/// D154 — SRS D-11 / FR-INV-07, §5.2.4; D141 pattern; persisted
/// Week 7 Day 1, D171).
///
/// Requests are filed through the production data layer
/// ([ProductionDataLayer.fileQuarantineOutcomeRequest]) and stored
/// under `branches/{branchId}/quarantineOutcomes/{id}` (mock now,
/// Firestore when the bundle switches), so a request survives a
/// notifier rebuild and an app restart. The notifier re-reads the
/// persisted requests on start ([refresh], kicked off from [build])
/// and resumes the `qo-N` sequence past them, so a re-filed id can
/// never collide with a persisted one.
///
/// Flow: the Return / Dispose dialog on a quarantined batch row
/// files a request ([requestOutcome]); an approver (a role the §5.1
/// matrix allows to approve adjustments, other than the requester)
/// approves ([approveOutcome]) or rejects ([rejectOutcome]).
/// Approval applies the outcome through the layer — status (+
/// quantity 0 on a return) + audit + sync, exactly like the
/// quarantine transition itself (D140) — and the batch row updates
/// at once. A rejected batch stays quarantined. The decision is
/// persisted to the same document before the state updates, so the
/// persisted queue never lags the screen.
final quarantineOutcomeQueueProvider =
    NotifierProvider<
      QuarantineOutcomeQueueNotifier,
      List<QuarantineOutcomeRequest>
    >(QuarantineOutcomeQueueNotifier.new);

class QuarantineOutcomeQueueNotifier
    extends Notifier<List<QuarantineOutcomeRequest>> {
  int _sequence = 0;

  /// The in-flight initial load, started by [build]: mutating
  /// methods await it before minting an id or deciding a request,
  /// so they always see the persisted queue first.
  Future<void>? _loadFuture;

  @override
  List<QuarantineOutcomeRequest> build() {
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
  /// persisted `qo-N` id.
  Future<void> refresh() async {
    final persisted = await ref
        .read(productionDataLayerProvider)
        .loadQuarantineOutcomeRequests();
    final mergedById = <String, QuarantineOutcomeRequest>{
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
      final match = RegExp(r'^qo-(\d+)$').firstMatch(request.id);
      if (match != null) {
        final number = int.tryParse(match.group(1) ?? '') ?? 0;
        if (number > _sequence) _sequence = number;
      }
    }
  }

  /// Files a new return / disposal request for a quarantined batch.
  /// Persists it through the layer first, then adds it to the
  /// state. Returns the request, or `null` when the requester is
  /// signed out or the reason is missing.
  Future<QuarantineOutcomeRequest?> requestOutcome({
    required InventoryItem batch,
    required String medicineName,
    required QuarantineOutcome outcome,
    required String reason,
  }) async {
    await _ensureLoaded();
    final requester = ref.read(authProvider);
    if (requester == null) return null;
    final error = validateQuarantineOutcomeRequest(reason: reason);
    if (error != null) return null;
    _sequence++;
    final request = QuarantineOutcomeRequest(
      id: 'qo-$_sequence',
      batchId: batch.id,
      batchNo: batch.batchNo ?? '—',
      medicineId: batch.medicineId,
      medicineName: medicineName,
      branchId: batch.branchId,
      outcome: outcome,
      reason: reason.trim(),
      quantityAtRequest: batch.quantity,
      requesterId: requester.uid,
      requesterName: requester.name,
      requestedAt: DateTime.now(),
    );
    final saved = await ref
        .read(productionDataLayerProvider)
        .fileQuarantineOutcomeRequest(request);
    state = [...state, saved];
    return saved;
  }

  /// Approves a pending request and applies it through the layer.
  /// Returns the approved request, or `null` when the request is
  /// not pending, the caller may not approve it (wrong role, or the
  /// requester themself — §5.2.4), or the layer rejects the apply
  /// (e.g. the batch is no longer quarantined — the request stays
  /// pending, and the approver can try again or reject it; or the
  /// branch was deactivated — FR-HO-08, D149/D161, same refusal).
  ///
  /// The idempotency key is the request id, so a double-tap on
  /// Approve applies the outcome once. The decision is persisted
  /// before the state updates; a retry after a failed persist
  /// replays the apply as a duplicate (no second stock move, D171 —
  /// the batch row is already in the target status) and then
  /// persists the decision.
  Future<QuarantineOutcomeRequest?> approveOutcome({
    required String requestId,
    String? note,
  }) async {
    await _ensureLoaded();
    final index = state.indexWhere((item) => item.id == requestId);
    if (index == -1) return null;
    final request = state[index];
    if (!request.isPending) return null;
    final approver = ref.read(authProvider);
    if (!canApproveQuarantineOutcome(approver: approver, request: request)) {
      return null;
    }
    try {
      await ref
          .read(productionDataLayerProvider)
          .applyQuarantineOutcome(
            batchId: request.batchId,
            outcome: request.outcome,
            reason: request.reason,
            actorId: approver!.uid,
            actorName: approver.name,
            idempotencyKey: 'quarantine-outcome-${request.id}',
          );
      final approved = request.copyWith(
        status: QuarantineOutcomeStatus.approved,
        decidedById: approver.uid,
        decidedByName: approver.name,
        decidedAt: DateTime.now(),
        decisionNote: note?.trim().isEmpty ?? true ? null : note!.trim(),
      );
      await ref
          .read(productionDataLayerProvider)
          .updateQuarantineOutcomeRequest(approved);
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
  /// may reject. The batch stays quarantined. The decision is
  /// persisted before the state updates. Returns the rejected
  /// request, or `null` when the request is not pending or the
  /// caller may not decide it.
  Future<QuarantineOutcomeRequest?> rejectOutcome({
    required String requestId,
    String? note,
  }) async {
    await _ensureLoaded();
    final index = state.indexWhere((item) => item.id == requestId);
    if (index == -1) return null;
    final request = state[index];
    if (!request.isPending) return null;
    final approver = ref.read(authProvider);
    if (!canApproveQuarantineOutcome(approver: approver, request: request)) {
      return null;
    }
    final rejected = request.copyWith(
      status: QuarantineOutcomeStatus.rejected,
      decidedById: approver!.uid,
      decidedByName: approver.name,
      decidedAt: DateTime.now(),
      decisionNote: note?.trim().isEmpty ?? true ? null : note!.trim(),
    );
    await ref
        .read(productionDataLayerProvider)
        .updateQuarantineOutcomeRequest(rejected);
    state = [
      for (var i = 0; i < state.length; i++)
        if (i == index) rejected else state[i],
    ];
    return rejected;
  }
}
