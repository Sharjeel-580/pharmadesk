import 'model_utils.dart';

/// Short uppercase branch code (SRS §3 `branches.code`, required),
/// used for sequential numbers (`INV-DHA-1001`, `PO-GLB-1002`, …).
///
/// A code is valid when it is 2–8 uppercase letters/digits. The
/// stored value may be missing (seeded / legacy data written before
/// the field existed) or invalid — [normalizeBranchCode] then falls
/// back to [defaultBranchCodeForId], so a branch never carries an
/// empty or unusable code. See D163.
String defaultBranchCodeForId(String branchId) {
  final lower = branchId.toLowerCase();
  if (lower.contains('dha')) return 'DHA';
  if (lower.contains('gulberg') || lower.contains('glb')) return 'GLB';
  final segments = branchId
      .split('-')
      .where((segment) => segment.isNotEmpty)
      .toList();
  final last = segments.isEmpty ? branchId : segments.last;
  final cleaned = last.replaceAll(RegExp(r'[^a-z0-9]'), '').toUpperCase();
  if (cleaned.length >= 2) {
    return cleaned.length > 3 ? cleaned.substring(0, 3) : cleaned;
  }
  // A one-letter last segment (e.g. `branch-x`) cannot stand alone:
  // use the segments' initials (`branch-x` → `BX`).
  final initials = segments
      .map((segment) => segment[0].toUpperCase())
      .join();
  if (initials.length >= 2) {
    return initials.length > 3 ? initials.substring(0, 3) : initials;
  }
  return '${cleaned}XX'.substring(0, 2);
}

/// True when [code] is already a valid branch code: 2–8 uppercase
/// letters/digits, with no normalization applied. The form validator
/// (D168) checks the trimmed + uppercased input against this — it
/// must be able to tell a valid code from one [normalizeBranchCode]
/// would silently replace with the derived default.
bool isValidBranchCode(String code) =>
    RegExp(r'^[A-Z0-9]{2,8}$').hasMatch(code);

/// Normalizes a stored [code]: trimmed + uppercased when it is a
/// valid 2–8 character code, otherwise the migration-safe default
/// for [branchId] (D163). Never returns an empty or invalid code and
/// never throws — a bad doc degrades to the derived default.
String normalizeBranchCode(String? code, {required String branchId}) {
  final cleaned = (code ?? '').trim().toUpperCase();
  if (isValidBranchCode(cleaned)) return cleaned;
  return defaultBranchCodeForId(branchId);
}

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

  /// Short uppercase branch code (SRS §3.1 `code`, required).
  /// `''` means "not set" — use [effectiveCode] wherever a code is
  /// actually needed (sequential numbers, the Firestore mapper):
  /// it returns this code when valid, otherwise the migration-safe
  /// default derived from [id] (D163). Direct constructors
  /// (demo branches, the add-branch form) may leave it unset; the
  /// parsers ([fromMap] and the Firestore mapper) always normalize
  /// it, so a stored branch never keeps an empty code.
  final String code;

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
    this.code = '',
    this.type = 'own',
    this.managerId,
    this.franchiseFeeRateBps,
    this.royaltyRateBps,
  });

  /// The code to use: [code] when it is valid, otherwise the
  /// migration-safe default derived from [id]. Never empty.
  String get effectiveCode => normalizeBranchCode(code, branchId: id);

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
      code: normalizeBranchCode(map['code'] as String?, branchId: id),
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
      'code': effectiveCode,
      'type': type,
      'managerId': managerId,
      'franchiseFeeRateBps': franchiseFeeRateBps,
      'royaltyRateBps': royaltyRateBps,
    };
  }

  Branch copyWith({
    String? id,
    String? name,
    String? address,
    String? phone,
    List<String>? deliveryAreas,
    bool? active,
    String? code,
    String? type,
    String? managerId,
    bool clearManagerId = false,
    int? franchiseFeeRateBps,
    bool clearFranchiseFeeRateBps = false,
    int? royaltyRateBps,
    bool clearRoyaltyRateBps = false,
  }) {
    return Branch(
      id: id ?? this.id,
      name: name ?? this.name,
      address: address ?? this.address,
      phone: phone ?? this.phone,
      deliveryAreas: deliveryAreas ?? this.deliveryAreas,
      active: active ?? this.active,
      createdAt: createdAt,
      code: code ?? this.code,
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
