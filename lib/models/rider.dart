import 'model_utils.dart';

/// A delivery rider. Riders are staff for delivery purposes but are kept
/// in their own collection because their fields (vehicle, live order)
/// differ from counter/pharmacy staff.
///
/// Week 4 Day 2 (D119): the rider stays a separate model (the SRS and
/// the seed already have one — `lib/models/rider.dart`, Firestore
/// `branches/{branchId}/riders`), NOT a Staff row with a rider role:
/// the Staff model has no vehicle / live-order fields, and the order
/// flow already reads riders from this collection. `branchId` is the
/// rider's home branch (Week 4 Day 2 extra — the SRS §3 rider
/// contract names no branch field, but riders live in a
/// branch-scoped collection, so the doc's branch is recorded on the
/// model too, like the employees extras in D99).
///
/// Firestore collection: `riders`.
class Rider {
  final String id;
  final String name;
  final String phone;
  final String? vehicle;
  final bool active;
  final String? currentOrderId;
  final String? branchId;
  final DateTime? createdAt;

  const Rider({
    required this.id,
    required this.name,
    required this.phone,
    this.vehicle,
    this.active = true,
    this.currentOrderId,
    this.branchId,
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
      branchId: map['branchId'] as String?,
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
      'branchId': branchId,
      'createdAt': dateToMap(createdAt),
    };
  }

  Rider copyWith({
    String? id,
    String? name,
    String? phone,
    String? vehicle,
    bool? active,
    String? currentOrderId,
    bool clearCurrentOrderId = false,
    String? branchId,
    DateTime? createdAt,
  }) {
    return Rider(
      id: id ?? this.id,
      name: name ?? this.name,
      phone: phone ?? this.phone,
      vehicle: vehicle ?? this.vehicle,
      active: active ?? this.active,
      currentOrderId: clearCurrentOrderId
          ? null
          : (currentOrderId ?? this.currentOrderId),
      branchId: branchId ?? this.branchId,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}
