// Week 4 Day 1 tests — responsive top bar (D116).
//
// At a 390px viewport the shared shell top bar overflowed by 236px on
// the right (Week 3 Day 5 QA finding, D116): brand mark + app name +
// branch switcher (up to 180px) + DEMO MODE badge + three icon buttons
// did not fit. Every shell screen was affected because the top bar is
// shared; it was never caught before because every mobile test ran at
// 800px wide.
//
// The fix (D117): below ~600px the top bar hides the app-name text,
// shrinks the branch-switcher cap, and compacts the icon buttons —
// while the DEMO MODE badge stays visible on every screen (SRS §8.2)
// and the desktop layout (≥900px) is unchanged.
//
// These tests assert TOP-BAR fit only: each top-bar widget's rect must
// sit inside the 390px viewport. Screen-BODY overflows at 390px are
// deliberately NOT asserted here — they are recorded as findings for
// the Day 5 sweep (see the route-walk test, which drains and logs
// them instead of failing on them).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:pharmadesk/core/routing/app_router.dart';
import 'package:pharmadesk/core/theme/app_theme.dart';
import 'package:pharmadesk/core/theme/white_label.dart';
import 'package:pharmadesk/features/authentication/auth_state.dart';

/// Phone viewport used by every test here (iPhone 12/13/14 width).
const _phoneSize = Size(390, 844);

/// Pumps the ungated router app with a fresh container the test owns
/// (same harness as the Week 3 Day 4 / Day 5 widget tests), signed in
/// as the Owner.
Future<(ProviderContainer, GoRouter)> pumpRouterApp(
  WidgetTester tester, {
  Size size = const Size(1920, 1080),
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final container = ProviderContainer();
  addTearDown(container.dispose);
  await container.read(authProvider.notifier).signInAsDemo(DemoRole.owner);
  final router = createAppRouter();
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

/// Drains any exceptions the binding recorded during pumping (e.g.
/// RenderFlex overflows from the screen BODY at 390px) and returns
/// their first lines. Callers that assert top-bar fit only use this
/// so a body overflow — out of scope for Day 1, a Day 5 sweep finding
/// — does not fail the test; the messages are logged and recorded in
/// `docs/day-18-progress.md` instead.
List<String> drainExceptions(WidgetTester tester) {
  final messages = <String>[];
  Object? error;
  while ((error = tester.takeException()) != null) {
    messages.add(error.toString().split('\n').first);
  }
  return messages;
}

/// Asserts every top-bar widget sits inside the viewport: this is the
/// D116 symptom made precise — before the fix the row overflows by
/// 236px on the right, so the badge and the icon buttons sit past the
/// right edge.
void expectTopBarFits(WidgetTester tester, {double width = 390}) {
  final items = <String, Finder>{
    'branch switcher':
        find.byKey(const ValueKey('branch-switcher-button')),
    'DEMO MODE badge': find.text('DEMO MODE'),
    'theme button': find.byKey(const ValueKey('theme-menu-button')),
    'notifications button':
        find.byKey(const ValueKey('notifications-button')),
    'profile button': find.byKey(const ValueKey('profile-button')),
  };
  for (final entry in items.entries) {
    expect(entry.value, findsOneWidget, reason: '${entry.key} missing');
    final rect = tester.getRect(entry.value);
    expect(
      rect.left,
      greaterThanOrEqualTo(-0.5),
      reason: '${entry.key} off the left edge: $rect',
    );
    expect(
      rect.right,
      lessThanOrEqualTo(width + 0.5),
      reason:
          '${entry.key} overflows the right edge: $rect (viewport $width)',
    );
  }
}

void main() {
  group('Top bar at 390px (D116/D117)', () {
    testWidgets('dashboard top bar fits within the 390px viewport',
        (WidgetTester tester) async {
      await pumpRouterApp(tester, size: _phoneSize);
      drainExceptions(tester);

      expectTopBarFits(tester);
      // The DEMO MODE badge stays visible (SRS §8.2) — never hidden
      // or shrunk away by the responsive pass.
      expect(find.text('DEMO MODE'), findsOneWidget);
      // The app-name text is hidden below ~600px (the brand-mark
      // initial tile stays); no other screen text reads 'PharmaDesk'
      // on the dashboard, so findsNothing pins the top bar itself.
      expect(find.text('PharmaDesk'), findsNothing);
      // The branch switcher is capped small at phone width (its
      // pre-fix rect was ~242px wide with the 180px name cap).
      final switcherRect = tester.getRect(
        find.byKey(const ValueKey('branch-switcher-button')),
      );
      expect(
        switcherRect.width,
        lessThanOrEqualTo(140),
        reason: 'switcher still too wide at 390px: $switcherRect',
      );
    });

    testWidgets('orders screen top bar fits at 390px',
        (WidgetTester tester) async {
      final (_, router) = await pumpRouterApp(tester, size: _phoneSize);
      router.go('/orders');
      await tester.pumpAndSettle();
      drainExceptions(tester);

      expectTopBarFits(tester);
      expect(find.text('DEMO MODE'), findsOneWidget);
    });

    testWidgets('branch switcher still opens and switches at 390px',
        (WidgetTester tester) async {
      await pumpRouterApp(tester, size: _phoneSize);
      drainExceptions(tester);

      await tester.tap(find.byKey(const ValueKey('branch-switcher-button')));
      await tester.pumpAndSettle();
      // Scoped to the popup menu: the dashboard body lists the other
      // branch name too, so a bare text finder matches twice.
      // (byType matches the exact reified type — PopupMenuItem<String>.)
      final gulbergMenuEntry = find.ancestor(
        of: find.text('Demo Branch — Gulberg'),
        matching: find.byType(PopupMenuItem<String>),
      );
      expect(gulbergMenuEntry, findsOneWidget);

      await tester.tap(gulbergMenuEntry);
      await tester.pumpAndSettle();
      drainExceptions(tester);

      // The switcher now shows the Gulberg branch (truncated text
      // still carries the full branch name) and the bar still fits.
      // Scoped to the switcher: the dashboard body shows the active
      // branch name too.
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('branch-switcher-button')),
          matching: find.text('Demo Branch — Gulberg'),
        ),
        findsOneWidget,
      );
      expectTopBarFits(tester);
    });

    testWidgets(
        'theme, notifications and profile buttons present and tappable at 390px',
        (WidgetTester tester) async {
      final (_, router) = await pumpRouterApp(tester, size: _phoneSize);
      drainExceptions(tester);

      // Notifications bell navigates to the notifications center.
      await tester.tap(find.byKey(const ValueKey('notifications-button')));
      await tester.pumpAndSettle();
      expect(find.text('Notifications'), findsWidgets);

      // Theme menu opens and offers the theme choices.
      router.go('/dashboard');
      await tester.pumpAndSettle();
      drainExceptions(tester);
      await tester.tap(find.byKey(const ValueKey('theme-menu-button')));
      await tester.pumpAndSettle();
      expect(find.text('Dark'), findsOneWidget);
      await tester.tap(find.text('Dark'));
      await tester.pumpAndSettle();
      drainExceptions(tester);

      // Profile menu opens and offers sign-out.
      await tester.tap(find.byKey(const ValueKey('profile-button')));
      await tester.pumpAndSettle();
      expect(find.text('Sign out'), findsOneWidget);
      expectTopBarFits(tester);
    });

    testWidgets('desktop top bar unchanged at 1280px',
        (WidgetTester tester) async {
      await pumpRouterApp(tester, size: const Size(1280, 800));
      drainExceptions(tester);

      // Full desktop layout: the app name is shown (top bar and
      // sidebar) and the branch switcher keeps its wide cap.
      expect(find.text('PharmaDesk'), findsWidgets);
      expect(find.text('DEMO MODE'), findsOneWidget);
      final switcherRect = tester.getRect(
        find.byKey(const ValueKey('branch-switcher-button')),
      );
      expect(
        switcherRect.width,
        greaterThanOrEqualTo(170),
        reason: 'desktop switcher shrank unexpectedly: $switcherRect',
      );
      expectTopBarFits(tester, width: 1280);
    });
  });

  group('390px route walk: top bar on every primary shell route', () {
    testWidgets('dashboard, orders, billing, medicines, inventory',
        (WidgetTester tester) async {
      final (_, router) = await pumpRouterApp(tester, size: _phoneSize);
      final bodyFindings = <String, List<String>>{};
      for (final route in [
        '/dashboard',
        '/orders',
        '/billing',
        '/medicines',
        '/inventory',
      ]) {
        router.go(route);
        await tester.pumpAndSettle();
        final exceptions = drainExceptions(tester);
        if (exceptions.isNotEmpty) {
          bodyFindings[route] = exceptions;
        }
        expectTopBarFits(tester);
        expect(
          find.text('DEMO MODE'),
          findsOneWidget,
          reason: 'badge missing on $route',
        );
      }
      // Body overflows at 390px are Day 5 sweep findings, not Day 1
      // failures — but they are logged here so the progress doc can
      // record them exactly as observed.
      if (bodyFindings.isNotEmpty) {
        debugPrint('390px BODY OVERFLOW FINDINGS (Day 5 sweep): $bodyFindings');
      }
    });
  });
}
