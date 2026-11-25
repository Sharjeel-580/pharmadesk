import 'model_utils.dart';

/// Financial transaction type (SRS §3.7
/// `branches/{branchId}/financialTransactions`).
enum FinancialTransactionType {
  income,
  expense,
  supplierPayment,
  customerPayment,
  adjustment,
}

FinancialTransactionType financialTransactionTypeFromString(String? value) {
  switch (value) {
    case 'income':
      return FinancialTransactionType.income;
    case 'supplier_payment':
      return FinancialTransactionType.supplierPayment;
    case 'customer_payment':
      return FinancialTransactionType.customerPayment;
    case 'adjustment':
      return FinancialTransactionType.adjustment;
    case 'expense':
    default:
      return FinancialTransactionType.expense;
  }
}

String financialTransactionTypeLabel(FinancialTransactionType type) =>
    switch (type) {
      FinancialTransactionType.income => 'Income',
      FinancialTransactionType.expense => 'Expense',
      FinancialTransactionType.supplierPayment => 'Supplier payment',
      FinancialTransactionType.customerPayment => 'Customer payment',
      FinancialTransactionType.adjustment => 'Adjustment',
    };

/// One append-only financial transaction (SRS §3.7, FR-FIN-01).
///
/// [amountMinor] is SIGNED int paisa: positive = money in
/// (income, customer payment received), negative = money out
/// (expense, supplier payment). The collection is append-only —
/// transactions are never edited or deleted (same rule as the
/// stock, khata and supplier ledgers). It feeds the P&L's
/// other-income line and the finance audit trail; the P&L's
/// expense line itself reads the `expenses` collection, and every
/// expense recording writes both, so the two never diverge.
class FinancialTransaction {
  final String id;
  final String branchId;
  final FinancialTransactionType type;
  final int amountMinor;
  final String category;
  final String? referenceType;
  final String? referenceId;
  final String? createdBy;
  final DateTime? createdAt;

  const FinancialTransaction({
    required this.id,
    required this.branchId,
    required this.type,
    required this.amountMinor,
    this.category = '',
    this.referenceType,
    this.referenceId,
    this.createdBy,
    this.createdAt,
  });

  FinancialTransaction copyWith({
    String? id,
    String? branchId,
    FinancialTransactionType? type,
    int? amountMinor,
    String? category,
    String? referenceType,
    bool clearReferenceType = false,
    String? referenceId,
    bool clearReferenceId = false,
    String? createdBy,
    DateTime? createdAt,
  }) {
    return FinancialTransaction(
      id: id ?? this.id,
      branchId: branchId ?? this.branchId,
      type: type ?? this.type,
      amountMinor: amountMinor ?? this.amountMinor,
      category: category ?? this.category,
      referenceType: clearReferenceType
          ? null
          : (referenceType ?? this.referenceType),
      referenceId: clearReferenceId
          ? null
          : (referenceId ?? this.referenceId),
      createdBy: createdBy ?? this.createdBy,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  factory FinancialTransaction.fromMap(
    String id,
    Map<String, dynamic> map,
  ) {
    return FinancialTransaction(
      id: id,
      branchId: map['branchId'] as String? ?? '',
      type: financialTransactionTypeFromString(map['type'] as String?),
      amountMinor: (map['amount'] as num?)?.toInt() ?? 0,
      category: map['category'] as String? ?? '',
      referenceType: map['referenceType'] as String?,
      referenceId: map['referenceId'] as String?,
      createdBy: map['createdBy'] as String?,
      createdAt: parseDate(map['createdAt']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'branchId': branchId,
      'type': type.name,
      'amount': amountMinor,
      'category': category,
      'referenceType': referenceType,
      'referenceId': referenceId,
      'createdBy': createdBy,
      'createdAt': dateToMap(createdAt),
    };
  }
}
