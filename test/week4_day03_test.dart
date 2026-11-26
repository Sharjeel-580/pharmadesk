// Week 4 Day 3 tests — finance hub: cashbook (D-24) + payables /
// receivables aging (D-25) + P&L / statements (D-26) (D124–D129).
//
// - Aging buckets (D92 boundaries + FIFO): boundary days, FIFO
//   payment allocation across buckets, overpayment ignored.
// - Cashbook logic: expense + income union (newest first, branch
//   filter), entry validation, income categories.
// - Daily closing: totals, opening carried from the previous
//   closing, duplicate / future validation, stale detection.
// - Notifiers: recordIncome (gate + backdated date kept, D125),
//   closeDay (totals, opening carry, duplicate/future/gate).
// - P&L agreement (D128): the finance statement provider returns
//   the exact P&L the Reports hub computes, for the same window and
//   branch — and both equal a direct live computation (no counters
//   in the mock, so countersUsed is false).
// - Aging aggregates (D127): seeded ledger totals per party and per
//   bucket, from the one D92 computation.
// - DailyClosing mapper + Firestore repo on the fake transport.
// - Widget tests: route walk (hub + 3 screens), cashbook add-entry
//   + close-day end to end, aging row navigation, statements
//   rendering, role gates (pharmacist / cashier / auditor /
//   regional manager), sidebar Finance entry.
//
// What is NOT tested here (and why): the production-layer sync
// payload for cashbook writes does not exist yet (D129 follow-up) —
// no test asserts a sync enqueue for an expense/income write.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:pharmadesk/core/data/auth_repository.dart';
import 'package:pharmadesk/core/data/firestore_mappers.dart';
import 'package:pharmadesk/core/data/firestore_repositories.dart';
import 'package:pharmadesk/core/data/firestore_schema.dart';
import 'package:pharmadesk/core/data/firestore_transport.dart';
import 'package:pharmadesk/core/data/inventory_engine.dart';
import 'package:pharmadesk/core/data/permission_service.dart';
import 'package:pharmadesk/core/routing/app_router.dart';
import 'package:pharmadesk/core/services/repositories.dart';
import 'package:pharmadesk/core/theme/app_theme.dart';
import 'package:pharmadesk/core/theme/white_label.dart';
import 'package:pharmadesk/features/authentication/auth_state.dart';
import 'package:pharmadesk/features/customers/customers_provider.dart';
import 'package:pharmadesk/features/finance/finance_logic.dart';
import 'package:pharmadesk/features/finance/finance_provider.dart';
import 'package:pharmadesk/features/reports/analytics_logic.dart';
import 'package:pharmadesk/features/reports/reports_provider.dart';
import 'package:pharmadesk/features/suppliers/suppliers_provider.dart';
import 'package:pharmadesk/models/daily_closing.dart';
import 'package:pharmadesk/models/expense.dart';
import 'package:pharmadesk/models/financial_transaction.dart';

const _dha = 'branch-dha-main';
const _glb = 'branch-demo-gulberg';
const _org = demoOrganizationId;

DateTime _day(int daysAgo) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  return today.subtract(Duration(days: daysAgo));
}

List<SignedEntry> _charges(List<(int daysAgo, int amountMinor)> charges) {
  return [
    for (var i = 0; i < charges.length; i++)
      (id: 'c$i', date: _day(charges[i].$1), amountMinor: charges[i].$2),
  ];
}

void main() {
  group('Aging buckets — D92 boundaries', () {
    test('boundary days land in the right bucket', () {
      expect(agingBucketForAge(0), AgingBucket.current);
      expect(agingBucketForAge(30), AgingBucket.current);
      expect(agingBucketForAge(31), AgingBucket.days30);
      expect(agingBucketForAge(60), AgingBucket.days30);
      expect(agingBucketForAge(61), AgingBucket.days60);
      expect(agingBucketForAge(90), AgingBucket.days60);
      expect(agingBucketForAge(91), AgingBucket.days90plus);
      expect(agingBucketForAge(400), AgingBucket.days90plus);
    });

    test('FIFO: payments settle the oldest charge first', () {
      final summary = computeAging(
        entries: [
          ..._charges([(45, 100000), (5, 50000)]),
          (id: 'p1', date: _day(2), amountMinor: -80000),
        ],
        now: DateTime.now(),
      );
      // Oldest charge (45d) keeps Rs 200 after the Rs 800 payment;
      // the 5-day charge is untouched.
      expect(summary.totalMinor, 70000);
      expect(summary.bucket(AgingBucket.days30), 20000);
      expect(summary.bucket(AgingBucket.current), 50000);
      expect(summary.bucket(AgingBucket.days60), 0);
      expect(summary.bucket(AgingBucket.days90plus), 0);
    });

    test('overpayment leaves no negative payable', () {
      final summary = computeAging(
        entries: [
          ..._charges([(10, 50000)]),
          (id: 'p1', date: _day(1), amountMinor: -90000),
        ],
        now: DateTime.now(),
      );
      expect(summary.totalMinor, 0);
      expect(summary.bucket(AgingBucket.current), 0);
    });

    test('a future-dated charge ages as current, never negative', () {
      final now = DateTime.now();
      final summary = computeAging(
        entries: [
          (
            id: 'c0',
            date: now.add(const Duration(days: 3)),
            amountMinor: 40000,
          ),
        ],
        now: now,
      );
      expect(summary.bucket(AgingBucket.current), 40000);
      expect(summary.totalMinor, 40000);
    });
  });

  group('Cashbook entries — union + validation (D124/D125)', () {
    test('expenses + income unify newest-first, branch-scoped', () {
      final entries = cashbookEntries(
        expenses: [
          Expense(
            id: 'e1',
            branchId: _dha,
            category: 'Rent',
            amountMinor: 8500000,
            description: 'Monthly shop rent',
            expenseDate: _day(3),
          ),
          Expense(
            id: 'e2',
            branchId: _glb,
            category: 'Utilities',
            amountMinor: 1200000,
            expenseDate: _day(1),
          ),
        ],
        transactions: [
          FinancialTransaction(
            id: 't1',
            branchId: _dha,
            type: FinancialTransactionType.income,
            amountMinor: 250000,
            category: 'Other income',
            createdAt: _day(1),
          ),
          // The expense mirror must NOT appear as income.
          FinancialTransaction(
            id: 't2',
            branchId: _dha,
            type: FinancialTransactionType.expense,
            amountMinor: -8500000,
            category: 'Rent',
            createdAt: _day(3),
          ),
        ],
        branchId: _dha,
      );
      expect(entries.length, 2);
      expect(entries.first.kind, CashbookEntryKind.income);
      expect(entries.first.amountMinor, 250000);
      expect(entries.last.kind, CashbookEntryKind.expense);
      expect(entries.last.note, 'Monthly shop rent');
    });

    test(
      'validateCashbookEntry rejects bad category, zero, future, long note',
      () {
        expect(
          validateCashbookEntry(
            isIncome: false,
            category: 'Not a category',
            amountMinor: 10000,
            date: _day(0),
          ),
          isNotEmpty,
        );
        expect(
          validateCashbookEntry(
            isIncome: true,
            category: 'Other income',
            amountMinor: 0,
            date: _day(0),
          ),
          isNotEmpty,
        );
        expect(
          validateCashbookEntry(
            isIncome: false,
            category: 'Rent',
            amountMinor: 10000,
            date: DateTime.now().add(const Duration(days: 1)),
          ),
          isNotEmpty,
        );
        expect(
          validateCashbookEntry(
            isIncome: false,
            category: 'Rent',
            amountMinor: 10000,
            date: _day(0),
            note: 'x' * 201,
          ),
          isNotEmpty,
        );
        expect(
          validateCashbookEntry(
            isIncome: true,
            category: 'Owner contribution',
            amountMinor: 10000,
            date: _day(0),
          ),
          isEmpty,
        );
      },
    );
  });

  group('Daily closing — totals, opening, validation, stale (D126)', () {
    final entries = <CashbookEntry>[
      (
        id: 'i1',
        date: _day(0),
        kind: CashbookEntryKind.income,
        category: 'Other income',
        amountMinor: 250000,
        note: '',
        referenceId: null,
      ),
      (
        id: 'e1',
        date: _day(0),
        kind: CashbookEntryKind.expense,
        category: 'Rent',
        amountMinor: 1000000,
        note: '',
        referenceId: null,
      ),
      (
        id: 'e2',
        date: _day(1),
        kind: CashbookEntryKind.expense,
        category: 'Utilities',
        amountMinor: 50000,
        note: '',
        referenceId: null,
      ),
    ];

    test('computeDailyClosing counts only that day, opening + in − out', () {
      final totals = computeDailyClosing(
        entries: entries,
        date: _day(0),
        openingBalanceMinor: 400000,
      );
      expect(totals.incomeMinor, 250000);
      expect(totals.expenseMinor, 1000000);
      expect(totals.openingBalanceMinor, 400000);
      expect(totals.closingBalanceMinor, -350000);
    });

    test('previousClosingBalance is the latest closing before the day', () {
      final closings = [
        DailyClosing(
          id: 'dc-1',
          branchId: _dha,
          date: _day(3),
          totalIncomeMinor: 0,
          totalExpenseMinor: 100000,
          openingBalanceMinor: 0,
          closingBalanceMinor: -100000,
        ),
        DailyClosing(
          id: 'dc-2',
          branchId: _dha,
          date: _day(1),
          totalIncomeMinor: 50000,
          totalExpenseMinor: 0,
          openingBalanceMinor: -100000,
          closingBalanceMinor: -50000,
        ),
        DailyClosing(
          id: 'dc-3',
          branchId: _glb,
          date: _day(1),
          totalIncomeMinor: 0,
          totalExpenseMinor: 0,
          openingBalanceMinor: 0,
          closingBalanceMinor: 999999,
        ),
      ];
      expect(
        previousClosingBalance(
          closings: closings,
          branchId: _dha,
          date: _day(0),
        ),
        -50000,
      );
      // No earlier closing → 0. A same-day closing is not its own opening.
      expect(
        previousClosingBalance(
          closings: closings,
          branchId: _dha,
          date: _day(1),
        ),
        -100000,
      );
      expect(
        previousClosingBalance(
          closings: closings,
          branchId: _dha,
          date: _day(5),
        ),
        0,
      );
    });

    test('validateDailyClosing rejects future days and duplicates', () {
      expect(
        validateDailyClosing(
          date: DateTime.now().add(const Duration(days: 1)),
          existing: const [],
          branchId: _dha,
        ),
        isNotEmpty,
      );
      final existing = [
        DailyClosing(
          id: 'dc-1',
          branchId: _dha,
          date: _day(0),
          totalIncomeMinor: 0,
          totalExpenseMinor: 0,
          openingBalanceMinor: 0,
          closingBalanceMinor: 0,
        ),
      ];
      expect(
        validateDailyClosing(date: _day(0), existing: existing, branchId: _dha),
        isNotEmpty,
      );
      // Same day, other branch: fine.
      expect(
        validateDailyClosing(date: _day(0), existing: existing, branchId: _glb),
        isEmpty,
      );
    });

    test('dailyClosingIsStale flags entries added after the close', () {
      final closing = DailyClosing(
        id: 'dc-1',
        branchId: _dha,
        date: _day(0),
        totalIncomeMinor: 250000,
        totalExpenseMinor: 1000000,
        openingBalanceMinor: 0,
        closingBalanceMinor: -750000,
      );
      expect(dailyClosingIsStale(closing: closing, entries: entries), isFalse);
      final withLateEntry = [
        ...entries,
        (
          id: 'e3',
          date: _day(0),
          kind: CashbookEntryKind.expense,
          category: 'Supplies',
          amountMinor: 10000,
          note: '',
          referenceId: null,
        ),
      ];
      expect(
        dailyClosingIsStale(closing: closing, entries: withLateEntry),
        isTrue,
      );
    });
  });

  group('Income + closing through the notifiers (D125/D126)', () {
    test(
      'recordIncome writes an income transaction, visible in the cashbook',
      () async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final result = await container
            .read(financialTransactionsProvider.notifier)
            .recordIncome(
              branchId: _dha,
              category: 'Owner contribution',
              amountMinor: 500000,
              date: _day(0),
            );
        expect(result.error, isNull);
        expect(result.transaction, isNotNull);
        expect(result.transaction!.type, FinancialTransactionType.income);
        await container.read(expensesProvider.future);
        await container.read(financialTransactionsProvider.future);
        final entries = container.read(cashbookEntriesProvider(_dha));
        expect(
          entries.any(
            (entry) =>
                entry.kind == CashbookEntryKind.income &&
                entry.amountMinor == 500000,
          ),
          isTrue,
        );
      },
    );

    test('recordIncome keeps a backdated business date (D125)', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final fiveDaysAgo = _day(5);
      final result = await container
          .read(financialTransactionsProvider.notifier)
          .recordIncome(
            branchId: _dha,
            category: 'Refund received',
            amountMinor: 120000,
            date: fiveDaysAgo,
          );
      expect(result.error, isNull);
      final createdAt = result.transaction!.createdAt!;
      expect(
        DateTime(createdAt.year, createdAt.month, createdAt.day),
        DateTime(fiveDaysAgo.year, fiveDaysAgo.month, fiveDaysAgo.day),
      );
    });

    test('recordIncome is gated: pharmacist + auditor are refused', () async {
      for (final roleKey in ['pharmacist', 'auditor']) {
        final container = ProviderContainer(
          overrides: [
            authProvider.overrideWith(
              () => _FixedAuthNotifier(_userFor(roleKey)),
            ),
          ],
        );
        addTearDown(container.dispose);
        final result = await container
            .read(financialTransactionsProvider.notifier)
            .recordIncome(
              branchId: _dha,
              category: 'Other income',
              amountMinor: 10000,
              date: _day(0),
            );
        expect(result.transaction, isNull);
        expect(result.error, isNotNull, reason: roleKey);
      }
    });

    test('closeDay snapshots totals and carries the opening forward', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      // Yesterday: Rs 1,000 expense. Today: Rs 2,500 income.
      await container
          .read(expensesProvider.notifier)
          .recordExpense(
            branchId: _dha,
            category: 'Supplies',
            amountMinor: 100000,
            description: 'Yesterday supplies',
            expenseDate: _day(1),
          );
      await container
          .read(financialTransactionsProvider.notifier)
          .recordIncome(
            branchId: _dha,
            category: 'Other income',
            amountMinor: 250000,
            date: _day(0),
          );
      final yesterday = await container
          .read(dailyClosingsProvider.notifier)
          .closeDay(branchId: _dha, date: _day(1));
      expect(yesterday.error, isNull);
      expect(yesterday.closing!.totalExpenseMinor, 100000);
      expect(yesterday.closing!.closingBalanceMinor, -100000);
      final today = await container
          .read(dailyClosingsProvider.notifier)
          .closeDay(branchId: _dha, date: _day(0));
      expect(today.error, isNull);
      expect(today.closing!.openingBalanceMinor, -100000);
      expect(today.closing!.totalIncomeMinor, 250000);
      expect(today.closing!.closingBalanceMinor, 150000);
      // Second close of the same day is refused.
      final again = await container
          .read(dailyClosingsProvider.notifier)
          .closeDay(branchId: _dha, date: _day(0));
      expect(again.closing, isNull);
      expect(again.error, isNotNull);
    });

    test('closeDay refuses a future day and a pharmacist', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final future = await container
          .read(dailyClosingsProvider.notifier)
          .closeDay(
            branchId: _dha,
            date: DateTime.now().add(const Duration(days: 1)),
          );
      expect(future.closing, isNull);
      expect(future.error, isNotNull);

      final pharma = ProviderContainer(
        overrides: [
          authProvider.overrideWith(
            () => _FixedAuthNotifier(_userFor('pharmacist')),
          ),
        ],
      );
      addTearDown(pharma.dispose);
      final denied = await pharma
          .read(dailyClosingsProvider.notifier)
          .closeDay(branchId: _dha, date: _day(0));
      expect(denied.closing, isNull);
      expect(denied.error, isNotNull);
    });
  });

  group('P&L agreement — finance vs Reports (D128)', () {
    test('same P&L for the same window, all branches + one branch', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      for (final (branchId, days) in [(null, 30), (_dha, 30), (null, 7)]) {
        final reports = await container.read(
          advancedReportDataProvider((branchId, days)).future,
        );
        final statement = await container.read(
          branchStatementProvider((branchId, days)).future,
        );
        expect(
          statement.revenueMinor,
          reports.profitLoss.revenueMinor,
          reason: '$branchId / $days revenue',
        );
        expect(
          statement.cogsMinor,
          reports.profitLoss.cogsMinor,
          reason: '$branchId / $days COGS',
        );
        expect(statement.grossProfitMinor, reports.profitLoss.grossProfitMinor);
        expect(statement.otherIncomeMinor, reports.profitLoss.otherIncomeMinor);
        expect(statement.expensesMinor, reports.profitLoss.expensesMinor);
        expect(statement.netProfitMinor, reports.profitLoss.netProfitMinor);
      }
    });

    test('both equal a direct live computation', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final orders = await container.read(orderRepositoryProvider).getOrders();
      final sales = await container.read(saleRepositoryProvider).getSales();
      final returns = await container
          .read(saleReturnRepositoryProvider)
          .getReturns();
      final inventory = await container
          .read(inventoryRepositoryProvider)
          .getInventory();
      final medicines = await container
          .read(medicineRepositoryProvider)
          .getMedicines();
      final expenses = await container
          .read(expenseRepositoryProvider)
          .getExpenses();
      final transactions = await container
          .read(financialTransactionRepositoryProvider)
          .getTransactions();
      final live = computeProfitAndLoss(
        orders: orders,
        sales: sales,
        returns: returns,
        inventory: inventory,
        expenses: expenses,
        transactions: transactions,
        medicinesById: {for (final m in medicines) m.id: m},
        now: DateTime.now(),
        days: 30,
      );
      final reports = await container.read(
        advancedReportDataProvider((null, 30)).future,
      );
      // The mock counter repo covers the window (D105), so the
      // Reports figures here are counter-backed — the agreement
      // below is what matters: whatever the Reports hub shows, the
      // finance screen must show the same.
      expect(reports.profitLoss.revenueMinor, live.revenueMinor);
      expect(reports.profitLoss.cogsMinor, live.cogsMinor);
      expect(reports.profitLoss.netProfitMinor, live.netProfitMinor);
      final statement = await container.read(
        branchStatementProvider((null, 30)).future,
      );
      expect(statement.netProfitMinor, live.netProfitMinor);
    });
  });

  group('Aging aggregates — seeded ledgers (D127)', () {
    test('payables: seeded opening balances, all current', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(suppliersProvider.future);
      for (final id in [
        'sup-sami',
        'sup-medserve',
        'sup-hassan-traders',
        'sup-careline',
      ]) {
        await container.read(supplierLedgerProvider(id).future);
      }
      final aging = container.read(allPayablesAgingProvider);
      expect(aging['sup-sami']!.totalMinor, 12500000);
      expect(aging['sup-medserve']!.totalMinor, 4825000);
      expect(aging['sup-hassan-traders']!.totalMinor, 0);
      expect(aging['sup-careline']!.totalMinor, 2100000);
      // 28 / 25 / 15 days old — every open charge is Current.
      final total = aging.values.fold(
        0,
        (sum, summary) => sum + summary.totalMinor,
      );
      expect(total, 19425000);
      final current = aging.values.fold(
        0,
        (sum, summary) => sum + summary.bucket(AgingBucket.current),
      );
      expect(current, total);
    });

    test('receivables: seeded khata balances, all current', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(customersProvider.future);
      for (final id in ['cust-1', 'cust-2', 'cust-3', 'cust-4']) {
        await container.read(ledgerProvider(id).future);
      }
      final aging = container.read(allReceivablesAgingProvider);
      expect(aging['cust-1']!.totalMinor, 550000);
      expect(aging['cust-2']!.totalMinor, 250000);
      expect(aging['cust-3']!.totalMinor, 1200000);
      // cust-4: Rs 15,000 charge − Rs 5,000 payment + Rs 2,000 charge.
      expect(aging['cust-4']!.totalMinor, 1200000);
      final total = aging.values.fold(
        0,
        (sum, summary) => sum + summary.totalMinor,
      );
      expect(total, 3200000);
    });
  });

  group('DailyClosing mapper + Firestore repo (fake transport, D126)', () {
    test('mapper round-trips the closing', () {
      final closing = DailyClosing(
        id: 'dc-test-1',
        branchId: _dha,
        date: DateTime(2026, 11, 25),
        totalIncomeMinor: 250000,
        totalExpenseMinor: 1000000,
        openingBalanceMinor: 400000,
        closingBalanceMinor: -350000,
        closedBy: 'demo-owner',
        note: 'Test close',
      );
      final doc = dailyClosingToFirestore(closing, orgId: _org);
      final back = dailyClosingFromFirestore('dc-test-1', doc);
      expect(back.branchId, _dha);
      expect(
        DateTime(back.date.year, back.date.month, back.date.day),
        DateTime(2026, 11, 25),
      );
      expect(back.totalIncomeMinor, 250000);
      expect(back.totalExpenseMinor, 1000000);
      expect(back.openingBalanceMinor, 400000);
      expect(back.closingBalanceMinor, -350000);
      expect(back.closedBy, 'demo-owner');
      expect(back.note, 'Test close');
    });

    test('create + read + duplicate refused', () async {
      final transport = _FakeFirestoreTransport();
      await transport.setDocument('branches/$_dha', {
        'name': 'Demo Branch — DHA',
        'code': 'DHA',
        'organizationId': _org,
      });
      final repo = FirestoreDailyClosingRepository(
        transport: transport,
        organizationId: _org,
      );
      final created = await repo.createClosing(
        DailyClosing(
          id: '',
          branchId: _dha,
          date: DateTime(2026, 11, 25),
          totalIncomeMinor: 250000,
          totalExpenseMinor: 1000000,
          openingBalanceMinor: 0,
          closingBalanceMinor: -750000,
          closedBy: 'demo-owner',
          note: 'Test close',
        ),
      );
      expect(created.id, isNotEmpty);
      final byDay = await repo.getClosing(
        branchId: _dha,
        date: DateTime(2026, 11, 25),
      );
      expect(byDay, isNotNull);
      expect(byDay!.closingBalanceMinor, -750000);
      expect(byDay.note, 'Test close');
      expect((await repo.getClosings(branchId: _dha)).length, 1);
      expect(
        () => repo.createClosing(
          DailyClosing(
            id: '',
            branchId: _dha,
            date: DateTime(2026, 11, 25),
            totalIncomeMinor: 0,
            totalExpenseMinor: 0,
            openingBalanceMinor: 0,
            closingBalanceMinor: 0,
          ),
        ),
        throwsArgumentError,
      );
    });
  });

  group('Finance routes + screens (widget)', () {
    testWidgets('route walk: hub + cashbook + aging + statements render', (
      WidgetTester tester,
    ) async {
      final (container, router) = await pumpRouterApp(tester);
      await container.read(authProvider.notifier).signInAsDemo(DemoRole.owner);
      await tester.pumpAndSettle();

      const present = <(String, String)>[
        ('/finance', 'P&L & Statements'),
        ('/finance/cashbook', 'Daily closings'),
        ('/finance/aging', 'Unpaid purchase orders'),
        ('/finance/statements', 'Branch statements'),
      ];
      for (final (route, marker) in present) {
        router.go(route);
        await tester.pumpAndSettle();
        expect(
          find.textContaining(marker),
          findsWidgets,
          reason: '$route should render its screen ($marker)',
        );
        expect(
          find.text('Page not found'),
          findsNothing,
          reason: '$route must resolve',
        );
      }
    });

    testWidgets('hub shows the four finance cards (owner)', (
      WidgetTester tester,
    ) async {
      final (container, router) = await pumpRouterApp(tester);
      await container.read(authProvider.notifier).signInAsDemo(DemoRole.owner);
      await tester.pumpAndSettle();
      router.go('/finance');
      await tester.pumpAndSettle();
      expect(find.text('Cashbook'), findsOneWidget);
      expect(find.text('Payables & Receivables'), findsOneWidget);
      expect(find.text('P&L & Statements'), findsOneWidget);
      expect(find.text('Franchise Royalties'), findsOneWidget);
      expect(find.textContaining('No access'), findsNothing);
    });

    testWidgets('hub marks the cards a cashier may not use (D124)', (
      WidgetTester tester,
    ) async {
      final (_, router) = await pumpRouterAppAsRole(tester, 'cashier');
      router.go('/finance');
      await tester.pumpAndSettle();
      expect(find.text('Cashbook'), findsOneWidget);
      // Cashier has `financeReports` none: aging + statements locked.
      // The Franchise Royalties card is locked too (D159 — head
      // office only, `branches` write level), so three cards show
      // "No access" now, not two.
      expect(find.textContaining('No access'), findsNWidgets(3));
    });

    testWidgets('cashbook shows seeded expenses + aging totals', (
      WidgetTester tester,
    ) async {
      final (container, router) = await pumpRouterApp(tester);
      await container.read(authProvider.notifier).signInAsDemo(DemoRole.owner);
      await tester.pumpAndSettle();
      router.go('/finance/cashbook');
      await tester.pumpAndSettle();
      // "Show all dates" — the seeded expenses are 2–28 days back.
      await tester.tap(find.text('Show all dates'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Monthly shop rent'), findsOneWidget);
      expect(find.textContaining('Staff salaries'), findsWidgets);

      router.go('/finance/aging');
      await tester.pumpAndSettle();
      expect(find.text('Sami Pharmaceuticals'), findsOneWidget);
      expect(find.text('MedServe Distributors'), findsOneWidget);
      expect(find.text('CareLine Supplies'), findsOneWidget);
      expect(find.text('Hassan Pharma Traders'), findsNothing);
      expect(find.text('Rs 194,250.00'), findsWidgets);
      expect(find.text('Rs 32,000.00'), findsWidgets);
    });

    testWidgets('cashbook add-entry + close-day end to end', (
      WidgetTester tester,
    ) async {
      final (container, router) = await pumpRouterApp(tester);
      await container.read(authProvider.notifier).signInAsDemo(DemoRole.owner);
      await tester.pumpAndSettle();
      router.go('/finance/cashbook');
      await tester.pumpAndSettle();
      final now = DateTime.now();
      final todayText = '${now.day}/${now.month}/${now.year}';

      await tester.tap(find.text('Add entry'));
      await tester.pumpAndSettle();
      // Scope the field to the dialog: the cashbook screen itself now
      // has text fields (drawer-count, Week 5 Day 4) that come before
      // the dialog's fields in tree order, so an unscoped `.first`
      // would type into the screen behind the dialog.
      await tester.enterText(
        find
            .descendant(
              of: find.byType(AlertDialog),
              matching: find.byType(TextFormField),
            )
            .first,
        '5000',
      );
      await tester.tap(find.text('Save entry'));
      await tester.pumpAndSettle();
      expect(find.text('Cashbook entry recorded.'), findsOneWidget);
      // Today's list now holds the new Rent entry.
      expect(find.text('Rent'), findsOneWidget);

      await tester.tap(find.text('Close this day'));
      await tester.pumpAndSettle();
      expect(find.text('Close day — $todayText'), findsOneWidget);
      await tester.tap(find.text('Close day'));
      await tester.pumpAndSettle();
      // Durable proof the close landed (the "Day closed" snackbar is
      // transient — the first snackbar is still showing when it is
      // queued, so asserting on it is timing-sensitive).
      expect(find.text('Closed $todayText'), findsOneWidget);
      expect(find.text('Day closed'), findsOneWidget);
    });

    testWidgets('aging row navigates to the supplier detail', (
      WidgetTester tester,
    ) async {
      final (container, router) = await pumpRouterApp(tester);
      await container.read(authProvider.notifier).signInAsDemo(DemoRole.owner);
      await tester.pumpAndSettle();
      router.go('/finance/aging');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sami Pharmaceuticals'));
      await tester.pumpAndSettle();
      expect(find.text('Payables ledger'), findsOneWidget);
    });

    testWidgets('statements show the consolidated P&L + branch cards', (
      WidgetTester tester,
    ) async {
      final (container, router) = await pumpRouterApp(tester);
      await container.read(authProvider.notifier).signInAsDemo(DemoRole.owner);
      await tester.pumpAndSettle();
      router.go('/finance/statements');
      await tester.pumpAndSettle();
      expect(find.text('P&L & Statements'), findsOneWidget);
      expect(find.text('Profit & loss — All branches'), findsOneWidget);
      expect(find.text('Net profit'), findsWidgets);
      // Both names also appear in the top-bar branch switcher, so
      // the finder matches the card title AND the switcher.
      expect(find.text('Demo Branch — DHA'), findsWidgets);
      expect(find.text('Demo Branch — Gulberg'), findsWidgets);
    });

    testWidgets('sidebar lists Finance under Insights (desktop)', (
      WidgetTester tester,
    ) async {
      final (container, router) = await pumpRouterApp(tester);
      await container.read(authProvider.notifier).signInAsDemo(DemoRole.owner);
      await tester.pumpAndSettle();
      router.go('/dashboard');
      await tester.pumpAndSettle();
      // The sidebar is a lazy ListView: scroll it until the item is
      // built, then assert — scoped to the sidebar's ListView, the
      // way the Day 2 sidebar test does it (the module title also
      // appears in the screen body).
      final sidebarList = find.byType(ListView);
      final financeItem = find.descendant(
        of: sidebarList,
        matching: find.text('Finance'),
      );
      for (var i = 0; i < 12 && financeItem.evaluate().isEmpty; i++) {
        await tester.drag(sidebarList, const Offset(0, -300));
        await tester.pumpAndSettle();
      }
      expect(financeItem, findsOneWidget);
    });
  });

  group('Finance gates (SRS §5.1 — D124)', () {
    test('routeCapability maps the three screens, not the hub', () {
      expect(routeCapability('/finance'), isNull);
      expect(routeCapability('/finance/cashbook'), 'financeEntry');
      expect(routeCapability('/finance/aging'), 'financeReports');
      expect(routeCapability('/finance/statements'), 'financeReports');
    });

    testWidgets('pharmacist is stopped at the cashbook route', (
      WidgetTester tester,
    ) async {
      final (_, router) = await pumpRouterAppAsRole(tester, 'pharmacist');
      router.go('/finance/cashbook');
      await tester.pumpAndSettle();
      expect(find.text('No permission for Finance'), findsOneWidget);
    });

    testWidgets('cashier may use the cashbook but not the statements', (
      WidgetTester tester,
    ) async {
      final (_, router) = await pumpRouterAppAsRole(tester, 'cashier');
      router.go('/finance/cashbook');
      await tester.pumpAndSettle();
      expect(find.text('Cashbook'), findsOneWidget);
      router.go('/finance/statements');
      await tester.pumpAndSettle();
      expect(find.text('No permission for Finance'), findsOneWidget);
    });

    testWidgets('auditor may view the cashbook but sees no Add entry', (
      WidgetTester tester,
    ) async {
      final (_, router) = await pumpRouterAppAsRole(tester, 'auditor');
      router.go('/finance/cashbook');
      await tester.pumpAndSettle();
      expect(find.text('Cashbook'), findsOneWidget);
      expect(find.text('Add entry'), findsNothing);
    });

    testWidgets('regional manager may view statements, not the cashbook', (
      WidgetTester tester,
    ) async {
      final (_, router) = await pumpRouterAppAsRole(tester, 'regional_manager');
      router.go('/finance/cashbook');
      await tester.pumpAndSettle();
      expect(find.text('No permission for Finance'), findsOneWidget);
      router.go('/finance/statements');
      await tester.pumpAndSettle();
      expect(find.text('P&L & Statements'), findsOneWidget);
    });
  });
}

/// A signed-in user with [roleKey] in the DHA branch (same shape as
/// the Week 3 Day 4 auditor helper).
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

class _FixedAuthNotifier extends AuthNotifier {
  _FixedAuthNotifier(this.user);

  final AppUser user;

  @override
  AppUser? build() => user;
}

/// Pumps the ungated router app with a fresh container the test owns
/// (same harness as the Week 3 Day 4 widget tests), at a desktop
/// viewport.
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

/// Pumps the router app signed in as [roleKey] (see [_userFor]).
Future<(ProviderContainer, GoRouter)> pumpRouterAppAsRole(
  WidgetTester tester,
  String roleKey, {
  List<String> branchIds = const [_dha],
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1920, 1080);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final user = _userFor(roleKey, branchIds: branchIds);
  final container = ProviderContainer(
    overrides: [authProvider.overrideWith(() => _FixedAuthNotifier(user))],
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

/// Fake Firestore transport (same shape as the Week 4 Day 2 one):
/// an in-memory document map behind the transport interface.
class _FakeFirestoreTransport implements FirestoreTransport {
  final Map<String, Map<String, dynamic>> docs = {};
  int _autoId = 0;

  @override
  Future<Map<String, dynamic>?> getDocument(String path) async {
    final data = docs[path];
    return data == null ? null : Map<String, dynamic>.from(data);
  }

  @override
  Future<List<FirestoreDocument>> queryCollection(
    String collectionPath, {
    Map<String, Object?> whereEquals = const {},
    String? orderBy,
    bool descending = false,
    int? limit,
    String? startAfterId,
  }) async {
    var entries = docs.entries.where((entry) {
      if (!entry.key.startsWith('$collectionPath/')) return false;
      return !entry.key.substring(collectionPath.length + 1).contains('/');
    }).toList();
    for (final filter in whereEquals.entries) {
      entries = entries
          .where((entry) => entry.value[filter.key] == filter.value)
          .toList();
    }
    var found = [
      for (final entry in entries)
        FirestoreDocument(
          id: entry.key.split('/').last,
          data: Map<String, dynamic>.from(entry.value),
        ),
    ]..sort((a, b) => a.id.compareTo(b.id));
    if (startAfterId != null) {
      final index = found.indexWhere((doc) => doc.id == startAfterId);
      if (index != -1) found = found.sublist(index + 1);
    }
    if (limit != null && found.length > limit) {
      found = found.sublist(0, limit);
    }
    return found;
  }

  @override
  Future<void> setDocument(
    String path,
    Map<String, dynamic> data, {
    bool merge = false,
  }) async {
    if (merge && docs.containsKey(path)) {
      docs[path] = {...docs[path]!, ...data};
    } else {
      docs[path] = Map<String, dynamic>.from(data);
    }
  }

  @override
  Future<void> updateDocument(String path, Map<String, dynamic> data) async {
    final existing = docs[path];
    if (existing == null) {
      throw StateError('No document at $path to update.');
    }
    docs[path] = {...existing, ...data};
  }

  @override
  Future<String> addDocument(
    String collectionPath,
    Map<String, dynamic> data,
  ) async {
    final id = 'auto-${++_autoId}';
    await setDocument('$collectionPath/$id', data);
    return id;
  }

  @override
  Future<void> runBatchedWrites(List<WriteOperation> operations) async {
    for (final operation in operations) {
      switch (operation.kind) {
        case WriteOperationKind.set:
          await setDocument(operation.path, operation.data ?? {});
        case WriteOperationKind.update:
          await updateDocument(operation.path, operation.data ?? {});
        case WriteOperationKind.delete:
          docs.remove(operation.path);
      }
    }
  }

  @override
  Future<T> runTransaction<T>(
    Future<T> Function(FirestoreTransaction tx) action,
  ) async {
    return action(_FakeFirestoreTransaction(this));
  }

  @override
  String newDocumentId(String collectionPath) => 'auto-${++_autoId}';
}

class _FakeFirestoreTransaction implements FirestoreTransaction {
  _FakeFirestoreTransaction(this.transport);

  final _FakeFirestoreTransport transport;

  @override
  Future<Map<String, dynamic>?> get(String path) => transport.getDocument(path);

  @override
  void set(String path, Map<String, dynamic> data, {bool merge = false}) {
    // Fire-and-forget is fine for the fake: the repo tests never
    // transact, this only satisfies the interface.
    unawaited(transport.setDocument(path, data, merge: merge));
  }

  @override
  void update(String path, Map<String, dynamic> data) {
    unawaited(transport.updateDocument(path, data));
  }
}
