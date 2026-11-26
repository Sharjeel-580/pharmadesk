import 'model_utils.dart';

/// One daily cashbook closing (Week 4 Day 3, D126 — SRS D-24 /
/// FR-FIN-02).
///
/// A closing is a RECORD, not an edit of the entries: it snapshots
/// the day's totals (money in / money out, from the cashbook entries
/// of that day) plus the opening balance carried from the previous
/// closing, and the resulting closing balance. Entries recorded after
/// the close do not rewrite it — the cashbook screen flags the
/// closing as changed-since-closing instead (see
/// `dailyClosingIsStale` in `finance_logic.dart`).
///
/// Money is int paisa. [date] is the calendar day being closed
/// (time-of-day ignored). Corrections follow FR-FIN-06: a wrong
/// closing is never edited in place — a reversing/adjusting entry
/// and a new closing record are the correction path (not built in
/// this day; see the Day 3 follow-ups).
class DailyClosing {
  final String id;
  final String branchId;

  /// The day being closed (date-only).
  final DateTime date;

  /// Money in that day (int paisa, from income entries).
  final int totalIncomeMinor;

  /// Money out that day (int paisa, from expense entries).
  final int totalExpenseMinor;

  /// Balance carried into the day (previous closing's closing
  /// balance, or 0 when no earlier closing exists).
  final int openingBalanceMinor;

  /// `opening + income − expense` at close time.
  final int closingBalanceMinor;

  final String? closedBy;
  final DateTime? closedAt;
  final String note;
  final bool isDemo;

  const DailyClosing({
    required this.id,
    required this.branchId,
    required this.date,
    required this.totalIncomeMinor,
    required this.totalExpenseMinor,
    required this.openingBalanceMinor,
    required this.closingBalanceMinor,
    this.closedBy,
    this.closedAt,
    this.note = '',
    this.isDemo = false,
  });

  DailyClosing copyWith({
    String? id,
    String? branchId,
    DateTime? date,
    int? totalIncomeMinor,
    int? totalExpenseMinor,
    int? openingBalanceMinor,
    int? closingBalanceMinor,
    String? closedBy,
    DateTime? closedAt,
    String? note,
    bool? isDemo,
  }) {
    return DailyClosing(
      id: id ?? this.id,
      branchId: branchId ?? this.branchId,
      date: date ?? this.date,
      totalIncomeMinor: totalIncomeMinor ?? this.totalIncomeMinor,
      totalExpenseMinor: totalExpenseMinor ?? this.totalExpenseMinor,
      openingBalanceMinor: openingBalanceMinor ?? this.openingBalanceMinor,
      closingBalanceMinor:
          closingBalanceMinor ?? this.closingBalanceMinor,
      closedBy: closedBy ?? this.closedBy,
      closedAt: closedAt ?? this.closedAt,
      note: note ?? this.note,
      isDemo: isDemo ?? this.isDemo,
    );
  }

  factory DailyClosing.fromMap(String id, Map<String, dynamic> map) {
    return DailyClosing(
      id: id,
      branchId: map['branchId'] as String? ?? '',
      date: parseDate(map['date']) ?? DateTime.now(),
      totalIncomeMinor: (map['totalIncome'] as num?)?.toInt() ?? 0,
      totalExpenseMinor: (map['totalExpense'] as num?)?.toInt() ?? 0,
      openingBalanceMinor: (map['openingBalance'] as num?)?.toInt() ?? 0,
      closingBalanceMinor: (map['closingBalance'] as num?)?.toInt() ?? 0,
      closedBy: map['closedBy'] as String?,
      closedAt: parseDate(map['closedAt']),
      note: map['note'] as String? ?? '',
      isDemo: map['isDemo'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'branchId': branchId,
      'date': dateToMap(date),
      'totalIncome': totalIncomeMinor,
      'totalExpense': totalExpenseMinor,
      'openingBalance': openingBalanceMinor,
      'closingBalance': closingBalanceMinor,
      'closedBy': closedBy,
      'closedAt': dateToMap(closedAt),
      'note': note,
      'isDemo': isDemo,
    };
  }
}
