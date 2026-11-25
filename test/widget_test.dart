// PharmaDesk smoke tests — Week 1 Day 1 foundation + Day 2 shell +
// Day 3 auth flow.
//
// Verifies each entry point's app widget builds without errors. Firebase is
// not initialised in these shells yet (no project exists), so no Firebase
// mocking is needed at this stage. Screens run on mock repositories.
// Day 3: each app starts on the splash screen and routes to login, so
// these tests sign in with the Owner demo account before asserting on
// the shell.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharmadesk/app/admin_app.dart';
import 'package:pharmadesk/app/customer_app.dart';
import 'package:pharmadesk/app/desktop_app.dart';
import 'package:pharmadesk/app/pharmadesk_app.dart';

import 'test_helpers.dart';

void main() {
  testWidgets('PharmaDesk staff app builds with the Day 2 shell',
      (WidgetTester tester) async {
    await pumpAppToLogin(tester, const PharmaDeskApp());
    await signInAsDemoRole(tester, 'Owner');
    // Mobile layout at the default 800x600 test size: top bar shows the
    // brand and the active demo branch; bottom nav shows the modules.
    expect(find.text('PharmaDesk'), findsWidgets);
    expect(find.text('Demo Branch — DHA'), findsWidgets);
    expect(find.text('Dashboard'), findsWidgets);
    // 'Orders' appears twice on the owner dashboard: the bottom-nav
    // label and the Recent orders card's action button.
    expect(find.text('Orders'), findsWidgets);
    // Bottom-nav navigation works: Orders opens the real queue screen.
    await tester.tap(
      find.descendant(
        of: find.byType(BottomNavigationBar),
        matching: find.text('Orders'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Orders'), findsWidgets);
    expect(find.text('New Order'), findsOneWidget);
    expect(find.textContaining('ord-dha-'), findsWidgets);
  });

  testWidgets('Legacy customer shell is flagged for conversion',
      (WidgetTester tester) async {
    await tester.pumpWidget(const CustomerApp());
    expect(find.text('FLAGGED FOR CONVERSION'), findsOneWidget);
    expect(find.text('PharmaDesk — Staff'), findsOneWidget);
  });

  testWidgets('Admin web panel builds with the Day 2 shell',
      (WidgetTester tester) async {
    await pumpAppToLogin(tester, const AdminApp());
    await signInAsDemoRole(tester, 'Owner');
    expect(find.text('PharmaDesk'), findsWidgets);
    expect(find.text('Demo Branch — DHA'), findsWidgets);
    expect(find.text('Dashboard'), findsWidgets);
  });

  testWidgets('Windows desktop shell builds with the Day 2 shell',
      (WidgetTester tester) async {
    await pumpAppToLogin(tester, const DesktopApp());
    await signInAsDemoRole(tester, 'Owner');
    expect(find.text('PharmaDesk'), findsWidgets);
    expect(find.text('Demo Branch — DHA'), findsWidgets);
    expect(find.text('Dashboard'), findsWidgets);
  });
}
