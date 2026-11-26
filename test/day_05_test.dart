// PharmaDesk Day 5 tests — medicine catalogue + inventory.
//
// Covers: the 180-medicine seed catalogue, expiry buckets + FEFO
// ordering, the expired-never-sellable guard (pure + Day 4 order form),
// receive / adjust / count operations (repo + notifier + widgets),
// branch scoping, catalogue search/filter/sort, and dashboard figures
// reflecting stock changes.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharmadesk/app/pharmadesk_app.dart';
import 'package:pharmadesk/core/services/demo_seed_data.dart';
import 'package:pharmadesk/core/services/repositories.dart';
import 'package:pharmadesk/core/widgets/buttons.dart';
import 'package:pharmadesk/features/dashboard/dashboard_data.dart';
import 'package:pharmadesk/features/inventory/inventory_logic.dart';
import 'package:pharmadesk/features/inventory/inventory_provider.dart';
import 'package:pharmadesk/features/medicines/medicine_logic.dart';
import 'package:pharmadesk/models/inventory_item.dart';
import 'package:pharmadesk/models/medicine.dart';

import 'test_helpers.dart';

InventoryItem _batch({
  String id = 'inv-test-1',
  String medicineId = 'med-panadol-extra',
  String branchId = 'branch-dha-main',
  int quantity = 20,
  int lowStockThreshold = 10,
  DateTime? expiryDate,
  String? batchNo,
  DateTime? mfgDate,
  int costMinor = 5000,
}) => InventoryItem(
  id: id,
  medicineId: medicineId,
  branchId: branchId,
  quantity: quantity,
  lowStockThreshold: lowStockThreshold,
  expiryDate: expiryDate,
  batchNo: batchNo ?? 'B-1',
  mfgDate: mfgDate,
  costMinor: costMinor,
);

void main() {
  group('Seed catalogue (Day 5)', () {
    test('catalogue is 180 medicines: 14 core + 166 generated', () {
      expect(demoMedicinesCore.length, 14);
      expect(demoMedicines.length, 180);
      final ids = demoMedicines.map((m) => m.id).toSet();
      expect(ids.length, 180);
      final names = demoMedicines.map((m) => m.name).toSet();
      expect(names.length, 180);
    });

    test('every medicine has a unique 13-digit barcode', () {
      final barcodes = <String>{};
      for (final medicine in demoMedicines) {
        final barcode = medicine.barcode;
        expect(barcode, isNotNull);
        expect(barcode!.length, 13);
        expect(int.tryParse(barcode), isNotNull);
        expect(barcodes.add(barcode), isTrue);
      }
    });

    test('every medicine category is a known catalogue category', () {
      for (final medicine in demoMedicines) {
        expect(
          medicineCategoryLabels.containsKey(medicine.categoryId),
          isTrue,
          reason: '${medicine.name} has ${medicine.categoryId}',
        );
      }
      expect(medicineCategoryLabels.length, 16);
    });

    test('every medicine has batches at both branches, mfg before expiry',
        () {
      final items = generateDemoInventory();
      for (final medicine in demoMedicines) {
        for (final branchId in demoSeedBranchIds) {
          final rows = items.where(
            (i) => i.medicineId == medicine.id && i.branchId == branchId,
          );
          expect(rows, isNotEmpty);
          expect(rows.length, inInclusiveRange(1, 3));
          for (final row in rows) {
            expect(row.mfgDate, isNotNull);
            expect(row.expiryDate, isNotNull);
            expect(row.mfgDate!.isBefore(row.expiryDate!), isTrue);
            expect(row.costMinor, greaterThanOrEqualTo(0));
            expect(row.costMinor, lessThanOrEqualTo(medicine.priceMinor));
          }
        }
      }
    });

    test('inventory keeps low-stock, near-expiry and expired rows', () {
      final items = generateDemoInventory();
      expect(items.where((i) => i.isLowStock), isNotEmpty);
      final now = DateTime.now();
      expect(
        items.where(
          (i) =>
              expiryBucketFor(i.expiryDate, now: now) ==
              ExpiryBucket.within30,
        ),
        isNotEmpty,
      );
      expect(
        items.where(
          (i) =>
              expiryBucketFor(i.expiryDate, now: now) ==
              ExpiryBucket.expired,
        ),
        isNotEmpty,
      );
    });

    test('seeded orders still 491 and reference only the core 14', () {
      final orders = generateDemoOrders();
      // 491, not the 499 the Day 3/4 docs state — the Day 4 code itself
      // generates 491 (verified against commit 2e1954d); the docs were
      // wrong, the stream is unchanged by Day 5 (D31).
      expect(orders.length, 491);
      final coreIds = demoMedicinesCore.map((m) => m.id).toSet();
      for (final order in orders) {
        expect(order.totalAmount, order.computedTotal);
        for (final item in order.items) {
          expect(coreIds.contains(item.medicineId), isTrue);
        }
      }
    });

    test('barcode lookup finds a medicine, unknown returns null',
        () async {
      final repo = MockMedicineRepository();
      final panadol = await repo.getByBarcode('8901000000001');
      expect(panadol?.id, 'med-panadol-extra');
      expect(await repo.getByBarcode('8900000000000'), isNull);
      expect(await repo.getByBarcode(''), isNull);
    });
  });

  group('Expiry buckets + FEFO (pure)', () {
    final now = DateTime(2026, 11, 24, 12);

    test('bucket boundaries are exact', () {
      DateTime inDays(int days) => now.add(Duration(days: days));
      expect(expiryBucketFor(inDays(-5), now: now), ExpiryBucket.expired);
      expect(expiryBucketFor(inDays(-1), now: now), ExpiryBucket.expired);
      expect(expiryBucketFor(inDays(0), now: now), ExpiryBucket.expired);
      expect(expiryBucketFor(inDays(1), now: now), ExpiryBucket.within30);
      expect(expiryBucketFor(inDays(30), now: now), ExpiryBucket.within30);
      expect(expiryBucketFor(inDays(31), now: now), ExpiryBucket.within60);
      expect(expiryBucketFor(inDays(60), now: now), ExpiryBucket.within60);
      expect(expiryBucketFor(inDays(61), now: now), ExpiryBucket.within90);
      expect(expiryBucketFor(inDays(90), now: now), ExpiryBucket.within90);
      expect(expiryBucketFor(inDays(91), now: now), ExpiryBucket.fresh);
      expect(expiryBucketFor(null, now: now), ExpiryBucket.fresh);
    });

    test('FEFO sorts earliest expiry first, no-expiry last', () {
      final batches = [
        _batch(id: 'b-fresh', expiryDate: now.add(const Duration(days: 200))),
        _batch(id: 'b-none', expiryDate: null),
        _batch(id: 'b-soon', expiryDate: now.add(const Duration(days: 5))),
        _batch(id: 'b-exp', expiryDate: now.subtract(const Duration(days: 2))),
      ];
      final ordered = fefoBatches(batches);
      expect(
        ordered.map((b) => b.id).toList(),
        ['b-exp', 'b-soon', 'b-fresh', 'b-none'],
      );
    });

    test('sellable guard: expired and empty batches never sell', () {
      final expired = _batch(
        expiryDate: now.subtract(const Duration(days: 1)),
      );
      final expiresToday = _batch(expiryDate: now);
      final empty = _batch(
        quantity: 0,
        expiryDate: now.add(const Duration(days: 100)),
      );
      final good = _batch(
        expiryDate: now.add(const Duration(days: 100)),
      );
      final noExpiry = _batch(expiryDate: null);
      expect(isBatchSellable(expired, now: now), isFalse);
      expect(isBatchSellable(expiresToday, now: now), isFalse);
      expect(isBatchSellable(empty, now: now), isFalse);
      expect(isBatchSellable(good, now: now), isTrue);
      expect(isBatchSellable(noExpiry, now: now), isTrue);
    });

    test('canSellMedicine + fefoBatchFor skip expired batches', () {
      final mixed = [
        _batch(
          id: 'b-exp',
          expiryDate: now.subtract(const Duration(days: 3)),
        ),
        _batch(
          id: 'b-late',
          expiryDate: now.add(const Duration(days: 200)),
        ),
        _batch(
          id: 'b-soon',
          expiryDate: now.add(const Duration(days: 10)),
        ),
      ];
      expect(canSellMedicine(mixed, now: now), isTrue);
      expect(fefoBatchFor(mixed, now: now)?.id, 'b-soon');
      final allExpired = [
        _batch(
          id: 'b-e1',
          expiryDate: now.subtract(const Duration(days: 1)),
        ),
        _batch(
          id: 'b-e2',
          expiryDate: now.subtract(const Duration(days: 9)),
        ),
      ];
      expect(canSellMedicine(allExpired, now: now), isFalse);
      expect(fefoBatchFor(allExpired, now: now), isNull);
      expect(canSellMedicine(const [], now: now), isFalse);
    });

    test('sellable vs total stock', () {
      final batches = [
        _batch(
          id: 'b-exp',
          quantity: 7,
          expiryDate: now.subtract(const Duration(days: 2)),
        ),
        _batch(
          id: 'b-good',
          quantity: 12,
          expiryDate: now.add(const Duration(days: 40)),
        ),
      ];
      expect(sellableStockFor(batches, now: now), 12);
      expect(totalStockFor(batches), 19);
    });

    test('grouping keeps FEFO order inside each medicine group', () {
      final batches = [
        _batch(
          id: 'b2',
          medicineId: 'm1',
          expiryDate: now.add(const Duration(days: 90)),
        ),
        _batch(
          id: 'b1',
          medicineId: 'm1',
          expiryDate: now.add(const Duration(days: 9)),
        ),
        _batch(id: 'b3', medicineId: 'm2'),
      ];
      final grouped = groupBatchesByMedicine(batches);
      expect(grouped['m1']!.map((b) => b.id).toList(), ['b1', 'b2']);
      expect(grouped['m2']!.length, 1);
    });
  });

  group('Catalogue search / filter / sort (pure)', () {
    final medicines = [
      const Medicine(
        id: 'm1',
        name: 'Panadol Extra',
        brand: 'GSK',
        categoryId: 'cat-analgesic',
        strength: '500mg',
        packSize: '10 tablets',
        price: 120,
        barcode: '8901000000001',
      ),
      const Medicine(
        id: 'm2',
        name: 'Augmentin',
        brand: 'GSK',
        categoryId: 'cat-antibiotic',
        strength: '625mg',
        packSize: '12 tablets',
        price: 1850,
        barcode: '8901000000002',
        requiresPrescription: true,
      ),
      const Medicine(
        id: 'm3',
        name: 'Risek',
        brand: 'Getz Pharma',
        categoryId: 'cat-gastric',
        strength: '20mg',
        packSize: '14 capsules',
        price: 640,
        barcode: '8901000000003',
      ),
    ];

    test('search matches name, brand and barcode', () {
      expect(
        filterMedicines(medicines, query: 'panadol').map((m) => m.id),
        ['m1'],
      );
      expect(
        filterMedicines(medicines, query: 'gsk').map((m) => m.id),
        ['m1', 'm2'],
      );
      expect(
        filterMedicines(medicines, query: '0000002').map((m) => m.id),
        ['m2'],
      );
      expect(filterMedicines(medicines, query: 'zzz'), isEmpty);
      expect(filterMedicines(medicines, query: '').length, 3);
    });

    test('category filter narrows, combined with search', () {
      expect(
        filterMedicines(
          medicines,
          categoryId: 'cat-antibiotic',
        ).map((m) => m.id),
        ['m2'],
      );
      expect(
        filterMedicines(
          medicines,
          query: 'gsk',
          categoryId: 'cat-antibiotic',
        ).map((m) => m.id),
        ['m2'],
      );
      expect(
        filterMedicines(medicines, categoryId: 'all').length,
        3,
      );
    });

    test('sort by name, price (int paisa) and stock', () {
      final stock = {'m1': 5, 'm2': 50, 'm3': 0};
      expect(
        sortMedicines(medicines, MedicineSort.nameAsc).map((m) => m.id),
        ['m2', 'm1', 'm3'],
      );
      expect(
        sortMedicines(medicines, MedicineSort.priceAsc).map((m) => m.id),
        ['m1', 'm3', 'm2'],
      );
      expect(
        sortMedicines(medicines, MedicineSort.priceDesc).map((m) => m.id),
        ['m2', 'm3', 'm1'],
      );
      expect(
        sortMedicines(
          medicines,
          MedicineSort.stockAsc,
          sellableStockByMedicine: stock,
        ).map((m) => m.id),
        ['m3', 'm1', 'm2'],
      );
      expect(
        sortMedicines(
          medicines,
          MedicineSort.stockDesc,
          sellableStockByMedicine: stock,
        ).map((m) => m.id),
        ['m2', 'm1', 'm3'],
      );
    });
  });

  group('Stock operations (repository)', () {
    test('receive adds a batch, branch-scoped', () async {
      final repo = MockInventoryRepository();
      final beforeDha = await repo.getInventory(
        branchId: 'branch-dha-main',
      );
      final beforeGlb = await repo.getInventory(
        branchId: 'branch-demo-gulberg',
      );
      final created = await repo.receiveStock(
        branchId: 'branch-dha-main',
        medicineId: 'med-panadol-extra',
        batchNo: 'DHA-TEST-1',
        mfgDate: DateTime(2026, 1, 1),
        expiryDate: DateTime(2027, 6, 1),
        quantity: 40,
        costMinor: 8000,
      );
      expect(created.batchNo, 'DHA-TEST-1');
      expect(created.quantity, 40);
      final afterDha = await repo.getInventory(branchId: 'branch-dha-main');
      final afterGlb = await repo.getInventory(
        branchId: 'branch-demo-gulberg',
      );
      expect(afterDha.length, beforeDha.length + 1);
      expect(afterGlb.length, beforeGlb.length);
    });

    test('receive rejects bad input', () async {
      final repo = MockInventoryRepository();
      expect(
        () => repo.receiveStock(
          branchId: 'branch-dha-main',
          medicineId: 'med-panadol-extra',
          batchNo: 'X',
          mfgDate: DateTime(2026, 1, 1),
          expiryDate: DateTime(2027, 1, 1),
          quantity: 0,
          costMinor: 100,
        ),
        throwsArgumentError,
      );
      expect(
        () => repo.receiveStock(
          branchId: 'branch-dha-main',
          medicineId: 'med-panadol-extra',
          batchNo: 'X',
          mfgDate: DateTime(2026, 1, 1),
          expiryDate: DateTime(2025, 1, 1),
          quantity: 5,
          costMinor: 100,
        ),
        throwsArgumentError,
      );
    });

    test('adjust increases and decreases, never below zero', () async {
      final repo = MockInventoryRepository();
      final rows = await repo.getInventory(branchId: 'branch-dha-main');
      final row = rows.firstWhere((r) => r.quantity > 5);
      final up = await repo.adjustStock(
        batchId: row.id,
        deltaQty: 5,
        reason: 'found stock',
      );
      expect(up.quantity, row.quantity + 5);
      final down = await repo.adjustStock(
        batchId: row.id,
        deltaQty: -3,
        reason: 'damaged',
      );
      expect(down.quantity, row.quantity + 2);
      expect(
        () => repo.adjustStock(
          batchId: row.id,
          deltaQty: -(row.quantity + 100),
          reason: 'write off',
        ),
        throwsArgumentError,
      );
      expect(
        () => repo.adjustStock(batchId: row.id, deltaQty: 0, reason: 'x'),
        throwsArgumentError,
      );
      expect(
        () => repo.adjustStock(batchId: row.id, deltaQty: 1, reason: '  '),
        throwsArgumentError,
      );
    });

    test('stock count sets the quantity (variance is counted - system)',
        () async {
      final repo = MockInventoryRepository();
      final rows = await repo.getInventory(branchId: 'branch-dha-main');
      final row = rows.first;
      final counted = row.quantity + 4;
      final updated = await repo.recordStockCount(
        batchId: row.id,
        countedQty: counted,
        note: 'shelf recount',
      );
      expect(updated.quantity, counted);
      expect(counted - row.quantity, 4);
      expect(
        () => repo.recordStockCount(batchId: row.id, countedQty: -1),
        throwsArgumentError,
      );
    });
  });

  group('Stock operations (notifier) + dashboard reflection', () {
    test('receive / adjust / count update provider state', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(inventoryProvider.notifier);
      await container.read(inventoryProvider.future);
      final before = container.read(inventoryProvider).asData!.value;
      final target = before.firstWhere(
        (r) => r.branchId == 'branch-dha-main' && r.quantity > 10,
      );

      final created = await notifier.receiveStock(
        branchId: 'branch-dha-main',
        medicineId: 'med-panadol-extra',
        batchNo: 'DHA-NOT-1',
        mfgDate: DateTime(2026, 1, 1),
        expiryDate: DateTime(2027, 6, 1),
        quantity: 30,
        costMinor: 9000,
      );
      var items = container.read(inventoryProvider).asData!.value;
      expect(items.any((i) => i.id == created.id), isTrue);

      final adjusted = await notifier.adjustStock(
        batchId: target.id,
        deltaQty: -4,
        reason: 'damaged',
      );
      expect(adjusted?.quantity, target.quantity - 4);
      items = container.read(inventoryProvider).asData!.value;
      expect(
        items.firstWhere((i) => i.id == target.id).quantity,
        target.quantity - 4,
      );

      final result = await notifier.recordStockCount(
        batchId: target.id,
        countedQty: target.quantity - 4 + 2,
      );
      expect(result?.variance, 2);
      expect(result?.item.quantity, target.quantity - 4 + 2);

      // Rejected adjustments return null and leave state untouched.
      final rejected = await notifier.adjustStock(
        batchId: target.id,
        deltaQty: -10000,
        reason: 'too much',
      );
      expect(rejected, isNull);
    });

    test('adjusting a batch to low stock raises the dashboard count',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(inventoryProvider.notifier);
      final before = await container.read(inventoryProvider.future);
      final orders = await MockOrderRepository().getOrders();
      final prescriptions = await MockPrescriptionRepository()
          .getPrescriptions();
      final kpisBefore = computeDashboardKpis(
        orders: orders,
        inventory: before,
        prescriptions: prescriptions,
        branchId: 'branch-dha-main',
        now: DateTime.now(),
      );
      final target = before.firstWhere(
        (r) => r.branchId == 'branch-dha-main' && !r.isLowStock,
      );
      await notifier.adjustStock(
        batchId: target.id,
        deltaQty: -(target.quantity - 5),
        reason: 'test: drop to low stock',
      );
      final after = container.read(inventoryProvider).asData!.value;
      final kpisAfter = computeDashboardKpis(
        orders: orders,
        inventory: after,
        prescriptions: prescriptions,
        branchId: 'branch-dha-main',
        now: DateTime.now(),
      );
      expect(kpisAfter.lowStockCount, kpisBefore.lowStockCount + 1);
    });
  });

  group('Catalogue + inventory screens (widget)', () {
    Future<void> openPanadolDetail(WidgetTester tester) async {
      await pumpAppToLogin(tester, const PharmaDeskApp());
      await signInAsDemoRole(tester, 'Owner');
      await tester.tap(
        find.descendant(
          of: find.byType(BottomNavigationBar),
          matching: find.text('Medicines'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'Panadol');
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Panadol Extra 500mg'));
      await tester.tap(find.text('Panadol Extra 500mg'));
      await tester.pumpAndSettle();
      expect(find.text('8901000000001'), findsOneWidget);
    }

    testWidgets('catalogue shows 180 medicines, search narrows',
        (WidgetTester tester) async {
      await pumpAppToLogin(tester, const PharmaDeskApp());
      await signInAsDemoRole(tester, 'Owner');
      await tester.tap(
        find.descendant(
          of: find.byType(BottomNavigationBar),
          matching: find.text('Medicines'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('180 medicines'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, 'Panadol');
      await tester.pumpAndSettle();
      expect(find.text('1 result(s)'), findsOneWidget);
      expect(find.text('Panadol Extra 500mg'), findsOneWidget);
    });

    testWidgets('category chip filters, sort dropdown reorders',
        (WidgetTester tester) async {
      await pumpAppToLogin(tester, const PharmaDeskApp());
      await signInAsDemoRole(tester, 'Owner');
      await tester.tap(
        find.descendant(
          of: find.byType(BottomNavigationBar),
          matching: find.text('Medicines'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Antibiotic (20)'));
      await tester.tap(find.text('Antibiotic (20)'));
      await tester.pumpAndSettle();
      expect(find.text('20 result(s)'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('catalogue-sort-dropdown')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Price: high to low'));
      await tester.pumpAndSettle();
      final priciest = demoMedicines
          .where((m) => m.categoryId == 'cat-antibiotic')
          .reduce((a, b) => a.priceMinor >= b.priceMinor ? a : b);
      expect(
        find.text('${priciest.name} ${priciest.strength}'),
        findsOneWidget,
      );
    });

    testWidgets('medicine detail shows barcode, price, FEFO batches',
        (WidgetTester tester) async {
      await openPanadolDetail(tester);
      expect(find.textContaining('Batches —'), findsOneWidget);
      expect(find.text('Receive stock'), findsOneWidget);
      expect(find.textContaining('Batch '), findsWidgets);
    });

    testWidgets('receive stock from medicine detail adds a batch',
        (WidgetTester tester) async {
      await openPanadolDetail(tester);
      await tester.ensureVisible(find.text('Receive stock'));
      await tester.tap(find.text('Receive stock'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), 'DHA-TEST-001');
      await tester.enterText(find.byType(TextField).at(1), '25');
      await tester.enterText(find.byType(TextField).at(2), '90');
      await tester.tap(find.text('Receive'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Received 25 units'), findsOneWidget);
      await tester.ensureVisible(find.text('Batch DHA-TEST-001'));
      expect(find.text('Batch DHA-TEST-001'), findsOneWidget);
    });

    testWidgets('adjust stock from medicine detail files a request',
        (WidgetTester tester) async {
      final repo = MockInventoryRepository();
      final rows = await repo.getInventory(branchId: 'branch-dha-main');
      final batch = fefoBatches(
        rows.where((r) => r.medicineId == 'med-panadol-extra'),
      ).first;
      await openPanadolDetail(tester);
      await tester.ensureVisible(find.text('Adjust').first);
      await tester.tap(find.text('Adjust').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Decrease'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), '2');
      await tester.enterText(
        find.byType(TextField).at(1),
        'damaged in transit',
      );
      // Week 4 Day 5 (D141): the dialog no longer applies the
      // adjustment directly — it files a request for approval, so
      // the quantity does NOT change here. The old expectation
      // ("now has N units") belonged to the direct-apply flow.
      await tester.tap(find.text('Submit request'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Adjustment requested — pending approval'),
        findsOneWidget,
      );
      expect(
        find.textContaining('now has ${batch.quantity - 2} units'),
        findsNothing,
      );
    });

    testWidgets('stock count from medicine detail reports variance',
        (WidgetTester tester) async {
      final repo = MockInventoryRepository();
      final rows = await repo.getInventory(branchId: 'branch-dha-main');
      final batch = fefoBatches(
        rows.where((r) => r.medicineId == 'med-panadol-extra'),
      ).first;
      await openPanadolDetail(tester);
      await tester.ensureVisible(find.text('Count').first);
      await tester.tap(find.text('Count').first);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField).at(0),
        '${batch.quantity + 3}',
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Variance: +3 units'), findsOneWidget);
      await tester.tap(find.text('Save count'));
      await tester.pumpAndSettle();
      expect(find.textContaining('variance +3 units'), findsOneWidget);
    });

    testWidgets('inventory bucket filter shows only that bucket',
        (WidgetTester tester) async {
      await pumpAppToLogin(tester, const PharmaDeskApp());
      await signInAsDemoRole(tester, 'Owner');
      await tester.ensureVisible(find.text('Low stock'));
      await tester.tap(find.text('Low stock'));
      await tester.pumpAndSettle();
      expect(find.text('Inventory'), findsWidgets);
      final rows = await MockInventoryRepository().getInventory(
        branchId: 'branch-dha-main',
      );
      final expiredCount =
          expiryBucketCounts(
            rows,
          )[ExpiryBucket.expired]!;
      await tester.ensureVisible(find.text('Expired ($expiredCount)'));
      await tester.tap(find.text('Expired ($expiredCount)'));
      await tester.pumpAndSettle();
      expect(find.text('Expired'), findsWidgets);
      expect(find.text('Fresh (> 90 days)'), findsNothing);
      expect(find.text('Expiring ≤ 30 days'), findsNothing);
    });

    testWidgets('inventory alerts tab opens the medicine detail',
        (WidgetTester tester) async {
      await pumpAppToLogin(tester, const PharmaDeskApp());
      await signInAsDemoRole(tester, 'Owner');
      await tester.ensureVisible(find.text('Low stock'));
      await tester.tap(find.text('Low stock'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Alerts'));
      await tester.tap(find.text('Alerts'));
      await tester.pumpAndSettle();
      expect(find.text('Expired batches'), findsOneWidget);
      expect(find.text('Expiring within 30 days'), findsOneWidget);
      expect(find.text('Low stock'), findsOneWidget);
      final rows = await MockInventoryRepository().getInventory(
        branchId: 'branch-dha-main',
      );
      final expired = rows
          .where(
            (r) => expiryBucketFor(r.expiryDate) == ExpiryBucket.expired,
          )
          .first;
      await tester.ensureVisible(
        find.byKey(ValueKey('alert-${expired.id}')),
      );
      await tester.tap(find.byKey(ValueKey('alert-${expired.id}')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Batches —'), findsOneWidget);
    });

    testWidgets('branch switching re-scopes the inventory',
        (WidgetTester tester) async {
      await pumpAppToLogin(tester, const PharmaDeskApp());
      await signInAsDemoRole(tester, 'Owner');
      await tester.ensureVisible(find.text('Low stock'));
      await tester.tap(find.text('Low stock'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Demo Branch — DHA'), findsWidgets);
      await tester.tap(
        find.byKey(const ValueKey('branch-switcher-button')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Demo Branch — Gulberg').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('Demo Branch — Gulberg'), findsWidgets);
    });
  });

  group('Order form expired guard (widget, shared rule)', () {
    testWidgets('all-expired medicine cannot be added; mixed can',
        (WidgetTester tester) async {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      // Tall viewport: the order form's pick rows otherwise sit under
      // the shell top bar / bottom nav at the default 800x600 size and
      // taps miss them (D24).
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final fake = _FakeInventoryRepository([
        InventoryItem(
          id: 'inv-fake-1',
          medicineId: 'med-panadol-extra',
          branchId: 'branch-dha-main',
          quantity: 10,
          lowStockThreshold: 10,
          batchNo: 'EXP-1',
          expiryDate: today.subtract(const Duration(days: 1)),
          mfgDate: today.subtract(const Duration(days: 400)),
          costMinor: 5000,
        ),
        InventoryItem(
          id: 'inv-fake-2',
          medicineId: 'med-panadol-extra',
          branchId: 'branch-dha-main',
          quantity: 5,
          lowStockThreshold: 10,
          batchNo: 'EXP-2',
          expiryDate: today.subtract(const Duration(days: 5)),
          mfgDate: today.subtract(const Duration(days: 400)),
          costMinor: 5000,
        ),
        InventoryItem(
          id: 'inv-fake-3',
          medicineId: 'med-risek-20',
          branchId: 'branch-dha-main',
          quantity: 5,
          lowStockThreshold: 10,
          batchNo: 'EXP-3',
          expiryDate: today.subtract(const Duration(days: 3)),
          mfgDate: today.subtract(const Duration(days: 400)),
          costMinor: 5000,
        ),
        InventoryItem(
          id: 'inv-fake-4',
          medicineId: 'med-risek-20',
          branchId: 'branch-dha-main',
          quantity: 20,
          lowStockThreshold: 10,
          batchNo: 'FRESH-1',
          expiryDate: today.add(const Duration(days: 200)),
          mfgDate: today.subtract(const Duration(days: 100)),
          costMinor: 5000,
        ),
      ]);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            inventoryRepositoryProvider.overrideWithValue(fake),
          ],
          child: const PharmaDeskApp(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 1500));
      await tester.pumpAndSettle();
      await signInAsDemoRole(tester, 'Owner');
      await tester.tap(
        find.descendant(
          of: find.byType(BottomNavigationBar),
          matching: find.text('Orders'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('New Order'));
      await tester.tap(find.text('New Order'));
      await tester.pumpAndSettle();

      // Panadol: every batch expired → blocked by the shared guard.
      await tester.enterText(find.byType(TextField).first, 'Panadol');
      await tester.pumpAndSettle();
      expect(
        find.text('All batches expired — never sellable'),
        findsOneWidget,
      );
      expect(find.text('Expired'), findsOneWidget);
      final expiredButton = tester.widget<PharmaButton>(
        find.byKey(const ValueKey('add-med-panadol-extra')),
      );
      expect(expiredButton.onPressed, isNull);
      await tester.tap(find.byKey(const ValueKey('add-med-panadol-extra')));
      await tester.pumpAndSettle();
      expect(
        find.text('No items yet — add at least one medicine.'),
        findsOneWidget,
      );

      // Risek: one expired batch, one sellable FEFO batch → addable.
      await tester.enterText(find.byType(TextField).first, 'Risek');
      await tester.pumpAndSettle();
      expect(find.text('Add'), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const ValueKey('add-med-risek-20')),
      );
      await tester.tap(find.byKey(const ValueKey('add-med-risek-20')));
      await tester.pumpAndSettle();
      expect(
        find.text('No items yet — add at least one medicine.'),
        findsNothing,
      );
      expect(find.text('Risek'), findsWidgets);
    });
  });
}

/// Inventory repository with crafted rows, for the order-form guard
/// test: Panadol's batches are all expired, Risek has one expired and
/// one sellable batch.
class _FakeInventoryRepository implements InventoryRepository {
  _FakeInventoryRepository(this._rows);

  final List<InventoryItem> _rows;

  List<InventoryItem> _scoped(String? branchId) {
    if (branchId == null) return _rows;
    return _rows.where((item) => item.branchId == branchId).toList();
  }

  @override
  Future<List<InventoryItem>> getInventory({String? branchId}) async =>
      List.unmodifiable(_scoped(branchId));

  @override
  Future<List<InventoryItem>> getLowStock({String? branchId}) async =>
      List.unmodifiable(
        _scoped(branchId).where((item) => item.isLowStock),
      );

  @override
  Future<List<InventoryItem>> getExpiringWithin({
    int days = 30,
    String? branchId,
  }) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final limit = today.add(Duration(days: days));
    return List.unmodifiable(
      _scoped(branchId).where((item) {
        final expiry = item.expiryDate;
        if (expiry == null) return false;
        final expiryDay = DateTime(expiry.year, expiry.month, expiry.day);
        return !expiryDay.isBefore(today) && !expiryDay.isAfter(limit);
      }),
    );
  }

  @override
  Future<InventoryItem> receiveStock({
    required String branchId,
    required String medicineId,
    required String batchNo,
    required DateTime mfgDate,
    required DateTime expiryDate,
    required int quantity,
    required int costMinor,
  }) async => throw UnimplementedError();

  @override
  Future<InventoryItem> adjustStock({
    required String batchId,
    required int deltaQty,
    required String reason,
  }) async => throw UnimplementedError();

  @override
  Future<InventoryItem> recordStockCount({
    required String batchId,
    required int countedQty,
    String? note,
  }) async => throw UnimplementedError();

  @override
  Future<InventoryItem> updateBatchStatus({
    required String batchId,
    required BatchStatus status,
    String? reason,
  }) async => throw UnimplementedError();
}
