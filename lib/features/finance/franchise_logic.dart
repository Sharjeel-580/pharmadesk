import '../../core/data/auth_repository.dart';
import '../../core/data/permission_service.dart';
import '../../core/utils/money.dart';
import '../../models/branch.dart';
import '../../models/order.dart';
import '../../models/sale.dart';
import '../../models/sale_return.dart';

/// Franchise commission / royalty tracking (Week 5 Day 5, D158 —
/// SRS D-28 / FR-HO-07, P3, Phase 2 prep).
///
/// Schema + head-office view only: the [Branch] model already
/// carries the nullable `franchiseFeeRateBps` / `royaltyRateBps`
/// (D130) and the branch detail screen is where terms are set —
/// this file only COMPUTES what is due from those rates and the
/// branch's sales. No franchise onboarding flow lives here (that is
/// Phase 2 business scope, not V1), and nothing here writes a rate.
///
/// All money is int paisa, never floats (D6). Rates are basis
/// points (1% = 100), like every other rate in the codebase.

/// Branch sales for a period (int paisa): POS sales + non-cancelled
/// order totals − sale-return refunds, branch-scoped, over the
/// inclusive day window [start]..[end].
///
/// This is deliberately the SAME revenue base as the P&L
/// ([computeProfitAndLoss] in the reports analytics — POS
/// `totalMinor` + `rupeesToMinorUnits(order.totalAmount)` for
/// non-cancelled orders − `refundedAmountMinor`), so a royalty
/// figure can never diverge from the revenue the Statements screen
/// shows for the same branch and window: the royalty base IS the
/// P&L revenue. Order totals convert at the boundary (D6); the
/// P&L's order-discount handling is mirrored exactly (no separate
/// discount subtraction).
///
/// A period where refunds exceed sales counts as zero sales — a
/// royalty base is never negative.
int branchSalesMinor({
  required List<Sale> sales,
  required List<Order> orders,
  required List<SaleReturn> returns,
  required String branchId,
  required DateTime start,
  required DateTime end,
}) {
  final startDay = DateTime(start.year, start.month, start.day);
  final endDay = DateTime(end.year, end.month, end.day);
  bool inWindow(DateTime? created) {
    if (created == null) return false;
    final day = DateTime(created.year, created.month, created.day);
    return !day.isBefore(startDay) && !day.isAfter(endDay);
  }

  var total = 0;
  for (final sale in sales) {
    if (sale.branchId != branchId) continue;
    if (!inWindow(sale.createdAt)) continue;
    total += sale.totalMinor;
  }
  for (final order in orders) {
    if (order.branchId != branchId) continue;
    if (order.status == OrderStatus.cancelled) continue;
    if (!inWindow(order.createdAt)) continue;
    total += rupeesToMinorUnits(order.totalAmount);
  }
  for (final ret in returns) {
    if (ret.branchId != branchId) continue;
    if (!inWindow(ret.createdAt)) continue;
    total -= ret.refundedAmountMinor;
  }
  return total < 0 ? 0 : total;
}

/// The amount due at [rateBps] on [salesMinor] (int paisa), or
/// `null` when the rate was never configured.
///
/// `null` means "Not set" (D130) — never 0: an unconfigured rate
/// owes nothing AND shows as unconfigured, while an explicitly
/// configured 0% rate owes exactly 0 and shows as 0%. The
/// division truncates any sub-paisa remainder (`~/`): a due is
/// never rounded UP, so the house never overcharges a franchise
/// by a fraction of a paisa. Rates arrive validated (0–10000 bps)
/// from the branch form ([validateBranchForm]).
int? rateDueMinor({required int salesMinor, required int? rateBps}) {
  if (rateBps == null) return null;
  return salesMinor * rateBps ~/ 10000;
}

/// One branch's royalty / franchise-fee row for a period.
class FranchiseRoyaltyRow {
  const FranchiseRoyaltyRow({
    required this.branch,
    required this.salesMinor,
    this.royaltyDueMinor,
    this.franchiseFeeDueMinor,
  });

  /// The branch this row is for (own or franchise, active or not —
  /// a deactivated branch keeps its history, FR-HO-08, so its
  /// period sales still count here; it just cannot transact going
  /// forward).
  final Branch branch;

  /// Branch sales in the period (int paisa, see [branchSalesMinor]).
  final int salesMinor;

  /// Royalty due at the branch's `royaltyRateBps`, or `null` when
  /// the rate was never configured ("Not set").
  final int? royaltyDueMinor;

  /// Franchise fee due at the branch's `franchiseFeeRateBps`, or
  /// `null` when the rate was never configured ("Not set").
  final int? franchiseFeeDueMinor;

  /// True when at least one of the two rates is configured.
  bool get hasConfiguredRates =>
      royaltyDueMinor != null || franchiseFeeDueMinor != null;

  /// What the branch owes in total for the period: the configured
  /// dues summed, unconfigured rates contributing nothing.
  int get totalDueMinor =>
      (royaltyDueMinor ?? 0) + (franchiseFeeDueMinor ?? 0);
}

/// One royalty row per branch, in directory order — including own
/// branches (their sales show, both rates "Not set", due Rs 0.00)
/// and branches with no sales in the period (sales Rs 0.00, dues
/// 0 / "Not set" per rate). Nothing is invented: a row with no
/// configured rate shows "Not set", never a made-up percentage.
List<FranchiseRoyaltyRow> computeFranchiseRoyalties({
  required List<Branch> branches,
  required List<Sale> sales,
  required List<Order> orders,
  required List<SaleReturn> returns,
  required DateTime start,
  required DateTime end,
}) {
  final rows = <FranchiseRoyaltyRow>[];
  for (final branch in branches) {
    final salesMinor = branchSalesMinor(
      sales: sales,
      orders: orders,
      returns: returns,
      branchId: branch.id,
      start: start,
      end: end,
    );
    rows.add(
      FranchiseRoyaltyRow(
        branch: branch,
        salesMinor: salesMinor,
        royaltyDueMinor: rateDueMinor(
          salesMinor: salesMinor,
          rateBps: branch.royaltyRateBps,
        ),
        franchiseFeeDueMinor: rateDueMinor(
          salesMinor: salesMinor,
          rateBps: branch.franchiseFeeRateBps,
        ),
      ),
    );
  }
  return rows;
}

/// The first day of a trailing-[days]-day window ending today
/// (same convention as the P&L: the window is the last [days]
/// days, today included).
DateTime franchiseWindowStart({required int days, DateTime? now}) {
  final reference = now ?? DateTime.now();
  final today = DateTime(reference.year, reference.month, reference.day);
  return today.subtract(Duration(days: days - 1));
}

/// True when [user] may view franchise royalty figures in
/// [branchId] (D159 — head-office only).
///
/// The gate is the EXISTING §5.1 `branches` capability ("Manage
/// branches / franchises") at WRITE level: Super Admin / Owner /
/// HO Admin hold it, everyone else does not — and the Auditor,
/// who is `readOnly` on `branches`, is excluded here. Royalty
/// figures are head-office financials, not branch reference data,
/// so unlike the Branch Management screens (where read-only
/// viewing is allowed) this view needs more than a view pass. A
/// signed-out user (`null`) passes, like every other permission
/// check — the router's auth redirect is the signed-out guard.
/// No new capability is invented: the matrix stays the authority.
bool canViewFranchiseRoyalties(AppUser? user, String branchId) =>
    permissionService.canWrite(user, 'branches', branchId);

/// Display label for a royalty / fee due: the formatted amount
/// when configured, "Not set" when the rate was never configured
/// (D130 — the same "Not set, never 0%" rule as the rate label).
String franchiseDueLabel(int? dueMinor) =>
    dueMinor == null ? 'Not set' : formatPkr(dueMinor);
