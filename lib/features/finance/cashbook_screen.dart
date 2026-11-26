import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/data/permission_service.dart';
import '../../core/services/branch_context.dart';
import '../../core/utils/money.dart';
import '../../core/widgets/design_system.dart';
import '../../core/widgets/pagination_controls.dart';
import '../../core/widgets/sync_status_widget.dart';
import '../../models/cash_reconciliation.dart';
import '../../models/closing_correction.dart';
import '../../models/daily_closing.dart';
import '../../models/expense.dart';
import '../authentication/auth_state.dart';
import '../billing/billing_provider.dart';
import 'finance_logic.dart';
import 'finance_provider.dart';

/// Cashbook (Week 4 Day 3, D124–D126 — SRS D-24 / FR-FIN-01/02).
///
/// Income/expense entries for the active branch (expenses from the
/// `expenses` collection, income from `financialTransactions` of type
/// `income` — unified by [cashbookEntries], newest first), a date
/// filter, and the daily closing: one snapshot record per branch-day
/// (totals in/out + closing balance, never an edit of the entries).
///
/// Writes here go through the production data layer (Week 4 Day 5,
/// D145 — closes D129): expense / income / closing writes each
/// enqueue one sync payload, so — per D108 — this screen shows the
/// [SyncStatusChip].
class CashbookScreen extends ConsumerStatefulWidget {
  const CashbookScreen({super.key});

  @override
  ConsumerState<CashbookScreen> createState() => _CashbookScreenState();
}

class _CashbookScreenState extends ConsumerState<CashbookScreen> {
  DateTime _selectedDate = DateTime.now();
  bool _allDates = false;

  /// Cash-reconciliation inputs (Week 5 Day 4, D157): the counted
  /// drawer cash for the selected day, in whole rupees, plus an
  /// optional note. Cleared after a successful record.
  final _countedController = TextEditingController();
  final _reconNoteController = TextEditingController();

  @override
  void dispose() {
    _countedController.dispose();
    _reconNoteController.dispose();
    super.dispose();
  }

  String _dateText(DateTime date) => '${date.day}/${date.month}/${date.year}';

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
    );
    if (picked != null) {
      setState(() {
        _selectedDate = picked;
        _allDates = false;
      });
    }
  }

  Future<void> _showAddEntryDialog(String branchId) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => _CashbookEntryDialog(branchId: branchId),
    );
    if (saved == true && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Cashbook entry recorded.')));
    }
  }

  Future<void> _showCloseDayDialog(
    String branchId,
    DailyClosingTotals totals,
  ) async {
    final closed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => _CloseDayDialog(
        branchId: branchId,
        date: _selectedDate,
        totals: totals,
      ),
    );
    if (closed == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Day ${_dateText(_selectedDate)} closed.')),
      );
    }
  }

  /// Opens the closing-correction dialog (Week 5 Day 4, D156 —
  /// FR-FIN-06): records a reversing entry for [closing] with the
  /// corrected totals. The original closing is never edited.
  Future<void> _showCorrectClosingDialog(DailyClosing closing) async {
    final corrected = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => _CorrectClosingDialog(closing: closing),
    );
    if (corrected == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Closing for ${_dateText(closing.date)} corrected — the original record is unchanged.',
          ),
        ),
      );
    }
  }

  /// Records the drawer count for the selected day (Week 5 Day 4,
  /// D157): the expected drawer is computed live, the counted cash
  /// comes from [_countedController], and the difference is
  /// recorded. Returns nothing — errors surface in a snackbar.
  Future<void> _recordReconciliation(String branchId) async {
    final countedText = _countedController.text.trim();
    final counted = int.tryParse(countedText);
    if (counted == null || counted < 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Counted cash must be a whole number of rupees.'),
        ),
      );
      return;
    }
    final result = await ref
        .read(cashReconciliationsProvider.notifier)
        .reconcileDay(
          branchId: branchId,
          date: _selectedDate,
          countedMinor: counted * 100,
          note: _reconNoteController.text.trim(),
        );
    if (!mounted) return;
    final saved = result.reconciliation;
    if (saved == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.error ?? 'Could not record the count.')),
      );
      return;
    }
    _countedController.clear();
    _reconNoteController.clear();
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          saved.isExact
              ? 'Drawer reconciled — exact match.'
              : saved.isOver
              ? 'Drawer reconciled — ${formatPkr(saved.differenceMinor)} over.'
              : 'Drawer reconciled — ${formatPkr(-saved.differenceMinor)} short.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final branch = ref.watch(activeBranchProvider);
    final user = ref.watch(authProvider);
    final mayWrite = permissionService.canWrite(
      user,
      'financeEntry',
      branch.id,
    );
    final entries = ref.watch(cashbookEntriesProvider(branch.id));
    final closingsAsync = ref.watch(dailyClosingsProvider);
    // Week 5 Day 4 (D156/D157): the corrections for these closings
    // and the drawer counts for this branch, newest first.
    final corrections =
        ref.watch(closingCorrectionsProvider).asData?.value ??
        const <ClosingCorrection>[];
    final reconciliations = [
      ...?ref
          .watch(cashReconciliationsProvider)
          .asData
          ?.value
          .where((r) => r.branchId == branch.id),
    ];
    reconciliations.sort((a, b) => b.date.compareTo(a.date));
    final branchSales = (ref.watch(salesProvider).asData?.value ?? const [])
        .where((sale) => sale.branchId == branch.id)
        .toList();
    // Fresh growable copy: the provider's list is unmodifiable, and
    // while it is still loading there is no list at all — sorting
    // either in place would throw (a const fallback is unmodifiable
    // too).
    final closings = [
      ...?closingsAsync.asData?.value.where(
        (closing) => closing.branchId == branch.id,
      ),
    ];
    closings.sort((a, b) => b.date.compareTo(a.date));

    final day = DateTime(
      _selectedDate.year,
      _selectedDate.month,
      _selectedDate.day,
    );
    final shown = _allDates
        ? entries
        : entries.where((entry) {
            final entryDay = DateTime(
              entry.date.year,
              entry.date.month,
              entry.date.day,
            );
            return entryDay == day;
          }).toList();
    var moneyIn = 0;
    var moneyOut = 0;
    for (final entry in shown) {
      if (entry.kind == CashbookEntryKind.income) {
        moneyIn += entry.amountMinor;
      } else {
        moneyOut += entry.amountMinor;
      }
    }
    final alreadyClosed = closings.any(
      (closing) =>
          DateTime(closing.date.year, closing.date.month, closing.date.day) ==
          day,
    );
    final closeTotals = _allDates
        ? null
        : computeDailyClosing(
            entries: entries,
            date: day,
            openingBalanceMinor: previousClosingBalance(
              closings: closings,
              branchId: branch.id,
              date: day,
            ),
          );
    // Week 5 Day 4 (D157): the expected drawer for the selected day
    // — opening + cash sales + cashbook income − cashbook expenses.
    // Only meaningful for one day, so it is null while all dates
    // are shown.
    final expectedDrawer = _allDates
        ? null
        : expectedDrawerMinor(
            sales: branchSales,
            entries: entries,
            openingBalanceMinor: previousClosingBalance(
              closings: closings,
              branchId: branch.id,
              date: day,
            ),
            date: day,
          );

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            title: 'Cashbook',
            subtitle:
                'Income and expense entries — ${branch.name}. Amounts are whole rupees.',
            actionLabel: mayWrite ? 'Add entry' : null,
            actionIcon: Icons.add_outlined,
            onAction: mayWrite ? () => _showAddEntryDialog(branch.id) : null,
          ),
          if (!mayWrite) ...[
            const SizedBox(height: 12),
            const Text(
              'Recording entries needs the "Finance: income/expense entry" '
              'permission (SRS §5.1) — Owner, HO Admin, Accountant, or '
              'your own Branch Manager / Cashier.',
              style: TextStyle(fontSize: 12),
            ),
          ],
          const SizedBox(height: 8),
          const SyncStatusChip(),
          const SizedBox(height: 16),
          // Day filter + close action.
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              PharmaButton(
                label: 'Day: ${_dateText(_selectedDate)}',
                variant: PharmaButtonVariant.secondary,
                size: PharmaButtonSize.small,
                icon: Icons.calendar_today_outlined,
                onPressed: _pickDate,
              ),
              PharmaButton(
                label: _allDates ? 'Showing all dates' : 'Show all dates',
                variant: PharmaButtonVariant.secondary,
                size: PharmaButtonSize.small,
                onPressed: () => setState(() => _allDates = !_allDates),
              ),
              if (!_allDates && mayWrite)
                PharmaButton(
                  label: alreadyClosed ? 'Day closed' : 'Close this day',
                  variant: PharmaButtonVariant.secondary,
                  size: PharmaButtonSize.small,
                  icon: Icons.lock_outlined,
                  onPressed: alreadyClosed || closeTotals == null
                      ? null
                      : () => _showCloseDayDialog(branch.id, closeTotals),
                ),
            ],
          ),
          const SizedBox(height: 16),
          // Summary for the filtered set.
          PharmaCard(
            child: Column(
              children: [
                _SummaryRow(label: 'Money in', amountMinor: moneyIn),
                _SummaryRow(label: 'Money out', amountMinor: -moneyOut),
                const Divider(height: 16),
                _SummaryRow(
                  label: 'Net',
                  amountMinor: moneyIn - moneyOut,
                  bold: true,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          PagedList<CashbookEntry>(
            items: shown,
            pageSize: 10,
            emptyMessage: _allDates
                ? 'No cashbook entries yet for this branch.'
                : 'No cashbook entries for ${_dateText(_selectedDate)} yet.',
            itemBuilder: (context, entry) => _CashbookEntryRow(entry: entry),
          ),
          const SizedBox(height: 24),
          const SectionHeader(
            title: 'Daily closings',
            subtitle: 'One snapshot record per day — totals at close time. Entries added later never rewrite a closing.',
          ),
          const SizedBox(height: 12),
          closingsAsync.when(
            loading: () => const SkeletonList(count: 2),
            error: (error, _) => Text('Closings could not load: $error'),
            data: (_) => PagedList<DailyClosing>(
              items: closings,
              pageSize: 10,
              emptyMessage: 'No day has been closed yet for this branch.',
              itemBuilder: (context, closing) => _ClosingRow(
                closing: closing,
                stale: dailyClosingIsStale(closing: closing, entries: entries),
                // Week 5 Day 4 (D156): the row shows the corrected
                // figures when a reversing entry exists — the
                // original record is never rewritten.
                adjusted: adjustedClosingTotals(
                  original: closing,
                  corrections: corrections,
                ),
                latestCorrection: corrections
                    .where((c) => c.originalClosingId == closing.id)
                    .fold<ClosingCorrection?>(null, (latest, c) {
                      if (latest == null) return c;
                      final latestAt = latest.correctedAt;
                      final thisAt = c.correctedAt;
                      if (thisAt != null &&
                          (latestAt == null || !thisAt.isBefore(latestAt))) {
                        return c;
                      }
                      return latest;
                    }),
                dateText: _dateText,
                onCorrect: mayWrite
                    ? () => _showCorrectClosingDialog(closing)
                    : null,
              ),
            ),
          ),
          const SizedBox(height: 24),
          const SectionHeader(
            title: 'Cash reconciliation',
            subtitle: 'Count the drawer against the expected cash for the selected day — the difference is recorded, never absorbed.',
          ),
          const SizedBox(height: 12),
          PharmaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_allDates)
                  const Text('Pick one day above to reconcile its drawer.')
                else ...[
                  _SummaryRow(
                    label: 'Expected drawer',
                    amountMinor: expectedDrawer ?? 0,
                    bold: true,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Opening + cash sales + cashbook income − cashbook expenses for ${_dateText(_selectedDate)}. Card and credit sales never touch the drawer.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  PharmaTextField(
                    key: const ValueKey('recon-counted-field'),
                    controller: _countedController,
                    label: 'Counted cash in drawer (Rs)',
                    hintText: 'Whole rupees counted',
                    keyboardType: TextInputType.number,
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 8),
                  PharmaTextField(
                    key: const ValueKey('recon-note-field'),
                    controller: _reconNoteController,
                    label: 'Note (optional)',
                    hintText: 'e.g. shortfall traced to a missed entry',
                  ),
                  const SizedBox(height: 12),
                  PharmaButton(
                    key: const ValueKey('recon-record'),
                    // Short label on purpose: the full-width button
                    // inside the card is 310px at 390px width, and
                    // 'Record drawer count' overflows it by 41px.
                    label: 'Record count',
                    icon: Icons.fact_check_outlined,
                    onPressed: mayWrite
                        ? () => _recordReconciliation(branch.id)
                        : null,
                  ),
                  if (!mayWrite)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text(
                        'Recording a count needs the "Finance: income/expense entry" permission (SRS §5.1).',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
          PagedList<CashReconciliation>(
            items: reconciliations,
            pageSize: 10,
            emptyMessage: 'No drawer count recorded yet for this branch.',
            itemBuilder: (context, recon) =>
                _ReconciliationRow(reconciliation: recon, dateText: _dateText),
          ),
        ],
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({
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

class _CashbookEntryRow extends StatelessWidget {
  const _CashbookEntryRow({required this.entry});

  final CashbookEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isIncome = entry.kind == CashbookEntryKind.income;
    final date = '${entry.date.day}/${entry.date.month}/${entry.date.year}';
    return PharmaCard(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(
          isIncome ? Icons.arrow_downward : Icons.arrow_upward,
          color: isIncome ? Colors.green : theme.colorScheme.error,
        ),
        title: Text(
          entry.note.isEmpty
              ? entry.category
              : '${entry.category} — ${entry.note}',
        ),
        subtitle: Text('$date • ${isIncome ? 'Income' : 'Expense'}'),
        trailing: Text(
          '${isIncome ? '+' : '−'}${formatPkr(entry.amountMinor)}',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: isIncome ? Colors.green : theme.colorScheme.error,
          ),
        ),
      ),
    );
  }
}

class _ClosingRow extends StatelessWidget {
  const _ClosingRow({
    required this.closing,
    required this.stale,
    required this.adjusted,
    required this.latestCorrection,
    required this.dateText,
    required this.onCorrect,
  });

  final DailyClosing closing;
  final bool stale;

  /// The figures the closing stands at after corrections (D156) —
  /// the original totals when uncorrected.
  final AdjustedClosingTotals adjusted;

  /// The latest reversing entry for this closing, if any.
  final ClosingCorrection? latestCorrection;

  final String Function(DateTime) dateText;

  /// Opens the correction dialog, or `null` when the caller may not
  /// correct closings in this branch.
  final VoidCallback? onCorrect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final correction = latestCorrection;
    return PharmaCard(
      margin: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            leading: Icon(
              Icons.lock_outlined,
              color: theme.colorScheme.primary,
            ),
            title: Text(
              'Closed ${dateText(closing.date)}',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'In ${formatPkr(closing.totalIncomeMinor)} • '
                  'Out ${formatPkr(closing.totalExpenseMinor)} • '
                  'Opening ${formatPkr(closing.openingBalanceMinor)}',
                ),
                if (stale)
                  Text(
                    'Changed since closing — entries were added for this day after the close.',
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.error,
                    ),
                  ),
                if (closing.note.isNotEmpty) Text(closing.note),
                if (adjusted.corrected && correction != null) ...[
                  Text(
                    'Corrected: In ${formatPkr(adjusted.incomeMinor)} • '
                    'Out ${formatPkr(adjusted.expenseMinor)} • '
                    'Balance ${formatPkr(adjusted.closingBalanceMinor)}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  Text(
                    'Reason: ${correction.reason}'
                    '${correction.correctedBy == null ? '' : ' • by ${correction.correctedBy}'}',
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ],
            ),
            trailing: Text(
              formatPkr(adjusted.closingBalanceMinor),
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          if (onCorrect != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: PharmaButton(
                key: ValueKey('correct-closing-${closing.id}'),
                label: adjusted.corrected ? 'Correct again' : 'Correct closing',
                icon: Icons.edit_outlined,
                variant: PharmaButtonVariant.secondary,
                size: PharmaButtonSize.small,
                onPressed: onCorrect,
              ),
            ),
        ],
      ),
    );
  }
}

/// One recorded drawer count (Week 5 Day 4, D157): date, expected
/// vs counted, and the difference — over, short, or exact.
class _ReconciliationRow extends StatelessWidget {
  const _ReconciliationRow({
    required this.reconciliation,
    required this.dateText,
  });

  final CashReconciliation reconciliation;
  final String Function(DateTime) dateText;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final recon = reconciliation;
    final differenceLabel = recon.isExact
        ? 'Exact match'
        : recon.isOver
        ? '${formatPkr(recon.differenceMinor)} over'
        : '${formatPkr(-recon.differenceMinor)} short';
    return PharmaCard(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(
          recon.isExact
              ? Icons.check_circle_outline
              : Icons.warning_amber_outlined,
          color: recon.isExact ? Colors.green : theme.colorScheme.error,
        ),
        title: Text(
          'Counted ${dateText(recon.date)} — $differenceLabel',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Expected ${formatPkr(recon.expectedMinor)} • '
              'Counted ${formatPkr(recon.countedMinor)}',
            ),
            if (recon.note.isNotEmpty) Text(recon.note),
          ],
        ),
        trailing: Text(
          '${recon.differenceMinor >= 0 ? '+' : '−'}${formatPkr(recon.differenceMinor.abs())}',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: recon.isExact ? Colors.green : theme.colorScheme.error,
          ),
        ),
      ),
    );
  }
}

/// Add-entry dialog: income or expense, date, fixed category list,
/// whole-rupee amount, note (expense only — income transactions
/// carry no note field, D125).
class _CashbookEntryDialog extends ConsumerStatefulWidget {
  const _CashbookEntryDialog({required this.branchId});

  final String branchId;

  @override
  ConsumerState<_CashbookEntryDialog> createState() =>
      _CashbookEntryDialogState();
}

class _CashbookEntryDialogState extends ConsumerState<_CashbookEntryDialog> {
  bool _isIncome = false;
  String _category = expenseCategories.first;
  DateTime _date = DateTime.now();
  final _amount = TextEditingController();
  final _note = TextEditingController();
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  List<String> get _categories =>
      _isIncome ? incomeCategories : expenseCategories;

  Future<void> _save() async {
    final rupees = int.tryParse(_amount.text.trim());
    if (rupees == null) {
      setState(() => _error = 'Enter a whole-rupee amount.');
      return;
    }
    setState(() => _saving = true);
    final amountMinor = rupees * 100;
    String? error;
    if (_isIncome) {
      final result = await ref
          .read(financialTransactionsProvider.notifier)
          .recordIncome(
            branchId: widget.branchId,
            category: _category,
            amountMinor: amountMinor,
            date: _date,
          );
      error = result.error;
    } else {
      final result = await ref
          .read(expensesProvider.notifier)
          .recordExpense(
            branchId: widget.branchId,
            category: _category,
            amountMinor: amountMinor,
            description: _note.text,
            expenseDate: _date,
          );
      error = result.error;
    }
    if (!mounted) return;
    setState(() => _saving = false);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add cashbook entry'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error != null) ...[
              PharmaErrorBox(errors: [_error!]),
              const SizedBox(height: 12),
            ],
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment<bool>(
                  value: false,
                  label: Text('Expense'),
                  icon: Icon(Icons.arrow_upward, size: 18),
                ),
                ButtonSegment<bool>(
                  value: true,
                  label: Text('Income'),
                  icon: Icon(Icons.arrow_downward, size: 18),
                ),
              ],
              selected: {_isIncome},
              onSelectionChanged: (selected) {
                setState(() {
                  _isIncome = selected.single;
                  _category = _categories.first;
                  _error = null;
                });
              },
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _category,
              decoration: const InputDecoration(labelText: 'Category'),
              items: [
                for (final category in _categories)
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
              label: 'Amount (Rs, whole rupees)',
              hintText: 'e.g. 5000',
              keyboardType: TextInputType.number,
              autofocus: true,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Date: ${_date.day}/${_date.month}/${_date.year}',
                  ),
                ),
                TextButton(
                  onPressed: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: _date,
                      firstDate: DateTime(2020),
                      lastDate: DateTime.now(),
                    );
                    if (picked != null) setState(() => _date = picked);
                  },
                  child: const Text('Change'),
                ),
              ],
            ),
            if (!_isIncome) ...[
              const SizedBox(height: 12),
              PharmaTextField(
                controller: _note,
                label: 'Note',
                hintText: 'What was this for?',
              ),
            ],
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
          label: _saving ? 'Saving…' : 'Save entry',
          size: PharmaButtonSize.small,
          onPressed: _saving ? null : _save,
        ),
      ],
    );
  }
}

/// Close-day dialog: shows the live totals for the day and saves the
/// closing record. The totals are computed at confirm time by the
/// notifier from the live entries — what the dialog shows is what
/// gets recorded.
class _CloseDayDialog extends ConsumerStatefulWidget {
  const _CloseDayDialog({
    required this.branchId,
    required this.date,
    required this.totals,
  });

  final String branchId;
  final DateTime date;
  final DailyClosingTotals totals;

  @override
  ConsumerState<_CloseDayDialog> createState() => _CloseDayDialogState();
}

class _CloseDayDialogState extends ConsumerState<_CloseDayDialog> {
  final _note = TextEditingController();
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _close() async {
    setState(() => _saving = true);
    final result = await ref
        .read(dailyClosingsProvider.notifier)
        .closeDay(
          branchId: widget.branchId,
          date: widget.date,
          note: _note.text,
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
    final totals = widget.totals;
    final date = '${widget.date.day}/${widget.date.month}/${widget.date.year}';
    return AlertDialog(
      title: Text('Close day — $date'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error != null) ...[
              PharmaErrorBox(errors: [_error!]),
              const SizedBox(height: 12),
            ],
            _SummaryRow(label: 'Money in', amountMinor: totals.incomeMinor),
            _SummaryRow(label: 'Money out', amountMinor: -totals.expenseMinor),
            _SummaryRow(
              label: 'Opening balance',
              amountMinor: totals.openingBalanceMinor,
            ),
            const Divider(height: 16),
            _SummaryRow(
              label: 'Closing balance',
              amountMinor: totals.closingBalanceMinor,
              bold: true,
            ),
            const SizedBox(height: 12),
            const Text(
              'This saves a closing record for the day. Entries added '
              'later will not change it — the closing will be flagged as '
              'changed instead.',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            PharmaTextField(
              controller: _note,
              label: 'Note (optional)',
              hintText: 'e.g. Cash counted, matches drawer',
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
          label: _saving ? 'Closing…' : 'Close day',
          size: PharmaButtonSize.small,
          onPressed: _saving ? null : _close,
        ),
      ],
    );
  }
}

/// Correct-closing dialog (Week 5 Day 4, D156 — FR-FIN-06): the
/// reversing entry for a wrong closing.
///
/// The income / expense fields prefill with the figures the closing
/// stands at now (corrected figures when a correction already
/// exists, original figures otherwise) — the corrector edits the
/// wrong figure, states the reason, and saves. The original closing
/// is never edited: saving records a new correction linked to it.
/// The corrected closing balance is derived (`opening + income −
/// expense`), never typed.
class _CorrectClosingDialog extends ConsumerStatefulWidget {
  const _CorrectClosingDialog({required this.closing});

  final DailyClosing closing;

  @override
  ConsumerState<_CorrectClosingDialog> createState() =>
      _CorrectClosingDialogState();
}

class _CorrectClosingDialogState extends ConsumerState<_CorrectClosingDialog> {
  late final TextEditingController _income;
  late final TextEditingController _expense;
  final _reason = TextEditingController();
  final _note = TextEditingController();
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final corrections =
        ref.read(closingCorrectionsProvider).asData?.value ?? const [];
    final adjusted = adjustedClosingTotals(
      original: widget.closing,
      corrections: corrections,
    );
    _income = TextEditingController(
      text: (adjusted.incomeMinor ~/ 100).toString(),
    );
    _expense = TextEditingController(
      text: (adjusted.expenseMinor ~/ 100).toString(),
    );
  }

  @override
  void dispose() {
    _income.dispose();
    _expense.dispose();
    _reason.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final income = int.tryParse(_income.text.trim());
    final expense = int.tryParse(_expense.text.trim());
    if (income == null || income < 0 || expense == null || expense < 0) {
      setState(
        () => _error = 'Income and expense must be whole numbers of rupees.',
      );
      return;
    }
    setState(() {
      _error = null;
      _saving = true;
    });
    final result = await ref
        .read(closingCorrectionsProvider.notifier)
        .correctClosing(
          original: widget.closing,
          correctedIncomeMinor: income * 100,
          correctedExpenseMinor: expense * 100,
          reason: _reason.text,
          note: _note.text,
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
    final closing = widget.closing;
    final date =
        '${closing.date.day}/${closing.date.month}/${closing.date.year}';
    return AlertDialog(
      title: Text('Correct closing — $date'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error != null) ...[
              PharmaErrorBox(errors: [_error!]),
              const SizedBox(height: 12),
            ],
            Text(
              'Original: In ${formatPkr(closing.totalIncomeMinor)} • '
              'Out ${formatPkr(closing.totalExpenseMinor)} • '
              'Balance ${formatPkr(closing.closingBalanceMinor)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            const Text(
              'This records a reversing entry with the corrected totals. The original closing stays exactly as closed.',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            PharmaTextField(
              key: const ValueKey('correct-income-field'),
              controller: _income,
              label: 'Corrected income (Rs)',
              hintText: 'Whole rupees',
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 8),
            PharmaTextField(
              key: const ValueKey('correct-expense-field'),
              controller: _expense,
              label: 'Corrected expense (Rs)',
              hintText: 'Whole rupees',
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 8),
            PharmaTextField(
              key: const ValueKey('correct-reason-field'),
              controller: _reason,
              label: 'Reason (required)',
              hintText: 'e.g. Rs 500 income was entered twice',
            ),
            const SizedBox(height: 8),
            PharmaTextField(
              controller: _note,
              label: 'Note (optional)',
              hintText: 'Anything else for the record',
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
          key: const ValueKey('correct-closing-confirm'),
          label: _saving ? 'Saving…' : 'Record correction',
          size: PharmaButtonSize.small,
          onPressed: _saving ? null : _save,
        ),
      ],
    );
  }
}
