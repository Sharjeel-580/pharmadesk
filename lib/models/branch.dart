import 'model_utils.dart';

/// One pharmacy branch (shop location).
///
/// Firestore collection: `branches`.
/// Multi-branch support is a Phase 3 feature: until then the system runs
/// on a single branch, and every order/inventory record still carries a
/// `branchId` so the split is painless later.
class Branch {
  final String id;
  final String name;
  final String address;
  final String phone;
  final List<String> deliveryAreas;
  final bool active;
  final DateTime? createdAt;

  const Branch({
    required this.id,
    required this.name,
    required this.address,
    required this.phone,
    this.deliveryAreas = const [],
    this.active = true,
    this.createdAt,
  });

  factory Branch.fromMap(String id, Map<String, dynamic> map) {
    final rawAreas = map['deliveryAreas'] as List<dynamic>? ?? [];
    return Branch(
      id: id,
      name: map['name'] as String? ?? '',
      address: map['address'] as String? ?? '',
      phone: map['phone'] as String? ?? '',
      deliveryAreas: rawAreas.map((area) => area.toString()).toList(),
      active: map['active'] as bool? ?? true,
      createdAt: parseDate(map['createdAt']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'address': address,
      'phone': phone,
      'deliveryAreas': deliveryAreas,
      'active': active,
      'createdAt': dateToMap(createdAt),
    };
  }
}
