/// A medicine supplier (distributor / wholesaler).
///
/// Firestore collection: `suppliers` (+ `ledger` subcollection).
///
/// Day 7: the payable balance is NOT a stored field — it is always
/// computed from the append-only supplier ledger (see
/// `supplier_ledger.dart`, same pattern as the customer khata, D37).
/// The old `balanceMinor` field is gone; seed opening balances live as
/// ledger entries in `generateDemoSupplierLedgerEntries()`.
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
    };
  }
}
