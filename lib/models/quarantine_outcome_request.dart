import 'inventory_item.dart';
import 'model_utils.dart';

/// What happens to a quarantined batch (Week 5 Day 4, D154 — SRS
/// D-11 / FR-INV-07).
///
/// Quarantining (D140) only parks the batch out of the saleable
/// pool; the step that follows is decided here, with approval
/// (§5.2.4 — approver ≠ requester, same pattern as the adjustment
/// queue, D141):
///
/// - [returnToSupplier] — the batch goes back to the supplier; on
///   approval the batch becomes [BatchStatus.returned] with quantity
///   0 (the units leave the branch's stock).
/// - [dispose] — the batch is destroyed; on approval it becomes
///   [BatchStatus.disposed] and stays unsellable, its quantity kept
///   as the destroyed count (like an expired batch's quantity).
///
/// A request is filed with a reason; an approver approves or rejects
/// it, and approval applies the outcome through the production data
/// layer — status + quantity + audit + sync, exactly like the
/// quarantine transition itself (D140). The medicine name, batch
/// number and quantity are denormalized at request time: the queue
/// screen is a historical record, and the batch row may have moved
/// by the time a request is reviewed.
enum QuarantineOutcome { returnToSupplier, dispose }

String quarantineOutcomeLabel(QuarantineOutcome outcome) => switch (outcome) {
  QuarantineOutcome.returnToSupplier => 'Return to supplier',
  QuarantineOutcome.dispose => 'Dispose',
};

/// The batch status an approved outcome lands in.
BatchStatus quarantineOutcomeStatus(QuarantineOutcome outcome) =>
    switch (outcome) {
      QuarantineOutcome.returnToSupplier => BatchStatus.returned,
      QuarantineOutcome.dispose => BatchStatus.disposed,
    };

enum QuarantineOutcomeStatus { pending, approved, rejected }

class QuarantineOutcomeRequest {
  const QuarantineOutcomeRequest({
    required this.id,
    required this.batchId,
    required this.batchNo,
    required this.medicineId,
    required this.medicineName,
    required this.branchId,
    required this.outcome,
    required this.reason,
    required this.quantityAtRequest,
    required this.requesterId,
    required this.requesterName,
    required this.requestedAt,
    this.status = QuarantineOutcomeStatus.pending,
    this.decidedById,
    this.decidedByName,
    this.decidedAt,
    this.decisionNote,
  });

  /// Queue id (`qo-N`).
  final String id;

  final String batchId;

  /// Batch number at request time (denormalized).
  final String batchNo;

  final String medicineId;

  /// Medicine name at request time (denormalized).
  final String medicineName;

  final String branchId;

  /// What the requester wants done with the batch.
  final QuarantineOutcome outcome;

  /// Required reason — shown to the approver, written to the audit
  /// entry on approval.
  final String reason;

  /// Batch quantity at request time (denormalized — the disposed /
  /// returned count the approver is deciding on).
  final int quantityAtRequest;

  final String requesterId;
  final String requesterName;
  final DateTime requestedAt;

  final QuarantineOutcomeStatus status;

  final String? decidedById;
  final String? decidedByName;
  final DateTime? decidedAt;

  /// Approver's note on reject (optional on approve).
  final String? decisionNote;

  bool get isPending => status == QuarantineOutcomeStatus.pending;

  Map<String, dynamic> toMap() {
    return {
      'batchId': batchId,
      'batchNo': batchNo,
      'medicineId': medicineId,
      'medicineName': medicineName,
      'branchId': branchId,
      'outcome': outcome.name,
      'reason': reason,
      'quantityAtRequest': quantityAtRequest,
      'requesterId': requesterId,
      'requesterName': requesterName,
      'requestedAt': dateToMap(requestedAt),
      'status': status.name,
      'decidedById': decidedById,
      'decidedByName': decidedByName,
      'decidedAt': dateToMap(decidedAt),
      'decisionNote': decisionNote,
    };
  }

  factory QuarantineOutcomeRequest.fromMap(
    String id,
    Map<String, dynamic> map,
  ) {
    return QuarantineOutcomeRequest(
      id: id,
      batchId: map['batchId'] as String? ?? '',
      batchNo: map['batchNo'] as String? ?? '',
      medicineId: map['medicineId'] as String? ?? '',
      medicineName: map['medicineName'] as String? ?? '',
      branchId: map['branchId'] as String? ?? '',
      outcome: QuarantineOutcome.values.firstWhere(
        (o) => o.name == map['outcome'],
        orElse: () => QuarantineOutcome.dispose,
      ),
      reason: map['reason'] as String? ?? '',
      quantityAtRequest: (map['quantityAtRequest'] as num?)?.toInt() ?? 0,
      requesterId: map['requesterId'] as String? ?? '',
      requesterName: map['requesterName'] as String? ?? '',
      requestedAt: parseDate(map['requestedAt']) ?? DateTime.now(),
      status: QuarantineOutcomeStatus.values.firstWhere(
        (s) => s.name == map['status'],
        orElse: () => QuarantineOutcomeStatus.pending,
      ),
      decidedById: map['decidedById'] as String?,
      decidedByName: map['decidedByName'] as String?,
      decidedAt: parseDate(map['decidedAt']),
      decisionNote: map['decisionNote'] as String?,
    );
  }

  QuarantineOutcomeRequest copyWith({
    QuarantineOutcomeStatus? status,
    String? decidedById,
    String? decidedByName,
    DateTime? decidedAt,
    String? decisionNote,
  }) {
    return QuarantineOutcomeRequest(
      id: id,
      batchId: batchId,
      batchNo: batchNo,
      medicineId: medicineId,
      medicineName: medicineName,
      branchId: branchId,
      outcome: outcome,
      reason: reason,
      quantityAtRequest: quantityAtRequest,
      requesterId: requesterId,
      requesterName: requesterName,
      requestedAt: requestedAt,
      status: status ?? this.status,
      decidedById: decidedById ?? this.decidedById,
      decidedByName: decidedByName ?? this.decidedByName,
      decidedAt: decidedAt ?? this.decidedAt,
      decisionNote: decisionNote ?? this.decisionNote,
    );
  }
}
