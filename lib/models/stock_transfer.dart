import 'model_utils.dart';

/// A stock transfer between two branches (SRS D-16, Week 4 Day 2).
///
/// Lifecycle: Requested → Approved → Dispatched → Received, with
/// Rejected (from Requested) and Cancelled (from Requested/Approved)
/// as terminal states. Stock moves only at Dispatch (FEFO pick from
/// the source branch, `transfer_out` ledger movements) and at Receive
/// (new batches in the destination branch, `transfer_in` movements)
/// — a request or an approval moves nothing.
///
/// Firestore collection: `branches/{fromBranchId}/stockTransfers`
/// (the requesting/source branch owns the document; the SRS §3
/// contract names only `fromBranchId` / `toBranchId` / `status` /
/// `requestedBy` / `approvedBy` — `items`, `note`,
/// `dispatchedBy` / `receivedBy`, `dispatchAllocations` and `isDemo`
/// are Week 4 Day 2 extras, D120).
enum StockTransferStatus {
  requested,
  approved,
  dispatched,
  received,
  rejected,
  cancelled,
}

extension StockTransferStatusFirestore on StockTransferStatus {
  String get firestoreValue => switch (this) {
    StockTransferStatus.requested => 'requested',
    StockTransferStatus.approved => 'approved',
    StockTransferStatus.dispatched => 'dispatched',
    StockTransferStatus.received => 'received',
    StockTransferStatus.rejected => 'rejected',
    StockTransferStatus.cancelled => 'cancelled',
  };

  String get label => switch (this) {
    StockTransferStatus.requested => 'Requested',
    StockTransferStatus.approved => 'Approved',
    StockTransferStatus.dispatched => 'Dispatched',
    StockTransferStatus.received => 'Received',
    StockTransferStatus.rejected => 'Rejected',
    StockTransferStatus.cancelled => 'Cancelled',
  };
}

StockTransferStatus stockTransferStatusFromFirestore(String? value) =>
    switch (value) {
      'requested' => StockTransferStatus.requested,
      'approved' => StockTransferStatus.approved,
      'dispatched' => StockTransferStatus.dispatched,
      'received' => StockTransferStatus.received,
      'rejected' => StockTransferStatus.rejected,
      'cancelled' => StockTransferStatus.cancelled,
      _ => StockTransferStatus.requested,
    };

/// One requested line of a transfer: a medicine and how many units
/// the destination branch needs.
class TransferItem {
  const TransferItem({
    required this.medicineId,
    required this.medicineName,
    required this.quantity,
  });

  factory TransferItem.fromMap(Map<String, dynamic> map) {
    return TransferItem(
      medicineId: map['medicineId'] as String? ?? '',
      medicineName: map['medicineName'] as String? ?? '',
      quantity: (map['quantity'] as num?)?.toInt() ?? 0,
    );
  }

  final String medicineId;
  final String medicineName;
  final int quantity;

  Map<String, dynamic> toMap() => {
    'medicineId': medicineId,
    'medicineName': medicineName,
    'quantity': quantity,
  };
}

/// One FEFO allocation recorded at dispatch: which source batch the
/// units came from, with the batch's identity carried along so the
/// destination receive can recreate the batch exactly (same batch
/// number, mfg/expiry, unit cost). Without this the receive step
/// would have to guess which batch the units left in.
class TransferAllocation {
  const TransferAllocation({
    required this.medicineId,
    required this.batchId,
    required this.batchNo,
    required this.quantity,
    this.mfgDate,
    this.expiryDate,
    this.unitCostMinor = 0,
  });

  factory TransferAllocation.fromMap(Map<String, dynamic> map) {
    return TransferAllocation(
      medicineId: map['medicineId'] as String? ?? '',
      batchId: map['batchId'] as String? ?? '',
      batchNo: map['batchNo'] as String? ?? '',
      quantity: (map['quantity'] as num?)?.toInt() ?? 0,
      mfgDate: parseDate(map['mfgDate']),
      expiryDate: parseDate(map['expiryDate']),
      unitCostMinor: (map['unitCostMinor'] as num?)?.toInt() ?? 0,
    );
  }

  final String medicineId;
  final String batchId;
  final String batchNo;
  final int quantity;
  final DateTime? mfgDate;
  final DateTime? expiryDate;
  final int unitCostMinor;

  Map<String, dynamic> toMap() => {
    'medicineId': medicineId,
    'batchId': batchId,
    'batchNo': batchNo,
    'quantity': quantity,
    'mfgDate': dateToMap(mfgDate),
    'expiryDate': dateToMap(expiryDate),
    'unitCostMinor': unitCostMinor,
  };
}

class StockTransfer {
  const StockTransfer({
    required this.id,
    required this.transferNumber,
    required this.fromBranchId,
    required this.toBranchId,
    required this.status,
    required this.items,
    this.note,
    this.requestedBy,
    this.approvedBy,
    this.dispatchedBy,
    this.receivedBy,
    this.dispatchAllocations = const [],
    this.isDemo = false,
    this.createdAt,
    this.updatedAt,
  });

  factory StockTransfer.fromMap(String id, Map<String, dynamic> map) {
    final rawItems = map['items'] as List<dynamic>? ?? [];
    final rawAllocations =
        map['dispatchAllocations'] as List<dynamic>? ?? [];
    return StockTransfer(
      id: id,
      transferNumber: map['transferNumber'] as String? ?? id,
      fromBranchId: map['fromBranchId'] as String? ?? '',
      toBranchId: map['toBranchId'] as String? ?? '',
      status: stockTransferStatusFromFirestore(map['status'] as String?),
      items: [
        for (final raw in rawItems)
          TransferItem.fromMap(Map<String, dynamic>.from(raw as Map)),
      ],
      note: map['note'] as String?,
      requestedBy: map['requestedBy'] as String?,
      approvedBy: map['approvedBy'] as String?,
      dispatchedBy: map['dispatchedBy'] as String?,
      receivedBy: map['receivedBy'] as String?,
      dispatchAllocations: [
        for (final raw in rawAllocations)
          TransferAllocation.fromMap(
            Map<String, dynamic>.from(raw as Map),
          ),
      ],
      isDemo: map['isDemo'] as bool? ?? false,
      createdAt: parseDate(map['createdAt']),
      updatedAt: parseDate(map['updatedAt']),
    );
  }

  final String id;
  final String transferNumber;
  final String fromBranchId;
  final String toBranchId;
  final StockTransferStatus status;
  final List<TransferItem> items;
  final String? note;
  final String? requestedBy;
  final String? approvedBy;
  final String? dispatchedBy;
  final String? receivedBy;

  /// FEFO allocations, filled at dispatch, empty before.
  final List<TransferAllocation> dispatchAllocations;

  /// True for the seeded sample transfers (fictional sample data,
  /// never real stock movements — D102 posture for demo figures).
  final bool isDemo;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// Total units requested across all lines.
  int get totalQuantity =>
      items.fold(0, (sum, item) => sum + item.quantity);

  StockTransfer copyWith({
    String? id,
    String? transferNumber,
    String? fromBranchId,
    String? toBranchId,
    StockTransferStatus? status,
    List<TransferItem>? items,
    String? note,
    bool clearNote = false,
    String? requestedBy,
    String? approvedBy,
    String? dispatchedBy,
    String? receivedBy,
    List<TransferAllocation>? dispatchAllocations,
    bool? isDemo,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return StockTransfer(
      id: id ?? this.id,
      transferNumber: transferNumber ?? this.transferNumber,
      fromBranchId: fromBranchId ?? this.fromBranchId,
      toBranchId: toBranchId ?? this.toBranchId,
      status: status ?? this.status,
      items: items ?? this.items,
      note: clearNote ? null : (note ?? this.note),
      requestedBy: requestedBy ?? this.requestedBy,
      approvedBy: approvedBy ?? this.approvedBy,
      dispatchedBy: dispatchedBy ?? this.dispatchedBy,
      receivedBy: receivedBy ?? this.receivedBy,
      dispatchAllocations: dispatchAllocations ?? this.dispatchAllocations,
      isDemo: isDemo ?? this.isDemo,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'transferNumber': transferNumber,
      'fromBranchId': fromBranchId,
      'toBranchId': toBranchId,
      'status': status.firestoreValue,
      'items': [for (final item in items) item.toMap()],
      'note': note,
      'requestedBy': requestedBy,
      'approvedBy': approvedBy,
      'dispatchedBy': dispatchedBy,
      'receivedBy': receivedBy,
      'dispatchAllocations': [
        for (final allocation in dispatchAllocations) allocation.toMap(),
      ],
      'isDemo': isDemo,
      'createdAt': dateToMap(createdAt),
      'updatedAt': dateToMap(updatedAt),
    };
  }
}
