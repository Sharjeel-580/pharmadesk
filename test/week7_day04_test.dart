// Week 7 Day 4 tests — Phase 8 QA depth, fourth pass (D174, brief §5).
//
// - D174: fresh full 390px sweep + 47-route walk with the CORRECTED
//   `FlutterError.onError` trap (D170 standard — the D160
//   `takeException` drain undercounts; every sweep figure in this
//   file and in `docs/day-36-progress.md` states its trap).
// - D170 fixes re-verified in place (supplier detail, `/reports`
//   dropdown + PagedListControls, supplier payment dialog dropdown,
//   `/branches` row).
// - Week 7 new / changed screens swept: the quarantine outcome
//   queue (populated + decided), the Return / Dispose dialog on a
//   quarantined batch, the backup screen + restore confirm dialog
//   (D169 wording, D173 re-key) — plus the full D160 screen list
//   re-run with the corrected trap.
// - Finance agreement, THIRD pass: the guarded finance writes +
//   idempotent payments again (new keys / amounts), plus the
//   re-keyed restore (D173) — a restored sale moves the P&L and
//   the derived counter by exactly its amount, once, never twice.
// - Offline-queue + role-gate coverage for every Week 7 flow: the
//   persisted quarantine outcome queue (D171), the fake-transport
//   transaction / batch paths as exercised by the repos (D172),
//   and the re-keyed restore (D173).

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:pharmadesk/core/data/audit_log.dart';
import 'package:pharmadesk/core/data/auth_repository.dart';
import 'package:pharmadesk/core/data/backup_export.dart';
import 'package:pharmadesk/core/data/firestore_repositories.dart';
import 'package:pharmadesk/core/data/firestore_schema.dart';
import 'package:pharmadesk/core/data/inventory_engine.dart';
import 'package:pharmadesk/core/data/permission_service.dart';
import 'package:pharmadesk/core/data/production_data_layer.dart';
import 'package:pharmadesk/core/data/report_counters.dart';
import 'package:pharmadesk/core/data/sync_queue.dart';
import 'package:pharmadesk/core/routing/app_router.dart';
import 'package:pharmadesk/core/services/repositories.dart';
import 'package:pharmadesk/core/theme/app_theme.dart';
import 'package:pharmadesk/core/theme/white_label.dart';
import 'package:pharmadesk/features/authentication/auth_state.dart';
import 'package:pharmadesk/features/branches/branch_directory.dart';
import 'package:pharmadesk/features/finance/finance_logic.dart';
import 'package:pharmadesk/features/finance/finance_provider.dart';
import 'package:pharmadesk/features/inventory/inventory_provider.dart';
import 'package:pharmadesk/features/inventory/quarantine_outcome_queue.dart';
import 'package:pharmadesk/features/reports/analytics_logic.dart';
import 'package:pharmadesk/features/settings/org_settings.dart';
import 'package:pharmadesk/features/suppliers/supplier_logic.dart';
import 'package:pharmadesk/models/branch.dart';
import 'package:pharmadesk/models/cash_reconciliation.dart';
import 'package:pharmadesk/models/closing_correction.dart';
import 'package:pharmadesk/models/financial_transaction.dart';
import 'package:pharmadesk/models/inventory_item.dart';
import 'package:pharmadesk/models/quarantine_outcome_request.dart';
import 'package:pharmadesk/models/sale.dart';
import 'package:pharmadesk/models/supplier_payment.dart';

import 'week2_day03_test.dart';

const _dha = 'branch-dha-main';
const _org = demoOrganizationId;
const _phoneSize = Size(390, 844);

DateTime _day(int daysAgo) {
  final now = DateTime.now();
  final day = now.subtract(Duration(days: daysAgo));
  return DateTime(day.year, day.month, day.day);
}

AppUser _userFor(
  String roleKey, {
  List<String> branchIds = const [_dha],
  String? uid,
}) {
  return AppUser(
    uid: uid ?? 'test-$roleKey',
    email: '$roleKey@test.pharmadesk',
    displayName: 'Test $roleKey',
    orgId: _org,
    branchIds: branchIds,
    roleKey: roleKey,
  );
}

class _FixedAuthNotifier extends AuthNotifier {
  _FixedAuthNotifier(this.user);

  final AppUser user;

  @override
  AppUser? build() => user;
}

class _MutableAuthNotifier extends AuthNotifier {
  _MutableAuthNotifier(this._user);

  AppUser? _user;

  set user(AppUser? value) {
    _user = value;
    state = value;
  }

  @override
  AppUser? build() => _user;
}

/// Production layer over fresh mocks, with the inventory, outcome
/// and branch repos exposed so tests can simulate a restart: a
/// fresh layer over the same repos is a new app session over the
/// same persisted data (D171 pattern).
class _Harness {
  _Harness()
    : inventoryRepo = MockInventoryRepository(),
      outcomeRepo = MockQuarantineOutcomeRequestRepository(),
      branchRepo = MockBranchRepository(),
      audit = InMemoryAuditLogWriter() {
    layer = _buildLayer();
  }

  final MockInventoryRepository inventoryRepo;
  final MockQuarantineOutcomeRequestRepository outcomeRepo;
  final MockBranchRepository branchRepo;
  final InMemoryAuditLogWriter audit;
  late final ProductionDataLayer layer;

  ProductionDataLayer _buildLayer() {
    return ProductionDataLayer(
      organizationId: _org,
      inventoryRepo: inventoryRepo,
      saleRepo: MockSaleRepository(),
      orderRepo: MockOrderRepository(),
      customerRepo: MockCustomerRepository(),
      medicineRepo: MockMedicineRepository(),
      supplierRepo: MockSupplierRepository(),
      prescriptionRepo: MockPrescriptionRepository(),
      purchaseOrderRepo: MockPurchaseOrderRepository(),
      riderRepo: MockRiderRepository(),
      quarantineOutcomeRequestRepo: outcomeRepo,
      branchRepo: branchRepo,
      audit: audit,
      syncQueue: SyncQueue(InMemorySyncStore()),
      engine: InventoryEngine(organizationId: _org, audit: audit),
    );
  }

  ProductionDataLayer restartedLayer() => _buildLayer();
}

Future<void> _deactivate(_Harness h, String branchId) async {
  final branch = await h.branchRepo.getById(branchId);
  await h.branchRepo.updateBranch(branch!.copyWith(active: false));
}

Future<void> _reactivate(_Harness h, String branchId) async {
  final branch = await h.branchRepo.getById(branchId);
  await h.branchRepo.updateBranch(branch!.copyWith(active: true));
}

/// The seeded MedServe open payable (D92): Rs 48,250 outstanding
/// on `sled-2`. Returns allocations for a payment of [amountMinor].
Future<List<PaymentAllocation>> _medServeAllocations(
  _Harness h,
  int amountMinor,
) async {
  final ledger = await h.layer.supplierRepo.getLedgerEntries('sup-medserve');
  final open = openPayableBalances(supplierLedgerSignedEntries(ledger));
  return allocateSupplierPayment(open: open, paymentMinor: amountMinor);
}

/// Production layer whose sale + order repos are the Firestore
/// implementations over the Day 34 fake transport (D172); every
/// other repo is a mock. `seedBranches` runs first so the
/// Firestore repos can enumerate branches and read branch codes
/// (same shape as the Day 35 `_FirestoreHarness`).
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

Future<(ProviderContainer, GoRouter)> pumpRouterApp(
  WidgetTester tester, {
  Size size = const Size(1920, 1080),
  ProductionDataLayer? layerOverride,
  AppUser? user,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final container = ProviderContainer(
    overrides: [
      if (layerOverride != null)
        productionDataLayerProvider.overrideWithValue(layerOverride),
      if (user != null)
        authProvider.overrideWith(() => _FixedAuthNotifier(user)),
    ],
  );
  addTearDown(container.dispose);
  final router = createAppRouter(
    isSignedIn: user == null
        ? null
        : () => container.read(authProvider) != null,
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

Future<(ProviderContainer, GoRouter)> pumpRouterAppAsRole(
  WidgetTester tester,
  String roleKey, {
  List<String> branchIds = const [_dha],
  Size size = const Size(1920, 1080),
}) async {
  return pumpRouterApp(
    tester,
    size: size,
    user: _userFor(roleKey, branchIds: branchIds),
  );
}

Future<(ProviderContainer, GoRouter, _MutableAuthNotifier)>
pumpRouterAppWithMutableAuth(
  WidgetTester tester,
  AppUser initialUser, {
  Size size = const Size(1920, 1080),
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final auth = _MutableAuthNotifier(initialUser);
  final container = ProviderContainer(
    overrides: [authProvider.overrideWith(() => auth)],
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
  return (container, router, auth);
}

/// D170 — the overflow trap (the standard since Day 32): counts
/// every RenderFlex overflow the FlutterError handler sees.
///
/// The D160 helper (`takeException` + count "RenderFlex overflowed"
/// in the drained strings) UNDERCOUNTS: when two overflows arrive
/// in one pump without an acknowledgement in between, the binding
/// collapses them into a single "Multiple exceptions (2)..." string
/// whose text contains no "RenderFlex overflowed" at all — so the
/// D160 count reads 0 for a screen that really overflowed twice.
/// This trap records each error as the handler sees it (and still
/// forwards to the binding's handler, so `takeException` keeps
/// working and the test does not fail at teardown for an
/// unacknowledged exception).
class _OverflowTrap {
  _OverflowTrap() : _previous = FlutterError.onError {
    FlutterError.onError = (details) {
      _seen.add(details.toString());
      _previous?.call(details);
    };
  }

  // Inferred from `FlutterError.onError` (do not name the typedef:
  // it is not exported through material.dart).
  final dynamic _previous;
  final _seen = <String>[];

  int get overflowCount {
    // Count each DISTINCT overflow once: the framework re-reports
    // the same overflow on every pump that lays it out again, so a
    // raw report count would grow with the number of pump steps
    // (the cashbook dialog read 4 for one overflow). Two different
    // overflows have different RenderFlex identities in their
    // message, so distinct messages are distinct overflows.
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

/// The D160 drain, kept only for the harness-proof test below:
/// `takeException` strings, counted the D160 way.
List<String> _drainExceptionsD160(WidgetTester tester) {
  final messages = <String>[];
  Object? error;
  while ((error = tester.takeException()) != null) {
    messages.add(error.toString());
  }
  return messages;
}

int _countOverflowsD160(List<String> drained) {
  var count = 0;
  for (final message in drained) {
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

/// Pumps the router app at phone width with the overflow trap
/// already installed, so every overflow the pump produces is
/// captured (D170 pattern — install BEFORE pumping).
Future<(ProviderContainer, GoRouter, _OverflowTrap)> _pumpSweepApp(
  WidgetTester tester,
  String roleKey, {
  List<String> branchIds = const [_dha],
}) async {
  final trap = _OverflowTrap();
  addTearDown(trap.dispose);
  final (container, router) = await pumpRouterAppAsRole(
    tester,
    roleKey,
    branchIds: branchIds,
    size: _phoneSize,
  );
  return (container, router, trap);
}

Sale _sale({
  required String id,
  String branchId = _dha,
  required SalePaymentMethod method,
  required int amountMinor,
  required DateTime createdAt,
}) {
  return Sale(
    id: id,
    invoiceNumber: 'INV-TEST-$id',
    branchId: branchId,
    cashierName: 'Test Cashier',
    items: const [],
    subtotalMinor: amountMinor,
    totalMinor: amountMinor,
    paymentMethod: method,
    payments: [SalePayment(method: method, amountMinor: amountMinor)],
    cashReceivedMinor: method == SalePaymentMethod.cash ? amountMinor : 0,
    idempotencyKey: 'sale-test-$id',
    createdAt: createdAt,
  );
}

ClosingCorrection _correction({String originalId = 'dc-1'}) {
  return ClosingCorrection(
    id: '',
    branchId: _dha,
    originalClosingId: originalId,
    date: _day(0),
    correctedIncomeMinor: 200000,
    correctedExpenseMinor: 100000,
    correctedClosingBalanceMinor: 100000,
    reason: 'Income entered twice',
    correctedBy: 'test-owner',
    correctedAt: DateTime.now(),
  );
}

CashReconciliation _reconciliation() {
  return CashReconciliation(
    id: '',
    branchId: _dha,
    date: _day(0),
    expectedMinor: 50000,
    countedMinor: 50000,
    differenceMinor: 0,
    countedBy: 'test-owner',
    countedAt: DateTime.now(),
  );
}

/// A container whose queue notifier + inventory read through the
/// harness layer and its shared inventory repo (the app wiring,
/// with the layer swapped in — D171 / Day 33 pattern).
Future<ProviderContainer> _quarantineContainer(
  _Harness h,
  ProductionDataLayer layer, {
  required _MutableAuthNotifier auth,
}) async {
  final container = ProviderContainer(
    overrides: [
      productionDataLayerProvider.overrideWithValue(layer),
      inventoryRepositoryProvider.overrideWithValue(h.inventoryRepo),
      authProvider.overrideWith(() => auth),
    ],
  );
  addTearDown(container.dispose);
  // Initialize the auth notifier now: a later mid-test user swap
  // writes `state`, which throws on a notifier that was never
  // instantiated (Day 33 lesson — a watching screen reads auth on
  // build, so a fresh container must too).
  container.read(authProvider);
  await container.read(inventoryProvider.future);
  return container;
}

Future<InventoryItem> _quarantinePanadol(ProviderContainer c) async {
  final batch = (await c
          .read(inventoryRepositoryProvider)
          .getInventory(branchId: _dha))
      .firstWhere((item) => item.medicineId == 'med-panadol-extra');
  final updated = await c
      .read(inventoryProvider.notifier)
      .quarantineBatch(batchId: batch.id, reason: 'Suspected damage');
  return updated!;
}

/// Reads the queue after a (re)build has had time to load: the
/// notifier build starts `refresh()` async, so the first read
/// triggers it and the delay lets the load land (D146 pattern).
Future<List<QuarantineOutcomeRequest>> _readQueue(
  ProviderContainer container,
) async {
  container.read(quarantineOutcomeQueueProvider);
  await Future<void>.delayed(const Duration(milliseconds: 100));
  return container.read(quarantineOutcomeQueueProvider);
}

/// Files one dispose request for a quarantined Panadol batch as
/// the inventory manager, through the queue notifier. Returns the
/// filed request and the quarantined batch.
Future<(QuarantineOutcomeRequest, InventoryItem)> _fileDisposeRequest(
  ProviderContainer container,
) async {
  final batch = await _quarantinePanadol(container);
  final request = await container
      .read(quarantineOutcomeQueueProvider.notifier)
      .requestOutcome(
        batch: batch,
        medicineName: 'Panadol Extra',
        outcome: QuarantineOutcome.dispose,
        reason: 'Damaged beyond use',
      );
  return (request!, batch);
}

void main() {
  group('D174 — sweep harness: the corrected trap is still the standard', () {
    testWidgets('two simultaneous overflows: D160 drain counts 0, '
        'the trap counts 2', (tester) async {
      final trap = _OverflowTrap();
      addTearDown(trap.dispose);
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = _phoneSize;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      // Two Rows that each overflow the 390px line by 10px in the
      // same layout pass — exactly the shape the supplier detail
      // screen had on Day 32 (aging badges 63px + Export row 0.2px).
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                Row(
                  children: [
                    SizedBox(
                      width: 400,
                      height: 20,
                      child: Container(color: Colors.red),
                    ),
                  ],
                ),
                Row(
                  children: [
                    SizedBox(
                      width: 400,
                      height: 20,
                      child: Container(color: Colors.blue),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // The D160 helper drains the binding's pending exception —
      // one "Multiple exceptions (2)..." string with no overflow
      // text in it — and counts ZERO for two real overflows.
      expect(_countOverflowsD160(_drainExceptionsD160(tester)), 0);
      // The trap saw each error as the handler received it.
      expect(trap.overflowCount, 2);
    });
  });

  group('Phase 8 — route walk: every route resolves (Week 7 re-run)', () {
    testWidgets('Week 7 hub routes resolve', (tester) async {
      final (_, router) = await pumpRouterApp(
        tester,
        size: const Size(1280, 800),
      );
      const routes = <(String, String)>[
        ('/inventory/quarantine-outcomes', 'Quarantine Outcomes'),
        ('/inventory/adjustments', 'Adjustment Approvals'),
        ('/finance/franchise', 'Franchise Royalties'),
        ('/finance', 'Finance'),
        ('/finance/cashbook', 'Cashbook'),
        ('/finance/aging', 'Payables & Receivables'),
        ('/finance/statements', 'P&L & Statements'),
        ('/branches', 'Branch Management'),
        ('/branches/branch-dha-main', 'Demo Branch — DHA'),
        ('/audit-log', 'Audit Log'),
        ('/backup', 'Backup & Restore'),
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

    testWidgets('full route walk: every route in the router resolves', (
      tester,
    ) async {
      final (container, router) = await pumpRouterApp(
        tester,
        size: const Size(1280, 800),
      );
      final orders = await container.read(orderRepositoryProvider).getOrders();
      final orderId = orders.first.id;
      final customer = await container
          .read(customerRepositoryProvider)
          .getById('cust-1');
      final supplier = await container
          .read(supplierRepositoryProvider)
          .getById('sup-sami');
      // Week 7 added NO routes (brief §1–§6 are queue persistence,
      // fake-transport semantics, restore re-keying, QA depth and
      // demo polish on existing screens), so the walk is the same
      // 47 shell routes as Day 27 / Day 32 — the count is asserted,
      // not assumed.
      final routes = <(String, String?)>[
        ('/dashboard', 'Top-selling medicines'),
        ('/profile', 'Profile'),
        ('/orders', 'Orders'),
        ('/orders/new', 'New Order'),
        ('/orders/$orderId/edit', 'Edit order $orderId'),
        ('/orders/$orderId', 'Customer'),
        ('/medicines', 'Medicines'),
        ('/medicines/med-panadol-extra', 'Panadol Extra'),
        ('/inventory', 'Inventory'),
        ('/inventory/transfers', 'Stock Transfers'),
        ('/inventory/transfers/new', 'New Transfer'),
        ('/inventory/transfers/tr-demo-1', 'TR-DHA-GLB-1001'),
        ('/inventory/adjustments', 'Adjustment Approvals'),
        ('/inventory/quarantine-outcomes', 'Quarantine Outcomes'),
        ('/riders', 'Riders & Delivery'),
        ('/riders/rider-1', 'Bilal Ahmed'),
        ('/billing', 'Billing & POS'),
        ('/billing/history', 'Sales history'),
        ('/billing/returns', 'Returns & refunds'),
        ('/billing/returns/new', 'New return'),
        ('/billing/receipt/sale-missing', 'Sale not found'),
        ('/customers', 'Customers'),
        ('/customers/cust-1', customer!.name),
        ('/suppliers', 'Suppliers'),
        ('/suppliers/sup-sami', supplier!.name),
        ('/purchases', 'Purchases'),
        ('/purchases/new', 'New purchase order'),
        ('/purchases/auto', 'Auto Purchase List'),
        ('/purchases/po-dha-1001', 'PO-DHA-1001'),
        ('/prescriptions', 'Prescriptions'),
        ('/prescriptions/rx-dha-1', 'rx-dha-1'),
        ('/reports', 'Daily sales'),
        ('/finance', 'Finance'),
        ('/finance/cashbook', 'Cashbook'),
        ('/finance/aging', 'Payables & Receivables'),
        ('/finance/statements', 'P&L & Statements'),
        ('/finance/franchise', 'Franchise Royalties'),
        ('/staff', 'Staff & HR'),
        ('/staff/attendance', 'Attendance'),
        ('/staff/shifts', 'Shifts'),
        ('/staff/salary', 'Monthly total'),
        ('/notifications', 'Notifications'),
        ('/settings', 'Settings'),
        ('/branches', 'Branch Management'),
        ('/branches/branch-dha-main', 'Demo Branch — DHA'),
        ('/audit-log', 'Audit Log'),
        ('/backup', 'Backup & Restore'),
      ];
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
        if (marker != null) {
          expect(
            find.textContaining(marker),
            findsWidgets,
            reason: '$route should render its screen ($marker)',
          );
        }
      }
    });
  });

  group('Phase 8 — D170 overflow fixes still in place (trap)', () {
    testWidgets('supplier detail screen fits at 390px (D170 badge + '
        'Export fixes)', (tester) async {
      final (_, router, trap) = await _pumpSweepApp(tester, 'owner');
      router.go('/suppliers/sup-sami');
      await tester.pumpAndSettle();
      expect(find.textContaining('Sami'), findsWidgets);
      expect(find.text('Payable aging'), findsOneWidget);
      expect(find.text('Export statement (CSV)'), findsOneWidget);
      // The D170 fixes: the StatusBadge label wraps (was 63px) and
      // the Export button is Expanded with a Flexible label (was
      // 0.2px). Both are structural — no test-width change.
      expect(trap.overflowCount, 0);
    });

    testWidgets('supplier detail with a large payable fits at 390px',
        (tester) async {
      // MedServe carries the largest seeded payable (Rs 48,250);
      // its 90+ day badge is the widest aging label.
      final (_, router, trap) = await _pumpSweepApp(tester, 'owner');
      router.go('/suppliers/sup-medserve');
      await tester.pumpAndSettle();
      expect(find.text('MedServe Distributors'), findsWidgets);
      expect(find.text('Payable aging'), findsOneWidget);
      expect(trap.overflowCount, 0);
    });

    testWidgets('/reports branch filter dropdown fits at 390px, open '
        '(D170 isExpanded fix)', (tester) async {
      final (_, router, trap) = await _pumpSweepApp(tester, 'owner');
      router.go('/reports');
      await tester.pumpAndSettle();
      expect(find.text('Daily sales'), findsWidgets);
      // The branch filter dropdown overflowed 21px before the
      // D170 `isExpanded: true` fix — open it to lay out its items
      // at 390px too.
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
      final (_, router, trap) = await _pumpSweepApp(tester, 'owner');
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
      // The method dropdown overflowed 5.9px before the D170
      // `isExpanded: true` fix — open it as well.
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
      final (_, router, trap) = await _pumpSweepApp(tester, 'owner');
      router.go('/branches');
      await tester.pumpAndSettle();
      expect(find.text('Branch Management'), findsWidgets);
      expect(find.text('Demo Branch — DHA'), findsWidgets);
      // The name + two chips row overflowed 4.4px before the D170
      // Wrap fix (chips now flow below the name when they do not
      // fit beside it; the name is never ellipsized).
      expect(trap.overflowCount, 0);
    });

    testWidgets('sales history paged list fits at 390px (D170 '
        'PagedListControls Wrap fix)', (tester) async {
      final (_, router, trap) = await _pumpSweepApp(tester, 'owner');
      router.go('/billing/history');
      await tester.pumpAndSettle();
      expect(find.text('Sales history'), findsWidgets);
      // PagedListControls overflowed 120px as a Row before D170;
      // it is a right-aligned Wrap now — the same control backs
      // every paged list, sales history included.
      expect(trap.overflowCount, 0);
    });
  });

  group('Phase 8 — 390px sweep: Week 7 new / changed screens (D174)', () {
    testWidgets('quarantine outcomes queue (populated) fits at 390px, '
        'filters included', (tester) async {
      final (container, router, trap) = await _pumpSweepApp(
        tester,
        'inventory_manager',
      );
      final batch = (await container
              .read(inventoryRepositoryProvider)
              .getInventory(branchId: _dha))
          .firstWhere((item) => item.medicineId == 'med-panadol-extra');
      final parked = await container
          .read(inventoryProvider.notifier)
          .quarantineBatch(batchId: batch.id, reason: 'Suspected damage');
      expect(parked, isNotNull);
      final request = await container
          .read(quarantineOutcomeQueueProvider.notifier)
          .requestOutcome(
            batch: parked!,
            medicineName: 'Panadol Extra',
            outcome: QuarantineOutcome.dispose,
            reason: 'Damaged beyond use',
          );
      expect(request, isNotNull);
      router.go('/inventory/quarantine-outcomes');
      await tester.pumpAndSettle();
      expect(find.text('Quarantine Outcomes'), findsOneWidget);
      expect(find.textContaining('Panadol Extra'), findsWidgets);
      // The Week 7 queue is the persisted one (D171) — the same
      // screen, now backed by the persisted repo; the filter chips
      // are exercised too.
      await tester.tap(find.text('Approved'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Panadol Extra'), findsNothing);
      await tester.tap(find.text('Pending'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Panadol Extra'), findsWidgets);
      expect(trap.overflowCount, 0);
    });

    testWidgets('quarantine outcomes queue with a decided request fits '
        'at 390px (long decision note)', (tester) async {
      final (container, router, trap) = await _pumpSweepApp(
        tester,
        'inventory_manager',
      );
      final batch = (await container
              .read(inventoryRepositoryProvider)
              .getInventory(branchId: _dha))
          .firstWhere((item) => item.medicineId == 'med-panadol-extra');
      final parked = await container
          .read(inventoryProvider.notifier)
          .quarantineBatch(batchId: batch.id, reason: 'Suspected damage');
      final request = await container
          .read(quarantineOutcomeQueueProvider.notifier)
          .requestOutcome(
            batch: parked!,
            medicineName: 'Panadol Extra',
            outcome: QuarantineOutcome.dispose,
            reason: 'Damaged beyond use',
          );
      // Decide it as a different user (the Owner) with a long note
      // — the decided row renders the decider + note inline. The
      // sweep pump uses a fixed auth notifier, so decide through
      // the layer directly and re-read the queue via the notifier
      // refresh.
      await container
          .read(productionDataLayerProvider)
          .applyQuarantineOutcome(
            batchId: parked.id,
            outcome: QuarantineOutcome.dispose,
            reason: 'Damaged beyond use',
            actorId: 'test-owner',
            actorName: 'Test Owner',
            idempotencyKey: 'quarantine-outcome-${request!.id}',
          );
      await container
          .read(productionDataLayerProvider)
          .updateQuarantineOutcomeRequest(
            request.copyWith(
              status: QuarantineOutcomeStatus.approved,
              decidedById: 'test-owner',
              decidedByName: 'Test Owner',
              decidedAt: DateTime.now(),
              decisionNote:
                  'Destroyed per policy after the supplier refused '
                  'the return — witnessed by the branch manager.',
            ),
          );
      await container
          .read(quarantineOutcomeQueueProvider.notifier)
          .refresh();
      router.go('/inventory/quarantine-outcomes');
      await tester.pumpAndSettle();
      expect(find.text('Quarantine Outcomes'), findsOneWidget);
      expect(find.textContaining('Destroyed per policy'), findsOneWidget);
      expect(find.text('Approved'), findsWidgets);
      expect(trap.overflowCount, 0);
    });

    testWidgets('Return batch dialog on a quarantined batch fits at '
        '390px and files the request', (tester) async {
      final (container, router, trap) = await _pumpSweepApp(
        tester,
        'inventory_manager',
      );
      final batch = (await container
              .read(inventoryRepositoryProvider)
              .getInventory(branchId: _dha))
          .firstWhere((item) => item.medicineId == 'med-panadol-extra');
      final parked = await container
          .read(inventoryProvider.notifier)
          .quarantineBatch(batchId: batch.id, reason: 'Suspected damage');
      expect(parked, isNotNull);
      router.go('/inventory');
      await tester.pumpAndSettle();
      expect(find.text('Inventory'), findsWidgets);
      final returnButton = find.byKey(
        ValueKey('inv-return-${parked!.id}'),
      );
      await tester.ensureVisible(returnButton);
      await tester.pumpAndSettle();
      await tester.tap(returnButton);
      await tester.pumpAndSettle();
      expect(find.text('Return batch to supplier'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('quarantine-outcome-reason-field')),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const ValueKey('quarantine-outcome-reason-field')),
        'Supplier agreed to take the damaged batch back',
      );
      await tester.tap(
        find.byKey(const ValueKey('quarantine-outcome-confirm')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Return batch to supplier'), findsNothing);
      expect(
        find.textContaining('pending approval on the Quarantine '
            'Outcomes screen'),
        findsOneWidget,
      );
      expect(trap.overflowCount, 0);
    });

    testWidgets('Dispose batch dialog shows an empty-reason error '
        'inline at 390px', (tester) async {
      final (container, router, trap) = await _pumpSweepApp(
        tester,
        'inventory_manager',
      );
      final batch = (await container
              .read(inventoryRepositoryProvider)
              .getInventory(branchId: _dha))
          .firstWhere((item) => item.medicineId == 'med-panadol-extra');
      final parked = await container
          .read(inventoryProvider.notifier)
          .quarantineBatch(batchId: batch.id, reason: 'Suspected damage');
      expect(parked, isNotNull);
      router.go('/inventory');
      await tester.pumpAndSettle();
      final disposeButton = find.byKey(
        ValueKey('inv-dispose-${parked!.id}'),
      );
      await tester.ensureVisible(disposeButton);
      await tester.pumpAndSettle();
      await tester.tap(disposeButton);
      await tester.pumpAndSettle();
      expect(find.text('Dispose batch'), findsOneWidget);
      // Submit with no reason: the D154 validation error renders
      // inline and the dialog stays open — nothing is filed.
      await tester.tap(
        find.byKey(const ValueKey('quarantine-outcome-confirm')),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('A reason is required'), findsOneWidget);
      expect(find.text('Dispose batch'), findsOneWidget);
      expect(
        container.read(quarantineOutcomeQueueProvider),
        isEmpty,
      );
      expect(trap.overflowCount, 0);
    });

    testWidgets('backup screen with the D169 restore text fits at '
        '390px (D173 re-key wording)', (tester) async {
      final (_, router, trap) = await _pumpSweepApp(tester, 'owner');
      router.go('/backup');
      await tester.pumpAndSettle();
      expect(find.text('Backup & Restore'), findsWidgets);
      expect(find.text('What restore does NOT do'), findsOneWidget);
      expect(
        find.textContaining('Restore never deletes anything.'),
        findsOneWidget,
      );
      expect(trap.overflowCount, 0);
    });

    testWidgets('restore confirm dialog fits at 390px', (tester) async {
      final json = jsonEncode({
        'format': 'pharmadesk-backup',
        'formatVersion': 1,
        'exportedAt': DateTime.now().toIso8601String(),
        'organizationId': _org,
        'sections': {
          'medicines': [],
        },
      });
      final (_, router, trap) = await _pumpSweepApp(tester, 'owner');
      router.go('/backup');
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byType(TextField).first);
      await tester.enterText(find.byType(TextField).first, json);
      await tester.tap(
        find.byKey(const ValueKey('restore-validate-button')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Restore this backup?'), findsOneWidget);
      expect(
        find.textContaining('Records that are not in the backup are '
            'left untouched'),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Restore this backup?'), findsNothing);
      expect(trap.overflowCount, 0);
    });
  });

  group('Phase 8 — 390px sweep: D160 screens re-run with the '
      'corrected counter (D174)', () {
    testWidgets('branch shelf dialog fits at 390px', (tester) async {
      final (_, router, trap) = await _pumpSweepApp(tester, 'owner');
      router.go('/medicines/med-panadol-extra');
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('medicine-branch-shelf')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('medicine-branch-shelf')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('branch-rack-field')), findsOneWidget);
      expect(trap.overflowCount, 0);
    });

    testWidgets('POS with cash disabled fits at 390px', (tester) async {
      final (container, router, trap) = await _pumpSweepApp(
        tester,
        'cashier',
      );
      container
          .read(orgSettingsProvider.notifier)
          .togglePaymentMethod(OrgPaymentMethod.cash, false);
      router.go('/billing');
      await tester.pumpAndSettle();
      expect(find.text('Billing & POS'), findsOneWidget);
      expect(find.text('Cash'), findsNothing);
      expect(find.text('Card'), findsOneWidget);
      expect(find.text('Credit (khata)'), findsOneWidget);
      expect(trap.overflowCount, 0);
    });

    testWidgets('cashbook with correction + reconciliation fits at 390px',
        (tester) async {
      final (container, router, trap) = await _pumpSweepApp(tester, 'owner');
      await container.read(expensesProvider.notifier).recordExpense(
        branchId: _dha,
        category: 'Supplies',
        amountMinor: 10000,
        description: 'Today supplies',
        expenseDate: _day(0),
      );
      await container
          .read(financialTransactionsProvider.notifier)
          .recordIncome(
            branchId: _dha,
            category: 'Other income',
            amountMinor: 25000,
            date: _day(0),
          );
      final closed = await container
          .read(dailyClosingsProvider.notifier)
          .closeDay(branchId: _dha, date: _day(0));
      expect(closed.error, isNull);
      final original = closed.closing!;
      final corrected = await container
          .read(closingCorrectionsProvider.notifier)
          .correctClosing(
            original: original,
            correctedIncomeMinor: 20000,
            correctedExpenseMinor: 10000,
            reason: 'Income was Rs 200, not Rs 250',
          );
      expect(corrected.error, isNull);
      final reconciled = await container
          .read(cashReconciliationsProvider.notifier)
          .reconcileDay(
            branchId: _dha,
            date: _day(0),
            countedMinor: 15000,
            note: 'Counted exact',
          );
      expect(reconciled.error, isNull);
      router.go('/finance/cashbook');
      await tester.pumpAndSettle();
      expect(find.text('Cashbook'), findsOneWidget);
      expect(find.textContaining('Corrected:'), findsOneWidget);
      expect(find.textContaining('Expected'), findsWidgets);
      final correctKey = ValueKey('correct-closing-${original.id}');
      await tester.ensureVisible(find.byKey(correctKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(correctKey));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('correct-income-field')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('correct-reason-field')),
        findsOneWidget,
      );
      expect(trap.overflowCount, 0);
    });

    testWidgets('franchise view with configured rates fits at 390px',
        (tester) async {
      final (container, router, trap) = await _pumpSweepApp(tester, 'owner');
      final errors = await container
          .read(branchDirectoryProvider.notifier)
          .addBranch(
            const Branch(
              id: 'branch-franchise-1',
              name: 'Franchise — Model Town',
              address: 'Model Town, Lahore',
              phone: '0300-3333333',
              type: 'franchise',
              royaltyRateBps: 500,
              franchiseFeeRateBps: 200,
            ),
          );
      expect(errors, isEmpty);
      await container.read(saleRepositoryProvider).upsertSale(
        _sale(
          id: 'sale-fran-1',
          branchId: 'branch-franchise-1',
          method: SalePaymentMethod.cash,
          amountMinor: 1000000,
          createdAt: _day(0).add(const Duration(hours: 10)),
        ),
      );
      router.go('/finance/franchise');
      await tester.pumpAndSettle();
      expect(find.text('Franchise Royalties'), findsOneWidget);
      expect(find.text('Franchise — Model Town'), findsOneWidget);
      expect(find.text('Rs 500.00'), findsWidgets);
      expect(find.text('Rs 700.00'), findsWidgets);
      expect(trap.overflowCount, 0);
    });

    testWidgets('aging screen fits at 390px', (tester) async {
      final (_, router, trap) = await _pumpSweepApp(tester, 'owner');
      router.go('/finance/aging');
      await tester.pumpAndSettle();
      expect(find.text('Payables & Receivables'), findsOneWidget);
      expect(find.text('Supplier payables'), findsOneWidget);
      expect(trap.overflowCount, 0);
    });

    testWidgets('statements screen fits at 390px', (tester) async {
      final (_, router, trap) = await _pumpSweepApp(tester, 'owner');
      router.go('/finance/statements');
      await tester.pumpAndSettle();
      expect(find.text('P&L & Statements'), findsOneWidget);
      expect(trap.overflowCount, 0);
    });
  });

  group('Phase 8 — finance agreement, third pass over the guarded '
      'writes + idempotent payments (D161/D162/D173)', () {
    Future<ProfitLoss> plFromRepos(
      ProductionDataLayer layer, {
      int days = 30,
    }) async {
      return computeProfitAndLoss(
        orders: await layer.orderRepo.getOrders(),
        sales: await layer.saleRepo.getSales(),
        returns: const [],
        inventory: const [],
        expenses: await layer.expenseRepo.getExpenses(branchId: _dha),
        transactions: await layer.financialTransactionRepo.getTransactions(
          branchId: _dha,
        ),
        branchId: _dha,
        now: DateTime.now(),
        days: days,
      );
    }

    Future<({int incomeMinor, int expenseMinor})> cashbookSums(
      ProductionDataLayer layer,
    ) async {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final start = today.subtract(const Duration(days: 29));
      final entries = cashbookEntries(
        expenses: await layer.expenseRepo.getExpenses(branchId: _dha),
        transactions: await layer.financialTransactionRepo.getTransactions(
          branchId: _dha,
        ),
        branchId: _dha,
      );
      var income = 0;
      var expense = 0;
      for (final entry in entries) {
        final day = DateTime(
          entry.date.year,
          entry.date.month,
          entry.date.day,
        );
        if (day.isBefore(start) || day.isAfter(today)) continue;
        if (entry.kind == CashbookEntryKind.income) {
          income += entry.amountMinor;
        } else {
          expense += entry.amountMinor;
        }
      }
      return (incomeMinor: income, expenseMinor: expense);
    }

    Future<int> mirrorExpenseTxns(
      ProductionDataLayer layer,
      int amountMinor,
    ) async {
      final txns = await layer.financialTransactionRepo.getTransactions(
        branchId: _dha,
      );
      return txns
          .where(
            (txn) =>
                txn.type == FinancialTransactionType.expense &&
                txn.amountMinor == -amountMinor,
          )
          .length;
    }

    Future<int> todaySalesTotal(ProductionDataLayer layer) async {
      final counters = computeDailyCounters(
        orders: await layer.orderRepo.getOrders(),
        sales: await layer.saleRepo.getSales(),
        returns: const [],
        inventory: await layer.inventoryRepo.getInventory(),
        branchId: _dha,
        now: DateTime.now(),
      );
      return counters
          .lastWhere(
            (counter) =>
                counter.date.year == DateTime.now().year &&
                counter.date.month == DateTime.now().month &&
                counter.date.day == DateTime.now().day,
          )
          .salesTotalMinor;
    }

    test('guarded expense + income move the cashbook and the P&L by '
        'exactly their amounts; an idempotent replay moves nothing',
        () async {
      final h = _Harness();
      final sumsBefore = await cashbookSums(h.layer);
      await h.layer.recordExpense(
        branchId: _dha,
        category: 'Utilities',
        amountMinor: 750000,
        description: 'Electricity bill (agreement 3)',
        expenseDate: _day(0),
        createdBy: 'test-owner',
        idempotencyKey: 'agreement3-expense-1',
      );
      await h.layer.recordIncome(
        branchId: _dha,
        category: 'Other income',
        amountMinor: 125000,
        date: _day(0),
        createdBy: 'test-owner',
        idempotencyKey: 'agreement3-income-1',
      );
      final sums = await cashbookSums(h.layer);
      expect(sums.incomeMinor - sumsBefore.incomeMinor, 125000);
      expect(sums.expenseMinor - sumsBefore.expenseMinor, 750000);
      final pl = await plFromRepos(h.layer);
      expect(pl.otherIncomeMinor, sums.incomeMinor);
      expect(pl.expensesMinor, sums.expenseMinor);
      expect(
        pl.netProfitMinor,
        pl.grossProfitMinor + pl.otherIncomeMinor - pl.expensesMinor,
      );
      expect(await mirrorExpenseTxns(h.layer, 750000), 1);
      await h.layer.recordExpense(
        branchId: _dha,
        category: 'Utilities',
        amountMinor: 750000,
        description: 'Electricity bill (agreement 3)',
        expenseDate: _day(0),
        createdBy: 'test-owner',
        idempotencyKey: 'agreement3-expense-1',
      );
      await h.layer.recordIncome(
        branchId: _dha,
        category: 'Other income',
        amountMinor: 125000,
        date: _day(0),
        createdBy: 'test-owner',
        idempotencyKey: 'agreement3-income-1',
      );
      final sumsAfterReplay = await cashbookSums(h.layer);
      expect(sumsAfterReplay.incomeMinor, sums.incomeMinor);
      expect(sumsAfterReplay.expenseMinor, sums.expenseMinor);
      final plAfterReplay = await plFromRepos(h.layer);
      expect(plAfterReplay.otherIncomeMinor, pl.otherIncomeMinor);
      expect(plAfterReplay.expensesMinor, pl.expensesMinor);
      expect(plAfterReplay.netProfitMinor, pl.netProfitMinor);
      expect(await mirrorExpenseTxns(h.layer, 750000), 1);
      expect(
        (await h.layer.expenseRepo.getExpenses(branchId: _dha))
            .where((e) => e.description == 'Electricity bill (agreement 3)')
            .length,
        1,
      );
    });

    test('guarded supplier payment moves the aging by exactly the '
        'payment; an idempotent replay moves nothing and the P&L '
        'never moves', () async {
      final h = _Harness();
      final ledgerBefore = await h.layer.supplierRepo.getLedgerEntries(
        'sup-medserve',
      );
      final agingBefore = computeAging(
        entries: supplierLedgerSignedEntries(ledgerBefore),
        now: DateTime.now(),
      );
      expect(agingBefore.totalMinor, 4825000);
      final plBefore = await plFromRepos(h.layer);
      final first = await h.layer.recordSupplierPayment(
        supplierId: 'sup-medserve',
        branchId: _dha,
        amountMinor: 1500000,
        allocations: await _medServeAllocations(h, 1500000),
        idempotencyKey: 'agreement3-supplier-payment-1',
      );
      expect(first.isDuplicate, isFalse);
      final ledgerAfter = await h.layer.supplierRepo.getLedgerEntries(
        'sup-medserve',
      );
      final agingAfter = computeAging(
        entries: supplierLedgerSignedEntries(ledgerAfter),
        now: DateTime.now(),
      );
      expect(agingAfter.totalMinor, 3325000);
      expect(supplierOutstandingMinor(ledgerAfter), 3325000);
      expect(ledgerAfter.last.balanceAfterMinor, 3325000);
      expect(ledgerAfter.last.amountMinor, -1500000);
      final plAfter = await plFromRepos(h.layer);
      expect(plAfter.revenueMinor, plBefore.revenueMinor);
      expect(plAfter.otherIncomeMinor, plBefore.otherIncomeMinor);
      expect(plAfter.expensesMinor, plBefore.expensesMinor);
      expect(plAfter.netProfitMinor, plBefore.netProfitMinor);
      final replay = await h.layer.recordSupplierPayment(
        supplierId: 'sup-medserve',
        branchId: _dha,
        amountMinor: 1500000,
        allocations: await _medServeAllocations(h, 1500000),
        idempotencyKey: 'agreement3-supplier-payment-1',
      );
      expect(replay.isDuplicate, isTrue);
      expect(replay.payment.id, first.payment.id);
      final ledgerReplay = await h.layer.supplierRepo.getLedgerEntries(
        'sup-medserve',
      );
      expect(ledgerReplay.length, ledgerAfter.length);
      expect(
        computeAging(
          entries: supplierLedgerSignedEntries(ledgerReplay),
          now: DateTime.now(),
        ).totalMinor,
        3325000,
      );
      final plReplay = await plFromRepos(h.layer);
      expect(plReplay.netProfitMinor, plAfter.netProfitMinor);
    });

    test('a guarded closing correction moves neither the cashbook '
        'nor the P&L; its replay records nothing twice', () async {
      final h = _Harness();
      await h.layer.recordExpense(
        branchId: _dha,
        category: 'Supplies',
        amountMinor: 10000,
        description: 'Today supplies (agreement 3)',
        expenseDate: _day(0),
        createdBy: 'test-owner',
        idempotencyKey: 'agreement3-expense-2',
      );
      await h.layer.recordIncome(
        branchId: _dha,
        category: 'Other income',
        amountMinor: 25000,
        date: _day(0),
        createdBy: 'test-owner',
        idempotencyKey: 'agreement3-income-2',
      );
      final sumsBefore = await cashbookSums(h.layer);
      final plBefore = await plFromRepos(h.layer);
      final first = await h.layer.recordClosingCorrection(
        correction: _correction(),
        actorId: 'test-owner',
        actorName: 'Test Owner',
        idempotencyKey: 'agreement3-correction-1',
      );
      expect(first.id, isNotEmpty);
      final sumsAfter = await cashbookSums(h.layer);
      final plAfter = await plFromRepos(h.layer);
      expect(sumsAfter.incomeMinor, sumsBefore.incomeMinor);
      expect(sumsAfter.expenseMinor, sumsBefore.expenseMinor);
      expect(plAfter.otherIncomeMinor, plBefore.otherIncomeMinor);
      expect(plAfter.expensesMinor, plBefore.expensesMinor);
      expect(plAfter.netProfitMinor, plBefore.netProfitMinor);
      final replay = await h.layer.recordClosingCorrection(
        correction: _correction(),
        idempotencyKey: 'agreement3-correction-1',
      );
      expect(replay.id, first.id);
      expect(
        (await h.layer.closingCorrectionRepo.getCorrections(
          branchId: _dha,
        )).length,
        1,
      );
      final sumsReplay = await cashbookSums(h.layer);
      expect(sumsReplay.incomeMinor, sumsBefore.incomeMinor);
    });

    test('a guarded reconciliation moves neither the cashbook nor '
        'the P&L; its replay records nothing twice', () async {
      final h = _Harness();
      final sumsBefore = await cashbookSums(h.layer);
      final plBefore = await plFromRepos(h.layer);
      final first = await h.layer.recordCashReconciliation(
        reconciliation: _reconciliation(),
        actorId: 'test-owner',
        actorName: 'Test Owner',
        idempotencyKey: 'agreement3-recon-1',
      );
      expect(first.id, isNotEmpty);
      final sumsAfter = await cashbookSums(h.layer);
      final plAfter = await plFromRepos(h.layer);
      expect(sumsAfter.incomeMinor, sumsBefore.incomeMinor);
      expect(sumsAfter.expenseMinor, sumsBefore.expenseMinor);
      expect(plAfter.netProfitMinor, plBefore.netProfitMinor);
      final replay = await h.layer.recordCashReconciliation(
        reconciliation: _reconciliation(),
        idempotencyKey: 'agreement3-recon-1',
      );
      expect(replay.id, first.id);
      expect(
        (await h.layer.cashReconciliationRepo.getReconciliations(
          branchId: _dha,
        )).length,
        1,
      );
    });

    test('a refused write on a deactivated branch leaves the '
        'cashbook, the P&L and the aging exactly unchanged',
        () async {
      final h = _Harness();
      final sumsBefore = await cashbookSums(h.layer);
      final plBefore = await plFromRepos(h.layer);
      final ledgerBefore = await h.layer.supplierRepo.getLedgerEntries(
        'sup-medserve',
      );
      await _deactivate(h, _dha);
      await expectLater(
        h.layer.recordExpense(
          branchId: _dha,
          category: 'Supplies',
          amountMinor: 50000,
          expenseDate: _day(0),
          idempotencyKey: 'agreement3-refused-1',
        ),
        throwsArgumentError,
      );
      await expectLater(
        h.layer.recordIncome(
          branchId: _dha,
          category: 'Other income',
          amountMinor: 50000,
          date: _day(0),
          idempotencyKey: 'agreement3-refused-2',
        ),
        throwsArgumentError,
      );
      await expectLater(
        h.layer.recordSupplierPayment(
          supplierId: 'sup-medserve',
          branchId: _dha,
          amountMinor: 100000,
          allocations: await _medServeAllocations(h, 100000),
          idempotencyKey: 'agreement3-refused-3',
        ),
        throwsArgumentError,
      );
      final sumsAfter = await cashbookSums(h.layer);
      final plAfter = await plFromRepos(h.layer);
      final ledgerAfter = await h.layer.supplierRepo.getLedgerEntries(
        'sup-medserve',
      );
      expect(sumsAfter.incomeMinor, sumsBefore.incomeMinor);
      expect(sumsAfter.expenseMinor, sumsBefore.expenseMinor);
      expect(plAfter.netProfitMinor, plBefore.netProfitMinor);
      expect(ledgerAfter.length, ledgerBefore.length);
      expect(
        supplierOutstandingMinor(ledgerAfter),
        supplierOutstandingMinor(ledgerBefore),
      );
    });

    test('a guarded daily closing agrees with the day’s cashbook '
        'entries', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(expensesProvider.notifier).recordExpense(
        branchId: _dha,
        category: 'Supplies',
        amountMinor: 10000,
        description: 'Today supplies (closing 3)',
        expenseDate: _day(0),
      );
      await container
          .read(financialTransactionsProvider.notifier)
          .recordIncome(
            branchId: _dha,
            category: 'Other income',
            amountMinor: 25000,
            date: _day(0),
          );
      final closed = await container
          .read(dailyClosingsProvider.notifier)
          .closeDay(branchId: _dha, date: _day(0));
      expect(closed.error, isNull);
      final closing = closed.closing!;
      final entries = cashbookEntries(
        expenses: await container
            .read(expenseRepositoryProvider)
            .getExpenses(branchId: _dha),
        transactions: await container
            .read(financialTransactionRepositoryProvider)
            .getTransactions(branchId: _dha),
        branchId: _dha,
      );
      final totals = computeDailyClosing(
        entries: entries,
        date: _day(0),
        openingBalanceMinor: closing.openingBalanceMinor,
      );
      expect(closing.totalIncomeMinor, totals.incomeMinor);
      expect(closing.totalExpenseMinor, totals.expenseMinor);
      expect(closing.closingBalanceMinor, totals.closingBalanceMinor);
      expect(closing.totalIncomeMinor, 25000);
      expect(closing.totalExpenseMinor, 10000);
      expect(dailyClosingIsStale(closing: closing, entries: entries),
          isFalse);
    });

    test('re-keyed restore agreement (D173): a restored sale moves '
        'the P&L revenue and the derived counter by exactly its '
        'amount, once — a re-restore moves nothing further',
        () async {
      final source = _Harness();
      final saved = await source.layer.saleRepo.createSale(
        Sale(
          id: '',
          invoiceNumber: '',
          branchId: _dha,
          cashierName: 'Test Cashier',
          items: const [],
          subtotalMinor: 1000000,
          totalMinor: 1000000,
          paymentMethod: SalePaymentMethod.cash,
          payments: const [
            SalePayment(
              method: SalePaymentMethod.cash,
              amountMinor: 1000000,
            ),
          ],
          cashReceivedMinor: 1000000,
          idempotencyKey: 'sale-d174-restore-1',
          createdAt: _day(0).add(const Duration(hours: 10)),
        ),
      );
      expect(saved.id, isNot('sale-d174-restore-1'));
      final backup = await source.layer.exportBackup();
      final fresh = _Harness();
      final plBefore = await plFromRepos(fresh.layer);
      final counterBefore = await todaySalesTotal(fresh.layer);
      final first = await fresh.layer.importBackup(
        backup,
        policy: ImportPolicy.overwrite,
      );
      expect(first.errors, isEmpty);
      expect(first.created, greaterThan(0));
      // D173: the sale lands under its key, not the mock id.
      expect(
        await fresh.layer.saleRepo.getById('sale-d174-restore-1'),
        isNotNull,
      );
      expect(await fresh.layer.saleRepo.getById(saved.id), isNull);
      final plAfter = await plFromRepos(fresh.layer);
      expect(plAfter.revenueMinor - plBefore.revenueMinor, 1000000);
      expect(
        plAfter.netProfitMinor - plBefore.netProfitMinor,
        1000000,
      );
      expect(
        await todaySalesTotal(fresh.layer) - counterBefore,
        1000000,
      );
      // A re-restore under overwrite counts the sale once more as
      // overwritten — and moves no figure a second time.
      final second = await fresh.layer.importBackup(
        backup,
        policy: ImportPolicy.overwrite,
      );
      expect(second.errors, isEmpty);
      expect(second.created, 0);
      expect(second.overwritten, greaterThan(0));
      expect((await fresh.layer.saleRepo.getSales()).length, 1);
      final plReplay = await plFromRepos(fresh.layer);
      expect(plReplay.revenueMinor, plAfter.revenueMinor);
      expect(plReplay.netProfitMinor, plAfter.netProfitMinor);
      expect(await todaySalesTotal(fresh.layer), counterBefore + 1000000);
    });
  });

  group('Phase 8 — offline queue: Week 7 flows (D171/D172/D173)', () {
    test('quarantine filing enqueues exactly one payload, flushes '
        'once, and a re-file dedupes', () async {
      final h = _Harness();
      final request = QuarantineOutcomeRequest(
        id: 'qo-1',
        batchId: 'batch-1',
        batchNo: 'B-1001',
        medicineId: 'med-panadol-extra',
        medicineName: 'Panadol Extra',
        branchId: _dha,
        outcome: QuarantineOutcome.dispose,
        reason: 'Damaged beyond use',
        quantityAtRequest: 12,
        requesterId: 'test-inventory_manager',
        requesterName: 'Test inventory_manager',
        requestedAt: DateTime(2026, 11, 26, 10, 0),
      );
      final filed = await h.layer.fileQuarantineOutcomeRequest(request);
      expect(filed.id, 'qo-1');
      expect(await h.layer.syncQueue.pendingCount(), 1);
      expect(h.layer.lastSyncAt, isNull);
      final flushed = await h.layer.syncQueue.processAll((_) async => true);
      expect(flushed, 1);
      expect(await h.layer.syncQueue.pendingCount(), 0);
      expect(h.layer.lastSyncAt, isNotNull);
      // Same-id re-file: the stored request comes back, no second
      // doc and no second payload (D171 — the registry + the
      // store check dedupe together).
      final again = await h.layer.fileQuarantineOutcomeRequest(request);
      expect(again.id, 'qo-1');
      expect(await h.layer.syncQueue.pendingCount(), 0);
      expect(
        await h.layer.loadQuarantineOutcomeRequests(branchId: _dha),
        hasLength(1),
      );
      expect(await h.layer.syncQueue.processAll((_) async => true), 0);
    });

    test('quarantine approve enqueues apply + decision on top of the '
        'quarantine + file payloads (four total), flushes once, and '
        'a double-approve adds nothing', () async {
      final h = _Harness();
      final auth = _MutableAuthNotifier(_userFor('inventory_manager'));
      final container = await _quarantineContainer(h, h.layer, auth: auth);
      final (request, batch) = await _fileDisposeRequest(container);
      // Quarantining the batch enqueued one batch-status payload
      // (D140) before the filing enqueued its one (D171).
      expect(await h.layer.syncQueue.pendingCount(), 2);
      // Approve as a different user (the Owner — not the requester,
      // §5.2.4 separation of duties).
      auth.user = _userFor('owner');
      final approved = await container
          .read(quarantineOutcomeQueueProvider.notifier)
          .approveOutcome(requestId: request.id);
      expect(approved, isNotNull);
      expect(approved!.status, QuarantineOutcomeStatus.approved);
      // D171 counting on top of the two already queued: apply (1)
      // + decision (1) = 4 total.
      expect(await h.layer.syncQueue.pendingCount(), 4);
      final flushed = await h.layer.syncQueue.processAll((_) async => true);
      expect(flushed, 4);
      expect(await h.layer.syncQueue.pendingCount(), 0);
      // A second approve is a no-op: the request is no longer
      // pending, so nothing is applied, persisted or enqueued.
      final second = await container
          .read(quarantineOutcomeQueueProvider.notifier)
          .approveOutcome(requestId: request.id);
      expect(second, isNull);
      expect(await h.layer.syncQueue.pendingCount(), 0);
      expect(
        (await h.audit.entries(action: 'batch.disposed')).length,
        1,
      );
      final after = (await h.layer.inventoryRepo.getInventory(
        branchId: _dha,
      )).firstWhere((item) => item.id == batch.id);
      expect(after.isDisposed, isTrue);
    });

    test('quarantine reject enqueues the decision on top of the '
        'quarantine + file payloads (three total), flushes once, '
        'and the batch stays quarantined', () async {
      final h = _Harness();
      final auth = _MutableAuthNotifier(_userFor('inventory_manager'));
      final container = await _quarantineContainer(h, h.layer, auth: auth);
      final (request, batch) = await _fileDisposeRequest(container);
      // Quarantine (1) + file (1) already queued.
      expect(await h.layer.syncQueue.pendingCount(), 2);
      auth.user = _userFor('owner');
      final rejected = await container
          .read(quarantineOutcomeQueueProvider.notifier)
          .rejectOutcome(requestId: request.id, note: 'Batch looks safe');
      expect(rejected, isNotNull);
      expect(rejected!.status, QuarantineOutcomeStatus.rejected);
      // + decision (1) = 3 total.
      expect(await h.layer.syncQueue.pendingCount(), 3);
      final flushed = await h.layer.syncQueue.processAll((_) async => true);
      expect(flushed, 3);
      expect(await h.layer.syncQueue.pendingCount(), 0);
      final after = (await h.layer.inventoryRepo.getInventory(
        branchId: _dha,
      )).firstWhere((item) => item.id == batch.id);
      expect(after.isQuarantined, isTrue);
      expect(after.isDisposed, isFalse);
      expect(
        (await h.audit.entries(action: 'batch.disposed')).length,
        0,
      );
    });

    test('a refused approve on a deactivated branch enqueues nothing '
        'new; reactivation lets the same approval through exactly '
        'once', () async {
      final h = _Harness();
      final auth = _MutableAuthNotifier(_userFor('inventory_manager'));
      final container = await _quarantineContainer(h, h.layer, auth: auth);
      final (request, batch) = await _fileDisposeRequest(container);
      // Quarantine (1) + file (1) already queued.
      expect(await h.layer.syncQueue.pendingCount(), 2);
      await _deactivate(h, _dha);
      auth.user = _userFor('owner');
      final refused = await container
          .read(quarantineOutcomeQueueProvider.notifier)
          .approveOutcome(requestId: request.id);
      expect(refused, isNull);
      // The guard sits before the apply AND before the decision
      // persist: no new payload, the request stays pending, the
      // batch stays quarantined.
      expect(await h.layer.syncQueue.pendingCount(), 2);
      expect(
        (await _readQueue(container)).first.status,
        QuarantineOutcomeStatus.pending,
      );
      final still = (await h.layer.inventoryRepo.getInventory(
        branchId: _dha,
      )).firstWhere((item) => item.id == batch.id);
      expect(still.isQuarantined, isTrue);
      await _reactivate(h, _dha);
      final approved = await container
          .read(quarantineOutcomeQueueProvider.notifier)
          .approveOutcome(requestId: request.id);
      expect(approved, isNotNull);
      expect(approved!.status, QuarantineOutcomeStatus.approved);
      // Apply (1) + decision (1) on top of the two queued = 4.
      expect(await h.layer.syncQueue.pendingCount(), 4);
      expect(
        (await h.audit.entries(action: 'batch.disposed')).length,
        1,
      );
    });

    test('a restore enqueues no sync payload (it writes direct to '
        'the repos, D169/D173)', () async {
      final source = _Harness();
      final backup = await source.layer.exportBackup();
      final fresh = _Harness();
      expect(await fresh.layer.syncQueue.pendingCount(), 0);
      final report = await fresh.layer.importBackup(
        backup,
        policy: ImportPolicy.overwrite,
      );
      expect(report.errors, isEmpty);
      // The fresh layer already holds the seeded docs, so the
      // restore overwrites rather than creates — the point is that
      // it writes direct to the repos and enqueues nothing.
      expect(report.created + report.overwritten, greaterThan(0));
      expect(await fresh.layer.syncQueue.pendingCount(), 0);
      expect(fresh.layer.lastSyncAt, isNull);
    });

    test('order create + restore replay through the fake transport '
        '(D172 transaction / batch paths as exercised by the repos)',
        () async {
      final target = await _FirestoreHarness.create();
      // `createOrder` runs the counter through `runTransaction`
      // and the doc + items through `runBatchedWrites`: the stored
      // doc, the items subcollection and the read-back agree.
      final created = await target.layer.orderRepo.createOrder(
        sampleOrder(),
      );
      expect(created.orderNumber, 'ORD-DHA-1001');
      expect(created.idempotencyKey, created.id);
      final stored = await target.transport.getDocument(
        FirestoreSchema.orderDocPath(_dha, created.id),
      );
      expect(stored, isNotNull);
      expect(stored!['orderNumber'], 'ORD-DHA-1001');
      final items = await target.transport.queryCollection(
        FirestoreSchema.nestedCollection(
          _dha,
          FirestoreSchema.orders,
          created.id,
          FirestoreSchema.orderItems,
        ),
      );
      expect(items, hasLength(1));
      expect(items.first.data['medicineId'], 'med-1');
      final readBack = await target.layer.orderRepo.getById(created.id);
      expect(readBack, isNotNull);
      expect(readBack!.orderNumber, 'ORD-DHA-1001');
      expect(readBack.idempotencyKey, created.id);
      // A restore replay of the same order via `upsertOrder`
      // (the batch path) returns the same number/key, consumes no
      // counter value, and writes nothing twice.
      final replayed = await target.layer.orderRepo.upsertOrder(created);
      expect(replayed.orderNumber, 'ORD-DHA-1001');
      expect(replayed.idempotencyKey, created.id);
      final next = await target.layer.orderRepo.createOrder(sampleOrder());
      expect(next.orderNumber, 'ORD-DHA-1002');
      expect(
        await target.transport.queryCollection(
          FirestoreSchema.nestedCollection(
          _dha,
          FirestoreSchema.orders,
          created.id,
          FirestoreSchema.orderItems,
        ),
        ),
        hasLength(1),
      );
    });

    test('Firestore upsertOrder preserves a carried order number '
        'on a new doc and advances the counter past it (D174/D175); '
        'an empty number still mints', () async {
      final target = await _FirestoreHarness.create();
      // A restore replay carries the backup's number: it is kept
      // as given — and (Week 7 Day 5, D175, deliberate change from
      // the Day 36 pin) the counter advances past the carried
      // sequence, so the next genuine create gets 1493, not 1001:
      // without the advance the counter would eventually mint
      // 1492 for a different order.
      final kept = await target.layer.orderRepo.upsertOrder(
        sampleOrder(
          id: 'ord-dha-1492',
        ).copyWith(orderNumber: 'ORD-DHA-1492'),
      );
      expect(kept.orderNumber, 'ORD-DHA-1492');
      expect(kept.id, 'ord-dha-1492');
      expect(kept.idempotencyKey, 'ord-dha-1492');
      final next = await target.layer.orderRepo.createOrder(sampleOrder());
      expect(next.orderNumber, 'ORD-DHA-1493');
      // A genuinely new order with no number still mints from the
      // counter (the Day 34 behaviour, unchanged) — now past the
      // advanced counter.
      final minted = await target.layer.orderRepo.upsertOrder(
        sampleOrder(id: 'ord-dha-2001'),
      );
      expect(minted.orderNumber, 'ORD-DHA-1494');
    });

    test('order-only backup restored into the Firestore layer lands '
        'via the batch path and re-imports count once (D172/D173)',
        () async {
      final source = _Harness();
      final order = await source.layer.orderRepo.createOrder(sampleOrder());
      // The mock repo's counter starts past its seeded orders, so
      // the number is whatever the repo assigned — the restore must
      // preserve exactly that number.
      expect(order.orderNumber, isNotEmpty);
      final backup = await source.layer.exportBackup();
      // The export carries every seeded order too — the order-only
      // backup is just the created order's doc.
      final orders = ((backup['sections'] as Map)['orders'] as List)
          .where((doc) => (doc as Map)['id'] == order.id)
          .toList();
      expect(orders, hasLength(1));
      final target = await _FirestoreHarness.create();
      final first = await target.layer.importBackup(
        {
          'format': BackupFormat.format,
          'formatVersion': BackupFormat.currentVersion,
          'organizationId': _org,
          'exportedAt': DateTime.now().toIso8601String(),
          'sections': {
            'orders': orders,
          },
        },
        policy: ImportPolicy.overwrite,
      );
      expect(first.errors, isEmpty);
      expect(first.created, 1);
      final restored = await target.layer.orderRepo.getById(order.id);
      expect(restored, isNotNull);
      expect(restored!.orderNumber, order.orderNumber);
      expect(restored.idempotencyKey, order.id);
      expect(
        await target.transport.queryCollection(
          FirestoreSchema.nestedCollection(
          _dha,
          FirestoreSchema.orders,
          order.id,
          FirestoreSchema.orderItems,
        ),
        ),
        hasLength(1),
      );
      final second = await target.layer.importBackup(
        {
          'format': BackupFormat.format,
          'formatVersion': BackupFormat.currentVersion,
          'organizationId': _org,
          'exportedAt': DateTime.now().toIso8601String(),
          'sections': {
            'orders': orders,
          },
        },
        policy: ImportPolicy.overwrite,
      );
      expect(second.errors, isEmpty);
      expect(second.created, 0);
      expect(second.overwritten, 1);
      expect(
        (await target.layer.orderRepo.getOrders()).length,
        1,
      );
    });
  });

  group('Phase 8 — role gates: Week 7 flows (D171/D144 pattern)', () {
    for (final roleKey in srsRoleKeys) {
      testWidgets('quarantine outcomes route gate: role $roleKey sees '
          'exactly its matrix outcome', (tester) async {
        final user = _userFor(roleKey);
        final (_, router) = await pumpRouterAppAsRole(
          tester,
          roleKey,
          size: const Size(1280, 800),
        );
        // The expected outcome comes from the matrix itself via
        // the permission service — the test pins that the ROUTE
        // GATE follows it, not a second copy of the matrix.
        // `stockAdjustReq` is allowed/own only for Owner, HO
        // Admin, Branch Mgr and Inventory Mgr; the other six
        // roles are `none`, so the FeatureGate shows its
        // no-permission screen under the Inventory module title
        // and the queue never renders.
        final allowed = routeCapability('/inventory/quarantine-outcomes') ==
                null ||
            permissionService.canInBranch(user, 'stockAdjustReq', _dha);
        router.go('/inventory/quarantine-outcomes');
        await tester.pumpAndSettle();
        if (allowed) {
          expect(find.text('Quarantine Outcomes'), findsWidgets);
        } else {
          expect(
            find.text('No permission for Inventory'),
            findsOneWidget,
            reason: '$roleKey is route-gated out of '
                '/inventory/quarantine-outcomes',
          );
          expect(find.text('Quarantine Outcomes'), findsNothing);
        }
      });
    }

    test('approve refused for the requester themself (§5.2.4 '
        'separation of duties)', () async {
      final h = _Harness();
      final auth = _MutableAuthNotifier(_userFor('inventory_manager'));
      final container = await _quarantineContainer(h, h.layer, auth: auth);
      final (request, batch) = await _fileDisposeRequest(container);
      // Quarantine (1) + file (1) already queued.
      expect(await h.layer.syncQueue.pendingCount(), 2);
      // The requester tries to approve their own request: the
      // notifier refuses — no apply, no decision persist, no new
      // payload, the request stays pending.
      final refused = await container
          .read(quarantineOutcomeQueueProvider.notifier)
          .approveOutcome(requestId: request.id);
      expect(refused, isNull);
      expect(await h.layer.syncQueue.pendingCount(), 2);
      expect(
        (await _readQueue(container)).first.status,
        QuarantineOutcomeStatus.pending,
      );
      final still = (await h.layer.inventoryRepo.getInventory(
        branchId: _dha,
      )).firstWhere((item) => item.id == batch.id);
      expect(still.isQuarantined, isTrue);
    });

    test('approve refused for a role without stockAdjustApprove; '
        'the Owner approves', () async {
      final h = _Harness();
      final auth = _MutableAuthNotifier(_userFor('inventory_manager'));
      final container = await _quarantineContainer(h, h.layer, auth: auth);
      final (request, batch) = await _fileDisposeRequest(container);
      // Quarantine (1) + file (1) already queued.
      expect(await h.layer.syncQueue.pendingCount(), 2);
      // A Cashier holds no `stockAdjustApprove` — the notifier
      // refuses before any layer call.
      auth.user = _userFor('cashier');
      final refused = await container
          .read(quarantineOutcomeQueueProvider.notifier)
          .approveOutcome(requestId: request.id);
      expect(refused, isNull);
      expect(await h.layer.syncQueue.pendingCount(), 2);
      expect(
        (await _readQueue(container)).first.status,
        QuarantineOutcomeStatus.pending,
      );
      // The Owner (a different user from the requester) approves.
      auth.user = _userFor('owner');
      final approved = await container
          .read(quarantineOutcomeQueueProvider.notifier)
          .approveOutcome(requestId: request.id);
      expect(approved, isNotNull);
      expect(approved!.status, QuarantineOutcomeStatus.approved);
      final after = (await h.layer.inventoryRepo.getInventory(
        branchId: _dha,
      )).firstWhere((item) => item.id == batch.id);
      expect(after.isDisposed, isTrue);
    });

    testWidgets('backup restore gate still holds: Owner passes, '
        'Pharmacist is gated (D144 spot-check)', (tester) async {
      final (_, ownerRouter) = await pumpRouterAppAsRole(
        tester,
        'owner',
        size: const Size(1280, 800),
      );
      ownerRouter.go('/backup');
      await tester.pumpAndSettle();
      expect(find.text('Backup & Restore'), findsWidgets);
      expect(
        find.byKey(const ValueKey('restore-validate-button')),
        findsOneWidget,
      );
    });

    testWidgets('backup restore gate still holds: Pharmacist sees '
        'the no-permission screen', (tester) async {
      final (_, router) = await pumpRouterAppAsRole(
        tester,
        'pharmacist',
        size: const Size(1280, 800),
      );
      router.go('/backup');
      await tester.pumpAndSettle();
      expect(
        find.text('No permission for Backup & Restore'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('restore-validate-button')),
        findsNothing,
      );
    });
  });
}
