import 'model_utils.dart';

/// One entry in a customer's credit ledger (khata) — SRS FR-POS-09.
///
/// The ledger is **append-only**: entries are never edited or deleted.
/// Amounts are **signed, in int minor units (paisa)**:
///
/// - Positive = the customer owes MORE (credit given / udhaar).
/// - Negative = the customer owes LESS (payment received).
///
/// The outstanding balance is always the sum of the entries
/// ([outstandingMinor] in `customer_logic.dart`) — never a stored
/// field that can drift. [balanceAfterMinor] is a snapshot stored on
/// each entry so the statement reads like a bank statement.
enum LedgerEntryKind {
  /// A POS sale settled on credit (khata) — created automatically when
  /// a sale completes with payment method "Credit".
  creditSale,

  /// Manual credit given (udhaar) — staff records an amount the
  /// customer took on credit outside a POS sale.
  credit,

  /// Payment received against the outstanding balance.
  payment,

  /// Manual correction (increase or decrease) with a required reason.
  adjustment,
}

String ledgerEntryKindLabel(LedgerEntryKind kind) => switch (kind) {
  LedgerEntryKind.creditSale => 'Credit sale',
  LedgerEntryKind.credit => 'Credit (udhaar)',
  LedgerEntryKind.payment => 'Payment received',
  LedgerEntryKind.adjustment => 'Adjustment',
};

LedgerEntryKind ledgerEntryKindFromString(String? value) {
  switch (value) {
    case 'credit':
      return LedgerEntryKind.credit;
    case 'payment':
      return LedgerEntryKind.payment;
    case 'adjustment':
      return LedgerEntryKind.adjustment;
    case 'creditSale':
    default:
      return LedgerEntryKind.creditSale;
  }
}

class LedgerEntry {
  final String id;
  final String customerId;
  final LedgerEntryKind kind;

  /// Signed amount in int minor units (paisa): positive = customer
  /// owes more, negative = customer paid / balance reduced.
  final int amountMinor;

  /// Human reason shown on the statement (required for manual
  /// credit/adjustment entries).
  final String reason;

  /// The sale id for [LedgerEntryKind.creditSale], else null.
  final String? referenceId;

  /// Outstanding balance (int paisa) immediately after this entry.
  final int balanceAfterMinor;
  final DateTime? createdAt;

  const LedgerEntry({
    required this.id,
    required this.customerId,
    required this.kind,
    required this.amountMinor,
    required this.reason,
    this.referenceId,
    required this.balanceAfterMinor,
    this.createdAt,
  });

  factory LedgerEntry.fromMap(String id, Map<String, dynamic> map) {
    return LedgerEntry(
      id: id,
      customerId: map['customerId'] as String? ?? '',
      kind: ledgerEntryKindFromString(map['kind'] as String?),
      amountMinor: (map['amountMinor'] as num?)?.toInt() ?? 0,
      reason: map['reason'] as String? ?? '',
      referenceId: map['referenceId'] as String?,
      balanceAfterMinor: (map['balanceAfterMinor'] as num?)?.toInt() ?? 0,
      createdAt: parseDate(map['createdAt']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'customerId': customerId,
      'kind': kind.name,
      'amountMinor': amountMinor,
      'reason': reason,
      'referenceId': referenceId,
      'balanceAfterMinor': balanceAfterMinor,
      'createdAt': dateToMap(createdAt),
    };
  }

  LedgerEntry copyWith({
    String? id,
    String? customerId,
    LedgerEntryKind? kind,
    int? amountMinor,
    String? reason,
    String? referenceId,
    bool clearReferenceId = false,
    int? balanceAfterMinor,
    DateTime? createdAt,
  }) {
    return LedgerEntry(
      id: id ?? this.id,
      customerId: customerId ?? this.customerId,
      kind: kind ?? this.kind,
      amountMinor: amountMinor ?? this.amountMinor,
      reason: reason ?? this.reason,
      referenceId: clearReferenceId ? null : (referenceId ?? this.referenceId),
      balanceAfterMinor: balanceAfterMinor ?? this.balanceAfterMinor,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}
