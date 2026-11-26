/// Per-branch rack / shelf override for one medicine (Week 5 Day 3,
/// D152 — SRS §3.3 `branches/{branchId}/inventory` doc, FR-INV-10).
///
/// The master [Medicine.location] is the default shelf for the
/// medicine everywhere. A branch that keeps the medicine somewhere
/// else records that here — one record per (branch, medicine), keyed
/// in Firestore by the medicine id under
/// `branches/{branchId}/inventory/{medicineId}`.
///
/// An override with both [rack] and [shelf] empty means "no override":
/// stock views fall back to the master location. The record is never
/// stored with both fields empty — [InventoryRepository.saveBranchLocation]
/// deletes (mock) or nulls (Firestore, merge-set) it instead, so a
/// cleared override cannot shadow the default.
class BranchInventoryLocation {
  const BranchInventoryLocation({
    required this.branchId,
    required this.medicineId,
    this.rack,
    this.shelf,
  });

  final String branchId;
  final String medicineId;

  /// Rack identifier, e.g. "Rack B". Null / blank = not set.
  final String? rack;

  /// Shelf identifier, e.g. "Shelf 1". Null / blank = not set.
  final String? shelf;

  /// True when neither rack nor shelf carries a value — no override.
  bool get isEmpty =>
      (rack == null || rack!.trim().isEmpty) &&
      (shelf == null || shelf!.trim().isEmpty);

  /// "Rack B • Shelf 1", or whichever half is set, or null when the
  /// override is empty. The same " • " separator the master location
  /// uses (D138), so the two read identically on screen.
  String? get displayLabel {
    final parts = [
      if (rack != null && rack!.trim().isNotEmpty) rack!.trim(),
      if (shelf != null && shelf!.trim().isNotEmpty) shelf!.trim(),
    ];
    if (parts.isEmpty) return null;
    return parts.join(' • ');
  }

  BranchInventoryLocation copyWith({
    String? branchId,
    String? medicineId,
    String? rack,
    String? shelf,
    bool clearRack = false,
    bool clearShelf = false,
  }) {
    return BranchInventoryLocation(
      branchId: branchId ?? this.branchId,
      medicineId: medicineId ?? this.medicineId,
      rack: clearRack ? null : (rack ?? this.rack),
      shelf: clearShelf ? null : (shelf ?? this.shelf),
    );
  }

  factory BranchInventoryLocation.fromMap(
    String branchId,
    String medicineId,
    Map<String, dynamic> map,
  ) {
    return BranchInventoryLocation(
      branchId: branchId,
      medicineId: medicineId,
      rack: map['rack'] as String?,
      shelf: map['shelf'] as String?,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'branchId': branchId,
      'medicineId': medicineId,
      'rack': rack,
      'shelf': shelf,
    };
  }

  @override
  bool operator ==(Object other) =>
      other is BranchInventoryLocation &&
      other.branchId == branchId &&
      other.medicineId == medicineId &&
      other.rack == rack &&
      other.shelf == shelf;

  @override
  int get hashCode => Object.hash(branchId, medicineId, rack, shelf);
}
