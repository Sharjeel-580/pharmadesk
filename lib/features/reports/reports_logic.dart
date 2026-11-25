import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/utils/money.dart';
import '../../models/inventory_item.dart';
import '../../models/medicine.dart';
import '../../models/order.dart';
import '../../models/sale.dart';

/// Day 7 reports — pure computation over repository data (SRS FR-REP-01/02/05/06).
///
/// All money is int minor units (paisa). Reports read the same
/// sources as the dashboard: seeded orders (30-day history) + POS
/// sales rung in the session + live inventory. Cancelled orders never
/// count toward sales or revenue.

/// One day of sales for the daily-sales report (oldest → newest).
class ReportDay {
  const ReportDay({
    required this.date,
    required this.salesMinor,
    required this.orders,
  });

  final DateTime date;
  final int salesMinor;
  final int orders;
}

/// One best-selling medicine over the window.
class ReportBestSeller {
  const ReportBestSeller({
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

/// One low-stock batch row.
class ReportLowStockRow {
  const ReportLowStockRow({
    required this.medicineName,
    required this.batchNo,
    required this.quantity,
    required this.threshold,
  });

  final String medicineName;
  final String? batchNo;
  final int quantity;
  final int threshold;
}

/// One expiring batch row.
class ReportExpiryRow {
  const ReportExpiryRow({
    required this.medicineName,
    required this.batchNo,
    required this.expiryDate,
    required this.daysLeft,
    required this.quantity,
  });

  final String medicineName;
  final String? batchNo;
  final DateTime expiryDate;
  final int daysLeft;
  final int quantity;
}

/// Everything the reports screen needs, computed in one pass.
class ReportData {
  const ReportData({
    required this.totalSalesMinor,
    required this.totalOrders,
    required this.dailySales,
    required this.bestSellers,
    required this.lowStock,
    required this.expiring,
    required this.expired,
    required this.stockValuationMinor,
    required this.totalStockUnits,
  });

  /// Sales over the window (non-cancelled orders + POS sales).
  final int totalSalesMinor;

  /// Orders + POS sales over the window.
  final int totalOrders;

  /// Daily sales for the window, oldest → newest.
  final List<ReportDay> dailySales;

  /// Best sellers over the window, by revenue, top 10.
  final List<ReportBestSeller> bestSellers;

  /// Batches at or below their low-stock threshold.
  final List<ReportLowStockRow> lowStock;

  /// Batches expiring within 90 days (not yet expired), soonest first.
  final List<ReportExpiryRow> expiring;

  /// Batches already expired.
  final List<ReportExpiryRow> expired;

  /// Stock valuation at cost price (int paisa, FR-INV-11).
  final int stockValuationMinor;

  /// Total units on hand across all batches.
  final int totalStockUnits;
}

bool _isSameDay(DateTime? value, DateTime day) =>
    value != null &&
    value.year == day.year &&
    value.month == day.month &&
    value.day == day.day;

/// Computes the report set for [branchId] (`null` = all branches)
/// over the last [days] days ending today.
ReportData computeReports({
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

  final scopedOrders = branchId == null
      ? orders
      : orders.where((order) => order.branchId == branchId).toList();
  final scopedSales = branchId == null
      ? sales
      : sales.where((sale) => sale.branchId == branchId).toList();
  final scopedInventory = branchId == null
      ? inventory
      : inventory.where((item) => item.branchId == branchId).toList();

  bool isCounted(Order order) => order.status != OrderStatus.cancelled;

  bool inWindow(DateTime? created) {
    if (created == null) return false;
    final day = DateTime(created.year, created.month, created.day);
    return !day.isBefore(windowStart) && !day.isAfter(today);
  }

  // Daily sales (oldest → newest).
  final daily = <ReportDay>[];
  var totalSales = 0;
  var totalOrders = 0;
  for (var offset = days - 1; offset >= 0; offset--) {
    final day = today.subtract(Duration(days: offset));
    final dayOrders = scopedOrders.where(
      (order) => isCounted(order) && _isSameDay(order.createdAt, day),
    );
    final dayPosSales = scopedSales.where(
      (sale) => _isSameDay(sale.createdAt, day),
    );
    final daySales =
        dayOrders.fold<int>(
          0,
          (sum, order) => sum + rupeesToMinorUnits(order.totalAmount),
        ) +
        dayPosSales.fold<int>(0, (sum, sale) => sum + sale.totalMinor);
    daily.add(
      ReportDay(
        date: day,
        salesMinor: daySales,
        orders: dayOrders.length + dayPosSales.length,
      ),
    );
    totalSales += daySales;
    totalOrders += dayOrders.length + dayPosSales.length;
  }

  // Best sellers over the window, by revenue.
  final sold = <String, ({String name, int qty, int revenue})>{};
  void addSale(String id, String name, int qty, int revenue) {
    final entry = sold[id];
    sold[id] = (
      name: name,
      qty: (entry?.qty ?? 0) + qty,
      revenue: (entry?.revenue ?? 0) + revenue,
    );
  }

  for (final order in scopedOrders) {
    if (!isCounted(order) || !inWindow(order.createdAt)) continue;
    for (final item in order.items) {
      addSale(
        item.medicineId,
        item.medicineName,
        item.quantity,
        rupeesToMinorUnits(item.unitPrice) * item.quantity,
      );
    }
  }
  for (final sale in scopedSales) {
    if (!inWindow(sale.createdAt)) continue;
    for (final item in sale.items) {
      addSale(
        item.medicineId,
        item.medicineName,
        item.quantity,
        item.lineTotalMinor,
      );
    }
  }
  final bestSellers = sold.entries
      .map(
        (entry) => ReportBestSeller(
          medicineId: entry.key,
          medicineName: entry.value.name,
          quantitySold: entry.value.qty,
          revenueMinor: entry.value.revenue,
        ),
      )
      .toList()
    ..sort((a, b) => b.revenueMinor.compareTo(a.revenueMinor));
  final topTen = bestSellers.take(10).toList();

  // Low stock, expiry, valuation — per batch row.
  final lowStock = <ReportLowStockRow>[];
  final expiring = <ReportExpiryRow>[];
  final expired = <ReportExpiryRow>[];
  var valuation = 0;
  var totalUnits = 0;
  for (final item in scopedInventory) {
    totalUnits += item.quantity;
    valuation += item.quantity * item.costMinor;
    final medicineName =
        medicinesById[item.medicineId]?.name ?? item.medicineId;
    if (item.isLowStock) {
      lowStock.add(
        ReportLowStockRow(
          medicineName: medicineName,
          batchNo: item.batchNo,
          quantity: item.quantity,
          threshold: item.lowStockThreshold,
        ),
      );
    }
    final expiry = item.expiryDate;
    if (expiry == null) continue;
    final expiryDay = DateTime(expiry.year, expiry.month, expiry.day);
    final daysLeft = expiryDay.difference(today).inDays;
    final row = ReportExpiryRow(
      medicineName: medicineName,
      batchNo: item.batchNo,
      expiryDate: expiryDay,
      daysLeft: daysLeft,
      quantity: item.quantity,
    );
    if (daysLeft < 0) {
      expired.add(row);
    } else if (daysLeft <= 90) {
      expiring.add(row);
    }
  }
  expiring.sort((a, b) => a.daysLeft.compareTo(b.daysLeft));
  expired.sort((a, b) => a.daysLeft.compareTo(b.daysLeft));
  lowStock.sort((a, b) => a.quantity.compareTo(b.quantity));

  return ReportData(
    totalSalesMinor: totalSales,
    totalOrders: totalOrders,
    dailySales: daily,
    bestSellers: topTen,
    lowStock: lowStock,
    expiring: expiring,
    expired: expired,
    stockValuationMinor: valuation,
    totalStockUnits: totalUnits,
  );
}

// --- CSV export (FR-REP-05) --------------------------------------------

/// Escapes one CSV cell (quotes, commas, newlines).
String csvEscape(Object? value) {
  final text = value == null ? '' : value.toString();
  if (text.contains(',') ||
      text.contains('"') ||
      text.contains('\n')) {
    return '"${text.replaceAll('"', '""')}"';
  }
  return text;
}

String _csvRow(List<Object?> cells) =>
    cells.map(csvEscape).join(',');

String _dateText(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

String dailySalesCsv(List<ReportDay> days) {
  final buffer = StringBuffer()..writeln('Date,Orders,Sales (Rs)');
  for (final day in days) {
    buffer.writeln(
      _csvRow([
        _dateText(day.date),
        day.orders,
        (day.salesMinor / 100).toStringAsFixed(2),
      ]),
    );
  }
  return buffer.toString();
}

String bestSellersCsv(List<ReportBestSeller> sellers) {
  final buffer = StringBuffer()
    ..writeln('Medicine,Quantity sold,Revenue (Rs)');
  for (final seller in sellers) {
    buffer.writeln(
      _csvRow([
        seller.medicineName,
        seller.quantitySold,
        (seller.revenueMinor / 100).toStringAsFixed(2),
      ]),
    );
  }
  return buffer.toString();
}

String lowStockCsv(List<ReportLowStockRow> rows) {
  final buffer = StringBuffer()
    ..writeln('Medicine,Batch,Quantity on hand,Low-stock threshold');
  for (final row in rows) {
    buffer.writeln(
      _csvRow([
        row.medicineName,
        row.batchNo ?? '',
        row.quantity,
        row.threshold,
      ]),
    );
  }
  return buffer.toString();
}

String expiryCsv(List<ReportExpiryRow> rows, {required bool expired}) {
  final buffer = StringBuffer()
    ..writeln('Medicine,Batch,Expiry date,Days left,Quantity on hand');
  for (final row in rows) {
    buffer.writeln(
      _csvRow([
        row.medicineName,
        row.batchNo ?? '',
        _dateText(row.expiryDate),
        expired ? 'EXPIRED' : row.daysLeft,
        row.quantity,
      ]),
    );
  }
  return buffer.toString();
}

// --- PDF export (FR-REP-05, real `pdf` package) -------------------------

/// Builds a one-page-per-section PDF of the daily-sales + best-sellers
/// reports. Returns the PDF bytes; the caller downloads them (web) or
/// shares them. Pure Dart (`pdf` package) — no platform plugin.
Future<Uint8List> buildSalesReportPdf({
  required ReportData data,
  required String branchName,
  required int days,
}) async {
  final doc = pw.Document();
  final headerStyle = pw.TextStyle(
    fontSize: 20,
    fontWeight: pw.FontWeight.bold,
    color: PdfColor.fromHex('164AAB'),
  );
  final subStyle = pw.TextStyle(fontSize: 11, color: PdfColors.grey700);
  final tableHeader = pw.TextStyle(
    fontSize: 11,
    fontWeight: pw.FontWeight.bold,
    color: PdfColors.white,
  );
  final cell = pw.TextStyle(fontSize: 11);

  pw.Widget sectionTitle(String title) => pw.Padding(
    padding: const pw.EdgeInsets.only(top: 16, bottom: 8),
    child: pw.Text(
      title,
      style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
    ),
  );

  pw.Widget table(List<String> headers, List<List<String>> rows) =>
      pw.Table(
        border: pw.TableBorder.all(color: PdfColors.grey300),
        children: [
          pw.TableRow(
            decoration: pw.BoxDecoration(color: PdfColor.fromHex('164AAB')),
            children: [
              for (final header in headers)
                pw.Padding(
                  padding: const pw.EdgeInsets.all(6),
                  child: pw.Text(header, style: tableHeader),
                ),
            ],
          ),
          for (final row in rows)
            pw.TableRow(
              children: [
                for (final value in row)
                  pw.Padding(
                    padding: const pw.EdgeInsets.all(6),
                    child: pw.Text(value, style: cell),
                  ),
              ],
            ),
        ],
      );

  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      header: (context) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text('PharmaDesk — Sales Report', style: headerStyle),
          pw.Text(
            '$branchName • Last $days days • Demo data',
            style: subStyle,
          ),
          pw.Divider(),
        ],
      ),
      footer: (context) => pw.Text(
        'PharmaDesk demo — figures are fictional sample data.',
        style: subStyle,
      ),
      build: (context) => [
        pw.Text(
          'Total sales: ${formatPkr(data.totalSalesMinor)} '
          '• ${data.totalOrders} orders/sales',
          style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold),
        ),
        sectionTitle('Daily sales'),
        table(
          ['Date', 'Orders', 'Sales (Rs)'],
          [
            for (final day in data.dailySales)
              [
                _dateText(day.date),
                day.orders.toString(),
                (day.salesMinor / 100).toStringAsFixed(2),
              ],
          ],
        ),
        sectionTitle('Best-selling medicines'),
        table(
          ['Medicine', 'Qty sold', 'Revenue (Rs)'],
          [
            for (final seller in data.bestSellers)
              [
                seller.medicineName,
                seller.quantitySold.toString(),
                (seller.revenueMinor / 100).toStringAsFixed(2),
              ],
          ],
        ),
        sectionTitle('Stock valuation'),
        pw.Text(
          'Stock on hand: ${data.totalStockUnits} units, valued at '
          '${formatPkr(data.stockValuationMinor)} (cost price). '
          '${data.lowStock.length} low-stock batches, '
          '${data.expired.length} expired batches.',
          style: cell,
        ),
      ],
    ),
  );
  return doc.save();
}
