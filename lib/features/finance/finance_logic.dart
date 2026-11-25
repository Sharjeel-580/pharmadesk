import '../../models/expense.dart';
import '../../models/supplier_ledger.dart';
import '../../models/supplier_payment.dart';

/// Week 2 Day 5 finance logic — pure functions over plain lists.
///
/// Payables / khata aging, supplier-payment allocation, and expense
/// validation. All money is int paisa. The same aging math serves
/// both ledgers: a supplier payable and a customer khata balance
/// are both a stream of signed entries (positive = owed more,
/// negative = paid), aged FIFO — oldest charge first.

/// One signed ledger entry, for the generic aging functions: the
/// entry's id, the date the charge was raised, and its signed
/// amount (positive = owed more, negative = paid / credited).
typedef SignedEntry = ({String id, DateTime date, int amountMinor});

/// Aging buckets for an outstanding balance (D92).
///
/// Boundaries (D92 — a documented demo rule; the SRS names the
/// buckets but not the day counts): Current = 0–30 days old,
/// 30 = 31–60, 60 = 61–90, 90+ = over 90 days.
enum AgingBucket { current, days30, days60, days90plus }

String agingBucketLabel(AgingBucket bucket) => switch (bucket) {
  AgingBucket.current => 'Current (0–30 days)',
  AgingBucket.days30 => '31–60 days',
  AgingBucket.days60 => '61–90 days',
  AgingBucket.days90plus => '90+ days',
};

AgingBucket agingBucketForAge(int ageDays) {
  if (ageDays <= 30) return AgingBucket.current;
  if (ageDays <= 60) return AgingBucket.days30;
  if (ageDays <= 90) return AgingBucket.days60;
  return AgingBucket.days90plus;
}

/// One charge with what is still outstanding on it after payments
/// have been applied oldest-first.
typedef OpenPayable = ({String id, DateTime date, int remainingMinor});

/// Applies payments (negative signed amounts) against charges
/// (positive signed amounts) oldest-first (FIFO) and returns what
/// is still outstanding per charge, oldest first.
///
/// [entries] are the ledger's signed entries in any order; the
/// function sorts charges by date. A payment larger than the total
/// charges leaves no negative remainder — the caller validates
/// against overpayment before recording (see
/// `validateSupplierLedgerEntry` / `validateLedgerEntry`); here the
/// excess is simply ignored, never turned into a negative payable.
List<OpenPayable> openPayableBalances(List<SignedEntry> entries) {
  final charges = entries
      .where((entry) => entry.amountMinor > 0)
      .toList()
    ..sort((a, b) => a.date.compareTo(b.date));
  var paid = entries
      .where((entry) => entry.amountMinor < 0)
      .fold(0, (sum, entry) => sum + (-entry.amountMinor));
  final open = <OpenPayable>[];
  for (final charge in charges) {
    final settled = paid >= charge.amountMinor
        ? charge.amountMinor
        : paid;
    paid -= settled;
    final remaining = charge.amountMinor - settled;
    if (remaining > 0) {
      open.add((
        id: charge.id,
        date: charge.date,
        remainingMinor: remaining,
      ));
    }
  }
  return open;
}

/// The aged outstanding balance: per-bucket totals plus the overall
/// outstanding.
class AgingSummary {
  const AgingSummary({required this.buckets, required this.totalMinor});

  /// Outstanding per bucket (every bucket present, zero when empty).
  final Map<AgingBucket, int> buckets;

  /// Total outstanding across all buckets (int paisa).
  final int totalMinor;

  int bucket(AgingBucket bucket) => buckets[bucket] ?? 0;
}

/// Ages an outstanding balance from a ledger's signed entries:
/// charges (positive) aged by their own date, payments (negative)
/// applied oldest-first. A charge's age is measured from its date
/// to [now] — an opening-balance purchase dated 28 days ago is
/// Current, not 90+.
AgingSummary computeAging({
  required List<SignedEntry> entries,
  required DateTime now,
}) {
  final today = DateTime(now.year, now.month, now.day);
  final buckets = <AgingBucket, int>{
    for (final bucket in AgingBucket.values) bucket: 0,
  };
  var total = 0;
  for (final open in openPayableBalances(entries)) {
    final chargeDay = DateTime(
      open.date.year,
      open.date.month,
      open.date.day,
    );
    final ageDays = today.difference(chargeDay).inDays;
    final bucket = agingBucketForAge(ageDays < 0 ? 0 : ageDays);
    buckets[bucket] = (buckets[bucket] ?? 0) + open.remainingMinor;
    total += open.remainingMinor;
  }
  return AgingSummary(buckets: buckets, totalMinor: total);
}

/// Signed supplier-ledger entries as generic [SignedEntry]s, for
/// the aging / allocation functions. Entries without a date sort as
/// today (they are never aged as old).
List<SignedEntry> supplierLedgerSignedEntries(
  List<SupplierLedgerEntry> entries,
) {
  return [
    for (final entry in entries)
      (
        id: entry.id,
        date: entry.createdAt ?? DateTime.now(),
        amountMinor: entry.amountMinor,
      ),
  ];
}

/// Allocates [paymentMinor] against [open] payables (oldest first,
/// from [openPayableBalances]) and returns the allocations. The
/// allocations sum to `paymentMinor` when the payment does not
/// exceed the total open — the caller validates that first, so an
/// overpayment here returns allocations that stop at the last open
/// payable and the caller must reject the payment (see
/// `validateSupplierPayment`).
List<PaymentAllocation> allocateSupplierPayment({
  required List<OpenPayable> open,
  required int paymentMinor,
}) {
  var remaining = paymentMinor;
  final allocations = <PaymentAllocation>[];
  for (final payable in open) {
    if (remaining <= 0) break;
    final amount = remaining >= payable.remainingMinor
        ? payable.remainingMinor
        : remaining;
    allocations.add(
      PaymentAllocation(ledgerEntryId: payable.id, amountMinor: amount),
    );
    remaining -= amount;
  }
  return allocations;
}

/// Validates a supplier payment before it is recorded: positive,
/// not above the outstanding payable, and allocated fully (the
/// allocations must sum to the payment — a shortfall means the
/// outstanding figure moved under the caller, so the payment is
/// refused rather than recorded half-allocated).
List<String> validateSupplierPayment({
  required int amountMinor,
  required int outstandingMinor,
  required List<PaymentAllocation> allocations,
}) {
  final errors = <String>[];
  if (amountMinor <= 0) {
    errors.add('Payment amount must be more than zero.');
  }
  if (amountMinor > outstandingMinor) {
    errors.add(
      'Payment cannot exceed the outstanding payable '
      '(${outstandingMinor ~/ 100} rupees).',
    );
  }
  final allocated = allocations.fold(
    0,
    (sum, allocation) => sum + allocation.amountMinor,
  );
  if (amountMinor > 0 && allocated != amountMinor) {
    errors.add(
      'Payment could not be fully allocated against open payables — '
      'please refresh and try again.',
    );
  }
  return errors;
}

/// Validates a new expense before saving. Returns the list of
/// problems (empty = valid). The category must be one of the fixed
/// [expenseCategories]; the amount is the UNSIGNED rupees the staff
/// typed, converted to paisa by the caller.
List<String> validateExpense({
  required String category,
  required int amountMinor,
  String description = '',
}) {
  final errors = <String>[];
  if (!expenseCategories.contains(category)) {
    errors.add('Pick an expense category.');
  }
  if (amountMinor <= 0) {
    errors.add('Expense amount must be more than zero.');
  }
  if (description.trim().length > 200) {
    errors.add('Description is too long (max 200 characters).');
  }
  return errors;
}

/// Supplier statement: the ledger entries oldest-first with the
/// running balance after each entry. The stored `balanceAfterMinor`
/// is the running balance (the repository computes it at insert);
/// this function only orders the entries — it never recomputes a
/// balance, so the statement shows exactly what was recorded.
List<SupplierLedgerEntry> supplierStatement(
  List<SupplierLedgerEntry> entries,
) {
  final sorted = entries.toList()
    ..sort((a, b) {
      final aTime = a.createdAt;
      final bTime = b.createdAt;
      if (aTime == null && bTime == null) return 0;
      if (aTime == null) return 1;
      if (bTime == null) return -1;
      return aTime.compareTo(bTime);
    });
  return sorted;
}

/// CSV export for a supplier statement (FR-REP-05 pattern, reused
/// from the Day 7 reports export util): one row per ledger entry
/// with the running balance.
String supplierStatementCsv(List<SupplierLedgerEntry> entries) {
  String escape(Object? value) {
    final text = value == null ? '' : value.toString();
    if (text.contains(',') || text.contains('"') || text.contains('\n')) {
      return '"${text.replaceAll('"', '""')}"';
    }
    return text;
  }

  String dateText(DateTime? date) => date == null
      ? ''
      : '${date.year}-${date.month.toString().padLeft(2, '0')}-'
            '${date.day.toString().padLeft(2, '0')}';
  final buffer = StringBuffer()
    ..writeln('Date,Type,Reason,Amount (Rs),Balance after (Rs)');
  for (final entry in supplierStatement(entries)) {
    buffer.writeln(
      [
        dateText(entry.createdAt),
        supplierLedgerEntryKindLabel(entry.kind),
        entry.reason,
        (entry.amountMinor / 100).toStringAsFixed(2),
        (entry.balanceAfterMinor / 100).toStringAsFixed(2),
      ].map(escape).join(','),
    );
  }
  return buffer.toString();
}
