import '../../core/data/auth_repository.dart';
import '../../core/data/permission_service.dart';
import '../../models/quarantine_outcome_request.dart';

/// Quarantine return / disposal approval rules (Week 5 Day 4, D154
/// — SRS D-11 / FR-INV-07, §5.2.4). Pure functions, tested without
/// widgets. Same separation-of-duties pattern as the adjustment
/// queue (D141):
///
/// - **Request:** a reason is required (the approver decides on the
///   reason + the quantity at request time). Filing is gated on the
///   existing `stockReceive` write — the same gate as the quarantine
///   buttons themselves (D140); no new capability is invented.
/// - **Approve / reject:** the approver must hold
///   `stockAdjustApprove` in the request's branch AND must not be
///   the requester (§5.2.4). A `null` (signed-out) user can do
///   neither.

/// Validates a new quarantine-outcome request. Returns the error
/// message, or `null` when the request is valid.
String? validateQuarantineOutcomeRequest({required String reason}) {
  if (reason.trim().isEmpty) {
    return 'A reason is required (e.g. damaged beyond use, supplier agreed to take it back).';
  }
  return null;
}

/// True when [approver] may decide [request]: holds
/// `stockAdjustApprove` in the request's branch and is not the
/// requester. The same check gates the Approve / Reject buttons on
/// the queue screen.
bool canApproveQuarantineOutcome({
  required AppUser? approver,
  required QuarantineOutcomeRequest request,
}) {
  if (approver == null) return false;
  if (approver.uid == request.requesterId) return false;
  return permissionService.canWrite(
    approver,
    'stockAdjustApprove',
    request.branchId,
  );
}

/// True when [user] may open the quarantine-outcomes queue in
/// [branchId]: anyone who may request an adjustment (the queue
/// route is gated on `stockAdjustReq`, like the adjustment queue —
/// all approvers are also requesters, per the §5.1 matrix).
bool canViewQuarantineOutcomeQueue(AppUser? user, String branchId) =>
    permissionService.canInBranch(user, 'stockAdjustReq', branchId);
