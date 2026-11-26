import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/data/permission_service.dart';
import '../../core/routing/app_router.dart';
import '../../core/services/branch_context.dart';
import '../../core/theme/theme_mode_provider.dart';
import '../../core/theme/white_label.dart';
import '../../core/widgets/demo_mode_badge.dart';
import '../../features/authentication/auth_state.dart';
import '../../features/audit/audit_logic.dart';
import '../../features/branches/branch_directory.dart';
import '../../features/notifications/notifications_provider.dart';
import '../../features/settings/feature_config.dart';
import '../../features/inventory/stock_adjustment_logic.dart';
import '../../features/inventory/transfer_logic.dart';
import '../../features/staff/salary_logic.dart';
import '../../models/branch.dart';

/// Responsive application shell — Day 2.
///
/// - Wide screens (≥900px, desktop entry + web admin): sidebar navigation
///   + top bar.
/// - Narrow screens (phone entry): top bar + bottom navigation with a
///   "More" sheet for the remaining modules.
/// - The top bar carries the branch switcher (mock demo branches) and the
///   theme switcher (light / dark / system), and the sidebar renders the
///   active [BrandConfig] (white-label name + colours).
///
/// Every navigation destination opens its module route — no dead items.
/// All 16 modules are real screens; disabled modules
/// (FR-SYS-05) are hidden from navigation by the Day 7 feature config.
class AppShell extends ConsumerWidget {
  const AppShell({
    super.key,
    required this.child,
    required this.currentLocation,
  });

  final Widget child;
  final String currentLocation;

  static const double desktopBreakpoint = 900;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final width = MediaQuery.sizeOf(context).width;
    if (width >= desktopBreakpoint) {
      return Scaffold(
        body: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Sidebar(currentLocation: currentLocation),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _TopBar(),
                  Expanded(child: child),
                ],
              ),
            ),
          ],
        ),
      );
    }
    return Scaffold(
      appBar: const _TopBar(),
      body: child,
      bottomNavigationBar: _BottomNav(currentLocation: currentLocation),
    );
  }
}

// --- Top bar ------------------------------------------------------------

/// Top bar shared by desktop and mobile: brand mark, branch switcher,
/// theme menu, notifications and profile shortcuts.
///
/// Responsive (D117, fixes the D116 phone-width overflow): below
/// [compactBreakpoint] the app-name text is hidden (the brand-mark
/// initial tile stays), the branch switcher drops its store icon and
/// its name cap shrinks to the space that is left, and the three icon
/// buttons compact to 40px. The DEMO MODE badge is NEVER hidden or
/// shrunk (SRS §8.2) — it keeps its full size at every width, and the
/// switcher + buttons give way around it instead. The full bar needs
/// ~615px (measured), so the breakpoint sits at 640px; at or above it
/// the bar is byte-for-byte the old layout, and the desktop layout
/// (≥900px, sidebar + top bar) is unchanged.
class _TopBar extends ConsumerWidget implements PreferredSizeWidget {
  const _TopBar();

  /// Width below which the top bar switches to its compact form.
  static const double compactBreakpoint = 640;

  @override
  Size get preferredSize => const Size.fromHeight(64);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final brand = ref.watch(brandConfigProvider);
    final theme = Theme.of(context);
    final width = MediaQuery.sizeOf(context).width;
    final compact = width < compactBreakpoint;
    return Material(
      color: theme.appBarTheme.backgroundColor,
      elevation: 1,
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: 64,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 12),
            child: Row(
              children: [
                // Brand mark (white-label: initial + app name).
                Container(
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: brand.primaryColor,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Text(
                    brand.appName.isEmpty
                        ? 'P'
                        : brand.appName[0].toUpperCase(),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                SizedBox(width: compact ? 8 : 10),
                // App name: hidden below the compact breakpoint — at
                // phone widths it is the first thing that has to go
                // (D117); the brand-mark tile above still identifies
                // the app.
                if (!compact) ...[
                  Flexible(
                    child: Text(
                      brand.appName,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 16),
                ],
                // Branch switcher (wired to the mock demo branches).
                // Compact: Flexible so its name cap follows the space
                // left after the badge + buttons (D117); the Spacer
                // would split that space with it, so it is dropped.
                if (compact)
                  const Flexible(child: _BranchSwitcher(compact: true))
                else
                  const _BranchSwitcher(),
                if (!compact) const Spacer(),
                // DEMO MODE indicator (SRS §8.2) — on every shell screen.
                const DemoModeBadge(),
                SizedBox(width: compact ? 4 : 8),
                _ThemeMenuButton(compact: compact),
                _NotificationsButton(compact: compact),
                _ProfileMenuButton(compact: compact),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Branch switcher: popup menu over the two demo branches. Selecting one
/// updates [activeBranchProvider], so every screen reading the provider
/// (e.g. the module placeholder's branch chip) changes immediately.
///
/// Compact (D117): the store icon is dropped and the name cap follows
/// the width the top bar leaves it (via LayoutBuilder — a fixed cap
/// cannot fit both a 390px and a 360px phone). The cap never exceeds
/// 80px; it has NO floor — the chrome around the name (horizontal
/// padding 16 + pill border 2 + dropdown arrow 18 = 36px) is
/// subtracted from the space left, so a floor would reintroduce the
/// overflow it exists to prevent (the Day 1 probe measured the pill
/// overflowing by 14px with a 32px floor). A truncated branch name is
/// always shown while the space allows; the popup menu itself still
/// shows both full names.
class _BranchSwitcher extends ConsumerWidget {
  const _BranchSwitcher({this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(activeBranchProvider);
    final theme = Theme.of(context);
    return PopupMenuButton<String>(
      key: const ValueKey('branch-switcher-button'),
      tooltip: 'Switch branch',
      initialValue: active.id,
      onSelected: (branchId) =>
          ref.read(activeBranchProvider.notifier).switchTo(branchId),
      itemBuilder: (context) => [
        for (final branch in demoBranches)
          PopupMenuItem<String>(
            value: branch.id,
            child: Row(
              children: [
                Icon(
                  branch.id == active.id
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        branch.name,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      Text(branch.address, style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
      child: compact
          ? LayoutBuilder(
              builder: (context, constraints) {
                // Chrome around the name: horizontal padding (16) +
                // pill border (2) + dropdown arrow (18). The cap
                // follows the space the top bar leaves the switcher,
                // so the bar fits at any phone width instead of
                // overflowing (D116). No floor: see the class doc.
                final cap = (constraints.maxWidth - 36).clamp(0.0, 80.0);
                return _switcherPill(theme, active, cap, showIcon: false);
              },
            )
          : _switcherPill(theme, active, 180, showIcon: true),
    );
  }

  Widget _switcherPill(
    ThemeData theme,
    Branch active,
    double maxNameWidth, {
    required bool showIcon,
  }) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 10, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.25),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showIcon) ...[
            Icon(
              Icons.store_outlined,
              size: 18,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 6),
          ],
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxNameWidth),
            child: Text(
              active.name,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.primary,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Icon(
            Icons.arrow_drop_down,
            size: 18,
            color: theme.colorScheme.primary,
          ),
        ],
      ),
    );
  }
}

/// Notifications bell with the unread-count badge (Day 7). The count
/// comes from the derived notifications list; tapping opens the
/// notifications center.
///
/// Compact (D117): 40px instead of 48px, so the three icon buttons
/// still fit next to the full-size DEMO MODE badge at phone widths.
class _NotificationsButton extends ConsumerWidget {
  const _NotificationsButton({this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unread = ref.watch(unreadNotificationsProvider).asData?.value ?? 0;
    return IconButton(
      key: const ValueKey('notifications-button'),
      tooltip: 'Notifications',
      padding: compact ? const EdgeInsets.all(4) : const EdgeInsets.all(8),
      constraints: compact
          ? const BoxConstraints.tightFor(width: 40, height: 40)
          : const BoxConstraints(minWidth: 48, minHeight: 48),
      icon: Badge(
        label: Text('$unread'),
        isLabelVisible: unread > 0,
        child: const Icon(Icons.notifications_outlined),
      ),
      onPressed: () => context.go('/notifications'),
      // NOTE: IconButton enforces a 48px tap target while its tap
      // target size is padded (the theme default) — `constraints`
      // alone cannot shrink it below 48. The shrinkWrap style below
      // lifts that floor so the 40px constraints take effect (D117);
      // without it the bell stays 48px and the branch switcher loses
      // the 8px (measured in the Day 1 probe).
      style: compact
          ? const ButtonStyle(
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              minimumSize: WidgetStatePropertyAll(Size(40, 40)),
            )
          : null,
    );
  }
}

/// Profile menu: shows the signed-in user, opens the profile screen,
/// and signs out (Day 3 auth). When nobody is signed in it offers
/// sign-in instead.
///
/// Compact (D117): 40px instead of 48px, like the other icon buttons.
class _ProfileMenuButton extends ConsumerWidget {
  const _ProfileMenuButton({this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authProvider);
    return PopupMenuButton<String>(
      key: const ValueKey('profile-button'),
      tooltip: 'Profile',
      padding: compact ? const EdgeInsets.all(4) : const EdgeInsets.all(8),
      // NOTE: PopupMenuButton.constraints sizes the popup MENU, not the
      // button — the button itself shrinks via style (shrinkWrap tap
      // target + 40px minimum). Passing tight constraints here would
      // squeeze the menu to 40px wide and break its ListTiles (D117).
      style: compact
          ? const ButtonStyle(
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              minimumSize: WidgetStatePropertyAll(Size(40, 40)),
            )
          : null,
      icon: const Icon(Icons.account_circle_outlined),
      onSelected: (value) {
        if (value == 'profile') {
          context.go('/profile');
        } else if (value == 'sign-out') {
          ref.read(authProvider.notifier).signOut();
          context.go('/login');
        } else if (value == 'sign-in') {
          context.go('/login');
        }
      },
      itemBuilder: (context) {
        if (user == null) {
          return const [
            PopupMenuItem(
              value: 'sign-in',
              child: ListTile(
                leading: Icon(Icons.login_outlined),
                title: Text('Sign in'),
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ];
        }
        return [
          PopupMenuItem<String>(
            enabled: false,
            child: ListTile(
              leading: const Icon(Icons.person_outline),
              title: Text(user.name),
              subtitle: Text('${user.roleLabel} • ${user.email}'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
          const PopupMenuDivider(),
          const PopupMenuItem(
            value: 'profile',
            child: ListTile(
              leading: Icon(Icons.person_outline),
              title: Text('Profile'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
          const PopupMenuItem(
            value: 'sign-out',
            child: ListTile(
              leading: Icon(Icons.logout_outlined),
              title: Text('Sign out'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ];
      },
    );
  }
}

/// Theme menu: Light / Dark / System. Writes to [themeModeProvider],
/// which the app root reads (persisted in-memory for the session).
///
/// Compact (D117): 40px instead of 48px, like the other icon buttons.
class _ThemeMenuButton extends ConsumerWidget {
  const _ThemeMenuButton({this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    final icon = switch (mode) {
      ThemeMode.dark => Icons.light_mode_outlined,
      ThemeMode.light => Icons.dark_mode_outlined,
      ThemeMode.system => Icons.brightness_auto_outlined,
    };
    return PopupMenuButton<ThemeMode>(
      key: const ValueKey('theme-menu-button'),
      tooltip: 'Change theme',
      padding: compact ? const EdgeInsets.all(4) : const EdgeInsets.all(8),
      // NOTE: PopupMenuButton.constraints sizes the popup MENU, not the
      // button — see the profile button above (D117).
      style: compact
          ? const ButtonStyle(
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              minimumSize: WidgetStatePropertyAll(Size(40, 40)),
            )
          : null,
      icon: Icon(icon),
      initialValue: mode,
      onSelected: (selected) =>
          ref.read(themeModeProvider.notifier).setMode(selected),
      itemBuilder: (context) => const [
        PopupMenuItem(
          value: ThemeMode.light,
          child: _ThemeMenuItem(
            mode: ThemeMode.light,
            icon: Icons.light_mode_outlined,
            label: 'Light',
          ),
        ),
        PopupMenuItem(
          value: ThemeMode.dark,
          child: _ThemeMenuItem(
            mode: ThemeMode.dark,
            icon: Icons.dark_mode_outlined,
            label: 'Dark',
          ),
        ),
        PopupMenuItem(
          value: ThemeMode.system,
          child: _ThemeMenuItem(
            mode: ThemeMode.system,
            icon: Icons.brightness_auto_outlined,
            label: 'System',
          ),
        ),
      ],
    );
  }
}

class _ThemeMenuItem extends ConsumerWidget {
  const _ThemeMenuItem({
    required this.mode,
    required this.icon,
    required this.label,
  });

  final ThemeMode mode;
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(themeModeProvider);
    return Row(
      children: [
        Icon(icon, size: 18),
        const SizedBox(width: 8),
        Text(label),
        const Spacer(),
        if (current == mode)
          Icon(
            Icons.check,
            size: 18,
            color: Theme.of(context).colorScheme.primary,
          ),
      ],
    );
  }
}

// --- Desktop sidebar ----------------------------------------------------

/// Sidebar navigation groups (module titles, in [appModules] order).
const _navGroups = <(String, List<String>)>[
  ('Main', ['Dashboard', 'Orders', 'Billing & POS', 'Medicines', 'Inventory']),
  (
    'Manage',
    ['Customers', 'Suppliers', 'Purchases', 'Prescriptions', 'Staff & HR'],
  ),
  ('Insights', ['Reports', 'Finance', 'Notifications']),
  ('System', ['Settings', 'Profile', 'Authentication']),
];

class _Sidebar extends ConsumerWidget {
  const _Sidebar({required this.currentLocation});

  final String currentLocation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final brand = ref.watch(brandConfigProvider);
    final moduleByTitle = {for (final m in appModules) m.title: m};
    // Disabled modules (FR-SYS-05) leave the navigation.
    final enabledModules = ref.watch(featureConfigProvider);
    // Modules the signed-in user has no §5.1 permission for in the
    // active branch leave the navigation too (Week 2 Day 3, D70).
    // A signed-out user sees everything — the router's auth redirect
    // is the signed-out guard.
    final user = ref.watch(authProvider);
    final branchId = ref.watch(activeBranchProvider).id;
    bool isVisible(AppModule module) {
      final config = featureModuleForRoute(module.route);
      if (config != null && !enabledModules.contains(config.key)) {
        return false;
      }
      final capability = routeCapability(module.route);
      if (capability != null && user != null) {
        return permissionService.canInBranch(user, capability, branchId);
      }
      return true;
    }

    return Container(
      width: 264,
      color: brand.secondaryColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Brand header (white-label).
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: brand.primaryColor,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    brand.appName.isEmpty
                        ? 'P'
                        : brand.appName[0].toUpperCase(),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        brand.appName,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        brand.organizationName,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.7),
                          fontSize: 12,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Divider(color: Colors.white.withValues(alpha: 0.15), height: 1),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                for (final (groupLabel, titles) in _navGroups) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 14, 16, 6),
                    child: Text(
                      groupLabel.toUpperCase(),
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.55),
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ),
                  for (final title in titles)
                    if (moduleByTitle[title] != null &&
                        isVisible(moduleByTitle[title]!)) ...[
                      _SidebarItem(
                        module: moduleByTitle[title]!,
                        selected:
                            moduleByTitle[title]!.route == currentLocation,
                      ),
                      // Stock Transfers sits under Inventory (Week 4
                      // Day 2, D118): a sub-screen of the Inventory
                      // module, same feature toggle — but only for
                      // users who may use transfers in the active
                      // branch (`stockTransfer`): a Pharmacist sees
                      // the inventory, not the transfer screens.
                      if (title == 'Inventory' &&
                          canViewTransfers(user, branchId))
                        _SidebarSubItem(
                          label: 'Stock Transfers',
                          route: '/inventory/transfers',
                          selected: currentLocation.startsWith(
                            '/inventory/transfers',
                          ),
                        ),
                      // Adjustment Approvals sits under Inventory
                      // (Week 4 Day 5, D141): a sub-screen of the
                      // Inventory module, same feature toggle — but
                      // only for users who may request adjustments
                      // in the active branch (`stockAdjustReq`): a
                      // Pharmacist sees the inventory, not the
                      // approval queue.
                      if (title == 'Inventory' &&
                          canViewAdjustmentQueue(user, branchId))
                        _SidebarSubItem(
                          label: 'Adjustment Approvals',
                          route: '/inventory/adjustments',
                          selected: currentLocation.startsWith(
                            '/inventory/adjustments',
                          ),
                        ),
                      // Riders & Delivery sits under Orders (Week 4
                      // Day 2, D121): a sub-screen of the Orders
                      // module, same feature toggle — no separate
                      // §5.1 capability governs rider viewing.
                      if (title == 'Orders')
                        _SidebarSubItem(
                          label: 'Riders & Delivery',
                          route: '/riders',
                          selected: currentLocation.startsWith('/riders'),
                        ),
                      // Auto Purchase List sits under Purchases (Day 2
                      // Week 2): a sub-screen of the Purchases module,
                      // not a 15th module — it follows the Purchases
                      // feature toggle via featureModuleForRoute.
                      if (title == 'Purchases')
                        _SidebarSubItem(
                          label: 'Auto Purchase List',
                          route: '/purchases/auto',
                          selected: currentLocation == '/purchases/auto',
                        ),
                      // Returns & refunds sits under Billing & POS
                      // (Week 2 Day 4): a sub-screen of the Billing
                      // module, same feature toggle as the POS.
                      if (title == 'Billing & POS')
                        _SidebarSubItem(
                          label: 'Returns & refunds',
                          route: '/billing/returns',
                          selected: currentLocation == '/billing/returns' ||
                              currentLocation == '/billing/returns/new',
                        ),
                      // Attendance & shifts sit under Staff & HR
                      // (Week 2 Day 5): sub-screens of the Staff
                      // module, same feature toggle as the directory.
                      if (title == 'Staff & HR') ...[
                        _SidebarSubItem(
                          label: 'Attendance',
                          route: '/staff/attendance',
                          selected:
                              currentLocation == '/staff/attendance',
                        ),
                        _SidebarSubItem(
                          label: 'Shifts',
                          route: '/staff/shifts',
                          selected: currentLocation == '/staff/shifts',
                        ),
                        // Salary sits under Staff & HR too (Week 3
                        // Day 2, D102) — but only for users who may
                        // view salary figures in the active branch
                        // (`hrSalary`): a Branch Manager sees the
                        // directory, not the salary screen.
                        if (canViewSalary(user, branchId))
                          _SidebarSubItem(
                            label: 'Salary',
                            route: '/staff/salary',
                            selected: currentLocation == '/staff/salary',
                          ),
                      ],
                      // System hub sits under Settings (Week 4 Day 4,
                      // D135 — SRS D-28 / D-33 / D-35): sub-screens
                      // of the Settings module, same feature toggle
                      // (Settings is always on) — each gated on its
                      // own §5.1 capability in the active branch.
                      if (title == 'Settings') ...[
                        if (canViewBranches(user, branchId))
                          _SidebarSubItem(
                            label: 'Branch Management',
                            route: '/branches',
                            selected: currentLocation.startsWith(
                              '/branches',
                            ),
                          ),
                        if (canViewAuditLog(user, branchId))
                          _SidebarSubItem(
                            label: 'Audit Log',
                            route: '/audit-log',
                            selected: currentLocation == '/audit-log',
                          ),
                        if (permissionService.canInBranch(
                          user,
                          'sysSettings',
                          branchId,
                        ))
                          _SidebarSubItem(
                            label: 'Backup & Restore',
                            route: '/backup',
                            selected: currentLocation == '/backup',
                          ),
                      ],
                    ],
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'PharmaDesk v1.0.0 • Demo mode — mock data',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.55),
                fontSize: 11,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SidebarSubItem extends StatelessWidget {
  const _SidebarSubItem({
    required this.label,
    required this.route,
    required this.selected,
  });

  final String label;
  final String route;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Material(
        color: selected
            ? Colors.white.withValues(alpha: 0.14)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => context.go(route),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(44, 8, 12, 8),
            child: Row(
              children: [
                Icon(
                  Icons.auto_awesome_outlined,
                  size: 16,
                  color: Colors.white.withValues(alpha: 0.75),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SidebarItem extends StatelessWidget {
  const _SidebarItem({required this.module, required this.selected});

  final AppModule module;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Material(
        color: selected
            ? Colors.white.withValues(alpha: 0.14)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => context.go(module.route),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(
                  module.icon,
                  size: 20,
                  color: Colors.white.withValues(alpha: selected ? 1.0 : 0.75),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    module.title,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// --- Mobile bottom navigation -------------------------------------------

/// Bottom nav (phone): the four most-used modules + "More", which opens
/// a sheet listing every module so nothing is unreachable on mobile.
/// Disabled modules (FR-SYS-05) are left out of the sheet.
class _BottomNav extends ConsumerWidget {
  const _BottomNav({required this.currentLocation});

  final String currentLocation;

  static const _primaryRoutes = [
    '/dashboard',
    '/orders',
    '/billing',
    '/medicines',
  ];

  int get _currentIndex {
    final index = _primaryRoutes.indexOf(currentLocation);
    return index == -1 ? 4 : index;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabledModules = ref.watch(featureConfigProvider);
    // The More sheet lists the same visible modules as the sidebar:
    // feature-flagged off, or without §5.1 permission in the active
    // branch, stays out (Week 2 Day 3, D70).
    final user = ref.watch(authProvider);
    final branchId = ref.watch(activeBranchProvider).id;
    final visibleModules = appModules.where((module) {
      final config = featureModuleForRoute(module.route);
      if (config != null && !enabledModules.contains(config.key)) {
        return false;
      }
      final capability = routeCapability(module.route);
      if (capability != null && user != null) {
        return permissionService.canInBranch(user, capability, branchId);
      }
      return true;
    }).toList();
    return BottomNavigationBar(
      currentIndex: _currentIndex,
      type: BottomNavigationBarType.fixed,
      onTap: (index) {
        if (index < _primaryRoutes.length) {
          context.go(_primaryRoutes[index]);
        } else {
          _showMoreSheet(
            context,
            visibleModules,
            canViewSalary(user, branchId),
            canViewTransfers(user, branchId),
            canViewAdjustmentQueue(user, branchId),
            canViewBranches(user, branchId),
            canViewAuditLog(user, branchId),
            permissionService.canInBranch(user, 'sysSettings', branchId),
          );
        }
      },
      items: const [
        BottomNavigationBarItem(
          icon: Icon(Icons.dashboard_outlined),
          activeIcon: Icon(Icons.dashboard),
          label: 'Dashboard',
        ),
        BottomNavigationBarItem(
          icon: Icon(Icons.receipt_long_outlined),
          activeIcon: Icon(Icons.receipt_long),
          label: 'Orders',
        ),
        BottomNavigationBarItem(
          icon: Icon(Icons.point_of_sale_outlined),
          activeIcon: Icon(Icons.point_of_sale),
          label: 'Billing',
        ),
        BottomNavigationBarItem(
          icon: Icon(Icons.medication_outlined),
          activeIcon: Icon(Icons.medication),
          label: 'Medicines',
        ),
        BottomNavigationBarItem(icon: Icon(Icons.menu), label: 'More'),
      ],
    );
  }

  void _showMoreSheet(
    BuildContext context,
    List<AppModule> modules,
    bool canViewSalaryRecords,
    bool canViewTransferRecords,
    bool canViewAdjustmentRecords,
    bool canViewBranchRecords,
    bool canViewAuditRecords,
    bool canViewBackupRecords,
  ) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        minChildSize: 0.4,
        maxChildSize: 0.9,
        builder: (context, scrollController) => ListView(
          controller: scrollController,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(
                'All modules',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
            ),
            for (final module in modules) ...[
              ListTile(
                leading: Icon(
                  module.icon,
                  color: Theme.of(context).colorScheme.primary,
                ),
                title: Text(module.title),
                subtitle: Text(module.day),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  context.go(module.route);
                },
              ),
              // Stock Transfers sits under Inventory (Week 4 Day 2,
              // D118) — only for users who may use transfers in the
              // active branch (`stockTransfer`).
              if (module.title == 'Inventory' && canViewTransferRecords)
                ListTile(
                  leading: const SizedBox(width: 24),
                  title: const Text('Stock Transfers'),
                  subtitle: const Text(
                    'Move stock between branches',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    context.go('/inventory/transfers');
                  },
                ),
              // Adjustment Approvals sits under Inventory (Week 4
              // Day 5, D141) — only for users who may request
              // adjustments in the active branch (`stockAdjustReq`).
              if (module.title == 'Inventory' && canViewAdjustmentRecords)
                ListTile(
                  leading: const SizedBox(width: 24),
                  title: const Text('Adjustment Approvals'),
                  subtitle: const Text(
                    'Review and approve stock adjustments',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    context.go('/inventory/adjustments');
                  },
                ),
              // Riders & Delivery sits under Orders (Week 4 Day 2,
              // D121).
              if (module.title == 'Orders')
                ListTile(
                  leading: const SizedBox(width: 24),
                  title: const Text('Riders & Delivery'),
                  subtitle: const Text(
                    'Riders, availability, assignment',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    context.go('/riders');
                  },
                ),
              // Auto Purchase List sits under Purchases (Day 2 Week 2).
              if (module.title == 'Purchases')
                ListTile(
                  leading: const SizedBox(width: 24),
                  title: const Text('Auto Purchase List'),
                  subtitle: const Text('Suggested orders from live stock'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    context.go('/purchases/auto');
                  },
                ),
              // Returns & refunds sits under Billing & POS (Week 2 Day 4).
              if (module.title == 'Billing & POS')
                ListTile(
                  leading: const SizedBox(width: 24),
                  title: const Text('Returns & refunds'),
                  subtitle: const Text('Return items, restock, refund'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    context.go('/billing/returns');
                  },
                ),
              // Attendance & shifts sit under Staff & HR (Week 2 Day 5).
              if (module.title == 'Staff & HR') ...[
                ListTile(
                  leading: const SizedBox(width: 24),
                  title: const Text('Attendance'),
                  subtitle: const Text('Check-in / check-out today'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    context.go('/staff/attendance');
                  },
                ),
                ListTile(
                  leading: const SizedBox(width: 24),
                  title: const Text('Shifts'),
                  subtitle: const Text('Shift planner'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    context.go('/staff/shifts');
                  },
                ),
                // Salary sits under Staff & HR too (Week 3 Day 2,
                // D102) — only for users who may view salary figures
                // (`hrSalary`).
                if (canViewSalaryRecords)
                  ListTile(
                    leading: const SizedBox(width: 24),
                    title: const Text('Salary'),
                    subtitle: const Text('Monthly payroll, per employee'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      context.go('/staff/salary');
                    },
                  ),
              ],
              // System hub sits under Settings (Week 4 Day 4, D135
              // — SRS D-28 / D-33 / D-35), each gated on its own
              // §5.1 capability in the active branch.
              if (module.title == 'Settings') ...[
                if (canViewBranchRecords)
                  ListTile(
                    leading: const SizedBox(width: 24),
                    title: const Text('Branch Management'),
                    subtitle: const Text(
                      'Branches, franchise settings, royalty',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      context.go('/branches');
                    },
                  ),
                if (canViewAuditRecords)
                  ListTile(
                    leading: const SizedBox(width: 24),
                    title: const Text('Audit Log'),
                    subtitle: const Text('Filterable log of actions'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      context.go('/audit-log');
                    },
                  ),
                if (canViewBackupRecords)
                  ListTile(
                    leading: const SizedBox(width: 24),
                    title: const Text('Backup & Restore'),
                    subtitle: const Text('Backup status, restore'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      context.go('/backup');
                    },
                  ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}
