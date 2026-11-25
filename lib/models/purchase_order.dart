import 'model_utils.dart';

/// Purchase order lifecycle (SRS FR-PUR-01/02, §3.6).
///
/// Draft → Approved → Received (via Partially received for partial
/// deliveries) or Cancelled. A received PO's goods land in inventory
/// batch-wise through the goods-receiving flow; stock increases only
/// after receiving is confirmed (FR-PUR-03).
enum PurchaseOrderStatus {
  draft,
  approved,
  partiallyReceived,
  received,
  cancelled,
}

String purchaseOrderStatusLabel(PurchaseOrderStatus status) => switch (status) {
  PurchaseOrderStatus.draft => 'Draft',
  PurchaseOrderStatus.approved => 'Approved',
  PurchaseOrderStatus.partiallyReceived => 'Partially received',
  PurchaseOrderStatus.received => 'Received',
  PurchaseOrderStatus.cancelled => 'Cancelled',
};

PurchaseOrderStatus purchaseOrderStatusFromString(String? value) {
  switch (value) {
    case 'approved':
      return PurchaseOrderStatus.approved;
    case 'partiallyReceived':
      return PurchaseOrderStatus.partiallyReceived;
    case 'received':
      return PurchaseOrderStatus.received;
    case 'cancelled':
      return PurchaseOrderStatus.cancelled;
    case 'draft':
    default:
      return PurchaseOrderStatus.draft;
  }
}

/// One line of a purchase order: a medicine, how many were ordered,
/// how many have arrived so far, and the agreed cost price per unit
/// (int paisa — D6, never doubles for money).
class PurchaseOrderItem {
  final String medicineId;
  final String medicineName;
  final int quantityOrdered;
  final int quantityReceived;

  /// Agreed cost price per unit, int minor units (paisa).
  final int unitCostMinor;

  const PurchaseOrderItem({
    required this.medicineId,
    required this.medicineName,
    required this.quantityOrdered,
    this.quantityReceived = 0,
    required this.unitCostMinor,
  });

  /// Ordered value: qty ordered × unit cost.
  int get lineTotalMinor => quantityOrdered * unitCostMinor;

  /// Received value so far: qty received × unit cost.
  int get receivedTotalMinor => quantityReceived * unitCostMinor;

  /// Units still outstanding on this line.
  int get quantityRemaining => quantityOrdered - quantityReceived;

  bool get isFullyReceived => quantityReceived >= quantityOrdered;

  PurchaseOrderItem copyWith({
    String? medicineId,
    String? medicineName,
    int? quantityOrdered,
    int? quantityReceived,
    int? unitCostMinor,
  }) {
    return PurchaseOrderItem(
      medicineId: medicineId ?? this.medicineId,
      medicineName: medicineName ?? this.medicineName,
      quantityOrdered: quantityOrdered ?? this.quantityOrdered,
      quantityReceived: quantityReceived ?? this.quantityReceived,
      unitCostMinor: unitCostMinor ?? this.unitCostMinor,
    );
  }

  factory PurchaseOrderItem.fromMap(Map<String, dynamic> map) {
    return PurchaseOrderItem(
      medicineId: map['medicineId'] as String? ?? '',
      medicineName: map['medicineName'] as String? ?? '',
      quantityOrdered: (map['quantityOrdered'] as num?)?.toInt() ?? 0,
      quantityReceived: (map['quantityReceived'] as num?)?.toInt() ?? 0,
      unitCostMinor: (map['unitCostMinor'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'medicineId': medicineId,
      'medicineName': medicineName,
      'quantityOrdered': quantityOrdered,
      'quantityReceived': quantityReceived,
      'unitCostMinor': unitCostMinor,
    };
  }
}

/// A purchase order to one supplier for one branch.
///
/// Firestore collection: `branches/{branchId}/purchaseOrders/{poId}`
/// (+ `items` subcollection in production; embedded here in the demo
/// model). The PO number is sequential per branch (`PO-DHA-1001`, …).
class PurchaseOrder {
  final String id;
  final String poNumber;
  final String supplierId;
  final String branchId;
  final PurchaseOrderStatus status;
  final List<PurchaseOrderItem> items;
  final String? approvedBy;
  final String? notes;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const PurchaseOrder({
    required this.id,
    required this.poNumber,
    required this.supplierId,
    required this.branchId,
    this.status = PurchaseOrderStatus.draft,
    required this.items,
    this.approvedBy,
    this.notes,
    this.createdAt,
    this.updatedAt,
  });

  /// Total ordered value (int paisa).
  int get totalMinor =>
      items.fold(0, (sum, item) => sum + item.lineTotalMinor);

  /// Value received so far (int paisa) — what the supplier ledger is
  /// charged when goods arrive.
  int get receivedTotalMinor =>
      items.fold(0, (sum, item) => sum + item.receivedTotalMinor);

  bool get isFullyReceived =>
      items.isNotEmpty && items.every((item) => item.isFullyReceived);

  bool get hasAnyReceived => items.any((item) => item.quantityReceived > 0);

  PurchaseOrder copyWith({
    String? id,
    String? poNumber,
    String? supplierId,
    String? branchId,
    PurchaseOrderStatus? status,
    List<PurchaseOrderItem>? items,
    String? approvedBy,
    bool clearApprovedBy = false,
    String? notes,
    bool clearNotes = false,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return PurchaseOrder(
      id: id ?? this.id,
      poNumber: poNumber ?? this.poNumber,
      supplierId: supplierId ?? this.supplierId,
      branchId: branchId ?? this.branchId,
      status: status ?? this.status,
      items: items ?? this.items,
      approvedBy: clearApprovedBy ? null : (approvedBy ?? this.approvedBy),
      notes: clearNotes ? null : (notes ?? this.notes),
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  factory PurchaseOrder.fromMap(String id, Map<String, dynamic> map) {
    final rawItems = map['items'] as List<dynamic>? ?? [];
    return PurchaseOrder(
      id: id,
      poNumber: map['poNumber'] as String? ?? '',
      supplierId: map['supplierId'] as String? ?? '',
      branchId: map['branchId'] as String? ?? '',
      status: purchaseOrderStatusFromString(map['status'] as String?),
      items: rawItems
          .whereType<Map<String, dynamic>>()
          .map(PurchaseOrderItem.fromMap)
          .toList(),
      approvedBy: map['approvedBy'] as String?,
      notes: map['notes'] as String?,
      createdAt: parseDate(map['createdAt']),
      updatedAt: parseDate(map['updatedAt']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'poNumber': poNumber,
      'supplierId': supplierId,
      'branchId': branchId,
      'status': status.name,
      'items': items.map((item) => item.toMap()).toList(),
      'approvedBy': approvedBy,
      'notes': notes,
      'createdAt': dateToMap(createdAt),
      'updatedAt': dateToMap(updatedAt),
    };
  }
}
