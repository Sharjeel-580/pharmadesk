import 'model_utils.dart';

/// One saved delivery address for a customer.
class CustomerAddress {
  final String label; // e.g. "Home", "Office"
  final String address;
  final String city;
  final bool isDefault;

  const CustomerAddress({
    required this.label,
    required this.address,
    required this.city,
    this.isDefault = false,
  });

  factory CustomerAddress.fromMap(Map<String, dynamic> map) {
    return CustomerAddress(
      label: map['label'] as String? ?? '',
      address: map['address'] as String? ?? '',
      city: map['city'] as String? ?? '',
      isDefault: map['isDefault'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'label': label,
      'address': address,
      'city': city,
      'isDefault': isDefault,
    };
  }
}

/// A pharmacy customer. Login is by phone OTP.
///
/// Firestore collection: `customers`.
class Customer {
  final String id;
  final String name;
  final String phone;
  final List<CustomerAddress> addresses;

  /// Credit limit in int minor units (paisa) — the most the customer
  /// may owe on khata at once (SRS FR-POS-09). `0` means no limit is
  /// set for this customer (unlimited credit in the demo). A credit
  /// sale that would take the outstanding past a set limit is blocked
  /// (see `validateSale` in `billing_logic.dart`).
  final int creditLimitMinor;
  final DateTime? createdAt;

  const Customer({
    required this.id,
    required this.name,
    required this.phone,
    this.addresses = const [],
    this.creditLimitMinor = 0,
    this.createdAt,
  });

  factory Customer.fromMap(String id, Map<String, dynamic> map) {
    final rawAddresses = map['addresses'] as List<dynamic>? ?? [];
    return Customer(
      id: id,
      name: map['name'] as String? ?? '',
      phone: map['phone'] as String? ?? '',
      addresses: rawAddresses
          .whereType<Map<String, dynamic>>()
          .map(CustomerAddress.fromMap)
          .toList(),
      creditLimitMinor: (map['creditLimitMinor'] as num?)?.toInt() ?? 0,
      createdAt: parseDate(map['createdAt']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'phone': phone,
      'addresses': addresses.map((a) => a.toMap()).toList(),
      'creditLimitMinor': creditLimitMinor,
      'createdAt': dateToMap(createdAt),
    };
  }

  Customer copyWith({
    String? id,
    String? name,
    String? phone,
    List<CustomerAddress>? addresses,
    int? creditLimitMinor,
    DateTime? createdAt,
  }) {
    return Customer(
      id: id ?? this.id,
      name: name ?? this.name,
      phone: phone ?? this.phone,
      addresses: addresses ?? this.addresses,
      creditLimitMinor: creditLimitMinor ?? this.creditLimitMinor,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}
