import '../../core/data/auth_repository.dart';
import '../../core/data/permission_service.dart';
import '../../models/stock_adjustment_request.dart';

/// Adjustment-approval rules (Week 4 Day 5, D141 — SRS D-14 /
/// FR-INV-08, §5.1, §5.2.4). Pure functions, tested without widgets.
///
/// - **Request:** the quantity change must be non-zero, a reason is
///   required, and a decrease may not exceed the on-hand quantity
///   at request time (the layer re-validates at approval time —
///   stock may have moved since the request was filed).
/// - **Approve:** the approver must hold `stockAdjustApprove` in
///   the request's branch AND must not be the requester (§5.2.4
///   separation of duties, on by default). A `null` (signed-out)
///   user can do neither.

/// Validates a new adjustment request. Returns the error message, or
/// `null` when the request is valid. [onHandQty] is the batch's
/// quantity at request time.
String? validateAdjustmentRequest({
  required int deltaQty,
  required String reason,
  required int onHandQty,
}) {
  if (deltaQty == 0) {
    return 'Quantity must be above zero.';
  }
  if (reason.trim().isEmpty) {
    return 'A reason is required (e.g. damaged, found, expired).';
  }
  if (deltaQty < 0 && -deltaQty > onHandQty) {
    return 'Cannot remove ${-deltaQty} units — only $onHandQty on hand.';
  }
  return null;
}

/// True when [approver] may decide [request]: holds
/// `stockAdjustApprove` in the request's branch and is not the
/// requester. The same check gates the Approve / Reject buttons on
/// the queue screen.
bool canApproveAdjustment({
  required AppUser? approver,
  required StockAdjustmentRequest request,
}) {
  if (approver == null) return false;
  if (approver.uid == request.requesterId) return false;
  return permissionService.canWrite(
    approver,
    'stockAdjustApprove',
    request.branchId,
  );
}

/// True when [user] may open the adjustment queue in [branchId]:
/// anyone who may request an adjustment (all approvers are also
/// requesters, per the §5.1 matrix — so the queue route is gated
/// on `stockAdjustReq`, not on the approve capability).
bool canViewAdjustmentQueue(AppUser? user, String branchId) =>
    permissionService.canInBranch(user, 'stockAdjustReq', branchId);
