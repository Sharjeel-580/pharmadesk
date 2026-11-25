import '../../models/medicine.dart';
import '../../models/purchase_order.dart';

/// Day 7 purchase logic — pure functions over plain values, so they
/// are unit-testable without pumping anything.
///
/// Status flow (SRS FR-PUR-01/02): Draft → Approved → Received
/// (Partially received in between for partial deliveries) or
/// Cancelled. Receiving adds batches to inventory and charges the
/// supplier ledger (FR-PUR-03) — that coordination lives in the
/// purchases provider; the guards and maths live here.

/// Human label for a PO status.
String poStatusLabel(PurchaseOrderStatus status) =>
    purchaseOrderStatusLabel(status);

/// True when the PO can be approved: only from Draft.
bool canApprovePo(PurchaseOrderStatus status) =>
    status == PurchaseOrderStatus.draft;

/// True when goods can be received against the PO: Approved or
/// Partially received, with at least one unit still outstanding.
bool canReceivePo(PurchaseOrder order) =>
    (order.status == PurchaseOrderStatus.approved ||
        order.status == PurchaseOrderStatus.partiallyReceived) &&
    order.items.any((item) => item.quantityRemaining > 0);

/// True when the PO can be cancelled: Draft or Approved (never after
/// any goods have been received).
bool canCancelPo(PurchaseOrder order) =>
    (order.status == PurchaseOrderStatus.draft ||
        order.status == PurchaseOrderStatus.approved) &&
    !order.hasAnyReceived;

/// Status after a receiving step: Received when every line is full,
/// otherwise Partially received.
PurchaseOrderStatus statusAfterReceiving(PurchaseOrder order) =>
    order.isFullyReceived
        ? PurchaseOrderStatus.received
        : PurchaseOrderStatus.partiallyReceived;

/// Total ordered value (int paisa) for a list of PO lines.
int poTotalMinor(List<PurchaseOrderItem> items) =>
    items.fold(0, (sum, item) => sum + item.lineTotalMinor);

/// Value received so far (int paisa) for a list of PO lines.
int poReceivedTotalMinor(List<PurchaseOrderItem> items) =>
    items.fold(0, (sum, item) => sum + item.receivedTotalMinor);

/// One line of a goods-receiving entry: how many units of [item]
/// arrived in this delivery, plus the batch they arrived as.
class ReceivingLine {
  const ReceivingLine({
    required this.item,
    this.quantityReceivedNow = 0,
    this.batchNo = '',
    this.mfgDate,
    this.expiryDate,
  });

  final PurchaseOrderItem item;
  final int quantityReceivedNow;
  final String batchNo;
  final DateTime? mfgDate;
  final DateTime? expiryDate;

  ReceivingLine copyWith({
    int? quantityReceivedNow,
    String? batchNo,
    DateTime? mfgDate,
    DateTime? expiryDate,
  }) {
    return ReceivingLine(
      item: item,
      quantityReceivedNow:
          quantityReceivedNow ?? this.quantityReceivedNow,
      batchNo: batchNo ?? this.batchNo,
      mfgDate: mfgDate ?? this.mfgDate,
      expiryDate: expiryDate ?? this.expiryDate,
    );
  }
}

/// Validates a create/edit PO form. Returns the list of problems
/// (empty = valid).
List<String> validatePurchaseOrderForm({
  String? supplierId,
  required List<PurchaseOrderItem> items,
}) {
  final errors = <String>[];
  if (supplierId == null || supplierId.isEmpty) {
    errors.add('Select a supplier for this purchase order.');
  }
  if (items.isEmpty) {
    errors.add('Add at least one medicine to the purchase order.');
  }
  for (final item in items) {
    if (item.quantityOrdered < 1) {
      errors.add('${item.medicineName}: quantity must be at least 1.');
    }
    if (item.unitCostMinor < 0) {
      errors.add('${item.medicineName}: cost price cannot be negative.');
    }
  }
  return errors;
}

/// Validates a goods-receiving step. Returns the list of problems
/// (empty = valid).
///
/// - At least one line must receive at least one unit.
/// - A line may not receive more than its remaining quantity.
/// - Every line receiving units needs a batch number, a manufacture
///   date and an expiry date after the manufacture date.
List<String> validateReceiving(List<ReceivingLine> lines) {
  final errors = <String>[];
  if (lines.every((line) => line.quantityReceivedNow <= 0)) {
    errors.add('Receive at least one unit on at least one line.');
  }
  for (final line in lines) {
    final qty = line.quantityReceivedNow;
    if (qty < 0) {
      errors.add('${line.item.medicineName}: quantity cannot be negative.');
      continue;
    }
    if (qty == 0) continue;
    if (qty > line.item.quantityRemaining) {
      errors.add(
        '${line.item.medicineName}: only ${line.item.quantityRemaining} '
        'units are still outstanding on this order.',
      );
    }
    if (line.batchNo.trim().isEmpty) {
      errors.add('${line.item.medicineName}: a batch number is required.');
    }
    if (line.mfgDate == null) {
      errors.add('${line.item.medicineName}: a manufacture date is required.');
    }
    if (line.expiryDate == null) {
      errors.add('${line.item.medicineName}: an expiry date is required.');
    }
    if (line.mfgDate != null &&
        line.expiryDate != null &&
        !line.expiryDate!.isAfter(line.mfgDate!)) {
      errors.add(
        '${line.item.medicineName}: expiry date must be after the '
        'manufacture date.',
      );
    }
  }
  return errors;
}

/// Applies a receiving step to a PO's lines: returns the updated
/// lines with `quantityReceived` increased by the received amounts.
List<PurchaseOrderItem> applyReceiving(
  List<PurchaseOrderItem> items,
  List<ReceivingLine> lines,
) {
  return items.map((item) {
    final line = lines
        .where((l) => l.item.medicineId == item.medicineId)
        .firstOrNull;
    if (line == null) return item;
    return item.copyWith(
      quantityReceived: item.quantityReceived + line.quantityReceivedNow,
    );
  }).toList();
}

/// Filters POs: branch scope, then status, then free text (PO number
/// or supplier name, case-insensitive, partial).
List<PurchaseOrder> filterPurchaseOrders({
  required List<PurchaseOrder> orders,
  required String branchId,
  PurchaseOrderStatus? statusFilter,
  String query = '',
  Map<String, String> supplierNamesById = const {},
}) {
  final needle = query.trim().toLowerCase();
  final scoped = orders.where((po) => po.branchId == branchId);
  return scoped.where((po) {
    if (statusFilter != null && po.status != statusFilter) return false;
    if (needle.isEmpty) return true;
    final supplierName =
        supplierNamesById[po.supplierId]?.toLowerCase() ?? '';
    return po.poNumber.toLowerCase().contains(needle) ||
        supplierName.contains(needle);
  }).toList()..sort((a, b) {
    final aTime = a.createdAt;
    final bTime = b.createdAt;
    if (aTime == null && bTime == null) return 0;
    if (aTime == null) return 1;
    if (bTime == null) return -1;
    return bTime.compareTo(aTime);
  });
}

/// Builds a draft PO from the create form. All money is int paisa.
/// [id] is the client-generated id when the caller mints one (auto
/// purchase approval, D65) — the repository dedupes on a non-empty id
/// and still assigns the sequential PO number.
PurchaseOrder buildNewPurchaseOrder({
  required String branchId,
  required String supplierId,
  required List<PurchaseOrderItem> items,
  String? notes,
  String id = '',
}) {
  return PurchaseOrder(
    id: id,
    poNumber: '',
    supplierId: supplierId,
    branchId: branchId,
    status: PurchaseOrderStatus.draft,
    items: List.unmodifiable(items),
    notes: notes?.trim().isEmpty ?? true ? null : notes!.trim(),
  );
}

/// Looks a medicine up by id for the PO form's medicine picker.
Medicine? findMedicineById(List<Medicine> medicines, String id) {
  for (final medicine in medicines) {
    if (medicine.id == id) return medicine;
  }
  return null;
}
