import 'model_utils.dart';

/// Lifecycle status of one stock batch (SRS §3 `batches.status`,
/// Week 2 Day 3 — D68).
///
/// Only [available] batches may be sold: the Day 5 sellable guard
/// ([isBatchSellable] in `inventory_logic.dart`) requires this status
/// in addition to a future expiry date and stock on hand. A batch
/// marked [quarantined] (damaged / suspect / held for inspection),
/// [expired] or [returned] (sent back to the supplier) is excluded
/// from usable stock everywhere — POS, orders and the Day 2 auto
/// purchase list all read the same guard, so the rule cannot drift.
///
/// Legacy rows without a status (demo seed, pre-Day 3 maps) parse as
/// [available].
enum BatchStatus { available, quarantined, expired, returned }

BatchStatus batchStatusFromString(String? value) {
  switch (value) {
    case 'quarantined':
      return BatchStatus.quarantined;
    case 'expired':
      return BatchStatus.expired;
    case 'returned':
      return BatchStatus.returned;
    case 'available':
    default:
      return BatchStatus.available;
  }
}

/// Stock of one medicine at one branch.
///
/// Firestore collection: `inventory`.
/// Kept separate from `medicines` (the catalogue) so each branch tracks
/// its own quantity, batch and expiry for the same medicine.
///
/// Day 5: one row is ONE BATCH — a medicine has 1–3 batch rows per
/// branch, so the batch list, FEFO ordering and expiry buckets all read
/// off these rows. [mfgDate] and [costMinor] (cost price, int paisa)
/// arrive with the batch; stock operations (receive / adjust / count)
/// rewrite rows via [copyWith].
class InventoryItem {
  final String id;
  final String medicineId;
  final String branchId;
  final int quantity;
  final int lowStockThreshold;
  final DateTime? expiryDate;
  final String? batchNo;
  final DateTime? mfgDate;
  final int costMinor;
  final DateTime? updatedAt;

  /// SRS §3 batch status (D68). Defaults to [BatchStatus.available];
  /// quarantined / expired / returned batches are never sellable.
  final BatchStatus status;

  const InventoryItem({
    required this.id,
    required this.medicineId,
    required this.branchId,
    required this.quantity,
    this.lowStockThreshold = 0,
    this.expiryDate,
    this.batchNo,
    this.mfgDate,
    this.costMinor = 0,
    this.updatedAt,
    this.status = BatchStatus.available,
  });

  InventoryItem copyWith({
    String? id,
    String? medicineId,
    String? branchId,
    int? quantity,
    int? lowStockThreshold,
    DateTime? expiryDate,
    bool clearExpiryDate = false,
    String? batchNo,
    DateTime? mfgDate,
    int? costMinor,
    DateTime? updatedAt,
    BatchStatus? status,
  }) {
    return InventoryItem(
      id: id ?? this.id,
      medicineId: medicineId ?? this.medicineId,
      branchId: branchId ?? this.branchId,
      quantity: quantity ?? this.quantity,
      lowStockThreshold: lowStockThreshold ?? this.lowStockThreshold,
      expiryDate: clearExpiryDate ? null : (expiryDate ?? this.expiryDate),
      batchNo: batchNo ?? this.batchNo,
      mfgDate: mfgDate ?? this.mfgDate,
      costMinor: costMinor ?? this.costMinor,
      updatedAt: updatedAt ?? this.updatedAt,
      status: status ?? this.status,
    );
  }

  factory InventoryItem.fromMap(String id, Map<String, dynamic> map) {
    return InventoryItem(
      id: id,
      medicineId: map['medicineId'] as String? ?? '',
      branchId: map['branchId'] as String? ?? '',
      quantity: (map['quantity'] as num?)?.toInt() ?? 0,
      lowStockThreshold: (map['lowStockThreshold'] as num?)?.toInt() ?? 0,
      expiryDate: parseDate(map['expiryDate']),
      batchNo: map['batchNo'] as String?,
      mfgDate: parseDate(map['mfgDate']),
      costMinor: (map['costMinor'] as num?)?.toInt() ?? 0,
      updatedAt: parseDate(map['updatedAt']),
      status: batchStatusFromString(
        map['status'] as String? ?? map['batchStatus'] as String?,
      ),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'medicineId': medicineId,
      'branchId': branchId,
      'quantity': quantity,
      'lowStockThreshold': lowStockThreshold,
      'expiryDate': dateToMap(expiryDate),
      'batchNo': batchNo,
      'mfgDate': dateToMap(mfgDate),
      'costMinor': costMinor,
      'updatedAt': dateToMap(updatedAt),
      'status': status.name,
    };
  }

  /// True when stock has fallen to (or below) the branch's alert level.
  bool get isLowStock => quantity <= lowStockThreshold;

  /// True when the batch is held for inspection / damaged — never
  /// sellable, never counted as usable stock (D68).
  bool get isQuarantined => status == BatchStatus.quarantined;

  /// True when the batch is expired (or expires today).
  bool get isExpired {
    final expiry = expiryDate;
    if (expiry == null) return false;
    final today = DateTime.now();
    return !expiry.isAfter(DateTime(today.year, today.month, today.day));
  }
}
