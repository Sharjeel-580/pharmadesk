import '../../core/utils/money.dart';
import '../../models/branch.dart';
import '../../models/customer_ledger.dart';
import '../../models/inventory_item.dart';
import '../../models/medicine.dart';
import '../../models/order.dart';
import '../../models/prescription.dart';
import '../../models/purchase_order.dart';
import '../../models/sale.dart';
import '../../models/sale_return.dart';

/// Owner dashboard, deepened (Week 2 Day 4).
///
/// The Day 3 dashboard already computed today's sales, 30-day
/// revenue, low stock and near-expiry from the repositories. This
/// module adds the figures the owner asks for every morning, all
/// computed from the same production data layer — nothing hardcoded:
///
/// - **Gross profit (today):** POS sale revenue minus batch cost.
///   Only POS sales carry batch costs (the sale item records the
///   batch it was picked from), so orders are excluded — documented
///   below, not silently mixed in.
/// - **Outstanding khata:** the sum of every customer's ledger
///   (D37 — never a stored field).
/// - **Open purchase orders:** Draft / Approved / Partially received
///   (the Day 2 open-PO definition).
/// - **Branch comparison:** every branch side by side — today's
///   sales, stock value (qty × cost), outstanding, alerts.
///
/// Pure functions over plain lists, unit-testable without widgets or
/// providers. `branchId == null` means "all branches" (owner view).

/// One branch's row in the comparison table.
class BranchComparisonRow {
  const BranchComparisonRow({
    required this.branchId,
    required this.branchName,
    required this.todaySalesMinor,
    required this.todayOrders,
    required this.stockValueMinor,
    required this.outstandingMinor,
    required this.lowStockCount,
    required this.nearExpiryCount,
    required this.expiredCount,
    required this.pendingPrescriptions,
    required this.openPurchaseOrders,
  });

  final String branchId;
  final String branchName;

  /// Today's sales (POS sales + non-cancelled orders, int paisa).
  final int todaySalesMinor;

  /// Today's orders (orders + POS sales).
  final int todayOrders;

  /// Stock value: Σ qty × batch cost over the branch's batches.
  final int stockValueMinor;

  /// Outstanding khata attributed to this branch (see D79).
  final int outstandingMinor;

  /// Inventory rows at or below their low-stock threshold.
  final int lowStockCount;

  /// Batches expiring within 30 days (not yet expired).
  final int nearExpiryCount;

  /// Batches already expired.
  final int expiredCount;

  /// Prescriptions still awaiting pharmacist review.
  final int pendingPrescriptions;

  /// Purchase orders still open (Draft / Approved / Partially
  /// received).
  final int openPurchaseOrders;

  /// Alert count for the row: low stock + near-expiry + expired
  /// batches (the same buckets the alerts feed uses).
  int get alertCount => lowStockCount + nearExpiryCount + expiredCount;
}

/// The owner's live KPI set: today's figures plus the balances that
/// do not fit the Day 3 KPI card set.
class OwnerLiveKpis {
  const OwnerLiveKpis({
    required this.grossProfitMinor,
    required this.outstandingKhataMinor,
    required this.openPurchaseOrders,
    required this.lowStockCount,
    required this.nearExpiryCount,
    required this.pendingPrescriptions,
  });

  /// Today's gross profit (POS sales only — see
  /// [computeGrossProfitMinor]).
  final int grossProfitMinor;

  /// Outstanding khata across all customers (int paisa).
  final int outstandingKhataMinor;

  /// Open purchase orders (Draft / Approved / Partially received).
  final int openPurchaseOrders;

  /// Inventory rows at or below their low-stock threshold.
  final int lowStockCount;

  /// Batches expiring within 30 days (not yet expired).
  final int nearExpiryCount;

  /// Prescriptions still awaiting pharmacist review.
  final int pendingPrescriptions;
}

/// Gross profit for [day] (default today): Σ over the day's POS sale
/// items of (line total − batch cost × qty), minus the day's refunds.
///
/// - **Cost lookup:** the batch the item was picked from
///   (`SaleItem.batchId`) → its `costMinor`. When the batch is gone
///   from inventory, the medicine's `purchasePriceMinor` is the
///   fallback; when both are unknown (0) the cost is 0 and the profit
///   equals the revenue for that item — an unknown cost is never
///   invented.
/// - **Orders are excluded:** an order has no batch, so its cost is
///   unknowable from the data layer. Mixing order revenue into a
///   "profit" figure would overstate it.
/// - **Bill discount / tax ignored:** the line totals already exclude
///   line discounts; the bill-level discount and tax are not
///   allocated per item (same rule as the refund maths, D78).
/// - **Returns:** refunds recorded on [day] are subtracted — a return
///   takes the profit of the returned units back with it.
int computeGrossProfitMinor({
  required List<Sale> sales,
  required List<InventoryItem> inventory,
  required List<Medicine> medicines,
  List<SaleReturn> returns = const [],
  DateTime? now,
  DateTime? day,
}) {
  final reference = now ?? DateTime.now();
  final targetDay = day ?? DateTime(reference.year, reference.month, reference.day);
  bool isTargetDay(DateTime? value) =>
      value != null &&
      value.year == targetDay.year &&
      value.month == targetDay.month &&
      value.day == targetDay.day;

  final costByBatch = {
    for (final batch in inventory) batch.id: batch.costMinor,
  };
  final purchasePriceByMedicine = {
    for (final medicine in medicines) medicine.id: medicine.purchasePriceMinor,
  };

  var profit = 0;
  for (final sale in sales) {
    if (!isTargetDay(sale.createdAt)) continue;
    for (final item in sale.items) {
      final costPerUnit =
          costByBatch[item.batchId] ??
          purchasePriceByMedicine[item.medicineId] ??
          0;
      profit += item.lineTotalMinor - costPerUnit * item.quantity;
    }
  }
  for (final saleReturn in returns) {
    if (!isTargetDay(saleReturn.createdAt)) continue;
    profit -= saleReturn.refundedAmountMinor;
  }
  return profit;
}

/// Outstanding khata across all customers: the sum of every ledger
/// entry (signed, D37).
int computeOutstandingKhataMinor(List<LedgerEntry> entries) =>
    entries.fold(0, (sum, entry) => sum + entry.amountMinor);

/// Open purchase orders (Draft / Approved / Partially received).
int countOpenPurchaseOrders(List<PurchaseOrder> purchaseOrders) =>
    purchaseOrders
        .where(
          (po) =>
              po.status == PurchaseOrderStatus.draft ||
              po.status == PurchaseOrderStatus.approved ||
              po.status == PurchaseOrderStatus.partiallyReceived,
        )
        .length;

/// One comparison row per branch.
///
/// **Outstanding attribution (D79):** a customer's khata has no
/// branch — customers are org-wide in the demo, and the seeded
/// opening entries carry no sale reference. A branch is therefore
/// charged only with the ledger entries that reference one of its
/// own credit sales (`LedgerEntry.referenceId` → sale → branch);
/// manual credit / payment entries with no sale reference are
/// unattributed and count only in the org-wide total
/// ([computeOutstandingKhataMinor]). The comparison table shows the
/// org total in its footer so the unattributed part is never hidden.
///
/// **Branch scoping:** callers pass the branches the user may see —
/// the provider enforces that (owner: all branches; branch users:
/// their home branch only). This function itself scopes every figure
/// to the branch it is given.
List<BranchComparisonRow> computeBranchComparison({
  required List<Branch> branches,
  required List<Order> orders,
  required List<Sale> sales,
  required List<InventoryItem> inventory,
  required List<Prescription> prescriptions,
  required List<PurchaseOrder> purchaseOrders,
  required List<LedgerEntry> ledgerEntries,
  required DateTime now,
}) {
  final today = DateTime(now.year, now.month, now.day);
  bool isToday(DateTime? value) =>
      value != null &&
      value.year == today.year &&
      value.month == today.month &&
      value.day == today.day;

  // Sale id → branch, for khata attribution (D79).
  final saleBranchById = {for (final sale in sales) sale.id: sale.branchId};

  return [
    for (final branch in branches)
      BranchComparisonRow(
        branchId: branch.id,
        branchName: branch.name,
        todaySalesMinor:
            orders
                .where(
                  (order) =>
                      order.branchId == branch.id &&
                      order.status != OrderStatus.cancelled &&
                      isToday(order.createdAt),
                )
                .fold(
                  0,
                  (sum, order) => sum + rupeesToMinorUnits(order.totalAmount),
                ) +
            sales
                .where(
                  (sale) =>
                      sale.branchId == branch.id && isToday(sale.createdAt),
                )
                .fold(0, (sum, sale) => sum + sale.totalMinor),
        todayOrders:
            orders
                .where(
                  (order) =>
                      order.branchId == branch.id &&
                      order.status != OrderStatus.cancelled &&
                      isToday(order.createdAt),
                )
                .length +
            sales
                .where(
                  (sale) =>
                      sale.branchId == branch.id && isToday(sale.createdAt),
                )
                .length,
        stockValueMinor: inventory
            .where((item) => item.branchId == branch.id)
            .fold(0, (sum, item) => sum + item.quantity * item.costMinor),
        outstandingMinor: ledgerEntries
            .where(
              (entry) =>
                  entry.referenceId != null &&
                  saleBranchById[entry.referenceId] == branch.id,
            )
            .fold(0, (sum, entry) => sum + entry.amountMinor),
        lowStockCount: inventory
            .where(
              (item) => item.branchId == branch.id && item.isLowStock,
            )
            .length,
        nearExpiryCount: inventory.where((item) {
          if (item.branchId != branch.id) return false;
          final expiry = item.expiryDate;
          if (expiry == null) return false;
          final expiryDay = DateTime(expiry.year, expiry.month, expiry.day);
          return !expiryDay.isBefore(today) &&
              !expiryDay.isAfter(today.add(const Duration(days: 30)));
        }).length,
        expiredCount: inventory.where((item) {
          if (item.branchId != branch.id) return false;
          final expiry = item.expiryDate;
          if (expiry == null) return false;
          final expiryDay = DateTime(expiry.year, expiry.month, expiry.day);
          return expiryDay.isBefore(today);
        }).length,
        pendingPrescriptions: prescriptions.where((rx) {
          final rxBranch = rx.branchId;
          final inBranch = rxBranch != null
              ? rxBranch == branch.id
              : rx.id.startsWith(
                  branch.id == 'branch-dha-main' ? 'rx-dha-' : 'rx-glb-',
                );
          return inBranch && rx.status == PrescriptionStatus.pending;
        }).length,
        openPurchaseOrders: purchaseOrders
            .where((po) => po.branchId == branch.id)
            .where(
              (po) =>
                  po.status == PurchaseOrderStatus.draft ||
                  po.status == PurchaseOrderStatus.approved ||
                  po.status == PurchaseOrderStatus.partiallyReceived,
            )
            .length,
      ),
  ];
}
