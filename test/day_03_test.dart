// PharmaDesk Day 3 tests — auth (splash / login / forgot password /
// demo login), owner & branch dashboards, KPI computation, DEMO MODE
// badge, seed data.
//
// The app starts on the splash screen (see test_helpers.dart for why
// the pump helper advances the clock past it first).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharmadesk/app/pharmadesk_app.dart';
import 'package:pharmadesk/core/routing/app_router.dart';
import 'package:pharmadesk/core/services/branch_context.dart';
import 'package:pharmadesk/core/services/demo_seed_data.dart';
import 'package:pharmadesk/core/services/repositories.dart';
import 'package:pharmadesk/core/theme/app_theme.dart';
import 'package:pharmadesk/core/theme/white_label.dart';
import 'package:pharmadesk/core/utils/money.dart';
import 'package:pharmadesk/features/authentication/auth_state.dart';
import 'package:pharmadesk/features/dashboard/dashboard_data.dart';
import 'package:pharmadesk/models/inventory_item.dart';
import 'package:pharmadesk/models/order.dart';
import 'package:pharmadesk/models/prescription.dart';

import 'test_helpers.dart';

void main() {
  group('Mock auth (provider)', () {
    late ProviderContainer container;

    setUp(() {
      container = ProviderContainer();
    });

    tearDown(() {
      container.dispose();
    });

    test('valid email/password signs in as Owner', () {
      final error = container
          .read(authProvider.notifier)
          .signIn('owner@demo.pharmadesk', 'demo1234');
      expect(error, isNull);
      final user = container.read(authProvider);
      expect(user, isNotNull);
      expect(user!.role, DemoRole.owner);
      expect(user.name, 'Hassan Raza');
      expect(user.branchId, isNull);
      expect(user.seesAllBranches, isTrue);
    });

    test('wrong password and unknown email fail without signing in', () {
      final notifier = container.read(authProvider.notifier);
      expect(
        notifier.signIn('owner@demo.pharmadesk', 'wrongpass'),
        'Incorrect password for this demo account.',
      );
      expect(container.read(authProvider), isNull);
      expect(
        notifier.signIn('nobody@demo.pharmadesk', 'demo1234'),
        'No demo account found for this email.',
      );
      expect(container.read(authProvider), isNull);
    });

    test('one-tap demo sign-in works for all five roles', () {
      final notifier = container.read(authProvider.notifier);
      const expectedBranch = {
        DemoRole.owner: null,
        DemoRole.branchManager: 'branch-dha-main',
        DemoRole.pharmacist: 'branch-dha-main',
        DemoRole.cashier: 'branch-demo-gulberg',
        DemoRole.inventoryManager: 'branch-demo-gulberg',
      };
      for (final role in DemoRole.values) {
        notifier.signInAsDemo(role);
        final user = container.read(authProvider);
        expect(user, isNotNull);
        expect(user!.role, role);
        expect(user.email, role.email);
        expect(user.branchId, expectedBranch[role]);
        notifier.signOut();
        expect(container.read(authProvider), isNull);
      }
    });

    test('demo sign-in moves branch-scoped roles to their home branch',
        () {
      final notifier = container.read(authProvider.notifier);
      // Start on DHA, sign in as the Gulberg cashier.
      container.read(activeBranchProvider.notifier).switchTo('branch-dha-main');
      notifier.signInAsDemo(DemoRole.cashier);
      expect(
        container.read(activeBranchProvider).id,
        'branch-demo-gulberg',
      );
      // Owner keeps whichever branch was active.
      notifier.signInAsDemo(DemoRole.owner);
      expect(
        container.read(activeBranchProvider).id,
        'branch-demo-gulberg',
      );
    });

    test('forgot-password flow: code, wrong code, reset, new password',
        () {
      final notifier = container.read(authProvider.notifier);
      expect(
        notifier.requestPasswordReset('nobody@demo.pharmadesk'),
        isNull,
      );
      final code = notifier.requestPasswordReset('owner@demo.pharmadesk');
      expect(code, isNotNull);
      expect(code!.length, 6);
      expect(int.tryParse(code), isNotNull);
      // Deterministic: same email always yields the same code.
      expect(
        AuthNotifier.resetCodeFor('owner@demo.pharmadesk'),
        code,
      );
      expect(
        notifier.resetPassword(
          email: 'owner@demo.pharmadesk',
          code: '000000',
          newPassword: 'newpass123',
        ),
        contains('incorrect'),
      );
      expect(
        notifier.resetPassword(
          email: 'owner@demo.pharmadesk',
          code: code,
          newPassword: 'short',
        ),
        contains('at least 6 characters'),
      );
      expect(
        notifier.resetPassword(
          email: 'owner@demo.pharmadesk',
          code: code,
          newPassword: 'newpass123',
        ),
        isNull,
      );
      // The new password signs in; the old one no longer does.
      expect(
        notifier.signIn('owner@demo.pharmadesk', 'demo1234'),
        isNotNull,
      );
      expect(
        notifier.signIn('owner@demo.pharmadesk', 'newpass123'),
        isNull,
      );
    });
  });

  group('Splash + login screens', () {
    testWidgets('splash shows brand + DEMO MODE, then routes to login',
        (WidgetTester tester) async {
      await tester.pumpWidget(const ProviderScope(child: PharmaDeskApp()));
      await tester.pump();
      expect(find.text('PharmaDesk'), findsWidgets);
      expect(find.text('DEMO MODE'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      // Still on the splash before the delay elapses.
      expect(find.text('Sign in'), findsNothing);
      await tester.pump(const Duration(milliseconds: 1500));
      await tester.pumpAndSettle();
      expect(find.text('Sign in'), findsOneWidget);
      expect(find.text('DEMO MODE'), findsOneWidget);
    });

    testWidgets('login shows all five demo accounts + password hint',
        (WidgetTester tester) async {
      await pumpAppToLogin(tester, const PharmaDeskApp());
      for (final role in DemoRole.values) {
        expect(find.text(role.label), findsOneWidget);
      }
      expect(find.text('Demo password for every account: demo1234'),
          findsOneWidget);
      expect(find.text('Forgot password?'), findsOneWidget);
    });

    testWidgets('login validation rejects bad email / short password',
        (WidgetTester tester) async {
      await pumpAppToLogin(tester, const PharmaDeskApp());
      await tester.enterText(
        find.byType(TextFormField).first,
        'not-an-email',
      );
      await tester.enterText(find.byType(TextFormField).last, '123');
      await tester.tap(find.text('Sign in'));
      await tester.pump();
      expect(find.text('Enter a valid email address.'), findsOneWidget);
      expect(
        find.text('Password must be at least 6 characters.'),
        findsOneWidget,
      );
      expect(find.text('Owner dashboard'), findsNothing);
    });

    testWidgets('login with wrong password shows an error, stays put',
        (WidgetTester tester) async {
      await pumpAppToLogin(tester, const PharmaDeskApp());
      await tester.enterText(
        find.byType(TextFormField).first,
        'owner@demo.pharmadesk',
      );
      await tester.enterText(find.byType(TextFormField).last, 'wrongpass');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      expect(
        find.text('Incorrect password for this demo account.'),
        findsOneWidget,
      );
      expect(find.text('Owner dashboard'), findsNothing);
    });

    testWidgets('login with valid credentials opens the owner dashboard',
        (WidgetTester tester) async {
      await pumpAppToLogin(tester, const PharmaDeskApp());
      await tester.enterText(
        find.byType(TextFormField).first,
        'owner@demo.pharmadesk',
      );
      await tester.enterText(find.byType(TextFormField).last, 'demo1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      expect(find.text('Owner dashboard'), findsOneWidget);
    });

    testWidgets('one-tap demo login works for every role',
        (WidgetTester tester) async {
      await pumpAppToLogin(tester, const PharmaDeskApp());
      const expectedTitle = {
        DemoRole.owner: 'Owner dashboard',
        DemoRole.branchManager: 'Branch dashboard',
        DemoRole.pharmacist: 'Branch dashboard',
        DemoRole.cashier: 'Branch dashboard',
        DemoRole.inventoryManager: 'Branch dashboard',
      };
      for (final role in DemoRole.values) {
        await signInAsDemoRole(tester, role.label);
        expect(find.text(expectedTitle[role]!), findsOneWidget);
        // Back to login via the profile menu for the next role.
        await tester.tap(find.byKey(const ValueKey('profile-button')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Sign out'));
        await tester.pumpAndSettle();
        expect(find.text('Sign in'), findsOneWidget);
      }
    });

    testWidgets('profile menu signs out back to the login screen',
        (WidgetTester tester) async {
      await pumpAppToLogin(tester, const PharmaDeskApp());
      await signInAsDemoRole(tester, 'Owner');
      expect(find.text('Owner dashboard'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('profile-button')));
      await tester.pumpAndSettle();
      expect(find.text('Hassan Raza'), findsOneWidget);
      await tester.tap(find.text('Sign out'));
      await tester.pumpAndSettle();
      expect(find.text('Sign in'), findsOneWidget);
      expect(find.text('Owner dashboard'), findsNothing);
    });

    testWidgets('profile screen shows the signed-in user + sign out',
        (WidgetTester tester) async {
      await pumpAppToLogin(tester, const PharmaDeskApp());
      await signInAsDemoRole(tester, 'Cashier');
      await tester.tap(find.byKey(const ValueKey('profile-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Profile'));
      await tester.pumpAndSettle();
      expect(find.text('Usman Tariq'), findsWidgets);
      expect(find.text('Cashier'), findsWidgets);
      expect(find.text('Demo Branch — Gulberg'), findsWidgets);
      await tester.tap(find.text('Sign out'));
      await tester.pumpAndSettle();
      expect(find.text('Sign in'), findsOneWidget);
    });
  });

  group('Forgot-password screen', () {
    testWidgets('unknown email is rejected with a clear error',
        (WidgetTester tester) async {
      await pumpAppToLogin(tester, const PharmaDeskApp());
      await tester.tap(find.text('Forgot password?'));
      await tester.pumpAndSettle();
      expect(find.text('Reset your password'), findsOneWidget);
      expect(find.text('DEMO MODE'), findsOneWidget);
      await tester.enterText(
        find.byType(TextFormField).first,
        'nobody@demo.pharmadesk',
      );
      await tester.tap(find.text('Send reset code'));
      await tester.pumpAndSettle();
      expect(find.textContaining('No demo account found'), findsOneWidget);
    });

    testWidgets('full mock reset flow ends with a working new password',
        (WidgetTester tester) async {
      await pumpAppToLogin(tester, const PharmaDeskApp());
      await tester.tap(find.text('Forgot password?'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextFormField).first,
        'owner@demo.pharmadesk',
      );
      await tester.tap(find.text('Send reset code'));
      await tester.pumpAndSettle();
      final code = AuthNotifier.resetCodeFor('owner@demo.pharmadesk');
      expect(find.text(code), findsOneWidget);
      expect(
        find.textContaining('no reset email is sent'),
        findsOneWidget,
      );
      // Wrong code first: rejected, still on step 2.
      final fields = find.byType(TextFormField);
      await tester.enterText(fields.at(0), '000000');
      await tester.enterText(fields.at(1), 'newpass123');
      await tester.enterText(fields.at(2), 'newpass123');
      await tester.ensureVisible(find.text('Reset password'));
      await tester.tap(find.text('Reset password'));
      await tester.pumpAndSettle();
      expect(find.textContaining('reset code is incorrect'), findsOneWidget);
      // Correct code: success step, then sign in with the new password.
      await tester.enterText(fields.at(0), code);
      await tester.ensureVisible(find.text('Reset password'));
      await tester.tap(find.text('Reset password'));
      await tester.pumpAndSettle();
      expect(find.text('Password reset'), findsOneWidget);
      await tester.tap(find.text('Sign in now'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextFormField).first,
        'owner@demo.pharmadesk',
      );
      await tester.enterText(find.byType(TextFormField).last, 'newpass123');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      expect(find.text('Owner dashboard'), findsOneWidget);
    });
  });

  group('Dashboard KPI computation (pure)', () {
    final now = DateTime(2026, 11, 24, 12, 0);
    final today = DateTime(2026, 11, 24);
    final yesterday = DateTime(2026, 11, 23);

    List<Order> ordersForTest() => [
      Order(
        id: 'ord-today-1',
        customerId: 'cust-1',
        branchId: 'branch-dha-main',
        items: const [
          OrderItem(
            medicineId: 'med-panadol-extra',
            medicineName: 'Panadol Extra',
            quantity: 2,
            unitPrice: 120,
          ),
        ],
        deliveryAddress: 'Test address',
        status: OrderStatus.delivered,
        totalAmount: 240,
        createdAt: today.add(const Duration(hours: 10)),
      ),
      Order(
        id: 'ord-today-2',
        customerId: 'cust-2',
        branchId: 'branch-demo-gulberg',
        items: const [
          OrderItem(
            medicineId: 'med-risek-20',
            medicineName: 'Risek',
            quantity: 1,
            unitPrice: 640,
          ),
        ],
        deliveryAddress: 'Test address',
        status: OrderStatus.placed,
        totalAmount: 640,
        createdAt: today.add(const Duration(hours: 11)),
      ),
      Order(
        id: 'ord-today-cancelled',
        customerId: 'cust-1',
        branchId: 'branch-dha-main',
        items: const [
          OrderItem(
            medicineId: 'med-panadol-extra',
            medicineName: 'Panadol Extra',
            quantity: 10,
            unitPrice: 120,
          ),
        ],
        deliveryAddress: 'Test address',
        status: OrderStatus.cancelled,
        totalAmount: 1200,
        createdAt: today.add(const Duration(hours: 9)),
      ),
      Order(
        id: 'ord-yesterday-1',
        customerId: 'cust-1',
        branchId: 'branch-dha-main',
        items: const [
          OrderItem(
            medicineId: 'med-augmentin-625',
            medicineName: 'Augmentin',
            quantity: 1,
            unitPrice: 1850,
          ),
        ],
        deliveryAddress: 'Test address',
        status: OrderStatus.delivered,
        totalAmount: 1850,
        createdAt: yesterday.add(const Duration(hours: 10)),
      ),
    ];

    List<InventoryItem> inventoryForTest() => [
      InventoryItem(
        id: 'inv-low',
        medicineId: 'med-panadol-extra',
        branchId: 'branch-dha-main',
        quantity: 3,
        lowStockThreshold: 10,
        batchNo: 'LOW-1',
        expiryDate: DateTime(2027, 6, 1),
      ),
      InventoryItem(
        id: 'inv-near',
        medicineId: 'med-risek-20',
        branchId: 'branch-dha-main',
        quantity: 50,
        lowStockThreshold: 10,
        batchNo: 'NEAR-1',
        expiryDate: today.add(const Duration(days: 12)),
      ),
      InventoryItem(
        id: 'inv-expired',
        medicineId: 'med-augmentin-625',
        branchId: 'branch-demo-gulberg',
        quantity: 20,
        lowStockThreshold: 10,
        batchNo: 'EXP-1',
        expiryDate: today.subtract(const Duration(days: 2)),
      ),
      InventoryItem(
        id: 'inv-healthy',
        medicineId: 'med-zyrtec-10',
        branchId: 'branch-demo-gulberg',
        quantity: 80,
        lowStockThreshold: 10,
        batchNo: 'OK-1',
        expiryDate: DateTime(2027, 12, 1),
      ),
    ];

    List<Prescription> prescriptionsForTest() => const [
      Prescription(
        id: 'rx-1',
        customerId: 'cust-1',
        imageUrl: 'demo-1.jpg',
        status: PrescriptionStatus.pending,
      ),
      Prescription(
        id: 'rx-2',
        customerId: 'cust-2',
        imageUrl: 'demo-2.jpg',
        status: PrescriptionStatus.approved,
      ),
      Prescription(
        id: 'rx-3',
        customerId: 'cust-1',
        imageUrl: 'demo-3.jpg',
        status: PrescriptionStatus.pending,
      ),
    ];

    test('KPIs are computed from the data, cancelled orders excluded',
        () {
      final kpis = computeDashboardKpis(
        orders: ordersForTest(),
        inventory: inventoryForTest(),
        prescriptions: prescriptionsForTest(),
        now: now,
      );
      // Today: 240 + 640 = Rs 880.00; cancelled Rs 1,200 excluded.
      expect(kpis.todaySalesMinor, 88000);
      expect(kpis.todayOrders, 2);
      expect(kpis.yesterdaySalesMinor, 185000);
      expect(kpis.revenue30dMinor, 88000 + 185000);
      expect(kpis.orders30d, 3);
      expect(kpis.lowStockCount, 1);
      expect(kpis.nearExpiryCount, 1);
      expect(kpis.expiredCount, 1);
      expect(kpis.pendingPrescriptions, 2);
      expect(kpis.salesSeries.length, 30);
      // Top sellers by revenue: Augmentin 1850, Risek 640, Panadol 240.
      expect(kpis.topSellers.map((s) => s.medicineName), [
        'Augmentin',
        'Risek',
        'Panadol Extra',
      ]);
      expect(kpis.topSellers.first.revenueMinor, 185000);
      // Recent orders, newest first (cancelled included in the list).
      expect(kpis.recentOrders.first.id, 'ord-today-2');
      expect(kpis.recentOrders.length, 4);
    });

    test('branch scoping changes every figure', () {
      final dha = computeDashboardKpis(
        orders: ordersForTest(),
        inventory: inventoryForTest(),
        prescriptions: prescriptionsForTest(),
        branchId: 'branch-dha-main',
        now: now,
      );
      final glb = computeDashboardKpis(
        orders: ordersForTest(),
        inventory: inventoryForTest(),
        prescriptions: prescriptionsForTest(),
        branchId: 'branch-demo-gulberg',
        now: now,
      );
      expect(dha.todaySalesMinor, 24000);
      expect(glb.todaySalesMinor, 64000);
      expect(dha.todayOrders, 1);
      expect(glb.todayOrders, 1);
      expect(dha.lowStockCount, 1);
      expect(glb.lowStockCount, 0);
      expect(dha.nearExpiryCount, 1);
      expect(glb.nearExpiryCount, 0);
      expect(dha.expiredCount, 0);
      expect(glb.expiredCount, 1);
    });
  });

  group('Seed data', () {
    test('30 days of orders across both branches, DHA busier', () {
      final orders = generateDemoOrders();
      expect(orders.length, greaterThan(300));
      final dha = orders.where((o) => o.branchId == 'branch-dha-main');
      final glb = orders.where(
        (o) => o.branchId == 'branch-demo-gulberg',
      );
      expect(dha.length, greaterThan(glb.length));
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      expect(
        dha.where((o) => o.createdAt!.year == today.year &&
            o.createdAt!.month == today.month &&
            o.createdAt!.day == today.day),
        isNotEmpty,
      );
      expect(
        glb.where((o) => o.createdAt!.year == today.year &&
            o.createdAt!.month == today.month &&
            o.createdAt!.day == today.day),
        isNotEmpty,
      );
      // Every order total equals the sum of its lines.
      for (final order in orders) {
        expect(order.totalAmount, order.computedTotal);
      }
    });

    test('inventory has low-stock, near-expiry and expired rows', () {
      final items = generateDemoInventory();
      // Day 5: 1–3 batch rows per medicine per branch.
      expect(items.length, greaterThanOrEqualTo(demoMedicines.length * 2));
      expect(items.length, lessThanOrEqualTo(demoMedicines.length * 2 * 3));
      // Every medicine has at least one batch at each branch.
      for (final medicine in demoMedicines) {
        for (final branchId in demoSeedBranchIds) {
          expect(
            items.where(
              (i) =>
                  i.medicineId == medicine.id && i.branchId == branchId,
            ),
            isNotEmpty,
          );
        }
      }
      expect(items.where((i) => i.isLowStock), isNotEmpty);
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      expect(
        items.where((i) {
          final expiry = i.expiryDate;
          if (expiry == null) return false;
          final day = DateTime(expiry.year, expiry.month, expiry.day);
          return !day.isBefore(today) &&
              !day.isAfter(today.add(const Duration(days: 30)));
        }),
        isNotEmpty,
      );
      expect(items.where((i) => i.isExpired), isNotEmpty);
    });

    test('medicines, customers, suppliers and prescriptions are seeded',
        () {
      expect(demoMedicines.length, 180);
      expect(demoMedicinesCore.length, 14);
      expect(demoCustomers.length, 8);
      expect(demoSuppliers.length, 4);
      final rxs = generateDemoPrescriptions();
      expect(rxs.length, 20);
      expect(
        rxs.where((rx) => rx.status == PrescriptionStatus.pending),
        isNotEmpty,
      );
    });

    test('prescription repository scopes pending reviews per branch',
        () async {
      final repo = MockPrescriptionRepository();
      final dha = await repo.getPending(branchId: 'branch-dha-main');
      final glb = await repo.getPending(
        branchId: 'branch-demo-gulberg',
      );
      final all = await repo.getPending();
      expect(dha.length + glb.length, all.length);
      expect(dha, isNotEmpty);
      expect(glb, isNotEmpty);
    });
  });

  group('Dashboards (widget)', () {
    testWidgets('owner dashboard shows computed KPIs + sections',
        (WidgetTester tester) async {
      await pumpAppToLogin(tester, const PharmaDeskApp());
      await signInAsDemoRole(tester, 'Owner');
      expect(find.text('Owner dashboard'), findsOneWidget);
      expect(find.text("Today's sales"), findsOneWidget);
      expect(find.text("Today's orders"), findsOneWidget);
      expect(find.text('Revenue — 30 days'), findsOneWidget);
      expect(find.text('Low stock'), findsOneWidget);
      expect(find.text('Near expiry'), findsOneWidget);
      expect(find.text('Sales — last 30 days'), findsOneWidget);
      expect(find.text('Branch performance'), findsOneWidget);
      expect(find.text('Top-selling medicines'), findsOneWidget);
      expect(find.text('Recent orders'), findsOneWidget);
      expect(find.text('Alerts'), findsOneWidget);
      expect(find.text('Demo Branch — DHA'), findsWidgets);
      expect(find.text('Demo Branch — Gulberg'), findsWidgets);
      // DEMO MODE badge is in the shell top bar on every screen.
      expect(find.text('DEMO MODE'), findsWidgets);
    });

    testWidgets('owner KPI values match the seed data computation',
        (WidgetTester tester) async {
      await pumpAppToLogin(tester, const PharmaDeskApp());
      await signInAsDemoRole(tester, 'Owner');
      final orders = await MockOrderRepository().getOrders();
      final inventory = await MockInventoryRepository().getInventory();
      final prescriptions = await MockPrescriptionRepository()
          .getPrescriptions();
      final expected = computeDashboardKpis(
        orders: orders,
        inventory: inventory,
        prescriptions: prescriptions,
        now: DateTime.now(),
      );
      expect(find.text(formatPkr(expected.todaySalesMinor)), findsWidgets);
      expect(
        find.text(formatPkr(expected.revenue30dMinor)),
        findsOneWidget,
      );
    });

    testWidgets('branch dashboard is scoped: cashier sees Gulberg',
        (WidgetTester tester) async {
      await pumpAppToLogin(tester, const PharmaDeskApp());
      await signInAsDemoRole(tester, 'Cashier');
      expect(find.text('Branch dashboard'), findsOneWidget);
      expect(
        find.text('Demo Branch — Gulberg • Cashier'),
        findsOneWidget,
      );
      expect(find.text("Today's branch sales"), findsOneWidget);
      expect(find.text('Pending prescriptions'), findsOneWidget);
      expect(find.text('Quick actions'), findsOneWidget);
      expect(find.text('New Sale'), findsOneWidget);
      expect(find.text('New Order'), findsOneWidget);
      expect(find.text('Stock Check'), findsOneWidget);
      // Owner-only sections are absent on the branch dashboard.
      expect(find.text('Branch performance'), findsNothing);
      expect(find.text('Revenue — 30 days'), findsNothing);
    });

    testWidgets('pharmacist quick actions lead with Prescriptions',
        (WidgetTester tester) async {
      await pumpAppToLogin(tester, const PharmaDeskApp());
      await signInAsDemoRole(tester, 'Pharmacist');
      expect(find.text('Branch dashboard'), findsOneWidget);
      expect(find.text('Prescriptions'), findsWidgets);
    });

    testWidgets('branch switching changes the dashboard figures',
        (WidgetTester tester) async {
      await pumpAppToLogin(tester, const PharmaDeskApp());
      await signInAsDemoRole(tester, 'Cashier'); // Gulberg home branch
      final orders = await MockOrderRepository().getOrders();
      final inventory = await MockInventoryRepository().getInventory();
      final prescriptions = await MockPrescriptionRepository()
          .getPrescriptions();
      final glb = computeDashboardKpis(
        orders: orders,
        inventory: inventory,
        prescriptions: prescriptions,
        branchId: 'branch-demo-gulberg',
        now: DateTime.now(),
      );
      final dha = computeDashboardKpis(
        orders: orders,
        inventory: inventory,
        prescriptions: prescriptions,
        branchId: 'branch-dha-main',
        now: DateTime.now(),
      );
      expect(glb.todaySalesMinor, isNot(dha.todaySalesMinor));
      final glbSalesText = formatPkr(glb.todaySalesMinor);
      final dhaSalesText = formatPkr(dha.todaySalesMinor);
      expect(find.text(glbSalesText), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('branch-switcher-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Demo Branch — DHA').last);
      await tester.pumpAndSettle();
      expect(find.text('Demo Branch — DHA • Cashier'), findsOneWidget);
      expect(find.text(dhaSalesText), findsWidgets);
      expect(find.text(glbSalesText), findsNothing);
    });

    testWidgets('quick actions navigate to their modules',
        (WidgetTester tester) async {
      await pumpAppToLogin(tester, const PharmaDeskApp());
      await signInAsDemoRole(tester, 'Cashier');
      await tester.ensureVisible(find.text('New Sale'));
      await tester.tap(find.text('New Sale'));
      await tester.pumpAndSettle();
      // Day 6: New Sale opens the real POS screen.
      expect(find.text('Billing & POS'), findsOneWidget);
      expect(find.text('Add medicines'), findsOneWidget);
      await tester.tap(find.text('Dashboard'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Stock Check'));
      await tester.tap(find.text('Stock Check'));
      await tester.pumpAndSettle();
      // Day 5: the inventory screen is real — summary chips + buckets.
      expect(find.text('Inventory'), findsWidgets);
      expect(find.textContaining('expiring'), findsWidgets);
    });

    testWidgets('owner branch row switches branch and opens orders',
        (WidgetTester tester) async {
      await pumpAppToLogin(tester, const PharmaDeskApp());
      await signInAsDemoRole(tester, 'Owner');
      // Scroll the branch-performance row into view, then tap it.
      final row = find.text('Demo Branch — Gulberg');
      await tester.ensureVisible(row);
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(find.text('Orders'), findsWidgets);
      expect(find.text('New Order'), findsOneWidget);
      // The top-bar switcher followed the tap.
      expect(find.text('Demo Branch — Gulberg'), findsWidgets);
    });
  });

  group('Auth redirect (router)', () {
    Future<void> pumpRouter(
      WidgetTester tester, {
      required bool signedIn,
    }) async {
      final router = createAppRouter(isSignedIn: () => signedIn);
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
      await tester.pump(const Duration(milliseconds: 1500));
      await tester.pumpAndSettle();
    }

    testWidgets('signed out: dashboard redirects to login',
        (WidgetTester tester) async {
      await pumpRouter(tester, signedIn: false);
      expect(find.text('Sign in'), findsOneWidget);
    });

    testWidgets('signed in: login redirects to the dashboard',
        (WidgetTester tester) async {
      await pumpRouter(tester, signedIn: true);
      // No user in the provider: the dashboard falls back to the
      // branch view for the active branch.
      expect(find.text('Branch dashboard'), findsOneWidget);
    });
  });
}
