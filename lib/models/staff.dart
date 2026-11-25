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
/// Firestore collection: `staff` (Week 2 Day 5: the SRS §3.7
/// `employees` collection is the branch-scoped employee record; this
/// Day 0 model is the directory record the staff screens use — see
/// D89. `phone` / `jobTitle` / `roleKey` were added on Day 5 so the
/// directory carries what the SRS employee record carries).
class Staff {
  final String id;
  final String name;
  final String email;
  final StaffRole role;
  final String branchId;
  final bool active;
  final DateTime? createdAt;

  /// Phone number (digits + formatting as entered; uniqueness is
  /// checked on digits only, like customers/suppliers).
  final String phone;

  /// Job title as written on the staff record, e.g. "Senior
  /// Pharmacist", "Counter Staff". Free text — the permission role
  /// is [roleKey], not this title.
  final String jobTitle;

  /// The SRS §5.1 role key for this staff member
  /// (`owner`, `branch_manager`, `pharmacist`, `cashier`,
  /// `inventory_manager`, `ho_admin`, `regional_manager`,
  /// `accountant`, `auditor`, `super_admin`) — the role the
  /// permission service enforces. Null = not assigned yet; the
  /// directory treats it as the legacy [role] mapped onto the
  /// closest SRS role (see [effectiveRoleKey]).
  final String? roleKey;

  const Staff({
    required this.id,
    required this.name,
    required this.email,
    required this.role,
    required this.branchId,
    this.active = true,
    this.createdAt,
    this.phone = '',
    this.jobTitle = '',
    this.roleKey,
  });

  /// The SRS role key that governs this staff member: the assigned
  /// [roleKey] when present, else the legacy [role] mapped onto the
  /// closest SRS role (owner → owner, pharmacist → pharmacist,
  /// counter → cashier). A rider has no SRS matrix role, so it maps
  /// to the literal key `'rider'` — the permission service returns
  /// `none` for unknown keys, which is the correct outcome (a rider
  /// holds no matrix permissions). This getter is display /
  /// directory use only: enforcement reads `AppUser.roleKey`.
  String get effectiveRoleKey =>
      roleKey ??
      switch (role) {
        StaffRole.owner => 'owner',
        StaffRole.pharmacist => 'pharmacist',
        StaffRole.counter => 'cashier',
        StaffRole.rider => 'rider',
      };

  Staff copyWith({
    String? id,
    String? name,
    String? email,
    StaffRole? role,
    String? branchId,
    bool? active,
    DateTime? createdAt,
    String? phone,
    String? jobTitle,
    String? roleKey,
    bool clearRoleKey = false,
  }) {
    return Staff(
      id: id ?? this.id,
      name: name ?? this.name,
      email: email ?? this.email,
      role: role ?? this.role,
      branchId: branchId ?? this.branchId,
      active: active ?? this.active,
      createdAt: createdAt ?? this.createdAt,
      phone: phone ?? this.phone,
      jobTitle: jobTitle ?? this.jobTitle,
      roleKey: clearRoleKey ? null : (roleKey ?? this.roleKey),
    );
  }

  factory Staff.fromMap(String id, Map<String, dynamic> map) {
    return Staff(
      id: id,
      name: map['name'] as String? ?? '',
      email: map['email'] as String? ?? '',
      role: staffRoleFromString(map['role'] as String?),
      branchId: map['branchId'] as String? ?? '',
      active: map['active'] as bool? ?? true,
      createdAt: parseDate(map['createdAt']),
      phone: map['phone'] as String? ?? '',
      jobTitle: map['jobTitle'] as String? ?? '',
      roleKey: map['roleKey'] as String?,
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
      'phone': phone,
      'jobTitle': jobTitle,
      'roleKey': roleKey,
    };
  }
}
