import 'model_utils.dart';

/// A return / refund against a completed POS sale (Week 2 Day 4,
/// SRS §3.4 `branches/{branchId}/saleReturns` + `items` subcollection,
/// FR-POS-08).
///
/// One [SaleReturn] records one approved return event: the sale it
/// reverses, the items + quantities handed back, the reason (required),
/// the refund in int paisa, and who approved it. Restocking, the sale
/// status transition and the khata adjustment happen with the return
/// (see `returns_provider.dart`) — the record itself is the audit
/// trail, append-only like the ledgers.
///
/// All money is int minor units (paisa) — never doubles (D6).

/// Status of a return record. A return is `completed` the moment it is
/// approved and applied (restock + refund + khata all happen in the
/// same step); `reversed` is reserved for a future void/correction
/// flow — returns are never edited or deleted today.
enum SaleReturnStatus { completed, reversed }

SaleReturnStatus saleReturnStatusFromString(String? value) => switch (value) {
  'reversed' => SaleReturnStatus.reversed,
  _ => SaleReturnStatus.completed,
};

String saleReturnStatusLabel(SaleReturnStatus status) => switch (status) {
  SaleReturnStatus.completed => 'Completed',
  SaleReturnStatus.reversed => 'Reversed',
};

/// One returned line: how many units of one sale chunk came back and
/// what was refunded for them.
///
/// A sale chunk is keyed by (`medicineId`, `batchId`) — the sale items
/// carry no ids of their own, and a cart line split across FEFO
/// batches is two chunks, so the medicine id alone is not enough.
class SaleReturnItem {
  const SaleReturnItem({
    required this.medicineId,
    required this.medicineName,
    required this.quantity,
    required this.unitPriceMinor,
    this.lineDiscountMinor = 0,
    required this.refundMinor,
    this.saleBatchId,
    this.restockBatchId,
    this.restockBatchNo,
  });

  final String medicineId;
  final String medicineName;
  final int quantity;

  /// Unit sale price in int minor units (paisa).
  final int unitPriceMinor;

  /// Line discount refunded for this chunk (pro-rated, int paisa).
  final int lineDiscountMinor;

  /// Refund for this chunk in int minor units (paisa).
  final int refundMinor;

  /// The batch the chunk was originally sold from — the key
  /// validation matches returns against ("how many of this chunk
  /// have already come back").
  final String? saleBatchId;

  /// The batch the units were restocked into (the original batch when
  /// it still exists, else the FEFO-earliest available batch — D78).
  final String? restockBatchId;
  final String? restockBatchNo;

  factory SaleReturnItem.fromMap(Map<String, dynamic> map) {
    return SaleReturnItem(
      medicineId: map['medicineId'] as String? ?? '',
      medicineName: map['medicineName'] as String? ?? '',
      quantity: (map['quantity'] as num?)?.toInt() ?? 0,
      unitPriceMinor: (map['unitPriceMinor'] as num?)?.toInt() ?? 0,
      lineDiscountMinor: (map['lineDiscountMinor'] as num?)?.toInt() ?? 0,
      refundMinor: (map['refundMinor'] as num?)?.toInt() ?? 0,
      saleBatchId: map['saleBatchId'] as String?,
      restockBatchId: map['restockBatchId'] as String?,
      restockBatchNo: map['restockBatchNo'] as String?,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'medicineId': medicineId,
      'medicineName': medicineName,
      'quantity': quantity,
      'unitPriceMinor': unitPriceMinor,
      'lineDiscountMinor': lineDiscountMinor,
      'refundMinor': refundMinor,
      'saleBatchId': saleBatchId,
      'restockBatchId': restockBatchId,
      'restockBatchNo': restockBatchNo,
    };
  }

  SaleReturnItem copyWith({
    String? medicineId,
    String? medicineName,
    int? quantity,
    int? unitPriceMinor,
    int? lineDiscountMinor,
    int? refundMinor,
    String? saleBatchId,
    String? restockBatchId,
    String? restockBatchNo,
  }) {
    return SaleReturnItem(
      medicineId: medicineId ?? this.medicineId,
      medicineName: medicineName ?? this.medicineName,
      quantity: quantity ?? this.quantity,
      unitPriceMinor: unitPriceMinor ?? this.unitPriceMinor,
      lineDiscountMinor: lineDiscountMinor ?? this.lineDiscountMinor,
      refundMinor: refundMinor ?? this.refundMinor,
      saleBatchId: saleBatchId ?? this.saleBatchId,
      restockBatchId: restockBatchId ?? this.restockBatchId,
      restockBatchNo: restockBatchNo ?? this.restockBatchNo,
    );
  }
}

/// One approved return event against a sale.
class SaleReturn {
  const SaleReturn({
    required this.id,
    required this.branchId,
    required this.saleId,
    required this.invoiceNumber,
    required this.items,
    required this.reason,
    required this.refundedAmountMinor,
    required this.approvedBy,
    required this.approvedByName,
    this.status = SaleReturnStatus.completed,
    this.createdAt,
  });

  final String id;
  final String branchId;

  /// The sale being (partly) reversed.
  final String saleId;

  /// Denormalised invoice number so the returns list reads without a
  /// sale lookup.
  final String invoiceNumber;
  final List<SaleReturnItem> items;

  /// Reason for the return (required — validation rejects an empty
  /// reason before anything is written).
  final String reason;

  /// Total refund in int minor units (paisa): the sum of the item
  /// refunds.
  final int refundedAmountMinor;

  /// Who approved the return (uid) — approval is role-gated
  /// (`posRefund` via the permission service, D70).
  final String approvedBy;
  final String approvedByName;

  final SaleReturnStatus status;
  final DateTime? createdAt;

  /// True when every unit of the original sale has been returned
  /// (this return alone, or together with earlier returns — the
  /// caller passes the sale's total quantities).
  bool isFullReturn({required Map<String, int> soldQuantities}) {
    // Compare per medicine: a chunk restocked into a different batch
    // still counts toward its medicine's returned total.
    final byMedicine = <String, int>{};
    for (final item in items) {
      byMedicine[item.medicineId] =
          (byMedicine[item.medicineId] ?? 0) + item.quantity;
    }
    for (final entry in soldQuantities.entries) {
      if ((byMedicine[entry.key] ?? 0) < entry.value) return false;
    }
    return true;
  }

  factory SaleReturn.fromMap(String id, Map<String, dynamic> map) {
    final rawItems = map['items'] as List<dynamic>? ?? [];
    return SaleReturn(
      id: id,
      branchId: map['branchId'] as String? ?? '',
      saleId: map['saleId'] as String? ?? '',
      invoiceNumber: map['invoiceNumber'] as String? ?? '',
      items: rawItems
          .whereType<Map<String, dynamic>>()
          .map(SaleReturnItem.fromMap)
          .toList(),
      reason: map['reason'] as String? ?? '',
      refundedAmountMinor: (map['refundedAmount'] as num?)?.toInt() ?? 0,
      approvedBy: map['approvedBy'] as String? ?? '',
      approvedByName: map['approvedByName'] as String? ?? '',
      status: saleReturnStatusFromString(map['status'] as String?),
      createdAt: parseDate(map['createdAt']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'branchId': branchId,
      'saleId': saleId,
      'invoiceNumber': invoiceNumber,
      'items': items.map((item) => item.toMap()).toList(),
      'reason': reason,
      'refundedAmount': refundedAmountMinor,
      'approvedBy': approvedBy,
      'approvedByName': approvedByName,
      'status': status.name,
      'createdAt': dateToMap(createdAt),
    };
  }

  SaleReturn copyWith({
    String? id,
    String? branchId,
    String? saleId,
    String? invoiceNumber,
    List<SaleReturnItem>? items,
    String? reason,
    int? refundedAmountMinor,
    String? approvedBy,
    String? approvedByName,
    SaleReturnStatus? status,
    DateTime? createdAt,
  }) {
    return SaleReturn(
      id: id ?? this.id,
      branchId: branchId ?? this.branchId,
      saleId: saleId ?? this.saleId,
      invoiceNumber: invoiceNumber ?? this.invoiceNumber,
      items: items ?? this.items,
      reason: reason ?? this.reason,
      refundedAmountMinor: refundedAmountMinor ?? this.refundedAmountMinor,
      approvedBy: approvedBy ?? this.approvedBy,
      approvedByName: approvedByName ?? this.approvedByName,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}
