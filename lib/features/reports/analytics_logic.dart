import '../../core/utils/money.dart';
import '../../models/customer_ledger.dart';
import '../../models/expense.dart';
import '../../models/financial_transaction.dart';
import '../../models/inventory_item.dart';
import '../../models/medicine.dart';
import '../../models/order.dart';
import '../../models/sale.dart';
import '../../models/sale_return.dart';
import 'reports_logic.dart';

/// Week 2 Day 5 advanced analytics — pure computation over
/// repository data (SRS FR-REP-01, FR-HO-05).
///
/// Sales trend (daily + weekly), branch comparison, top sellers +
/// slow movers, expiry-loss, and profit & loss. All money is int
/// paisa. The P&L deliberately reuses the Day 4 gross-profit cost
/// rule (D81): POS sale cost comes from the sold batch's `costMinor`
/// (fallback medicine `purchasePriceMinor`, else 0); order cost
/// uses `purchasePriceMinor` (orders carry no batch costs).

/// Profit & loss for a window (branch-scoped or org-wide).
class ProfitLoss {
  const ProfitLoss({
    required this.revenueMinor,
    required this.cogsMinor,
    required this.grossProfitMinor,
    required this.otherIncomeMinor,
    required this.expensesMinor,
    required this.netProfitMinor,
  });

  /// Sales revenue in the window (orders + POS sales, refunds
  /// subtracted).
  final int revenueMinor;

  /// Cost of goods sold in the window.
  final int cogsMinor;

  /// `revenue − COGS`.
  final int grossProfitMinor;

  /// Other income in the window (`financialTransactions` of type
  /// `income` — money in that is not a sale).
  final int otherIncomeMinor;

  /// Operating expenses in the window (`expenses` collection).
  final int expensesMinor;

  /// `gross profit + other income − expenses`.
  final int netProfitMinor;
}

/// Computes the P&L for [branchId] (`null` = all branches) over
/// the last [days] days ending today.
ProfitLoss computeProfitAndLoss({
  required List<Order> orders,
  required List<Sale> sales,
  required List<SaleReturn> returns,
  required List<InventoryItem> inventory,
  required List<Expense> expenses,
  required List<FinancialTransaction> transactions,
  Map<String, Medicine> medicinesById = const {},
  String? branchId,
  required DateTime now,
  int days = 30,
}) {
  final today = DateTime(now.year, now.month, now.day);
  final windowStart = today.subtract(Duration(days: days - 1));
  bool inWindow(DateTime? created) {
    if (created == null) return false;
    final day = DateTime(created.year, created.month, created.day);
    return !day.isBefore(windowStart) && !day.isAfter(today);
  }

  bool inScope(String itemBranchId) =>
      branchId == null || itemBranchId == branchId;

  final batchesById = {for (final item in inventory) item.id: item};

  int unitCostMinor({required String medicineId, String? batchId}) {
    final batch = batchId == null ? null : batchesById[batchId];
    if (batch != null) return batch.costMinor;
    return medicinesById[medicineId]?.purchasePriceMinor ?? 0;
  }

  var revenue = 0;
  var cogs = 0;
  for (final order in orders) {
    if (!inScope(order.branchId)) continue;
    if (order.status == OrderStatus.cancelled) continue;
    if (!inWindow(order.createdAt)) continue;
    revenue += rupeesToMinorUnits(order.totalAmount);
    for (final item in order.items) {
      cogs +=
          unitCostMinor(medicineId: item.medicineId) * item.quantity;
    }
  }
  for (final sale in sales) {
    if (!inScope(sale.branchId)) continue;
    if (!inWindow(sale.createdAt)) continue;
    revenue += sale.totalMinor;
    for (final item in sale.items) {
      cogs +=
          unitCostMinor(
            medicineId: item.medicineId,
            batchId: item.batchId,
          ) *
          item.quantity;
    }
  }
  // Refunds reduce revenue (a returned sale is not revenue kept).
  // A refund's COGS is not clawed back here: the restocked units
  // return to sellable stock, so their cost is not "spent" — the
  // revenue subtraction alone is the honest treatment, matching
  // the Day 4 dashboard rule (D81).
  for (final ret in returns) {
    if (!inScope(ret.branchId)) continue;
    if (!inWindow(ret.createdAt)) continue;
    revenue -= ret.refundedAmountMinor;
  }

  var expensesTotal = 0;
  for (final expense in expenses) {
    if (!inScope(expense.branchId)) continue;
    if (!inWindow(expense.expenseDate)) continue;
    expensesTotal += expense.amountMinor;
  }
  var otherIncome = 0;
  for (final txn in transactions) {
    if (!inScope(txn.branchId)) continue;
    if (txn.type != FinancialTransactionType.income) continue;
    if (!inWindow(txn.createdAt)) continue;
    otherIncome += txn.amountMinor;
  }

  final grossProfit = revenue - cogs;
  return ProfitLoss(
    revenueMinor: revenue,
    cogsMinor: cogs,
    grossProfitMinor: grossProfit,
    otherIncomeMinor: otherIncome,
    expensesMinor: expensesTotal,
    netProfitMinor: grossProfit + otherIncome - expensesTotal,
  );
}

/// One week of the sales trend (oldest → newest).
class WeeklyTrendPoint {
  const WeeklyTrendPoint({
    required this.weekStart,
    required this.salesMinor,
    required this.orders,
  });

  /// First day of the 7-day bucket.
  final DateTime weekStart;
  final int salesMinor;
  final int orders;
}

/// Groups a daily series (oldest → newest, as [ReportData.dailySales]
/// produces) into 7-day buckets, oldest first. A trailing partial
/// week is kept as its own bucket.
List<WeeklyTrendPoint> computeWeeklyTrend(List<ReportDay> daily) {
  final weeks = <WeeklyTrendPoint>[];
  for (var i = 0; i < daily.length; i += 7) {
    final chunk = daily.skip(i).take(7).toList();
    weeks.add(
      WeeklyTrendPoint(
        weekStart: chunk.first.date,
        salesMinor: chunk.fold(0, (sum, day) => sum + day.salesMinor),
        orders: chunk.fold(0, (sum, day) => sum + day.orders),
      ),
    );
  }
  return weeks;
}

/// One slow mover: stock on hand that did not sell in the window.
class SlowMover {
  const SlowMover({
    required this.medicineId,
    required this.medicineName,
    required this.quantitySold,
    required this.quantityOnHand,
    required this.stockValueMinor,
  });

  final String medicineId;
  final String medicineName;

  /// Units sold in the window (zero for a true slow mover).
  final int quantitySold;

  /// Units on hand across all batches at the branch scope.
  final int quantityOnHand;

  /// Value of the stock on hand at cost (int paisa).
  final int stockValueMinor;
}

/// Slow movers over the window: medicines with stock on hand that
/// sold nothing in the window, worst (most stock value tied up)
/// first, top 10. A medicine with no stock at all is not a slow
/// mover — it is out of stock, which the low-stock report covers.
List<SlowMover> computeSlowMovers({
  required List<Order> orders,
  required List<Sale> sales,
  required List<InventoryItem> inventory,
  Map<String, Medicine> medicinesById = const {},
  String? branchId,
  required DateTime now,
  int days = 30,
}) {
  final today = DateTime(now.year, now.month, now.day);
  final windowStart = today.subtract(Duration(days: days - 1));
  bool inWindow(DateTime? created) {
    if (created == null) return false;
    final day = DateTime(created.year, created.month, created.day);
    return !day.isBefore(windowStart) && !day.isAfter(today);
  }

  bool inScope(String itemBranchId) =>
      branchId == null || itemBranchId == branchId;

  final sold = <String, int>{};
  for (final order in orders) {
    if (!inScope(order.branchId)) continue;
    if (order.status == OrderStatus.cancelled) continue;
    if (!inWindow(order.createdAt)) continue;
    for (final item in order.items) {
      sold[item.medicineId] = (sold[item.medicineId] ?? 0) + item.quantity;
    }
  }
  for (final sale in sales) {
    if (!inScope(sale.branchId)) continue;
    if (!inWindow(sale.createdAt)) continue;
    for (final item in sale.items) {
      sold[item.medicineId] = (sold[item.medicineId] ?? 0) + item.quantity;
    }
  }

  final onHand = <String, ({int qty, int value})>{};
  for (final item in inventory) {
    if (!inScope(item.branchId)) continue;
    final entry = onHand[item.medicineId];
    onHand[item.medicineId] = (
      qty: (entry?.qty ?? 0) + item.quantity,
      value: (entry?.value ?? 0) + item.quantity * item.costMinor,
    );
  }

  final movers = <SlowMover>[];
  for (final entry in onHand.entries) {
    if (entry.value.qty <= 0) continue;
    if ((sold[entry.key] ?? 0) > 0) continue;
    movers.add(
      SlowMover(
        medicineId: entry.key,
        medicineName: medicinesById[entry.key]?.name ?? entry.key,
        quantitySold: 0,
        quantityOnHand: entry.value.qty,
        stockValueMinor: entry.value.value,
      ),
    );
  }
  movers.sort((a, b) => b.stockValueMinor.compareTo(a.stockValueMinor));
  return movers.take(10).toList();
}

/// Value of expired stock (SRS FR-REP-01 "expiry-loss" report).
class ExpiryLoss {
  const ExpiryLoss({
    required this.lossMinor,
    required this.batches,
    required this.units,
  });

  /// Value at cost price of expired batches (int paisa).
  final int lossMinor;

  /// Number of expired batch rows.
  final int batches;

  /// Units sitting in expired batches.
  final int units;
}

/// Sums the cost value of batches whose expiry day is before today.
/// Quarantined / returned batches are excluded only when they hold
/// no stock — the loss is the stock that cannot be sold, priced at
/// the batch's recorded cost (the same valuation the stock report
/// uses).
ExpiryLoss computeExpiryLoss({
  required List<InventoryItem> inventory,
  String? branchId,
  required DateTime now,
}) {
  final today = DateTime(now.year, now.month, now.day);
  var loss = 0;
  var batches = 0;
  var units = 0;
  for (final item in inventory) {
    if (branchId != null && item.branchId != branchId) continue;
    final expiry = item.expiryDate;
    if (expiry == null) continue;
    final expiryDay = DateTime(expiry.year, expiry.month, expiry.day);
    if (!expiryDay.isBefore(today)) continue;
    if (item.quantity <= 0) continue;
    loss += item.quantity * item.costMinor;
    batches++;
    units += item.quantity;
  }
  return ExpiryLoss(lossMinor: loss, batches: batches, units: units);
}

/// One branch's row in the branch-comparison report (SRS FR-HO-05).
class BranchAnalyticsRow {
  const BranchAnalyticsRow({
    required this.branchId,
    required this.branchName,
    required this.salesMinor,
    required this.grossProfitMinor,
    required this.stockValueMinor,
    required this.outstandingMinor,
    required this.expiryLossMinor,
  });

  final String branchId;
  final String branchName;

  /// Sales in the window (orders + POS sales, refunds subtracted).
  final int salesMinor;

  /// Windowed gross profit (revenue − COGS, D81 cost rule).
  final int grossProfitMinor;

  /// Stock on hand valued at cost.
  final int stockValueMinor;

  /// Outstanding khata for the branch (D79 attribution: only
  /// ledger entries whose `referenceId` is one of this branch's
  /// credit sales; manual entries are unattributed and count only
  /// in the org-wide total).
  final int outstandingMinor;

  /// Value of expired stock at cost.
  final int expiryLossMinor;
}

/// Branch comparison over the window: sales, profit, stock value,
/// outstanding and expiry loss per branch. [branchNames] maps branch
/// ids to display names; [ledgers] are all customer khata entries
/// (the D79 attribution needs the sale → branch link).
List<BranchAnalyticsRow> computeBranchAnalytics({
  required List<Order> orders,
  required List<Sale> sales,
  required List<SaleReturn> returns,
  required List<InventoryItem> inventory,
  required List<LedgerEntry> ledgers,
  required List<({String id, String name})> branches,
  Map<String, Medicine> medicinesById = const {},
  required DateTime now,
  int days = 30,
}) {
  final today = DateTime(now.year, now.month, now.day);
  final windowStart = today.subtract(Duration(days: days - 1));
  bool inWindow(DateTime? created) {
    if (created == null) return false;
    final day = DateTime(created.year, created.month, created.day);
    return !day.isBefore(windowStart) && !day.isAfter(today);
  }

  final saleBranchById = {
    for (final sale in sales) sale.id: sale.branchId,
  };
  final batchesById = {for (final item in inventory) item.id: item};
  int unitCostMinor({required String medicineId, String? batchId}) {
    final batch = batchId == null ? null : batchesById[batchId];
    if (batch != null) return batch.costMinor;
    return medicinesById[medicineId]?.purchasePriceMinor ?? 0;
  }

  final rows = <BranchAnalyticsRow>[];
  for (final branch in branches) {
    var revenue = 0;
    var cogs = 0;
    for (final order in orders) {
      if (order.branchId != branch.id) continue;
      if (order.status == OrderStatus.cancelled) continue;
      if (!inWindow(order.createdAt)) continue;
      revenue += rupeesToMinorUnits(order.totalAmount);
      for (final item in order.items) {
        cogs +=
            unitCostMinor(medicineId: item.medicineId) * item.quantity;
      }
    }
    for (final sale in sales) {
      if (sale.branchId != branch.id) continue;
      if (!inWindow(sale.createdAt)) continue;
      revenue += sale.totalMinor;
      for (final item in sale.items) {
        cogs +=
            unitCostMinor(
              medicineId: item.medicineId,
              batchId: item.batchId,
            ) *
            item.quantity;
      }
    }
    for (final ret in returns) {
      if (ret.branchId != branch.id) continue;
      if (!inWindow(ret.createdAt)) continue;
      revenue -= ret.refundedAmountMinor;
    }

    var stockValue = 0;
    for (final item in inventory) {
      if (item.branchId != branch.id) continue;
      stockValue += item.quantity * item.costMinor;
    }

    var outstanding = 0;
    for (final entry in ledgers) {
      final reference = entry.referenceId;
      if (reference == null) continue;
      if (saleBranchById[reference] != branch.id) continue;
      outstanding += entry.amountMinor;
    }

    final expiryLoss = computeExpiryLoss(
      inventory: inventory,
      branchId: branch.id,
      now: now,
    );
    rows.add(
      BranchAnalyticsRow(
        branchId: branch.id,
        branchName: branch.name,
        salesMinor: revenue,
        grossProfitMinor: revenue - cogs,
        stockValueMinor: stockValue,
        outstandingMinor: outstanding,
        expiryLossMinor: expiryLoss.lossMinor,
      ),
    );
  }
  return rows;
}

// --- CSV export (FR-REP-05, same escaping as `reports_logic.dart`) ---

String _csvRow(List<Object?> cells) {
  String escape(Object? value) {
    final text = value == null ? '' : value.toString();
    if (text.contains(',') ||
        text.contains('"') ||
        text.contains('\n')) {
      return '"${text.replaceAll('"', '""')}"';
    }
    return text;
  }

  return cells.map(escape).join(',');
}

String _dateText(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

String weeklyTrendCsv(List<WeeklyTrendPoint> weeks) {
  final buffer = StringBuffer()
    ..writeln('Week starting,Orders,Sales (Rs)');
  for (final week in weeks) {
    buffer.writeln(
      _csvRow([
        _dateText(week.weekStart),
        week.orders,
        (week.salesMinor / 100).toStringAsFixed(2),
      ]),
    );
  }
  return buffer.toString();
}

String branchComparisonCsv(List<BranchAnalyticsRow> rows) {
  final buffer = StringBuffer()
    ..writeln(
      'Branch,Sales (Rs),Gross profit (Rs),Stock value (Rs),'
      'Outstanding khata (Rs),Expiry loss (Rs)',
    );
  for (final row in rows) {
    buffer.writeln(
      _csvRow([
        row.branchName,
        (row.salesMinor / 100).toStringAsFixed(2),
        (row.grossProfitMinor / 100).toStringAsFixed(2),
        (row.stockValueMinor / 100).toStringAsFixed(2),
        (row.outstandingMinor / 100).toStringAsFixed(2),
        (row.expiryLossMinor / 100).toStringAsFixed(2),
      ]),
    );
  }
  return buffer.toString();
}

String slowMoversCsv(List<SlowMover> movers) {
  final buffer = StringBuffer()
    ..writeln('Medicine,Units sold,Units on hand,Stock value (Rs)');
  for (final mover in movers) {
    buffer.writeln(
      _csvRow([
        mover.medicineName,
        mover.quantitySold,
        mover.quantityOnHand,
        (mover.stockValueMinor / 100).toStringAsFixed(2),
      ]),
    );
  }
  return buffer.toString();
}

String profitLossCsv(ProfitLoss profitLoss) {
  final buffer = StringBuffer()
    ..writeln('Line,Amount (Rs)')
    ..writeln(
      _csvRow([
        'Sales revenue',
        (profitLoss.revenueMinor / 100).toStringAsFixed(2),
      ]),
    )
    ..writeln(
      _csvRow([
        'Cost of goods sold',
        (profitLoss.cogsMinor / 100).toStringAsFixed(2),
      ]),
    )
    ..writeln(
      _csvRow([
        'Gross profit',
        (profitLoss.grossProfitMinor / 100).toStringAsFixed(2),
      ]),
    )
    ..writeln(
      _csvRow([
        'Other income',
        (profitLoss.otherIncomeMinor / 100).toStringAsFixed(2),
      ]),
    )
    ..writeln(
      _csvRow([
        'Operating expenses',
        (profitLoss.expensesMinor / 100).toStringAsFixed(2),
      ]),
    )
    ..writeln(
      _csvRow([
        'Net profit',
        (profitLoss.netProfitMinor / 100).toStringAsFixed(2),
      ]),
    );
  return buffer.toString();
}

String expiryLossCsv(
  List<ReportExpiryRow> expiredRows, {
  required int totalLossMinor,
}) {
  final buffer = StringBuffer()
    ..writeln('Medicine,Batch,Expiry date,Quantity on hand')
    ..writeln(
      _csvRow([
        'TOTAL expired stock value (Rs)',
        '',
        '',
        (totalLossMinor / 100).toStringAsFixed(2),
      ]),
    );
  for (final row in expiredRows) {
    // Per-row money is not shown: the report row carries no batch
    // cost, and inventing one would be wrong. The total loss (at
    // cost, from `computeExpiryLoss`) is the summary row above.
    buffer.writeln(
      _csvRow([
        row.medicineName,
        row.batchNo ?? '',
        _dateText(row.expiryDate),
        row.quantity,
      ]),
    );
  }
  return buffer.toString();
}
