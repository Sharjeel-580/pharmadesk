/// A stock-adjustment request (Week 4 Day 5, D141 — SRS D-14 /
/// FR-INV-08, §5.2.4).
///
/// Adjustments no longer apply directly from the dialog: a request
/// is filed with a reason, an approver (a role the SRS §5.1 matrix
/// allows to approve, other than the requester) approves or rejects
/// it, and approval applies the adjustment through the layer —
/// ledger + audit + sync, exactly like the old direct adjust. The
/// queue is session-only (D131 pattern): requests are not persisted
/// to Firestore yet — that is a follow-up, recorded in D141.
///
/// The medicine name and batch number are denormalized at request
/// time: the queue screen is a historical record, and the batch row
/// may be gone by the time a request is reviewed.
enum StockAdjustmentStatus { pending, approved, rejected }

class StockAdjustmentRequest {
  const StockAdjustmentRequest({
    required this.id,
    required this.batchId,
    required this.batchNo,
    required this.medicineId,
    required this.medicineName,
    required this.branchId,
    required this.deltaQty,
    required this.reason,
    required this.requesterId,
    required this.requesterName,
    required this.requestedAt,
    this.status = StockAdjustmentStatus.pending,
    this.decidedById,
    this.decidedByName,
    this.decidedAt,
    this.decisionNote,
    this.movementId,
  });

  /// Queue id (`adj-N`).
  final String id;

  final String batchId;

  /// Batch number at request time (denormalized).
  final String batchNo;

  final String medicineId;

  /// Medicine name at request time (denormalized).
  final String medicineName;

  final String branchId;

  /// Signed quantity change: positive = add, negative = remove.
  final int deltaQty;

  /// Required reason — shown to the approver, written to the audit
  /// entry on approval.
  final String reason;

  final String requesterId;
  final String requesterName;
  final DateTime requestedAt;

  final StockAdjustmentStatus status;

  final String? decidedById;
  final String? decidedByName;
  final DateTime? decidedAt;

  /// Approver's note on reject (optional on approve).
  final String? decisionNote;

  /// Ledger movement id once approved (the applied adjustment).
  final String? movementId;

  bool get isPending => status == StockAdjustmentStatus.pending;

  StockAdjustmentRequest copyWith({
    StockAdjustmentStatus? status,
    String? decidedById,
    String? decidedByName,
    DateTime? decidedAt,
    String? decisionNote,
    String? movementId,
  }) {
    return StockAdjustmentRequest(
      id: id,
      batchId: batchId,
      batchNo: batchNo,
      medicineId: medicineId,
      medicineName: medicineName,
      branchId: branchId,
      deltaQty: deltaQty,
      reason: reason,
      requesterId: requesterId,
      requesterName: requesterName,
      requestedAt: requestedAt,
      status: status ?? this.status,
      decidedById: decidedById ?? this.decidedById,
      decidedByName: decidedByName ?? this.decidedByName,
      decidedAt: decidedAt ?? this.decidedAt,
      decisionNote: decisionNote ?? this.decisionNote,
      movementId: movementId ?? this.movementId,
    );
  }
}
