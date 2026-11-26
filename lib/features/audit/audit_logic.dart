import '../../core/data/audit_log.dart';
import '../../core/data/auth_repository.dart';
import '../../core/data/permission_service.dart';
import '../settings/roles_permissions.dart';

/// Audit Log logic (Week 4 Day 4, D132 — SRS D-33, FR-SYS-04).
///
/// Pure functions, no widgets, no providers, so they are
/// unit-testable without pumping anything. The viewer reads the SAME
/// store the writer writes: `ProductionDataLayer.auditEntries`
/// (in-memory `InMemoryAuditLogWriter` until the Firebase project
/// exists — the Firestore implementation writes the same shape to
/// the root `auditLogs` collection). There is no second audit
/// implementation anywhere in this feature.

/// True when [user] may view the audit log in [branchId]
/// (SRS §5.1 `auditLog`: Super Admin / Owner / HO Admin, Branch
/// Mgr in their own branch, Auditor read-only — everyone else none).
bool canViewAuditLog(AppUser? user, String branchId) =>
    permissionService.canInBranch(user, 'auditLog', branchId);

/// The audit entries [user] may see, by branch scope (SRS §5.1):
/// - `allowed` / `readOnly` (Super Admin, Owner, HO Admin,
///   Auditor): every branch.
/// - `own` (Branch Manager): only entries in the user's own
///   branches.
/// - `none` (everyone else): nothing — the route gate already
///   blocks them, but the filter never leaks through either.
/// A signed-out user (`null`) sees everything: the router's auth
/// redirect is the signed-out guard.
List<AuditLogEntry> auditVisibleEntries(
  List<AuditLogEntry> entries,
  AppUser? user,
) {
  final permission = permissionService.permissionFor(user, 'auditLog');
  return switch (permission) {
    RolePermission.none => const [],
    RolePermission.own =>
      user == null
          ? entries
          : entries
              .where((entry) => user.branchIds.contains(entry.branchId))
              .toList(),
    RolePermission.allowed || RolePermission.readOnly => entries,
  };
}

/// Filters [entries] by branch, actor, action and date range.
/// - [branchId]: exact branch match (null = all branches in scope).
/// - [actorName]: exact actor match (null = all actors).
/// - [actionPrefix]: matches the action family, e.g. `sale` matches
///   `sale.committed` and `sale.duplicate_skipped` (null = all).
/// - [from] / [to]: inclusive date bounds on `createdAt` (null =
///   unbounded). Entries with no timestamp are kept only when both
///   bounds are absent.
/// Results are newest first.
List<AuditLogEntry> filterAuditEntries(
  List<AuditLogEntry> entries, {
  String? branchId,
  String? actorName,
  String? actionPrefix,
  DateTime? from,
  DateTime? to,
}) {
  final filtered = entries.where((entry) {
    if (branchId != null && entry.branchId != branchId) return false;
    if (actorName != null && entry.actorName != actorName) return false;
    if (actionPrefix != null &&
        !(entry.action == actionPrefix ||
            entry.action.startsWith('$actionPrefix.'))) {
      return false;
    }
    final createdAt = entry.createdAt;
    if (createdAt == null) return from == null && to == null;
    if (from != null && createdAt.isBefore(from)) return false;
    if (to != null && createdAt.isAfter(to)) return false;
    return true;
  }).toList();
  filtered.sort((a, b) {
    final aAt = a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    final bAt = b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    return bAt.compareTo(aAt);
  });
  return filtered;
}

/// Distinct action families present in [entries], in first-seen
/// order (the action-type filter options).
List<String> auditActionFamilies(List<AuditLogEntry> entries) {
  final seen = <String>[];
  for (final entry in entries) {
    final family = entry.action.split('.').first;
    if (!seen.contains(family)) seen.add(family);
  }
  return seen;
}

/// Distinct actor names present in [entries], in first-seen order.
List<String> auditActors(List<AuditLogEntry> entries) {
  final seen = <String>[];
  for (final entry in entries) {
    if (!seen.contains(entry.actorName)) seen.add(entry.actorName);
  }
  return seen;
}
