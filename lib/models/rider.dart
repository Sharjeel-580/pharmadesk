import 'model_utils.dart';

/// A delivery rider. Riders are staff for delivery purposes but are kept
/// in their own collection because their fields (vehicle, live order)
/// differ from counter/pharmacy staff.
///
/// Firestore collection: `riders`.
class Rider {
  final String id;
  final String name;
  final String phone;
  final String? vehicle;
  final bool active;
  final String? currentOrderId;
  final DateTime? createdAt;

  const Rider({
    required this.id,
    required this.name,
    required this.phone,
    this.vehicle,
    this.active = true,
    this.currentOrderId,
    this.createdAt,
  });

  factory Rider.fromMap(String id, Map<String, dynamic> map) {
    return Rider(
      id: id,
      name: map['name'] as String? ?? '',
      phone: map['phone'] as String? ?? '',
      vehicle: map['vehicle'] as String?,
      active: map['active'] as bool? ?? true,
      currentOrderId: map['currentOrderId'] as String?,
      createdAt: parseDate(map['createdAt']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'phone': phone,
      'vehicle': vehicle,
      'active': active,
      'currentOrderId': currentOrderId,
      'createdAt': dateToMap(createdAt),
    };
  }
}
