import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/data/permission_service.dart';
import '../../core/services/branch_context.dart';
import '../../core/utils/money.dart';
import '../../core/widgets/design_system.dart';
import '../../core/widgets/pagination_controls.dart';
import '../../core/widgets/sync_status_widget.dart';
import '../../models/daily_closing.dart';
import '../../models/expense.dart';
import '../authentication/auth_state.dart';
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

  String _dateText(DateTime date) =>
      '${date.day}/${date.month}/${date.year}';

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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cashbook entry recorded.')),
      );
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
        SnackBar(
          content: Text('Day ${_dateText(_selectedDate)} closed.'),
        ),
      );
    }
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
          DateTime(
            closing.date.year,
            closing.date.month,
            closing.date.day,
          ) ==
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
            subtitle:
                'One snapshot record per day — totals at close time. Entries added later never rewrite a closing.',
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
                stale: dailyClosingIsStale(
                  closing: closing,
                  entries: entries,
                ),
                dateText: _dateText,
              ),
            ),
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
    final date =
        '${entry.date.day}/${entry.date.month}/${entry.date.year}';
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
    required this.dateText,
  });

  final DailyClosing closing;
  final bool stale;
  final String Function(DateTime) dateText;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PharmaCard(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
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
          ],
        ),
        trailing: Text(
          formatPkr(closing.closingBalanceMinor),
          style: const TextStyle(fontWeight: FontWeight.w700),
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
      final result = await ref.read(expensesProvider.notifier).recordExpense(
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
    final result = await ref.read(dailyClosingsProvider.notifier).closeDay(
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
    final date =
        '${widget.date.day}/${widget.date.month}/${widget.date.year}';
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
            _SummaryRow(
              label: 'Money out',
              amountMinor: -totals.expenseMinor,
            ),
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
