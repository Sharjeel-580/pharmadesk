import '../../features/settings/roles_permissions.dart';
import 'auth_repository.dart';

/// In-app permission service (Week 2 Day 3, SRS §5.1 — D70).
///
/// Wires the §5.1 roles × capabilities matrix
/// (`roles_permissions.dart`, previously display-only — D49) into
/// checks the UI consults: [FeatureGate] (route entry) and screens
/// (action buttons, navigation). This is the **UX layer only** —
/// defense in depth. The authority stays with Firestore security
/// rules + custom claims (`firebase/firestore.rules`): a user the UI
/// lets through is still stopped server-side, and a user the UI
/// blocks loses nothing server-side.
///
/// Matrix semantics (per `rolePermissionMatrix`):
///
/// - [RolePermission.allowed] — the role may do this in any branch of
///   its org (the claims list the branches; writes still need the
///   branch in `branchIds`, per the rules' `inBranchForWrite`).
/// - [RolePermission.own] — only in the user's own branches
///   (`branchIds` claim). Outside them the action is denied.
/// - [RolePermission.readOnly] — may view, never write. `can` returns
///   true (viewing is allowed); `canWrite` returns false.
/// - [RolePermission.none] — denied everywhere.
///
/// A signed-out user (`null`) is **allowed by every check**: the
/// router's auth redirect is the signed-out guard, and router-only
/// tests pump the app unsigned. The permission service never decides
/// whether anyone is signed in — only what a signed-in user may do.
class PermissionService {
  const PermissionService();

  /// The matrix permission for [user] on [capabilityKey], or
  /// [RolePermission.none] for unknown roles / capabilities.
  RolePermission permissionFor(AppUser? user, String capabilityKey) {
    if (user == null) return RolePermission.allowed;
    final index = demoRoles.indexOf(roleDisplayName(user.roleKey));
    if (index == -1) return RolePermission.none;
    return rolePermissionMatrix[capabilityKey]?[index] ?? RolePermission.none;
  }

  /// True when [user] may use [capabilityKey] at all (viewing counts:
  /// `readOnly` is allowed here — use [canWrite] for mutations).
  bool can(AppUser? user, String capabilityKey) =>
      permissionFor(user, capabilityKey) != RolePermission.none;

  /// True when [user] may use [capabilityKey] in [branchId].
  /// `allowed` / `readOnly` span the whole org; `own` requires the
  /// branch in the user's `branchIds`.
  bool canInBranch(AppUser? user, String capabilityKey, String branchId) {
    final permission = permissionFor(user, capabilityKey);
    return switch (permission) {
      RolePermission.none => false,
      RolePermission.own => user != null && user.branchIds.contains(branchId),
      RolePermission.allowed || RolePermission.readOnly => true,
    };
  }

  /// True when [user] may *change* something under [capabilityKey]
  /// in [branchId] (mutations only — `readOnly` is false here).
  bool canWrite(AppUser? user, String capabilityKey, String branchId) {
    final permission = permissionFor(user, capabilityKey);
    return switch (permission) {
      RolePermission.allowed => true,
      RolePermission.own => user != null && user.branchIds.contains(branchId),
      RolePermission.readOnly || RolePermission.none => false,
    };
  }

  /// True when [user] may only read under [capabilityKey].
  bool isReadOnly(AppUser? user, String capabilityKey) =>
      permissionFor(user, capabilityKey) == RolePermission.readOnly;
}

/// The capability a route's entry is gated on, or `null` when the
/// route is not capability-gated.
///
/// Only routes whose entry IS the capability are gated. The matrix
/// governs *actions*, not module viewing, so most modules stay open
/// at route level and gate their write actions in-screen instead:
///
/// - `/prescriptions` is NOT gated on `rxReview`: the Owner (matrix
///   `none` on review) must still view the prescription queue — only
///   the Approve / Reject actions are gated (prescription detail
///   screen). Gating the route would also break the Day 2 Owner
///   navigation test.
/// - `/inventory` and `/orders` are NOT gated: viewing stock / the
///   order queue is not a matrix capability (Cashier has `none` on
///   `stockReceive` yet must run Stock Check — Day 3 test). Their
///   write actions (`stockAdjustApprove`, `poManage`, …) are the
///   gated capabilities.
/// - `/notifications` and `/dashboard` are NOT gated: no matrix
///   capability governs viewing them.
String? routeCapability(String route) {
  for (final entry in _routeCapabilities.entries) {
    if (route == entry.key || route.startsWith('${entry.key}/')) {
      return entry.value;
    }
  }
  return null;
}

/// Route → capability, in longest-prefix-first order (so
/// `/purchases/auto` matches `/purchases`, not a shorter prefix).
const _routeCapabilities = <String, String>{
  '/billing': 'posSell',
  '/medicines': 'medicineCrud',
  '/customers': 'khata',
  '/suppliers': 'supplierPay',
  '/purchases': 'poManage',
  '/reports': 'reports',
};

/// The permission service for the app (pure — no state).
const permissionService = PermissionService();
