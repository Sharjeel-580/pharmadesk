// Week 3 Day 4 tests — Windows desktop verification + CI Windows
// build + D109 follow-up + salary edit flow (D110–D113).
//
// - Desktop bootstrap (D110): `initDesktopPlatform` is a no-op off
//   Windows; the sync store falls back to memory when SQLite cannot
//   open (the pre-ffi safety net); the `DesktopApp` shell renders at
//   1920×1080 and the desktop routes resolve.
// - D-01–D-35 audit: every desktop-present screen resolves to its
//   screen at desktop size, and the seven missing screens have no
//   route (the router's "Page not found" — they are documented
//   follow-ups, not half-built screens).
// - Layer receive/adjust (D111, closes D109): `receiveStock` /
//   `adjustStock` enqueue one sync payload each, dedupe on a retried
//   key, never double-apply, and the engine counter counts the
//   received batch exactly once. The inventory notifier routes
//   through the layer, so its writes move the sync-status chip.
// - Salary edit (D112): `canManageSalary` follows the SRS §5.1
//   matrix (Owner / HO Admin / Accountant write; Auditor read-only;
//   everyone else none); `saveRecord` gates + validates + saves;
//   the dialog edits a row end to end and an edited demo record
//   stops being demo; an Auditor sees the figures but no Edit
//   button.
//
// What is NOT tested here (and why): `flutter build windows`
// cannot run on this Linux sandbox (D11) — the CI job
// `build-windows` owns that check, and its YAML is validated
// separately (`python3 -c "import yaml; ..."`).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:pharmadesk/app/desktop_app.dart';
import 'package:pharmadesk/app/desktop_bootstrap.dart';
import 'package:pharmadesk/core/data/audit_log.dart';
import 'package:pharmadesk/core/data/auth_repository.dart';
import 'package:pharmadesk/core/data/firestore_schema.dart';
import 'package:pharmadesk/core/data/inventory_engine.dart';
import 'package:pharmadesk/core/data/production_data_layer.dart';
import 'package:pharmadesk/core/data/sync_queue.dart';
import 'package:pharmadesk/core/data/sync_store.dart';
import 'package:pharmadesk/core/routing/app_router.dart';
import 'package:pharmadesk/core/services/repositories.dart';
import 'package:pharmadesk/core/theme/app_theme.dart';
import 'package:pharmadesk/core/theme/white_label.dart';
import 'package:pharmadesk/features/authentication/auth_state.dart';
import 'package:pharmadesk/features/inventory/inventory_provider.dart';
import 'package:pharmadesk/features/staff/salary_logic.dart';
import 'package:pharmadesk/features/staff/salary_provider.dart';
import 'package:pharmadesk/models/salary_record.dart';

import 'test_helpers.dart';

const _dha = 'branch-dha-main';
const _glb = 'branch-demo-gulberg';
const _org = demoOrganizationId;

/// Production layer over fresh mocks, with the repos + engine kept
/// so tests can assert against them (same helper shape as the
/// Week 3 Day 2 layer tests).
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
/// (same harness as the Week 2 Day 5 / Week 3 Day 2 widget tests),
/// at a desktop viewport by default.
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

/// An Auditor user (SRS §5.1: `hrSalary` read-only). There is no
/// Auditor demo account, so widget tests sign in by overriding the
/// auth notifier with one that reports this user.
const _auditorUser = AppUser(
  uid: 'test-auditor',
  email: 'auditor@test.pharmadesk',
  displayName: 'Test Auditor',
  orgId: _org,
  branchIds: [_dha],
  roleKey: 'auditor',
);

class _AuditorAuthNotifier extends AuthNotifier {
  @override
  AppUser? build() => _auditorUser;
}

/// Pumps the router app signed in as the Auditor (see above).
Future<(ProviderContainer, GoRouter)> pumpRouterAppAsAuditor(
  WidgetTester tester,
) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1920, 1080);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final container = ProviderContainer(
    overrides: [authProvider.overrideWith(_AuditorAuthNotifier.new)],
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

AppUser _userFor(String roleKey, {List<String> branchIds = const [_dha]}) {
  return AppUser(
    uid: 'test-$roleKey',
    email: '$roleKey@test.pharmadesk',
    displayName: 'Test $roleKey',
    orgId: _org,
    branchIds: branchIds,
    roleKey: roleKey,
  );
}

SalaryRecord _salary({
  String id = '',
  String employeeId = 'staff-1',
  String branchId = _dha,
  String month = '2026-11',
  int base = 10000000,
  int allowances = 500000,
  int deductions = 0,
  bool isDemo = false,
}) => SalaryRecord(
  id: id,
  employeeId: employeeId,
  branchId: branchId,
  month: month,
  baseSalaryMinor: base,
  allowancesMinor: allowances,
  deductionsMinor: deductions,
  isDemo: isDemo,
);

void main() {
  group('Desktop bootstrap (D110)', () {
    test('initDesktopPlatform is a no-op off Windows', () async {
      // This host is Linux: the call must return immediately without
      // touching sqflite. On Windows the same call wires the FFI
      // factory — that path runs on the CI windows-latest runner.
      await initDesktopPlatform();
      await initDesktopPlatform();
    });

    test('sync store falls back to memory when SQLite cannot open',
        () async {
      // No FFI init happens in the test process, so the sqflite
      // open fails and the store must keep working in memory
      // (the pre-D110 safety net) instead of throwing.
      final store = SqfliteSyncStore(
        databaseName: 'day4-fallback-test.db',
      );
      final op = SyncOperation.create(
        idempotencyKey: 'fallback-op-1',
        entityType: 'stockTransaction',
        entityId: 'txn-1',
        branchId: _dha,
        organizationId: _org,
        kind: SyncOperationKind.create,
        payload: const {'path': 'branches/$_dha/stockTransactions/txn-1'},
      );
      final saved = await store.enqueue(op);
      expect(saved.idempotencyKey, 'fallback-op-1');
      expect(store.durable, isFalse);
      expect(await store.pendingCount(), 1);
      // A retried enqueue with the same key dedupes in memory too.
      final again = await store.enqueue(op);
      expect(again.idempotencyKey, 'fallback-op-1');
      expect(await store.pendingCount(), 1);
    });
  });

  group('Desktop app shell (D110)', () {
    testWidgets('DesktopApp renders the desktop shell at 1920x1080',
        (WidgetTester tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1920, 1080);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const ProviderScope(child: DesktopApp()));
      await tester.pump(const Duration(milliseconds: 1500));
      await tester.pumpAndSettle();
      expect(find.text('Sign in'), findsOneWidget);

      await signInAsDemoRole(tester, 'Owner');

      // Desktop layout at this width: the sidebar lists the modules
      // and the dashboard shows the owner-only branch comparison.
      expect(find.text('Billing & POS'), findsWidgets);
      expect(find.text('Staff & HR'), findsWidgets);
      expect(find.text('Branch comparison'), findsOneWidget);
    });
  });

  group('Desktop routes: D-01–D-35 audit (D110)', () {
    testWidgets('every desktop-present screen resolves at desktop size',
        (WidgetTester tester) async {
      final (container, router) = await pumpRouterApp(tester);
      await container
          .read(authProvider.notifier)
          .signInAsDemo(DemoRole.owner);
      await tester.pumpAndSettle();

      // Each entry: the route, and text only that screen shows.
      // (Shared shell text such as the sidebar module name is not
      // used — it would pass even on the wrong screen.)
      const present = <(String, String)>[
        ('/dashboard', 'Branch comparison'),
        ('/billing', 'Add medicines'),
        ('/billing/history', 'Sales history'),
        ('/inventory', 'Receive stock'),
        ('/medicines', 'Panadol Extra'),
        ('/medicines/med-panadol-extra', 'Batches —'),
        ('/orders', 'newest first'),
        ('/purchases', 'Purchase orders, goods receiving'),
        ('/purchases/auto', 'Auto Purchase List'),
        ('/prescriptions', 'New prescription'),
        ('/reports', 'Daily sales'),
        ('/staff', 'Staff directory'),
        ('/staff/attendance', 'Attendance —'),
        ('/staff/shifts', 'Shifts —'),
        ('/staff/salary', 'Monthly total'),
        ('/customers', 'Directory, purchase history and khata'),
        ('/suppliers', 'Profiles, contacts, purchase history'),
        ('/notifications', 'Alerts computed from live demo data'),
        ('/settings', 'Roles & Permissions'),
      ];
      for (final (route, marker) in present) {
        router.go(route);
        await tester.pumpAndSettle();
        expect(
          find.textContaining(marker),
          findsWidgets,
          reason: '$route should render its screen ($marker)',
        );
      }
    });

    testWidgets('the seven missing desktop screens have no route',
        (WidgetTester tester) async {
      final (container, router) = await pumpRouterApp(tester);
      await container
          .read(authProvider.notifier)
          .signInAsDemo(DemoRole.owner);
      await tester.pumpAndSettle();

      // D-16 stock transfer, D-21 riders, D-24 finance cashbook,
      // D-28 branch management, D-33 audit log, D-35 backup &
      // restore (+ the finance hub D-25/D-26 has no dedicated
      // route — its P&L lives inside Reports). None of these is
      // half-built: the router answers "Page not found" and the
      // tracker records each as a follow-up.
      const missing = <String>[
        '/stock-transfers',
        '/riders',
        '/finance',
        '/branches',
        '/audit-log',
        '/backup',
      ];
      for (final route in missing) {
        router.go(route);
        await tester.pumpAndSettle();
        expect(
          find.text('Page not found'),
          findsOneWidget,
          reason: '$route must not resolve yet',
        );
      }
    });
  });

  group('Layer receiveStock enqueues one sync payload (D111)', () {
    test('receive creates the batch, books the movement, enqueues once',
        () async {
      final t = _layer();
      final before = await t.inventoryRepo.getInventory(branchId: _dha);
      final baseOnHand = before
          .where((item) => item.medicineId == 'med-panadol-extra')
          .fold(0, (sum, item) => sum + item.quantity);

      final result = await t.layer.receiveStock(
        branchId: _dha,
        medicineId: 'med-panadol-extra',
        batchNo: 'B-DAY4-1',
        mfgDate: DateTime(2026, 1, 1),
        expiryDate: DateTime(2027, 1, 1),
        quantity: 10,
        costMinor: 5000,
      );

      expect(result.isDuplicate, isFalse);
      expect(result.batch.batchNo, 'B-DAY4-1');
      expect(result.batch.quantity, 10);
      expect(result.movements, hasLength(1));
      expect(result.movements.single.quantity, 10);
      // A manual receive has no goodsReceipts document — the
      // movement references the idempotency key, not a receipt.
      expect(result.movements.single.referenceType, 'stockReceive');
      // The engine counter counts the batch exactly once (the
      // load-before-create order — a load after the create would
      // double-count it here).
      expect(
        t.engine.counterFor('med-panadol-extra').quantityOnHand,
        baseOnHand + 10,
      );
      // One sync op: batch doc + stock-transaction doc.
      expect(await t.queue.pendingCount(), 1);
      final op = (await t.queue.pendingOperations()).single;
      expect(op.entityType, 'stockTransaction');
      expect(op.kind, SyncOperationKind.create);
      final operations =
          (op.payload['operations'] as List).cast<Map<String, dynamic>>();
      expect(operations.length, 2);
      expect(
        operations.map((o) => o['path'] as String),
        containsAll([
          contains('batches/${result.batch.id}'),
          contains('stockTransactions/'),
        ]),
      );
    });

    test('same-key retry returns the original batch, no second row',
        () async {
      final t = _layer();
      const key = 'stock-receive-day4-dup-1';
      final first = await t.layer.receiveStock(
        branchId: _dha,
        medicineId: 'med-panadol-extra',
        batchNo: 'B-DAY4-DUP',
        mfgDate: DateTime(2026, 1, 1),
        expiryDate: DateTime(2027, 1, 1),
        quantity: 4,
        costMinor: 5000,
        idempotencyKey: key,
      );
      final second = await t.layer.receiveStock(
        branchId: _dha,
        medicineId: 'med-panadol-extra',
        batchNo: 'B-DAY4-DUP',
        mfgDate: DateTime(2026, 1, 1),
        expiryDate: DateTime(2027, 1, 1),
        quantity: 4,
        costMinor: 5000,
        idempotencyKey: key,
      );
      expect(second.isDuplicate, isTrue);
      expect(second.batch.id, first.batch.id);
      expect(second.movements, isEmpty);
      final rows = (await t.inventoryRepo.getInventory(branchId: _dha))
          .where((item) => item.batchNo == 'B-DAY4-DUP')
          .toList();
      expect(rows, hasLength(1));
      expect(await t.queue.pendingCount(), 1);
    });

    test('a rejected receive enqueues nothing', () async {
      final t = _layer();
      await expectLater(
        () => t.layer.receiveStock(
          branchId: _dha,
          medicineId: 'med-panadol-extra',
          batchNo: 'B-DAY4-BAD',
          mfgDate: DateTime(2026, 1, 1),
          expiryDate: DateTime(2027, 1, 1),
          quantity: 0,
          costMinor: 5000,
        ),
        throwsArgumentError,
      );
      expect(await t.queue.pendingCount(), 0);
    });
  });

  group('Layer adjustStock enqueues one sync payload (D111)', () {
    test('adjust applies the delta and enqueues an update op', () async {
      final t = _layer();
      final batches = await t.inventoryRepo.getInventory(branchId: _dha);
      final batch = batches.first;
      final before = batch.quantity;

      final movement = await t.layer.adjustStock(
        batchId: batch.id,
        deltaQty: -2,
        reason: 'Damaged in handling',
      );

      expect(movement.quantity, -2);
      expect(movement.batchId, batch.id);
      final after = (await t.inventoryRepo.getInventory())
          .firstWhere((item) => item.id == batch.id);
      expect(after.quantity, before - 2);
      expect(await t.queue.pendingCount(), 1);
      final op = (await t.queue.pendingOperations()).single;
      expect(op.entityType, 'stockTransaction');
      expect(op.kind, SyncOperationKind.update);
      final operations =
          (op.payload['operations'] as List).cast<Map<String, dynamic>>();
      expect(operations.length, 2);
      expect(
        operations.map((o) => o['path'] as String),
        containsAll([
          contains('stockTransactions/${movement.id}'),
          contains('inventory/'),
        ]),
      );
    });

    test('same-key retry returns the original movement, no double-apply',
        () async {
      final t = _layer();
      final batch = (await t.inventoryRepo.getInventory(branchId: _dha))
          .first;
      final before = batch.quantity;
      const key = 'stock-adjust-day4-dup-1';
      final first = await t.layer.adjustStock(
        batchId: batch.id,
        deltaQty: -3,
        reason: 'Stock count correction',
        idempotencyKey: key,
      );
      final second = await t.layer.adjustStock(
        batchId: batch.id,
        deltaQty: -3,
        reason: 'Stock count correction',
        idempotencyKey: key,
      );
      expect(second.id, first.id);
      final after = (await t.inventoryRepo.getInventory())
          .firstWhere((item) => item.id == batch.id);
      expect(after.quantity, before - 3);
      expect(await t.queue.pendingCount(), 1);
    });

    test('adjust below zero throws and enqueues nothing', () async {
      final t = _layer();
      final batch = (await t.inventoryRepo.getInventory(branchId: _dha))
          .first;
      await expectLater(
        () => t.layer.adjustStock(
          batchId: batch.id,
          deltaQty: -(batch.quantity + 1),
          reason: 'Too much',
        ),
        throwsArgumentError,
      );
      expect(await t.queue.pendingCount(), 0);
    });

    test('returns-style restock carries the sale reference into the payload',
        () async {
      final t = _layer();
      final batch = (await t.inventoryRepo.getInventory(branchId: _dha))
          .first;
      await t.layer.adjustStock(
        batchId: batch.id,
        deltaQty: 2,
        reason: 'Sale return INV-1 — damaged pack',
        referenceId: 'sale-1',
      );
      expect(await t.queue.pendingCount(), 1);
      final op = (await t.queue.pendingOperations()).single;
      final operations =
          (op.payload['operations'] as List).cast<Map<String, dynamic>>();
      final txn = operations.firstWhere(
        (o) => (o['path'] as String).contains('stockTransactions/'),
      );
      expect((txn['data'] as Map)['referenceId'], 'sale-1');
    });
  });

  group('InventoryNotifier routes through the layer (D111)', () {
    test('receiveStock through the notifier enqueues one sync op',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final before = await container.read(inventoryProvider.future);
      final created = await container
          .read(inventoryProvider.notifier)
          .receiveStock(
            branchId: _dha,
            medicineId: 'med-panadol-extra',
            batchNo: 'B-DAY4-NOTIFIER',
            mfgDate: DateTime(2026, 1, 1),
            expiryDate: DateTime(2027, 1, 1),
            quantity: 5,
            costMinor: 1000,
          );
      expect(created.batchNo, 'B-DAY4-NOTIFIER');
      final after = await container.read(inventoryProvider.future);
      expect(after.length, before.length + 1);
      final layer = container.read(productionDataLayerProvider);
      expect(await layer.pendingSyncCount(), 1);
    });

    test('adjustStock through the notifier enqueues one sync op',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final batches = await container.read(inventoryProvider.future);
      final batch = batches.firstWhere(
        (item) => item.branchId == _dha,
      );
      final updated = await container
          .read(inventoryProvider.notifier)
          .adjustStock(
            batchId: batch.id,
            deltaQty: -1,
            reason: 'Day 4 test adjustment',
          );
      expect(updated, isNotNull);
      expect(updated!.quantity, batch.quantity - 1);
      final layer = container.read(productionDataLayerProvider);
      expect(await layer.pendingSyncCount(), 1);
    });

    test('a rejected adjustment returns null and enqueues nothing',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final batches = await container.read(inventoryProvider.future);
      final batch = batches.firstWhere(
        (item) => item.branchId == _dha,
      );
      final updated = await container
          .read(inventoryProvider.notifier)
          .adjustStock(
            batchId: batch.id,
            deltaQty: -(batch.quantity + 50),
            reason: 'Too much',
          );
      expect(updated, isNull);
      final layer = container.read(productionDataLayerProvider);
      expect(await layer.pendingSyncCount(), 0);
    });
  });

  group('Salary edit gating (D112)', () {
    test('canManageSalary follows the SRS §5.1 matrix', () {
      expect(canManageSalary(_userFor('owner'), _dha), isTrue);
      expect(canManageSalary(_userFor('ho_admin'), _dha), isTrue);
      expect(canManageSalary(_userFor('accountant'), _dha), isTrue);
      expect(canManageSalary(_userFor('auditor'), _dha), isFalse);
      expect(canManageSalary(_userFor('branch_manager'), _dha), isFalse);
      expect(canManageSalary(_userFor('pharmacist'), _dha), isFalse);
      expect(canManageSalary(_userFor('cashier'), _dha), isFalse);
      expect(canManageSalary(_userFor('inventory_manager'), _dha), isFalse);
      expect(canManageSalary(_userFor('super_admin'), _dha), isFalse);
      // A null user (signed-out guard is the router) is allowed —
      // same rule as the rest of the permission service (D70).
      expect(canManageSalary(null, _dha), isTrue);
      // `hrSalary` is `allowed` (not `own`) for its holders, so it
      // spans the whole org — branchIds do not scope it (D70:
      // `allowed` spans the org; only `own` requires the branch in
      // `branchIds`). An owner with a DHA-only branch list may
      // still manage Gulberg figures.
      expect(
        canManageSalary(_userFor('owner', branchIds: [_dha]), _glb),
        isTrue,
      );
    });

    test('saveRecord saves for the owner and refreshes the list',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final result = await container
          .read(salaryProvider.notifier)
          .saveRecord(
            record: _salary(
              employeeId: 'staff-4',
              month: '2026-11',
              base: 7000000,
              allowances: 400000,
              deductions: 100000,
            ),
            user: _userFor('owner'),
          );
      expect(result.error, isNull);
      expect(result.record, isNotNull);
      expect(result.record!.netMinor, 7300000);
      expect(result.record!.id, 'sal-staff-4-2026-11');
      final records = await container.read(salaryProvider.future);
      expect(
        records.any(
          (r) => r.employeeId == 'staff-4' && r.baseSalaryMinor == 7000000,
        ),
        isTrue,
      );
    });

    test('saveRecord refuses the auditor and the branch manager',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      for (final roleKey in ['auditor', 'branch_manager']) {
        final result = await container
            .read(salaryProvider.notifier)
            .saveRecord(
              record: _salary(),
              user: _userFor(roleKey),
            );
        expect(result.record, isNull);
        expect(result.error, contains('HR: salary records'));
      }
      // Nothing was written for either refused attempt.
      final records = await container.read(salaryProvider.future);
      expect(
        records
            .where((r) => r.employeeId == 'staff-1' && r.month == '2026-11')
            .single
            .baseSalaryMinor,
        25000000,
      );
    });

    test('saveRecord refuses an invalid record before the repository',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final result = await container
          .read(salaryProvider.notifier)
          .saveRecord(
            record: _salary(base: 100000, allowances: 0, deductions: 200000),
            user: _userFor('owner'),
          );
      expect(result.record, isNull);
      expect(
        result.error,
        'Net salary cannot be negative — deductions exceed pay.',
      );
    });
  });

  group('Salary edit dialog widget (D112)', () {
    testWidgets('owner edits a row end to end; demo badge clears',
        (WidgetTester tester) async {
      final (container, router) = await pumpRouterApp(tester);
      await container
          .read(authProvider.notifier)
          .signInAsDemo(DemoRole.owner);
      await tester.pumpAndSettle();
      router.go('/staff/salary');
      await tester.pumpAndSettle();

      // DHA rows, sorted by name — Ayesha Khan first, all demo.
      expect(find.text('Ayesha Khan'), findsOneWidget);
      expect(find.text('Demo'), findsNWidgets(7));
      expect(find.byIcon(Icons.edit_outlined), findsNWidgets(7));

      final editButton = find.byIcon(Icons.edit_outlined).first;
      await tester.ensureVisible(editButton);
      await tester.pumpAndSettle();
      await tester.tap(editButton);
      await tester.pumpAndSettle();

      expect(find.text('Edit salary — Ayesha Khan'), findsOneWidget);
      expect(find.text('Net: Rs 250,000.00'), findsOneWidget);
      final fields = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );
      expect(fields, findsNWidgets(3));
      await tester.enterText(fields.at(0), '260000');
      await tester.pumpAndSettle();
      expect(find.text('Net: Rs 260,000.00'), findsOneWidget);

      await tester.tap(find.text('Save salary'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Saved Ayesha Khan'), findsOneWidget);
      expect(find.text('Rs 260,000.00'), findsOneWidget);
      expect(find.text('Rs 872,000.00'), findsOneWidget);
      // The edited row is staff-entered now, not seeded demo.
      expect(find.text('Demo'), findsNWidgets(6));
    });

    testWidgets('auditor sees the figures but no Edit button',
        (WidgetTester tester) async {
      final (_, router) = await pumpRouterAppAsAuditor(tester);
      router.go('/staff/salary');
      await tester.pumpAndSettle();

      expect(find.text('Ayesha Khan'), findsOneWidget);
      expect(find.text('Rs 250,000.00'), findsOneWidget);
      expect(find.byIcon(Icons.edit_outlined), findsNothing);
    });
  });
}
