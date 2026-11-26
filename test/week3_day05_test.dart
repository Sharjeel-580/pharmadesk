// Week 3 Day 5 tests — Phase 8 QA start (D114–D116).
//
// - Stock count through the layer (D114, closes the D111 follow-up):
//   `recordStockCount` books the correction through the engine
//   (ledger + audit), enqueues one sync payload for a non-zero
//   correction, dedupes a same-key retry, and books nothing for a
//   zero-variance count. The inventory notifier routes through the
//   layer, so the sync-status chip moves for stock counts.
// - Dialog-held idempotency keys (D115, closes the D54 UI gap): the
//   three stock dialogs mint one key each and reuse it on a retried
//   submit — proven at the notifier level (same key twice moves
//   stock once) and at the widget level (a failed receive submit
//   stays in the dialog with the error shown and the button live
//   again, instead of stuck on loading).
// - QA route walk: every route the Day 7 walk and the Day 4 desktop
//   audit do NOT cover — the new/order/edit forms, the detail
//   routes and the returns routes — loads with its own screen, no
//   placeholder, no "Page not found".
// - QA sweep: sidebar + mobile More-sheet entries for the Week 3
//   screens, paged report sections, and the inventory sync chip
//   moving after a stock count.
//
// What is NOT tested here (and why): `flutter build windows`
// cannot run on this Linux sandbox (D52) — the CI job
// `build-windows` owns that check. Live Firestore verification is
// blocked on the Firebase project (Dazy-only).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:pharmadesk/core/data/audit_log.dart';
import 'package:pharmadesk/core/data/firestore_schema.dart';
import 'package:pharmadesk/core/data/inventory_engine.dart';
import 'package:pharmadesk/core/data/production_data_layer.dart';
import 'package:pharmadesk/core/data/sync_queue.dart';
import 'package:pharmadesk/core/routing/app_router.dart';
import 'package:pharmadesk/core/services/repositories.dart';
import 'package:pharmadesk/core/theme/app_theme.dart';
import 'package:pharmadesk/core/theme/white_label.dart';
import 'package:pharmadesk/features/authentication/auth_state.dart';
import 'package:pharmadesk/features/inventory/inventory_provider.dart';
import 'package:pharmadesk/models/branch_inventory_location.dart';
import 'package:pharmadesk/models/inventory_item.dart';

const _dha = 'branch-dha-main';
const _org = demoOrganizationId;

/// Production layer over fresh mocks, with the repos + engine kept
/// so tests can assert against them (same helper shape as the
/// Week 3 Day 2 / Day 4 layer tests).
({
  ProductionDataLayer layer,
  MockInventoryRepository inventoryRepo,
  MockSupplierRepository supplierRepo,
  MockPurchaseOrderRepository purchaseOrderRepo,
  MockGoodsReceiptRepository goodsReceiptRepo,
  InventoryEngine engine,
  InMemoryAuditLogWriter audit,
  SyncQueue queue,
})
_layer() {
  final audit = InMemoryAuditLogWriter();
  final queue = SyncQueue(InMemorySyncStore());
  final engine = InventoryEngine(organizationId: _org, audit: audit);
  final inventoryRepo = MockInventoryRepository();
  final supplierRepo = MockSupplierRepository();
  final purchaseOrderRepo = MockPurchaseOrderRepository();
  final goodsReceiptRepo = MockGoodsReceiptRepository();
  final layer = ProductionDataLayer(
    organizationId: _org,
    inventoryRepo: inventoryRepo,
    saleRepo: MockSaleRepository(),
    orderRepo: MockOrderRepository(),
    customerRepo: MockCustomerRepository(),
    medicineRepo: MockMedicineRepository(),
    supplierRepo: supplierRepo,
    prescriptionRepo: MockPrescriptionRepository(),
    purchaseOrderRepo: purchaseOrderRepo,
    riderRepo: MockRiderRepository(),
    goodsReceiptRepo: goodsReceiptRepo,
    audit: audit,
    syncQueue: queue,
    engine: engine,
  );
  return (
    layer: layer,
    inventoryRepo: inventoryRepo,
    supplierRepo: supplierRepo,
    purchaseOrderRepo: purchaseOrderRepo,
    goodsReceiptRepo: goodsReceiptRepo,
    engine: engine,
    audit: audit,
    queue: queue,
  );
}

/// Pumps the ungated router app with a fresh container the test owns
/// (same harness as the Week 3 Day 4 widget tests), at a desktop
/// viewport by default, signed in as the Owner. An optional
/// pre-built container lets a test override providers first (D66:
/// `Override` cannot be named, so the container is built by the
/// caller, not by this helper).
Future<(ProviderContainer, GoRouter)> pumpRouterApp(
  WidgetTester tester, {
  Size size = const Size(1920, 1080),
  ProviderContainer? container,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final owned = container ?? ProviderContainer();
  addTearDown(owned.dispose);
  await owned.read(authProvider.notifier).signInAsDemo(DemoRole.owner);
  final router = createAppRouter();
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: owned,
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
  return (owned, router);
}

/// Scrolls a lazy ListView until [title] is built (Day 2 pattern:
/// the list only builds visible rows).
Future<void> scrollListToTitle(
  WidgetTester tester,
  Finder scrollable,
  String title,
) async {
  final target = find.descendant(of: scrollable, matching: find.text(title));
  for (var i = 0; i < 12 && target.evaluate().isEmpty; i++) {
    await tester.drag(scrollable, const Offset(0, -300));
    await tester.pumpAndSettle();
  }
}

/// Inventory repo that fails ONLY on receiveStock (the receive-dialog
/// failure-path test): every other call delegates to a fresh mock,
/// so the screen still loads and only the submit fails.
class _FailingReceiveInventoryRepository implements InventoryRepository {
  _FailingReceiveInventoryRepository(this._inner);

  final MockInventoryRepository _inner;

  @override
  Future<List<InventoryItem>> getInventory({String? branchId}) =>
      _inner.getInventory(branchId: branchId);

  @override
  Future<List<InventoryItem>> getLowStock({String? branchId}) =>
      _inner.getLowStock(branchId: branchId);

  @override
  Future<List<InventoryItem>> getExpiringWithin({
    int days = 30,
    String? branchId,
  }) => _inner.getExpiringWithin(days: days, branchId: branchId);

  @override
  Future<InventoryItem> receiveStock({
    required String branchId,
    required String medicineId,
    required String batchNo,
    required DateTime mfgDate,
    required DateTime expiryDate,
    required int quantity,
    required int costMinor,
  }) async {
    throw ArgumentError('Simulated receive failure.');
  }

  @override
  Future<InventoryItem> adjustStock({
    required String batchId,
    required int deltaQty,
    required String reason,
  }) =>
      _inner.adjustStock(batchId: batchId, deltaQty: deltaQty, reason: reason);

  @override
  Future<InventoryItem> recordStockCount({
    required String batchId,
    required int countedQty,
    String? note,
  }) => _inner.recordStockCount(
    batchId: batchId,
    countedQty: countedQty,
    note: note,
  );

  @override
  Future<InventoryItem> updateBatchStatus({
    required String batchId,
    required BatchStatus status,
    String? reason,
  }) => _inner.updateBatchStatus(
    batchId: batchId,
    status: status,
    reason: reason,
  );

  @override
  Future<InventoryItem> upsertInventoryItem(InventoryItem item) =>
      _inner.upsertInventoryItem(item);

  @override
  Future<BranchInventoryLocation?> getBranchLocation({
    required String branchId,
    required String medicineId,
  }) => _inner.getBranchLocation(branchId: branchId, medicineId: medicineId);

  @override
  Future<List<BranchInventoryLocation>> getBranchLocations({
    String? branchId,
  }) => _inner.getBranchLocations(branchId: branchId);

  @override
  Future<BranchInventoryLocation> saveBranchLocation(
    BranchInventoryLocation location,
  ) => _inner.saveBranchLocation(location);
}

void main() {
  group('Stock count through the layer (D114)', () {
    test(
      'count with variance corrects once and enqueues one sync op',
      () async {
        final t = _layer();
        final rows = await t.inventoryRepo.getInventory(branchId: _dha);
        final batch = rows.first;
        final before = batch.quantity;
        // The engine starts empty; the layer loads it from live stock
        // before booking, so the per-medicine total after the count is
        // the seeded DHA total for this medicine plus the variance.
        final seededTotal = rows
            .where((item) => item.medicineId == batch.medicineId)
            .fold<int>(0, (sum, item) => sum + item.quantity);

        final result = await t.layer.recordStockCount(
          batchId: batch.id,
          countedQty: before + 3,
          note: 'shelf recount',
          idempotencyKey: 'count-qa-1',
        );

        expect(result.isDuplicate, isFalse);
        expect(result.variance, 3);
        expect(result.item.quantity, before + 3);
        expect(result.movement, isNotNull);
        expect(result.movement!.quantity, 3);
        expect(result.movement!.reason, contains('Stock count'));
        expect(await t.queue.pendingCount(), 1);
        // The engine counter agrees with the repo row (no double
        // count: the engine loaded live stock before booking, so the
        // per-medicine total rises by exactly the variance).
        expect(
          t.engine.counterFor(batch.medicineId).quantityOnHand,
          seededTotal + 3,
        );
        // The correction leaves an audit entry (an adjustment-type
        // stock movement for this batch).
        final movements = await t.audit.entries(
          branchId: _dha,
          action: 'stock.adjustment',
        );
        expect(
          movements.where((entry) => entry.entityId == batch.id),
          isNotEmpty,
        );
      },
    );

    test(
      'same-key retry returns the original and moves nothing twice',
      () async {
        final t = _layer();
        final rows = await t.inventoryRepo.getInventory(branchId: _dha);
        final batch = rows.first;
        const key = 'count-qa-dedupe';

        final first = await t.layer.recordStockCount(
          batchId: batch.id,
          countedQty: batch.quantity + 2,
          idempotencyKey: key,
        );
        final second = await t.layer.recordStockCount(
          batchId: batch.id,
          countedQty: batch.quantity + 2,
          idempotencyKey: key,
        );

        expect(second.isDuplicate, isTrue);
        expect(second.item.id, first.item.id);
        expect(second.variance, first.variance);
        final after = (await t.inventoryRepo.getInventory(branchId: _dha))
            .firstWhere((item) => item.id == batch.id);
        expect(after.quantity, batch.quantity + 2);
        expect(await t.queue.pendingCount(), 1);
      },
    );

    test(
      'zero-variance count records but books no movement, no sync',
      () async {
        final t = _layer();
        final rows = await t.inventoryRepo.getInventory(branchId: _dha);
        final batch = rows.first;

        final result = await t.layer.recordStockCount(
          batchId: batch.id,
          countedQty: batch.quantity,
          idempotencyKey: 'count-qa-zero',
        );

        expect(result.isDuplicate, isFalse);
        expect(result.variance, 0);
        expect(result.movement, isNull);
        expect(result.item.quantity, batch.quantity);
        expect(await t.queue.pendingCount(), 0);
      },
    );

    test(
      'negative count and missing batch throw and enqueue nothing',
      () async {
        final t = _layer();
        final rows = await t.inventoryRepo.getInventory(branchId: _dha);
        final batch = rows.first;

        await expectLater(
          () => t.layer.recordStockCount(
            batchId: batch.id,
            countedQty: -1,
            idempotencyKey: 'count-qa-neg',
          ),
          throwsArgumentError,
        );
        await expectLater(
          () => t.layer.recordStockCount(
            batchId: 'no-such-batch',
            countedQty: 5,
            idempotencyKey: 'count-qa-missing',
          ),
          throwsArgumentError,
        );
        expect(await t.queue.pendingCount(), 0);
        final after = (await t.inventoryRepo.getInventory(branchId: _dha))
            .firstWhere((item) => item.id == batch.id);
        expect(after.quantity, batch.quantity);
      },
    );

    test('count through the notifier enqueues one sync op', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final batches = await container.read(inventoryProvider.future);
      final batch = batches.firstWhere((item) => item.branchId == _dha);

      final result = await container
          .read(inventoryProvider.notifier)
          .recordStockCount(batchId: batch.id, countedQty: batch.quantity + 2);

      expect(result, isNotNull);
      expect(result!.variance, 2);
      expect(result.item.quantity, batch.quantity + 2);
      final layer = container.read(productionDataLayerProvider);
      expect(await layer.pendingSyncCount(), 1);
    });
  });

  group('Dialog-held idempotency keys (D115, closes D54)', () {
    test(
      'receiveStock with the same key twice creates one batch row',
      () async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final before = await container.read(inventoryProvider.future);
        const key = 'stock-receive-qa-held';

        final first = await container
            .read(inventoryProvider.notifier)
            .receiveStock(
              branchId: _dha,
              medicineId: 'med-panadol-extra',
              batchNo: 'B-QA-HELD-KEY',
              mfgDate: DateTime(2026, 1, 1),
              expiryDate: DateTime(2027, 1, 1),
              quantity: 5,
              costMinor: 1000,
              idempotencyKey: key,
            );
        final second = await container
            .read(inventoryProvider.notifier)
            .receiveStock(
              branchId: _dha,
              medicineId: 'med-panadol-extra',
              batchNo: 'B-QA-HELD-KEY',
              mfgDate: DateTime(2026, 1, 1),
              expiryDate: DateTime(2027, 1, 1),
              quantity: 5,
              costMinor: 1000,
              idempotencyKey: key,
            );

        // A retried submit is the same receive, not a second batch.
        expect(second.id, first.id);
        final after = await container.read(inventoryProvider.future);
        expect(after.length, before.length + 1);
        final layer = container.read(productionDataLayerProvider);
        expect(await layer.pendingSyncCount(), 1);
      },
    );

    test(
      'adjustStock with the same key twice applies the delta once',
      () async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final batches = await container.read(inventoryProvider.future);
        final batch = batches.firstWhere((item) => item.branchId == _dha);
        const key = 'stock-adjust-qa-held';

        final first = await container
            .read(inventoryProvider.notifier)
            .adjustStock(
              batchId: batch.id,
              deltaQty: -2,
              reason: 'QA held-key retry',
              idempotencyKey: key,
            );
        final second = await container
            .read(inventoryProvider.notifier)
            .adjustStock(
              batchId: batch.id,
              deltaQty: -2,
              reason: 'QA held-key retry',
              idempotencyKey: key,
            );

        expect(first, isNotNull);
        expect(second, isNotNull);
        expect(second!.quantity, batch.quantity - 2);
        final layer = container.read(productionDataLayerProvider);
        expect(await layer.pendingSyncCount(), 1);
      },
    );

    test('recordStockCount with the same key twice counts once', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final batches = await container.read(inventoryProvider.future);
      final batch = batches.firstWhere((item) => item.branchId == _dha);
      const key = 'stock-count-qa-held';

      final first = await container
          .read(inventoryProvider.notifier)
          .recordStockCount(
            batchId: batch.id,
            countedQty: batch.quantity + 4,
            idempotencyKey: key,
          );
      final second = await container
          .read(inventoryProvider.notifier)
          .recordStockCount(
            batchId: batch.id,
            countedQty: batch.quantity + 4,
            idempotencyKey: key,
          );

      expect(first, isNotNull);
      expect(second, isNotNull);
      expect(second!.variance, 4);
      expect(second.item.quantity, batch.quantity + 4);
      final layer = container.read(productionDataLayerProvider);
      expect(await layer.pendingSyncCount(), 1);
    });

    testWidgets(
      'failed receive submit stays in the dialog with the error shown',
      (WidgetTester tester) async {
        // The layer writes through a repo that fails every receive;
        // the dialog must surface the failure and stay open with its
        // button live again (D115) — before the fix a layer throw
        // left it stuck on loading with no retry path.
        final failingRepo = _FailingReceiveInventoryRepository(
          MockInventoryRepository(),
        );
        final audit = InMemoryAuditLogWriter();
        final queue = SyncQueue(InMemorySyncStore());
        final engine = InventoryEngine(organizationId: _org, audit: audit);
        final failingLayer = ProductionDataLayer(
          organizationId: _org,
          inventoryRepo: failingRepo,
          saleRepo: MockSaleRepository(),
          orderRepo: MockOrderRepository(),
          customerRepo: MockCustomerRepository(),
          medicineRepo: MockMedicineRepository(),
          supplierRepo: MockSupplierRepository(),
          prescriptionRepo: MockPrescriptionRepository(),
          purchaseOrderRepo: MockPurchaseOrderRepository(),
          riderRepo: MockRiderRepository(),
          goodsReceiptRepo: MockGoodsReceiptRepository(),
          audit: audit,
          syncQueue: queue,
          engine: engine,
        );
        final container = ProviderContainer(
          overrides: [
            productionDataLayerProvider.overrideWithValue(failingLayer),
          ],
        );
        final (_, router) = await pumpRouterApp(tester, container: container);
        router.go('/medicines/med-panadol-extra');
        await tester.pumpAndSettle();

        await tester.ensureVisible(find.text('Receive stock'));
        await tester.tap(find.text('Receive stock'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).at(0), 'DHA-QA-FAIL');
        await tester.enterText(find.byType(TextField).at(1), '10');
        await tester.enterText(find.byType(TextField).at(2), '90');
        await tester.tap(find.text('Receive'));
        await tester.pumpAndSettle();

        // The dialog is still open (title + the detail screen's own
        // button both read "Receive stock") and the failure is shown.
        expect(find.text('Receive stock'), findsNWidgets(2));
        expect(find.text('Receive failed — please try again.'), findsOneWidget);
        // And the button is live again: a second tap retries (and
        // fails the same way — the repo still throws — instead of
        // doing nothing).
        await tester.tap(find.text('Receive'));
        await tester.pumpAndSettle();
        expect(find.text('Receive stock'), findsNWidgets(2));
        expect(find.text('Receive failed — please try again.'), findsOneWidget);
      },
    );
  });

  group('QA route walk: routes the Day 7 / Day 4 walks do not cover', () {
    testWidgets('forms, detail routes and returns routes all load', (
      WidgetTester tester,
    ) async {
      final (container, router) = await pumpRouterApp(tester);
      final orders = await container.read(orderRepositoryProvider).getOrders();
      final orderId = orders.first.id;
      final supplier = await container
          .read(supplierRepositoryProvider)
          .getById('sup-sami');
      final customer = await container
          .read(customerRepositoryProvider)
          .getById('cust-1');

      // Each entry: the route, and text only that screen shows.
      // (Shared shell text such as the sidebar module name is not
      // used — it would pass even on the wrong screen.)
      final routes = <(String, String)>[
        ('/orders/new', 'New Order'),
        ('/orders/$orderId', 'Customer'),
        ('/orders/$orderId/edit', 'Edit order $orderId'),
        ('/customers/cust-1', customer!.name),
        ('/suppliers/sup-sami', supplier!.name),
        ('/purchases/new', 'New purchase order'),
        ('/purchases/po-dha-1001', 'PO-DHA-1001'),
        ('/prescriptions/rx-dha-1', 'rx-dha-1'),
        ('/billing/returns', 'Returns & refunds'),
        ('/billing/returns/new', 'New return'),
        ('/billing/receipt/sale-missing', 'Sale not found'),
      ];
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
          find.text(marker),
          findsWidgets,
          reason: '$route should render its screen ($marker)',
        );
      }
    });
  });

  group('QA sweep: Week 3 screens', () {
    testWidgets('sidebar lists Salary and Auto Purchase List', (
      WidgetTester tester,
    ) async {
      final (_, router) = await pumpRouterApp(tester);
      // The sidebar ListView builds lazily: the Quarantine Outcomes
      // row (Week 5 Day 4) pushed Salary below the 1080px fold, so
      // scroll the sidebar to each item before asserting it (the
      // file's scrollListToTitle pattern).
      final sidebar = find.byKey(const ValueKey('app-sidebar-list'));
      await scrollListToTitle(tester, sidebar, 'Auto Purchase List');
      expect(find.text('Auto Purchase List'), findsWidgets);
      await scrollListToTitle(tester, sidebar, 'Salary');
      expect(find.text('Salary'), findsWidgets);
      router.go('/staff/salary');
      await tester.pumpAndSettle();
      expect(find.textContaining('Monthly total'), findsWidgets);
      router.go('/purchases/auto');
      await tester.pumpAndSettle();
      expect(find.text('Auto Purchase List'), findsWidgets);
    });

    testWidgets('mobile More sheet lists Salary and Auto Purchase List', (
      WidgetTester tester,
    ) async {
      // Mobile layout at 800px wide (the established mobile test
      // width — D33/D40). At a 390px phone width the shared top bar
      // overflows (QA finding, see the tracker follow-ups): the
      // More sheet itself is verified here, the top bar is a
      // separate responsive-layout fix.
      await pumpRouterApp(tester, size: const Size(800, 600));
      await tester.tap(find.text('More'));
      await tester.pumpAndSettle();
      expect(find.text('All modules'), findsOneWidget);
      // The sheet lists modules in sidebar order: Purchases (with
      // its Auto Purchase List sub-item) comes before Staff & HR
      // (with Salary), so scroll to the earlier entry first —
      // scrolling down to Salary first would scroll past it.
      await scrollListToTitle(
        tester,
        find.byType(ListView),
        'Auto Purchase List',
      );
      expect(find.text('Auto Purchase List'), findsWidgets);
      await scrollListToTitle(tester, find.byType(ListView), 'Salary');
      expect(find.text('Salary'), findsWidgets);
    });

    testWidgets('reports screen still renders its paged sections', (
      WidgetTester tester,
    ) async {
      final (_, router) = await pumpRouterApp(tester);
      router.go('/reports');
      await tester.pumpAndSettle();
      expect(find.text('Daily sales'), findsWidgets);
      // Every paged list shows "Page x of y" (D107); the reports
      // hub has several, so this is a widgets match, not one.
      expect(find.textContaining('Page 1 of'), findsWidgets);
    });

    testWidgets('inventory sync chip moves after a stock count', (
      WidgetTester tester,
    ) async {
      final (container, router) = await pumpRouterApp(tester);
      router.go('/inventory');
      await tester.pumpAndSettle();
      expect(find.textContaining('All synced'), findsWidgets);

      final batches = await container.read(inventoryProvider.future);
      final batch = batches.firstWhere((item) => item.branchId == _dha);
      await container
          .read(inventoryProvider.notifier)
          .recordStockCount(batchId: batch.id, countedQty: batch.quantity + 2);
      await tester.pumpAndSettle();

      // The count enqueued one sync payload (D114), so the chip on
      // the inventory screen now reads a pending count.
      expect(find.textContaining('1 pending sync'), findsWidgets);
    });
  });
}
