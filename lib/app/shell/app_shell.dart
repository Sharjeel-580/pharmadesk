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
import '../../features/notifications/notifications_provider.dart';
import '../../features/settings/feature_config.dart';

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
/// All 14 modules are real screens (Days 3–7); disabled modules
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
class _TopBar extends ConsumerWidget implements PreferredSizeWidget {
  const _TopBar();

  @override
  Size get preferredSize => const Size.fromHeight(64);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final brand = ref.watch(brandConfigProvider);
    final theme = Theme.of(context);
    return Material(
      color: theme.appBarTheme.backgroundColor,
      elevation: 1,
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: 64,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
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
                const SizedBox(width: 10),
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
                // Branch switcher (wired to the mock demo branches).
                const _BranchSwitcher(),
                const Spacer(),
                // DEMO MODE indicator (SRS §8.2) — on every shell screen.
                const DemoModeBadge(),
                const SizedBox(width: 8),
                const _ThemeMenuButton(),
                const _NotificationsButton(),
                const _ProfileMenuButton(),
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
class _BranchSwitcher extends ConsumerWidget {
  const _BranchSwitcher();

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
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
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
            Icon(
              Icons.store_outlined,
              size: 18,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 180),
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
      ),
    );
  }
}

/// Notifications bell with the unread-count badge (Day 7). The count
/// comes from the derived notifications list; tapping opens the
/// notifications center.
class _NotificationsButton extends ConsumerWidget {
  const _NotificationsButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unread = ref.watch(unreadNotificationsProvider).asData?.value ?? 0;
    return IconButton(
      key: const ValueKey('notifications-button'),
      tooltip: 'Notifications',
      icon: Badge(
        label: Text('$unread'),
        isLabelVisible: unread > 0,
        child: const Icon(Icons.notifications_outlined),
      ),
      onPressed: () => context.go('/notifications'),
    );
  }
}

/// Profile menu: shows the signed-in user, opens the profile screen,
/// and signs out (Day 3 auth). When nobody is signed in it offers
/// sign-in instead.
class _ProfileMenuButton extends ConsumerWidget {
  const _ProfileMenuButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authProvider);
    return PopupMenuButton<String>(
      key: const ValueKey('profile-button'),
      tooltip: 'Profile',
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
class _ThemeMenuButton extends ConsumerWidget {
  const _ThemeMenuButton();

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
  ('Insights', ['Reports', 'Notifications']),
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
          _showMoreSheet(context, visibleModules);
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

  void _showMoreSheet(BuildContext context, List<AppModule> modules) {
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
              ],
            ],
          ],
        ),
      ),
    );
  }
}
