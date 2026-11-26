import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/branch_context.dart';
import '../../core/utils/file_download.dart';
import '../../core/utils/money.dart';
import '../../core/widgets/design_system.dart';
import '../reports/analytics_logic.dart';
import '../reports/reports_provider.dart';
import 'finance_provider.dart';

/// P&L / Statements (Week 4 Day 3, D128 — SRS D-26 / FR-FIN-04/05).
///
/// A dedicated finance screen for profit & loss and branch
/// statements. The P&L here is the SAME computation the Reports hub
/// shows for the same window and branch: this screen reads
/// [advancedReportDataProvider] directly (and the per-branch cards
/// read it through [branchStatementProvider]) — it never recomputes
/// P&L a second way. If the Reports P&L and this screen ever
/// disagree for the same window/branch, that is a bug, pinned by the
/// Day 3 agreement test.
class StatementsScreen extends ConsumerStatefulWidget {
  const StatementsScreen({super.key});

  @override
  ConsumerState<StatementsScreen> createState() => _StatementsScreenState();
}

class _StatementsScreenState extends ConsumerState<StatementsScreen> {
  int _days = 30;
  String? _branchId;

  String get _branchName {
    if (_branchId == null) return 'All branches';
    return demoBranches
            .where((branch) => branch.id == _branchId)
            .firstOrNull
            ?.name ??
        _branchId!;
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

  @override
  Widget build(BuildContext context) {
    final advancedAsync = ref.watch(
      advancedReportDataProvider((_branchId, _days)),
    );
    final branches = demoBranches
        .where((branch) => _branchId == null || branch.id == _branchId)
        .toList();
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            title: 'P&L & Statements',
            subtitle: 'Profit & loss for $_branchName — last $_days days.',
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment<int>(value: 7, label: Text('7 days')),
                  ButtonSegment<int>(value: 30, label: Text('30 days')),
                  ButtonSegment<int>(value: 90, label: Text('90 days')),
                ],
                selected: {_days},
                onSelectionChanged: (selected) {
                  setState(() => _days = selected.single);
                },
              ),
              SizedBox(
                width: 280,
                child: DropdownButtonFormField<String?>(
                  initialValue: _branchId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Branch'),
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
                  onChanged: (selected) {
                    setState(() => _branchId = selected);
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          advancedAsync.when(
            loading: () => const SkeletonList(count: 3),
            error: (error, _) => PharmaEmptyState(
              icon: Icons.error_outline,
              title: 'Statements could not load',
              message: 'The profit & loss figures failed to load.',
              actionLabel: 'Retry',
              onAction: () => ref.invalidate(
                advancedReportDataProvider((_branchId, _days)),
              ),
            ),
            data: (advanced) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  advanced.countersUsed
                      ? 'Pre-aggregated daily counters • ${advanced.counterDays} day(s) covered'
                      : 'Live computed — no daily counters yet for this window',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 16),
                _PlTable(
                  title: 'Profit & loss — $_branchName',
                  profitLoss: advanced.profitLoss,
                  onExportCsv: () => _exportCsv(
                    context,
                    'pharmadesk-profit-loss.csv',
                    profitLossCsv(advanced.profitLoss),
                  ),
                ),
                const SizedBox(height: 24),
                const SectionHeader(
                  title: 'Branch statements',
                  subtitle:
                      'Per-branch profit & loss for the same window, from the same computation.',
                ),
                const SizedBox(height: 12),
                for (final branch in branches) ...[
                  _BranchStatementCard(
                    branchId: branch.id,
                    branchName: branch.name,
                    days: _days,
                  ),
                  const SizedBox(height: 12),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PlTable extends StatelessWidget {
  const _PlTable({
    required this.title,
    required this.profitLoss,
    this.onExportCsv,
  });

  final String title;
  final ProfitLoss profitLoss;

  /// Null hides the export button — the per-branch cards have no
  /// export (the consolidated table is the exportable one), and a
  /// button that does nothing would be a fake feature (SRS §1.5).
  final VoidCallback? onExportCsv;

  @override
  Widget build(BuildContext context) {
    return PharmaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              if (onExportCsv != null)
                PharmaButton(
                  label: 'Export CSV',
                  variant: PharmaButtonVariant.secondary,
                  size: PharmaButtonSize.small,
                  icon: Icons.download_outlined,
                  onPressed: onExportCsv,
                ),
            ],
          ),
          const SizedBox(height: 12),
          _PlRow(label: 'Sales revenue', amountMinor: profitLoss.revenueMinor),
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
            'Revenue is orders + POS sales with refunds subtracted; cost '
            'of goods uses the sold batch cost (D81).',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
    );
  }
}

/// One branch's statement card: the branch's P&L for the window,
/// read through [branchStatementProvider] (the same
/// [advancedReportDataProvider] the Reports hub reads).
class _BranchStatementCard extends ConsumerWidget {
  const _BranchStatementCard({
    required this.branchId,
    required this.branchName,
    required this.days,
  });

  final String branchId;
  final String branchName;
  final int days;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final statementAsync = ref.watch(
      branchStatementProvider((branchId, days)),
    );
    return statementAsync.when(
      loading: () => const PharmaCard(child: SkeletonList(count: 2)),
      error: (error, _) => PharmaCard(
        child: Text('$branchName statement could not load: $error'),
      ),
      data: (profitLoss) => _PlTable(
        title: branchName,
        profitLoss: profitLoss,
      ),
    );
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
