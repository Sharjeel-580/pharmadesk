import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/data/production_data_layer.dart';
import '../../core/widgets/sync_status_widget.dart';
import '../../models/stock_adjustment_request.dart';
import '../authentication/auth_state.dart';
import 'inventory_provider.dart';
import 'stock_adjustment_logic.dart';

/// The stock-adjustment approval queue (Week 4 Day 5, D141 — SRS
/// D-14 / FR-INV-08, §5.2.4).
///
/// Session-only in-memory queue (D131 pattern): requests live for
/// the app session and are not persisted to Firestore yet — that is
/// a follow-up, recorded in D141.
///
/// Flow: the Adjust dialog files a request ([requestAdjustment]);
/// an approver (a role the §5.1 matrix allows to approve, other
/// than the requester) approves ([approveAdjustment]) or rejects
/// ([rejectAdjustment]). Approval applies the adjustment through
/// the layer — ledger + audit + sync, exactly like the old direct
/// adjust — and records the ledger movement id on the request.
final stockAdjustmentQueueProvider =
    NotifierProvider<StockAdjustmentQueueNotifier, List<StockAdjustmentRequest>>(
      StockAdjustmentQueueNotifier.new,
    );

class StockAdjustmentQueueNotifier
    extends Notifier<List<StockAdjustmentRequest>> {
  int _sequence = 0;

  @override
  List<StockAdjustmentRequest> build() => const [];

  /// Files a new adjustment request. Returns the request, or `null`
  /// when the requester is signed out or the request is invalid
  /// (zero quantity, missing reason, decrease above [onHandQty]).
  StockAdjustmentRequest? requestAdjustment({
    required String batchId,
    required String batchNo,
    required String medicineId,
    required String medicineName,
    required String branchId,
    required int deltaQty,
    required String reason,
    required int onHandQty,
  }) {
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
    state = [...state, request];
    return request;
  }

  /// Approves a pending request and applies it through the layer.
  /// Returns the approved request, or `null` when the request is
  /// not pending, the caller may not approve it (wrong role, or the
  /// requester themself — §5.2.4), or the layer rejects the apply
  /// (e.g. stock moved since the request was filed — the request
  /// stays pending, and the approver can try again or reject it).
  ///
  /// The idempotency key is the request id, so a double-tap on
  /// Approve applies the adjustment once.
  Future<StockAdjustmentRequest?> approveAdjustment({
    required String requestId,
    String? note,
  }) async {
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
  /// may reject. Returns the rejected request, or `null` when the
  /// request is not pending or the caller may not decide it.
  StockAdjustmentRequest? rejectAdjustment({
    required String requestId,
    String? note,
  }) {
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
    state = [
      for (var i = 0; i < state.length; i++)
        if (i == index) rejected else state[i],
    ];
    return rejected;
  }
}
