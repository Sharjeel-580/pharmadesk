import 'model_utils.dart';

/// One line of a goods receipt: what arrived, as which batch.
///
/// A receipt line mirrors the [ReceivingLine] the Day 7 receiving
/// dialog collects (per-line quantity, batch number, mfg/expiry) —
/// but this is the stored record of a completed receiving event,
/// not the form input. All money is int paisa (D6).
class GoodsReceiptItem {
  const GoodsReceiptItem({
    required this.medicineId,
    required this.medicineName,
    required this.quantityReceived,
    required this.batchNo,
    required this.mfgDate,
    required this.expiryDate,
    required this.unitCostMinor,
  });

  final String medicineId;
  final String medicineName;

  /// Units that arrived on this line, in this delivery.
  final int quantityReceived;

  /// The batch the goods arrived as (created in inventory by the
  /// receiving write).
  final String batchNo;
  final DateTime mfgDate;
  final DateTime expiryDate;

  /// Agreed cost price per unit, int minor units (paisa).
  final int unitCostMinor;

  /// Received value for this line: qty × unit cost.
  int get lineTotalMinor => quantityReceived * unitCostMinor;

  GoodsReceiptItem copyWith({
    String? medicineId,
    String? medicineName,
    int? quantityReceived,
    String? batchNo,
    DateTime? mfgDate,
    DateTime? expiryDate,
    int? unitCostMinor,
  }) {
    return GoodsReceiptItem(
      medicineId: medicineId ?? this.medicineId,
      medicineName: medicineName ?? this.medicineName,
      quantityReceived: quantityReceived ?? this.quantityReceived,
      batchNo: batchNo ?? this.batchNo,
      mfgDate: mfgDate ?? this.mfgDate,
      expiryDate: expiryDate ?? this.expiryDate,
      unitCostMinor: unitCostMinor ?? this.unitCostMinor,
    );
  }

  factory GoodsReceiptItem.fromMap(Map<String, dynamic> map) {
    return GoodsReceiptItem(
      medicineId: map['medicineId'] as String? ?? '',
      medicineName: map['medicineName'] as String? ?? '',
      quantityReceived: (map['quantityReceived'] as num?)?.toInt() ?? 0,
      batchNo: map['batchNo'] as String? ?? '',
      mfgDate: parseDate(map['mfgDate']) ?? DateTime.fromMillisecondsSinceEpoch(0),
      expiryDate:
          parseDate(map['expiryDate']) ?? DateTime.fromMillisecondsSinceEpoch(0),
      unitCostMinor: (map['unitCostMinor'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'medicineId': medicineId,
      'medicineName': medicineName,
      'quantityReceived': quantityReceived,
      'batchNo': batchNo,
      'mfgDate': dateToMap(mfgDate),
      'expiryDate': dateToMap(expiryDate),
      'unitCostMinor': unitCostMinor,
    };
  }
}

/// A goods receipt (SRS §3 `branches/{branchId}/goodsReceipts`).
///
/// One document per receiving event: when goods arrive against a
/// purchase order, the production data layer writes exactly one
/// receipt (id = the receiving idempotency key, D103) alongside the
/// inventory batches, the supplier-ledger charge and the PO update.
/// The PO itself carries the partial / complete status; the receipt
/// is the audit record of *this* delivery — which lines arrived, as
/// which batches, at what value, received by whom and when.
///
/// `status` is `'received'` for every receipt written today (a
/// receipt only ever documents goods that arrived). It stays a
/// string so a future returns-against-receipt flow can add values
/// without a model migration.
class GoodsReceipt {
  const GoodsReceipt({
    required this.id,
    this.receiptNumber = '',
    required this.poId,
    required this.supplierId,
    required this.branchId,
    this.receivedBy,
    this.receivedAt,
    this.status = 'received',
    this.items = const [],
    this.createdAt,
    this.updatedAt,
  });

  final String id;

  /// Sequential per-branch number (`GR-DHA-1001`, …), assigned by
  /// the repository — same pattern as PO numbers (D73).
  final String receiptNumber;

  /// The purchase order the goods arrived against.
  final String poId;
  final String supplierId;
  final String branchId;

  /// Who received the goods (display name / actor id).
  final String? receivedBy;

  /// When the goods arrived.
  final DateTime? receivedAt;

  final String status;

  /// The lines that arrived in this delivery (one per PO line with
  /// units received now).
  final List<GoodsReceiptItem> items;

  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// Total received value for this delivery (int paisa) — what the
  /// supplier ledger is charged for this receipt.
  int get totalValueMinor =>
      items.fold(0, (sum, item) => sum + item.lineTotalMinor);

  GoodsReceipt copyWith({
    String? id,
    String? receiptNumber,
    String? poId,
    String? supplierId,
    String? branchId,
    String? receivedBy,
    DateTime? receivedAt,
    String? status,
    List<GoodsReceiptItem>? items,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return GoodsReceipt(
      id: id ?? this.id,
      receiptNumber: receiptNumber ?? this.receiptNumber,
      poId: poId ?? this.poId,
      supplierId: supplierId ?? this.supplierId,
      branchId: branchId ?? this.branchId,
      receivedBy: receivedBy ?? this.receivedBy,
      receivedAt: receivedAt ?? this.receivedAt,
      status: status ?? this.status,
      items: items ?? this.items,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  factory GoodsReceipt.fromMap(String id, Map<String, dynamic> map) {
    final rawItems = map['items'];
    final items = <GoodsReceiptItem>[];
    if (rawItems is List) {
      for (final raw in rawItems) {
        if (raw is Map<String, dynamic>) {
          items.add(GoodsReceiptItem.fromMap(raw));
        } else if (raw is Map) {
          items.add(
            GoodsReceiptItem.fromMap(Map<String, dynamic>.from(raw)),
          );
        }
      }
    }
    return GoodsReceipt(
      id: id,
      receiptNumber: map['receiptNumber'] as String? ?? '',
      poId: map['poId'] as String? ?? '',
      supplierId: map['supplierId'] as String? ?? '',
      branchId: map['branchId'] as String? ?? '',
      receivedBy: map['receivedBy'] as String?,
      receivedAt: parseDate(map['receivedAt']),
      status: map['status'] as String? ?? 'received',
      items: items,
      createdAt: parseDate(map['createdAt']),
      updatedAt: parseDate(map['updatedAt']),
    );
  }

  /// Local map shape. Items are embedded here for the mock store;
  /// the Firestore mapper stores them in the `items` subcollection
  /// instead (SRS §3) and drops the embedded list on write.
  Map<String, dynamic> toMap() {
    return {
      'receiptNumber': receiptNumber,
      'poId': poId,
      'supplierId': supplierId,
      'branchId': branchId,
      'receivedBy': receivedBy,
      'receivedAt': dateToMap(receivedAt),
      'status': status,
      'totalValueMinor': totalValueMinor,
      'items': [for (final item in items) item.toMap()],
      'createdAt': dateToMap(createdAt),
      'updatedAt': dateToMap(updatedAt),
    };
  }
}
