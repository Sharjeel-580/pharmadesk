import '../../core/utils/money.dart';
import '../../models/inventory_item.dart';
import '../../models/medicine.dart';
import '../../models/order.dart';
import '../../models/sale.dart';
import '../../models/sale_return.dart';
import '../../features/reports/analytics_logic.dart';
import '../services/repositories.dart';
import '../utils/pagination.dart';
import 'firestore_schema.dart';

export '../utils/pagination.dart' show reportPageSize;

/// Week 3 Day 3 — pre-aggregated report counters (D105/D106).
///
/// The daily counters rollup Cloud Function (Job 3 in
/// `firebase/functions-design.md`) writes one document per branch per
/// day — `branches/{branchId}/counters/daily-{yyyy-MM-dd}` — with a
/// `value` map of that day's totals. The reports screen reads those
/// documents instead of scanning the whole sales / orders collections
/// (SRS §2.9 denormalized read models, D62 quota discipline).
///
/// This file holds the model, the pure aggregation (the same
/// computation the rollup performs — the mock repository runs it over
/// the seeded demo data, so mock counters are derived from the same
/// seed and never invented), and the repository interface with its
/// mock + Firestore implementations behind it (D75/D101 pattern).
///
/// **Cost rule (D81/D93, reused — never re-implemented):** POS sale
/// cost comes from the sold batch's `costMinor` (fallback medicine
/// `purchasePriceMinor`, else 0); order cost uses
/// `purchasePriceMinor`. Refunds reduce revenue only — COGS is not
/// clawed back, because restocked units return to sellable stock.

/// One day's pre-aggregated figures for one branch.
class DailyCounter {
  const DailyCounter({
    required this.branchId,
    required this.date,
    required this.salesTotalMinor,
    required this.salesCount,
    required this.ordersCount,
    required this.cogsMinor,
    required this.grossProfitMinor,
  });

  /// The branch this counter belongs to.
  final String branchId;

  /// The calendar day (time stripped).
  final DateTime date;

  /// Sales revenue for the day: non-cancelled orders + POS sales,
  /// refunds subtracted (int paisa).
  final int salesTotalMinor;

  /// POS sales completed that day.
  final int salesCount;

  /// Non-cancelled orders created that day.
  final int ordersCount;

  /// Cost of goods sold for the day (D81/D93 cost rule).
  final int cogsMinor;

  /// `salesTotalMinor − cogsMinor`.
  final int grossProfitMinor;

  /// `yyyy-MM-dd` key for [date].
  String get dateKey => dateKeyFor(date);

  /// The Firestore document id for [date]: `daily-{yyyy-MM-dd}`.
  String get docId => docIdFor(date);

  /// `yyyy-MM-dd` for a calendar day.
  static String dateKeyFor(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  /// The Firestore document id for a calendar day.
  static String docIdFor(DateTime date) => 'daily-${dateKeyFor(date)}';

  /// Parses a `yyyy-MM-dd` key back to a calendar day, or `null`
  /// when the key is not a valid date.
  static DateTime? dateFromKey(String key) {
    final parts = key.split('-');
    if (parts.length != 3) return null;
    final year = int.tryParse(parts[0]);
    final month = int.tryParse(parts[1]);
    final day = int.tryParse(parts[2]);
    if (year == null || month == null || day == null) return null;
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;
    return DateTime(year, month, day);
  }

  DailyCounter copyWith({
    String? branchId,
    DateTime? date,
    int? salesTotalMinor,
    int? salesCount,
    int? ordersCount,
    int? cogsMinor,
    int? grossProfitMinor,
  }) {
    return DailyCounter(
      branchId: branchId ?? this.branchId,
      date: date ?? this.date,
      salesTotalMinor: salesTotalMinor ?? this.salesTotalMinor,
      salesCount: salesCount ?? this.salesCount,
      ordersCount: ordersCount ?? this.ordersCount,
      cogsMinor: cogsMinor ?? this.cogsMinor,
      grossProfitMinor: grossProfitMinor ?? this.grossProfitMinor,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is DailyCounter &&
        other.branchId == branchId &&
        other.date == date &&
        other.salesTotalMinor == salesTotalMinor &&
        other.salesCount == salesCount &&
        other.ordersCount == ordersCount &&
        other.cogsMinor == cogsMinor &&
        other.grossProfitMinor == grossProfitMinor;
  }

  @override
  int get hashCode => Object.hash(
    branchId,
    date,
    salesTotalMinor,
    salesCount,
    ordersCount,
    cogsMinor,
    grossProfitMinor,
  );

  @override
  String toString() =>
      'DailyCounter($branchId $dateKey sales=$salesTotalMinor '
      'salesCount=$salesCount orders=$ordersCount cogs=$cogsMinor)';
}

/// Computes one [DailyCounter] per day in the window (oldest →
/// newest, one counter per day even when the day had no sales — a
/// missing day means "not rolled up yet", a zero day means "rolled
/// up, nothing sold").
///
/// This is the aggregation the rollup Function performs, written as
/// a pure function over the same inputs the live reports use
/// ([computeReports] / [computeProfitAndLoss]) — so a mock counter
/// and the live-computed figure for the same window agree exactly,
/// and the test pins that agreement instead of trusting it.
List<DailyCounter> computeDailyCounters({
  required List<Order> orders,
  required List<Sale> sales,
  required List<SaleReturn> returns,
  required List<InventoryItem> inventory,
  Map<String, Medicine> medicinesById = const {},
  required String branchId,
  required DateTime now,
  int days = 30,
}) {
  final today = DateTime(now.year, now.month, now.day);
  final windowStart = today.subtract(Duration(days: days - 1));
  bool isSameDay(DateTime? value, DateTime day) =>
      value != null &&
      value.year == day.year &&
      value.month == day.month &&
      value.day == day.day;

  final batchesById = {for (final item in inventory) item.id: item};
  int unitCostMinor({required String medicineId, String? batchId}) {
    final batch = batchId == null ? null : batchesById[batchId];
    if (batch != null) return batch.costMinor;
    return medicinesById[medicineId]?.purchasePriceMinor ?? 0;
  }

  final counters = <DailyCounter>[];
  for (var offset = days - 1; offset >= 0; offset--) {
    final day = today.subtract(Duration(days: offset));
    if (day.isBefore(windowStart)) continue;
    var revenue = 0;
    var cogs = 0;
    var salesCount = 0;
    var ordersCount = 0;
    for (final order in orders) {
      if (order.branchId != branchId) continue;
      if (order.status == OrderStatus.cancelled) continue;
      if (!isSameDay(order.createdAt, day)) continue;
      ordersCount++;
      revenue += rupeesToMinorUnits(order.totalAmount);
      for (final item in order.items) {
        cogs += unitCostMinor(medicineId: item.medicineId) * item.quantity;
      }
    }
    for (final sale in sales) {
      if (sale.branchId != branchId) continue;
      if (!isSameDay(sale.createdAt, day)) continue;
      salesCount++;
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
      if (ret.branchId != branchId) continue;
      if (!isSameDay(ret.createdAt, day)) continue;
      revenue -= ret.refundedAmountMinor;
    }
    counters.add(
      DailyCounter(
        branchId: branchId,
        date: day,
        salesTotalMinor: revenue,
        salesCount: salesCount,
        ordersCount: ordersCount,
        cogsMinor: cogs,
        grossProfitMinor: revenue - cogs,
      ),
    );
  }
  return counters;
}

/// Groups daily counters into 7-day buckets (oldest first), the
/// same bucketing [computeWeeklyTrend] applies to the live daily
/// series — so the counter-backed trend and the live trend render
/// identical rows for the same window.
///
/// Counters are grouped by calendar day FIRST: an org-wide scope
/// has one counter per branch per day, so chunking the flat list by
/// 7 would cut weeks in the middle of a day (two branches = 3.5
/// days per "week"). Grouping by day keeps one bucket per 7
/// calendar days whatever the branch scope is.
List<WeeklyTrendPoint> weeklyTrendFromCounters(
  List<DailyCounter> counters,
) {
  final byDay = <DateTime, ({int sales, int orders})>{};
  for (final counter in counters) {
    final entry = byDay[counter.date];
    byDay[counter.date] = (
      sales: (entry?.sales ?? 0) + counter.salesTotalMinor,
      orders:
          (entry?.orders ?? 0) + counter.salesCount + counter.ordersCount,
    );
  }
  final days = byDay.keys.toList()..sort();
  final weeks = <WeeklyTrendPoint>[];
  for (var i = 0; i < days.length; i += 7) {
    final chunk = days.skip(i).take(7).toList();
    weeks.add(
      WeeklyTrendPoint(
        weekStart: chunk.first,
        salesMinor: chunk.fold(0, (sum, day) => sum + byDay[day]!.sales),
        orders: chunk.fold(0, (sum, day) => sum + byDay[day]!.orders),
      ),
    );
  }
  return weeks;
}

/// One page of daily counters, in document-id order (oldest first).
class CounterPage {
  const CounterPage({
    required this.counters,
    required this.nextCursor,
    required this.hasMore,
  });

  /// Counters on this page (oldest → newest).
  final List<DailyCounter> counters;

  /// Opaque cursor for the next page (`null` when [hasMore] is
  /// false). The value is the last document id read.
  final String? nextCursor;

  /// True when another page follows.
  final bool hasMore;
}

/// Repository interface for the daily rollup counters.
///
/// The Firestore implementation reads the rollup Function's output
/// docs; the mock computes the same figures from the seeded demo
/// data ([computeDailyCounters]) — the two agree by construction,
/// and the Day 3 test pins the agreement on the seeded data.
abstract class ReportCounterRepository {
  /// One day's counter, or `null` when that day has not been rolled
  /// up yet (a missing doc is "not yet computed", never zero).
  Future<DailyCounter?> getDailyCounter({
    required String branchId,
    required DateTime date,
  });

  /// Counters for every day in [start]..[end] inclusive, oldest →
  /// newest. Days with no rollup doc are OMITTED (never zero-filled
  /// — the caller must treat a short list as incomplete coverage
  /// and fall back to the live computation, D106).
  Future<List<DailyCounter>> getDailyCounters({
    required String branchId,
    required DateTime start,
    required DateTime end,
  });

  /// Daily counters paged through the transport's paged fetch
  /// (document-id order, oldest first). Covers the last 30 days
  /// ending today; [startAfterId] is the previous page's
  /// [CounterPage.nextCursor].
  Future<CounterPage> listDailyCountersPaged({
    required String branchId,
    int pageSize = reportPageSize,
    String? startAfterId,
  });
}

/// Mock counters: computed from the same repositories the live
/// reports read, so the figures are derived from the seeded demo
/// data — never invented, never a second seed.
class MockReportCounterRepository implements ReportCounterRepository {
  MockReportCounterRepository({
    required this.orders,
    required this.sales,
    required this.returns,
    required this.inventory,
    required this.medicines,
  });

  final OrderRepository orders;
  final SaleRepository sales;
  final SaleReturnRepository returns;
  final InventoryRepository inventory;
  final MedicineRepository medicines;

  Future<List<DailyCounter>> _all({required String branchId}) async {
    final now = DateTime.now();
    return computeDailyCounters(
      orders: await orders.getOrders(branchId: branchId),
      sales: await sales.getSales(branchId: branchId),
      returns: await returns.getReturns(branchId: branchId),
      inventory: await inventory.getInventory(branchId: branchId),
      medicinesById: {
        for (final m in await medicines.getMedicines()) m.id: m,
      },
      branchId: branchId,
      now: now,
      days: 30,
    );
  }

  @override
  Future<DailyCounter?> getDailyCounter({
    required String branchId,
    required DateTime date,
  }) async {
    final day = DateTime(date.year, date.month, date.day);
    final counters = await _all(branchId: branchId);
    for (final counter in counters) {
      if (counter.date == day) return counter;
    }
    return null;
  }

  @override
  Future<List<DailyCounter>> getDailyCounters({
    required String branchId,
    required DateTime start,
    required DateTime end,
  }) async {
    final startDay = DateTime(start.year, start.month, start.day);
    final endDay = DateTime(end.year, end.month, end.day);
    final counters = await _all(branchId: branchId);
    return counters
        .where(
          (counter) =>
              !counter.date.isBefore(startDay) &&
              !counter.date.isAfter(endDay),
        )
        .toList();
  }

  @override
  Future<CounterPage> listDailyCountersPaged({
    required String branchId,
    int pageSize = reportPageSize,
    String? startAfterId,
  }) async {
    // Same page shape as the Firestore side: document-id order
    // (oldest first), cursor = last doc id read.
    final page = paginate(
      await _all(branchId: branchId),
      pageSize: pageSize,
      startAfterId: startAfterId,
      idOf: (counter) => counter.docId,
    );
    return CounterPage(
      counters: page.items,
      nextCursor: page.nextCursor,
      hasMore: page.hasMore,
    );
  }
}

/// The Firestore document path for one branch's counters — kept
/// here next to the model so the repository and the mapper agree.
String dailyCounterDocPath(String branchId, DateTime date) =>
    FirestoreSchema.counterDocPath(
      branchId,
      DailyCounter.docIdFor(date),
    );
