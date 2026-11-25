import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/data/report_counters.dart';
import '../../core/services/branch_context.dart';
import '../../core/services/repositories.dart';
import '../../models/customer_ledger.dart';
import '../../models/expense.dart';
import 'analytics_logic.dart';
import 'reports_logic.dart';

/// Day 7 reports state.
///
/// The report set for a (branch, window) pair, computed from the
/// repositories on demand. The family argument is `(branchId, days)`:
/// `branchId == null` means all branches; `days` is 1, 7 or 30.
/// Invalidating re-runs the computation (retry button, or after a
/// sale / receive that changes the figures).
final reportDataProvider =
    FutureProvider.family<ReportData, (String?, int)>((ref, args) async {
      final (branchId, days) = args;
      final orders = await ref.read(orderRepositoryProvider).getOrders();
      final sales = await ref.read(saleRepositoryProvider).getSales();
      final inventory = await ref
          .read(inventoryRepositoryProvider)
          .getInventory();
      final medicines = await ref
          .read(medicineRepositoryProvider)
          .getMedicines();
      return computeReports(
        orders: orders,
        sales: sales,
        inventory: inventory,
        medicinesById: {for (final m in medicines) m.id: m},
        branchId: branchId,
        now: DateTime.now(),
        days: days,
      );
    });

/// Week 2 Day 5 advanced analytics, computed alongside the Day 7
/// report set for the same (branch, window) pair: sales trend
/// (daily + weekly), branch comparison, slow movers, expiry loss,
/// profit & loss, and the expense list behind the P&L. Same family
/// argument as [reportDataProvider]; invalidated by the same
/// writes (sales, receiving, expenses, supplier payments) plus the
/// finance notifiers.
class AdvancedReportData {
  const AdvancedReportData({
    required this.weeklyTrend,
    required this.branchComparison,
    required this.slowMovers,
    required this.expiryLoss,
    required this.profitLoss,
    required this.expenses,
    this.countersUsed = false,
    this.counterDays = 0,
  });

  /// Weekly sales trend (oldest → newest), grouped from the daily
  /// series.
  final List<WeeklyTrendPoint> weeklyTrend;

  /// One row per demo branch (sales, profit, stock value,
  /// outstanding, expiry loss). Scoped to the selected branch
  /// when the report is branch-filtered — the other rows are
  /// omitted, not zeroed.
  final List<BranchAnalyticsRow> branchComparison;

  /// Medicines with stock on hand that sold nothing in the window.
  final List<SlowMover> slowMovers;

  /// Value of expired stock at cost.
  final ExpiryLoss expiryLoss;

  /// Profit & loss for the window.
  final ProfitLoss profitLoss;

  /// Expenses recorded in the window (newest first) — the detail
  /// behind the P&L's expense line.
  final List<Expense> expenses;

  /// True when the weekly trend, branch comparison and P&L revenue /
  /// COGS were read from the pre-aggregated daily counters (Week 3
  /// Day 3, D106) instead of computed live. False means no counter
  /// covered the whole window and every figure is live-computed —
  /// the screen says so, so a stale-looking figure is never
  /// mistaken for a counter-backed one.
  final bool countersUsed;

  /// How many days of the window the counters covered (== window
  /// length when [countersUsed] is true, 0 when no counter existed).
  final int counterDays;
}

final advancedReportDataProvider =
    FutureProvider.family<AdvancedReportData, (String?, int)>((
      ref,
      args,
    ) async {
      final (branchId, days) = args;
      final orders = await ref.read(orderRepositoryProvider).getOrders();
      final sales = await ref.read(saleRepositoryProvider).getSales();
      final returns = await ref
          .read(saleReturnRepositoryProvider)
          .getReturns();
      final inventory = await ref
          .read(inventoryRepositoryProvider)
          .getInventory();
      final medicines = await ref
          .read(medicineRepositoryProvider)
          .getMedicines();
      final expenses = await ref
          .read(expenseRepositoryProvider)
          .getExpenses();
      final transactions = await ref
          .read(financialTransactionRepositoryProvider)
          .getTransactions();
      final customers = await ref
          .read(customerRepositoryProvider)
          .getCustomers();
      final ledgers = <LedgerEntry>[];
      for (final customer in customers) {
        ledgers.addAll(
          await ref
              .read(customerRepositoryProvider)
              .getLedgerEntries(customer.id),
        );
      }
      final now = DateTime.now();
      final medicinesById = {for (final m in medicines) m.id: m};
      final base = computeReports(
        orders: orders,
        sales: sales,
        inventory: inventory,
        medicinesById: medicinesById,
        branchId: branchId,
        now: now,
        days: days,
      );
      final windowStart = DateTime(
        now.year,
        now.month,
        now.day,
      ).subtract(Duration(days: days - 1));
      final windowExpenses = expenses.where((expense) {
        if (branchId != null && expense.branchId != branchId) {
          return false;
        }
        final day = DateTime(
          expense.expenseDate.year,
          expense.expenseDate.month,
          expense.expenseDate.day,
        );
        return !day.isBefore(windowStart) &&
            !day.isAfter(DateTime(now.year, now.month, now.day));
      }).toList()
        ..sort((a, b) => b.expenseDate.compareTo(a.expenseDate));
      final branches = demoBranches
          .where(
            (branch) => branchId == null || branch.id == branchId,
          )
          .map((branch) => (id: branch.id, name: branch.name))
          .toList();
      // Counters first (Week 3 Day 3, D106): when the daily rollup
      // counters cover EVERY day of the window for EVERY branch in
      // scope, the weekly trend, branch comparison sales/profit and
      // P&L revenue/COGS come from the counters. Anything short of
      // full coverage falls back to the live computation for the
      // whole window — a partial counter set is never mixed with
      // live figures (the two would double-count or disagree).
      // Stock value, outstanding, expiry loss, slow movers and
      // expenses always stay live — no counter covers them.
      final counterCoverage = await _counterCoverage(
        ref,
        branches: branches,
        days: days,
        now: now,
      );
      final weeklyTrend = counterCoverage == null
          ? computeWeeklyTrend(base.dailySales)
          : weeklyTrendFromCounters(counterCoverage.counters);
      final liveComparison = computeBranchAnalytics(
        orders: orders,
        sales: sales,
        returns: returns,
        inventory: inventory,
        ledgers: ledgers,
        branches: branches,
        medicinesById: medicinesById,
        now: now,
        days: days,
      );
      final branchComparison = counterCoverage == null
          ? liveComparison
          : [
              for (final row in liveComparison)
                row.copyWith(
                  salesMinor: counterCoverage.salesByBranch[row.branchId] ?? 0,
                  grossProfitMinor:
                      counterCoverage.profitByBranch[row.branchId] ?? 0,
                ),
            ];
      final liveProfitLoss = computeProfitAndLoss(
        orders: orders,
        sales: sales,
        returns: returns,
        inventory: inventory,
        expenses: expenses,
        transactions: transactions,
        medicinesById: medicinesById,
        branchId: branchId,
        now: now,
        days: days,
      );
      final profitLoss = counterCoverage == null
          ? liveProfitLoss
          : liveProfitLoss.copyWith(
              revenueMinor: counterCoverage.totalSalesMinor,
              cogsMinor: counterCoverage.totalCogsMinor,
            );
      return AdvancedReportData(
        weeklyTrend: weeklyTrend,
        branchComparison: branchComparison,
        slowMovers: computeSlowMovers(
          orders: orders,
          sales: sales,
          inventory: inventory,
          medicinesById: medicinesById,
          branchId: branchId,
          now: now,
          days: days,
        ),
        expiryLoss: computeExpiryLoss(
          inventory: inventory,
          branchId: branchId,
          now: now,
        ),
        profitLoss: profitLoss,
        expenses: windowExpenses,
        countersUsed: counterCoverage != null,
        counterDays: counterCoverage == null ? 0 : days,
      );
    });

/// Full counter coverage for a window, or `null` when any day or
/// branch is missing a rollup doc (D106 — the caller falls back to
/// the live computation instead of mixing).
class _CounterCoverage {
  const _CounterCoverage({
    required this.counters,
    required this.salesByBranch,
    required this.profitByBranch,
    required this.totalSalesMinor,
    required this.totalCogsMinor,
  });

  /// Every daily counter in the window, all branches in scope.
  final List<DailyCounter> counters;

  /// Windowed sales per branch (counter-backed).
  final Map<String, int> salesByBranch;

  /// Windowed gross profit per branch (counter-backed).
  final Map<String, int> profitByBranch;

  /// Windowed sales across the scope (counter-backed).
  final int totalSalesMinor;

  /// Windowed COGS across the scope (counter-backed).
  final int totalCogsMinor;
}

Future<_CounterCoverage?> _counterCoverage(
  Ref ref, {
  required List<({String id, String name})> branches,
  required int days,
  required DateTime now,
}) async {
  final today = DateTime(now.year, now.month, now.day);
  final start = today.subtract(Duration(days: days - 1));
  final repo = ref.read(reportCounterRepositoryProvider);
  final all = <DailyCounter>[];
  for (final branch in branches) {
    final counters = await repo.getDailyCounters(
      branchId: branch.id,
      start: start,
      end: today,
    );
    // Full coverage means one counter per day — a missing day is a
    // day the rollup has not run for yet, not a zero day.
    if (counters.length != days) return null;
    all.addAll(counters);
  }
  final salesByBranch = <String, int>{};
  final profitByBranch = <String, int>{};
  var totalSales = 0;
  var totalCogs = 0;
  for (final counter in all) {
    salesByBranch[counter.branchId] =
        (salesByBranch[counter.branchId] ?? 0) + counter.salesTotalMinor;
    profitByBranch[counter.branchId] =
        (profitByBranch[counter.branchId] ?? 0) + counter.grossProfitMinor;
    totalSales += counter.salesTotalMinor;
    totalCogs += counter.cogsMinor;
  }
  return _CounterCoverage(
    counters: all,
    salesByBranch: salesByBranch,
    profitByBranch: profitByBranch,
    totalSalesMinor: totalSales,
    totalCogsMinor: totalCogs,
  );
}
