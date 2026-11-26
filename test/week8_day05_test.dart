// Week 8 Day 5 tests — final QA sweep (D180, brief §5).
//
// - Finance agreement, FOURTH and final pass: the guarded writes
//   (D161/D162) + idempotent payments (D162) + re-keyed restore
//   (D173) + counter advance (D175), with NEW angles this pass —
//   the correction chain (a corrected day's closing must flow into
//   the NEXT day's opening, close totals and expected drawer),
//   the split-payment cash leg in the reconciliation, the
//   counter-advance order moving the P&L and the daily counter by
//   exactly its amount once, and one full day with all four views
//   (cashbook vs P&L vs supplier ledger vs closing vs
//   reconciliation) agreeing in integer paisa.
// - Offline queue + role gates for the Week 8 flows: the Day 38
//   WhatsApp-order flow enqueues exactly one sync op, drains once,
//   and a same-key retry enqueues nothing (the Day 38 sale enqueue
//   is already pinned in week8_day01_test.dart §9 test 2 and is
//   re-run by the cumulative suite, not duplicated here); the
//   prescription Approve gate is re-pinned on the final tree
//   (pharmacist approves, Owner cannot). Every other Week 8 flow
//   has no queue/gate surface — the verdicts are recorded in
//   docs/day-42-progress.md §2, not invented as tests.
// - 390px sweep + 47-route walk RE-RUN on the final tree with the
//   corrected `FlutterError.onError` trap (D170/D174 standard —
//   counting DISTINCT overflow messages; the D160 `takeException`
//   drain is NOT the measurement here). The tree changed since
//   Day 39 only by docs + test files, so 0 is expected — verified,
//   not assumed.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharmadesk/core/data/audit_log.dart';
import 'package:pharmadesk/core/data/firestore_repositories.dart';
import 'package:pharmadesk/core/data/firestore_schema.dart';
import 'package:pharmadesk/core/data/inventory_engine.dart';
import 'package:pharmadesk/core/data/production_data_layer.dart';
import 'package:pharmadesk/core/data/report_counters.dart';
import 'package:pharmadesk/core/data/sync_queue.dart';
import 'package:pharmadesk/core/services/repositories.dart';
import 'package:pharmadesk/features/authentication/auth_state.dart';
import 'package:pharmadesk/features/finance/finance_logic.dart';
import 'package:pharmadesk/features/finance/finance_provider.dart';
import 'package:pharmadesk/features/orders/orders_provider.dart';
import 'package:pharmadesk/features/reports/analytics_logic.dart';
import 'package:pharmadesk/features/suppliers/supplier_logic.dart';
import 'package:pharmadesk/models/cash_reconciliation.dart';
import 'package:pharmadesk/models/daily_closing.dart';
import 'package:pharmadesk/models/order.dart';
import 'package:pharmadesk/models/sale.dart';
import 'package:pharmadesk/models/supplier_payment.dart';

import 'week2_day03_test.dart';
import 'week7_day04_test.dart';

const _dha = 'branch-dha-main';
const _org = demoOrganizationId;
const _desktopSize = Size(1920, 1080);
const _phoneSize = Size(390, 844);

DateTime _day(int daysAgo) {
  final now = DateTime.now();
  final day = now.subtract(Duration(days: daysAgo));
  return DateTime(day.year, day.month, day.day);
}

/// Production layer over fresh mocks (same shape as the Day 36
/// `_Harness` in week7_day04_test.dart — private there, so copied).
class _Harness {
  _Harness()
    : inventoryRepo = MockInventoryRepository(),
      branchRepo = MockBranchRepository(),
      audit = InMemoryAuditLogWriter() {
    layer = _buildLayer();
  }

  final MockInventoryRepository inventoryRepo;
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
      branchRepo: branchRepo,
      audit: audit,
      syncQueue: SyncQueue(InMemorySyncStore()),
      engine: InventoryEngine(organizationId: _org, audit: audit),
    );
  }
}

/// Production layer whose sale + order repos are the Firestore
/// implementations over the Day 34 fake transport (D172) — same
/// shape as the `_FirestoreHarness` in week7_day04/05 (private
/// there, so copied).
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

Future<void> _deactivate(_Harness h, String branchId) async {
  final branch = await h.branchRepo.getById(branchId);
  await h.branchRepo.updateBranch(branch!.copyWith(active: false));
}

/// The seeded MedServe open payable (D92): Rs 48,250 outstanding
/// on `sled-2`. Returns allocations for a payment of [amountMinor].
Future<List<PaymentAllocation>> _medServeAllocations(
  ProductionDataLayer layer,
  int amountMinor,
) async {
  final ledger = await layer.supplierRepo.getLedgerEntries('sup-medserve');
  final open = openPayableBalances(supplierLedgerSignedEntries(ledger));
  return allocateSupplierPayment(open: open, paymentMinor: amountMinor);
}

Future<ProfitLoss> _plFromRepos(ProductionDataLayer layer) async {
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
    days: 30,
  );
}

Future<({int incomeMinor, int expenseMinor})> _cashbookSums(
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
    final day = DateTime(entry.date.year, entry.date.month, entry.date.day);
    if (day.isBefore(start) || day.isAfter(today)) continue;
    if (entry.kind == CashbookEntryKind.income) {
      income += entry.amountMinor;
    } else {
      expense += entry.amountMinor;
    }
  }
  return (incomeMinor: income, expenseMinor: expense);
}

Future<int> _todaySalesTotal(ProductionDataLayer layer) async {
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

Sale _sale({
  required int totalMinor,
  required List<SalePayment> payments,
  required int cashReceivedMinor,
  required String idempotencyKey,
  required DateTime createdAt,
}) {
  return Sale(
    id: '',
    invoiceNumber: '',
    branchId: _dha,
    cashierName: 'Test Cashier',
    items: const [],
    subtotalMinor: totalMinor,
    totalMinor: totalMinor,
    paymentMethod: SalePaymentMethod.cash,
    payments: payments,
    cashReceivedMinor: cashReceivedMinor,
    idempotencyKey: idempotencyKey,
    createdAt: createdAt,
  );
}

/// The D170 corrected-trap shape (copied, not imported): counts
/// DISTINCT RenderFlex overflow messages as the handler sees them.
/// Every sweep figure in this file states its trap: this one.
class _D42OverflowTrap {
  _D42OverflowTrap() : _previous = FlutterError.onError {
    FlutterError.onError = (details) {
      _seen.add(details.toString());
      _previous?.call(details);
    };
  }

  final dynamic _previous;
  final _seen = <String>[];

  int get overflowCount {
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

/// The 47 shell routes (Day 27 / Day 32 / Day 36 count, asserted):
/// route + text only that screen shows. Copied from
/// week8_day02_test.dart (private there) for the Day 42 re-run.
Future<List<(String, String)>> _walkRoutes(
  ProviderContainer container,
) async {
  final orders = await container.read(orderRepositoryProvider).getOrders();
  final orderId = orders.first.id;
  final customer = await container
      .read(customerRepositoryProvider)
      .getById('cust-1');
  final supplier = await container
      .read(supplierRepositoryProvider)
      .getById('sup-sami');
  return [
    ('/dashboard', 'Branch comparison'),
    ('/profile', 'Profile'),
    ('/orders', 'newest first'),
    ('/orders/new', 'New Order'),
    ('/orders/$orderId/edit', 'Edit order $orderId'),
    ('/orders/$orderId', 'Status timeline'),
    ('/medicines', 'Panadol Extra'),
    ('/medicines/med-panadol-extra', 'Batches —'),
    ('/inventory', 'expiring ≤ 30 days'),
    ('/inventory/transfers', 'Stock Transfers'),
    ('/inventory/transfers/new', 'New Transfer'),
    ('/inventory/transfers/tr-demo-1', 'TR-DHA-GLB-1001'),
    ('/inventory/adjustments', 'Adjustment Approvals'),
    ('/inventory/quarantine-outcomes', 'Quarantine Outcomes'),
    ('/riders', 'Riders & Delivery'),
    ('/riders/rider-1', 'Bilal Ahmed'),
    ('/billing', 'Add medicines'),
    ('/billing/history', 'Sales history'),
    ('/billing/returns', 'Returns & refunds'),
    ('/billing/returns/new', 'New return'),
    ('/billing/receipt/sale-missing', 'Sale not found'),
    ('/customers', 'Directory, purchase history and khata'),
    ('/customers/cust-1', customer!.name),
    ('/suppliers', 'Profiles, contacts, purchase history'),
    ('/suppliers/sup-sami', supplier!.name),
    ('/purchases', 'Purchase orders, goods receiving'),
    ('/purchases/new', 'New purchase order'),
    ('/purchases/auto', 'Auto Purchase List'),
    ('/purchases/po-dha-1001', 'PO-DHA-1001'),
    ('/prescriptions', 'New prescription'),
    ('/prescriptions/rx-dha-1', 'rx-dha-1'),
    ('/reports', 'Daily sales'),
    ('/finance', 'Finance'),
    ('/finance/cashbook', 'Cashbook'),
    ('/finance/aging', 'Payables & Receivables'),
    ('/finance/statements', 'P&L & Statements'),
    ('/finance/franchise', 'Franchise Royalties'),
    ('/staff', 'Staff directory'),
    ('/staff/attendance', 'Attendance —'),
    ('/staff/shifts', 'Shifts —'),
    ('/staff/salary', 'Monthly total'),
    ('/notifications', 'Alerts computed from live demo data'),
    ('/settings', 'Roles & Permissions'),
    ('/branches', 'Add branch'),
    ('/branches/branch-dha-main', 'Franchise settings'),
    ('/audit-log', 'No audit entries match these filters.'),
    ('/backup', 'Backup status'),
  ];
}

Future<List<(String, String)>> _walkRoutesPhone(
  ProviderContainer container,
) async {
  final routes = await _walkRoutes(container);
  return [
    for (final (route, marker) in routes)
      if (route == '/dashboard')
        (route, 'Owner dashboard')
      else
        (route, marker),
  ];
}

void main() {
  group('D180 — finance agreement, final pass', () {
    test('correction chain: a corrected yesterday flows into today\'s '
        'opening, closing balance and expected drawer', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(authProvider.notifier).signInAsDemo(
        DemoRole.owner,
      );
      // Yesterday: Rs 250 in, Rs 100 out (seeded DHA expenses are
      // daysAgo 28/26/12/6/3 and seeded transactions are expense
      // mirrors only, so yesterday is clean — absolute figures).
      await container.read(expensesProvider.notifier).recordExpense(
        branchId: _dha,
        category: 'Supplies',
        amountMinor: 10000,
        description: 'Yesterday supplies (agreement 4)',
        expenseDate: _day(1),
      );
      await container
          .read(financialTransactionsProvider.notifier)
          .recordIncome(
            branchId: _dha,
            category: 'Other income',
            amountMinor: 25000,
            date: _day(1),
          );
      final closed = await container
          .read(dailyClosingsProvider.notifier)
          .closeDay(branchId: _dha, date: _day(1));
      expect(closed.error, isNull, reason: closed.error);
      final original = closed.closing!;
      expect(original.totalIncomeMinor, 25000);
      expect(original.totalExpenseMinor, 10000);
      expect(original.openingBalanceMinor, 0);
      expect(original.closingBalanceMinor, 15000);
      // Correct yesterday: income was Rs 300, not Rs 250.
      final corrected = await container
          .read(closingCorrectionsProvider.notifier)
          .correctClosing(
            original: original,
            correctedIncomeMinor: 30000,
            correctedExpenseMinor: 10000,
            reason: 'Income was Rs 300, not Rs 250 (agreement 4)',
          );
      expect(corrected.error, isNull, reason: corrected.error);
      final adjusted = adjustedClosingTotals(
        original: original,
        corrections: [corrected.correction!],
      );
      expect(adjusted.corrected, isTrue);
      expect(adjusted.incomeMinor, 30000);
      expect(adjusted.closingBalanceMinor, 20000);
      // The original record is untouched — the correction is a
      // read-side re-statement, not an edit.
      expect(original.totalIncomeMinor, 25000);
      expect(original.closingBalanceMinor, 15000);
      // Close today with no new entries: the opening MUST be the
      // corrected Rs 200, not the original Rs 150 — the closing
      // "stands at" its corrected totals (D156), and the opening
      // is the previous closing's closing balance.
      final todayClosed = await container
          .read(dailyClosingsProvider.notifier)
          .closeDay(branchId: _dha, date: _day(0));
      expect(todayClosed.error, isNull, reason: todayClosed.error);
      expect(todayClosed.closing!.openingBalanceMinor, 20000);
      expect(todayClosed.closing!.totalIncomeMinor, 0);
      expect(todayClosed.closing!.totalExpenseMinor, 0);
      expect(todayClosed.closing!.closingBalanceMinor, 20000);
      // The reconciliation for today opens from the corrected
      // balance too.
      final reconciled = await container
          .read(cashReconciliationsProvider.notifier)
          .reconcileDay(
            branchId: _dha,
            date: _day(0),
            countedMinor: 20000,
          );
      expect(reconciled.error, isNull, reason: reconciled.error);
      expect(reconciled.reconciliation!.expectedMinor, 20000);
      expect(reconciled.reconciliation!.differenceMinor, 0);
    });

    test('reconciliation expected drawer: a split sale counts its cash '
        'leg only; a supplier payment moves nothing (D157 scope)',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(authProvider.notifier).signInAsDemo(
        DemoRole.owner,
      );
      final layer = container.read(productionDataLayerProvider);
      final plBefore = await _plFromRepos(layer);
      // Split sale today: Rs 10,000 total — Rs 6,000 cash,
      // Rs 4,000 card. The drawer only ever sees the cash leg.
      final sale = await container
          .read(saleRepositoryProvider)
          .createSale(
            _sale(
              totalMinor: 1000000,
              payments: const [
                SalePayment(
                  method: SalePaymentMethod.cash,
                  amountMinor: 600000,
                ),
                SalePayment(
                  method: SalePaymentMethod.card,
                  amountMinor: 400000,
                ),
              ],
              cashReceivedMinor: 600000,
              idempotencyKey: 'agreement4-split-sale-1',
              createdAt: _day(0).add(const Duration(hours: 10)),
            ),
          );
      expect(sale.isSplit, isTrue);
      expect(sale.cashMinor, 600000);
      await layer.recordExpense(
        branchId: _dha,
        category: 'Supplies',
        amountMinor: 250000,
        description: 'Drawer day supplies (agreement 4)',
        expenseDate: _day(0),
        createdBy: 'test-owner',
        idempotencyKey: 'agreement4-expense-1',
      );
      await layer.recordIncome(
        branchId: _dha,
        category: 'Other income',
        amountMinor: 125000,
        date: _day(0),
        createdBy: 'test-owner',
        idempotencyKey: 'agreement4-income-1',
      );
      // Independent hand computation (not the function under test):
      // opening 0 + cash legs + income − expense.
      final sales = await layer.saleRepo.getSales(branchId: _dha);
      final cashLegs = sales
          .where(
            (s) =>
                s.createdAt != null &&
                DateTime(
                  s.createdAt!.year,
                  s.createdAt!.month,
                  s.createdAt!.day,
                ) ==
                    _day(0),
          )
          .fold(0, (sum, s) => sum + s.cashMinor);
      expect(cashLegs, 600000);
      const expected = 0 + 600000 + 125000 - 250000; // 475000
      final reconciled = await container
          .read(cashReconciliationsProvider.notifier)
          .reconcileDay(
            branchId: _dha,
            date: _day(0),
            countedMinor: expected,
          );
      expect(reconciled.error, isNull, reason: reconciled.error);
      expect(reconciled.reconciliation!.expectedMinor, expected);
      expect(reconciled.reconciliation!.differenceMinor, 0);
      // The P&L takes the FULL sale (both legs) while the drawer
      // took only the cash leg — the two views differ by design,
      // and by exactly the card leg.
      final plAfter = await _plFromRepos(layer);
      expect(plAfter.revenueMinor - plBefore.revenueMinor, 1000000);
      expect(
        plAfter.revenueMinor - plBefore.revenueMinor - cashLegs,
        400000,
      );
      // A cash supplier payment is recorded against the payable,
      // not the drawer (D157 documented scope): the expected
      // drawer does not move, and the P&L does not move either.
      await layer.recordSupplierPayment(
        supplierId: 'sup-medserve',
        branchId: _dha,
        amountMinor: 1000000,
        allocations: await _medServeAllocations(layer, 1000000),
        idempotencyKey: 'agreement4-supplier-payment-1',
      );
      final recount = await container
          .read(cashReconciliationsProvider.notifier)
          .reconcileDay(
            branchId: _dha,
            date: _day(0),
            countedMinor: expected + 100,
          );
      expect(recount.error, isNull, reason: recount.error);
      expect(recount.reconciliation!.expectedMinor, expected);
      expect(recount.reconciliation!.differenceMinor, 100);
      final plAfterPayment = await _plFromRepos(layer);
      expect(plAfterPayment.netProfitMinor, plAfter.netProfitMinor);
    });

    test('counter-advance finance agreement (D175): a restored '
        'ORD-DHA-1492 moves the P&L and the daily counter by exactly '
        'its amount, once; the next mint is 1493', () async {
      final target = await _FirestoreHarness.create();
      final plBefore = await _plFromRepos(target.layer);
      final counterBefore = await _todaySalesTotal(target.layer);
      // The restore path for orders is `upsertOrder` (its only
      // caller in lib/ is the restore); the carried number is
      // preserved (D174) and the counter advances past it (D175).
      // NOTE: the order must be internally consistent — the app
      // always builds orders with totalAmount == items − discount
      // (buildNewOrder / buildEditedOrder), and the Firestore
      // mapper stores the derived `grandTotal` (totalMinor), so a
      // hand-built order whose totalAmount disagrees with its
      // items/discount round-trips to the derived figure. The
      // first version of this test carried totalAmount 500.0 over
      // sampleOrder's 2×100 items with its Rs 5 discount (derived
      // 195.0) and measured 19500 — a test-fixture inconsistency,
      // not an app defect. The order below sums to Rs 500 with no
      // discount, so carried and derived totals agree.
      final restored = await target.layer.orderRepo.upsertOrder(
        sampleOrder(id: 'ord-dha-1492').copyWith(
          orderNumber: 'ORD-DHA-1492',
          items: const [
            OrderItem(
              medicineId: 'med-1',
              medicineName: 'Panadol',
              quantity: 5,
              unitPrice: 100.0,
            ),
          ],
          discountMinor: 0,
          totalAmount: 500.0,
          createdAt: _day(0).add(const Duration(hours: 10)),
        ),
      );
      expect(restored.orderNumber, 'ORD-DHA-1492');
      expect(restored.totalAmount, 500.0);
      final plAfter = await _plFromRepos(target.layer);
      expect(plAfter.revenueMinor - plBefore.revenueMinor, 50000);
      expect(plAfter.netProfitMinor - plBefore.netProfitMinor, 50000);
      final counterAfter = await _todaySalesTotal(target.layer);
      expect(counterAfter - counterBefore, 50000);
      // The P&L revenue and the daily counter agree exactly.
      expect(
        plAfter.revenueMinor - plBefore.revenueMinor,
        counterAfter - counterBefore,
      );
      // A re-restore (replay) moves nothing a second time.
      final replayed = await target.layer.orderRepo.upsertOrder(restored);
      expect(replayed.orderNumber, 'ORD-DHA-1492');
      final plReplay = await _plFromRepos(target.layer);
      expect(plReplay.revenueMinor, plAfter.revenueMinor);
      expect(plReplay.netProfitMinor, plAfter.netProfitMinor);
      expect(await _todaySalesTotal(target.layer), counterBefore + 50000);
      // The counter advanced past the restored number (D175).
      final next = await target.layer.orderRepo.createOrder(sampleOrder());
      expect(next.orderNumber, 'ORD-DHA-1493');
    });

    test('one day, four views: cashbook vs P&L vs supplier ledger vs '
        'closing vs reconciliation agree in integer paisa', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(authProvider.notifier).signInAsDemo(
        DemoRole.owner,
      );
      final layer = container.read(productionDataLayerProvider);
      final sumsBefore = await _cashbookSums(layer);
      final plBefore = await _plFromRepos(layer);
      final ledgerBefore = await layer.supplierRepo.getLedgerEntries(
        'sup-medserve',
      );
      expect(supplierOutstandingMinor(ledgerBefore), 4825000);
      // One day: a cash sale (Rs 10,000), an expense (Rs 7,500),
      // an income (Rs 1,250) and a supplier payment (Rs 10,000).
      await container.read(saleRepositoryProvider).createSale(
        _sale(
          totalMinor: 1000000,
          payments: const [
            SalePayment(
              method: SalePaymentMethod.cash,
              amountMinor: 1000000,
            ),
          ],
          cashReceivedMinor: 1000000,
          idempotencyKey: 'agreement4-day-sale-1',
          createdAt: _day(0).add(const Duration(hours: 10)),
        ),
      );
      await layer.recordExpense(
        branchId: _dha,
        category: 'Supplies',
        amountMinor: 750000,
        description: 'Full-day supplies (agreement 4)',
        expenseDate: _day(0),
        createdBy: 'test-owner',
        idempotencyKey: 'agreement4-day-expense-1',
      );
      await layer.recordIncome(
        branchId: _dha,
        category: 'Other income',
        amountMinor: 125000,
        date: _day(0),
        createdBy: 'test-owner',
        idempotencyKey: 'agreement4-day-income-1',
      );
      await layer.recordSupplierPayment(
        supplierId: 'sup-medserve',
        branchId: _dha,
        amountMinor: 1000000,
        allocations: await _medServeAllocations(layer, 1000000),
        idempotencyKey: 'agreement4-day-payment-1',
      );
      // Cashbook: income +125000, expense +750000. The sale and
      // the supplier payment are NOT cashbook entries.
      final sums = await _cashbookSums(layer);
      expect(sums.incomeMinor - sumsBefore.incomeMinor, 125000);
      expect(sums.expenseMinor - sumsBefore.expenseMinor, 750000);
      // P&L: revenue +1000000 (sale), other income +125000,
      // expenses +750000, net +375000. Its income/expense legs
      // equal the cashbook sums exactly.
      final pl = await _plFromRepos(layer);
      expect(pl.revenueMinor - plBefore.revenueMinor, 1000000);
      expect(pl.otherIncomeMinor - plBefore.otherIncomeMinor, 125000);
      expect(pl.expensesMinor - plBefore.expensesMinor, 750000);
      expect(pl.netProfitMinor - plBefore.netProfitMinor, 375000);
      expect(pl.otherIncomeMinor, sums.incomeMinor);
      expect(pl.expensesMinor, sums.expenseMinor);
      expect(
        pl.netProfitMinor,
        pl.grossProfitMinor + pl.otherIncomeMinor - pl.expensesMinor,
      );
      // Supplier ledger: aging == ledger sum == stored running
      // balance, after exactly the payment.
      final ledger = await layer.supplierRepo.getLedgerEntries(
        'sup-medserve',
      );
      expect(supplierOutstandingMinor(ledger), 3825000);
      expect(
        computeAging(
          entries: supplierLedgerSignedEntries(ledger),
          now: DateTime.now(),
        ).totalMinor,
        3825000,
      );
      expect(ledger.last.balanceAfterMinor, 3825000);
      expect(ledger.last.amountMinor, -1000000);
      // Closing: income 125000, expense 750000, opening 0,
      // closing −625000 (opening + income − expense).
      final closed = await container
          .read(dailyClosingsProvider.notifier)
          .closeDay(branchId: _dha, date: _day(0));
      expect(closed.error, isNull, reason: closed.error);
      expect(closed.closing!.totalIncomeMinor, 125000);
      expect(closed.closing!.totalExpenseMinor, 750000);
      expect(closed.closing!.openingBalanceMinor, 0);
      expect(closed.closing!.closingBalanceMinor, -625000);
      // Reconciliation: expected = 0 + 1000000 + 125000 − 750000.
      final reconciled = await container
          .read(cashReconciliationsProvider.notifier)
          .reconcileDay(
            branchId: _dha,
            date: _day(0),
            countedMinor: 375000,
          );
      expect(reconciled.error, isNull, reason: reconciled.error);
      expect(reconciled.reconciliation!.expectedMinor, 375000);
      expect(reconciled.reconciliation!.differenceMinor, 0);
    });

    test('a refused close / reconciliation on a deactivated branch '
        'leaves every figure exactly unchanged', () async {
      final h = _Harness();
      final sumsBefore = await _cashbookSums(h.layer);
      final plBefore = await _plFromRepos(h.layer);
      await _deactivate(h, _dha);
      await expectLater(
        h.layer.recordDailyClosing(
          closing: DailyClosing(
            id: '',
            branchId: _dha,
            date: _day(0),
            totalIncomeMinor: 0,
            totalExpenseMinor: 0,
            openingBalanceMinor: 0,
            closingBalanceMinor: 0,
          ),
          idempotencyKey: 'agreement4-refused-closing-1',
        ),
        throwsArgumentError,
      );
      await expectLater(
        h.layer.recordCashReconciliation(
          reconciliation: CashReconciliation(
            id: '',
            branchId: _dha,
            date: _day(0),
            expectedMinor: 0,
            countedMinor: 0,
            differenceMinor: 0,
          ),
          idempotencyKey: 'agreement4-refused-recon-1',
        ),
        throwsArgumentError,
      );
      final sumsAfter = await _cashbookSums(h.layer);
      final plAfter = await _plFromRepos(h.layer);
      expect(sumsAfter.incomeMinor, sumsBefore.incomeMinor);
      expect(sumsAfter.expenseMinor, sumsBefore.expenseMinor);
      expect(plAfter.netProfitMinor, plBefore.netProfitMinor);
      expect(
        await h.layer.dailyClosingRepo.getClosings(branchId: _dha),
        isEmpty,
      );
      expect(
        await h.layer.cashReconciliationRepo.getReconciliations(
          branchId: _dha,
        ),
        isEmpty,
      );
    });
  });

  group('D180 — offline queue + role gates: Week 8 flows', () {
    test('Day 38 criterion-6 flow enqueues exactly one sync op, '
        'drains once, and a same-key retry enqueues nothing', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(authProvider.notifier).signInAsDemo(
        DemoRole.owner,
      );
      final layer = container.read(productionDataLayerProvider);
      final before = await layer.pendingSyncCount();
      final queue = container.read(orderQueueProvider.notifier);
      final medicine = await container
          .read(medicineRepositoryProvider)
          .getById('med-panadol-extra');
      expect(medicine, isNotNull);
      final order = Order(
        id: '',
        customerId: 'cust-1',
        branchId: _dha,
        items: [
          OrderItem(
            medicineId: medicine!.id,
            medicineName: medicine.name,
            quantity: 2,
            unitPrice: medicine.priceMinor / 100,
          ),
        ],
        deliveryAddress: 'House 12, Street 4, DHA Lahore',
        source: OrderSource.whatsapp,
        fulfillment: FulfillmentType.delivery,
        totalAmount: 2 * medicine.priceMinor / 100,
        status: OrderStatus.newOrder,
      );
      final created = await queue.createOrder(
        order,
        idempotencyKey: 'd180-whatsapp-order-1',
      );
      expect(created.id, isNotEmpty);
      expect(created.source, OrderSource.whatsapp);
      expect(await layer.pendingSyncCount(), before + 1);
      final drained = await layer.processSyncQueue((_) async => true);
      expect(drained, 1);
      expect(await layer.pendingSyncCount(), before);
      // A same-key retry returns the original and enqueues nothing.
      final retry = await queue.createOrder(
        order,
        idempotencyKey: 'd180-whatsapp-order-1',
      );
      expect(retry.id, created.id);
      expect(await layer.pendingSyncCount(), before);
    });

    testWidgets('prescription Approve is pharmacist-only: the Owner '
        'cannot approve, the pharmacist can', (tester) async {
      final (_, ownerRouter) = await pumpRouterAppAsRole(tester, 'owner');
      ownerRouter.go('/prescriptions/rx-dha-1');
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Approve'));
      await tester.pumpAndSettle();
      // Tapping as Owner changes nothing: no snackbar, Approve
      // stays (the button is disabled for the Owner — D70 gate).
      await tester.tap(find.text('Approve'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        find.textContaining('approved — linked orders can now be dispatched'),
        findsNothing,
      );
      await tester.pumpAndSettle();
      expect(find.text('Approve'), findsOneWidget);
    });

    testWidgets('prescription Approve approves as pharmacist (final '
        'tree re-pin of the Day 39 walk check)', (tester) async {
      final (_, router) = await pumpRouterAppAsRole(tester, 'pharmacist');
      router.go('/prescriptions/rx-dha-1');
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Approve'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Approve'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        find.textContaining('approved — linked orders can now be dispatched'),
        findsOneWidget,
      );
      await tester.pumpAndSettle();
      expect(find.text('Approve'), findsNothing);
    });
  });

  group('D180 — 390px sweep + 47-route walk re-run (corrected trap)',
      () {
    testWidgets('all 47 routes resolve at desktop (1920x1080) with '
        'their markers', (tester) async {
      final (container, router) = await pumpRouterAppAsRole(
        tester,
        'owner',
        size: _desktopSize,
      );
      final routes = await _walkRoutes(container);
      expect(routes, hasLength(47));
      for (final (route, marker) in routes) {
        router.go(route);
        await tester.pumpAndSettle();
        expect(
          find.textContaining(marker),
          findsWidgets,
          reason: 'Missing marker "$marker" on $route at desktop',
        );
        expect(
          find.text('Page not found'),
          findsNothing,
          reason: 'Missing route $route at desktop',
        );
        expect(
          find.textContaining('coming Week 1'),
          findsNothing,
          reason: 'Placeholder left on $route at desktop',
        );
      }
    });

    testWidgets('all 47 routes: 0 distinct overflows at 390px '
        '(corrected trap)', (tester) async {
      final trap = _D42OverflowTrap();
      addTearDown(trap.dispose);
      final (container, router) = await pumpRouterAppAsRole(
        tester,
        'owner',
        size: _phoneSize,
      );
      final routes = await _walkRoutesPhone(container);
      expect(routes, hasLength(47));
      for (final (route, _) in routes) {
        router.go(route);
        await tester.pumpAndSettle();
        expect(
          find.text('Page not found'),
          findsNothing,
          reason: 'Missing route $route at 390px',
        );
        expect(
          find.textContaining('coming Week 1'),
          findsNothing,
          reason: 'Placeholder left on $route at 390px',
        );
      }
      expect(
        trap.overflowCount,
        0,
        reason: 'distinct RenderFlex overflows at 390px (corrected trap)',
      );
    });
  });
}
