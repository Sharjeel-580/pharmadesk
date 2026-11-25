import 'model_utils.dart';

/// Expense categories (SRS §3.7 `expenseCategories`, org-wide
/// lookup). The demo keeps the lookup as a fixed list; production
/// stores categories as `expenseCategories/{categoryId}` documents.
const expenseCategories = <String>[
  'Rent',
  'Utilities',
  'Salaries',
  'Transport',
  'Supplies',
  'Marketing',
  'Maintenance',
  'Other',
];

/// One operating expense (SRS §3.7
/// `branches/{branchId}/expenses`, FR-FIN-01/05).
///
/// Money is int paisa ([amountMinor], always positive — an expense
/// is money out). Recording an expense also writes a
/// `financialTransactions` entry of type `expense` with the matching
/// negative amount (see `lib/features/finance/`), so the P&L and
/// the transaction feed never diverge.
class Expense {
  final String id;
  final String branchId;
  final String category;
  final int amountMinor;
  final String description;
  final DateTime expenseDate;
  final String? createdBy;
  final String? approvedBy;
  final DateTime? createdAt;

  const Expense({
    required this.id,
    required this.branchId,
    required this.category,
    required this.amountMinor,
    this.description = '',
    required this.expenseDate,
    this.createdBy,
    this.approvedBy,
    this.createdAt,
  });

  Expense copyWith({
    String? id,
    String? branchId,
    String? category,
    int? amountMinor,
    String? description,
    DateTime? expenseDate,
    String? createdBy,
    String? approvedBy,
    bool clearApprovedBy = false,
    DateTime? createdAt,
  }) {
    return Expense(
      id: id ?? this.id,
      branchId: branchId ?? this.branchId,
      category: category ?? this.category,
      amountMinor: amountMinor ?? this.amountMinor,
      description: description ?? this.description,
      expenseDate: expenseDate ?? this.expenseDate,
      createdBy: createdBy ?? this.createdBy,
      approvedBy: clearApprovedBy ? null : (approvedBy ?? this.approvedBy),
      createdAt: createdAt ?? this.createdAt,
    );
  }

  factory Expense.fromMap(String id, Map<String, dynamic> map) {
    return Expense(
      id: id,
      branchId: map['branchId'] as String? ?? '',
      category: map['category'] as String? ?? 'Other',
      amountMinor: (map['amount'] as num?)?.toInt() ?? 0,
      description: map['description'] as String? ?? '',
      expenseDate: parseDate(map['expenseDate']) ?? DateTime.now(),
      createdBy: map['createdBy'] as String?,
      approvedBy: map['approvedBy'] as String?,
      createdAt: parseDate(map['createdAt']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'branchId': branchId,
      'category': category,
      'amount': amountMinor,
      'description': description,
      'expenseDate': dateToMap(expenseDate),
      'createdBy': createdBy,
      'approvedBy': approvedBy,
      'createdAt': dateToMap(createdAt),
    };
  }
}
