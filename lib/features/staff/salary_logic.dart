import '../../core/data/auth_repository.dart';
import '../../core/data/permission_service.dart';
import '../../models/salary_record.dart';
import '../../models/staff.dart';

/// Week 3 Day 2 salary logic — pure functions over plain values.
///
/// Salary figures live in a separate payroll record
/// ([SalaryRecord]), NOT on the [Staff] model (D102): salary is
/// sensitive (only `hrSalary` holders may see it), and monthly
/// figures change over time. The edit flow landed Week 3 Day 4
/// (D112) — the dialog calls `SalaryNotifier.saveRecord`, which
/// gates on [canManageSalary] and validates with
/// [validateSalaryRecord] before the repository writes.
///
/// Permissions come from the SRS §5.1 matrix via the Day 3
/// permission service (D70): `hrSalary` — Owner allowed, HO Admin
/// allowed, Accountant allowed, Auditor read-only, everyone else
/// none. Nobody assumes a role from a job title — the matrix
/// governs.

/// True when [user] may view salary records in [branchId] — the
/// `hrSalary` capability (viewing counts: Auditor is read-only and
/// may still view).
bool canViewSalary(AppUser? user, String branchId) =>
    permissionService.canInBranch(user, 'hrSalary', branchId);

/// True when [user] may change salary records in [branchId] —
/// mutations only (`readOnly` is false here).
bool canManageSalary(AppUser? user, String branchId) =>
    permissionService.canWrite(user, 'hrSalary', branchId);

/// Month key `YYYY-MM` for a date.
String salaryMonthKey(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}';

const _monthNames = <String>[
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

/// Human label for a month key: `2026-11` → `November 2026`.
String salaryMonthLabel(String monthKey) {
  final parts = monthKey.split('-');
  if (parts.length != 2) return monthKey;
  final year = int.tryParse(parts[0]);
  final month = int.tryParse(parts[1]);
  if (year == null || month == null || month < 1 || month > 12) {
    return monthKey;
  }
  return '${_monthNames[month - 1]} $year';
}

/// The month key one month before [monthKey] (`2026-11` → `2026-10`).
String previousSalaryMonth(String monthKey) {
  final parts = monthKey.split('-');
  final year = int.tryParse(parts[0]) ?? DateTime.now().year;
  final month = int.tryParse(parts[1]) ?? DateTime.now().month;
  if (month <= 1) {
    return '${year - 1}-12';
  }
  return '$year-${(month - 1).toString().padLeft(2, '0')}';
}

/// The month key one month after [monthKey] (`2026-11` → `2026-12`).
String nextSalaryMonth(String monthKey) {
  final parts = monthKey.split('-');
  final year = int.tryParse(parts[0]) ?? DateTime.now().year;
  final month = int.tryParse(parts[1]) ?? DateTime.now().month;
  if (month >= 12) {
    return '${year + 1}-01';
  }
  return '$year-${(month + 1).toString().padLeft(2, '0')}';
}

/// Validates a salary record before saving. Returns the list of
/// problems (empty = valid). The repositories mirror these checks
/// so a direct caller cannot write a bad record either.
List<String> validateSalaryRecord(SalaryRecord record) {
  final errors = <String>[];
  if (record.employeeId.isEmpty) {
    errors.add('A salary record needs an employee.');
  }
  if (record.branchId.isEmpty) {
    errors.add('A salary record needs a branch.');
  }
  final month = record.month;
  final monthPattern = RegExp(r'^\d{4}-(0[1-9]|1[0-2])$');
  if (!monthPattern.hasMatch(month)) {
    errors.add('Month must look like YYYY-MM (e.g. 2026-11).');
  }
  if (record.baseSalaryMinor < 0) {
    errors.add('Base salary cannot be negative.');
  }
  if (record.allowancesMinor < 0) {
    errors.add('Allowances cannot be negative.');
  }
  if (record.deductionsMinor < 0) {
    errors.add('Deductions cannot be negative.');
  }
  if (record.netMinor < 0) {
    errors.add('Net salary cannot be negative — deductions exceed pay.');
  }
  return errors;
}

/// One row of the salary screen: the employee and their record for
/// the month ([record] is null when no record exists yet for that
/// month — the row still shows, with no figures).
class SalaryRow {
  const SalaryRow({required this.employee, this.record});

  final Staff employee;
  final SalaryRecord? record;

  /// True when the employee has a salary record for the month.
  bool get hasRecord => record != null;

  /// True when the shown figures are seeded demo figures.
  bool get isDemo => record?.isDemo ?? false;
}

/// Builds the salary screen's rows for [month]: one row per active
/// staff member at the branch (all branches when [branchId] is
/// null), each with their record for the month when one exists.
/// Inactive staff never appear — they are not on this month's
/// payroll. Rows sort by employee name.
List<SalaryRow> salaryRowsFor({
  required List<Staff> staff,
  required List<SalaryRecord> records,
  required String month,
  String? branchId,
}) {
  final scopedStaff = staff
      .where(
        (member) =>
            member.active &&
            (branchId == null || member.branchId == branchId),
      )
      .toList()
    ..sort((a, b) => a.name.compareTo(b.name));
  SalaryRecord? recordFor(String employeeId) {
    for (final record in records) {
      if (record.employeeId == employeeId && record.month == month) {
        return record;
      }
    }
    return null;
  }

  return [
    for (final member in scopedStaff)
      SalaryRow(employee: member, record: recordFor(member.id)),
  ];
}

/// Monthly totals across the screen's rows (recorded employees
/// only — a row without a record contributes nothing).
class MonthlySalaryTotals {
  const MonthlySalaryTotals({
    required this.baseMinor,
    required this.allowancesMinor,
    required this.deductionsMinor,
    required this.netMinor,
    required this.employeeCount,
    required this.recordedCount,
  });

  final int baseMinor;
  final int allowancesMinor;
  final int deductionsMinor;
  final int netMinor;

  /// Employees on the payroll view (active staff at the branch).
  final int employeeCount;

  /// Employees with a record for the month.
  final int recordedCount;

  /// True when every shown employee has a record for the month.
  bool get isComplete => recordedCount == employeeCount;
}

MonthlySalaryTotals monthlySalaryTotals(List<SalaryRow> rows) {
  var base = 0;
  var allowances = 0;
  var deductions = 0;
  var net = 0;
  var recorded = 0;
  for (final row in rows) {
    final record = row.record;
    if (record == null) continue;
    recorded++;
    base += record.baseSalaryMinor;
    allowances += record.allowancesMinor;
    deductions += record.deductionsMinor;
    net += record.netMinor;
  }
  return MonthlySalaryTotals(
    baseMinor: base,
    allowancesMinor: allowances,
    deductionsMinor: deductions,
    netMinor: net,
    employeeCount: rows.length,
    recordedCount: recorded,
  );
}
