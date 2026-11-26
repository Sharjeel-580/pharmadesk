import '../../core/data/auth_repository.dart';
import '../../core/data/permission_service.dart';
import '../../core/services/branch_context.dart';
import '../../core/widgets/badges.dart';
import '../../models/stock_transfer.dart';

/// Stock transfer logic (Week 4 Day 2, D118) — pure functions, no
/// widgets, no providers, so they are unit-testable without pumping
/// anything. The production data layer re-checks the rules it owns
/// (status order, approval separation, stock at dispatch); these
/// helpers are the UI's gates + validators, following the
/// `salary_logic.dart` (D102/D112) pattern.

/// True when [user] may view the transfer screens in [branchId]
/// (SRS §5.1 `stockTransfer`: Owner / HO Admin / Regional Mgr,
/// Branch Mgr + Inventory Mgr in their own branch, Auditor
/// read-only — everyone else none).
bool canViewTransfers(AppUser? user, String branchId) =>
    permissionService.canInBranch(user, 'stockTransfer', branchId);

/// True when [user] may change a transfer in [branchId] (request,
/// approve, dispatch, receive — `readOnly` is false here, so the
/// Auditor sees the screens but no action buttons).
bool canWriteTransfer(AppUser? user, String branchId) =>
    permissionService.canWrite(user, 'stockTransfer', branchId);

/// True when [user] may request a transfer out of [branchId].
bool canRequestTransfer(AppUser? user, String branchId) =>
    canWriteTransfer(user, branchId);

/// True when [user] may approve / reject / dispatch / receive a
/// transfer touching [branchId] — the same capability as requesting
/// (the SRS names no separate dispatch/receive row); the layer adds
/// the status-order and approval-separation checks.
bool canDecideTransfer(AppUser? user, String branchId) =>
    canWriteTransfer(user, branchId);

/// Branch display name for a branch id (`Demo Branch — DHA`).
String branchDisplayName(String branchId) {
  for (final branch in demoBranches) {
    if (branch.id == branchId) return branch.name;
  }
  return branchId;
}

/// Badge kind for a transfer status.
StatusKind transferStatusKind(StockTransferStatus status) => switch (status) {
  StockTransferStatus.requested => StatusKind.warning,
  StockTransferStatus.approved => StatusKind.info,
  StockTransferStatus.dispatched => StatusKind.info,
  StockTransferStatus.received => StatusKind.success,
  StockTransferStatus.rejected => StatusKind.danger,
  StockTransferStatus.cancelled => StatusKind.neutral,
};

/// Validates a transfer request before it reaches the layer.
/// Returns the first problem, or `null` when the request is valid.
String? validateTransferRequest({
  required String? fromBranchId,
  required String? toBranchId,
  required List<TransferItem> items,
}) {
  if (fromBranchId == null || fromBranchId.isEmpty) {
    return 'Choose the source branch.';
  }
  if (toBranchId == null || toBranchId.isEmpty) {
    return 'Choose the destination branch.';
  }
  if (fromBranchId == toBranchId) {
    return 'Source and destination must be different branches.';
  }
  if (items.isEmpty) {
    return 'Add at least one medicine to transfer.';
  }
  for (final item in items) {
    if (item.quantity <= 0) {
      return 'Quantity for ${item.medicineName} must be above zero.';
    }
  }
  return null;
}
