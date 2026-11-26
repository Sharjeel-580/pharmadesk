import 'model_utils.dart';

/// A correction to a daily closing (Week 5 Day 4, D156 — SRS D-24 /
/// FR-FIN-06).
///
/// A wrong closing is NEVER edited in place (D126): the correction
/// is a reversing entry — a NEW record linked to the original
/// closing ([originalClosingId]) that carries the CORRECTED totals
/// for that day. The original record stays exactly as closed (the
/// audit trail of what was first recorded); the corrected figures
/// are what the screens show from then on (see
/// `adjustedClosingTotals` in `finance_logic.dart` — the latest
/// correction's totals win, or the original's when no correction
/// exists).
///
/// Money is int paisa. The correction re-states the day's totals
/// in full (income / expense / closing balance) rather than a
/// delta, so a reader never has to sum a chain to know what the
/// day's figures are — the same "snapshot, not delta" shape as the
/// closing itself (D126).
class ClosingCorrection {
  final String id;
  final String branchId;

  /// The closing this corrects (never edited itself).
  final String originalClosingId;

  /// The day being corrected (date-only, same day as the original).
  final DateTime date;

  /// Corrected money in for the day (int paisa).
  final int correctedIncomeMinor;

  /// Corrected money out for the day (int paisa).
  final int correctedExpenseMinor;

  /// Corrected closing balance (`opening + income − expense`).
  final int correctedClosingBalanceMinor;

  /// Why the original was wrong — required, shown to the next
  /// reader of the closing.
  final String reason;

  final String? correctedBy;
  final DateTime? correctedAt;
  final String note;
  final bool isDemo;

  const ClosingCorrection({
    required this.id,
    required this.branchId,
    required this.originalClosingId,
    required this.date,
    required this.correctedIncomeMinor,
    required this.correctedExpenseMinor,
    required this.correctedClosingBalanceMinor,
    required this.reason,
    this.correctedBy,
    this.correctedAt,
    this.note = '',
    this.isDemo = false,
  });

  ClosingCorrection copyWith({
    String? id,
    String? branchId,
    String? originalClosingId,
    DateTime? date,
    int? correctedIncomeMinor,
    int? correctedExpenseMinor,
    int? correctedClosingBalanceMinor,
    String? reason,
    String? correctedBy,
    DateTime? correctedAt,
    String? note,
    bool? isDemo,
  }) {
    return ClosingCorrection(
      id: id ?? this.id,
      branchId: branchId ?? this.branchId,
      originalClosingId: originalClosingId ?? this.originalClosingId,
      date: date ?? this.date,
      correctedIncomeMinor: correctedIncomeMinor ?? this.correctedIncomeMinor,
      correctedExpenseMinor:
          correctedExpenseMinor ?? this.correctedExpenseMinor,
      correctedClosingBalanceMinor:
          correctedClosingBalanceMinor ?? this.correctedClosingBalanceMinor,
      reason: reason ?? this.reason,
      correctedBy: correctedBy ?? this.correctedBy,
      correctedAt: correctedAt ?? this.correctedAt,
      note: note ?? this.note,
      isDemo: isDemo ?? this.isDemo,
    );
  }

  factory ClosingCorrection.fromMap(String id, Map<String, dynamic> map) {
    return ClosingCorrection(
      id: id,
      branchId: map['branchId'] as String? ?? '',
      originalClosingId: map['originalClosingId'] as String? ?? '',
      date: parseDate(map['date']) ?? DateTime.now(),
      correctedIncomeMinor: (map['correctedIncome'] as num?)?.toInt() ?? 0,
      correctedExpenseMinor: (map['correctedExpense'] as num?)?.toInt() ?? 0,
      correctedClosingBalanceMinor:
          (map['correctedClosingBalance'] as num?)?.toInt() ?? 0,
      reason: map['reason'] as String? ?? '',
      correctedBy: map['correctedBy'] as String?,
      correctedAt: parseDate(map['correctedAt']),
      note: map['note'] as String? ?? '',
      isDemo: map['isDemo'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'branchId': branchId,
      'originalClosingId': originalClosingId,
      'date': dateToMap(date),
      'correctedIncome': correctedIncomeMinor,
      'correctedExpense': correctedExpenseMinor,
      'correctedClosingBalance': correctedClosingBalanceMinor,
      'reason': reason,
      'correctedBy': correctedBy,
      'correctedAt': dateToMap(correctedAt),
      'note': note,
      'isDemo': isDemo,
    };
  }
}
