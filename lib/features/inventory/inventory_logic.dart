import '../../core/widgets/badges.dart';
import '../../models/branch_inventory_location.dart';
import '../../models/inventory_item.dart';

/// Day 5 inventory logic — pure functions, no widgets, no providers, so
/// they are unit-testable without pumping anything.
///
/// One [InventoryItem] is ONE BATCH. A medicine has 1–3 batch rows per
/// branch; the batch list, FEFO ordering, expiry buckets and the
/// sellable guard all read off these rows.
///
/// THE RULE (SRS §8, demo scope): an expired batch can NEVER be sold —
/// not from an order, not from the POS. Since Day 3 (D68) the same
/// applies to a batch whose SRS §3 status is not `available`
/// (quarantined / expired / returned). The guard lives here, in ONE
/// place ([isBatchSellable] / [canSellMedicine]); the Day 4 order form
/// and the Day 6 POS both call it instead of re-implementing the rule
/// (D30).

/// Expiry buckets used by the inventory screen's filters (SRS §8:
/// 30/60/90 days + expired).
enum ExpiryBucket { expired, within30, within60, within90, fresh }

/// Which bucket an expiry date falls in, relative to [now] (defaults to
/// today). A null expiry (no batch info) counts as [ExpiryBucket.fresh].
/// "Expires today" is expired — a batch is sellable only while its
/// expiry day is still ahead (same rule as [InventoryItem.isExpired]).
ExpiryBucket expiryBucketFor(DateTime? expiry, {DateTime? now}) {
  if (expiry == null) return ExpiryBucket.fresh;
  final reference = now ?? DateTime.now();
  final today = DateTime(reference.year, reference.month, reference.day);
  final expiryDay = DateTime(expiry.year, expiry.month, expiry.day);
  final daysLeft = expiryDay.difference(today).inDays;
  if (daysLeft <= 0) return ExpiryBucket.expired;
  if (daysLeft <= 30) return ExpiryBucket.within30;
  if (daysLeft <= 60) return ExpiryBucket.within60;
  if (daysLeft <= 90) return ExpiryBucket.within90;
  return ExpiryBucket.fresh;
}

/// Days until expiry (negative when expired, 0 when it expires today).
/// Null when there is no expiry date.
int? daysToExpiry(DateTime? expiry, {DateTime? now}) {
  if (expiry == null) return null;
  final reference = now ?? DateTime.now();
  final today = DateTime(reference.year, reference.month, reference.day);
  final expiryDay = DateTime(expiry.year, expiry.month, expiry.day);
  return expiryDay.difference(today).inDays;
}

String expiryBucketLabel(ExpiryBucket bucket) => switch (bucket) {
  ExpiryBucket.expired => 'Expired',
  ExpiryBucket.within30 => 'Expiring ≤ 30 days',
  ExpiryBucket.within60 => 'Expiring 31–60 days',
  ExpiryBucket.within90 => 'Expiring 61–90 days',
  ExpiryBucket.fresh => 'Fresh (> 90 days)',
};

StatusKind expiryBucketKind(ExpiryBucket bucket) => switch (bucket) {
  ExpiryBucket.expired => StatusKind.danger,
  ExpiryBucket.within30 => StatusKind.warning,
  ExpiryBucket.within60 => StatusKind.warning,
  ExpiryBucket.within90 => StatusKind.info,
  ExpiryBucket.fresh => StatusKind.success,
};

/// THE GUARD — true only when this batch may be sold: its status is
/// [BatchStatus.available] (D68 — quarantined / expired / returned
/// batches are never sellable, even with stock on hand and a future
/// expiry date), its expiry day is still ahead AND it has stock on
/// hand. Expired batches and empty batches are never sellable. [now]
/// is injectable so tests can pin the date; production callers omit it.
bool isBatchSellable(InventoryItem batch, {DateTime? now}) {
  if (batch.status != BatchStatus.available) return false;
  if (batch.quantity <= 0) return false;
  return expiryBucketFor(batch.expiryDate, now: now) != ExpiryBucket.expired;
}

/// True when at least one batch of the medicine can be sold.
bool canSellMedicine(Iterable<InventoryItem> batches, {DateTime? now}) =>
    batches.any((batch) => isBatchSellable(batch, now: now));

/// Batches in FEFO order — earliest expiry first, so the batch that
/// expires soonest is always sold first. Batches with no expiry date
/// sort last; ties break on batch number for a stable order.
List<InventoryItem> fefoBatches(Iterable<InventoryItem> batches) {
  final sorted = batches.toList();
  sorted.sort((a, b) {
    final aExpiry = a.expiryDate;
    final bExpiry = b.expiryDate;
    if (aExpiry == null && bExpiry == null) {
      return (a.batchNo ?? '').compareTo(b.batchNo ?? '');
    }
    if (aExpiry == null) return 1;
    if (bExpiry == null) return -1;
    final byExpiry = aExpiry.compareTo(bExpiry);
    if (byExpiry != 0) return byExpiry;
    return (a.batchNo ?? '').compareTo(b.batchNo ?? '');
  });
  return sorted;
}

/// The batch to sell from: the first sellable batch in FEFO order, or
/// `null` when every batch is expired or empty. This is what the order
/// form and the POS show as the batch being picked.
InventoryItem? fefoBatchFor(Iterable<InventoryItem> batches, {DateTime? now}) {
  for (final batch in fefoBatches(batches)) {
    if (isBatchSellable(batch, now: now)) return batch;
  }
  return null;
}

/// Stock on hand that can actually be sold (non-expired batches only).
int sellableStockFor(Iterable<InventoryItem> batches, {DateTime? now}) =>
    batches
        .where((batch) => isBatchSellable(batch, now: now))
        .fold(0, (sum, batch) => sum + batch.quantity);

/// Total units across all batches, expired included (the physical count
/// on the shelf — expired stock still has to be written off, not sold).
int totalStockFor(Iterable<InventoryItem> batches) =>
    batches.fold(0, (sum, batch) => sum + batch.quantity);

/// True when any batch row sits at or below its low-stock threshold.
bool isMedicineLowStock(Iterable<InventoryItem> batches) =>
    batches.any((batch) => batch.isLowStock);

/// Groups batch rows by medicine id, each group in FEFO order.
Map<String, List<InventoryItem>> groupBatchesByMedicine(
  Iterable<InventoryItem> batches,
) {
  final grouped = <String, List<InventoryItem>>{};
  for (final batch in batches) {
    (grouped[batch.medicineId] ??= []).add(batch);
  }
  for (final group in grouped.values) {
    group.sort((a, b) {
      final aExpiry = a.expiryDate;
      final bExpiry = b.expiryDate;
      if (aExpiry == null && bExpiry == null) return 0;
      if (aExpiry == null) return 1;
      if (bExpiry == null) return -1;
      return aExpiry.compareTo(bExpiry);
    });
  }
  return grouped;
}

/// Short date for batch rows and dialogs, e.g. `4/1/2027`.
String formatShortDate(DateTime value) =>
    '${value.day}/${value.month}/${value.year}';

/// Counts batch rows per expiry bucket (for the inventory filter chips).
Map<ExpiryBucket, int> expiryBucketCounts(
  Iterable<InventoryItem> batches, {
  DateTime? now,
}) {
  final counts = {for (final bucket in ExpiryBucket.values) bucket: 0};
  for (final batch in batches) {
    final bucket = expiryBucketFor(batch.expiryDate, now: now);
    counts[bucket] = counts[bucket]! + 1;
  }
  return counts;
}

/// Effective storage location for a medicine at one branch (Week 5
/// Day 3, D152 — SRS §3.3 / FR-INV-10).
///
/// The per-branch rack/shelf override wins when it carries a value;
/// otherwise the master [Medicine.location] is the default shelf.
/// Returns `null` when neither is set — the screens show "Not set".
String? effectiveLocation({
  required String? masterLocation,
  BranchInventoryLocation? override,
}) {
  final overrideLabel = override?.displayLabel;
  if (overrideLabel != null) return overrideLabel;
  final master = masterLocation?.trim();
  if (master == null || master.isEmpty) return null;
  return master;
}

/// Finds the override for one (branch, medicine) in a locations list,
/// or `null` when the branch keeps the medicine at the default shelf.
BranchInventoryLocation? branchLocationFor(
  Iterable<BranchInventoryLocation> locations, {
  required String branchId,
  required String medicineId,
}) {
  for (final location in locations) {
    if (location.branchId == branchId &&
        location.medicineId == medicineId &&
        !location.isEmpty) {
      return location;
    }
  }
  return null;
}
