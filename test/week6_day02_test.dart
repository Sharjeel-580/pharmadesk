// Week 6 Day 2 tests — payment idempotency, D115 dialog-held-key pattern (D162).
//
// - D162 (closes the Week 5 Day 23 gap): the cashbook entry dialog
//   (income + expense), the Reports expense dialog and the supplier
//   payment dialog each mint ONE idempotency key for the dialog's
//   lifetime and pass it through the notifier on every submit, so a
//   double-submit returns the original payment instead of recording
//   a second one. The notifiers accept and forward the key instead
//   of letting the layer mint a fresh one per call; the layer's
//   registries and the D149/D161 deactivation guard are untouched.
// - The supplier notifier also remembers completed dialog-held keys
//   for the session (the D65 auto-PO pattern): it re-validates
//   against the LIVE outstanding before calling the layer, and the
//   first submit already reduced that outstanding, so without the
//   shortcut a same-key double-submit of a full settlement would
//   fail validation instead of returning the original.
// - Regression (pinned, not a defect): calling a notifier twice
//   with NO key still behaves as before — the layer mints a fresh
//   key per call, so each call is a new payment. The key is held by
//   the dialog, never by the notifier.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:pharmadesk/core/data/auth_repository.dart';
import 'package:pharmadesk/core/data/firestore_schema.dart';
import 'package:pharmadesk/core/data/production_data_layer.dart';
import 'package:pharmadesk/core/routing/app_router.dart';
import 'package:pharmadesk/core/services/repositories.dart';
import 'package:pharmadesk/core/theme/app_theme.dart';
import 'package:pharmadesk/core/theme/white_label.dart';
import 'package:pharmadesk/features/authentication/auth_state.dart';
import 'package:pharmadesk/features/finance/finance_logic.dart';
import 'package:pharmadesk/features/finance/finance_provider.dart';
import 'package:pharmadesk/features/suppliers/supplier_logic.dart';
import 'package:pharmadesk/models/financial_transaction.dart';
import 'package:pharmadesk/models/supplier_ledger.dart';
import 'package:pharmadesk/models/supplier_payment.dart';

const _dha = 'branch-dha-main';
const _org = demoOrganizationId;
const _phoneSize = Size(390, 844);

/// The seeded MedServe open payable (D92): Rs 48,250 outstanding.
const _medServeOutstanding = 4825000;

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

/// Pumps the real router app as [roleKey] (same helper shape as the
/// Week 6 Day 1 widget tests).
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

Future<void> _deactivate(ProviderContainer container, String branchId) async {
  final branchRepo = container.read(branchRepositoryProvider);
  final branch = await branchRepo.getById(branchId);
  await branchRepo.updateBranch(branch!.copyWith(active: false));
}

Future<int> _outstanding(
  ProviderContainer container,
  String supplierId,
) async {
  final entries = await container
      .read(supplierRepositoryProvider)
      .getLedgerEntries(supplierId);
  return supplierOutstandingMinor(entries);
}

Future<int> _agingTotal(
  ProviderContainer container,
  String supplierId,
) async {
  final entries = await container
      .read(supplierRepositoryProvider)
      .getLedgerEntries(supplierId);
  return computeAging(
    entries: supplierLedgerSignedEntries(entries),
    now: DateTime.now(),
  ).totalMinor;
}

void main() {
  group('D162 — cashbook double-submit with a dialog-held key', () {
    test('recordExpense with the same key twice records one expense '
        'and one mirror transaction', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      const key = 'cashbook-d29-expense-1';
      final beforeExpenses =
          (await container
                  .read(expenseRepositoryProvider)
                  .getExpenses(branchId: _dha))
              .length;
      final beforeTxns =
          (await container
                  .read(financialTransactionRepositoryProvider)
                  .getTransactions(branchId: _dha))
              .where((txn) => txn.type == FinancialTransactionType.expense)
              .length;

      final first = await container
          .read(expensesProvider.notifier)
          .recordExpense(
            branchId: _dha,
            category: 'Supplies',
            amountMinor: 50000,
            description: 'Double-submit expense',
            expenseDate: _day(0),
            idempotencyKey: key,
          );
      expect(first.error, isNull);
      final second = await container
          .read(expensesProvider.notifier)
          .recordExpense(
            branchId: _dha,
            category: 'Supplies',
            amountMinor: 50000,
            description: 'Double-submit expense',
            expenseDate: _day(0),
            idempotencyKey: key,
          );
      // A retried submit is the same expense, not a second one.
      expect(second.error, isNull);
      expect(second.expense, isNotNull);
      expect(second.expense!.id, first.expense!.id);
      expect(
        (await container
                .read(expenseRepositoryProvider)
                .getExpenses(branchId: _dha))
            .length,
        beforeExpenses + 1,
      );
      // One money move: exactly one mirror transaction.
      expect(
        (await container
                .read(financialTransactionRepositoryProvider)
                .getTransactions(branchId: _dha))
            .where((txn) => txn.type == FinancialTransactionType.expense)
            .length,
        beforeTxns + 1,
      );
      // One sync payload for the pair of submits, not two.
      expect(
        await container.read(productionDataLayerProvider).pendingSyncCount(),
        1,
      );
    });

    test('recordIncome with the same key twice records one transaction',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      const key = 'cashbook-d29-income-1';
      final beforeTxns =
          (await container
                  .read(financialTransactionRepositoryProvider)
                  .getTransactions(branchId: _dha))
              .where((txn) => txn.type == FinancialTransactionType.income)
              .length;

      final first = await container
          .read(financialTransactionsProvider.notifier)
          .recordIncome(
            branchId: _dha,
            category: 'Other income',
            amountMinor: 25000,
            date: _day(0),
            idempotencyKey: key,
          );
      expect(first.error, isNull);
      final second = await container
          .read(financialTransactionsProvider.notifier)
          .recordIncome(
            branchId: _dha,
            category: 'Other income',
            amountMinor: 25000,
            date: _day(0),
            idempotencyKey: key,
          );
      expect(second.error, isNull);
      expect(second.transaction, isNotNull);
      expect(second.transaction!.id, first.transaction!.id);
      expect(
        (await container
                .read(financialTransactionRepositoryProvider)
                .getTransactions(branchId: _dha))
            .where((txn) => txn.type == FinancialTransactionType.income)
            .length,
        beforeTxns + 1,
      );
      expect(
        await container.read(productionDataLayerProvider).pendingSyncCount(),
        1,
      );
    });

    test('two different keys record two expenses — a fresh dialog '
        'mints a fresh key', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final before =
          (await container
                  .read(expenseRepositoryProvider)
                  .getExpenses(branchId: _dha))
              .length;
      final first = await container
          .read(expensesProvider.notifier)
          .recordExpense(
            branchId: _dha,
            category: 'Supplies',
            amountMinor: 50000,
            expenseDate: _day(0),
            idempotencyKey: 'cashbook-d29-expense-first-dialog',
          );
      final second = await container
          .read(expensesProvider.notifier)
          .recordExpense(
            branchId: _dha,
            category: 'Supplies',
            amountMinor: 50000,
            expenseDate: _day(0),
            idempotencyKey: 'cashbook-d29-expense-second-dialog',
          );
      expect(first.error, isNull);
      expect(second.error, isNull);
      expect(second.expense!.id, isNot(first.expense!.id));
      expect(
        (await container
                .read(expenseRepositoryProvider)
                .getExpenses(branchId: _dha))
            .length,
        before + 2,
      );
    });
  });

  group('D162 — supplier double-submit with a dialog-held key', () {
    test('a partial payment with the same key twice pays once; aging '
        'moves by exactly the payment', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      const key = 'spay-d29-partial-1';
      expect(await _outstanding(container, 'sup-medserve'),
          _medServeOutstanding);
      final beforeLedger = await container
          .read(supplierRepositoryProvider)
          .getLedgerEntries('sup-medserve');
      final beforePaymentEntries = beforeLedger
          .where(
            (entry) =>
                entry.kind == SupplierLedgerEntryKind.payment,
          )
          .length;
      final beforeTxns =
          (await container
                  .read(financialTransactionRepositoryProvider)
                  .getTransactions(branchId: _dha))
              .where(
                (txn) =>
                    txn.type == FinancialTransactionType.supplierPayment,
              )
              .length;

      final first = await container
          .read(supplierPaymentsProvider.notifier)
          .recordPayment(
            supplierId: 'sup-medserve',
            branchId: _dha,
            amountMinor: 1000000,
            method: SupplierPaymentMethod.cash,
            idempotencyKey: key,
          );
      expect(first.error, isNull);
      final second = await container
          .read(supplierPaymentsProvider.notifier)
          .recordPayment(
            supplierId: 'sup-medserve',
            branchId: _dha,
            amountMinor: 1000000,
            method: SupplierPaymentMethod.cash,
            idempotencyKey: key,
          );
      // A retried submit is the same payment, not a second one.
      expect(second.error, isNull);
      expect(second.payment, isNotNull);
      expect(second.payment!.id, first.payment!.id);
      expect(
        await container
            .read(supplierPaymentRepositoryProvider)
            .getPayments(),
        hasLength(1),
      );
      // The aging moved by exactly the payment, and the ledger sum
      // agrees with it — one money move, no second move.
      expect(await _outstanding(container, 'sup-medserve'), 3825000);
      expect(await _agingTotal(container, 'sup-medserve'), 3825000);
      final afterLedger = await container
          .read(supplierRepositoryProvider)
          .getLedgerEntries('sup-medserve');
      expect(
        afterLedger
            .where(
              (entry) =>
                  entry.kind == SupplierLedgerEntryKind.payment,
            )
            .length,
        beforePaymentEntries + 1,
      );
      expect(
        afterLedger
            .where(
              (entry) =>
                  entry.kind == SupplierLedgerEntryKind.payment &&
                  entry.amountMinor == -1000000,
            )
            .length,
        1,
      );
      expect(
        (await container
                .read(financialTransactionRepositoryProvider)
                .getTransactions(branchId: _dha))
            .where(
              (txn) => txn.type == FinancialTransactionType.supplierPayment,
            )
            .length,
        beforeTxns + 1,
      );
      expect(
        await container.read(productionDataLayerProvider).pendingSyncCount(),
        1,
      );
    });

    test('a full settlement with the same key twice pays once — the '
        'live-outstanding validation must not reject the retry',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      const key = 'spay-d29-full-1';
      // Without the notifier's completed-key shortcut this second
      // call would fail validation: the first submit already took
      // the outstanding to zero, so "cannot exceed the outstanding
      // payable" would fire before the layer's registry is reached.
      final first = await container
          .read(supplierPaymentsProvider.notifier)
          .recordPayment(
            supplierId: 'sup-medserve',
            branchId: _dha,
            amountMinor: _medServeOutstanding,
            method: SupplierPaymentMethod.bankTransfer,
            reference: 'TXN-D29',
            idempotencyKey: key,
          );
      expect(first.error, isNull);
      expect(await _outstanding(container, 'sup-medserve'), 0);
      final second = await container
          .read(supplierPaymentsProvider.notifier)
          .recordPayment(
            supplierId: 'sup-medserve',
            branchId: _dha,
            amountMinor: _medServeOutstanding,
            method: SupplierPaymentMethod.bankTransfer,
            reference: 'TXN-D29',
            idempotencyKey: key,
          );
      expect(second.error, isNull);
      expect(second.payment!.id, first.payment!.id);
      expect(
        await container
            .read(supplierPaymentRepositoryProvider)
            .getPayments(),
        hasLength(1),
      );
      expect(await _outstanding(container, 'sup-medserve'), 0);
      expect(await _agingTotal(container, 'sup-medserve'), 0);
    });

    test('two different keys pay twice — a fresh dialog mints a '
        'fresh key', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final first = await container
          .read(supplierPaymentsProvider.notifier)
          .recordPayment(
            supplierId: 'sup-medserve',
            branchId: _dha,
            amountMinor: 1000000,
            method: SupplierPaymentMethod.cash,
            idempotencyKey: 'spay-d29-first-dialog',
          );
      final second = await container
          .read(supplierPaymentsProvider.notifier)
          .recordPayment(
            supplierId: 'sup-medserve',
            branchId: _dha,
            amountMinor: 500000,
            method: SupplierPaymentMethod.cash,
            idempotencyKey: 'spay-d29-second-dialog',
          );
      expect(first.error, isNull);
      expect(second.error, isNull);
      expect(second.payment!.id, isNot(first.payment!.id));
      expect(
        await container
            .read(supplierPaymentRepositoryProvider)
            .getPayments(),
        hasLength(2),
      );
      expect(
        await _outstanding(container, 'sup-medserve'),
        _medServeOutstanding - 1500000,
      );
    });
  });

  group('D162 — the D161 deactivation guard still refuses', () {
    test('recordExpense with a dialog-held key is refused on a '
        'deactivated branch; nothing written', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await _deactivate(container, _dha);
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
            expenseDate: _day(0),
            idempotencyKey: 'cashbook-d29-deactivated',
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

    test('recordPayment with a dialog-held key is refused on a '
        'deactivated branch; outstanding unchanged', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await _deactivate(container, _dha);
      final result = await container
          .read(supplierPaymentsProvider.notifier)
          .recordPayment(
            supplierId: 'sup-medserve',
            branchId: _dha,
            amountMinor: 1000000,
            method: SupplierPaymentMethod.cash,
            idempotencyKey: 'spay-d29-deactivated',
          );
      expect(result.payment, isNull);
      expect(result.error, contains('deactivated'));
      expect(result.error, contains('FR-HO-08'));
      expect(
        await container
            .read(supplierPaymentRepositoryProvider)
            .getPayments(),
        isEmpty,
      );
      expect(await _outstanding(container, 'sup-medserve'),
          _medServeOutstanding);
    });

    test('a duplicate expense retry after deactivation still returns '
        'the original', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      const key = 'cashbook-d29-expense-dupe-after-deact';
      final first = await container
          .read(expensesProvider.notifier)
          .recordExpense(
            branchId: _dha,
            category: 'Supplies',
            amountMinor: 50000,
            expenseDate: _day(0),
            idempotencyKey: key,
          );
      expect(first.error, isNull);
      await _deactivate(container, _dha);
      // The guard sits after the idempotency check in the layer: a
      // retried key is not a new write, so it returns the original
      // instead of the refusal (D161 ordering, unchanged).
      final retry = await container
          .read(expensesProvider.notifier)
          .recordExpense(
            branchId: _dha,
            category: 'Supplies',
            amountMinor: 50000,
            expenseDate: _day(0),
            idempotencyKey: key,
          );
      expect(retry.error, isNull);
      expect(retry.expense!.id, first.expense!.id);
    });

    test('a duplicate supplier-payment retry after deactivation still '
        'returns the original — no double money move', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      const key = 'spay-d29-dupe-after-deact';
      final first = await container
          .read(supplierPaymentsProvider.notifier)
          .recordPayment(
            supplierId: 'sup-medserve',
            branchId: _dha,
            amountMinor: _medServeOutstanding,
            method: SupplierPaymentMethod.bankTransfer,
            reference: 'TXN-D29-DEACT',
            idempotencyKey: key,
          );
      expect(first.error, isNull);
      expect(await _outstanding(container, 'sup-medserve'), 0);
      await _deactivate(container, _dha);
      final retry = await container
          .read(supplierPaymentsProvider.notifier)
          .recordPayment(
            supplierId: 'sup-medserve',
            branchId: _dha,
            amountMinor: _medServeOutstanding,
            method: SupplierPaymentMethod.bankTransfer,
            reference: 'TXN-D29-DEACT',
            idempotencyKey: key,
          );
      expect(retry.error, isNull);
      expect(retry.payment!.id, first.payment!.id);
      expect(
        await container
            .read(supplierPaymentRepositoryProvider)
            .getPayments(),
        hasLength(1),
      );
      expect(await _outstanding(container, 'sup-medserve'), 0);
    });
  });

  group('D162 — regression: no dialog-held key, behaviour unchanged', () {
    test('recordExpense twice with no key records two expenses — '
        'the notifier never mints or holds a key of its own',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final before =
          (await container
                  .read(expenseRepositoryProvider)
                  .getExpenses(branchId: _dha))
              .length;
      final first = await container
          .read(expensesProvider.notifier)
          .recordExpense(
            branchId: _dha,
            category: 'Supplies',
            amountMinor: 50000,
            expenseDate: _day(0),
          );
      final second = await container
          .read(expensesProvider.notifier)
          .recordExpense(
            branchId: _dha,
            category: 'Supplies',
            amountMinor: 50000,
            expenseDate: _day(0),
          );
      expect(first.error, isNull);
      expect(second.error, isNull);
      expect(second.expense!.id, isNot(first.expense!.id));
      expect(
        (await container
                .read(expenseRepositoryProvider)
                .getExpenses(branchId: _dha))
            .length,
        before + 2,
      );
    });

    test('recordIncome twice with no key records two transactions',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final before =
          (await container
                  .read(financialTransactionRepositoryProvider)
                  .getTransactions(branchId: _dha))
              .where((txn) => txn.type == FinancialTransactionType.income)
              .length;
      final first = await container
          .read(financialTransactionsProvider.notifier)
          .recordIncome(
            branchId: _dha,
            category: 'Other income',
            amountMinor: 25000,
            date: _day(0),
          );
      final second = await container
          .read(financialTransactionsProvider.notifier)
          .recordIncome(
            branchId: _dha,
            category: 'Other income',
            amountMinor: 25000,
            date: _day(0),
          );
      expect(first.error, isNull);
      expect(second.error, isNull);
      expect(second.transaction!.id, isNot(first.transaction!.id));
      expect(
        (await container
                .read(financialTransactionRepositoryProvider)
                .getTransactions(branchId: _dha))
            .where((txn) => txn.type == FinancialTransactionType.income)
            .length,
        before + 2,
      );
    });

    test('recordPayment twice with no key pays twice — each call '
        'mints a fresh key in the layer', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final first = await container
          .read(supplierPaymentsProvider.notifier)
          .recordPayment(
            supplierId: 'sup-medserve',
            branchId: _dha,
            amountMinor: 1000000,
            method: SupplierPaymentMethod.cash,
          );
      final second = await container
          .read(supplierPaymentsProvider.notifier)
          .recordPayment(
            supplierId: 'sup-medserve',
            branchId: _dha,
            amountMinor: 1000000,
            method: SupplierPaymentMethod.cash,
          );
      expect(first.error, isNull);
      expect(second.error, isNull);
      expect(second.payment!.id, isNot(first.payment!.id));
      expect(
        await container
            .read(supplierPaymentRepositoryProvider)
            .getPayments(),
        hasLength(2),
      );
      expect(
        await _outstanding(container, 'sup-medserve'),
        _medServeOutstanding - 2000000,
      );
    });
  });

  group('D162 — UI: each dialog instance submits once', () {
    testWidgets('cashbook entry dialog: two separate opens record an '
        'expense and then an income entry', (tester) async {
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
      final beforeIncome =
          (await container
                  .read(financialTransactionRepositoryProvider)
                  .getTransactions(branchId: _dha))
              .where((txn) => txn.type == FinancialTransactionType.income)
              .length;

      // First dialog instance: an expense.
      await tester.tap(find.text('Add entry'));
      await tester.pumpAndSettle();
      expect(find.text('Add cashbook entry'), findsOneWidget);
      await tester.enterText(
        find
            .descendant(
              of: find.byType(AlertDialog),
              matching: find.byType(TextField),
            )
            .first,
        '500',
      );
      await tester.tap(find.text('Save entry'));
      await tester.pumpAndSettle();
      expect(find.text('Cashbook entry recorded.'), findsOneWidget);
      expect(
        (await container
                .read(expenseRepositoryProvider)
                .getExpenses(branchId: _dha))
            .length,
        beforeExpenses + 1,
      );

      // Second dialog instance: a fresh key, so it records again —
      // this time as income, proving both sides of the dialog flow
      // through the held key.
      await tester.pump(const Duration(seconds: 5));
      await tester.tap(find.text('Add entry'));
      await tester.pumpAndSettle();
      expect(find.text('Add cashbook entry'), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Income'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find
            .descendant(
              of: find.byType(AlertDialog),
              matching: find.byType(TextField),
            )
            .first,
        '300',
      );
      await tester.tap(find.text('Save entry'));
      await tester.pumpAndSettle();
      expect(find.text('Cashbook entry recorded.'), findsOneWidget);
      expect(
        (await container
                .read(financialTransactionRepositoryProvider)
                .getTransactions(branchId: _dha))
            .where((txn) => txn.type == FinancialTransactionType.income)
            .length,
        beforeIncome + 1,
      );
    });

    testWidgets('supplier payment dialog: two separate opens pay twice '
        '— each dialog mints its own key', (tester) async {
      // 800px, not 390px: the supplier detail screen itself has
      // pre-existing 390px overflows unrelated to this day (the
      // aging badges in `_AgingChips` overflow by 63px in the test
      // font, and the Export-statement row by 0.2px) — that screen
      // was never in a 390px sweep (D142/D160), and fixing its
      // layout belongs to the Day 32 QA-depth day, not this
      // idempotency day. The dialog flow under test is identical
      // at 800px. Recorded as a follow-up in docs/day-29-progress.md.
      final (container, router) = await _pumpRouterAppAsRole(
        tester,
        'owner',
        size: const Size(800, 1200),
      );
      router.go('/suppliers/sup-medserve');
      await tester.pumpAndSettle();
      expect(find.text('MedServe Distributors'), findsWidgets);
      expect(await _outstanding(container, 'sup-medserve'),
          _medServeOutstanding);

      // First dialog instance: Rs 10,000.
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
      await tester.enterText(
        find
            .descendant(
              of: find.byType(AlertDialog),
              matching: find.byType(TextField),
            )
            .first,
        '10000',
      );
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Record'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Ledger entry recorded.'), findsOneWidget);
      expect(
        await container
            .read(supplierPaymentRepositoryProvider)
            .getPayments(),
        hasLength(1),
      );
      expect(await _outstanding(container, 'sup-medserve'), 3825000);

      // Second dialog instance: a fresh key, so it pays again —
      // Rs 5,000, leaving Rs 33,250 outstanding.
      await tester.pump(const Duration(seconds: 5));
      await tester.ensureVisible(find.text('Record payment'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Record payment'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find
            .descendant(
              of: find.byType(AlertDialog),
              matching: find.byType(TextField),
            )
            .first,
        '5000',
      );
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Record'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Ledger entry recorded.'), findsOneWidget);
      expect(
        await container
            .read(supplierPaymentRepositoryProvider)
            .getPayments(),
        hasLength(2),
      );
      expect(await _outstanding(container, 'sup-medserve'), 3325000);
      expect(await _agingTotal(container, 'sup-medserve'), 3325000);
    });
  });
}
