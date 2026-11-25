import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/branch_context.dart';
import '../../core/utils/file_download.dart';
import '../../core/utils/money.dart';
import '../../core/widgets/design_system.dart';
import '../billing/receipt_print.dart';
import 'reports_logic.dart';
import 'reports_provider.dart';

/// Reports hub (Day 7, SRS FR-REP-01/02/05/06, D-27/M-19).
///
/// Route `/reports`.
///
/// Daily sales, best-selling medicines, low-stock, expiry and stock
/// valuation — computed from orders + POS sales + inventory, with
/// branch + date-range filters. Every section exports to CSV
/// (download on web, copyable text elsewhere); the whole report
/// exports to a real PDF (`pdf` package), and the print button opens
/// the browser print dialog on web.
class ReportsScreen extends ConsumerStatefulWidget {
  const ReportsScreen({super.key});

  @override
  ConsumerState<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends ConsumerState<ReportsScreen> {
  String? _branchId; // null = all branches
  int _days = 30;
  bool _exportingPdf = false;

  String get _branchName {
    if (_branchId == null) return 'All branches';
    return demoBranches
        .where((b) => b.id == _branchId)
        .firstOrNull
        ?.name ?? _branchId!;
  }

  Future<void> _exportCsv(
    BuildContext context,
    String filename,
    String csv,
  ) async {
    if (canDownloadFile) {
      downloadTextFile(filename, csv, 'text/csv');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$filename downloaded.')),
        );
      }
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(filename),
        content: SingleChildScrollView(
          child: SelectableText(csv),
        ),
        actions: [
          PharmaButton(
            label: 'Copy',
            size: PharmaButtonSize.small,
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: csv));
              if (dialogContext.mounted) {
                Navigator.of(dialogContext).pop();
              }
            },
          ),
          PharmaButton(
            label: 'Close',
            variant: PharmaButtonVariant.text,
            size: PharmaButtonSize.small,
            onPressed: () => Navigator.of(dialogContext).pop(),
          ),
        ],
      ),
    );
  }

  Future<void> _exportPdf(ReportData data) async {
    setState(() => _exportingPdf = true);
    final bytes = await buildSalesReportPdf(
      data: data,
      branchName: _branchName,
      days: _days,
    );
    if (!mounted) return;
    setState(() => _exportingPdf = false);
    if (canDownloadFile) {
      downloadBytesFile(
        'pharmadesk-sales-report-${_days}d.pdf',
        bytes,
        'application/pdf',
      );
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('PDF report downloaded.')),
      );
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('PDF report ready'),
        content: Text(
          'The PDF (${bytes.lengthInBytes} bytes) was generated. File '
          'download works on web — on this device, use the CSV export '
          'buttons instead.',
        ),
        actions: [
          PharmaButton(
            label: 'OK',
            size: PharmaButtonSize.small,
            onPressed: () => Navigator.of(dialogContext).pop(),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dataAsync = ref.watch(reportDataProvider((_branchId, _days)));
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            title: 'Reports',
            subtitle: 'Sales, best sellers, stock and expiry — $_branchName',
            actionLabel: 'Export PDF',
            actionIcon: Icons.picture_as_pdf_outlined,
            onAction: _exportingPdf
                ? null
                : () async {
                    final data = dataAsync.asData?.value;
                    if (data != null) await _exportPdf(data);
                  },
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              DropdownButton<String?>(
                value: _branchId,
                hint: const Text('All branches'),
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('All branches'),
                  ),
                  for (final branch in demoBranches)
                    DropdownMenuItem<String?>(
                      value: branch.id,
                      child: Text(branch.name),
                    ),
                ],
                onChanged: (selected) =>
                    setState(() => _branchId = selected),
              ),
              for (final days in [1, 7, 30])
                ChoiceChip(
                  label: Text(
                    days == 1 ? 'Today' : 'Last $days days',
                  ),
                  selected: _days == days,
                  onSelected: (_) => setState(() => _days = days),
                ),
              if (canPrintReceipt)
                ActionChip(
                  avatar: const Icon(Icons.print_outlined, size: 18),
                  label: const Text('Print view'),
                  onPressed: printReceipt,
                ),
            ],
          ),
          const SizedBox(height: 16),
          dataAsync.when(
            loading: () => const SkeletonList(count: 5),
            error: (error, _) => PharmaEmptyState(
              icon: Icons.error_outline,
              title: 'Reports could not load',
              message: 'The demo data failed to load. Try again.',
              actionLabel: 'Retry',
              onAction: () =>
                  ref.invalidate(reportDataProvider((_branchId, _days))),
            ),
            data: (data) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    SizedBox(
                      width: 220,
                      child: StatCard(
                        label: 'Total sales',
                        moneyMinorUnits: data.totalSalesMinor,
                        icon: Icons.payments_outlined,
                      ),
                    ),
                    SizedBox(
                      width: 220,
                      child: StatCard(
                        label: 'Orders / sales',
                        value: '${data.totalOrders}',
                        icon: Icons.receipt_long_outlined,
                      ),
                    ),
                    SizedBox(
                      width: 220,
                      child: StatCard(
                        label: 'Stock valuation (cost)',
                        moneyMinorUnits: data.stockValuationMinor,
                        icon: Icons.inventory_2_outlined,
                      ),
                    ),
                    SizedBox(
                      width: 220,
                      child: StatCard(
                        label: 'Units on hand',
                        value: '${data.totalStockUnits}',
                        icon: Icons.medication_outlined,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                _ReportSection(
                  title: 'Daily sales',
                  actionLabel: 'Export CSV',
                  onExport: () => _exportCsv(
                    context,
                    'pharmadesk-daily-sales.csv',
                    dailySalesCsv(data.dailySales),
                  ),
                  child: _DailySalesTable(days: data.dailySales),
                ),
                const SizedBox(height: 24),
                _ReportSection(
                  title: 'Best-selling medicines',
                  actionLabel: 'Export CSV',
                  onExport: () => _exportCsv(
                    context,
                    'pharmadesk-best-sellers.csv',
                    bestSellersCsv(data.bestSellers),
                  ),
                  child: data.bestSellers.isEmpty
                      ? const Text('No sales in this window.')
                      : Column(
                          children: [
                            for (final seller in data.bestSellers)
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: const Icon(
                                  Icons.trending_up_outlined,
                                ),
                                title: Text(seller.medicineName),
                                subtitle: Text(
                                  '${seller.quantitySold} sold',
                                ),
                                trailing: Text(
                                  formatPkr(seller.revenueMinor),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                          ],
                        ),
                ),
                const SizedBox(height: 24),
                _ReportSection(
                  title:
                      'Low stock — ${data.lowStock.length} batch(es)',
                  actionLabel: 'Export CSV',
                  onExport: () => _exportCsv(
                    context,
                    'pharmadesk-low-stock.csv',
                    lowStockCsv(data.lowStock),
                  ),
                  child: data.lowStock.isEmpty
                      ? const Text('No batches at or below their threshold.')
                      : Column(
                          children: [
                            for (final row in data.lowStock.take(20))
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: const Icon(
                                  Icons.warning_amber_outlined,
                                ),
                                title: Text(row.medicineName),
                                subtitle: Text(
                                  'Batch ${row.batchNo ?? '—'} • threshold ${row.threshold}',
                                ),
                                trailing: Text(
                                  '${row.quantity} left',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            if (data.lowStock.length > 20)
                              Text(
                                '…and ${data.lowStock.length - 20} more — see the CSV export.',
                              ),
                          ],
                        ),
                ),
                const SizedBox(height: 24),
                _ReportSection(
                  title:
                      'Expiry — ${data.expiring.length} expiring, ${data.expired.length} expired',
                  actionLabel: 'Export CSV',
                  onExport: () => _exportCsv(
                    context,
                    'pharmadesk-expiry.csv',
                    '${expiryCsv(data.expiring, expired: false)}'
                    '${expiryCsv(data.expired, expired: true)}',
                  ),
                  child: (data.expiring.isEmpty && data.expired.isEmpty)
                      ? const Text(
                          'No batches expiring within 90 days and none expired.',
                        )
                      : Column(
                          children: [
                            for (final row in data.expired.take(10))
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: Icon(
                                  Icons.dangerous_outlined,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.error,
                                ),
                                title: Text(row.medicineName),
                                subtitle: Text(
                                  'Batch ${row.batchNo ?? '—'} • expired '
                                  '${row.expiryDate.day}/${row.expiryDate.month}/${row.expiryDate.year}',
                                ),
                                trailing: Text('${row.quantity} units'),
                              ),
                            for (final row in data.expiring.take(10))
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: const Icon(
                                  Icons.schedule_outlined,
                                ),
                                title: Text(row.medicineName),
                                subtitle: Text(
                                  'Batch ${row.batchNo ?? '—'} • expires '
                                  '${row.expiryDate.day}/${row.expiryDate.month}/${row.expiryDate.year}',
                                ),
                                trailing: Text(
                                  '${row.daysLeft}d left • ${row.quantity} units',
                                ),
                              ),
                            if (data.expiring.length + data.expired.length >
                                20)
                              const Text(
                                'Showing the 20 most urgent — see the CSV export for the full list.',
                              ),
                          ],
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ReportSection extends StatelessWidget {
  const _ReportSection({
    required this.title,
    required this.actionLabel,
    required this.onExport,
    required this.child,
  });

  final String title;
  final String actionLabel;
  final VoidCallback onExport;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(
          title: title,
          actionLabel: actionLabel,
          actionIcon: Icons.download_outlined,
          onAction: onExport,
        ),
        const SizedBox(height: 12),
        PharmaCard(child: child),
      ],
    );
  }
}

class _DailySalesTable extends StatelessWidget {
  const _DailySalesTable({required this.days});

  final List<ReportDay> days;

  @override
  Widget build(BuildContext context) {
    // Newest first for reading; the CSV keeps oldest → newest.
    final rows = days.toList().reversed.toList();
    return Column(
      children: [
        for (final day in rows)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.calendar_today_outlined),
            title: Text(
              '${day.date.day}/${day.date.month}/${day.date.year}',
            ),
            subtitle: Text('${day.orders} order(s)'),
            trailing: Text(
              formatPkr(day.salesMinor),
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
      ],
    );
  }
}
