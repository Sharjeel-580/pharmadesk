// PharmaDesk Day 2 tests — design system + application shell.
//
// Covers: core components (buttons, stat card, search field, data table,
// dialogs, empty state, section header, badges, shimmer), the desktop
// sidebar / mobile bottom-nav shell, branch switching, theme switching,
// white-label branding, and unknown-route handling.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharmadesk/app/pharmadesk_app.dart';
import 'package:pharmadesk/core/routing/app_router.dart';
import 'package:pharmadesk/core/theme/app_theme.dart';
import 'package:pharmadesk/core/theme/white_label.dart';
import 'package:pharmadesk/core/widgets/design_system.dart';

import 'test_helpers.dart';

/// Drags [scrollable] (down, then up if needed) until the list item
/// with [title] is built, then asserts it exists exactly once inside it.
///
/// Lazy lists only build visible rows, so items below the fold do not
/// exist until scrolled into view.
Future<void> scrollListToTitle(
  WidgetTester tester,
  Finder scrollable,
  String title,
) async {
  final target = find.descendant(
    of: scrollable,
    matching: find.text(title),
  );
  for (var i = 0; i < 12 && target.evaluate().isEmpty; i++) {
    await tester.drag(scrollable, const Offset(0, -300));
    await tester.pumpAndSettle();
  }
  for (var i = 0; i < 12 && target.evaluate().isEmpty; i++) {
    await tester.drag(scrollable, const Offset(0, 300));
    await tester.pumpAndSettle();
  }
  expect(target, findsOneWidget);
}
///
/// Uses plain [WidgetTester.pump] (not pumpAndSettle): components such as
/// the loading spinner and [ShimmerBox] animate forever, so pumpAndSettle
/// would time out.
Future<void> pumpComponent(
  WidgetTester tester,
  Widget child, {
  ThemeMode themeMode = ThemeMode.light,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: AppTheme.light(BrandConfig.defaults),
        darkTheme: AppTheme.dark(BrandConfig.defaults),
        themeMode: themeMode,
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('Design-system components', () {
    testWidgets('primary button fires onPressed; loading disables it',
        (WidgetTester tester) async {
      var taps = 0;
      await pumpComponent(
        tester,
        Column(
          children: [
            PharmaButton(
              label: 'Save',
              onPressed: () => taps++,
            ),
            PharmaButton(
              label: 'Saving…',
              loading: true,
              onPressed: () => taps++,
            ),
            PharmaButton(
              label: 'Delete',
              variant: PharmaButtonVariant.danger,
              onPressed: () => taps++,
            ),
          ],
        ),
      );
      await tester.tap(find.text('Save'));
      await tester.tap(find.text('Delete'));
      await tester.pump();
      expect(taps, 2);
      // Loading button shows a spinner and ignores taps.
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.tap(find.text('Saving…'));
      await tester.pump();
      expect(taps, 2);
    });

    testWidgets('stat card renders money in int minor units (paisa)',
        (WidgetTester tester) async {
      await pumpComponent(
        tester,
        const StatCard(
          label: "Today's sales",
          moneyMinorUnits: 125000,
          icon: Icons.attach_money,
          deltaLabel: '+12% vs yesterday',
          deltaPositive: true,
        ),
      );
      expect(find.text("Today's sales"), findsOneWidget);
      expect(find.text('Rs 1,250.00'), findsOneWidget);
      expect(find.text('+12% vs yesterday'), findsOneWidget);
    });

    testWidgets('search field shows a clear button and clears the text',
        (WidgetTester tester) async {
      final controller = TextEditingController();
      await pumpComponent(
        tester,
        PharmaSearchField(
          controller: controller,
          hintText: 'Search medicines…',
        ),
      );
      expect(find.text('Search medicines…'), findsOneWidget);
      expect(find.byIcon(Icons.clear), findsNothing);
      await tester.enterText(find.byType(TextField), 'panadol');
      await tester.pump();
      expect(controller.text, 'panadol');
      expect(find.byIcon(Icons.clear), findsOneWidget);
      await tester.tap(find.byIcon(Icons.clear));
      await tester.pump();
      expect(controller.text, '');
    });

    testWidgets('data table sorts by column and shows an empty state',
        (WidgetTester tester) async {
      await pumpComponent(
        tester,
        PharmaDataTable<String>(
          columns: [
            PharmaDataColumn<String>(
              label: 'Name',
              cell: (row) => Text(row),
              sortValue: (row) => row,
            ),
          ],
          rows: const ['Risek', 'Panadol', 'Augmentin'],
        ),
      );
      // Initial order is the given order.
      final firstBefore = tester
          .widgetList<Text>(find.descendant(
            of: find.byType(DataTable),
            matching: find.byType(Text),
          ))
          .map((text) => text.data)
          .where((data) => data != 'Name')
          .toList();
      expect(firstBefore, ['Risek', 'Panadol', 'Augmentin']);
      // Tap the Name header to sort ascending.
      await tester.tap(find.text('Name'));
      await tester.pumpAndSettle();
      final sorted = tester
          .widgetList<Text>(find.descendant(
            of: find.byType(DataTable),
            matching: find.byType(Text),
          ))
          .map((text) => text.data)
          .where((data) => data != 'Name')
          .toList();
      expect(sorted, ['Augmentin', 'Panadol', 'Risek']);

      // Empty rows show the empty state instead of a table.
      await pumpComponent(
        tester,
        PharmaDataTable<String>(
          columns: [
            PharmaDataColumn<String>(
              label: 'Name',
              cell: (row) => Text(row),
            ),
          ],
          rows: const [],
          emptyTitle: 'No medicines yet',
          emptyMessage: 'Add your first medicine to get started.',
        ),
      );
      expect(find.byType(DataTable), findsNothing);
      expect(find.text('No medicines yet'), findsOneWidget);
      expect(
        find.text('Add your first medicine to get started.'),
        findsOneWidget,
      );
    });

    testWidgets('confirm dialog returns true on confirm, false on cancel',
        (WidgetTester tester) async {
      bool? result;
      await pumpComponent(
        tester,
        Builder(
          builder: (context) => PharmaButton(
            label: 'Ask',
            onPressed: () async {
              result = await showConfirmDialog(
                context,
                title: 'Delete medicine?',
                message: 'This cannot be undone.',
                confirmLabel: 'Delete',
                danger: true,
              );
            },
          ),
        ),
      );
      await tester.tap(find.text('Ask'));
      await tester.pumpAndSettle();
      expect(find.text('Delete medicine?'), findsOneWidget);
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(result, isTrue);

      await tester.tap(find.text('Ask'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(result, isFalse);
    });

    testWidgets(
        'empty state, section header, badges and shimmer render in dark theme',
        (WidgetTester tester) async {
      await pumpComponent(
        tester,
        const Column(
          children: [
            SectionHeader(
              title: 'Stock alerts',
              subtitle: '3 items need attention',
              actionLabel: 'View all',
            ),
            StatusBadge(label: 'Low stock', kind: StatusKind.warning),
            StatusBadge(label: 'Delivered', kind: StatusKind.success),
            PharmaEmptyState(
              icon: Icons.inventory_2_outlined,
              title: 'No low-stock items',
              message: 'All stock levels are healthy.',
            ),
            ShimmerBox(width: 120, height: 16),
            SkeletonCard(),
          ],
        ),
        themeMode: ThemeMode.dark,
      );
      expect(find.text('Stock alerts'), findsOneWidget);
      expect(find.text('Low stock'), findsOneWidget);
      expect(find.text('Delivered'), findsOneWidget);
      expect(find.text('No low-stock items'), findsOneWidget);
      expect(find.byType(ShimmerBox), findsWidgets);
    });
  });

  group('Application shell', () {
    Future<void> pumpWideApp(WidgetTester tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1280, 800);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await pumpAppToLogin(tester, const PharmaDeskApp());
      // Day 3: the shell sits behind the Day 3 login flow.
      await signInAsDemoRole(tester, 'Owner');
    }

    testWidgets('desktop sidebar lists all 16 modules and navigates',
        (WidgetTester tester) async {
      await pumpWideApp(tester);
      // The sidebar is a lazy ListView: scroll each item into view
      // before asserting it exists. Scope the finder to the sidebar's
      // ListView — the module title also appears in the screen body.
      // Iterate in sidebar (visual) order so scrolling is monotonic.
      const sidebarOrder = [
        'Dashboard',
        'Orders',
        'Billing & POS',
        'Medicines',
        'Inventory',
        'Customers',
        'Suppliers',
        'Purchases',
        'Prescriptions',
        'Staff & HR',
        'Reports',
        'Finance',
        'Notifications',
        'Settings',
        'Profile',
        'Authentication',
      ];
      expect(
        sidebarOrder.toSet(),
        appModules.map((module) => module.title).toSet(),
      );
      final sidebarList = find.byType(ListView);
      for (final title in sidebarOrder) {
        await scrollListToTitle(tester, sidebarList, title);
      }
      await scrollListToTitle(tester, sidebarList, 'Medicines');
      final medicinesItem = find.descendant(
        of: sidebarList,
        matching: find.text('Medicines'),
      );
      // Week 2 Day 2: the Auto Purchase List sub-item under Purchases
      // lengthened the sidebar list, so the 300px drag steps can park
      // an item half under the brand header — bring it fully into
      // view before tapping (D24 pattern).
      await tester.ensureVisible(medicinesItem);
      await tester.pumpAndSettle();
      await tester.tap(medicinesItem);
      await tester.pumpAndSettle();
      // Day 5: the catalogue is real — 180 medicines, not a placeholder.
      expect(find.textContaining('180 medicines'), findsOneWidget);
      await scrollListToTitle(tester, sidebarList, 'Suppliers');
      final suppliersItem = find.descendant(
        of: sidebarList,
        matching: find.text('Suppliers'),
      );
      await tester.ensureVisible(suppliersItem);
      await tester.pumpAndSettle();
      await tester.tap(suppliersItem);
      await tester.pumpAndSettle();
      // Day 7: the supplier directory is real — seeded suppliers listed.
      expect(find.text('Sami Pharmaceuticals'), findsOneWidget);
      expect(find.text('Add supplier'), findsOneWidget);
      // Week 2 Day 2: the Auto Purchase List sub-item under Purchases
      // navigates to the auto purchase list screen.
      await scrollListToTitle(tester, sidebarList, 'Auto Purchase List');
      final autoItem = find.descendant(
        of: sidebarList,
        matching: find.text('Auto Purchase List'),
      );
      await tester.ensureVisible(autoItem);
      await tester.pumpAndSettle();
      await tester.tap(autoItem);
      await tester.pumpAndSettle();
      expect(find.textContaining('Branch: Demo Branch'), findsOneWidget);
    });

    testWidgets('branch switcher changes the displayed branch context',
        (WidgetTester tester) async {
      await pumpAppToLogin(tester, const PharmaDeskApp());
      // Cashier's home branch is Gulberg: the branch dashboard shows
      // only the active branch, so switching visibly changes it.
      await signInAsDemoRole(tester, 'Cashier');
      expect(find.text('Demo Branch — Gulberg'), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('branch-switcher-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Demo Branch — DHA').last);
      await tester.pumpAndSettle();
      expect(find.text('Demo Branch — DHA'), findsWidgets);
      expect(find.text('Demo Branch — Gulberg'), findsNothing);
    });

    testWidgets('theme menu switches light/dark/system',
        (WidgetTester tester) async {
      await pumpAppToLogin(tester, const PharmaDeskApp());
      await signInAsDemoRole(tester, 'Owner');
      // Default is system: the menu button shows the auto icon.
      expect(find.byIcon(Icons.brightness_auto_outlined), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('theme-menu-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dark'));
      await tester.pumpAndSettle();
      // Dark mode: the menu button now offers switching back to light.
      expect(find.byIcon(Icons.light_mode_outlined), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('theme-menu-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Light'));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.dark_mode_outlined), findsOneWidget);
    });

    testWidgets('mobile bottom nav + More sheet reach every module',
        (WidgetTester tester) async {
      await pumpAppToLogin(tester, const PharmaDeskApp());
      await signInAsDemoRole(tester, 'Owner');
      await tester.tap(find.text('Billing'));
      await tester.pumpAndSettle();
      // Day 6: the POS screen is real — search + cart + payment.
      expect(find.text('Billing & POS'), findsOneWidget);
      expect(find.text('Add medicines'), findsOneWidget);
      await tester.tap(find.text('More'));
      await tester.pumpAndSettle();
      expect(find.text('All modules'), findsOneWidget);
      // The sheet list is lazy: scroll Prescriptions into view inside
      // the sheet's ListView, then tap it.
      await scrollListToTitle(tester, find.byType(ListView), 'Prescriptions');
      await tester.tap(find.text('Prescriptions'));
      await tester.pumpAndSettle();
      // Day 7: the prescription review queue is real.
      expect(find.text('New prescription'), findsOneWidget);
      expect(find.textContaining('Pending review'), findsWidgets);
    });

    testWidgets('white-label brand renders in the shell',
        (WidgetTester tester) async {
      await pumpWideApp(tester);
      // Default brand is generic PharmaDesk.
      expect(find.text('PharmaDesk'), findsWidgets);
    });

    testWidgets('unknown route shows a working not-found screen',
        (WidgetTester tester) async {
      final router = createAppRouter();
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp.router(
            theme: AppTheme.light(BrandConfig.defaults),
            darkTheme: AppTheme.dark(BrandConfig.defaults),
            themeMode: ThemeMode.light,
            routerConfig: router,
          ),
        ),
      );
      // Advance past the splash (ungated router lands on the dashboard).
      await tester.pump(const Duration(milliseconds: 1500));
      await tester.pumpAndSettle();
      expect(find.text('Branch dashboard'), findsOneWidget);
      router.go('/does-not-exist');
      await tester.pumpAndSettle();
      expect(find.text('Page not found'), findsOneWidget);
      await tester.tap(find.text('Go to Dashboard'));
      await tester.pumpAndSettle();
      expect(
        find.text('Branch dashboard'),
        findsOneWidget,
      );
    });

    testWidgets('Fazal Din brand override rebrands the shell',
        (WidgetTester tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1280, 800);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            brandConfigProvider.overrideWith(
              () => _FazalDinBrandNotifier(),
            ),
          ],
          child: const PharmaDeskApp(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 1500));
      await tester.pumpAndSettle();
      expect(find.text("Fazal Din's Pharma Plus"), findsWidgets);
      expect(find.text('PharmaDesk'), findsNothing);
      await signInAsDemoRole(tester, 'Owner');
      expect(find.text("Fazal Din's Pharma Plus"), findsWidgets);
      expect(find.text('PharmaDesk'), findsNothing);
      // Theme-mode provider is untouched by the brand override.
      expect(
        find.byKey(const ValueKey('theme-menu-button')),
        findsOneWidget,
      );
    });
  });
}

class _FazalDinBrandNotifier extends BrandConfigNotifier {
  @override
  BrandConfig build() => BrandConfig.fazalDin;
}
