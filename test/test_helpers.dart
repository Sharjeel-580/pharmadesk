// Shared widget-test helpers for the PharmaDesk Week 1 sprint.
//
// The app starts on the splash screen, which shows an indeterminate
// spinner — `pumpAndSettle` alone would never finish while it is
// visible, so these helpers advance the fake clock past the splash
// delay first, then settle.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pumps [app] and advances past the splash screen to the login screen.
Future<void> pumpAppToLogin(WidgetTester tester, Widget app) async {
  await tester.pumpWidget(ProviderScope(child: app));
  await tester.pump(const Duration(milliseconds: 1500));
  await tester.pumpAndSettle();
  expect(find.text('Sign in'), findsOneWidget);
}

/// Taps a demo-account card (by role label, e.g. 'Owner') on the login
/// screen and waits for the dashboard to load. Scrolls the card into
/// view first: on a phone-sized screen the demo cards sit below the
/// fold of the scrollable login form.
///
/// `ensureVisible` (not `scrollUntilVisible`) is used: the login form's
/// text fields each contain their own Scrollable, so the default
/// `find.byType(Scrollable)` in `scrollUntilVisible` matches several
/// scrollables and throws.
Future<void> signInAsDemoRole(WidgetTester tester, String roleLabel) async {
  await tester.ensureVisible(find.text(roleLabel));
  await tester.pumpAndSettle();
  await tester.tap(find.text(roleLabel));
  await tester.pumpAndSettle();
}
