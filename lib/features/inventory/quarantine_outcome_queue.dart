import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/data/production_data_layer.dart';
import '../../core/widgets/sync_status_widget.dart';
import '../../models/inventory_item.dart';
import '../../models/quarantine_outcome_request.dart';
import '../authentication/auth_state.dart';
import 'inventory_provider.dart';
import 'quarantine_outcome_logic.dart';

/// The quarantine return / disposal approval queue (Week 5 Day 4,
/// D154 — SRS D-11 / FR-INV-07, §5.2.4; D141 pattern).
///
/// Flow: the Return / Dispose dialog on a quarantined batch row
/// files a request ([requestOutcome]); an approver (a role the §5.1
/// matrix allows to approve adjustments, other than the requester)
/// approves ([approveOutcome]) or rejects ([rejectOutcome]).
/// Approval applies the outcome through the layer — status (+
/// quantity 0 on a return) + audit + sync, exactly like the
/// quarantine transition itself (D140) — and the batch row updates
/// at once. A rejected batch stays quarantined.
///
/// The queue is session-only, like the adjustment queue was at
/// D141: Firestore persistence (`branches/{branchId}/
/// quarantineOutcomes`, D146 pattern) is a follow-up, not smuggled
/// into this day. The outcome itself IS persisted — the batch row
/// carries the outcome status, so a decided batch survives a
/// restart even though the queue entry does not.
final quarantineOutcomeQueueProvider =
    NotifierProvider<
      QuarantineOutcomeQueueNotifier,
      List<QuarantineOutcomeRequest>
    >(QuarantineOutcomeQueueNotifier.new);

class QuarantineOutcomeQueueNotifier
    extends Notifier<List<QuarantineOutcomeRequest>> {
  int _sequence = 0;

  @override
  List<QuarantineOutcomeRequest> build() => const [];

  /// Files a new return / disposal request for a quarantined batch.
  /// Returns the request, or `null` when the requester is signed
  /// out or the reason is missing.
  QuarantineOutcomeRequest? requestOutcome({
    required InventoryItem batch,
    required String medicineName,
    required QuarantineOutcome outcome,
    required String reason,
  }) {
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
    state = [...state, request];
    return request;
  }

  /// Approves a pending request and applies it through the layer.
  /// Returns the approved request, or `null` when the request is
  /// not pending, the caller may not approve it (wrong role, or the
  /// requester themself — §5.2.4), or the layer rejects the apply
  /// (e.g. the batch is no longer quarantined — the request stays
  /// pending, and the approver can try again or reject it).
  ///
  /// The idempotency key is the request id, so a double-tap on
  /// Approve applies the outcome once.
  Future<QuarantineOutcomeRequest?> approveOutcome({
    required String requestId,
    String? note,
  }) async {
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
  /// may reject. The batch stays quarantined. Returns the rejected
  /// request, or `null` when the request is not pending or the
  /// caller may not decide it.
  QuarantineOutcomeRequest? rejectOutcome({
    required String requestId,
    String? note,
  }) {
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
    state = [
      for (var i = 0; i < state.length; i++)
        if (i == index) rejected else state[i],
    ];
    return rejected;
  }
}
