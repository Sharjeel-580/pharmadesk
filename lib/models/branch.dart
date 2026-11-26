import 'model_utils.dart';

/// One pharmacy branch (shop location).
///
/// Firestore collection: `branches` (SRS §3.1). The SRS contract
/// names `type` (own / franchise), `managerId`, `status`,
/// `franchiseFeeRate` and `royaltyRate` — all four are nullable here:
/// the demo branches are own branches with no franchise rates set,
/// and a rate of `null` means "not configured", never an invented
/// number (Week 4 Day 4, D130). Rates are basis points (1% = 100)
/// so money-adjacent values stay integers, like every other rate in
/// the codebase (`taxRateBps` on medicines).
class Branch {
  final String id;
  final String name;
  final String address;
  final String phone;
  final List<String> deliveryAreas;
  final bool active;
  final DateTime? createdAt;

  /// `'own'` or `'franchise'` (SRS §3.1). Defaults to `'own'` —
  /// V1 is the 8 own branches; franchises are Phase 2 (A1).
  final String type;

  /// Staff id of the branch manager, when assigned.
  final String? managerId;

  /// Franchise fee rate in basis points, when configured.
  final int? franchiseFeeRateBps;

  /// Royalty rate in basis points, when configured.
  final int? royaltyRateBps;

  const Branch({
    required this.id,
    required this.name,
    required this.address,
    required this.phone,
    this.deliveryAreas = const [],
    this.active = true,
    this.createdAt,
    this.type = 'own',
    this.managerId,
    this.franchiseFeeRateBps,
    this.royaltyRateBps,
  });

  /// True for a franchise branch (SRS §3.1 `type == 'franchise'`).
  bool get isFranchise => type == 'franchise';

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
      type: map['type'] as String? ?? 'own',
      managerId: map['managerId'] as String?,
      franchiseFeeRateBps: (map['franchiseFeeRateBps'] as num?)?.toInt(),
      royaltyRateBps: (map['royaltyRateBps'] as num?)?.toInt(),
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
      'type': type,
      'managerId': managerId,
      'franchiseFeeRateBps': franchiseFeeRateBps,
      'royaltyRateBps': royaltyRateBps,
    };
  }

  Branch copyWith({
    String? name,
    String? address,
    String? phone,
    List<String>? deliveryAreas,
    bool? active,
    String? type,
    String? managerId,
    bool clearManagerId = false,
    int? franchiseFeeRateBps,
    bool clearFranchiseFeeRateBps = false,
    int? royaltyRateBps,
    bool clearRoyaltyRateBps = false,
  }) {
    return Branch(
      id: id,
      name: name ?? this.name,
      address: address ?? this.address,
      phone: phone ?? this.phone,
      deliveryAreas: deliveryAreas ?? this.deliveryAreas,
      active: active ?? this.active,
      createdAt: createdAt,
      type: type ?? this.type,
      managerId: clearManagerId ? null : (managerId ?? this.managerId),
      franchiseFeeRateBps: clearFranchiseFeeRateBps
          ? null
          : (franchiseFeeRateBps ?? this.franchiseFeeRateBps),
      royaltyRateBps: clearRoyaltyRateBps
          ? null
          : (royaltyRateBps ?? this.royaltyRateBps),
    );
  }
}
