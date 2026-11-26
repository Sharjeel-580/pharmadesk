// Week 7 Day 5 tests — Demo polish, first pass (D175, brief §6).
//
// - Branch switching changes EVERY figure (demo guide §4 regression):
//   dashboard KPIs, order queue, inventory, reports — DHA vs Gulberg,
//   at the computation layer and through the shell's branch switcher.
// - Demo login for all 5 roles still works via email + `demo1234`
//   (the one-tap path is pinned in Day 3; the typed path is re-pinned
//   here for every role, plus a typed cashier widget login).
// - Prescription dispatch guard still blocks correctly: the seeded
//   linked orders (`ord-dha-1312` / `ord-glb-1487`) cannot dispatch
//   while `rx-dha-1` / `rx-glb-11` is Pending, and dispatch works
//   after pharmacist approval — end to end through the order queue
//   notifier for DHA.
// - FEFO cart + auto purchase list still behave: FEFO ordering,
//   `allocateFefo` splits, seeded FEFO picks, seeded auto purchase
//   lists per branch, and the open-PO exclusion (synthetic).
// - Restore counter advance (D175): preserving a backup order number
//   advances the target branch's counter past its sequence, so the
//   counter can never later mint the same number for a different
//   order. Parser rule + Firestore-repo behaviour, including the
//   other-branch / unparsable / below-floor cases that must NOT
//   advance anything.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharmadesk/app/pharmadesk_app.dart';
import 'package:pharmadesk/core/data/audit_log.dart';
import 'package:pharmadesk/core/data/firestore_repositories.dart';
import 'package:pharmadesk/core/data/firestore_schema.dart';
import 'package:pharmadesk/core/data/inventory_engine.dart';
import 'package:pharmadesk/core/data/production_data_layer.dart';
import 'package:pharmadesk/core/data/sync_queue.dart';
import 'package:pharmadesk/core/services/branch_context.dart';
import 'package:pharmadesk/core/services/repositories.dart';
import 'package:pharmadesk/features/authentication/auth_state.dart';
import 'package:pharmadesk/features/billing/billing_logic.dart';
import 'package:pharmadesk/features/dashboard/dashboard_data.dart';
import 'package:pharmadesk/features/dashboard/dashboard_screen.dart';
import 'package:pharmadesk/features/inventory/inventory_logic.dart';
import 'package:pharmadesk/features/orders/order_logic.dart';
import 'package:pharmadesk/features/orders/orders_provider.dart';
import 'package:pharmadesk/features/purchases/auto_purchase_logic.dart';
import 'package:pharmadesk/features/reports/reports_logic.dart';
import 'package:pharmadesk/models/inventory_item.dart';
import 'package:pharmadesk/models/medicine.dart';
import 'package:pharmadesk/models/order.dart';
import 'package:pharmadesk/models/prescription.dart';
import 'package:pharmadesk/models/purchase_order.dart';
import 'package:pharmadesk/models/sale.dart';
import 'package:pharmadesk/models/supplier.dart';

import 'test_helpers.dart';
import 'week2_day03_test.dart';

const _dha = 'branch-dha-main';
const _glb = 'branch-demo-gulberg';
const _org = demoOrganizationId;

InventoryItem _batch({
  required String id,
  required String medicineId,
  required String branchId,
  required int quantity,
  DateTime? expiry,
  String? batchNo,
  int lowStockThreshold = 10,
  int costMinor = 5000,
  BatchStatus status = BatchStatus.available,
}) {
  return InventoryItem(
    id: id,
    medicineId: medicineId,
    branchId: branchId,
    quantity: quantity,
    lowStockThreshold: lowStockThreshold,
    expiryDate: expiry,
    batchNo: batchNo,
    costMinor: costMinor,
    status: status,
  );
}

/// Production layer whose order repo is the Firestore implementation
/// over the Day 34 fake transport (D172); every other repo is a mock.
/// `seedBranches` runs first so the repo can read branch codes
/// (same shape as the Day 36 `_FirestoreHarness`).
class _FirestoreHarness {
  _FirestoreHarness._(this.transport, this.layer);

  static Future<_FirestoreHarness> create() async {
    final transport = FakeFirestoreTransport();
    await seedBranches(transport);
    final audit = InMemoryAuditLogWriter();
    final layer = ProductionDataLayer(
      organizationId: _org,
      inventoryRepo: MockInventoryRepository(),
      saleRepo: FirestoreSaleRepository(
        transport: transport,
        organizationId: _org,
      ),
      orderRepo: FirestoreOrderRepository(
        transport: transport,
        organizationId: _org,
      ),
      customerRepo: MockCustomerRepository(),
      medicineRepo: MockMedicineRepository(),
      supplierRepo: MockSupplierRepository(),
      prescriptionRepo: MockPrescriptionRepository(),
      purchaseOrderRepo: MockPurchaseOrderRepository(),
      riderRepo: MockRiderRepository(),
      branchRepo: MockBranchRepository(),
      audit: audit,
      syncQueue: SyncQueue(InMemorySyncStore()),
      engine: InventoryEngine(organizationId: _org, audit: audit),
    );
    return _FirestoreHarness._(transport, layer);
  }

  final FakeFirestoreTransport transport;
  final ProductionDataLayer layer;
}

void main() {
  group('Branch switching changes every figure (demo guide §4)', () {
    late List<Order> orders;
    late List<InventoryItem> inventory;
    late List<Sale> sales;
    late List<Medicine> medicines;

    setUp(() async {
      orders = await MockOrderRepository().getOrders();
      inventory = await MockInventoryRepository().getInventory();
      sales = await MockSaleRepository().getSales();
      medicines = await MockMedicineRepository().getMedicines();
    });

    test('seeded order stream is 491 across both branches (D31)', () {
      expect(orders, hasLength(491));
      expect(
        orders.where((o) => o.branchId == _dha).length,
        319,
      );
      expect(
        orders.where((o) => o.branchId == _glb).length,
        172,
      );
    });

    test('dashboard KPIs differ on every figure, DHA busier', () async {
      final rxRepo = MockPrescriptionRepository();

      // Prescriptions are branch-scoped by the repo (D21); fetch
      // each branch's list the way the provider does.
      Future<DashboardKpis> kpisWithRx(String branchId) async {
        final rx = await rxRepo.getPrescriptions(branchId: branchId);
        return computeDashboardKpis(
          orders: orders,
          inventory: inventory,
          prescriptions: rx,
          sales: sales,
          branchId: branchId,
          now: DateTime.now(),
        );
      }

      final dha = await kpisWithRx(_dha);
      final glb = await kpisWithRx(_glb);
      expect(dha.todaySalesMinor, isNot(glb.todaySalesMinor));
      expect(dha.todaySalesMinor, greaterThan(glb.todaySalesMinor));
      expect(dha.todayOrders, isNot(glb.todayOrders));
      expect(dha.todayOrders, greaterThan(glb.todayOrders));
      expect(dha.revenue30dMinor, isNot(glb.revenue30dMinor));
      expect(dha.revenue30dMinor, greaterThan(glb.revenue30dMinor));
      expect(dha.orders30d, isNot(glb.orders30d));
      expect(dha.orders30d, greaterThan(glb.orders30d));
      expect(dha.lowStockCount, isNot(glb.lowStockCount));
      expect(dha.nearExpiryCount, isNot(glb.nearExpiryCount));
      expect(dha.expiredCount, isNot(glb.expiredCount));
      expect(dha.pendingPrescriptions, isNot(glb.pendingPrescriptions));
      // Recent orders are branch-scoped too — no order id appears
      // in both branches' lists.
      final dhaIds = dha.recentOrders.map((o) => o.id).toSet();
      final glbIds = glb.recentOrders.map((o) => o.id).toSet();
      expect(dhaIds.intersection(glbIds), isEmpty);
      expect(
        dha.recentOrders.every((o) => o.branchId == _dha),
        isTrue,
      );
      expect(
        glb.recentOrders.every((o) => o.branchId == _glb),
        isTrue,
      );
    });

    test('order queue, inventory and reports all change per branch', () {
      final dhaOrders = filterOrders(orders: orders, branchId: _dha);
      final glbOrders = filterOrders(orders: orders, branchId: _glb);
      expect(dhaOrders, hasLength(319));
      expect(glbOrders, hasLength(172));
      expect(
        dhaOrders.every((o) => o.branchId == _dha),
        isTrue,
      );
      expect(
        glbOrders.every((o) => o.branchId == _glb),
        isTrue,
      );

      final dhaInv = inventory
          .where((i) => i.branchId == _dha)
          .toList();
      final glbInv = inventory
          .where((i) => i.branchId == _glb)
          .toList();
      expect(dhaInv, hasLength(379));
      expect(glbInv, hasLength(358));
      final dhaLow = dhaInv
          .where((i) => i.isLowStock)
          .map((i) => i.medicineId)
          .toSet();
      final glbLow = glbInv
          .where((i) => i.isLowStock)
          .map((i) => i.medicineId)
          .toSet();
      expect(dhaLow, isNot(glbLow));

      ReportData reportFor(String branchId) {
        return computeReports(
          orders: orders,
          sales: sales,
          inventory: inventory,
          medicinesById: {for (final m in medicines) m.id: m},
          branchId: branchId,
          now: DateTime.now(),
        );
      }

      final dhaReport = reportFor(_dha);
      final glbReport = reportFor(_glb);
      expect(dhaReport.totalSalesMinor, isNot(glbReport.totalSalesMinor));
      expect(dhaReport.totalOrders, isNot(glbReport.totalOrders));
      expect(dhaReport.lowStock.length, isNot(glbReport.lowStock.length));
      expect(
        dhaReport.stockValuationMinor,
        isNot(glbReport.stockValuationMinor),
      );
      expect(
        dhaReport.dailySales.map((d) => d.salesMinor),
        isNot(glbReport.dailySales.map((d) => d.salesMinor)),
      );
    });

    test('switching the active branch flips the provider figures', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final dhaKpis = await container.read(
        dashboardKpisProvider(_dha).future,
      );
      expect(container.read(activeBranchProvider).id, _dha);
      expect(
        container
            .read(activeBranchProvider.notifier)
            .switchTo(_glb),
        isTrue,
      );
      expect(container.read(activeBranchProvider).id, _glb);
      final glbKpis = await container.read(
        dashboardKpisProvider(_glb).future,
      );
      expect(glbKpis.todaySalesMinor, isNot(dhaKpis.todaySalesMinor));
      expect(glbKpis.todayOrders, isNot(dhaKpis.todayOrders));
      expect(glbKpis.revenue30dMinor, isNot(dhaKpis.revenue30dMinor));
      expect(glbKpis.orders30d, isNot(dhaKpis.orders30d));
      // Switching back restores the DHA figures exactly.
      expect(
        container
            .read(activeBranchProvider.notifier)
            .switchTo(_dha),
        isTrue,
      );
      final dhaAgain = await container.read(
        dashboardKpisProvider(_dha).future,
      );
      expect(dhaAgain.todaySalesMinor, dhaKpis.todaySalesMinor);
      expect(dhaAgain.orders30d, dhaKpis.orders30d);
    });

    testWidgets('shell branch switcher flips DHA to Gulberg', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await pumpAppToLogin(tester, const PharmaDeskApp());
      await signInAsDemoRole(tester, 'Owner');
      expect(find.text('Owner dashboard'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('branch-switcher-button')),
          matching: find.text('Demo Branch — DHA'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('branch-switcher-button')));
      await tester.pumpAndSettle();
      // The owner dashboard's per-branch section also shows the
      // Gulberg name — tap the popup menu item specifically.
      await tester.tap(
        find.widgetWithText(
          PopupMenuItem<String>,
          'Demo Branch — Gulberg',
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('branch-switcher-button')),
          matching: find.text('Demo Branch — Gulberg'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('branch-switcher-button')),
          matching: find.text('Demo Branch — DHA'),
        ),
        findsNothing,
      );
    });
  });

  group('Demo login for all 5 roles (email + demo1234)', () {
    const expectedName = {
      DemoRole.owner: 'Hassan Raza',
      DemoRole.branchManager: 'Bilal Ahmed',
      DemoRole.pharmacist: 'Dr. Sana Malik',
      DemoRole.cashier: 'Usman Tariq',
      DemoRole.inventoryManager: 'Fatima Noor',
    };
    const expectedBranch = {
      DemoRole.owner: null,
      DemoRole.branchManager: _dha,
      DemoRole.pharmacist: _dha,
      DemoRole.cashier: _glb,
      DemoRole.inventoryManager: _glb,
    };

    test('email + demo1234 signs in every role with its identity', () async {
      for (final role in DemoRole.values) {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final error = await container
            .read(authProvider.notifier)
            .signIn(role.email, demoPassword);
        expect(error, isNull, reason: '${role.label} sign-in');
        final user = container.read(authProvider);
        expect(user, isNotNull, reason: role.label);
        expect(user!.demoRole, role);
        expect(user.roleKey, role.roleKey);
        expect(user.name, expectedName[role]);
        expect(user.branchId, expectedBranch[role]);
      }
    });

    test('a wrong password fails for every role, nobody signs in', () async {
      for (final role in DemoRole.values) {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final error = await container
            .read(authProvider.notifier)
            .signIn(role.email, 'not-the-demo-password');
        expect(
          error,
          'Incorrect password for this demo account.',
          reason: role.label,
        );
        expect(container.read(authProvider), isNull);
      }
    });

    testWidgets('typed cashier login opens the branch dashboard', (
      WidgetTester tester,
    ) async {
      await pumpAppToLogin(tester, const PharmaDeskApp());
      await tester.enterText(
        find.byType(TextFormField).first,
        'cashier@demo.pharmadesk',
      );
      await tester.enterText(find.byType(TextFormField).last, 'demo1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      expect(find.text('Branch dashboard'), findsOneWidget);
    });
  });

  group('Prescription dispatch guard (demo guide §6)', () {
    test('pending blocks dispatch; approved releases; rejected releases',
        () {
      final order = sampleOrder(
        id: 'ord-guard-1',
      ).copyWith(prescriptionId: 'rx-dha-1');
      expect(
        advanceBlockedReason(
          order: order,
          next: OrderStatus.dispatched,
          linkedPrescriptionStatus: PrescriptionStatus.pending,
        ),
        contains('still pending'),
      );
      expect(
        advanceBlockedReason(
          order: order,
          next: OrderStatus.dispatched,
          linkedPrescriptionStatus: PrescriptionStatus.approved,
        ),
        isNull,
      );
      expect(
        advanceBlockedReason(
          order: order,
          next: OrderStatus.dispatched,
          linkedPrescriptionStatus: PrescriptionStatus.rejected,
        ),
        isNull,
      );
      expect(
        advanceBlockedReason(
          order: order,
          next: OrderStatus.dispatched,
          linkedPrescriptionStatus: PrescriptionStatus.needsClearerPhoto,
        ),
        isNull,
      );
      // The guard only gates the dispatch step: a pending
      // prescription never blocks Confirm / Processing / Ready.
      expect(
        advanceBlockedReason(
          order: order,
          next: OrderStatus.confirmed,
          linkedPrescriptionStatus: PrescriptionStatus.pending,
        ),
        isNull,
      );
      expect(
        advanceBlockedReason(
          order: order,
          next: OrderStatus.ready,
          linkedPrescriptionStatus: PrescriptionStatus.pending,
        ),
        isNull,
      );
      // An approved prescription whose validity expired still
      // blocks dispatch (D90); one valid tomorrow does not.
      final now = DateTime(2026, 11, 26);
      expect(
        advanceBlockedReason(
          order: order,
          next: OrderStatus.dispatched,
          linkedPrescriptionStatus: PrescriptionStatus.approved,
          linkedPrescriptionValidUntil: DateTime(2026, 11, 25),
          now: now,
        ),
        contains('validity expired'),
      );
      expect(
        advanceBlockedReason(
          order: order,
          next: OrderStatus.dispatched,
          linkedPrescriptionStatus: PrescriptionStatus.approved,
          linkedPrescriptionValidUntil: DateTime(2026, 11, 27),
          now: now,
        ),
        isNull,
      );
    });

    test('seeded linked orders are New + Pending on both branches', () async {
      final orders = await MockOrderRepository().getOrders();
      final rxRepo = MockPrescriptionRepository();
      final dhaOrder = orders.firstWhere(
        (o) => o.prescriptionId == 'rx-dha-1',
      );
      expect(dhaOrder.id, 'ord-dha-1312');
      expect(dhaOrder.branchId, _dha);
      expect(dhaOrder.status, OrderStatus.newOrder);
      expect(
        (await rxRepo.getById('rx-dha-1'))!.status,
        PrescriptionStatus.pending,
      );
      final glbOrder = orders.firstWhere(
        (o) => o.prescriptionId == 'rx-glb-11',
      );
      expect(glbOrder.id, 'ord-glb-1487');
      expect(glbOrder.branchId, _glb);
      expect(glbOrder.status, OrderStatus.newOrder);
      expect(
        (await rxRepo.getById('rx-glb-11'))!.status,
        PrescriptionStatus.pending,
      );
    });

    test('DHA linked order: held at dispatch, released after approval',
        () async {
      final orderRepo = MockOrderRepository();
      final rxRepo = MockPrescriptionRepository();
      final container = ProviderContainer(
        overrides: [
          orderRepositoryProvider.overrideWithValue(orderRepo),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(orderQueueProvider.notifier);

      Future<Order> live(String id) async =>
          (await orderRepo.getById(id))!;

      var order = await live('ord-dha-1312');
      expect(order.status, OrderStatus.newOrder);
      // New → Confirmed → Processing → Ready: the pending
      // prescription never blocks these steps.
      for (final next in [
        OrderStatus.confirmed,
        OrderStatus.processing,
        OrderStatus.ready,
      ]) {
        expect(
          await notifier.advanceOrder(
            order,
            linkedPrescriptionStatus: PrescriptionStatus.pending,
          ),
          isTrue,
        );
        order = await live('ord-dha-1312');
        expect(order.status, next);
      }
      // Ready → Dispatched is held while rx-dha-1 is Pending.
      expect(
        await notifier.advanceOrder(
          order,
          linkedPrescriptionStatus: PrescriptionStatus.pending,
        ),
        isFalse,
      );
      expect((await live('ord-dha-1312')).status, OrderStatus.ready);
      // The pharmacist approves the prescription: the same
      // advance now goes through, no order-side mutation needed.
      final reviewed = await rxRepo.reviewPrescription(
        id: 'rx-dha-1',
        status: PrescriptionStatus.approved,
        reviewedBy: 'pharmacist-1',
      );
      expect(reviewed!.status, PrescriptionStatus.approved);
      expect(
        await notifier.advanceOrder(
          order,
          linkedPrescriptionStatus: PrescriptionStatus.approved,
        ),
        isTrue,
      );
      expect(
        (await live('ord-dha-1312')).status,
        OrderStatus.dispatched,
      );
    });

    test('Gulberg linked order is held the same way, released on approval',
        () async {
      final rxRepo = MockPrescriptionRepository();
      final orders = await MockOrderRepository().getOrders();
      final order = orders.firstWhere(
        (o) => o.prescriptionId == 'rx-glb-11',
      );
      expect(
        advanceBlockedReason(
          order: order,
          next: OrderStatus.dispatched,
          linkedPrescriptionStatus: PrescriptionStatus.pending,
        ),
        isNotNull,
      );
      await rxRepo.reviewPrescription(
        id: 'rx-glb-11',
        status: PrescriptionStatus.approved,
        reviewedBy: 'pharmacist-1',
      );
      expect(
        advanceBlockedReason(
          order: order,
          next: OrderStatus.dispatched,
          linkedPrescriptionStatus: PrescriptionStatus.approved,
        ),
        isNull,
      );
    });
  });

  group('FEFO cart + auto purchase list', () {
    final now = DateTime(2026, 11, 26);

    test('fefoBatches: earliest expiry first, no-expiry last, ties by batch',
        () {
      final batches = [
        _batch(
          id: 'b-late',
          medicineId: 'med-1',
          branchId: _dha,
          quantity: 5,
          expiry: DateTime(2027, 3, 1),
          batchNo: 'B-2',
        ),
        _batch(
          id: 'b-none',
          medicineId: 'med-1',
          branchId: _dha,
          quantity: 5,
          batchNo: 'B-3',
        ),
        _batch(
          id: 'b-early',
          medicineId: 'med-1',
          branchId: _dha,
          quantity: 5,
          expiry: DateTime(2027, 1, 15),
          batchNo: 'B-1',
        ),
        _batch(
          id: 'b-expired',
          medicineId: 'med-1',
          branchId: _dha,
          quantity: 5,
          expiry: DateTime(2026, 1, 1),
          batchNo: 'B-0',
        ),
        _batch(
          id: 'b-tie',
          medicineId: 'med-1',
          branchId: _dha,
          quantity: 5,
          expiry: DateTime(2027, 1, 15),
          batchNo: 'B-0',
        ),
      ];
      final ordered = fefoBatches(batches);
      expect(
        ordered.map((b) => b.id),
        ['b-expired', 'b-tie', 'b-early', 'b-late', 'b-none'],
      );
      // The batch to sell from is the earliest SELLABLE one:
      // the expired row is skipped even though it sorts first.
      expect(fefoBatchFor(batches, now: now)!.id, 'b-tie');
    });

    test('fefoBatchFor skips expired, empty and quarantined batches', () {
      final batches = [
        _batch(
          id: 'b-expired',
          medicineId: 'med-1',
          branchId: _dha,
          quantity: 9,
          expiry: DateTime(2026, 11, 25),
          batchNo: 'B-1',
        ),
        _batch(
          id: 'b-empty',
          medicineId: 'med-1',
          branchId: _dha,
          quantity: 0,
          expiry: DateTime(2027, 1, 15),
          batchNo: 'B-2',
        ),
        _batch(
          id: 'b-quarantined',
          medicineId: 'med-1',
          branchId: _dha,
          quantity: 9,
          expiry: DateTime(2027, 1, 10),
          batchNo: 'B-3',
          status: BatchStatus.quarantined,
        ),
      ];
      expect(fefoBatchFor(batches, now: now), isNull);
      expect(canSellMedicine(batches, now: now), isFalse);
      expect(sellableStockFor(batches, now: now), 0);
      // One available batch with stock makes the medicine sellable.
      final withGood = [
        ...batches,
        _batch(
          id: 'b-good',
          medicineId: 'med-1',
          branchId: _dha,
          quantity: 4,
          expiry: DateTime(2027, 2, 1),
          batchNo: 'B-4',
        ),
      ];
      expect(fefoBatchFor(withGood, now: now)!.id, 'b-good');
      expect(canSellMedicine(withGood, now: now), isTrue);
      expect(sellableStockFor(withGood, now: now), 4);
    });

    test('seeded FEFO picks the earliest-expiry sellable batch per branch',
        () async {
      final inventory = await MockInventoryRepository().getInventory();
      final dhaBatches = groupBatchesByMedicine(
        inventory.where((i) => i.branchId == _dha),
      );
      // Panadol Extra at DHA: two sellable batches; the May 2027
      // one expires first and is picked.
      final panadol = dhaBatches['med-panadol-extra']!;
      expect(fefoBatchFor(panadol, now: now)!.batchNo, 'DHA-1-2-173');
      final risek = dhaBatches['med-risek-20']!;
      expect(fefoBatchFor(risek, now: now)!.batchNo, 'DHA-3-2-863');
      // Every medicine's FEFO pick is its earliest-expiry sellable
      // batch (no later-expiry batch is ever picked first).
      for (final entry in dhaBatches.entries) {
        final picked = fefoBatchFor(entry.value, now: now);
        if (picked == null) continue;
        for (final batch in entry.value) {
          if (!isBatchSellable(batch, now: now)) continue;
          expect(
            picked.expiryDate!.isAfter(batch.expiryDate!),
            isFalse,
            reason: '${entry.key}: picked ${picked.batchNo} over '
                '${batch.batchNo}',
          );
        }
      }
    });

    test('allocateFefo splits across batches earliest-first, discount once',
        () {
      final batches = {
        'med-1': [
          _batch(
            id: 'b-early',
            medicineId: 'med-1',
            branchId: _dha,
            quantity: 3,
            expiry: DateTime(2027, 1, 15),
            batchNo: 'B-1',
          ),
          _batch(
            id: 'b-late',
            medicineId: 'med-1',
            branchId: _dha,
            quantity: 10,
            expiry: DateTime(2027, 6, 1),
            batchNo: 'B-2',
          ),
          _batch(
            id: 'b-expired',
            medicineId: 'med-1',
            branchId: _dha,
            quantity: 50,
            expiry: DateTime(2026, 1, 1),
            batchNo: 'B-0',
          ),
        ],
      };
      final result = allocateFefo(
        lines: const [
          CartLine(
            medicineId: 'med-1',
            medicineName: 'Panadol',
            unitPriceMinor: 10000,
            quantity: 5,
            lineDiscountMinor: 1000,
          ),
        ],
        batchesByMedicine: batches,
        now: now,
      );
      // 3 from the earliest batch, 2 from the next; the expired
      // batch's 50 units are never touched.
      expect(result.items, hasLength(2));
      expect(result.items[0].batchId, 'b-early');
      expect(result.items[0].quantity, 3);
      expect(result.items[0].lineDiscountMinor, 1000);
      expect(result.items[1].batchId, 'b-late');
      expect(result.items[1].quantity, 2);
      expect(result.items[1].lineDiscountMinor, 0);
      expect(result.decrements, [
        (batchId: 'b-early', quantity: 3),
        (batchId: 'b-late', quantity: 2),
      ]);
    });

    test('allocateFefo refuses expired-only and insufficient stock', () {
      final expiredOnly = {
        'med-1': [
          _batch(
            id: 'b-expired',
            medicineId: 'med-1',
            branchId: _dha,
            quantity: 50,
            expiry: DateTime(2026, 1, 1),
            batchNo: 'B-0',
          ),
        ],
      };
      expect(
        () => allocateFefo(
          lines: const [
            CartLine(
              medicineId: 'med-1',
              medicineName: 'Panadol',
              unitPriceMinor: 10000,
              quantity: 1,
            ),
          ],
          batchesByMedicine: expiredOnly,
          now: now,
        ),
        throwsArgumentError,
      );
      final short = {
        'med-1': [
          _batch(
            id: 'b-only',
            medicineId: 'med-1',
            branchId: _dha,
            quantity: 2,
            expiry: DateTime(2027, 1, 15),
            batchNo: 'B-1',
          ),
        ],
      };
      expect(
        () => allocateFefo(
          lines: const [
            CartLine(
              medicineId: 'med-1',
              medicineName: 'Panadol',
              unitPriceMinor: 10000,
              quantity: 5,
            ),
          ],
          batchesByMedicine: short,
          now: now,
        ),
        throwsArgumentError,
      );
    });

    test('seeded auto purchase lists differ per branch and are valid',
        () async {
      final medicines = await MockMedicineRepository().getMedicines();
      final inventory = await MockInventoryRepository().getInventory();
      final purchaseOrders =
          await MockPurchaseOrderRepository().getPurchaseOrders();
      final suppliers = await MockSupplierRepository().getSuppliers();

      AutoPurchaseListResult listFor(String branchId) {
        return computeAutoPurchaseList(
          medicines: medicines,
          inventory: inventory,
          branchOrders: purchaseOrders
              .where((p) => p.branchId == branchId)
              .toList(),
          suppliers: suppliers,
          branchId: branchId,
        );
      }

      final dha = listFor(_dha);
      final glb = listFor(_glb);
      expect(dha.suggestions, hasLength(23));
      expect(glb.suggestions, hasLength(21));
      for (final suggestion in [
        ...dha.suggestions,
        ...glb.suggestions,
      ]) {
        expect(suggestion.suggestedQuantity, greaterThan(0));
        expect(
          suggestion.usableStock,
          lessThan(suggestion.reorderLevel),
        );
        expect(
          suggestion.suggestedQuantity,
          suggestion.reorderLevel - suggestion.usableStock,
        );
        expect(
          suggestion.lineTotalMinor,
          suggestion.suggestedQuantity * suggestion.unitCostMinor,
        );
      }
      final dhaIds = dha.suggestions.map((s) => s.medicineId).toSet();
      final glbIds = glb.suggestions.map((s) => s.medicineId).toSet();
      expect(dhaIds, isNot(glbIds));
    });

    test('auto purchase: open-PO cover excludes, reason priority holds', () {
      const medicine = Medicine(
        id: 'med-test',
        name: 'Testmed',
        brand: 'Test',
        categoryId: 'cat-1',
        strength: '10mg',
        packSize: '10 tabs',
        price: 100.0,
      );
      const supplier = Supplier(
        id: 'sup-1',
        name: 'Sami Pharmaceuticals',
        contactPerson: 'Sami',
        phone: '0300-0000001',
      );
      // Two batches, par 20, usable 5 → suggest 15.
      final batches = [
        _batch(
          id: 'b-1',
          medicineId: 'med-test',
          branchId: _dha,
          quantity: 5,
          expiry: DateTime(2027, 6, 1),
          batchNo: 'B-1',
        ),
        _batch(
          id: 'b-2',
          medicineId: 'med-test',
          branchId: _dha,
          quantity: 0,
          expiry: DateTime(2027, 6, 1),
          batchNo: 'B-2',
        ),
      ];
      final base = computeAutoPurchaseList(
        medicines: const [medicine],
        inventory: batches,
        branchOrders: const [],
        suppliers: const [supplier],
        branchId: _dha,
        now: now,
      );
      expect(base.suggestions, hasLength(1));
      expect(base.suggestions.first.suggestedQuantity, 15);
      expect(base.suggestions.first.reason, AutoPurchaseReason.belowReorderLevel);
      expect(base.suggestions.first.supplierId, 'sup-1');
      // The same medicine on an open Draft PO is excluded, not
      // suggested — the count counts only would-be suggestions.
      final covered = computeAutoPurchaseList(
        medicines: const [medicine],
        inventory: batches,
        branchOrders: const [
          PurchaseOrder(
            id: 'po-1',
            poNumber: 'PO-DHA-1001',
            supplierId: 'sup-1',
            branchId: _dha,
            status: PurchaseOrderStatus.draft,
            items: [
              PurchaseOrderItem(
                medicineId: 'med-test',
                medicineName: 'Testmed',
                quantityOrdered: 10,
                unitCostMinor: 5000,
              ),
            ],
          ),
        ],
        suppliers: const [supplier],
        branchId: _dha,
        now: now,
      );
      expect(covered.suggestions, isEmpty);
      expect(covered.excluded, hasLength(1));
      expect(covered.excluded.first.medicineId, 'med-test');
      // Reason priority: zero usable stock beats near-expiry.
      expect(
        reasonFor(usableStock: 0, nearExpiry: true),
        AutoPurchaseReason.lowStock,
      );
      expect(
        reasonFor(usableStock: 5, nearExpiry: true),
        AutoPurchaseReason.nearExpiry,
      );
      expect(
        reasonFor(usableStock: 5, nearExpiry: false),
        AutoPurchaseReason.belowReorderLevel,
      );
    });
  });

  group('Restore counter advance (D175)', () {
    test('parseOrderNumberSequence: the ORD-<branch>-<seq> rule', () {
      expect(
        parseOrderNumberSequence('ORD-DHA-1492'),
        (branchCode: 'DHA', sequence: 1492),
      );
      expect(
        parseOrderNumberSequence('ORD-GLB-1007'),
        (branchCode: 'GLB', sequence: 1007),
      );
      expect(
        parseOrderNumberSequence('ORD-DHA-1001'),
        (branchCode: 'DHA', sequence: 1001),
      );
      expect(parseOrderNumberSequence('ORD-DHA-ABC'), isNull);
      expect(parseOrderNumberSequence('ORD-DHA-'), isNull);
      expect(parseOrderNumberSequence('INV-DHA-1001'), isNull);
      expect(parseOrderNumberSequence(''), isNull);
      expect(parseOrderNumberSequence('ord-dha-1492'), isNull);
      expect(parseOrderNumberSequence('ORD-DHA-1492-extra'), isNull);
      expect(
        parseOrderNumberSequence('  ORD-DHA-1492  '),
        (branchCode: 'DHA', sequence: 1492),
      );
    });

    test('preserving 1492 advances the counter: next create is 1493',
        () async {
      final target = await _FirestoreHarness.create();
      final kept = await target.layer.orderRepo.upsertOrder(
        sampleOrder(
          id: 'ord-dha-1492',
        ).copyWith(orderNumber: 'ORD-DHA-1492'),
      );
      expect(kept.orderNumber, 'ORD-DHA-1492');
      final next = await target.layer.orderRepo.createOrder(sampleOrder());
      expect(next.orderNumber, 'ORD-DHA-1493');
      final following = await target.layer.orderRepo.createOrder(
        sampleOrder(id: 'ord-dha-next'),
      );
      expect(following.orderNumber, 'ORD-DHA-1494');
    });

    test('re-restoring the same number advances nothing twice', () async {
      final target = await _FirestoreHarness.create();
      final first = await target.layer.orderRepo.upsertOrder(
        sampleOrder(
          id: 'ord-dha-1492',
        ).copyWith(orderNumber: 'ORD-DHA-1492'),
      );
      expect(first.orderNumber, 'ORD-DHA-1492');
      // The same doc re-restored (an existing doc now): the number
      // is kept and the counter is already past it, so the next
      // genuine create still gets 1493 — no double advance.
      final replayed = await target.layer.orderRepo.upsertOrder(first);
      expect(replayed.orderNumber, 'ORD-DHA-1492');
      final next = await target.layer.orderRepo.createOrder(sampleOrder());
      expect(next.orderNumber, 'ORD-DHA-1493');
    });

    test('a GLB number on a DHA order advances neither counter', () async {
      final target = await _FirestoreHarness.create();
      final kept = await target.layer.orderRepo.upsertOrder(
        sampleOrder(
          id: 'ord-dha-glbnum',
        ).copyWith(orderNumber: 'ORD-GLB-1492'),
      );
      expect(kept.orderNumber, 'ORD-GLB-1492');
      // DHA's counter never saw a DHA sequence: first mint is 1001.
      final dhaNext = await target.layer.orderRepo.createOrder(sampleOrder());
      expect(dhaNext.orderNumber, 'ORD-DHA-1001');
      // GLB's counter never saw it either (the order lives in DHA):
      // first GLB mint is 1001 too.
      final glbNext = await target.layer.orderRepo.createOrder(
        sampleOrder(id: 'ord-glb-first').copyWith(branchId: _glb),
      );
      expect(glbNext.orderNumber, 'ORD-GLB-1001');
    });

    test('an unparsable carried number is kept but advances nothing',
        () async {
      final target = await _FirestoreHarness.create();
      final kept = await target.layer.orderRepo.upsertOrder(
        sampleOrder(
          id: 'ord-dha-weird',
        ).copyWith(orderNumber: 'RESTORED-42'),
      );
      expect(kept.orderNumber, 'RESTORED-42');
      final next = await target.layer.orderRepo.createOrder(sampleOrder());
      expect(next.orderNumber, 'ORD-DHA-1001');
    });

    test('a below-floor sequence never writes a low counter value',
        () async {
      final target = await _FirestoreHarness.create();
      final kept = await target.layer.orderRepo.upsertOrder(
        sampleOrder(
          id: 'ord-dha-500',
        ).copyWith(orderNumber: 'ORD-DHA-500'),
      );
      expect(kept.orderNumber, 'ORD-DHA-500');
      final next = await target.layer.orderRepo.createOrder(sampleOrder());
      expect(next.orderNumber, 'ORD-DHA-1001');
    });

    test('an in-range low sequence is a no-op for the next mint', () async {
      final target = await _FirestoreHarness.create();
      final kept = await target.layer.orderRepo.upsertOrder(
        sampleOrder(
          id: 'ord-dha-1001',
        ).copyWith(orderNumber: 'ORD-DHA-1001'),
      );
      expect(kept.orderNumber, 'ORD-DHA-1001');
      final next = await target.layer.orderRepo.createOrder(sampleOrder());
      expect(next.orderNumber, 'ORD-DHA-1002');
    });

    test('existing-doc replay still consumes no counter (D172 pin holds)',
        () async {
      final target = await _FirestoreHarness.create();
      final created = await target.layer.orderRepo.createOrder(
        sampleOrder(id: 'order-client-1'),
      );
      expect(created.orderNumber, 'ORD-DHA-1001');
      final replayed = await target.layer.orderRepo.upsertOrder(
        created.copyWith(deliveryAddress: 'Street 2, DHA'),
      );
      expect(replayed.orderNumber, 'ORD-DHA-1001');
      final next = await target.layer.orderRepo.createOrder(
        sampleOrder(id: 'order-client-2'),
      );
      expect(next.orderNumber, 'ORD-DHA-1002');
    });
  });
}
