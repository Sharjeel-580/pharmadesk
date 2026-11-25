import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/data/permission_service.dart';
import '../../core/services/branch_context.dart';
import '../../core/utils/file_download.dart';
import '../../core/utils/money.dart';
import '../../core/widgets/design_system.dart';
import '../../core/widgets/pagination_controls.dart';
import '../../models/expense.dart';
import '../authentication/auth_state.dart';
import '../billing/receipt_print.dart';
import '../finance/finance_provider.dart';
import 'analytics_logic.dart';
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
                      : PagedList<ReportLowStockRow>(
                          items: data.lowStock,
                          itemBuilder: (context, row) => ListTile(
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
                      : PagedList<({ReportExpiryRow row, bool expired})>(
                          items: [
                            for (final row in data.expired)
                              (row: row, expired: true),
                            for (final row in data.expiring)
                              (row: row, expired: false),
                          ],
                          itemBuilder: (context, entry) {
                            final row = entry.row;
                            if (entry.expired) {
                              return ListTile(
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
                              );
                            }
                            return ListTile(
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
                            );
                          },
                        ),
                ),
                const SizedBox(height: 24),
                _AdvancedSections(
                  branchId: _branchId,
                  days: _days,
                  expiredRows: data.expired,
                  onExportCsv: (filename, csv) =>
                      _exportCsv(context, filename, csv),
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

/// Week 2 Day 5 advanced sections: sales trend (weekly), branch
/// comparison, slow movers, expiry loss, profit & loss + expenses.
/// Computed by [advancedReportDataProvider] for the same branch +
/// window as the Day 7 sections above.
class _AdvancedSections extends ConsumerWidget {
  const _AdvancedSections({
    required this.branchId,
    required this.days,
    required this.expiredRows,
    required this.onExportCsv,
  });

  final String? branchId;
  final int days;
  final List<ReportExpiryRow> expiredRows;
  final void Function(String filename, String csv) onExportCsv;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final advancedAsync = ref.watch(
      advancedReportDataProvider((branchId, days)),
    );
    return advancedAsync.when(
      loading: () => const SkeletonList(count: 3),
      error: (error, _) => PharmaEmptyState(
        icon: Icons.error_outline,
        title: 'Advanced reports could not load',
        message: 'The trend, comparison and P&L sections failed to load.',
        actionLabel: 'Retry',
        onAction: () => ref.invalidate(
          advancedReportDataProvider((branchId, days)),
        ),
      ),
      data: (advanced) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Counters caption (D106): the reader can see whether the
          // figures below came from the pre-aggregated daily
          // counters or were computed live for this window.
          Text(
            advanced.countersUsed
                ? 'Pre-aggregated daily counters • ${advanced.counterDays} day(s) covered'
                : 'Live computed — no daily counters yet for this window',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          _ReportSection(
            title: 'Sales trend — weekly',
            actionLabel: 'Export CSV',
            onExport: () => onExportCsv(
              'pharmadesk-weekly-trend.csv',
              weeklyTrendCsv(advanced.weeklyTrend),
            ),
            child: advanced.weeklyTrend.isEmpty
                ? const Text('No sales in this window.')
                : PagedList<WeeklyTrendPoint>(
                    items: advanced.weeklyTrend,
                    itemBuilder: (context, week) => ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.show_chart_outlined),
                      title: Text(
                        'Week of ${week.weekStart.day}/${week.weekStart.month}/${week.weekStart.year}',
                      ),
                      subtitle: Text('${week.orders} order(s)'),
                      trailing: Text(
                        formatPkr(week.salesMinor),
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
          ),
          const SizedBox(height: 24),
          _ReportSection(
            title: 'Branch comparison',
            actionLabel: 'Export CSV',
            onExport: () => onExportCsv(
              'pharmadesk-branch-comparison.csv',
              branchComparisonCsv(advanced.branchComparison),
            ),
            child: advanced.branchComparison.isEmpty
                ? const Text('No branches in this scope.')
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      PagedList<BranchAnalyticsRow>(
                        items: advanced.branchComparison,
                        itemBuilder: (context, row) => ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.store_outlined),
                          title: Text(row.branchName),
                          subtitle: Text(
                            'Profit ${formatPkr(row.grossProfitMinor)} • '
                            'Stock ${formatPkr(row.stockValueMinor)} • '
                            'Outstanding ${formatPkr(row.outstandingMinor)} • '
                            'Expiry loss ${formatPkr(row.expiryLossMinor)}',
                          ),
                          trailing: Text(
                            formatPkr(row.salesMinor),
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Outstanding counts only khata entries linked to '
                        'that branch\'s credit sales (D79) — manual '
                        'entries are unattributed.',
                        style: TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
          ),
          const SizedBox(height: 24),
          _ReportSection(
            title: 'Slow movers — ${advanced.slowMovers.length} medicine(s)',
            actionLabel: 'Export CSV',
            onExport: () => onExportCsv(
              'pharmadesk-slow-movers.csv',
              slowMoversCsv(advanced.slowMovers),
            ),
            child: advanced.slowMovers.isEmpty
                ? const Text(
                    'No slow movers — every stocked medicine sold in this window.',
                  )
                : PagedList<SlowMover>(
                    items: advanced.slowMovers,
                    itemBuilder: (context, mover) => ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(
                        Icons.trending_down_outlined,
                      ),
                      title: Text(mover.medicineName),
                      subtitle: Text(
                        '0 sold • ${mover.quantityOnHand} on hand',
                      ),
                      trailing: Text(
                        formatPkr(mover.stockValueMinor),
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
          ),
          const SizedBox(height: 24),
          _ReportSection(
            title:
                'Expiry loss — ${formatPkr(advanced.expiryLoss.lossMinor)} '
                '(${advanced.expiryLoss.batches} batches, '
                '${advanced.expiryLoss.units} units)',
            actionLabel: 'Export CSV',
            onExport: () => onExportCsv(
              'pharmadesk-expiry-loss.csv',
              expiryLossCsv(
                expiredRows,
                totalLossMinor: advanced.expiryLoss.lossMinor,
              ),
            ),
            child: Text(
              advanced.expiryLoss.lossMinor == 0
                  ? 'No expired stock on hand — nothing lost to expiry in this scope.'
                  : 'Expired batches on hand are worth '
                        '${formatPkr(advanced.expiryLoss.lossMinor)} at '
                        'cost price (${advanced.expiryLoss.units} units '
                        'across ${advanced.expiryLoss.batches} batches). '
                        'See the Expiry section above for the batch list.',
            ),
          ),
          const SizedBox(height: 24),
          _ProfitLossSection(
            profitLoss: advanced.profitLoss,
            expenses: advanced.expenses,
            branchId: branchId,
            onExportCsv: onExportCsv,
          ),
        ],
      ),
    );
  }
}

/// Profit & loss + the expense list behind it, with a Record
/// expense action (gated on `financeEntry`).
class _ProfitLossSection extends ConsumerWidget {
  const _ProfitLossSection({
    required this.profitLoss,
    required this.expenses,
    required this.branchId,
    required this.onExportCsv,
  });

  final ProfitLoss profitLoss;
  final List<Expense> expenses;
  final String? branchId;
  final void Function(String filename, String csv) onExportCsv;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authProvider);
    final activeBranchId = ref.watch(activeBranchProvider).id;
    final expenseBranchId = branchId ?? activeBranchId;
    final mayRecord = permissionService.canWrite(
      user,
      'financeEntry',
      expenseBranchId,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ReportSection(
          title: 'Profit & loss',
          actionLabel: 'Export CSV',
          onExport: () => onExportCsv(
            'pharmadesk-profit-loss.csv',
            profitLossCsv(profitLoss),
          ),
          child: Column(
            children: [
              _PlRow(
                label: 'Sales revenue',
                amountMinor: profitLoss.revenueMinor,
              ),
              _PlRow(
                label: 'Cost of goods sold',
                amountMinor: -profitLoss.cogsMinor,
              ),
              _PlRow(
                label: 'Gross profit',
                amountMinor: profitLoss.grossProfitMinor,
                bold: true,
              ),
              _PlRow(
                label: 'Other income',
                amountMinor: profitLoss.otherIncomeMinor,
              ),
              _PlRow(
                label: 'Operating expenses',
                amountMinor: -profitLoss.expensesMinor,
              ),
              const Divider(height: 16),
              _PlRow(
                label: 'Net profit',
                amountMinor: profitLoss.netProfitMinor,
                bold: true,
              ),
              const SizedBox(height: 4),
              const Text(
                'Revenue is orders + POS sales with refunds subtracted; '
                'cost of goods uses the sold batch cost (D81). Expenses '
                'come from the list below.',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        SectionHeader(
          title: 'Expenses — ${expenses.length} in this window',
          actionLabel: 'Record expense',
          actionIcon: Icons.add_outlined,
          onAction: mayRecord
              ? () => _showExpenseDialog(context, ref, expenseBranchId)
              : null,
        ),
        const SizedBox(height: 12),
        if (!mayRecord)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              'Recording expenses needs the "Finance: income/expense '
              'entry" permission (SRS §5.1) — Owner, HO Admin, '
              'Accountant, or your own Branch Manager / Cashier.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        PharmaCard(
          child: expenses.isEmpty
              ? const Text('No expenses recorded in this window.')
              : PagedList<Expense>(
                  items: expenses,
                  itemBuilder: (context, expense) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.receipt_outlined),
                    title: Text(
                      expense.description.isEmpty
                          ? expense.category
                          : expense.description,
                    ),
                    subtitle: Text(
                      '${expense.category} • '
                      '${expense.expenseDate.day}/${expense.expenseDate.month}/${expense.expenseDate.year}',
                    ),
                    trailing: Text(
                      formatPkr(expense.amountMinor),
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  Future<void> _showExpenseDialog(
    BuildContext context,
    WidgetRef ref,
    String branchId,
  ) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => _ExpenseDialog(branchId: branchId),
    );
    if (saved == true && context.mounted) {
      ref.invalidate(advancedReportDataProvider);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Expense recorded.')),
      );
    }
  }
}

class _PlRow extends StatelessWidget {
  const _PlRow({
    required this.label,
    required this.amountMinor,
    this.bold = false,
  });

  final String label;
  final int amountMinor;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text(label, style: style)),
          Text(formatPkr(amountMinor), style: style),
        ],
      ),
    );
  }
}

class _ExpenseDialog extends ConsumerStatefulWidget {
  const _ExpenseDialog({required this.branchId});

  final String branchId;

  @override
  ConsumerState<_ExpenseDialog> createState() => _ExpenseDialogState();
}

class _ExpenseDialogState extends ConsumerState<_ExpenseDialog> {
  final _amount = TextEditingController();
  final _description = TextEditingController();
  String _category = expenseCategories.first;
  DateTime _date = DateTime.now();
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _amount.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final rupees = double.tryParse(_amount.text.trim()) ?? -1;
    final amountMinor = (rupees * 100).round();
    setState(() => _saving = true);
    final result = await ref
        .read(expensesProvider.notifier)
        .recordExpense(
          branchId: widget.branchId,
          category: _category,
          amountMinor: amountMinor,
          description: _description.text,
          expenseDate: _date,
        );
    if (!mounted) return;
    setState(() => _saving = false);
    if (result.error != null) {
      setState(() => _error = result.error);
      return;
    }
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Record expense'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error != null) ...[
              PharmaErrorBox(errors: [_error!]),
              const SizedBox(height: 12),
            ],
            DropdownButtonFormField<String>(
              initialValue: _category,
              decoration: const InputDecoration(labelText: 'Category'),
              items: [
                for (final category in expenseCategories)
                  DropdownMenuItem<String>(
                    value: category,
                    child: Text(category),
                  ),
              ],
              onChanged: (selected) {
                if (selected != null) setState(() => _category = selected);
              },
            ),
            const SizedBox(height: 12),
            PharmaTextField(
              controller: _amount,
              label: 'Amount (Rs)',
              hintText: 'e.g. 5000',
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              autofocus: true,
            ),
            const SizedBox(height: 12),
            PharmaTextField(
              controller: _description,
              label: 'Description',
              hintText: 'e.g. Electricity bill — November',
              maxLines: 2,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Date: ${_date.day}/${_date.month}/${_date.year}',
                  ),
                ),
                PharmaButton(
                  label: 'Change date',
                  variant: PharmaButtonVariant.secondary,
                  size: PharmaButtonSize.small,
                  onPressed: () async {
                    final now = DateTime.now();
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: _date,
                      firstDate: now.subtract(const Duration(days: 365)),
                      lastDate: now,
                    );
                    if (picked != null) setState(() => _date = picked);
                  },
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              'Recording also writes a financial-transactions entry, '
              'so the P&L and the transaction feed always agree.',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
      actions: [
        PharmaButton(
          label: 'Cancel',
          variant: PharmaButtonVariant.text,
          size: PharmaButtonSize.small,
          onPressed: () => Navigator.of(context).pop(false),
        ),
        PharmaButton(
          label: 'Record',
          size: PharmaButtonSize.small,
          loading: _saving,
          onPressed: _save,
        ),
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
    // Paged at the shared page size (D107) — a 30-day window is
    // three pages instead of a 30-row scroll.
    final rows = days.toList().reversed.toList();
    return PagedList<ReportDay>(
      items: rows,
      itemBuilder: (context, day) => ListTile(
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
    );
  }
}
