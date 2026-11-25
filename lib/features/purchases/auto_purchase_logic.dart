import '../../models/inventory_item.dart';
import '../../models/medicine.dart';
import '../../models/purchase_order.dart';
import '../../models/supplier.dart';
import '../inventory/inventory_logic.dart';

/// Week 2 Day 2 — Auto Purchase List logic (pure functions, no widgets,
/// no providers, so the suggestion maths is unit-testable without
/// pumping anything).
///
/// The demo only had low-stock alerts + manual PO creation. This
/// module computes a suggested order list from live inventory and
/// groups the approved lines into Draft POs, one per supplier.
///
/// ## Rules (D63)
/// - One suggestion per medicine, branch-scoped. Batches are grouped
///   by medicine; a medicine with no batch rows at a branch has no
///   reorder level there and is never suggested.
/// - **Usable stock** = [sellableStockFor] — the Day 5 shared guard
///   (D30): non-expired batches with stock on hand only. Expired
///   batches never count as usable. There is no batch `status` field
///   on [InventoryItem] yet (the SRS batch status — available /
///   quarantined / expired / returned — is a Week 2 model migration),
///   so "non-quarantined" is currently the same as "sellable": a
///   quarantined batch cannot be represented in the model, and the
///   rule is re-checked when the status field lands (D64).
/// - **Reorder (par) level** = the sum of `lowStockThreshold` over
///   the medicine's batch rows at the branch (each seeded batch
///   carries 10, so a medicine with 3 batches has par 30). The
///   threshold lives on the batch row, so the par level follows the
///   branch's own alert levels instead of inventing a new field.
/// - **Suggested quantity** = reorder level − usable stock, floored
///   at 0. Only lines with suggested quantity > 0 appear.
/// - **Reason** (one label per line, highest priority first):
///   `Low stock` when usable stock is 0; `Near expiry — usable stock
///   low` when a sellable batch expires within 30 days; otherwise
///   `Below reorder level`.
/// - **Unit cost** = the cost of the FEFO batch (the batch that
///   would be sold first), falling back to the earliest-expiry batch
///   with a cost, then to 80% of the sale price (the Day 7 PO-form
///   default, D43).
/// - **Exclusions:** a medicine already on an open PO (Draft /
///   Approved / Partially received, same branch, with units still
///   outstanding) is excluded, so nothing is double-ordered. The
///   count counts only medicines that would otherwise have been
///   suggested — a covered medicine with plenty of stock was never
///   going to be suggested anyway.
/// - **Preferred supplier:** the catalogue has no medicine→supplier
///   field, so the suggestion reuses history — the supplier of the
///   most recent non-cancelled PO for that medicine at the branch,
///   falling back to the first active supplier. Staff can change it
///   per line on the screen; approval groups by the line's supplier.

/// Why a medicine is on the auto purchase list.
enum AutoPurchaseReason { lowStock, belowReorderLevel, nearExpiry }

String autoPurchaseReasonLabel(AutoPurchaseReason reason) => switch (reason) {
  AutoPurchaseReason.lowStock => 'Low stock',
  AutoPurchaseReason.belowReorderLevel => 'Below reorder level',
  AutoPurchaseReason.nearExpiry => 'Near expiry — usable stock low',
};

/// Statuses that count as "open" for the double-order exclusion:
/// the PO can still receive goods (or is waiting to be approved).
bool isOpenPurchaseOrderStatus(PurchaseOrderStatus status) =>
    status == PurchaseOrderStatus.draft ||
    status == PurchaseOrderStatus.approved ||
    status == PurchaseOrderStatus.partiallyReceived;

/// One suggested line: what to order, why, and at what cost.
/// All money is int paisa (D6).
class AutoPurchaseSuggestion {
  const AutoPurchaseSuggestion({
    required this.medicineId,
    required this.medicineName,
    required this.brand,
    required this.strength,
    required this.packSize,
    required this.reason,
    required this.usableStock,
    required this.reorderLevel,
    required this.unitCostMinor,
    required this.suggestedQuantity,
    required this.supplierId,
  });

  final String medicineId;
  final String medicineName;
  final String brand;
  final String strength;
  final String packSize;
  final AutoPurchaseReason reason;

  /// Sellable (non-expired, in-stock) units on hand.
  final int usableStock;

  /// Par level: sum of the batch low-stock thresholds.
  final int reorderLevel;

  /// Suggested cost price per unit, int paisa.
  final int unitCostMinor;

  /// reorderLevel − usableStock (> 0 for every suggested line).
  final int suggestedQuantity;

  /// Preferred supplier (see module doc); may be null when there is
  /// no active supplier at all — such a line cannot be approved.
  final String? supplierId;

  /// Suggested line value, int paisa.
  int get lineTotalMinor => suggestedQuantity * unitCostMinor;
}

/// An editable line on the screen: a suggestion plus the staff's
/// quantity and supplier choices.
class AutoPurchaseLine {
  const AutoPurchaseLine({
    required this.suggestion,
    required this.quantity,
    required this.supplierId,
  });

  final AutoPurchaseSuggestion suggestion;
  final int quantity;
  final String? supplierId;

  int get lineTotalMinor => quantity * suggestion.unitCostMinor;

  AutoPurchaseLine copyWith({int? quantity, String? supplierId}) {
    return AutoPurchaseLine(
      suggestion: suggestion,
      quantity: quantity ?? this.quantity,
      supplierId: supplierId ?? this.supplierId,
    );
  }

  PurchaseOrderItem toPurchaseOrderItem() => PurchaseOrderItem(
    medicineId: suggestion.medicineId,
    medicineName: suggestion.medicineName,
    quantityOrdered: quantity,
    unitCostMinor: suggestion.unitCostMinor,
  );
}

/// Reorder (par) level for one medicine at one branch: the sum of the
/// batch low-stock thresholds.
int reorderLevelFor(Iterable<InventoryItem> batches) =>
    batches.fold(0, (sum, batch) => sum + batch.lowStockThreshold);

/// Usable stock for one medicine: sellable batches only (D30 guard).
int usableStockFor(Iterable<InventoryItem> batches, {DateTime? now}) =>
    sellableStockFor(batches, now: now);

/// True when a sellable batch of the medicine expires within 30 days.
bool hasNearExpirySellableBatch(
  Iterable<InventoryItem> batches, {
  DateTime? now,
}) {
  return batches.any(
    (batch) =>
        isBatchSellable(batch, now: now) &&
        expiryBucketFor(batch.expiryDate, now: now) ==
            ExpiryBucket.within30,
  );
}

/// Suggested unit cost for one medicine (see module doc).
int suggestedUnitCostMinor({
  required List<InventoryItem> batches,
  required Medicine medicine,
}) {
  final fefo = fefoBatchFor(batches);
  if (fefo != null && fefo.costMinor > 0) return fefo.costMinor;
  final withCost = batches.where((batch) => batch.costMinor > 0).toList();
  if (withCost.isNotEmpty) {
    withCost.sort((a, b) {
      final aExpiry = a.expiryDate;
      final bExpiry = b.expiryDate;
      if (aExpiry == null && bExpiry == null) return 0;
      if (aExpiry == null) return 1;
      if (bExpiry == null) return -1;
      return aExpiry.compareTo(bExpiry);
    });
    return withCost.first.costMinor;
  }
  return (medicine.priceMinor * 0.8).round();
}

/// The reason label for a medicine whose usable stock is below its
/// reorder level (see module doc for the priority order).
AutoPurchaseReason reasonFor({
  required int usableStock,
  required bool nearExpiry,
}) {
  if (usableStock <= 0) return AutoPurchaseReason.lowStock;
  if (nearExpiry) return AutoPurchaseReason.nearExpiry;
  return AutoPurchaseReason.belowReorderLevel;
}

/// Medicine ids already covered by an open PO at [branchId], with
/// units still outstanding on the line.
Set<String> openPoMedicineIds(
  List<PurchaseOrder> orders, {
  required String branchId,
}) {
  final covered = <String>{};
  for (final order in orders) {
    if (order.branchId != branchId) continue;
    if (!isOpenPurchaseOrderStatus(order.status)) continue;
    for (final item in order.items) {
      if (item.quantityRemaining > 0) covered.add(item.medicineId);
    }
  }
  return covered;
}

/// Preferred supplier for a medicine: the supplier of the most
/// recent non-cancelled PO for it (branch-scoped, newest first),
/// falling back to the first active supplier, or `null` when there
/// is no active supplier.
String? preferredSupplierIdForMedicine({
  required String medicineId,
  required List<PurchaseOrder> branchOrders,
  required List<Supplier> suppliers,
}) {
  final active = suppliers.where((s) => s.isActive).toList();
  final sorted = branchOrders.toList()
    ..sort((a, b) {
      final aTime = a.createdAt;
      final bTime = b.createdAt;
      if (aTime == null && bTime == null) return 0;
      if (aTime == null) return 1;
      if (bTime == null) return -1;
      return bTime.compareTo(aTime);
    });
  for (final order in sorted) {
    if (order.status == PurchaseOrderStatus.cancelled) continue;
    if (!order.items.any((item) => item.medicineId == medicineId)) {
      continue;
    }
    if (active.any((s) => s.id == order.supplierId)) {
      return order.supplierId;
    }
  }
  return active.isEmpty ? null : active.first.id;
}

/// Result of computing the list: the lines to show, and the medicines
/// held back because an open PO already covers them.
class AutoPurchaseListResult {
  const AutoPurchaseListResult({
    required this.suggestions,
    required this.excluded,
  });

  /// Lines with suggested quantity > 0 and no open-PO cover.
  final List<AutoPurchaseSuggestion> suggestions;

  /// Medicines that would have been suggested but are covered by an
  /// open PO (same shape, so the screen can name them).
  final List<AutoPurchaseSuggestion> excluded;
}

/// Computes the auto purchase list for one branch from live data.
///
/// - [medicines] is the full catalogue; [inventory] is the branch's
///   batch rows (the caller scopes to the branch — never mix branches
///   in one list, and never mix them in one PO).
/// - [branchOrders] is the branch's POs (any status; the exclusion
///   only looks at open ones).
/// - [suppliers] is the supplier directory (active suppliers only
///   are used as fallbacks).
/// - [now] is injectable so tests can pin the date.
AutoPurchaseListResult computeAutoPurchaseList({
  required List<Medicine> medicines,
  required List<InventoryItem> inventory,
  required List<PurchaseOrder> branchOrders,
  required List<Supplier> suppliers,
  required String branchId,
  DateTime? now,
}) {
  final byMedicine = groupBatchesByMedicine(
    inventory.where((item) => item.branchId == branchId),
  );
  final medicineById = {for (final m in medicines) m.id: m};
  final covered = openPoMedicineIds(branchOrders, branchId: branchId);
  final suggestions = <AutoPurchaseSuggestion>[];
  final excluded = <AutoPurchaseSuggestion>[];
  for (final entry in byMedicine.entries) {
    final medicine = medicineById[entry.key];
    if (medicine == null) continue;
    final batches = entry.value;
    final usable = usableStockFor(batches, now: now);
    final reorderLevel = reorderLevelFor(batches);
    final suggested = reorderLevel - usable;
    if (suggested <= 0) continue;
    final suggestion = AutoPurchaseSuggestion(
      medicineId: medicine.id,
      medicineName: medicine.name,
      brand: medicine.brand,
      strength: medicine.strength,
      packSize: medicine.packSize,
      reason: reasonFor(
        usableStock: usable,
        nearExpiry: hasNearExpirySellableBatch(batches, now: now),
      ),
      usableStock: usable,
      reorderLevel: reorderLevel,
      unitCostMinor: suggestedUnitCostMinor(
        batches: batches,
        medicine: medicine,
      ),
      suggestedQuantity: suggested,
      supplierId: preferredSupplierIdForMedicine(
        medicineId: medicine.id,
        branchOrders: branchOrders,
        suppliers: suppliers,
      ),
    );
    if (covered.contains(medicine.id)) {
      excluded.add(suggestion);
    } else {
      suggestions.add(suggestion);
    }
  }
  // Most urgent first: out of stock, then lowest usable stock.
  int rank(AutoPurchaseSuggestion s) =>
      s.reason == AutoPurchaseReason.lowStock ? 0 : 1;
  suggestions.sort((a, b) {
    final byReason = rank(a).compareTo(rank(b));
    if (byReason != 0) return byReason;
    final byUsable = a.usableStock.compareTo(b.usableStock);
    if (byUsable != 0) return byUsable;
    return a.medicineName.compareTo(b.medicineName);
  });
  excluded.sort((a, b) => a.medicineName.compareTo(b.medicineName));
  return AutoPurchaseListResult(suggestions: suggestions, excluded: excluded);
}

/// Groups approved lines by supplier into PO items: one Draft PO per
/// supplier. Lines with quantity ≤ 0 contribute nothing (a line the
/// staff set to 0 is "do not order"). Lines without a supplier are
/// left out — [validateAutoPurchaseLines] flags them first.
Map<String, List<PurchaseOrderItem>> groupLinesBySupplier(
  List<AutoPurchaseLine> lines,
) {
  final grouped = <String, List<PurchaseOrderItem>>{};
  for (final line in lines) {
    final supplierId = line.supplierId;
    if (supplierId == null || supplierId.isEmpty) continue;
    if (line.quantity <= 0) continue;
    (grouped[supplierId] ??= []).add(line.toPurchaseOrderItem());
  }
  return grouped;
}

/// Total value of the approved lines (int paisa).
int autoPurchaseTotalMinor(List<AutoPurchaseLine> lines) =>
    lines
        .where((line) => line.quantity > 0)
        .fold(0, (sum, line) => sum + line.lineTotalMinor);

/// Validates the edited lines before approval. Returns the list of
/// problems (empty = valid). Quantities are integers by construction
/// (the screen parses text to int first); a negative quantity can
/// only arrive programmatically, so it is rejected here too.
List<String> validateAutoPurchaseLines(List<AutoPurchaseLine> lines) {
  final errors = <String>[];
  final orderable = lines.where((line) => line.quantity > 0).toList();
  if (orderable.isEmpty) {
    errors.add(
      'Nothing to order — set a quantity above 0 on at least one line.',
    );
    return errors;
  }
  for (final line in lines) {
    if (line.quantity < 0) {
      errors.add(
        '${line.suggestion.medicineName}: quantity cannot be negative.',
      );
    }
  }
  for (final line in orderable) {
    if (line.supplierId == null || line.supplierId!.isEmpty) {
      errors.add(
        '${line.suggestion.medicineName}: pick a supplier before approving.',
      );
    }
  }
  return errors;
}
