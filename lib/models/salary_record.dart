import 'model_utils.dart';

/// One employee's salary record for one month (Week 3 Day 2, D102).
///
/// **Where salary figures live:** in this record — NOT on the
/// [Staff] model. Salary is sensitive (only `hrSalary` holders may
/// see it: Owner / HO Admin / Accountant; a Branch Manager has
/// `users: own` but `hrSalary: none`, so a salary field on the Staff
/// model would leak figures into the directory fetch), and monthly
/// figures change over time (history matters). One record per
/// (employee, month); the doc id is `sal-{employeeId}-{yyyy-MM}` so
/// a re-save overwrites the same record instead of duplicating it.
///
/// All money is int paisa per month (D6). `netMinor` is always
/// `base + allowances − deductions` — the repositories refuse a
/// record whose stored net disagrees, so the figure can never drift.
///
/// `isDemo` marks seeded demo figures: clearly-marked fictional
/// sample payroll, never real data. The salary screen labels demo
/// figures as demo/sample whenever it shows them.
class SalaryRecord {
  const SalaryRecord({
    required this.id,
    required this.employeeId,
    required this.branchId,
    required this.month,
    required this.baseSalaryMinor,
    this.allowancesMinor = 0,
    this.deductionsMinor = 0,
    this.isDemo = false,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String employeeId;
  final String branchId;

  /// The month this record pays, as `YYYY-MM` (e.g. `2026-11`).
  final String month;

  /// Base monthly salary, int paisa.
  final int baseSalaryMinor;

  /// Monthly allowances (transport, etc.), int paisa.
  final int allowancesMinor;

  /// Monthly deductions (advance recovery, etc.), int paisa.
  final int deductionsMinor;

  /// True for seeded demo figures (fictional sample payroll).
  final bool isDemo;

  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// Take-home for the month: base + allowances − deductions.
  int get netMinor => baseSalaryMinor + allowancesMinor - deductionsMinor;

  SalaryRecord copyWith({
    String? id,
    String? employeeId,
    String? branchId,
    String? month,
    int? baseSalaryMinor,
    int? allowancesMinor,
    int? deductionsMinor,
    bool? isDemo,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return SalaryRecord(
      id: id ?? this.id,
      employeeId: employeeId ?? this.employeeId,
      branchId: branchId ?? this.branchId,
      month: month ?? this.month,
      baseSalaryMinor: baseSalaryMinor ?? this.baseSalaryMinor,
      allowancesMinor: allowancesMinor ?? this.allowancesMinor,
      deductionsMinor: deductionsMinor ?? this.deductionsMinor,
      isDemo: isDemo ?? this.isDemo,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  factory SalaryRecord.fromMap(String id, Map<String, dynamic> map) {
    return SalaryRecord(
      id: id,
      employeeId: map['employeeId'] as String? ?? '',
      branchId: map['branchId'] as String? ?? '',
      month: map['month'] as String? ?? '',
      baseSalaryMinor: (map['baseSalaryMinor'] as num?)?.toInt() ?? 0,
      allowancesMinor: (map['allowancesMinor'] as num?)?.toInt() ?? 0,
      deductionsMinor: (map['deductionsMinor'] as num?)?.toInt() ?? 0,
      isDemo: map['isDemo'] as bool? ?? false,
      createdAt: parseDate(map['createdAt']),
      updatedAt: parseDate(map['updatedAt']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'employeeId': employeeId,
      'branchId': branchId,
      'month': month,
      'baseSalaryMinor': baseSalaryMinor,
      'allowancesMinor': allowancesMinor,
      'deductionsMinor': deductionsMinor,
      'netMinor': netMinor,
      'isDemo': isDemo,
      'createdAt': dateToMap(createdAt),
      'updatedAt': dateToMap(updatedAt),
    };
  }
}
