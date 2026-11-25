import 'model_utils.dart';

/// Payment methods for a supplier payment (SRS §3.6
/// `supplierPayments` — `method` is free text in the SRS; the demo
/// offers the four methods below and stores the chosen one).
enum SupplierPaymentMethod { cash, bankTransfer, cheque, online }

SupplierPaymentMethod supplierPaymentMethodFromString(String? value) {
  switch (value) {
    case 'bankTransfer':
    case 'bank_transfer':
      return SupplierPaymentMethod.bankTransfer;
    case 'cheque':
      return SupplierPaymentMethod.cheque;
    case 'online':
      return SupplierPaymentMethod.online;
    case 'cash':
    default:
      return SupplierPaymentMethod.cash;
  }
}

String supplierPaymentMethodLabel(SupplierPaymentMethod method) =>
    switch (method) {
      SupplierPaymentMethod.cash => 'Cash',
      SupplierPaymentMethod.bankTransfer => 'Bank transfer',
      SupplierPaymentMethod.cheque => 'Cheque',
      SupplierPaymentMethod.online => 'Online',
    };

/// One allocation of a payment against a single open payable
/// (a supplier ledger purchase entry). Allocations are computed
/// oldest-payable-first (FIFO) by `allocateSupplierPayment` and
/// stored on the payment, so the statement can show exactly which
/// purchases a payment settled.
class PaymentAllocation {
  const PaymentAllocation({
    required this.ledgerEntryId,
    required this.amountMinor,
  });

  /// Id of the supplier ledger entry (a purchase) this part of the
  /// payment settles.
  final String ledgerEntryId;

  /// Amount allocated to that entry, int paisa (positive).
  final int amountMinor;

  factory PaymentAllocation.fromMap(Map<String, dynamic> map) {
    return PaymentAllocation(
      ledgerEntryId: map['ledgerEntryId'] as String? ?? '',
      amountMinor: (map['amount'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toMap() {
    return {'ledgerEntryId': ledgerEntryId, 'amount': amountMinor};
  }
}

/// A payment made to a supplier (SRS §3.6
/// `branches/{branchId}/supplierPayments`, FR-PUR-04/05).
///
/// A payment is always allocated against open payables: the
/// [allocations] list (oldest purchase first) sums to
/// [amountMinor], and recording it also writes the matching
/// negative supplier-ledger entry and a `financialTransactions`
/// entry of type `supplierPayment` — one payment, three records,
/// all written by the same provider call. Money is int paisa.
class SupplierPayment {
  final String id;
  final String branchId;
  final String supplierId;
  final int amountMinor;
  final SupplierPaymentMethod method;
  final String reference;
  final String? paidBy;
  final DateTime paidAt;
  final List<PaymentAllocation> allocations;
  final DateTime? createdAt;

  const SupplierPayment({
    required this.id,
    required this.branchId,
    required this.supplierId,
    required this.amountMinor,
    this.method = SupplierPaymentMethod.cash,
    this.reference = '',
    this.paidBy,
    required this.paidAt,
    this.allocations = const [],
    this.createdAt,
  });

  /// Amount of this payment not allocated to any payable — zero in
  /// normal use (validation rejects a payment larger than the
  /// outstanding payable). A non-zero value means the allocations
  /// were computed against a stale outstanding figure.
  int get unallocatedMinor =>
      amountMinor -
      allocations.fold(0, (sum, a) => sum + a.amountMinor);

  SupplierPayment copyWith({
    String? id,
    String? branchId,
    String? supplierId,
    int? amountMinor,
    SupplierPaymentMethod? method,
    String? reference,
    String? paidBy,
    DateTime? paidAt,
    List<PaymentAllocation>? allocations,
    DateTime? createdAt,
  }) {
    return SupplierPayment(
      id: id ?? this.id,
      branchId: branchId ?? this.branchId,
      supplierId: supplierId ?? this.supplierId,
      amountMinor: amountMinor ?? this.amountMinor,
      method: method ?? this.method,
      reference: reference ?? this.reference,
      paidBy: paidBy ?? this.paidBy,
      paidAt: paidAt ?? this.paidAt,
      allocations: allocations ?? this.allocations,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  factory SupplierPayment.fromMap(String id, Map<String, dynamic> map) {
    return SupplierPayment(
      id: id,
      branchId: map['branchId'] as String? ?? '',
      supplierId: map['supplierId'] as String? ?? '',
      amountMinor: (map['amount'] as num?)?.toInt() ?? 0,
      method: supplierPaymentMethodFromString(map['method'] as String?),
      reference: map['reference'] as String? ?? '',
      paidBy: map['paidBy'] as String?,
      paidAt: parseDate(map['paidAt']) ?? DateTime.now(),
      allocations:
          (map['allocations'] as List?)
              ?.map(
                (e) => PaymentAllocation.fromMap(
                  Map<String, dynamic>.from(e as Map),
                ),
              )
              .toList() ??
          const [],
      createdAt: parseDate(map['createdAt']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'branchId': branchId,
      'supplierId': supplierId,
      'amount': amountMinor,
      'method': method.name,
      'reference': reference,
      'paidBy': paidBy,
      'paidAt': dateToMap(paidAt),
      'allocations': [for (final a in allocations) a.toMap()],
      'createdAt': dateToMap(createdAt),
    };
  }
}
