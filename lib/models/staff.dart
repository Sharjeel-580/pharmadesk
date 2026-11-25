import 'model_utils.dart';

/// Staff roles. Each role sees only what it needs:
/// owner = everything, pharmacist = prescriptions + dispensing,
/// counter = orders + billing, rider = assigned deliveries.
enum StaffRole { owner, pharmacist, counter, rider }

StaffRole staffRoleFromString(String? value) {
  switch (value) {
    case 'pharmacist':
      return StaffRole.pharmacist;
    case 'counter':
      return StaffRole.counter;
    case 'rider':
      return StaffRole.rider;
    case 'owner':
    default:
      return StaffRole.owner;
  }
}

/// A staff member (owner / pharmacist / counter staff). Login is by
/// email + password; riders are tracked separately in `riders`.
///
/// Firestore collection: `staff`.
class Staff {
  final String id;
  final String name;
  final String email;
  final StaffRole role;
  final String branchId;
  final bool active;
  final DateTime? createdAt;

  const Staff({
    required this.id,
    required this.name,
    required this.email,
    required this.role,
    required this.branchId,
    this.active = true,
    this.createdAt,
  });

  factory Staff.fromMap(String id, Map<String, dynamic> map) {
    return Staff(
      id: id,
      name: map['name'] as String? ?? '',
      email: map['email'] as String? ?? '',
      role: staffRoleFromString(map['role'] as String?),
      branchId: map['branchId'] as String? ?? '',
      active: map['active'] as bool? ?? true,
      createdAt: parseDate(map['createdAt']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'email': email,
      'role': role.name,
      'branchId': branchId,
      'active': active,
      'createdAt': dateToMap(createdAt),
    };
  }
}
