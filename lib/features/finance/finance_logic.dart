import '../../models/closing_correction.dart';
import '../../models/daily_closing.dart';
import '../../models/expense.dart';
import '../../models/financial_transaction.dart';
import '../../models/sale.dart';
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
  final charges = entries.where((entry) => entry.amountMinor > 0).toList()
    ..sort((a, b) => a.date.compareTo(b.date));
  var paid = entries
      .where((entry) => entry.amountMinor < 0)
      .fold(0, (sum, entry) => sum + (-entry.amountMinor));
  final open = <OpenPayable>[];
  for (final charge in charges) {
    final settled = paid >= charge.amountMinor ? charge.amountMinor : paid;
    paid -= settled;
    final remaining = charge.amountMinor - settled;
    if (remaining > 0) {
      open.add((id: charge.id, date: charge.date, remainingMinor: remaining));
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
    final chargeDay = DateTime(open.date.year, open.date.month, open.date.day);
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
List<SupplierLedgerEntry> supplierStatement(List<SupplierLedgerEntry> entries) {
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

// --- Cashbook (Week 4 Day 3, D124–D126 — SRS D-24 / FR-FIN-01/02) ---

/// Fixed income categories for cashbook income entries (D125).
///
/// The mirror of the fixed [expenseCategories] list: the SRS names
/// income/expense categories but lists no income categories, so the
/// demo keeps a small fixed list (same rule as expenses — the
/// category NAME is the id). Sales income is NOT here: sales revenue
/// lives in the P&L, not in the cashbook — these are the non-sale
/// money-in lines (owner money, loans, refunds received).
const incomeCategories = <String>[
  'Owner contribution',
  'Loan received',
  'Refund received',
  'Other income',
];

/// One cashbook line: an expense record or an income transaction,
/// unified for the cashbook list. [amountMinor] is UNSIGNED (the
/// kind says which way the money moved); [note] is the expense
/// description, empty for income (see D125 — income transactions
/// carry no note field).
enum CashbookEntryKind { income, expense }

typedef CashbookEntry = ({
  String id,
  DateTime date,
  CashbookEntryKind kind,
  String category,
  int amountMinor,
  String note,
  String? referenceId,
});

/// Unifies the branch's expenses and income transactions into the
/// cashbook list, newest first. Expense entries come from the
/// `expenses` collection (their date is the expense date); income
/// entries come from `financialTransactions` of type `income` (their
/// date is the transaction date). Supplier/customer payments and
/// expense mirrors are NOT income — only type `income` counts, so a
/// recorded expense never appears twice (once as the expense, once
/// as its mirror transaction).
List<CashbookEntry> cashbookEntries({
  required List<Expense> expenses,
  required List<FinancialTransaction> transactions,
  String? branchId,
}) {
  final entries = <CashbookEntry>[
    for (final expense in expenses)
      if (branchId == null || expense.branchId == branchId)
        (
          id: expense.id,
          date: expense.expenseDate,
          kind: CashbookEntryKind.expense,
          category: expense.category,
          amountMinor: expense.amountMinor,
          note: expense.description,
          referenceId: null,
        ),
    for (final txn in transactions)
      if (txn.type == FinancialTransactionType.income &&
          (branchId == null || txn.branchId == branchId))
        (
          id: txn.id,
          date: txn.createdAt ?? DateTime.now(),
          kind: CashbookEntryKind.income,
          category: txn.category.isEmpty ? 'Other income' : txn.category,
          amountMinor: txn.amountMinor,
          note: '',
          referenceId: txn.referenceId,
        ),
  ];
  entries.sort((a, b) => b.date.compareTo(a.date));
  return entries;
}

/// Validates a new cashbook entry before saving: the category must
/// be on the fixed list for its kind, the amount is the UNSIGNED
/// whole rupees the staff typed (converted to paisa by the caller),
/// the date may not be in the future, and the note is capped at 200
/// characters (same cap as `validateExpense`).
List<String> validateCashbookEntry({
  required bool isIncome,
  required String category,
  required int amountMinor,
  required DateTime date,
  String note = '',
  DateTime? now,
}) {
  final errors = <String>[];
  final categories = isIncome ? incomeCategories : expenseCategories;
  if (!categories.contains(category)) {
    errors.add('Pick a ${isIncome ? 'income' : 'expense'} category.');
  }
  if (amountMinor <= 0) {
    errors.add('Amount must be more than zero.');
  }
  final today = now ?? DateTime.now();
  final entryDay = DateTime(date.year, date.month, date.day);
  final todayDay = DateTime(today.year, today.month, today.day);
  if (entryDay.isAfter(todayDay)) {
    errors.add('Entries cannot be dated in the future.');
  }
  if (note.trim().length > 200) {
    errors.add('Note is too long (max 200 characters).');
  }
  return errors;
}

/// Totals for one day's closing (D126).
class DailyClosingTotals {
  const DailyClosingTotals({
    required this.incomeMinor,
    required this.expenseMinor,
    required this.openingBalanceMinor,
    required this.closingBalanceMinor,
  });

  /// Money in that day (int paisa).
  final int incomeMinor;

  /// Money out that day (int paisa).
  final int expenseMinor;

  /// Balance carried into the day.
  final int openingBalanceMinor;

  /// `opening + income − expense`.
  final int closingBalanceMinor;
}

/// Computes a day's closing totals from the branch's cashbook
/// entries: only entries dated that day count, and the opening
/// balance is the previous closing's closing balance (0 when no
/// earlier closing exists).
DailyClosingTotals computeDailyClosing({
  required List<CashbookEntry> entries,
  required DateTime date,
  required int openingBalanceMinor,
}) {
  final day = DateTime(date.year, date.month, date.day);
  var income = 0;
  var expense = 0;
  for (final entry in entries) {
    final entryDay = DateTime(
      entry.date.year,
      entry.date.month,
      entry.date.day,
    );
    if (entryDay != day) continue;
    if (entry.kind == CashbookEntryKind.income) {
      income += entry.amountMinor;
    } else {
      expense += entry.amountMinor;
    }
  }
  return DailyClosingTotals(
    incomeMinor: income,
    expenseMinor: expense,
    openingBalanceMinor: openingBalanceMinor,
    closingBalanceMinor: openingBalanceMinor + income - expense,
  );
}

/// The opening balance for closing [date]: the latest closing
/// BEFORE that day for the branch, or 0 when no earlier closing
/// exists. A closing for the same day is not its own opening — the
/// caller rejects a duplicate close first (see
/// `validateDailyClosing`).
int previousClosingBalance({
  required List<DailyClosing> closings,
  required String branchId,
  required DateTime date,
}) {
  final day = DateTime(date.year, date.month, date.day);
  DailyClosing? latest;
  for (final closing in closings) {
    if (closing.branchId != branchId) continue;
    final closingDay = DateTime(
      closing.date.year,
      closing.date.month,
      closing.date.day,
    );
    if (!closingDay.isBefore(day)) continue;
    if (latest == null ||
        closingDay.isAfter(
          DateTime(latest.date.year, latest.date.month, latest.date.day),
        )) {
      latest = closing;
    }
  }
  return latest?.closingBalanceMinor ?? 0;
}

/// Validates closing a day: the day may not be in the future, and a
/// branch-day may be closed only once.
List<String> validateDailyClosing({
  required DateTime date,
  required List<DailyClosing> existing,
  required String branchId,
  DateTime? now,
}) {
  final errors = <String>[];
  final today = now ?? DateTime.now();
  final day = DateTime(date.year, date.month, date.day);
  final todayDay = DateTime(today.year, today.month, today.day);
  if (day.isAfter(todayDay)) {
    errors.add('A future day cannot be closed yet.');
  }
  final duplicate = existing.any(
    (closing) =>
        closing.branchId == branchId &&
        DateTime(closing.date.year, closing.date.month, closing.date.day) ==
            day,
  );
  if (duplicate) {
    errors.add('This day is already closed for this branch.');
  }
  return errors;
}

/// True when the cashbook entries for a closing's day no longer add
/// up to the totals the closing recorded — i.e. entries were added
/// (or backdated) after the close. The closing itself is never
/// rewritten; the screen shows this as "changed since closing".
bool dailyClosingIsStale({
  required DailyClosing closing,
  required List<CashbookEntry> entries,
}) {
  final totals = computeDailyClosing(
    entries: entries,
    date: closing.date,
    openingBalanceMinor: closing.openingBalanceMinor,
  );
  return totals.incomeMinor != closing.totalIncomeMinor ||
      totals.expenseMinor != closing.totalExpenseMinor;
}

// --- Closing corrections (Week 5 Day 4, D156 — SRS D-24 / FR-FIN-06) ---

/// Validates a closing correction before saving: the original
/// closing must exist, the corrected totals must be non-negative
/// (a day's money in / out cannot be below zero), and a reason is
/// required — the correction is an audit record, and a reason-less
/// correction explains nothing to the next reader.
List<String> validateClosingCorrection({
  required DailyClosing? original,
  required int correctedIncomeMinor,
  required int correctedExpenseMinor,
  required String reason,
}) {
  final errors = <String>[];
  if (original == null) {
    errors.add('The closing being corrected no longer exists.');
  }
  if (correctedIncomeMinor < 0) {
    errors.add('Corrected income cannot be negative.');
  }
  if (correctedExpenseMinor < 0) {
    errors.add('Corrected expense cannot be negative.');
  }
  if (reason.trim().isEmpty) {
    errors.add(
      'A reason is required — say what was wrong with the original closing.',
    );
  }
  return errors;
}

/// The figures a closing stands at after corrections (D156).
class AdjustedClosingTotals {
  const AdjustedClosingTotals({
    required this.incomeMinor,
    required this.expenseMinor,
    required this.closingBalanceMinor,
    required this.corrected,
    this.correctionId,
  });

  /// Money in that day (corrected when a correction exists).
  final int incomeMinor;

  /// Money out that day (corrected when a correction exists).
  final int expenseMinor;

  /// Closing balance (corrected when a correction exists).
  final int closingBalanceMinor;

  /// True when at least one correction applies to this closing.
  final bool corrected;

  /// The latest correction's id, or `null` when uncorrected.
  final String? correctionId;
}

/// The totals a closing stands at: the ORIGINAL totals when no
/// correction exists, the LATEST correction's totals when one or
/// more do (latest by `correctedAt`, ties broken by list order —
/// a correction re-states the day in full, so there is never a
/// chain to sum). The original record is never rewritten; this is
/// the read side of the reversing-entry flow.
AdjustedClosingTotals adjustedClosingTotals({
  required DailyClosing original,
  required List<ClosingCorrection> corrections,
}) {
  ClosingCorrection? latest;
  for (final correction in corrections) {
    if (correction.originalClosingId != original.id) continue;
    if (latest == null) {
      latest = correction;
      continue;
    }
    final latestAt = latest.correctedAt;
    final thisAt = correction.correctedAt;
    if (thisAt != null && (latestAt == null || !thisAt.isBefore(latestAt))) {
      latest = correction;
    }
  }
  if (latest == null) {
    return AdjustedClosingTotals(
      incomeMinor: original.totalIncomeMinor,
      expenseMinor: original.totalExpenseMinor,
      closingBalanceMinor: original.closingBalanceMinor,
      corrected: false,
    );
  }
  return AdjustedClosingTotals(
    incomeMinor: latest.correctedIncomeMinor,
    expenseMinor: latest.correctedExpenseMinor,
    closingBalanceMinor: latest.correctedClosingBalanceMinor,
    corrected: true,
    correctionId: latest.id,
  );
}

// --- Cash reconciliation (Week 5 Day 4, D157 — SRS D-24 / FR-FIN-02) ---

/// Expected cash in the drawer at the end of [date] (D157, int
/// paisa):
///
/// `opening + cash sales + cashbook income − cashbook expenses`
///
/// - **Opening** is the previous closing's closing balance (the
///   cash the drawer started the day with).
/// - **Cash sales** are the cash legs of the day's sales
///   ([Sale.cashMinor] — every sale carries legs, D137, so a
///   single-method cash sale counts in full and a split sale counts
///   its cash leg only; card and credit legs never touch the drawer).
/// - **Cashbook income / expenses** are the day's cashbook entries
///   (cash in / cash out).
///
/// Deliberately NOT in the figure: card/credit sales (no cash
/// moves), supplier payments (they are not cashbook entries — a
/// cash supplier payment is recorded against the payable, not the
/// drawer; see the Day 4 follow-up), and sale-return refunds (no
/// cash refund is modelled yet). The reconciliation compares the
/// drawer against the cash the app knows about; anything outside
/// that scope shows up as a difference to investigate, not as a
/// silently adjusted expectation.
int expectedDrawerMinor({
  required List<Sale> sales,
  required List<CashbookEntry> entries,
  required int openingBalanceMinor,
  required DateTime date,
}) {
  final day = DateTime(date.year, date.month, date.day);
  var expected = openingBalanceMinor;
  for (final sale in sales) {
    final created = sale.createdAt;
    if (created == null) continue;
    if (DateTime(created.year, created.month, created.day) != day) {
      continue;
    }
    expected += sale.cashMinor;
  }
  for (final entry in entries) {
    final entryDay = DateTime(
      entry.date.year,
      entry.date.month,
      entry.date.day,
    );
    if (entryDay != day) continue;
    if (entry.kind == CashbookEntryKind.income) {
      expected += entry.amountMinor;
    } else {
      expected -= entry.amountMinor;
    }
  }
  return expected;
}

/// The drawer difference for a count: actual − expected (int
/// paisa). Positive = cash over, negative = cash short, 0 = exact.
int cashReconciliationDifference({
  required int expectedMinor,
  required int countedMinor,
}) => countedMinor - expectedMinor;

/// Validates recording a cash count: the counted amount cannot be
/// negative, and a future day cannot be reconciled yet.
List<String> validateCashReconciliation({
  required int countedMinor,
  required DateTime date,
  DateTime? now,
}) {
  final errors = <String>[];
  if (countedMinor < 0) {
    errors.add('Counted cash cannot be negative.');
  }
  final today = now ?? DateTime.now();
  final day = DateTime(date.year, date.month, date.day);
  final todayDay = DateTime(today.year, today.month, today.day);
  if (day.isAfter(todayDay)) {
    errors.add('A future day cannot be reconciled yet.');
  }
  return errors;
}
