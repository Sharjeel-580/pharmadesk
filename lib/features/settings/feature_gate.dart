import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/data/auth_repository.dart';
import '../../core/data/permission_service.dart';
import '../../core/services/branch_context.dart';
import '../../core/widgets/design_system.dart';
import '../authentication/auth_state.dart';
import 'feature_config.dart';

/// Guards a module route behind its feature flag (SRS FR-SYS-05) and,
/// since Week 2 Day 3 (D70), behind the SRS §5.1 capability for the
/// route ([routeCapability]).
///
/// When the module for [route] is enabled AND the signed-in user may
/// use its capability in the active branch, the [child] renders
/// unchanged. A disabled module shows the "module disabled" state; a
/// module the user has no permission for shows the "no permission"
/// state instead — with working actions to go back (Dashboard).
/// Routes that are not toggleable modules (dashboard, settings,
/// profile, auth, unknown) render their child — EXCEPT when the route
/// carries a capability ([routeCapability] returns non-`null`): since
/// Week 4 Day 4 (D135) those routes are capability-gated too, so the
/// system-hub screens (`/branches`, `/audit-log`, `/backup`) — which
/// are sub-screens of Settings, not modules of their own — still stop
/// a role the §5.1 matrix excludes. Routes with no capability mapping
/// are gated on the feature flag only.
///
/// A signed-out user (`null`) is never permission-blocked here: the
/// router's auth redirect is the signed-out guard, and the permission
/// service is a UX layer for signed-in users (see
/// `permission_service.dart`). Firestore security rules remain the
/// authority — this gate only decides what the UI shows.
class FeatureGate extends ConsumerWidget {
  const FeatureGate({super.key, required this.route, required this.child});

  final String route;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final module = featureModuleForRoute(route);
    final capability = routeCapability(route);
    if (module == null) {
      // Not a toggleable module: no feature flag applies, but a
      // capability mapping still gates the route (D135).
      if (capability == null) return child;
      final user = ref.watch(authProvider);
      if (user != null) {
        final branchId = ref.watch(activeBranchProvider).id;
        if (!permissionService.canInBranch(user, capability, branchId)) {
          return _NoPermissionScreen(
            title: _titleForRoute(route),
            subtitle: _subtitleForRoute(route),
            capability: capability,
            user: user,
          );
        }
      }
      return child;
    }
    final enabled = ref.watch(featureConfigProvider).contains(module.key);
    if (!enabled) return _ModuleDisabledScreen(module: module);
    if (capability != null) {
      final user = ref.watch(authProvider);
      if (user != null) {
        final branchId = ref.watch(activeBranchProvider).id;
        if (!permissionService.canInBranch(user, capability, branchId)) {
          return _NoPermissionScreen(
            title: module.title,
            subtitle: module.description,
            capability: capability,
            user: user,
          );
        }
      }
    }
    return child;
  }
}

/// Display title for a non-module gated route (D135). Prefix-aware:
/// `/branches/:id` is still Branch Management.
String _titleForRoute(String route) {
  if (route == '/branches' || route.startsWith('/branches/')) {
    return 'Branch Management';
  }
  if (route == '/finance/franchise') {
    return 'Franchise Royalties';
  }
  if (route == '/audit-log' || route.startsWith('/audit-log/')) {
    return 'Audit Log';
  }
  if (route == '/backup' || route.startsWith('/backup/')) {
    return 'Backup & Restore';
  }
  if (route == '/inventory/adjustments' ||
      route.startsWith('/inventory/adjustments/')) {
    return 'Adjustment Approvals';
  }
  return 'This screen';
}

/// Display subtitle for a non-module gated route (D135).
String _subtitleForRoute(String route) {
  if (route == '/branches' || route.startsWith('/branches/')) {
    return 'Own branches and franchises — list, detail, franchise '
        'settings, commission / royalty.';
  }
  if (route == '/finance/franchise') {
    return 'Franchise commission and royalty by branch — head office only.';
  }
  if (route == '/audit-log' || route.startsWith('/audit-log/')) {
    return 'Filterable log of all important actions.';
  }
  if (route == '/backup' || route.startsWith('/backup/')) {
    return 'Backup status, manual backup, restore (admin only).';
  }
  if (route == '/inventory/adjustments' ||
      route.startsWith('/inventory/adjustments/')) {
    return 'Review and approve stock adjustments.';
  }
  return '';
}

class _ModuleDisabledScreen extends StatelessWidget {
  const _ModuleDisabledScreen({required this.module});

  final FeatureModuleConfig module;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            title: module.title,
            subtitle: module.description,
            actionLabel: 'Back to Dashboard',
            actionIcon: Icons.dashboard_outlined,
            onAction: () => context.go('/dashboard'),
          ),
          const SizedBox(height: 16),
          PharmaEmptyState(
            icon: Icons.extension_off_outlined,
            title: '${module.title} is disabled',
            message:
                'This module is turned off for this organization in '
                'Feature Settings (SRS FR-SYS-05). Turn it back on in '
                'Settings → Features to use it again. Nothing about '
                'this module was deleted — its data is untouched.',
            actionLabel: 'Open Feature Settings',
            onAction: () => context.go('/settings'),
          ),
          const SizedBox(height: 16),
          PharmaButton(
            label: 'Back to Dashboard',
            variant: PharmaButtonVariant.secondary,
            icon: Icons.dashboard_outlined,
            onPressed: () => context.go('/dashboard'),
          ),
        ],
      ),
    );
  }
}

/// Shown when the signed-in user may not use a module in the active
/// branch (SRS §5.1). The message names the role and the capability
/// so the user (or an admin) knows what to change; it never reveals
/// anything about other users.
class _NoPermissionScreen extends StatelessWidget {
  const _NoPermissionScreen({
    required this.title,
    required this.subtitle,
    required this.capability,
    required this.user,
  });

  final String title;
  final String subtitle;
  final String capability;
  final AppUser user;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            title: title,
            subtitle: subtitle,
            actionLabel: 'Back to Dashboard',
            actionIcon: Icons.dashboard_outlined,
            onAction: () => context.go('/dashboard'),
          ),
          const SizedBox(height: 16),
          PharmaEmptyState(
            icon: Icons.lock_outline,
            title: 'No permission for $title',
            message:
                'Your role (${user.roleLabel}) does not have the '
                '"$capability" permission for this branch (SRS §5.1). '
                'Ask an owner or HO admin to change your role or '
                'branch access if you need this module.',
            actionLabel: 'Back to Dashboard',
            onAction: () => context.go('/dashboard'),
          ),
        ],
      ),
    );
  }
}
