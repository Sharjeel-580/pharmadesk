import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/money.dart';
import '../../core/widgets/design_system.dart';
import '../../models/salary_record.dart';
import '../../models/staff.dart';
import '../authentication/auth_state.dart';
import 'salary_logic.dart';
import 'salary_provider.dart';

/// Salary edit dialog (Week 3 Day 4, D112).
///
/// Opens from the salary screen's per-row Edit button. Edits the
/// base salary, allowances and deductions for one employee and one
/// month (whole rupees in, int paisa stored — D6); the net is shown
/// live as base + allowances − deductions and can never go
/// negative. Saving creates the record when the month has none yet,
/// or replaces it when one exists (the repository keys by
/// employee + month, so a re-save never duplicates).
///
/// Gating: the Edit button only renders when
/// `canManageSalary` passes, and [SalaryNotifier.saveRecord]
/// re-checks the same gate — a dialog opened by any other path
/// still cannot save without `hrSalary` write.
///
/// An edited demo record stops being demo: the saved record has
/// `isDemo: false`, because the figures are now staff-entered, not
/// the seeded sample payroll.
Future<SalaryRecord?> showSalaryEditDialog(
  BuildContext context,
  WidgetRef ref, {
  required Staff employee,
  required String month,
  SalaryRecord? record,
}) {
  return showDialog<SalaryRecord>(
    context: context,
    builder: (dialogContext) => _SalaryEditDialog(
      employee: employee,
      month: month,
      record: record,
    ),
  );
}

class _SalaryEditDialog extends ConsumerStatefulWidget {
  const _SalaryEditDialog({
    required this.employee,
    required this.month,
    this.record,
  });

  final Staff employee;
  final String month;
  final SalaryRecord? record;

  @override
  ConsumerState<_SalaryEditDialog> createState() =>
      _SalaryEditDialogState();
}

class _SalaryEditDialogState extends ConsumerState<_SalaryEditDialog> {
  late final TextEditingController _baseController;
  late final TextEditingController _allowancesController;
  late final TextEditingController _deductionsController;
  String? _error;
  bool _saving = false;

  /// Whole rupees, or null when the field is not a whole number.
  int? get _baseRupees => int.tryParse(_baseController.text.trim());

  int? get _allowancesRupees =>
      int.tryParse(_allowancesController.text.trim());

  int? get _deductionsRupees =>
      int.tryParse(_deductionsController.text.trim());

  /// Live net in rupees (null until every field parses).
  int? get _netRupees {
    final base = _baseRupees;
    final allowances = _allowancesRupees;
    final deductions = _deductionsRupees;
    if (base == null || allowances == null || deductions == null) {
      return null;
    }
    return base + allowances - deductions;
  }

  @override
  void initState() {
    super.initState();
    final record = widget.record;
    _baseController = TextEditingController(
      text: record == null
          ? ''
          : (record.baseSalaryMinor ~/ 100).toString(),
    );
    _allowancesController = TextEditingController(
      text: record == null
          ? '0'
          : (record.allowancesMinor ~/ 100).toString(),
    );
    _deductionsController = TextEditingController(
      text: record == null
          ? '0'
          : (record.deductionsMinor ~/ 100).toString(),
    );
  }

  @override
  void dispose() {
    _baseController.dispose();
    _allowancesController.dispose();
    _deductionsController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final base = _baseRupees;
    final allowances = _allowancesRupees;
    final deductions = _deductionsRupees;
    String? error;
    if (base == null || base < 0) {
      error = 'Base salary must be a whole number of rupees (0 or more).';
    } else if (allowances == null || allowances < 0) {
      error = 'Allowances must be a whole number of rupees (0 or more).';
    } else if (deductions == null || deductions < 0) {
      error = 'Deductions must be a whole number of rupees (0 or more).';
    } else if (base + allowances - deductions < 0) {
      error =
          'Net salary cannot be negative — deductions exceed base + allowances.';
    }
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    setState(() {
      _error = null;
      _saving = true;
    });
    final user = ref.read(authProvider);
    final result = await ref
        .read(salaryProvider.notifier)
        .saveRecord(
          record: SalaryRecord(
            id: widget.record?.id ?? '',
            employeeId: widget.employee.id,
            branchId: widget.employee.branchId,
            month: widget.month,
            baseSalaryMinor: rupeesToMinorUnits(base!),
            allowancesMinor: rupeesToMinorUnits(allowances!),
            deductionsMinor: rupeesToMinorUnits(deductions!),
            // An edited record is staff-entered, not the seeded
            // sample payroll — it stops being demo (D112).
            isDemo: false,
          ),
          user: user,
        );
    if (!mounted) return;
    setState(() => _saving = false);
    if (result.error != null) {
      setState(() => _error = result.error);
      return;
    }
    Navigator.of(context).pop(result.record);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final net = _netRupees;
    final existing = widget.record;
    return AlertDialog(
      title: Text(
        existing == null
            ? 'Set salary — ${widget.employee.name}'
            : 'Edit salary — ${widget.employee.name}',
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${salaryMonthLabel(widget.month)} • '
              '${widget.employee.jobTitle.isEmpty ? '—' : widget.employee.jobTitle}',
              style: theme.textTheme.bodyMedium,
            ),
            if (existing != null && existing.isDemo) ...[
              const SizedBox(height: 8),
              const Text(
                'This row currently shows seeded demo figures. Saving '
                'replaces them with the figures entered here.',
              ),
            ],
            const SizedBox(height: 16),
            PharmaTextField(
              controller: _baseController,
              label: 'Base salary (Rs)',
              hintText: 'e.g. 85000',
              keyboardType: TextInputType.number,
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            PharmaTextField(
              controller: _allowancesController,
              label: 'Allowances (Rs)',
              hintText: 'e.g. 5000',
              keyboardType: TextInputType.number,
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            PharmaTextField(
              controller: _deductionsController,
              label: 'Deductions (Rs)',
              hintText: 'e.g. 2000',
              keyboardType: TextInputType.number,
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 16),
            Text(
              net == null
                  ? 'Net: —'
                  : 'Net: ${formatPkr(rupeesToMinorUnits(net))}',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: net != null && net < 0
                    ? StatusKind.danger.color
                    : null,
              ),
            ),
            const SizedBox(height: 4),
            const Text('Net = base + allowances − deductions.'),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: StatusKind.danger.color),
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
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
        ),
        PharmaButton(
          label: _saving ? 'Saving…' : 'Save salary',
          size: PharmaButtonSize.small,
          onPressed: _saving ? null : _save,
        ),
      ],
    );
  }
}
