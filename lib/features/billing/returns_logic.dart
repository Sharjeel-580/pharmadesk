import '../../models/inventory_item.dart';
import '../../models/sale.dart';
import '../../models/sale_return.dart';
import '../inventory/inventory_logic.dart';

/// Returns / refunds (Week 2 Day 4, FR-POS-08, SRS §3.4
/// `saleReturns`) — pure functions over plain values, so they are
/// unit-testable without pumping anything.
///
/// All money is int minor units (paisa) — never doubles (D6).
///
/// **Refund rule:** the refund for a returned chunk is its line total
/// for the returned units — unit price × qty, minus the line discount
/// pro-rated across the chunk's units (integer division truncates, so
/// the refund never exceeds the line total). The bill discount and
/// tax are NOT refunded: they were computed on the whole bill, and
/// re-allocating them per chunk would invent a split the bill never
/// had. The refund is therefore the sum of the returned chunks'
/// line totals — documented here so a future change is deliberate.
/// **Restock rule (D78):** returned units go back into the batch they
/// were sold from when that batch still exists in inventory; when it
/// is gone, into the earliest-expiry `available` batch of the same
/// medicine; when no batch of the medicine exists at all, the return
/// is rejected — restocking never invents a batch, and never moves
/// stock to a different medicine. The batch's status decides whether
/// the restocked units can sell again (the Day 5 guard, D30) — a
/// return into an expired batch restocks unsellable stock, which is
/// correct: expired stock can never be sold.
///
/// A sale chunk is keyed by (`medicineId`, `batchId`): a cart line
/// split across FEFO batches is two chunks, so the medicine id alone
/// is not enough to match a return against what was sold.

/// Chunk key: `medicineId|batchId` (empty batch id when the chunk
/// was sold without a batch).
String returnChunkKey(String medicineId, String? batchId) =>
    '$medicineId|${batchId ?? ''}';

/// Quantities sold per chunk, from the sale's items.
Map<String, int> soldChunkQuantities(Sale sale) {
  final sold = <String, int>{};
  for (final item in sale.items) {
    final key = returnChunkKey(item.medicineId, item.batchId);
    sold[key] = (sold[key] ?? 0) + item.quantity;
  }
  return sold;
}

/// Quantities already returned per chunk, across all returns recorded
/// against the sale so far.
Map<String, int> alreadyReturnedChunkQuantities(List<SaleReturn> returns) {
  final returned = <String, int>{};
  for (final saleReturn in returns) {
    for (final item in saleReturn.items) {
      final key = returnChunkKey(item.medicineId, item.saleBatchId);
      returned[key] = (returned[key] ?? 0) + item.quantity;
    }
  }
  return returned;
}

/// Quantities still returnable per chunk: sold − already returned.
Map<String, int> returnableChunkQuantities(
  Sale sale,
  List<SaleReturn> existingReturns,
) {
  final sold = soldChunkQuantities(sale);
  final returned = alreadyReturnedChunkQuantities(existingReturns);
  final returnable = <String, int>{};
  for (final entry in sold.entries) {
    final left = entry.value - (returned[entry.key] ?? 0);
    if (left > 0) returnable[entry.key] = left;
  }
  return returnable;
}

/// Refund for one chunk: unit price × qty − pro-rated line discount,
/// never below zero.
///
/// The line discount belongs to the whole chunk; returning part of it
/// refunds the same share of the discount
/// (`discount × qty / chunkQty`, truncated). Returning the whole chunk
/// refunds the full discount, so the refund equals the chunk's line
/// total exactly.
int chunkRefundMinor({required SaleItem item, required int quantity}) {
  if (quantity <= 0) return 0;
  final discountShare = item.lineDiscountMinor * quantity ~/ item.quantity;
  final refund = item.unitPriceMinor * quantity - discountShare;
  return refund < 0 ? 0 : refund;
}

/// Total refund for the requested quantities (chunk key → qty).
int computeRefundMinor({
  required Sale sale,
  required Map<String, int> quantities,
}) {
  var refund = 0;
  for (final item in sale.items) {
    final qty = quantities[returnChunkKey(item.medicineId, item.batchId)] ?? 0;
    refund += chunkRefundMinor(item: item, quantity: qty);
  }
  return refund;
}

/// Validates a return before anything is written. Returns the list of
/// problems (empty = the return may be recorded).
///
/// - The reason is required (SRS: a return without a reason is not
///   an auditable record).
/// - At least one item must be returned, and no chunk may be returned
///   past what is still returnable (sold − already returned).
/// - A voided sale cannot be returned; a fully-returned sale has
///   nothing left to return (caught by the quantity check).
List<String> validateReturn({
  required Sale sale,
  required List<SaleReturn> existingReturns,
  required Map<String, int> quantities,
  required String reason,
}) {
  final errors = <String>[];
  if (reason.trim().isEmpty) {
    errors.add('A reason for the return is required.');
  }
  if (sale.status == SaleStatus.voided) {
    errors.add('This sale was voided — it cannot be returned.');
  }
  final returnable = returnableChunkQuantities(sale, existingReturns);
  var anyQuantity = false;
  for (final entry in quantities.entries) {
    final qty = entry.value;
    if (qty < 0) {
      errors.add('Return quantity cannot be negative.');
      continue;
    }
    if (qty == 0) continue;
    anyQuantity = true;
    final left = returnable[entry.key] ?? 0;
    if (qty > left) {
      errors.add(
        'Only $left unit(s) of this item can still be returned.',
      );
    }
  }
  if (!anyQuantity) {
    errors.add('Pick at least one item to return.');
  }
  return errors;
}

/// Sale status after a return: `returned` when every sold unit has
/// come back (across all returns for the sale), else
/// `partiallyReturned`. The caller passes the full return list
/// including the return being recorded.
SaleStatus returnStatusAfter({
  required Sale sale,
  required List<SaleReturn> allReturns,
}) {
  final sold = soldChunkQuantities(sale);
  final returned = alreadyReturnedChunkQuantities(allReturns);
  for (final entry in sold.entries) {
    if ((returned[entry.key] ?? 0) < entry.value) {
      return SaleStatus.partiallyReturned;
    }
  }
  return SaleStatus.returned;
}

/// Where returned units of one chunk are restocked (D78): the
/// original batch when it still exists in inventory, else the
/// earliest-expiry `available` batch of the same medicine, else
/// `null` (the caller rejects the return — restocking never invents
/// a batch).
InventoryItem? restockTarget({
  required List<InventoryItem> inventory,
  required String medicineId,
  required String? originalBatchId,
}) {
  if (originalBatchId != null) {
    for (final batch in inventory) {
      if (batch.id == originalBatchId) return batch;
    }
  }
  final sameMedicine = inventory
      .where(
        (batch) =>
            batch.medicineId == medicineId &&
            batch.status == BatchStatus.available,
      )
      .toList();
  if (sameMedicine.isEmpty) return null;
  return fefoBatches(sameMedicine).first;
}
