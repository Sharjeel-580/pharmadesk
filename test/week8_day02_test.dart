// Week 8 Day 2 tests — full screen walk, final (D177, brief §2).
//
// - D-01–D-35 desktop walk (owner, 1920x1080): every SRS desktop
//   screen resolves, no placeholder, no 404; D-03 (branch dashboard)
//   separately, as branch_manager; D-29/D-30/D-31 via the Settings
//   tabs (Roles & Permissions / Features / Branding).
// - M-01–M-24 mobile walk (390x844, corrected trap): every SRS
//   mobile screen resolves at phone width; M-03/M-04 role dashboards
//   separately; M-21 branch switcher switches (provider-read, not
//   text — the compact pill truncates the name); M-23/M-24 (Live
//   Control Center O-11, AI Assistant O-2) are PINNED AS ABSENT —
//   optional modules, unselected, BLOCKED-CLIENT, not built.
// - Buttons do what they say: the primary action of a sample of
//   screens is tapped and the screen/dialog it promises appears
//   (receive stock, stock count, receive goods, cashbook add entry,
//   prescription approve, notifications mark-all-read, order-form
//   validation, unknown route way back).
// - D170 fixes re-verified with the corrected trap (supplier detail
//   x2, /reports dropdown, supplier payment dialog, /branches rows,
//   sales history paged list).
// - Fresh full 390px sweep: all 47 routes as owner, 0 distinct
//   overflows, measured with the CORRECTED `FlutterError.onError`
//   trap (D170/D174 standard — counting DISTINCT overflow messages;
//   the D160 `takeException` drain is NOT the measurement here).
//   The trap is copied, not imported — the Day 36 trap is private
//   to its file (same shape as the Day 38 copy).
// - Week 7 changed screens (quarantine outcomes queue, backup +
//   restore) are inside the 47-route sweep; their dialogs were
//   swept in week7_day04_test.dart (D174) and no app code changed
//   them since, so they are re-run in the cumulative suite, not
//   duplicated here. Week 8 Day 1 changed no app code at all.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:pharmadesk/core/data/auth_repository.dart';
import 'package:pharmadesk/core/routing/app_router.dart';
import 'package:pharmadesk/core/services/branch_context.dart';
import 'package:pharmadesk/core/services/repositories.dart';
import 'package:pharmadesk/core/theme/app_theme.dart';
import 'package:pharmadesk/core/theme/white_label.dart';
import 'package:pharmadesk/features/authentication/auth_state.dart';
import 'package:pharmadesk/models/supplier_payment.dart';

import 'week7_day04_test.dart';

const _dha = 'branch-dha-main';
const _glb = 'branch-demo-gulberg';
const _desktopSize = Size(1920, 1080);
const _phoneSize = Size(390, 844);

/// The D170 corrected-trap shape (copied, not imported): counts
/// DISTINCT RenderFlex overflow messages as the handler sees them.
/// Every sweep figure in this file states its trap: this one.
class _D39OverflowTrap {
  _D39OverflowTrap() : _previous = FlutterError.onError {
    FlutterError.onError = (details) {
      _seen.add(details.toString());
      _previous?.call(details);
    };
  }

  final dynamic _previous;
  final _seen = <String>[];

  int get overflowCount {
    var count = 0;
    final distinct = <String>{
      for (final message in _seen)
        if (message.contains('RenderFlex overflowed')) message,
    };
    for (final message in distinct) {
      var from = 0;
      while (true) {
        final at = message.indexOf('RenderFlex overflowed', from);
        if (at == -1) break;
        count++;
        from = at + 1;
      }
    }
    return count;
  }

  void dispose() {
    FlutterError.onError = _previous;
  }
}

class _SignedOutAuthNotifier extends AuthNotifier {
  @override
  AppUser? build() => null;
}

/// Pumps the router app with no signed-in user (login screen), at
/// [size]. The shared `pumpRouterApp` defaults to signed-in, so the
/// login screen needs its own pump.
Future<(ProviderContainer, GoRouter)> _pumpSignedOut(
  WidgetTester tester, {
  Size size = _desktopSize,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final container = ProviderContainer(
    overrides: [authProvider.overrideWith(() => _SignedOutAuthNotifier())],
  );
  addTearDown(container.dispose);
  final router = createAppRouter(
    isSignedIn: () => container.read(authProvider) != null,
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: AppTheme.light(BrandConfig.defaults),
        darkTheme: AppTheme.dark(BrandConfig.defaults),
        themeMode: ThemeMode.light,
        routerConfig: router,
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 1500));
  await tester.pumpAndSettle();
  return (container, router);
}

/// The 47 shell routes (Day 27 / Day 32 / Day 36 count, asserted):
/// route + text only that screen shows. Shared shell text (sidebar
/// module names, top-bar titles) is never used as a marker.
Future<List<(String, String)>> _walkRoutes(
  ProviderContainer container,
) async {
  final orders = await container.read(orderRepositoryProvider).getOrders();
  final orderId = orders.first.id;
  final customer = await container
      .read(customerRepositoryProvider)
      .getById('cust-1');
  final supplier = await container
      .read(supplierRepositoryProvider)
      .getById('sup-sami');
  return [
    ('/dashboard', 'Branch comparison'),
    ('/profile', 'Profile'),
    ('/orders', 'newest first'),
    ('/orders/new', 'New Order'),
    ('/orders/$orderId/edit', 'Edit order $orderId'),
    ('/orders/$orderId', 'Status timeline'),
    ('/medicines', 'Panadol Extra'),
    ('/medicines/med-panadol-extra', 'Batches —'),
    ('/inventory', 'expiring ≤ 30 days'),
    ('/inventory/transfers', 'Stock Transfers'),
    ('/inventory/transfers/new', 'New Transfer'),
    ('/inventory/transfers/tr-demo-1', 'TR-DHA-GLB-1001'),
    ('/inventory/adjustments', 'Adjustment Approvals'),
    ('/inventory/quarantine-outcomes', 'Quarantine Outcomes'),
    ('/riders', 'Riders & Delivery'),
    ('/riders/rider-1', 'Bilal Ahmed'),
    ('/billing', 'Add medicines'),
    ('/billing/history', 'Sales history'),
    ('/billing/returns', 'Returns & refunds'),
    ('/billing/returns/new', 'New return'),
    ('/billing/receipt/sale-missing', 'Sale not found'),
    ('/customers', 'Directory, purchase history and khata'),
    ('/customers/cust-1', customer!.name),
    ('/suppliers', 'Profiles, contacts, purchase history'),
    ('/suppliers/sup-sami', supplier!.name),
    ('/purchases', 'Purchase orders, goods receiving'),
    ('/purchases/new', 'New purchase order'),
    ('/purchases/auto', 'Auto Purchase List'),
    ('/purchases/po-dha-1001', 'PO-DHA-1001'),
    ('/prescriptions', 'New prescription'),
    ('/prescriptions/rx-dha-1', 'rx-dha-1'),
    ('/reports', 'Daily sales'),
    ('/finance', 'Finance'),
    ('/finance/cashbook', 'Cashbook'),
    ('/finance/aging', 'Payables & Receivables'),
    ('/finance/statements', 'P&L & Statements'),
    ('/finance/franchise', 'Franchise Royalties'),
    ('/staff', 'Staff directory'),
    ('/staff/attendance', 'Attendance —'),
    ('/staff/shifts', 'Shifts —'),
    ('/staff/salary', 'Monthly total'),
    ('/notifications', 'Alerts computed from live demo data'),
    ('/settings', 'Roles & Permissions'),
    ('/branches', 'Add branch'),
    ('/branches/branch-dha-main', 'Franchise settings'),
    ('/audit-log', 'No audit entries match these filters.'),
    ('/backup', 'Backup status'),
  ];
}

/// The 47 routes as they render at phone width: same routes, but
/// the dashboard marker is the screen title ('Owner dashboard') —
/// the owner branch-comparison section is a wide layout and must not
/// be the phone marker.
Future<List<(String, String)>> _walkRoutesPhone(
  ProviderContainer container,
) async {
  final routes = await _walkRoutes(container);
  return [
    for (final (route, marker) in routes)
      if (route == '/dashboard') (route, 'Owner dashboard') else (route, marker),
  ];
}

void main() {
  group('D177 — desktop walk: D-01–D-35 (owner, 1920x1080)', () {
    testWidgets('D-01 login renders signed out (desktop)', (tester) async {
      final (_, _) = await _pumpSignedOut(tester);
      expect(find.text('Sign in'), findsOneWidget);
      expect(find.text('Owner'), findsWidgets);
      expect(find.text('Page not found'), findsNothing);
      expect(find.textContaining('coming Week 1'), findsNothing);
    });

    testWidgets('D-02–D-35 desktop walk: every screen resolves',
        (tester) async {
      final (container, router) = await pumpRouterApp(tester);
      await container
          .read(authProvider.notifier)
          .signInAsDemo(DemoRole.owner);
      await tester.pumpAndSettle();
      final routes = await _walkRoutes(container);
      expect(routes, hasLength(47));
      for (final (route, marker) in routes) {
        router.go(route);
        await tester.pumpAndSettle();
        expect(
          find.textContaining('coming Week 1'),
          findsNothing,
          reason: 'Placeholder left on $route',
        );
        expect(
          find.text('Page not found'),
          findsNothing,
          reason: 'Missing route $route',
        );
        expect(
          find.textContaining(marker),
          findsWidgets,
          reason: '$route should render its screen ($marker)',
        );
      }
      // D-11 / D-12 / D-13 / D-15 all live on /inventory: the
      // expiry radar (D-11, asserted in the walk), the low-stock
      // summary (D-12), the Receive stock action (D-13) and the
      // per-batch stock-count action (D-15).
      router.go('/inventory');
      await tester.pumpAndSettle();
      expect(find.textContaining('low stock'), findsWidgets);
      expect(find.text('Receive stock'), findsWidgets);
      expect(find.byTooltip('Stock count'), findsWidgets);
    });

    testWidgets('D-03 branch dashboard renders for branch_manager '
        '(no owner comparison)', (tester) async {
      final (_, router) = await pumpRouterAppAsRole(tester, 'branch_manager');
      expect(find.text('Branch dashboard'), findsOneWidget);
      expect(find.text('Branch comparison'), findsNothing);
      expect(find.text('Page not found'), findsNothing);
      // The branch dashboard is the same route as the owner one;
      // navigating away and back keeps the branch view.
      router.go('/billing');
      await tester.pumpAndSettle();
      router.go('/dashboard');
      await tester.pumpAndSettle();
      expect(find.text('Branch dashboard'), findsOneWidget);
    });

    testWidgets('D-29/D-30/D-31 settings tabs render their screens',
        (tester) async {
      final (container, router) = await pumpRouterApp(tester);
      await container.read(authProvider.notifier).signInAsDemo(DemoRole.owner);
      await tester.pumpAndSettle();
      router.go('/settings');
      await tester.pumpAndSettle();
      // D-29 Roles & Permissions: the capability table.
      await tester.tap(find.text('Roles & Permissions'));
      await tester.pumpAndSettle();
      expect(find.text('Capability'), findsWidgets);
      // D-30 Feature Modules: the module list (same titles as the
      // sidebar modules).
      await tester.tap(find.text('Features'));
      await tester.pumpAndSettle();
      expect(find.text('Billing & POS'), findsWidgets);
      // D-31 Brand Settings: the branding form + Fazal Din preset.
      await tester.tap(find.text('Branding'));
      await tester.pumpAndSettle();
      expect(find.text('Apply branding'), findsOneWidget);
      expect(find.text("Use Fazal Din's Pharma Plus"), findsOneWidget);
    });
  });

  group('D177 — mobile walk: M-01–M-24 (390x844, corrected trap)', () {
    testWidgets('M-01 login renders at 390px (trap)', (tester) async {
      final trap = _D39OverflowTrap();
      addTearDown(trap.dispose);
      final (_, _) = await _pumpSignedOut(tester, size: _phoneSize);
      expect(find.text('Sign in'), findsOneWidget);
      expect(find.text('Owner'), findsWidgets);
      expect(find.text('Page not found'), findsNothing);
      expect(trap.overflowCount, 0);
    });

    testWidgets('M-02–M-20 + M-22 mobile walk: every screen resolves '
        'at 390px (trap)', (tester) async {
      final trap = _D39OverflowTrap();
      addTearDown(trap.dispose);
      final (container, router) = await pumpRouterAppAsRole(
        tester,
        'owner',
        size: _phoneSize,
      );
      final routes = await _walkRoutesPhone(container);
      expect(routes, hasLength(47));
      for (final (route, marker) in routes) {
        router.go(route);
        await tester.pumpAndSettle();
        expect(
          find.textContaining('coming Week 1'),
          findsNothing,
          reason: 'Placeholder left on $route',
        );
        expect(
          find.text('Page not found'),
          findsNothing,
          reason: 'Missing route $route',
        );
        expect(
          find.textContaining(marker),
          findsWidgets,
          reason: '$route should render its screen at 390px ($marker)',
        );
      }
      expect(trap.overflowCount, 0);
    });

    testWidgets('M-03/M-04 role dashboards render at 390px (trap)',
        (tester) async {
      for (final roleKey in ['branch_manager', 'cashier']) {
        final trap = _D39OverflowTrap();
        addTearDown(trap.dispose);
        final (_, router) = await pumpRouterAppAsRole(
          tester,
          roleKey,
          size: _phoneSize,
        );
        expect(
          find.text('Branch dashboard'),
          findsOneWidget,
          reason: '$roleKey should see the branch dashboard',
        );
        expect(find.text('Branch comparison'), findsNothing);
        router.go('/billing');
        await tester.pumpAndSettle();
        expect(find.text('Page not found'), findsNothing);
        expect(trap.overflowCount, 0);
      }
    });

    testWidgets('M-21 branch switcher lists both branches and switches '
        'at 390px (trap)', (tester) async {
      final trap = _D39OverflowTrap();
      addTearDown(trap.dispose);
      final (container, _) = await pumpRouterAppAsRole(
        tester,
        'owner',
        size: _phoneSize,
      );
      expect(container.read(activeBranchProvider).id, _dha);
      await tester.tap(find.byKey(const ValueKey('branch-switcher-button')));
      await tester.pumpAndSettle();
      expect(find.text('Demo Branch — DHA'), findsWidgets);
      expect(find.text('Demo Branch — Gulberg'), findsWidgets);
      await tester.tap(find.text('Demo Branch — Gulberg').last);
      await tester.pumpAndSettle();
      expect(container.read(activeBranchProvider).id, _glb);
      expect(trap.overflowCount, 0);
    });

    testWidgets('M-23/M-24 optional modules are NOT built (O-11/O-2, '
        'BLOCKED-CLIENT)', (tester) async {
      final (_, router) = await pumpRouterAppAsRole(
        tester,
        'owner',
        size: _phoneSize,
      );
      // Neither the dashboard nor the settings screens claim a Live
      // Control Center or an AI Assistant anywhere.
      expect(find.textContaining('Live Control'), findsNothing);
      expect(find.textContaining('AI Assistant'), findsNothing);
      router.go('/settings');
      await tester.pumpAndSettle();
      // The tab bar is scrollable at 390px — the Features tab sits
      // past the viewport edge, so it must be scrolled into view
      // before it can be tapped.
      await tester.ensureVisible(find.text('Features'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Features'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Live Control'), findsNothing);
      expect(find.textContaining('AI Assistant'), findsNothing);
    });
  });

  group('D177 — buttons do what they say', () {
    testWidgets('inventory Receive stock opens the receive dialog',
        (tester) async {
      final (_, router) = await pumpRouterAppAsRole(tester, 'owner');
      router.go('/inventory');
      await tester.pumpAndSettle();
      // Two 'Receive stock' texts exist on this screen (the header
      // action and a per-batch action below it); the header action
      // is first in tree order and opens the receive dialog.
      await tester.ensureVisible(find.text('Receive stock').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Receive stock').first);
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Receive stock'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('stock count opens the count dialog from a batch row',
        (tester) async {
      final (_, router) = await pumpRouterAppAsRole(tester, 'owner');
      router.go('/inventory');
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byTooltip('Stock count').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Stock count').first);
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Stock count'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('purchase detail Receive goods opens the receive dialog',
        (tester) async {
      final (_, router) = await pumpRouterAppAsRole(tester, 'owner');
      router.go('/purchases/po-dha-1001');
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Receive goods'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Receive goods'));
      await tester.pumpAndSettle();
      expect(find.text('Receive goods — PO-DHA-1001'), findsOneWidget);
    });

    testWidgets('cashbook Add entry opens the add-entry dialog',
        (tester) async {
      final (_, router) = await pumpRouterAppAsRole(tester, 'owner');
      router.go('/finance/cashbook');
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Add entry'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add entry'));
      await tester.pumpAndSettle();
      expect(find.text('Add cashbook entry'), findsOneWidget);
    });

    testWidgets('prescription Approve approves immediately (snackbar)',
        (tester) async {
      // Review is pharmacist-only (SRS §5.1 rxReview): the Owner
      // sees the Approve button disabled, so this taps as the
      // pharmacist (home branch DHA, like rx-dha-1).
      final (_, router) = await pumpRouterAppAsRole(tester, 'pharmacist');
      router.go('/prescriptions/rx-dha-1');
      await tester.pumpAndSettle();
      // Approve applies at once (no dialog — the note dialog is
      // only for Reject); the snackbar confirms and the Approve
      // action is gone once the prescription is Approved. The
      // snackbar lives only 4s, so it is checked after a short
      // pump — a full pumpAndSettle would wait it out.
      await tester.ensureVisible(find.text('Approve'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Approve'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        find.textContaining('approved — linked orders can now be dispatched'),
        findsOneWidget,
      );
      await tester.pumpAndSettle();
      expect(find.text('Approve'), findsNothing);
    });

    testWidgets('notifications Mark all read clears the unread badge',
        (tester) async {
      final (_, router) = await pumpRouterAppAsRole(tester, 'owner');
      router.go('/notifications');
      await tester.pumpAndSettle();
      expect(find.text('Mark all read'), findsOneWidget);
      expect(find.textContaining('unread'), findsWidgets);
      await tester.ensureVisible(find.text('Mark all read'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mark all read'));
      await tester.pumpAndSettle();
      expect(find.text('All notifications read'), findsOneWidget);
    });

    testWidgets('order form Save Order validates an empty order',
        (tester) async {
      final (_, router) = await pumpRouterAppAsRole(tester, 'owner');
      router.go('/orders/new');
      await tester.pumpAndSettle();
      expect(find.text('Save Order'), findsOneWidget);
      await tester.ensureVisible(find.text('Save Order'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save Order'));
      await tester.pumpAndSettle();
      expect(find.text('Please fix the following:'), findsOneWidget);
    });

    testWidgets('unknown route shows Page not found with a working way '
        'back', (tester) async {
      final (_, router) = await pumpRouterAppAsRole(tester, 'owner');
      router.go('/no-such-screen');
      await tester.pumpAndSettle();
      expect(find.text('Page not found'), findsOneWidget);
      await tester.tap(find.text('Go to Dashboard'));
      await tester.pumpAndSettle();
      expect(find.text('Branch comparison'), findsOneWidget);
    });
  });

  group('D177 — D170 overflow fixes still in place (trap)', () {
    testWidgets('supplier detail screen fits at 390px (D170 badge + '
        'Export fixes)', (tester) async {
      final trap = _D39OverflowTrap();
      addTearDown(trap.dispose);
      final (_, router) = await pumpRouterAppAsRole(
        tester,
        'owner',
        size: _phoneSize,
      );
      router.go('/suppliers/sup-sami');
      await tester.pumpAndSettle();
      expect(find.textContaining('Sami'), findsWidgets);
      expect(find.text('Payable aging'), findsOneWidget);
      expect(find.text('Export statement (CSV)'), findsOneWidget);
      expect(trap.overflowCount, 0);
    });

    testWidgets('supplier detail with a large payable fits at 390px',
        (tester) async {
      final trap = _D39OverflowTrap();
      addTearDown(trap.dispose);
      final (_, router) = await pumpRouterAppAsRole(
        tester,
        'owner',
        size: _phoneSize,
      );
      router.go('/suppliers/sup-medserve');
      await tester.pumpAndSettle();
      expect(find.text('MedServe Distributors'), findsWidgets);
      expect(find.text('Payable aging'), findsOneWidget);
      expect(trap.overflowCount, 0);
    });

    testWidgets('/reports branch filter dropdown fits at 390px, open '
        '(D170 isExpanded fix)', (tester) async {
      final trap = _D39OverflowTrap();
      addTearDown(trap.dispose);
      final (_, router) = await pumpRouterAppAsRole(
        tester,
        'owner',
        size: _phoneSize,
      );
      router.go('/reports');
      await tester.pumpAndSettle();
      expect(find.text('Daily sales'), findsWidgets);
      final dropdown = find.byType(DropdownButton<String?>).first;
      await tester.ensureVisible(dropdown);
      await tester.pumpAndSettle();
      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      expect(find.text('Demo Branch — DHA'), findsWidgets);
      await tester.tap(find.text('Demo Branch — DHA').last);
      await tester.pumpAndSettle();
      expect(trap.overflowCount, 0);
    });

    testWidgets('supplier payment dialog fits at 390px (D170 method '
        'dropdown fix)', (tester) async {
      final trap = _D39OverflowTrap();
      addTearDown(trap.dispose);
      final (_, router) = await pumpRouterAppAsRole(
        tester,
        'owner',
        size: _phoneSize,
      );
      router.go('/suppliers/sup-medserve');
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Record payment'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Record payment'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Record payment'),
        ),
        findsOneWidget,
      );
      final method =
          find.byType(DropdownButtonFormField<SupplierPaymentMethod>);
      expect(method, findsWidgets);
      await tester.tap(method.first);
      await tester.pumpAndSettle();
      expect(find.text('Cash'), findsWidgets);
      expect(trap.overflowCount, 0);
    });

    testWidgets('/branches list rows fit at 390px (D170 Wrap fix)',
        (tester) async {
      final trap = _D39OverflowTrap();
      addTearDown(trap.dispose);
      final (_, router) = await pumpRouterAppAsRole(
        tester,
        'owner',
        size: _phoneSize,
      );
      router.go('/branches');
      await tester.pumpAndSettle();
      expect(find.text('Branch Management'), findsWidgets);
      expect(find.text('Demo Branch — DHA'), findsWidgets);
      expect(trap.overflowCount, 0);
    });

    testWidgets('sales history paged list fits at 390px (D170 '
        'PagedListControls Wrap fix)', (tester) async {
      final trap = _D39OverflowTrap();
      addTearDown(trap.dispose);
      final (_, router) = await pumpRouterAppAsRole(
        tester,
        'owner',
        size: _phoneSize,
      );
      router.go('/billing/history');
      await tester.pumpAndSettle();
      expect(find.text('Sales history'), findsWidgets);
      expect(trap.overflowCount, 0);
    });
  });

  group('D177 — fresh full 390px sweep (corrected trap)', () {
    testWidgets('all 47 routes: 0 distinct overflows at 390px',
        (tester) async {
      final trap = _D39OverflowTrap();
      addTearDown(trap.dispose);
      final (container, router) = await pumpRouterAppAsRole(
        tester,
        'owner',
        size: _phoneSize,
      );
      final routes = await _walkRoutesPhone(container);
      expect(routes, hasLength(47));
      for (final (route, _) in routes) {
        router.go(route);
        await tester.pumpAndSettle();
        expect(
          find.text('Page not found'),
          findsNothing,
          reason: 'Missing route $route at 390px',
        );
        expect(
          find.textContaining('coming Week 1'),
          findsNothing,
          reason: 'Placeholder left on $route at 390px',
        );
      }
      expect(
        trap.overflowCount,
        0,
        reason: 'distinct RenderFlex overflows at 390px (corrected trap)',
      );
    });
  });
}
