import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/repositories.dart';
import '../branches/branch_directory.dart';
import 'franchise_logic.dart';

/// Head-office franchise royalty report (Week 5 Day 5, D158/D159
/// — SRS D-28 / FR-HO-07).
///
/// One report per window ([days] = 7 / 30 / 90, same windows as
/// the Statements screen): every branch in the directory with its
/// period sales and the royalty / franchise-fee due at its
/// configured rates. The sales come from the live repos (POS sales
/// + orders − returns), so the report always agrees with the P&L
/// revenue for the same window — there is no second sales figure
/// to drift. Read-only: nothing here writes a rate (terms are set
/// in Branch Management → branch detail → Franchise settings).
class FranchiseRoyaltyReport {
  const FranchiseRoyaltyReport({
    required this.days,
    required this.start,
    required this.end,
    required this.rows,
  });

  /// Window length in days (7 / 30 / 90).
  final int days;

  /// First day of the window (inclusive).
  final DateTime start;

  /// Last day of the window (today, inclusive).
  final DateTime end;

  /// One row per branch, in directory order.
  final List<FranchiseRoyaltyRow> rows;

  /// Total branch sales in the period, all branches (int paisa).
  int get totalSalesMinor =>
      rows.fold(0, (sum, row) => sum + row.salesMinor);

  /// Total royalty due in the period, all branches (int paisa).
  int get totalRoyaltyDueMinor =>
      rows.fold(0, (sum, row) => sum + (row.royaltyDueMinor ?? 0));

  /// Total franchise fees due in the period, all branches.
  int get totalFranchiseFeeDueMinor =>
      rows.fold(0, (sum, row) => sum + (row.franchiseFeeDueMinor ?? 0));

  /// Total commission due in the period, all branches.
  int get totalDueMinor =>
      rows.fold(0, (sum, row) => sum + row.totalDueMinor);

  /// Branches with at least one rate configured.
  int get configuredBranchCount =>
      rows.where((row) => row.hasConfiguredRates).length;
}

/// The royalty report for the trailing-[days]-day window ending
/// today. Reads the branch directory + the three sales repos
/// fresh on every evaluation (same shape as the reports
/// providers); invalidating re-runs the computation.
final franchiseRoyaltiesProvider =
    FutureProvider.family<FranchiseRoyaltyReport, int>((ref, days) async {
      final branches = ref.watch(branchDirectoryProvider);
      final sales = await ref.read(saleRepositoryProvider).getSales();
      final orders = await ref.read(orderRepositoryProvider).getOrders();
      final returns = await ref
          .read(saleReturnRepositoryProvider)
          .getReturns();
      final now = DateTime.now();
      final end = DateTime(now.year, now.month, now.day);
      final start = franchiseWindowStart(days: days, now: now);
      return FranchiseRoyaltyReport(
        days: days,
        start: start,
        end: end,
        rows: computeFranchiseRoyalties(
          branches: branches,
          sales: sales,
          orders: orders,
          returns: returns,
          start: start,
          end: end,
        ),
      );
    });
