// Week 6 Day 1 tests — FR-HO-08 deactivation guard on finance writes (D161).
//
// - D161 (closes the D149 boundary follow-up): the production data
//   layer refuses every finance write on a deactivated branch —
//   `recordExpense` / `recordIncome` / `recordSupplierPayment` /
//   `recordDailyClosing` / `recordClosingCorrection` /
//   `recordCashReconciliation` — with the same `ArgumentError` the
//   ten stock/sale paths already throw (D149), in the same position
//   (after the idempotency-duplicate early return, before the first
//   write), and unknown branch ids are still NOT refused.
// - The six finance notifiers catch that error and return it as an
//   error string (they previously had no `on ArgumentError` handler,
//   so the refusal would have escaped as an uncaught exception).
//   The dialogs/screens already render `result.error` (cashbook
//   entry dialog + close-day / correction dialogs via PharmaErrorBox,
//   reconciliation + supplier-payment dialog the same way), so the
//   refusal is visible to the user instead of a silent no-op.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:pharmadesk/core/data/audit_log.dart';
import 'package:pharmadesk/core/data/auth_repository.dart';
import 'package:pharmadesk/core/data/firestore_schema.dart';
import 'package:pharmadesk/core/data/inventory_engine.dart';
import 'package:pharmadesk/core/data/production_data_layer.dart';
import 'package:pharmadesk/core/data/sync_queue.dart';
import 'package:pharmadesk/core/routing/app_router.dart';
import 'package:pharmadesk/core/services/repositories.dart';
import 'package:pharmadesk/core/theme/app_theme.dart';
import 'package:pharmadesk/core/theme/white_label.dart';
import 'package:pharmadesk/features/authentication/auth_state.dart';
import 'package:pharmadesk/features/finance/finance_logic.dart';
import 'package:pharmadesk/features/finance/finance_provider.dart';
import 'package:pharmadesk/features/suppliers/supplier_logic.dart';
import 'package:pharmadesk/models/cash_reconciliation.dart';
import 'package:pharmadesk/models/closing_correction.dart';
import 'package:pharmadesk/models/daily_closing.dart';
import 'package:pharmadesk/models/financial_transaction.dart';
import 'package:pharmadesk/models/supplier_payment.dart';

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

/// Production layer over fresh mocks, with the branch repo exposed
/// so tests can deactivate a branch and watch the guard refuse
/// (same helper shape as the Week 5 Day 2 harness).
class _Harness {
  _Harness()
    : branchRepo = MockBranchRepository(),
      audit = InMemoryAuditLogWriter() {
    layer = ProductionDataLayer(
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
      branchRepo: branchRepo,
      audit: audit,
      syncQueue: SyncQueue(InMemorySyncStore()),
      engine: InventoryEngine(organizationId: _org, audit: audit),
    );
  }

  final MockBranchRepository branchRepo;
  final InMemoryAuditLogWriter audit;
  late final ProductionDataLayer layer;
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

DailyClosing _closing({String id = 'dc-1'}) {
  return DailyClosing(
    id: id,
    branchId: _dha,
    date: _day(0),
    totalIncomeMinor: 250000,
    totalExpenseMinor: 100000,
    openingBalanceMinor: 0,
    closingBalanceMinor: 150000,
    closedBy: 'test-owner',
    closedAt: DateTime.now(),
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

/// Pumps the real router app as [roleKey] (same helper shape as the
/// Week 5 Day 4 widget tests).
Future<(ProviderContainer, GoRouter)> _pumpRouterAppAsRole(
  WidgetTester tester,
  String roleKey, {
  Size size = const Size(1920, 1080),
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final container = ProviderContainer(
    overrides: [
      authProvider.overrideWith(
        () => _FixedAuthNotifier(_userFor(roleKey)),
      ),
    ],
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

void main() {
  group('D161 — layer: finance writes refused on a deactivated branch', () {
    test('recordExpense refused; no expense, no mirror transaction',
        () async {
      final h = _Harness();
      final beforeExpenses =
          (await h.layer.expenseRepo.getExpenses(branchId: _dha)).length;
      final beforeTxns =
          (await h.layer.financialTransactionRepo.getTransactions(
            branchId: _dha,
          )).length;
      await _deactivate(h, _dha);
      await expectLater(
        h.layer.recordExpense(
          branchId: _dha,
          category: 'Supplies',
          amountMinor: 50000,
          description: 'Deactivated-branch expense',
          expenseDate: _day(0),
          idempotencyKey: 'expense-d161-1',
        ),
        throwsArgumentError,
      );
      expect(
        (await h.layer.expenseRepo.getExpenses(branchId: _dha)).length,
        beforeExpenses,
      );
      expect(
        (await h.layer.financialTransactionRepo.getTransactions(
          branchId: _dha,
        )).length,
        beforeTxns,
      );
      // The refusal names the branch and the rule.
      try {
        await h.layer.recordExpense(
          branchId: _dha,
          category: 'Supplies',
          amountMinor: 50000,
          expenseDate: _day(0),
          idempotencyKey: 'expense-d161-1b',
        );
        fail('expected ArgumentError');
      } on ArgumentError catch (error) {
        expect(error.message, contains('deactivated'));
        expect(error.message, contains('FR-HO-08'));
      }
    });

    test('recordIncome refused; no transaction written', () async {
      final h = _Harness();
      final before =
          (await h.layer.financialTransactionRepo.getTransactions(
            branchId: _dha,
          )).length;
      await _deactivate(h, _dha);
      await expectLater(
        h.layer.recordIncome(
          branchId: _dha,
          category: 'Other income',
          amountMinor: 25000,
          date: _day(0),
          idempotencyKey: 'income-d161-1',
        ),
        throwsArgumentError,
      );
      expect(
        (await h.layer.financialTransactionRepo.getTransactions(
          branchId: _dha,
        )).length,
        before,
      );
    });

    test(
        'recordSupplierPayment refused; no payment, ledger or '
        'transaction — outstanding unchanged', () async {
      final h = _Harness();
      final beforePayments =
          (await h.layer.supplierPaymentRepo.getPayments()).length;
      final beforeOutstanding = supplierOutstandingMinor(
        await h.layer.supplierRepo.getLedgerEntries('sup-medserve'),
      );
      expect(beforeOutstanding, 4825000);
      await _deactivate(h, _dha);
      await expectLater(
        h.layer.recordSupplierPayment(
          supplierId: 'sup-medserve',
          branchId: _dha,
          amountMinor: 100000,
          method: SupplierPaymentMethod.cash,
          allocations: await _medServeAllocations(h, 100000),
          idempotencyKey: 'spay-d161-1',
        ),
        throwsArgumentError,
      );
      expect(
        (await h.layer.supplierPaymentRepo.getPayments()).length,
        beforePayments,
      );
      expect(
        supplierOutstandingMinor(
          await h.layer.supplierRepo.getLedgerEntries('sup-medserve'),
        ),
        beforeOutstanding,
      );
      expect(
        (await h.layer.financialTransactionRepo.getTransactions(
          branchId: _dha,
        )).where(
          (txn) => txn.type == FinancialTransactionType.supplierPayment,
        ),
        isEmpty,
      );
    });

    test('recordDailyClosing refused; no closing written', () async {
      final h = _Harness();
      final before =
          (await h.layer.dailyClosingRepo.getClosings(branchId: _dha)).length;
      await _deactivate(h, _dha);
      await expectLater(
        h.layer.recordDailyClosing(
          closing: _closing(),
          idempotencyKey: 'closing-d161-1',
        ),
        throwsArgumentError,
      );
      expect(
        (await h.layer.dailyClosingRepo.getClosings(branchId: _dha)).length,
        before,
      );
    });

    test('recordClosingCorrection refused; no correction, no audit',
        () async {
      final h = _Harness();
      final before =
          (await h.layer.closingCorrectionRepo.getCorrections(
            branchId: _dha,
          )).length;
      await _deactivate(h, _dha);
      await expectLater(
        h.layer.recordClosingCorrection(
          correction: _correction(),
          idempotencyKey: 'correction-d161-1',
        ),
        throwsArgumentError,
      );
      expect(
        (await h.layer.closingCorrectionRepo.getCorrections(
          branchId: _dha,
        )).length,
        before,
      );
      expect(
        await h.audit.entries(
          entityType: 'dailyClosing',
          entityId: 'dc-1',
          action: 'closing.corrected',
        ),
        isEmpty,
      );
    });

    test('recordCashReconciliation refused; no reconciliation, no audit',
        () async {
      final h = _Harness();
      final before =
          (await h.layer.cashReconciliationRepo.getReconciliations(
            branchId: _dha,
          )).length;
      await _deactivate(h, _dha);
      await expectLater(
        h.layer.recordCashReconciliation(
          reconciliation: _reconciliation(),
          idempotencyKey: 'recon-d161-1',
        ),
        throwsArgumentError,
      );
      expect(
        (await h.layer.cashReconciliationRepo.getReconciliations(
          branchId: _dha,
        )).length,
        before,
      );
      expect(
        await h.audit.entries(action: 'cash.reconciled'),
        isEmpty,
      );
    });

    test('a duplicate expense retry after deactivation still returns '
        'the original', () async {
      final h = _Harness();
      final beforeExpenses =
          (await h.layer.expenseRepo.getExpenses(branchId: _dha)).length;
      final beforeTxns =
          (await h.layer.financialTransactionRepo.getTransactions(
            branchId: _dha,
          )).length;
      final first = await h.layer.recordExpense(
        branchId: _dha,
        category: 'Supplies',
        amountMinor: 50000,
        description: 'Before deactivation',
        expenseDate: _day(0),
        idempotencyKey: 'expense-d161-dupe',
      );
      await _deactivate(h, _dha);
      // The guard sits after the idempotency check: a retried key is
      // not a new write, so it returns the original instead of an error.
      final retry = await h.layer.recordExpense(
        branchId: _dha,
        category: 'Supplies',
        amountMinor: 50000,
        description: 'Before deactivation',
        expenseDate: _day(0),
        idempotencyKey: 'expense-d161-dupe',
      );
      expect(retry.id, first.id);
      expect(
        (await h.layer.expenseRepo.getExpenses(branchId: _dha)).length,
        beforeExpenses + 1,
      );
      expect(
        (await h.layer.financialTransactionRepo.getTransactions(
          branchId: _dha,
        )).length,
        beforeTxns + 1,
      );
    });

    test('a duplicate supplier-payment retry after deactivation still '
        'returns the original — no double money move', () async {
      final h = _Harness();
      final first = await h.layer.recordSupplierPayment(
        supplierId: 'sup-medserve',
        branchId: _dha,
        amountMinor: 4825000,
        method: SupplierPaymentMethod.bankTransfer,
        reference: 'TXN-D161',
        allocations: await _medServeAllocations(h, 4825000),
        idempotencyKey: 'spay-d161-dupe',
      );
      expect(first.isDuplicate, isFalse);
      expect(
        supplierOutstandingMinor(
          await h.layer.supplierRepo.getLedgerEntries('sup-medserve'),
        ),
        0,
      );
      await _deactivate(h, _dha);
      final retry = await h.layer.recordSupplierPayment(
        supplierId: 'sup-medserve',
        branchId: _dha,
        amountMinor: 4825000,
        method: SupplierPaymentMethod.bankTransfer,
        reference: 'TXN-D161',
        allocations: await _medServeAllocations(h, 4825000),
        idempotencyKey: 'spay-d161-dupe',
      );
      expect(retry.isDuplicate, isTrue);
      expect(retry.payment.id, first.payment.id);
      expect(
        (await h.layer.supplierPaymentRepo.getPayments()).length,
        1,
      );
      // Still settled in full — the retry moved no money.
      expect(
        supplierOutstandingMinor(
          await h.layer.supplierRepo.getLedgerEntries('sup-medserve'),
        ),
        0,
      );
    });

    test('unknown branch ids are NOT refused (D149 posture)', () async {
      final h = _Harness();
      final created = await h.layer.recordExpense(
        branchId: 'branch-never-in-directory',
        category: 'Supplies',
        amountMinor: 10000,
        expenseDate: _day(0),
        idempotencyKey: 'expense-d161-unknown',
      );
      expect(created.branchId, 'branch-never-in-directory');
      final income = await h.layer.recordIncome(
        branchId: 'branch-never-in-directory',
        category: 'Other income',
        amountMinor: 20000,
        date: _day(0),
        idempotencyKey: 'income-d161-unknown',
      );
      expect(income.branchId, 'branch-never-in-directory');
    });

    test('reactivating the branch lets finance writes through again',
        () async {
      final h = _Harness();
      await _deactivate(h, _dha);
      await expectLater(
        h.layer.recordIncome(
          branchId: _dha,
          category: 'Other income',
          amountMinor: 10000,
          date: _day(0),
          idempotencyKey: 'income-d161-react',
        ),
        throwsArgumentError,
      );
      await _reactivate(h, _dha);
      final created = await h.layer.recordIncome(
        branchId: _dha,
        category: 'Other income',
        amountMinor: 10000,
        date: _day(0),
        idempotencyKey: 'income-d161-react',
      );
      expect(created.amountMinor, 10000);
    });
  });

  group('D161 — notifiers return the refusal as an error string', () {
    test('recordExpense returns the deactivation error, writes nothing',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final branchRepo = container.read(branchRepositoryProvider);
      final branch = await branchRepo.getById(_dha);
      await branchRepo.updateBranch(branch!.copyWith(active: false));
      final before =
          (await container
                  .read(expenseRepositoryProvider)
                  .getExpenses(branchId: _dha))
              .length;
      final result = await container
          .read(expensesProvider.notifier)
          .recordExpense(
            branchId: _dha,
            category: 'Supplies',
            amountMinor: 50000,
            description: 'Deactivated-branch expense',
            expenseDate: _day(0),
          );
      expect(result.expense, isNull);
      expect(result.error, contains('deactivated'));
      expect(result.error, contains('FR-HO-08'));
      expect(
        (await container
                .read(expenseRepositoryProvider)
                .getExpenses(branchId: _dha))
            .length,
        before,
      );
    });

    test('recordIncome returns the deactivation error, writes nothing',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final branchRepo = container.read(branchRepositoryProvider);
      final branch = await branchRepo.getById(_dha);
      await branchRepo.updateBranch(branch!.copyWith(active: false));
      final before =
          (await container
                  .read(financialTransactionRepositoryProvider)
                  .getTransactions(branchId: _dha))
              .length;
      final result = await container
          .read(financialTransactionsProvider.notifier)
          .recordIncome(
            branchId: _dha,
            category: 'Other income',
            amountMinor: 25000,
            date: _day(0),
          );
      expect(result.transaction, isNull);
      expect(result.error, contains('deactivated'));
      expect(
        (await container
                .read(financialTransactionRepositoryProvider)
                .getTransactions(branchId: _dha))
            .length,
        before,
      );
    });

    test('recordPayment returns the deactivation error, pays nothing',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final branchRepo = container.read(branchRepositoryProvider);
      final branch = await branchRepo.getById(_dha);
      await branchRepo.updateBranch(branch!.copyWith(active: false));
      final result = await container
          .read(supplierPaymentsProvider.notifier)
          .recordPayment(
            supplierId: 'sup-medserve',
            branchId: _dha,
            amountMinor: 100000,
            method: SupplierPaymentMethod.cash,
          );
      expect(result.payment, isNull);
      expect(result.error, contains('deactivated'));
      expect(
        await container.read(supplierPaymentRepositoryProvider).getPayments(),
        isEmpty,
      );
      expect(
        supplierOutstandingMinor(
          await container
              .read(supplierRepositoryProvider)
              .getLedgerEntries('sup-medserve'),
        ),
        4825000,
      );
    });

    test('closeDay returns the deactivation error, closes nothing',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final branchRepo = container.read(branchRepositoryProvider);
      final branch = await branchRepo.getById(_dha);
      await branchRepo.updateBranch(branch!.copyWith(active: false));
      final result = await container
          .read(dailyClosingsProvider.notifier)
          .closeDay(branchId: _dha, date: _day(0));
      expect(result.closing, isNull);
      expect(result.error, contains('deactivated'));
      expect(
        await container
            .read(dailyClosingRepositoryProvider)
            .getClosings(branchId: _dha),
        isEmpty,
      );
    });

    test('correctClosing returns the deactivation error', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final branchRepo = container.read(branchRepositoryProvider);
      final branch = await branchRepo.getById(_dha);
      await branchRepo.updateBranch(branch!.copyWith(active: false));
      final result = await container
          .read(closingCorrectionsProvider.notifier)
          .correctClosing(
            original: _closing(),
            correctedIncomeMinor: 200000,
            correctedExpenseMinor: 100000,
            reason: 'Income entered twice',
          );
      expect(result.correction, isNull);
      expect(result.error, contains('deactivated'));
      expect(
        await container
            .read(closingCorrectionRepositoryProvider)
            .getCorrections(branchId: _dha),
        isEmpty,
      );
    });

    test('reconcileDay returns the deactivation error', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final branchRepo = container.read(branchRepositoryProvider);
      final branch = await branchRepo.getById(_dha);
      await branchRepo.updateBranch(branch!.copyWith(active: false));
      final result = await container
          .read(cashReconciliationsProvider.notifier)
          .reconcileDay(
            branchId: _dha,
            date: _day(0),
            countedMinor: 50000,
          );
      expect(result.reconciliation, isNull);
      expect(result.error, contains('deactivated'));
      expect(
        await container
            .read(cashReconciliationRepositoryProvider)
            .getReconciliations(branchId: _dha),
        isEmpty,
      );
    });
  });

  group('D161 — UI surfaces the refusal (390px)', () {
    testWidgets('cashbook entry dialog shows the deactivation refusal '
        'and stays open', (tester) async {
      final (container, router) = await _pumpRouterAppAsRole(
        tester,
        'owner',
        size: _phoneSize,
      );
      router.go('/finance/cashbook');
      await tester.pumpAndSettle();
      expect(find.text('Cashbook'), findsOneWidget);
      final beforeExpenses =
          (await container
                  .read(expenseRepositoryProvider)
                  .getExpenses(branchId: _dha))
              .length;
      // Deactivate the active branch, then try to record an expense.
      final branchRepo = container.read(branchRepositoryProvider);
      final branch = await branchRepo.getById(_dha);
      await branchRepo.updateBranch(branch!.copyWith(active: false));
      await tester.tap(find.text('Add entry'));
      await tester.pumpAndSettle();
      expect(find.text('Add cashbook entry'), findsOneWidget);
      final amountField = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );
      await tester.enterText(amountField.first, '500');
      await tester.tap(find.text('Save entry'));
      await tester.pumpAndSettle();
      // The refusal is shown in the dialog (PharmaErrorBox) and the
      // dialog stays open — no silent close, no recorded entry.
      expect(find.textContaining('deactivated'), findsOneWidget);
      expect(find.textContaining('FR-HO-08'), findsOneWidget);
      expect(find.text('Add cashbook entry'), findsOneWidget);
      expect(find.text('Cashbook entry recorded.'), findsNothing);
      expect(
        (await container
                .read(expenseRepositoryProvider)
                .getExpenses(branchId: _dha))
            .length,
        beforeExpenses,
      );
    });

    testWidgets('reconciliation shows the deactivation refusal in a '
        'snackbar', (tester) async {
      final (container, router) = await _pumpRouterAppAsRole(
        tester,
        'owner',
        size: _phoneSize,
      );
      router.go('/finance/cashbook');
      await tester.pumpAndSettle();
      expect(find.text('Cashbook'), findsOneWidget);
      final branchRepo = container.read(branchRepositoryProvider);
      final branch = await branchRepo.getById(_dha);
      await branchRepo.updateBranch(branch!.copyWith(active: false));
      await tester.ensureVisible(
        find.byKey(const ValueKey('recon-counted-field')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('recon-counted-field')),
        '100',
      );
      await tester.ensureVisible(find.byKey(const ValueKey('recon-record')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('recon-record')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('deactivated'), findsOneWidget);
      expect(
        (await container
                .read(cashReconciliationRepositoryProvider)
                .getReconciliations(branchId: _dha))
            .length,
        0,
      );
    });
  });
}
