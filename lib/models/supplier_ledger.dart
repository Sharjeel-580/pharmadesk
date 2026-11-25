import 'model_utils.dart';

/// One entry in a supplier's payables ledger — SRS FR-PUR-04 / FR-FIN-03.
///
/// Mirrors the customer khata pattern (D37): the ledger is
/// **append-only**, amounts are **signed, in int minor units (paisa)**
/// (positive = the pharmacy owes the supplier more, negative = paid),
/// and the outstanding balance is always the SUM of the entries — never
/// a stored field that can drift. [balanceAfterMinor] is a snapshot
/// stored on each entry so the statement reads like a bank statement.
enum SupplierLedgerEntryKind {
  /// Stock received against a purchase order (or the demo opening
  /// balance) — the pharmacy owes the supplier more.
  purchase,

  /// Payment made to the supplier — reduces what is owed.
  payment,

  /// Goods returned to the supplier — reduces what is owed.
  purchaseReturn,

  /// Manual correction (increase or decrease) with a required reason.
  adjustment,
}

String supplierLedgerEntryKindLabel(SupplierLedgerEntryKind kind) =>
    switch (kind) {
      SupplierLedgerEntryKind.purchase => 'Purchase',
      SupplierLedgerEntryKind.payment => 'Payment made',
      SupplierLedgerEntryKind.purchaseReturn => 'Purchase return',
      SupplierLedgerEntryKind.adjustment => 'Adjustment',
    };

SupplierLedgerEntryKind supplierLedgerEntryKindFromString(String? value) {
  switch (value) {
    case 'payment':
      return SupplierLedgerEntryKind.payment;
    case 'purchaseReturn':
      return SupplierLedgerEntryKind.purchaseReturn;
    case 'adjustment':
      return SupplierLedgerEntryKind.adjustment;
    case 'purchase':
    default:
      return SupplierLedgerEntryKind.purchase;
  }
}

class SupplierLedgerEntry {
  final String id;
  final String supplierId;
  final SupplierLedgerEntryKind kind;

  /// Signed amount in int minor units (paisa): positive = pharmacy
  /// owes more, negative = paid / balance reduced.
  final int amountMinor;

  /// Human reason shown on the statement (required for manual
  /// payment/adjustment entries).
  final String reason;

  /// The purchase order id for [SupplierLedgerEntryKind.purchase],
  /// else null.
  final String? referenceId;

  /// Outstanding balance (int paisa) immediately after this entry.
  final int balanceAfterMinor;
  final DateTime? createdAt;

  const SupplierLedgerEntry({
    required this.id,
    required this.supplierId,
    required this.kind,
    required this.amountMinor,
    required this.reason,
    this.referenceId,
    required this.balanceAfterMinor,
    this.createdAt,
  });

  factory SupplierLedgerEntry.fromMap(String id, Map<String, dynamic> map) {
    return SupplierLedgerEntry(
      id: id,
      supplierId: map['supplierId'] as String? ?? '',
      kind: supplierLedgerEntryKindFromString(map['kind'] as String?),
      amountMinor: (map['amountMinor'] as num?)?.toInt() ?? 0,
      reason: map['reason'] as String? ?? '',
      referenceId: map['referenceId'] as String?,
      balanceAfterMinor: (map['balanceAfterMinor'] as num?)?.toInt() ?? 0,
      createdAt: parseDate(map['createdAt']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'supplierId': supplierId,
      'kind': kind.name,
      'amountMinor': amountMinor,
      'reason': reason,
      'referenceId': referenceId,
      'balanceAfterMinor': balanceAfterMinor,
      'createdAt': dateToMap(createdAt),
    };
  }

  SupplierLedgerEntry copyWith({
    String? id,
    String? supplierId,
    SupplierLedgerEntryKind? kind,
    int? amountMinor,
    String? reason,
    String? referenceId,
    bool clearReferenceId = false,
    int? balanceAfterMinor,
    DateTime? createdAt,
  }) {
    return SupplierLedgerEntry(
      id: id ?? this.id,
      supplierId: supplierId ?? this.supplierId,
      kind: kind ?? this.kind,
      amountMinor: amountMinor ?? this.amountMinor,
      reason: reason ?? this.reason,
      referenceId: clearReferenceId
          ? null
          : (referenceId ?? this.referenceId),
      balanceAfterMinor: balanceAfterMinor ?? this.balanceAfterMinor,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}
