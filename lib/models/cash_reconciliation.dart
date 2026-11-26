import 'model_utils.dart';

/// One cash reconciliation — the expected-vs-actual drawer count
/// (Week 5 Day 4, D157 — SRS D-24 / FR-FIN-02).
///
/// The closing snapshots the day's cashbook totals (D126); the
/// reconciliation checks the physical drawer against them: the
/// EXPECTED drawer amount is computed from the day's figures
/// (opening balance + cash taken in − cash paid out — see
/// `expectedDrawerMinor` in `finance_logic.dart`), the ACTUAL
/// amount is the counted cash in the drawer, and the DIFFERENCE
/// (actual − expected) is recorded, never silently absorbed. A
/// positive difference is cash over; a negative one is cash short.
///
/// One record per (branch, day) count — a recount is a new record,
/// never an edit of the previous count, so the history of counts
/// for a day is preserved.
class CashReconciliation {
  final String id;
  final String branchId;

  /// The day being reconciled (date-only).
  final DateTime date;

  /// Expected drawer amount at count time (int paisa, computed —
  /// see `expectedDrawerMinor`).
  final int expectedMinor;

  /// Counted cash in the drawer (int paisa).
  final int countedMinor;

  /// `counted − expected` (int paisa): positive = over, negative =
  /// short, 0 = exact.
  final int differenceMinor;

  /// Optional note (e.g. what the shortfall was traced to).
  final String note;

  final String? countedBy;
  final DateTime? countedAt;
  final bool isDemo;

  const CashReconciliation({
    required this.id,
    required this.branchId,
    required this.date,
    required this.expectedMinor,
    required this.countedMinor,
    required this.differenceMinor,
    this.note = '',
    this.countedBy,
    this.countedAt,
    this.isDemo = false,
  });

  CashReconciliation copyWith({
    String? id,
    String? branchId,
    DateTime? date,
    int? expectedMinor,
    int? countedMinor,
    int? differenceMinor,
    String? note,
    String? countedBy,
    DateTime? countedAt,
    bool? isDemo,
  }) {
    return CashReconciliation(
      id: id ?? this.id,
      branchId: branchId ?? this.branchId,
      date: date ?? this.date,
      expectedMinor: expectedMinor ?? this.expectedMinor,
      countedMinor: countedMinor ?? this.countedMinor,
      differenceMinor: differenceMinor ?? this.differenceMinor,
      note: note ?? this.note,
      countedBy: countedBy ?? this.countedBy,
      countedAt: countedAt ?? this.countedAt,
      isDemo: isDemo ?? this.isDemo,
    );
  }

  factory CashReconciliation.fromMap(String id, Map<String, dynamic> map) {
    return CashReconciliation(
      id: id,
      branchId: map['branchId'] as String? ?? '',
      date: parseDate(map['date']) ?? DateTime.now(),
      expectedMinor: (map['expected'] as num?)?.toInt() ?? 0,
      countedMinor: (map['counted'] as num?)?.toInt() ?? 0,
      differenceMinor: (map['difference'] as num?)?.toInt() ?? 0,
      note: map['note'] as String? ?? '',
      countedBy: map['countedBy'] as String?,
      countedAt: parseDate(map['countedAt']),
      isDemo: map['isDemo'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'branchId': branchId,
      'date': dateToMap(date),
      'expected': expectedMinor,
      'counted': countedMinor,
      'difference': differenceMinor,
      'note': note,
      'countedBy': countedBy,
      'countedAt': dateToMap(countedAt),
      'isDemo': isDemo,
    };
  }

  /// True when the count matched the expected drawer exactly.
  bool get isExact => differenceMinor == 0;

  /// True when the drawer held more cash than expected.
  bool get isOver => differenceMinor > 0;

  /// True when the drawer held less cash than expected.
  bool get isShort => differenceMinor < 0;
}
