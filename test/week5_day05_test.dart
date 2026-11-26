// Week 5 Day 5 tests — franchise commission/royalty (FR-HO-07) +
// Phase 8 QA depth (D158–D160).
//
// - D158: royalty / franchise-fee computation — rate × branch sales,
//   int paisa, never floats; null rate = "Not set", never 0%;
//   per-branch isolation; sales base agrees with the P&L revenue.
// - D159: franchise view gating (head-office only, existing
//   `branches` capability at write level — no new capability).
// - Phase 8: full route walk incl. all Week 5 routes; 390px sweep
//   over the new/changed screens; offline-queue + role-gate
//   coverage for the new flows; finance hub second QA pass
//   (cashbook vs P&L agreement, aging buckets vs supplier ledger).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:pharmadesk/core/data/audit_log.dart';
import 'package:pharmadesk/core/data/auth_repository.dart';
import 'package:pharmadesk/core/data/firestore_schema.dart';
import 'package:pharmadesk/core/data/inventory_engine.dart';
import 'package:pharmadesk/core/data/permission_service.dart';
import 'package:pharmadesk/core/data/production_data_layer.dart';
import 'package:pharmadesk/core/data/sync_queue.dart';
import 'package:pharmadesk/core/routing/app_router.dart';
import 'package:pharmadesk/core/services/demo_seed_data.dart';
import 'package:pharmadesk/core/services/repositories.dart';
import 'package:pharmadesk/core/theme/app_theme.dart';
import 'package:pharmadesk/core/theme/white_label.dart';
import 'package:pharmadesk/features/authentication/auth_state.dart';
import 'package:pharmadesk/features/branches/branch_directory.dart';
import 'package:pharmadesk/features/finance/finance_logic.dart';
import 'package:pharmadesk/features/finance/finance_provider.dart';
import 'package:pharmadesk/features/finance/franchise_logic.dart';
import 'package:pharmadesk/features/finance/franchise_provider.dart';
import 'package:pharmadesk/features/inventory/inventory_provider.dart';
import 'package:pharmadesk/features/inventory/quarantine_outcome_queue.dart';
import 'package:pharmadesk/features/reports/analytics_logic.dart';
import 'package:pharmadesk/features/settings/org_settings.dart';
import 'package:pharmadesk/features/suppliers/supplier_logic.dart';
import 'package:pharmadesk/features/suppliers/suppliers_provider.dart';
import 'package:pharmadesk/models/branch.dart';
import 'package:pharmadesk/models/cash_reconciliation.dart';
import 'package:pharmadesk/models/closing_correction.dart';
import 'package:pharmadesk/models/daily_closing.dart';
import 'package:pharmadesk/models/expense.dart';
import 'package:pharmadesk/models/financial_transaction.dart';
import 'package:pharmadesk/models/inventory_item.dart';
import 'package:pharmadesk/models/order.dart';
import 'package:pharmadesk/models/quarantine_outcome_request.dart';
import 'package:pharmadesk/models/sale.dart';
import 'package:pharmadesk/models/sale_return.dart';
import 'package:pharmadesk/models/stock_adjustment_request.dart';
import 'package:pharmadesk/models/supplier_ledger.dart';
import 'package:pharmadesk/models/supplier_payment.dart';

const _dha = 'branch-dha-main';
const _gulberg = 'branch-demo-gulberg';
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

/// An auth notifier whose user can be swapped mid-test — the
/// approval queue needs two different users in one container (the
/// requester, then a different approver).
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

/// Production layer over fresh mocks (same helper shape as the
/// Week 4 Day 5 / Week 5 Day 4 layer tests). [nowProvider] makes
/// the sync queue's clock controllable for the offline flush
/// tests (D143 pattern).
ProductionDataLayer _layer({
  InMemoryAuditLogWriter? audit,
  DateTime Function()? nowProvider,
}) {
  final writer = audit ?? InMemoryAuditLogWriter();
  final queue = SyncQueue(
    InMemorySyncStore(),
    nowProvider: nowProvider,
  );
  final engine = InventoryEngine(organizationId: _org, audit: writer);
  return ProductionDataLayer(
    organizationId: _org,
    inventoryRepo: MockInventoryRepository(),
    saleRepo: MockSaleRepository(),
    orderRepo: MockOrderRepository(),
    customerRepo: MockCustomerRepository(),
    medicineRepo: MockMedicineRepository(),
    supplierRepo: MockSupplierRepository(),
    prescriptionRepo: MockPrescriptionRepository(),
    purchaseOrderRepo: MockPurchaseOrderRepository(),
    riderRepo: MockRiderRepository(),
    stockTransferRepo: MockStockTransferRepository(),
    audit: writer,
    syncQueue: queue,
    engine: engine,
  );
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

/// Drains exceptions the binding recorded during pumping (e.g.
/// RenderFlex overflows) and returns their full texts.
List<String> drainExceptions(WidgetTester tester) {
  final messages = <String>[];
  Object? error;
  while ((error = tester.takeException()) != null) {
    messages.add(error.toString());
  }
  return messages;
}

int countOverflows(List<String> drained) {
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

Order _order({
  required String id,
  String branchId = _dha,
  required double totalAmount,
  required DateTime createdAt,
  OrderStatus status = OrderStatus.placed,
}) {
  return Order(
    id: id,
    customerId: 'cust-1',
    branchId: branchId,
    items: const [],
    deliveryAddress: 'Test address',
    totalAmount: totalAmount,
    status: status,
    createdAt: createdAt,
  );
}

SaleReturn _saleReturn({
  required String id,
  String branchId = _dha,
  required int refundedAmountMinor,
  required DateTime createdAt,
}) {
  return SaleReturn(
    id: id,
    branchId: branchId,
    saleId: 'sale-test-1',
    invoiceNumber: 'INV-TEST-sale-test-1',
    items: const [],
    reason: 'Customer changed their mind',
    refundedAmountMinor: refundedAmountMinor,
    approvedBy: 'test-owner',
    approvedByName: 'Test Owner',
    createdAt: createdAt,
  );
}

DailyClosing _closing({
  String id = 'dc-1',
  int income = 250000,
  int expense = 100000,
  int opening = 0,
}) {
  return DailyClosing(
    id: id,
    branchId: _dha,
    date: _day(0),
    totalIncomeMinor: income,
    totalExpenseMinor: expense,
    openingBalanceMinor: opening,
    closingBalanceMinor: opening + income - expense,
    closedBy: 'test-owner',
    closedAt: DateTime.now(),
  );
}

void main() {
  group('D158 — franchise royalty: pure computation', () {
    test('royalty due is rate × sales in int paisa', () {
      // 5% of Rs 10,000.00 = Rs 500.00.
      expect(rateDueMinor(salesMinor: 1000000, rateBps: 500), 50000);
      // 2.5% of Rs 10,000.00 = Rs 250.00.
      expect(rateDueMinor(salesMinor: 1000000, rateBps: 250), 25000);
      // 10% of Rs 1,234.56.
      expect(rateDueMinor(salesMinor: 123456, rateBps: 1000), 12345);
    });

    test('a sub-paisa remainder truncates — never rounds up', () {
      // 1,000,005 paisa × 333 bps = 333,001,665 / 10,000 =
      // 33,300.1665 paisa → 33,300, not 33,301.
      expect(rateDueMinor(salesMinor: 1000005, rateBps: 333), 33300);
      // 1 paisa of sales at 1 bp is a fraction of a paisa → 0.
      expect(rateDueMinor(salesMinor: 1, rateBps: 1), 0);
    });

    test('an unconfigured rate owes nothing AND shows as unconfigured', () {
      expect(rateDueMinor(salesMinor: 1000000, rateBps: null), isNull);
      expect(franchiseDueLabel(null), 'Not set');
      expect(franchiseDueLabel(50000), 'Rs 500.00');
      // An explicitly configured 0% rate is a real zero, distinct
      // from "Not set".
      expect(rateDueMinor(salesMinor: 1000000, rateBps: 0), 0);
      expect(franchiseDueLabel(0), 'Rs 0.00');
    });

    test('zero sales owe zero when configured', () {
      expect(rateDueMinor(salesMinor: 0, rateBps: 500), 0);
      expect(rateDueMinor(salesMinor: 0, rateBps: null), isNull);
    });

    test('branch sales: POS + orders − returns, branch-scoped, windowed', () {
      final today = _day(0);
      final sales = [
        _sale(
          id: 's1',
          method: SalePaymentMethod.cash,
          amountMinor: 500000,
          createdAt: today.add(const Duration(hours: 10)),
        ),
        _sale(
          id: 's2',
          method: SalePaymentMethod.card,
          amountMinor: 300000,
          createdAt: today.add(const Duration(hours: 11)),
        ),
        // Another branch's sale is not this branch's sales.
        _sale(
          id: 's3',
          branchId: _gulberg,
          method: SalePaymentMethod.cash,
          amountMinor: 999999,
          createdAt: today.add(const Duration(hours: 10)),
        ),
        // Yesterday's sale is outside a today-only window.
        _sale(
          id: 's4',
          method: SalePaymentMethod.cash,
          amountMinor: 111111,
          createdAt: _day(1).add(const Duration(hours: 10)),
        ),
      ];
      final orders = [
        _order(id: 'o1', totalAmount: 1000.0, createdAt: today),
        // A cancelled order is not revenue kept.
        _order(
          id: 'o2',
          totalAmount: 5000.0,
          createdAt: today,
          status: OrderStatus.cancelled,
        ),
        _order(
          id: 'o3',
          branchId: _gulberg,
          totalAmount: 200.0,
          createdAt: today,
        ),
      ];
      final returns = [
        _saleReturn(
          id: 'r1',
          refundedAmountMinor: 50000,
          createdAt: today.add(const Duration(hours: 15)),
        ),
      ];
      // DHA today: 500,000 + 300,000 + 100,000 (order) − 50,000.
      expect(
        branchSalesMinor(
          sales: sales,
          orders: orders,
          returns: returns,
          branchId: _dha,
          start: today,
          end: today,
        ),
        850000,
      );
      // Gulberg today: 999,999 + 20,000 (order).
      expect(
        branchSalesMinor(
          sales: sales,
          orders: orders,
          returns: returns,
          branchId: _gulberg,
          start: today,
          end: today,
        ),
        1019999,
      );
      // A two-day window picks up yesterday's DHA sale too.
      expect(
        branchSalesMinor(
          sales: sales,
          orders: orders,
          returns: returns,
          branchId: _dha,
          start: _day(1),
          end: today,
        ),
        850000 + 111111,
      );
    });

    test('refunds above sales clamp the base at zero, never negative', () {
      final today = _day(0);
      expect(
        branchSalesMinor(
          sales: [
            _sale(
              id: 's1',
              method: SalePaymentMethod.cash,
              amountMinor: 10000,
              createdAt: today,
            ),
          ],
          orders: const [],
          returns: [
            _saleReturn(
              id: 'r1',
              refundedAmountMinor: 50000,
              createdAt: today,
            ),
          ],
          branchId: _dha,
          start: today,
          end: today,
        ),
        0,
      );
    });

    test('per-branch rows are isolated; own branches show Not set', () {
      final today = _day(0);
      final branches = [
        Branch(
          id: _dha,
          name: 'Demo Branch — DHA',
          address: 'DHA Phase 2, Lahore',
          phone: '0300-1111111',
          type: 'franchise',
          royaltyRateBps: 500,
          franchiseFeeRateBps: 200,
        ),
        const Branch(
          id: _gulberg,
          name: 'Demo Branch — Gulberg',
          address: 'Gulberg III, Lahore',
          phone: '0300-2222222',
        ),
        Branch(
          id: 'branch-franchise-closed',
          name: 'Franchise — Closed',
          address: 'Old address',
          phone: '0300-4444444',
          type: 'franchise',
          active: false,
          royaltyRateBps: 1000,
        ),
      ];
      final sales = [
        _sale(
          id: 's1',
          method: SalePaymentMethod.cash,
          amountMinor: 1000000,
          createdAt: today,
        ),
        _sale(
          id: 's2',
          branchId: _gulberg,
          method: SalePaymentMethod.cash,
          amountMinor: 2000000,
          createdAt: today,
        ),
        _sale(
          id: 's3',
          branchId: 'branch-franchise-closed',
          method: SalePaymentMethod.cash,
          amountMinor: 500000,
          createdAt: today,
        ),
      ];
      final rows = computeFranchiseRoyalties(
        branches: branches,
        sales: sales,
        orders: const [],
        returns: const [],
        start: today,
        end: today,
      );
      expect(rows, hasLength(3));
      // DHA franchise: 5% royalty + 2% fee on Rs 10,000.
      expect(rows[0].salesMinor, 1000000);
      expect(rows[0].royaltyDueMinor, 50000);
      expect(rows[0].franchiseFeeDueMinor, 20000);
      expect(rows[0].totalDueMinor, 70000);
      expect(rows[0].hasConfiguredRates, isTrue);
      // Gulberg own branch: sales show, both rates unconfigured.
      expect(rows[1].salesMinor, 2000000);
      expect(rows[1].royaltyDueMinor, isNull);
      expect(rows[1].franchiseFeeDueMinor, isNull);
      expect(rows[1].totalDueMinor, 0);
      expect(rows[1].hasConfiguredRates, isFalse);
      // A deactivated franchise keeps its history: its period
      // sales still accrue its 10% royalty.
      expect(rows[2].salesMinor, 500000);
      expect(rows[2].royaltyDueMinor, 50000);
      expect(rows[2].franchiseFeeDueMinor, isNull);
      expect(rows[2].totalDueMinor, 50000);
      // Report totals sum the rows.
      final report = FranchiseRoyaltyReport(
        days: 1,
        start: today,
        end: today,
        rows: rows,
      );
      expect(report.totalSalesMinor, 3500000);
      expect(report.totalRoyaltyDueMinor, 100000);
      expect(report.totalFranchiseFeeDueMinor, 20000);
      expect(report.totalDueMinor, 120000);
      expect(report.configuredBranchCount, 2);
    });

    test('franchise window starts days-1 before today', () {
      final today = DateTime.now();
      final todayDay = DateTime(today.year, today.month, today.day);
      expect(
        franchiseWindowStart(days: 30, now: today),
        todayDay.subtract(const Duration(days: 29)),
      );
      expect(
        franchiseWindowStart(days: 7, now: today),
        todayDay.subtract(const Duration(days: 6)),
      );
      expect(franchiseWindowStart(days: 1, now: today), todayDay);
    });
  });

  group('D159 — franchise view gating (head-office only)', () {
    test('write-level branches: Super Admin / Owner / HO Admin only', () {
      for (final roleKey in ['super_admin', 'owner', 'ho_admin']) {
        expect(
          canViewFranchiseRoyalties(_userFor(roleKey), _dha),
          isTrue,
          reason: '$roleKey should view franchise royalties',
        );
      }
      for (final roleKey in [
        'regional_manager',
        'branch_manager',
        'pharmacist',
        'cashier',
        'inventory_manager',
        'accountant',
      ]) {
        expect(
          canViewFranchiseRoyalties(_userFor(roleKey), _dha),
          isFalse,
          reason: '$roleKey should NOT view franchise royalties',
        );
      }
      // The Auditor is read-only on `branches` — a view pass on
      // Branch Management, but NOT on head-office royalty figures.
      final auditor = _userFor('auditor');
      expect(permissionService.canInBranch(auditor, 'branches', _dha), isTrue);
      expect(canViewFranchiseRoyalties(auditor, _dha), isFalse);
      expect(permissionService.canWrite(auditor, 'branches', _dha), isFalse);
      // Signed-out passes (the router's auth redirect is the
      // signed-out guard, like every other permission check).
      expect(canViewFranchiseRoyalties(null, _dha), isTrue);
    });

    test('the route maps to the existing branches capability', () {
      expect(routeCapability('/finance/franchise'), 'branches');
      expect(routeCapability('/finance/cashbook'), 'financeEntry');
      expect(routeCapability('/finance/aging'), 'financeReports');
      expect(routeCapability('/branches'), 'branches');
    });

    testWidgets('an Owner sees the report; demo branches show Not set', (
      tester,
    ) async {
      final (_, router) = await pumpRouterAppAsRole(
        tester,
        'owner',
        size: const Size(1024, 768),
      );
      router.go('/finance/franchise');
      await tester.pumpAndSettle();
      expect(find.text('Franchise Royalties'), findsWidgets);
      expect(find.text('Total branch sales'), findsOneWidget);
      expect(find.text('Total commission due'), findsOneWidget);
      // The demo branches are own branches with no rates set.
      expect(find.text('Not set'), findsWidgets);
      // Branch names also appear in the top-bar branch switcher,
      // so these are widgets matches, not one-widget matches.
      expect(find.text('Demo Branch — DHA'), findsWidgets);
      expect(find.text('Demo Branch — Gulberg'), findsWidgets);
      expect(find.textContaining('No permission for'), findsNothing);
      expect(countOverflows(drainExceptions(tester)), 0);
    });

    testWidgets('an Auditor sees the no-permission state, not figures', (
      tester,
    ) async {
      final (_, router) = await pumpRouterAppAsRole(
        tester,
        'auditor',
        size: const Size(1024, 768),
      );
      router.go('/finance/franchise');
      await tester.pumpAndSettle();
      expect(find.text('No permission for Franchise Royalties'), findsWidgets);
      expect(find.text('Total branch sales'), findsNothing);
      expect(find.text('Total commission due'), findsNothing);
    });

    testWidgets('a Cashier is stopped at the route gate', (tester) async {
      final (_, router) = await pumpRouterAppAsRole(
        tester,
        'cashier',
        size: const Size(1024, 768),
      );
      router.go('/finance/franchise');
      await tester.pumpAndSettle();
      expect(find.textContaining('No permission for'), findsWidgets);
      expect(find.text('Total branch sales'), findsNothing);
    });

    testWidgets('the hub card is open for the Owner', (tester) async {
      final (_, ownerRouter) = await pumpRouterAppAsRole(
        tester,
        'owner',
        size: const Size(1024, 768),
      );
      ownerRouter.go('/finance');
      await tester.pumpAndSettle();
      expect(find.text('Franchise Royalties'), findsWidgets);
      expect(
        find.text('No access for your role in this branch (SRS §5.1).'),
        findsNothing,
      );
    });

    testWidgets('the hub card is locked for the Auditor', (tester) async {
      final (_, auditorRouter) = await pumpRouterAppAsRole(
        tester,
        'auditor',
        size: const Size(1024, 768),
      );
      auditorRouter.go('/finance');
      await tester.pumpAndSettle();
      expect(find.text('Franchise Royalties'), findsWidgets);
      // The Auditor passes the other three finance cards
      // (read-only) — the franchise card is the only locked one.
      expect(
        find.text('No access for your role in this branch (SRS §5.1).'),
        findsOneWidget,
      );
    });

    testWidgets('a configured franchise branch shows its dues', (
      tester,
    ) async {
      final (container, router) = await pumpRouterAppAsRole(
        tester,
        'owner',
        size: const Size(1024, 768),
      );
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
      expect(find.text('Franchise — Model Town'), findsWidgets);
      // 5% of Rs 10,000.00 royalty, 2% fee, Rs 700.00 total.
      expect(find.text('Rs 500.00'), findsWidgets);
      expect(find.text('Rs 200.00'), findsWidgets);
      expect(find.text('Rs 700.00'), findsWidgets);
      expect(countOverflows(drainExceptions(tester)), 0);
    });
  });

  group('Phase 8 — route walk: every route resolves (Week 5)', () {
    testWidgets('Week 5 routes + finance / system hub routes resolve', (
      tester,
    ) async {
      final (_, router) = await pumpRouterApp(
        tester,
        size: const Size(1280, 800),
      );
      const routes = <(String, String)>[
        ('/inventory/adjustments', 'Adjustment Approvals'),
        ('/inventory/quarantine-outcomes', 'Quarantine Outcomes'),
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

  group('Phase 8 — 390px sweep: new / changed screens', () {
    testWidgets('medicine edit form opens clean at 390px', (tester) async {
      final (_, router) = await pumpRouterAppAsRole(
        tester,
        'owner',
        size: _phoneSize,
      );
      router.go('/medicines/med-panadol-extra');
      await tester.pumpAndSettle();
      expect(find.textContaining('Panadol Extra'), findsWidgets);
      await tester.ensureVisible(
        find.byKey(const ValueKey('medicine-edit')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('medicine-edit')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('medicine-name-field')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('medicine-sale-price-field')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('medicine-edit-save')),
        findsOneWidget,
      );
      expect(countOverflows(drainExceptions(tester)), 0);
    });

    testWidgets('branch shelf dialog saves clean at 390px', (tester) async {
      final (_, router) = await pumpRouterAppAsRole(
        tester,
        'owner',
        size: _phoneSize,
      );
      router.go('/medicines/med-panadol-extra');
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('medicine-branch-shelf')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('medicine-branch-shelf')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('branch-rack-field')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('branch-shelf-field')),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const ValueKey('branch-rack-field')),
        'B',
      );
      await tester.enterText(
        find.byKey(const ValueKey('branch-shelf-field')),
        '1',
      );
      await tester.tap(find.byKey(const ValueKey('branch-shelf-save')));
      await tester.pumpAndSettle();
      expect(find.textContaining('(this branch)'), findsWidgets);
      expect(countOverflows(drainExceptions(tester)), 0);
    });

    testWidgets('quarantine outcomes queue (populated) fits at 390px', (
      tester,
    ) async {
      final (container, router, _) = await pumpRouterAppWithMutableAuth(
        tester,
        _userFor('inventory_manager'),
        size: _phoneSize,
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
      expect(
        find.text('Waiting for an approver (not the requester).'),
        findsOneWidget,
      );
      expect(countOverflows(drainExceptions(tester)), 0);
    });

    testWidgets('POS with cash disabled fits at 390px', (tester) async {
      final (container, router) = await pumpRouterAppAsRole(
        tester,
        'cashier',
        size: _phoneSize,
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
      expect(countOverflows(drainExceptions(tester)), 0);
    });

    testWidgets('cashbook with correction + reconciliation fits at 390px', (
      tester,
    ) async {
      final (container, router) = await pumpRouterAppAsRole(
        tester,
        'owner',
        size: _phoneSize,
      );
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
      expect(countOverflows(drainExceptions(tester)), 0);
    });

    testWidgets('franchise view with configured rates fits at 390px', (
      tester,
    ) async {
      final (container, router) = await pumpRouterAppAsRole(
        tester,
        'owner',
        size: _phoneSize,
      );
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
      expect(countOverflows(drainExceptions(tester)), 0);
    });

    testWidgets('aging screen fits at 390px', (tester) async {
      final (_, router) = await pumpRouterAppAsRole(
        tester,
        'owner',
        size: _phoneSize,
      );
      router.go('/finance/aging');
      await tester.pumpAndSettle();
      expect(find.text('Payables & Receivables'), findsOneWidget);
      expect(find.text('Supplier payables'), findsOneWidget);
      expect(countOverflows(drainExceptions(tester)), 0);
    });

    testWidgets('statements screen fits at 390px', (tester) async {
      final (_, router) = await pumpRouterAppAsRole(
        tester,
        'owner',
        size: _phoneSize,
      );
      router.go('/finance/statements');
      await tester.pumpAndSettle();
      expect(find.text('P&L & Statements'), findsOneWidget);
      expect(countOverflows(drainExceptions(tester)), 0);
    });
  });

  group('Phase 8 — offline queue: new flows (D143 pattern)', () {
    test('adjustment filing works offline, flushes once, never twice', () async {
      final layer = _layer();
      final request = StockAdjustmentRequest(
        id: 'adj-offline-1',
        batchId: 'inv-test-1',
        batchNo: 'B-TEST-1',
        medicineId: 'med-panadol-extra',
        medicineName: 'Panadol Extra',
        branchId: _dha,
        deltaQty: -2,
        reason: 'Damaged on shelf',
        requesterId: 'test-inventory_manager',
        requesterName: 'Test Inventory Mgr',
        requestedAt: DateTime.now(),
      );
      // Filing enqueues the sync payload at write time — no
      // transport is involved, so the write "works offline".
      final filed = await layer.fileAdjustmentRequest(request);
      expect(filed.id, 'adj-offline-1');
      expect(await layer.syncQueue.pendingCount(), 1);
      expect(layer.lastSyncAt, isNull);
      // Reconnect: the payload flushes exactly once.
      final sent = <String>[];
      final flushed = await layer.syncQueue.processAll((op) async {
        sent.add(op.idempotencyKey);
        return true;
      });
      expect(flushed, 1);
      expect(sent, hasLength(1));
      expect(await layer.syncQueue.pendingCount(), 0);
      expect(layer.lastSyncAt, isNotNull);
      // A second flush sends nothing, and re-filing the same
      // request id returns the original without a new payload.
      final again = await layer.syncQueue.processAll((op) async {
        sent.add(op.idempotencyKey);
        return true;
      });
      expect(again, 0);
      expect(sent, hasLength(1));
      final refiled = await layer.fileAdjustmentRequest(request);
      expect(refiled.id, filed.id);
      expect(await layer.syncQueue.pendingCount(), 0);
      expect((await layer.loadAdjustmentRequests()).length, 1);
    });

    test('supplier payment works offline, flushes once, never twice', () async {
      final layer = _layer();
      final before = await layer.supplierRepo.getLedgerEntries('sup-medserve');
      final beforeCount = before.length;
      final result = await layer.recordSupplierPayment(
        supplierId: 'sup-medserve',
        branchId: _dha,
        amountMinor: 1000000,
        allocations: [
          PaymentAllocation(ledgerEntryId: 'sled-2', amountMinor: 1000000),
        ],
        idempotencyKey: 'supplier-payment-offline-1',
      );
      expect(result.isDuplicate, isFalse);
      expect(result.payment.amountMinor, 1000000);
      expect(await layer.syncQueue.pendingCount(), 1);
      expect(layer.lastSyncAt, isNull);
      final flushed = await layer.syncQueue.processAll((_) async => true);
      expect(flushed, 1);
      expect(await layer.syncQueue.pendingCount(), 0);
      // Retry with the same key: the original payment, no new
      // ledger entry, no new payload — no money moves twice.
      final retry = await layer.recordSupplierPayment(
        supplierId: 'sup-medserve',
        branchId: _dha,
        amountMinor: 1000000,
        allocations: [
          PaymentAllocation(ledgerEntryId: 'sled-2', amountMinor: 1000000),
        ],
        idempotencyKey: 'supplier-payment-offline-1',
      );
      expect(retry.isDuplicate, isTrue);
      expect(retry.payment.id, result.payment.id);
      expect(await layer.syncQueue.pendingCount(), 0);
      final after = await layer.supplierRepo.getLedgerEntries('sup-medserve');
      expect(after.length, beforeCount + 1);
      expect(after.last.amountMinor, -1000000);
    });

    test('branch save works offline, flushes once', () async {
      final layer = _layer();
      final saved = await layer.saveBranch(
        const Branch(
          id: 'branch-offline-1',
          name: 'Offline Branch',
          address: 'Test address',
          phone: '0300-9999999',
        ),
      );
      expect(saved.id, 'branch-offline-1');
      expect(await layer.syncQueue.pendingCount(), 1);
      expect(layer.lastSyncAt, isNull);
      final flushed = await layer.syncQueue.processAll((_) async => true);
      expect(flushed, 1);
      expect(await layer.syncQueue.pendingCount(), 0);
      expect(await layer.getBranch('branch-offline-1'), isNotNull);
      final again = await layer.syncQueue.processAll((_) async => true);
      expect(again, 0);
    });

    test('quarantine outcome works offline, flushes, never applies twice',
        () async {
      final layer = _layer();
      final batch = (await layer.inventoryRepo.getInventory(branchId: _dha))
          .firstWhere((item) => item.medicineId == 'med-panadol-extra');
      final parked = await layer.quarantineBatch(
        batchId: batch.id,
        reason: 'Suspected damage',
        idempotencyKey: 'quarantine-offline-1',
      );
      expect(parked.status, BatchStatus.quarantined);
      expect(await layer.syncQueue.pendingCount(), 1);
      final disposed = await layer.applyQuarantineOutcome(
        batchId: parked.id,
        outcome: QuarantineOutcome.dispose,
        reason: 'Damaged beyond use',
        actorId: 'test-owner',
        actorName: 'Test Owner',
        idempotencyKey: 'outcome-offline-1',
      );
      expect(disposed.status, BatchStatus.disposed);
      expect(await layer.syncQueue.pendingCount(), 2);
      final flushed = await layer.syncQueue.processAll((_) async => true);
      expect(flushed, 2);
      expect(await layer.syncQueue.pendingCount(), 0);
      final retry = await layer.applyQuarantineOutcome(
        batchId: parked.id,
        outcome: QuarantineOutcome.dispose,
        reason: 'Damaged beyond use',
        idempotencyKey: 'outcome-offline-1',
      );
      expect(retry.id, disposed.id);
      expect(retry.status, BatchStatus.disposed);
      expect(await layer.syncQueue.pendingCount(), 0);
      final again = await layer.syncQueue.processAll((_) async => true);
      expect(again, 0);
    });

    test('closing correction + reconciliation work offline, flush once',
        () async {
      final layer = _layer();
      final correction = await layer.recordClosingCorrection(
        correction: ClosingCorrection(
          id: '',
          branchId: _dha,
          originalClosingId: 'dc-1',
          date: _day(0),
          correctedIncomeMinor: 200000,
          correctedExpenseMinor: 100000,
          correctedClosingBalanceMinor: 100000,
          reason: 'Rs 500 income entered twice',
          correctedBy: 'test-owner',
          correctedAt: DateTime.now(),
        ),
        actorId: 'test-owner',
        actorName: 'Test Owner',
        idempotencyKey: 'correction-offline-1',
      );
      expect(correction.id, isNotEmpty);
      expect(await layer.syncQueue.pendingCount(), 1);
      final recon = await layer.recordCashReconciliation(
        reconciliation: CashReconciliation(
          id: '',
          branchId: _dha,
          date: _day(0),
          expectedMinor: 600000,
          countedMinor: 595000,
          differenceMinor: -5000,
          note: 'Rs 50 short',
          countedBy: 'test-owner',
          countedAt: DateTime.now(),
        ),
        actorId: 'test-owner',
        actorName: 'Test Owner',
        idempotencyKey: 'recon-offline-1',
      );
      expect(recon.id, isNotEmpty);
      expect(await layer.syncQueue.pendingCount(), 2);
      final flushed = await layer.syncQueue.processAll((_) async => true);
      expect(flushed, 2);
      expect(await layer.syncQueue.pendingCount(), 0);
      // Retries with the same keys return the originals and
      // enqueue nothing more.
      final retryCorrection = await layer.recordClosingCorrection(
        correction: ClosingCorrection(
          id: '',
          branchId: _dha,
          originalClosingId: 'dc-1',
          date: _day(0),
          correctedIncomeMinor: 200000,
          correctedExpenseMinor: 100000,
          correctedClosingBalanceMinor: 100000,
          reason: 'Rs 500 income entered twice',
        ),
        idempotencyKey: 'correction-offline-1',
      );
      expect(retryCorrection.id, correction.id);
      final retryRecon = await layer.recordCashReconciliation(
        reconciliation: CashReconciliation(
          id: '',
          branchId: _dha,
          date: _day(0),
          expectedMinor: 600000,
          countedMinor: 595000,
          differenceMinor: -5000,
        ),
        idempotencyKey: 'recon-offline-1',
      );
      expect(retryRecon.id, recon.id);
      expect(await layer.syncQueue.pendingCount(), 0);
    });

    test('a failed send keeps the op, and it flushes past the back-off',
        () async {
      var now = DateTime(2026, 11, 26, 12, 0, 0);
      final layer = _layer(nowProvider: () => now);
      await layer.recordSupplierPayment(
        supplierId: 'sup-medserve',
        branchId: _dha,
        amountMinor: 500000,
        allocations: [
          PaymentAllocation(ledgerEntryId: 'sled-2', amountMinor: 500000),
        ],
        idempotencyKey: 'supplier-payment-backoff-1',
      );
      expect(await layer.syncQueue.pendingCount(), 1);
      // Offline: the send fails — the op is kept, with a back-off.
      final offline = await layer.syncQueue.processAll((_) async => false);
      expect(offline, 0);
      expect((await layer.syncQueue.store.all()).length, 1);
      // `pendingCount` reads the real clock, so a controllable
      // clock needs `pendingOperations` (D143 pattern): right
      // after the failure the op is backing off, not due.
      expect((await layer.syncQueue.pendingOperations()).length, 0);
      expect(layer.lastSyncAt, isNull);
      // Past the back-off it is due again and flushes on reconnect.
      now = now.add(const Duration(seconds: 10));
      expect((await layer.syncQueue.pendingOperations()).length, 1);
      final flushed = await layer.syncQueue.processAll((_) async => true);
      expect(flushed, 1);
      expect(await layer.syncQueue.pendingCount(), 0);
      expect(layer.lastSyncAt, isNotNull);
    });
  });

  group('Phase 8 — role gates: new routes (D144 pattern)', () {
    const routes = <(String, String)>[
      ('/inventory/quarantine-outcomes', 'Quarantine Outcomes'),
      ('/finance/franchise', 'Franchise Royalties'),
    ];

    for (final roleKey in srsRoleKeys) {
      testWidgets('role $roleKey reaches exactly its matrix routes', (
        tester,
      ) async {
        final user = _userFor(roleKey);
        final (_, router) = await pumpRouterAppAsRole(
          tester,
          roleKey,
          size: const Size(1280, 800),
        );
        for (final (route, marker) in routes) {
          // The expected outcome comes from the matrix itself — the
          // test pins the WIRING, not a second copy of the matrix.
          // The franchise route is the one deliberate exception to
          // the D144 read-only rule: it needs write-level
          // `branches`, so the Auditor's read-only pass stops at
          // the screen (D159).
          final allowed = route == '/finance/franchise'
              ? permissionService.canWrite(user, 'branches', _dha)
              : routeCapability(route) == null ||
                    permissionService.canInBranch(
                      user,
                      routeCapability(route)!,
                      _dha,
                    );
          router.go(route);
          await tester.pump(const Duration(milliseconds: 400));
          await tester.pumpAndSettle();
          if (allowed) {
            expect(
              find.textContaining('No permission for'),
              findsNothing,
              reason: '$roleKey should reach $route',
            );
            expect(
              find.text(marker),
              findsWidgets,
              reason: '$roleKey should see $marker on $route',
            );
          } else {
            expect(
              find.textContaining('No permission for'),
              findsWidgets,
              reason: '$roleKey should be gated from $route',
            );
          }
        }
      });
    }

    test('spot checks: Auditor divergence, Owner + HO Admin pass', () {
      final auditor = _userFor('auditor');
      // The Auditor CAN view Branch Management (read-only view
      // gate) but NOT franchise royalties (write-level gate).
      expect(
        permissionService.canInBranch(auditor, 'branches', _dha),
        isTrue,
      );
      expect(canViewFranchiseRoyalties(auditor, _dha), isFalse);
      // …and cannot reach the quarantine queue either
      // (`stockAdjustReq` is none for the Auditor).
      expect(
        permissionService.canInBranch(auditor, 'stockAdjustReq', _dha),
        isFalse,
      );
      for (final roleKey in ['owner', 'ho_admin']) {
        final user = _userFor(roleKey);
        expect(canViewFranchiseRoyalties(user, _dha), isTrue);
        expect(
          permissionService.canInBranch(user, 'stockAdjustReq', _dha),
          isTrue,
        );
      }
      // An Inventory Mgr may request (and see the queue) in their
      // own branch, but never the franchise figures.
      final inventoryMgr = _userFor('inventory_manager');
      expect(
        permissionService.canInBranch(
          inventoryMgr,
          'stockAdjustReq',
          _dha,
        ),
        isTrue,
      );
      expect(canViewFranchiseRoyalties(inventoryMgr, _dha), isFalse);
    });
  });

  group('Phase 8 — finance hub agreement, second pass (D160)', () {
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

    /// Cashbook entries in the trailing-[days]-day window ending
    /// today — the SAME window [computeProfitAndLoss] uses, so the
    /// two figures are comparable. The mock expense repo is seeded,
    /// so an unwindowed sum would mix in older history.
    Future<List<CashbookEntry>> cashbookEntriesInWindow(
      ProductionDataLayer layer, {
      int days = 30,
    }) async {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final start = today.subtract(Duration(days: days - 1));
      final entries = cashbookEntries(
        expenses: await layer.expenseRepo.getExpenses(branchId: _dha),
        transactions: await layer.financialTransactionRepo.getTransactions(
          branchId: _dha,
        ),
        branchId: _dha,
      );
      return entries.where((entry) {
        final day = DateTime(
          entry.date.year,
          entry.date.month,
          entry.date.day,
        );
        return !day.isBefore(start) && !day.isAfter(today);
      }).toList();
    }

    Future<({int incomeMinor, int expenseMinor})> cashbookSums(
      ProductionDataLayer layer,
    ) async {
      final entries = await cashbookEntriesInWindow(layer);
      var income = 0;
      var expense = 0;
      for (final entry in entries) {
        if (entry.kind == CashbookEntryKind.income) {
          income += entry.amountMinor;
        } else {
          expense += entry.amountMinor;
        }
      }
      return (incomeMinor: income, expenseMinor: expense);
    }

    test('cashbook income/expense agree with the P&L, same window', () async {
      final layer = _layer();
      final sumsBefore = await cashbookSums(layer);
      await layer.recordExpense(
        branchId: _dha,
        category: 'Utilities',
        amountMinor: 500000,
        description: 'Electricity bill',
        expenseDate: _day(0),
        createdBy: 'test-owner',
        idempotencyKey: 'agreement-expense-1',
      );
      await layer.recordIncome(
        branchId: _dha,
        category: 'Other income',
        amountMinor: 250000,
        date: _day(0),
        createdBy: 'test-owner',
        idempotencyKey: 'agreement-income-1',
      );
      final sums = await cashbookSums(layer);
      // The new entries move the windowed sums by exactly their
      // amounts (the repo is seeded, so only the delta is pinned).
      expect(sums.incomeMinor - sumsBefore.incomeMinor, 250000);
      expect(sums.expenseMinor - sumsBefore.expenseMinor, 500000);
      final pl = await plFromRepos(layer);
      // The P&L's other income IS the cashbook's income, and its
      // expenses ARE the cashbook's expenses — same lists, same
      // window, so the two screens can never disagree.
      expect(pl.otherIncomeMinor, sums.incomeMinor);
      expect(pl.expensesMinor, sums.expenseMinor);
      // Net is derived from the same inputs (seeded demo orders
      // contribute revenue/COGS here, so only the derivation is
      // pinned, not an absolute figure).
      expect(
        pl.netProfitMinor,
        pl.grossProfitMinor + pl.otherIncomeMinor - pl.expensesMinor,
      );
      // The expense's mirror transaction (type `expense`,
      // −500,000) is not income and is not a second expense: the
      // cashbook shows one expense line for it.
      final entries = await cashbookEntriesInWindow(layer);
      expect(
        entries.where(
          (e) =>
              e.kind == CashbookEntryKind.expense &&
              e.note == 'Electricity bill',
        ),
        hasLength(1),
      );
    });

    test('a closing correction moves neither the cashbook nor the P&L',
        () async {
      final layer = _layer();
      await layer.recordExpense(
        branchId: _dha,
        category: 'Supplies',
        amountMinor: 10000,
        description: 'Today supplies',
        expenseDate: _day(0),
        createdBy: 'test-owner',
        idempotencyKey: 'agreement-expense-2',
      );
      await layer.recordIncome(
        branchId: _dha,
        category: 'Other income',
        amountMinor: 25000,
        date: _day(0),
        createdBy: 'test-owner',
        idempotencyKey: 'agreement-income-2',
      );
      final sumsBefore = await cashbookSums(layer);
      final plBefore = await plFromRepos(layer);
      // A correction re-states a CLOSING record — it never rewrites
      // an entry, so the books it is computed from do not move.
      await layer.recordClosingCorrection(
        correction: ClosingCorrection(
          id: '',
          branchId: _dha,
          originalClosingId: 'dc-1',
          date: _day(0),
          correctedIncomeMinor: 20000,
          correctedExpenseMinor: 10000,
          correctedClosingBalanceMinor: 10000,
          reason: 'Income was Rs 200, not Rs 250',
          correctedBy: 'test-owner',
          correctedAt: DateTime.now(),
        ),
        actorId: 'test-owner',
        actorName: 'Test Owner',
        idempotencyKey: 'agreement-correction-1',
      );
      final sumsAfter = await cashbookSums(layer);
      final plAfter = await plFromRepos(layer);
      expect(sumsAfter.incomeMinor, sumsBefore.incomeMinor);
      expect(sumsAfter.expenseMinor, sumsBefore.expenseMinor);
      expect(plAfter.otherIncomeMinor, plBefore.otherIncomeMinor);
      expect(plAfter.expensesMinor, plBefore.expensesMinor);
      expect(plAfter.netProfitMinor, plBefore.netProfitMinor);
      // …while the closing itself DOES show the corrected figures
      // (the original record is untouched — the adjustment is a
      // read-side view over the correction).
      final adjusted = adjustedClosingTotals(
        original: _closing(income: 25000, expense: 10000, opening: 0),
        corrections: [
          ClosingCorrection(
            id: 'cc-1',
            branchId: _dha,
            originalClosingId: 'dc-1',
            date: _day(0),
            correctedIncomeMinor: 20000,
            correctedExpenseMinor: 10000,
            correctedClosingBalanceMinor: 10000,
            reason: 'Income was Rs 200, not Rs 250',
            correctedAt: DateTime.now(),
          ),
        ],
      );
      expect(adjusted.corrected, isTrue);
      expect(adjusted.incomeMinor, 20000);
      expect(adjusted.closingBalanceMinor, 10000);
    });

    test('a supplier payment moves the aging, not the P&L', () async {
      final layer = _layer();
      final ledgerBefore = await layer.supplierRepo.getLedgerEntries(
        'sup-medserve',
      );
      final agingBefore = computeAging(
        entries: supplierLedgerSignedEntries(ledgerBefore),
        now: DateTime.now(),
      );
      expect(agingBefore.totalMinor, 4825000);
      expect(
        supplierOutstandingMinor(ledgerBefore),
        agingBefore.totalMinor,
      );
      final plBefore = await plFromRepos(layer);
      final result = await layer.recordSupplierPayment(
        supplierId: 'sup-medserve',
        branchId: _dha,
        amountMinor: 1000000,
        allocations: [
          PaymentAllocation(ledgerEntryId: 'sled-2', amountMinor: 1000000),
        ],
        idempotencyKey: 'agreement-supplier-payment-1',
      );
      expect(result.isDuplicate, isFalse);
      final ledgerAfter = await layer.supplierRepo.getLedgerEntries(
        'sup-medserve',
      );
      final agingAfter = computeAging(
        entries: supplierLedgerSignedEntries(ledgerAfter),
        now: DateTime.now(),
      );
      // The payable falls by exactly the payment, and the aging
      // total, the ledger sum and the stored running balance all
      // agree on the new figure.
      expect(agingAfter.totalMinor, 3825000);
      expect(supplierOutstandingMinor(ledgerAfter), 3825000);
      expect(ledgerAfter.last.balanceAfterMinor, 3825000);
      expect(ledgerAfter.last.amountMinor, -1000000);
      // Paying a payable is balance-sheet, not P&L: revenue, other
      // income, expenses and net are all unchanged (the
      // supplierPayment transaction is not income).
      final plAfter = await plFromRepos(layer);
      expect(plAfter.revenueMinor, plBefore.revenueMinor);
      expect(plAfter.otherIncomeMinor, plBefore.otherIncomeMinor);
      expect(plAfter.expensesMinor, plBefore.expensesMinor);
      expect(plAfter.netProfitMinor, plBefore.netProfitMinor);
    });

    test('seeded aging buckets agree with the supplier ledger', () {
      final entries = generateDemoSupplierLedgerEntries();
      final now = DateTime.now();
      // Per supplier: aging total == ledger sum == stored running
      // balance, and the bucket split sums to the total.
      for (final supplier in demoSuppliers) {
        final scoped = entries
            .where((e) => e.supplierId == supplier.id)
            .toList();
        final aging = computeAging(
          entries: supplierLedgerSignedEntries(scoped),
          now: now,
        );
        expect(
          aging.totalMinor,
          supplierOutstandingMinor(scoped),
          reason: '${supplier.id} aging vs ledger sum',
        );
        final bucketSum = AgingBucket.values.fold(
          0,
          (sum, bucket) => sum + aging.bucket(bucket),
        );
        expect(bucketSum, aging.totalMinor);
        if (scoped.isNotEmpty) {
          expect(
            aging.totalMinor,
            scoped.last.balanceAfterMinor,
            reason: '${supplier.id} aging vs stored balance',
          );
        }
      }
      final sami = computeAging(
        entries: supplierLedgerSignedEntries(
          entries.where((e) => e.supplierId == 'sup-sami').toList(),
        ),
        now: now,
      );
      // Sami's Rs 125,000.00 charge is 28 days old → Current.
      expect(sami.totalMinor, 12500000);
      expect(sami.bucket(AgingBucket.current), 12500000);
      expect(sami.bucket(AgingBucket.days30), 0);
      final medserve = computeAging(
        entries: supplierLedgerSignedEntries(
          entries.where((e) => e.supplierId == 'sup-medserve').toList(),
        ),
        now: now,
      );
      // MedServe: Rs 60,000.00 charge (25d) − Rs 11,750.00 payment.
      expect(medserve.totalMinor, 4825000);
      expect(medserve.bucket(AgingBucket.current), 4825000);
      final careline = computeAging(
        entries: supplierLedgerSignedEntries(
          entries.where((e) => e.supplierId == 'sup-careline').toList(),
        ),
        now: now,
      );
      expect(careline.totalMinor, 2100000);
      final hassan = computeAging(
        entries: supplierLedgerSignedEntries(
          entries.where((e) => e.supplierId == 'sup-hassan-traders').toList(),
        ),
        now: now,
      );
      expect(hassan.totalMinor, 0);
      // Org-wide outstanding: 125,000 + 48,250 + 21,000.
      final orgTotal = demoSuppliers.fold(0, (sum, supplier) {
        final scoped = entries
            .where((e) => e.supplierId == supplier.id)
            .toList();
        return sum +
            computeAging(
              entries: supplierLedgerSignedEntries(scoped),
              now: now,
            ).totalMinor;
      });
      expect(orgTotal, 19425000);
    });

    test('aging buckets split a mixed-age ledger FIFO, summing to the total',
        () {
      final today = DateTime.now();
      final day = DateTime(today.year, today.month, today.day);
      DateTime daysAgo(int days) =>
          day.subtract(Duration(days: days)).add(const Duration(hours: 10));
      final entries = <SupplierLedgerEntry>[
        SupplierLedgerEntry(
          id: 't-1',
          supplierId: 'sup-test',
          kind: SupplierLedgerEntryKind.purchase,
          amountMinor: 1000000,
          reason: 'Charge 10 days ago',
          balanceAfterMinor: 1000000,
          createdAt: daysAgo(10),
        ),
        SupplierLedgerEntry(
          id: 't-2',
          supplierId: 'sup-test',
          kind: SupplierLedgerEntryKind.purchase,
          amountMinor: 2000000,
          reason: 'Charge 45 days ago',
          balanceAfterMinor: 3000000,
          createdAt: daysAgo(45),
        ),
        SupplierLedgerEntry(
          id: 't-3',
          supplierId: 'sup-test',
          kind: SupplierLedgerEntryKind.purchase,
          amountMinor: 3000000,
          reason: 'Charge 75 days ago',
          balanceAfterMinor: 6000000,
          createdAt: daysAgo(75),
        ),
        SupplierLedgerEntry(
          id: 't-4',
          supplierId: 'sup-test',
          kind: SupplierLedgerEntryKind.purchase,
          amountMinor: 4000000,
          reason: 'Charge 120 days ago',
          balanceAfterMinor: 10000000,
          createdAt: daysAgo(120),
        ),
        SupplierLedgerEntry(
          id: 't-5',
          supplierId: 'sup-test',
          kind: SupplierLedgerEntryKind.payment,
          amountMinor: -1500000,
          reason: 'Part payment',
          balanceAfterMinor: 8500000,
          createdAt: day,
        ),
      ];
      final aging = computeAging(
        entries: supplierLedgerSignedEntries(entries),
        now: today,
      );
      // FIFO settles the OLDEST charge first: the Rs 15,000.00
      // payment settles Rs 15,000.00 of the 120-day charge, so the
      // 10-day charge is untouched and the 120-day one is left
      // with Rs 25,000.00.
      expect(aging.totalMinor, 8500000);
      expect(aging.bucket(AgingBucket.current), 1000000);
      expect(aging.bucket(AgingBucket.days30), 2000000);
      expect(aging.bucket(AgingBucket.days60), 3000000);
      expect(aging.bucket(AgingBucket.days90plus), 2500000);
      final bucketSum = AgingBucket.values.fold(
        0,
        (sum, bucket) => sum + aging.bucket(bucket),
      );
      expect(bucketSum, aging.totalMinor);
      expect(supplierOutstandingMinor(entries), aging.totalMinor);
      expect(entries.last.balanceAfterMinor, aging.totalMinor);
    });

    test('aging providers agree with the ledger per supplier', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final suppliers = await container.read(suppliersProvider.future);
      expect(suppliers, hasLength(4));
      var orgTotal = 0;
      for (final supplier in suppliers) {
        final entries = await container
            .read(supplierLedgerProvider(supplier.id).future);
        final aging = container.read(supplierAgingProvider(supplier.id));
        expect(
          aging.totalMinor,
          supplierOutstandingMinor(entries),
          reason: '${supplier.id} provider aging vs ledger sum',
        );
        final outstanding = container.read(
          supplierOutstandingProvider(supplier.id),
        );
        expect(outstanding, aging.totalMinor);
        orgTotal += aging.totalMinor;
      }
      expect(orgTotal, 19425000);
      final all = container.read(allPayablesAgingProvider);
      expect(all.length, 4);
      expect(
        all.values.fold(0, (sum, aging) => sum + aging.totalMinor),
        orgTotal,
      );
    });

    test('closing totals agree with the cashbook; the drawer follows entries',
        () {
      final today = _day(0);
      final sales = [
        _sale(
          id: 's1',
          method: SalePaymentMethod.cash,
          amountMinor: 500000,
          createdAt: today.add(const Duration(hours: 10)),
        ),
        _sale(
          id: 's2',
          method: SalePaymentMethod.card,
          amountMinor: 300000,
          createdAt: today.add(const Duration(hours: 11)),
        ),
      ];
      final entries = cashbookEntries(
        expenses: [
          Expense(
            id: 'e1',
            branchId: _dha,
            category: 'Supplies',
            amountMinor: 20000,
            expenseDate: today,
          ),
        ],
        transactions: [
          FinancialTransaction(
            id: 't1',
            branchId: _dha,
            type: FinancialTransactionType.income,
            amountMinor: 50000,
            category: 'Other income',
            createdAt: today,
          ),
        ],
        branchId: _dha,
      );
      // The closing for the day IS the day's cashbook entries:
      // income Rs 500.00, expense Rs 200.00.
      final totals = computeDailyClosing(
        entries: entries,
        date: today,
        openingBalanceMinor: 100000,
      );
      expect(totals.incomeMinor, 50000);
      expect(totals.expenseMinor, 20000);
      expect(totals.closingBalanceMinor, 130000);
      // The expected drawer follows the same entries (opening +
      // cash sales + income − expense); card sales never touch it.
      expect(
        expectedDrawerMinor(
          sales: sales,
          entries: entries,
          openingBalanceMinor: 100000,
          date: today,
        ),
        630000,
      );
      // A correction re-states the closing, not the entries: the
      // drawer and the ORIGINAL closing still follow the entries.
      final original = _closing(income: 50000, expense: 20000, opening: 100000);
      final adjusted = adjustedClosingTotals(
        original: original,
        corrections: [
          ClosingCorrection(
            id: 'cc-1',
            branchId: _dha,
            originalClosingId: 'dc-1',
            date: today,
            correctedIncomeMinor: 40000,
            correctedExpenseMinor: 20000,
            correctedClosingBalanceMinor: 120000,
            reason: 'Rs 100 income was a duplicate',
            correctedAt: DateTime.now(),
          ),
        ],
      );
      expect(adjusted.incomeMinor, 40000);
      expect(adjusted.closingBalanceMinor, 120000);
      expect(original.totalIncomeMinor, 50000);
      expect(original.closingBalanceMinor, 130000);
      expect(
        expectedDrawerMinor(
          sales: sales,
          entries: entries,
          openingBalanceMinor: 100000,
          date: today,
        ),
        630000,
      );
      expect(
        dailyClosingIsStale(closing: original, entries: entries),
        isFalse,
      );
    });
  });
}
