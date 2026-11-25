import 'package:flutter_riverpod/flutter_riverpod.dart';

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
      return AdvancedReportData(
        weeklyTrend: computeWeeklyTrend(base.dailySales),
        branchComparison: computeBranchAnalytics(
          orders: orders,
          sales: sales,
          returns: returns,
          inventory: inventory,
          ledgers: ledgers,
          branches: branches,
          medicinesById: medicinesById,
          now: now,
          days: days,
        ),
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
        profitLoss: computeProfitAndLoss(
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
        ),
        expenses: windowExpenses,
      );
    });
