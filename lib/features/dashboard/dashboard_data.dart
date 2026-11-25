import '../../core/utils/money.dart';
import '../../core/widgets/badges.dart';
import '../../models/inventory_item.dart';
import '../../models/order.dart';
import '../../models/prescription.dart';
import '../../models/sale.dart';

/// Dashboard figures computed from mock repository data — never
/// hardcoded. All money is int minor units (paisa); the Day 0 models
/// still store money as `double` rupees, so conversion happens at the
/// boundary with [rupeesToMinorUnits] (see D6).
///
/// Pure functions over plain lists, so they are unit-testable without
/// widgets or providers. `branchId == null` means "all branches"
/// (owner view); a branch id scopes every figure to that branch.

/// One day of sales for the chart (oldest → newest).
class DailySales {
  const DailySales({
    required this.date,
    required this.salesMinor,
    required this.orders,
  });

  final DateTime date;
  final int salesMinor;
  final int orders;
}

/// One top-selling medicine over the window.
class TopSeller {
  const TopSeller({
    required this.medicineId,
    required this.medicineName,
    required this.quantitySold,
    required this.revenueMinor,
  });

  final String medicineId;
  final String medicineName;
  final int quantitySold;
  final int revenueMinor;
}

/// Everything a dashboard screen needs, computed in one pass.
class DashboardKpis {
  const DashboardKpis({
    required this.todaySalesMinor,
    required this.todayOrders,
    required this.yesterdaySalesMinor,
    required this.revenue30dMinor,
    required this.orders30d,
    required this.lowStockCount,
    required this.nearExpiryCount,
    required this.expiredCount,
    required this.pendingPrescriptions,
    required this.salesSeries,
    required this.topSellers,
    required this.recentOrders,
  });

  /// Today's sales (all non-cancelled orders created today).
  final int todaySalesMinor;

  /// Today's orders (all statuses except cancelled).
  final int todayOrders;

  /// Yesterday's sales, for the "vs yesterday" delta.
  final int yesterdaySalesMinor;

  /// Revenue over the last [days] days (non-cancelled orders).
  final int revenue30dMinor;

  /// Orders over the last [days] days (non-cancelled).
  final int orders30d;

  /// Inventory rows at or below their low-stock threshold.
  final int lowStockCount;

  /// Batches expiring within 30 days (not yet expired).
  final int nearExpiryCount;

  /// Batches already expired.
  final int expiredCount;

  /// Prescriptions still awaiting pharmacist review.
  final int pendingPrescriptions;

  /// Daily sales for the last [days] days, oldest → newest.
  final List<DailySales> salesSeries;

  /// Best sellers over the last [days] days, by revenue, top 5.
  final List<TopSeller> topSellers;

  /// Latest orders, newest first, top 8.
  final List<Order> recentOrders;
}

/// Computes dashboard KPIs from repository data.
///
/// Cancelled orders never count toward sales or revenue. Orders with a
/// null `createdAt` are ignored for date-based figures.
///
/// Day 6: completed POS sales ([sales]) count toward the same figures
/// — today's sales/orders, the 30-day revenue and the daily series and
/// top sellers — so a cash sale rung through the POS shows on the
/// dashboard immediately. The parameter defaults to empty, so callers
/// without sales data (and all Day 3 tests) are unchanged.
DashboardKpis computeDashboardKpis({
  required List<Order> orders,
  required List<InventoryItem> inventory,
  required List<Prescription> prescriptions,
  List<Sale> sales = const [],
  String? branchId,
  required DateTime now,
  int days = 30,
}) {
  final today = DateTime(now.year, now.month, now.day);
  final yesterday = today.subtract(const Duration(days: 1));
  final windowStart = today.subtract(Duration(days: days - 1));

  final scopedOrders = branchId == null
      ? orders
      : orders.where((order) => order.branchId == branchId).toList();
  final scopedInventory = branchId == null
      ? inventory
      : inventory.where((item) => item.branchId == branchId).toList();
  final scopedSales = branchId == null
      ? sales
      : sales.where((sale) => sale.branchId == branchId).toList();

  bool isSameDay(DateTime? value, DateTime day) =>
      value != null &&
      value.year == day.year &&
      value.month == day.month &&
      value.day == day.day;

  bool isCounted(Order order) => order.status != OrderStatus.cancelled;

  int orderSalesOn(DateTime day) => scopedOrders
      .where((order) => isCounted(order) && isSameDay(order.createdAt, day))
      .fold(0, (sum, order) => sum + rupeesToMinorUnits(order.totalAmount));

  int posSalesOn(DateTime day) => scopedSales
      .where((sale) => isSameDay(sale.createdAt, day))
      .fold(0, (sum, sale) => sum + sale.totalMinor);

  final todaySales = orderSalesOn(today) + posSalesOn(today);
  final yesterdaySales = orderSalesOn(yesterday) + posSalesOn(yesterday);
  final todayOrders =
      scopedOrders
          .where(
            (order) => isCounted(order) && isSameDay(order.createdAt, today),
          )
          .length +
      scopedSales.where((sale) => isSameDay(sale.createdAt, today)).length;

  // Daily series for the window (oldest → newest).
  final series = <DailySales>[];
  var revenue30d = 0;
  var orders30d = 0;
  for (var offset = days - 1; offset >= 0; offset--) {
    final day = today.subtract(Duration(days: offset));
    final dayOrders = scopedOrders.where(
      (order) => isCounted(order) && isSameDay(order.createdAt, day),
    );
    final dayPosSales = scopedSales.where(
      (sale) => isSameDay(sale.createdAt, day),
    );
    final daySales =
        dayOrders.fold<int>(
          0,
          (sum, order) => sum + rupeesToMinorUnits(order.totalAmount),
        ) +
        dayPosSales.fold<int>(0, (sum, sale) => sum + sale.totalMinor);
    series.add(
      DailySales(
        date: day,
        salesMinor: daySales,
        orders: dayOrders.length + dayPosSales.length,
      ),
    );
    revenue30d += daySales;
    orders30d += dayOrders.length + dayPosSales.length;
  }

  // Top sellers over the window, by revenue.
  final sold = <String, ({String name, int qty, int revenue})>{};
  for (final order in scopedOrders) {
    if (!isCounted(order)) continue;
    final created = order.createdAt;
    if (created == null) continue;
    final createdDay = DateTime(created.year, created.month, created.day);
    if (createdDay.isBefore(windowStart)) continue;
    for (final item in order.items) {
      final entry = sold[item.medicineId];
      final revenue = rupeesToMinorUnits(item.unitPrice) * item.quantity;
      sold[item.medicineId] = (
        name: item.medicineName,
        qty: (entry?.qty ?? 0) + item.quantity,
        revenue: (entry?.revenue ?? 0) + revenue,
      );
    }
  }
  for (final sale in scopedSales) {
    final created = sale.createdAt;
    if (created == null) continue;
    final createdDay = DateTime(created.year, created.month, created.day);
    if (createdDay.isBefore(windowStart)) continue;
    for (final item in sale.items) {
      final entry = sold[item.medicineId];
      sold[item.medicineId] = (
        name: item.medicineName,
        qty: (entry?.qty ?? 0) + item.quantity,
        revenue: (entry?.revenue ?? 0) + item.lineTotalMinor,
      );
    }
  }
  final topSellers = sold.entries
      .map(
        (entry) => TopSeller(
          medicineId: entry.key,
          medicineName: entry.value.name,
          quantitySold: entry.value.qty,
          revenueMinor: entry.value.revenue,
        ),
      )
      .toList()
    ..sort((a, b) => b.revenueMinor.compareTo(a.revenueMinor));
  final topFive = topSellers.take(5).toList();

  // Recent orders, newest first.
  final recent = scopedOrders
      .where((order) => order.createdAt != null)
      .toList()
    ..sort((a, b) => b.createdAt!.compareTo(a.createdAt!));
  final recentEight = recent.take(8).toList();

  // Stock alerts (branch-scoped).
  var lowStock = 0;
  var nearExpiry = 0;
  var expired = 0;
  for (final item in scopedInventory) {
    if (item.isLowStock) lowStock++;
    final expiry = item.expiryDate;
    if (expiry == null) continue;
    final expiryDay = DateTime(expiry.year, expiry.month, expiry.day);
    if (expiryDay.isBefore(today)) {
      expired++;
    } else if (!expiryDay.isAfter(today.add(const Duration(days: 30)))) {
      nearExpiry++;
    }
  }

  // Pending prescriptions. The Day 0 model has no branchId; the
  // repository scopes by the seed id prefix, so the list passed in is
  // already branch-scoped when a branchId is given (see D21).
  final pending = prescriptions
      .where((rx) => rx.status == PrescriptionStatus.pending)
      .length;

  return DashboardKpis(
    todaySalesMinor: todaySales,
    todayOrders: todayOrders,
    yesterdaySalesMinor: yesterdaySales,
    revenue30dMinor: revenue30d,
    orders30d: orders30d,
    lowStockCount: lowStock,
    nearExpiryCount: nearExpiry,
    expiredCount: expired,
    pendingPrescriptions: pending,
    salesSeries: series,
    topSellers: topFive,
    recentOrders: recentEight,
  );
}

/// Human label for an order status.
///
/// Week 1 vocabulary (Day 4, D25): the Day 0 legacy values map onto it
/// — `placed` is shown as "New", `preparing` as "Processing",
/// `outForDelivery` as "Dispatched" — so old and new orders read the
/// same in every list.
String orderStatusLabel(OrderStatus status) => switch (status) {
  OrderStatus.placed => 'New',
  OrderStatus.newOrder => 'New',
  OrderStatus.confirmed => 'Confirmed',
  OrderStatus.preparing => 'Processing',
  OrderStatus.processing => 'Processing',
  OrderStatus.ready => 'Ready',
  OrderStatus.outForDelivery => 'Dispatched',
  OrderStatus.dispatched => 'Dispatched',
  OrderStatus.delivered => 'Delivered',
  OrderStatus.cancelled => 'Cancelled',
};

StatusKind orderStatusKind(OrderStatus status) => switch (status) {
  OrderStatus.delivered => StatusKind.success,
  OrderStatus.cancelled => StatusKind.danger,
  OrderStatus.placed => StatusKind.info,
  OrderStatus.newOrder => StatusKind.info,
  OrderStatus.confirmed => StatusKind.info,
  OrderStatus.preparing => StatusKind.warning,
  OrderStatus.processing => StatusKind.warning,
  OrderStatus.ready => StatusKind.info,
  OrderStatus.outForDelivery => StatusKind.warning,
  OrderStatus.dispatched => StatusKind.warning,
};
