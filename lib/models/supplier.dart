import 'model_utils.dart';

/// A medicine supplier (distributor / wholesaler).
///
/// Firestore collection: `suppliers` (+ `ledger` subcollection).
///
/// Day 7: the payable balance is NOT a stored field — it is always
/// computed from the append-only supplier ledger (see
/// `supplier_ledger.dart`, same pattern as the customer khata, D37).
/// The old `balanceMinor` field is gone; seed opening balances live as
/// ledger entries in `generateDemoSupplierLedgerEntries()`.
///
/// Week 6 Day 4 (D165): [createdAt] records when the supplier was
/// added. It is nullable: suppliers seeded before the field existed
/// (and legacy Firestore docs without it) read back as `null` —
/// "unknown", never an invented date. A supplier created through a
/// repository gets `DateTime.now()` stamped at creation (mock +
/// Firestore mapper stamp); an update never rewrites it.
class Supplier {
  final String id;
  final String name;
  final String contactPerson;
  final String phone;
  final String? email;
  final String? address;
  final String? taxNumber;
  final String? paymentTerms;
  final bool isActive;

  /// When this supplier was added (`null` = unknown — seeded /
  /// legacy rows predate the field, D165).
  final DateTime? createdAt;

  const Supplier({
    required this.id,
    required this.name,
    required this.contactPerson,
    required this.phone,
    this.email,
    this.address,
    this.taxNumber,
    this.paymentTerms,
    this.isActive = true,
    this.createdAt,
  });

  Supplier copyWith({
    String? id,
    String? name,
    String? contactPerson,
    String? phone,
    String? email,
    bool clearEmail = false,
    String? address,
    bool clearAddress = false,
    String? taxNumber,
    bool clearTaxNumber = false,
    String? paymentTerms,
    bool clearPaymentTerms = false,
    bool? isActive,
    DateTime? createdAt,
  }) {
    return Supplier(
      id: id ?? this.id,
      name: name ?? this.name,
      contactPerson: contactPerson ?? this.contactPerson,
      phone: phone ?? this.phone,
      email: clearEmail ? null : (email ?? this.email),
      address: clearAddress ? null : (address ?? this.address),
      taxNumber: clearTaxNumber ? null : (taxNumber ?? this.taxNumber),
      paymentTerms: clearPaymentTerms
          ? null
          : (paymentTerms ?? this.paymentTerms),
      isActive: isActive ?? this.isActive,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  factory Supplier.fromMap(String id, Map<String, dynamic> map) {
    return Supplier(
      id: id,
      name: map['name'] as String? ?? '',
      contactPerson: map['contactPerson'] as String? ?? '',
      phone: map['phone'] as String? ?? '',
      email: map['email'] as String?,
      address: map['address'] as String?,
      taxNumber: map['taxNumber'] as String?,
      paymentTerms: map['paymentTerms'] as String?,
      isActive: map['isActive'] as bool? ?? true,
      createdAt: parseDate(map['createdAt']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'contactPerson': contactPerson,
      'phone': phone,
      'email': email,
      'address': address,
      'taxNumber': taxNumber,
      'paymentTerms': paymentTerms,
      'isActive': isActive,
      'createdAt': dateToMap(createdAt),
    };
  }
}
