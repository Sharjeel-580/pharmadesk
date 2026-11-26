import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/data/permission_service.dart';
import '../../core/data/production_data_layer.dart';
import '../../core/services/repositories.dart';
import '../../core/widgets/sync_status_widget.dart';
import '../../models/daily_closing.dart';
import '../../models/expense.dart';
import '../../models/financial_transaction.dart';
import '../../models/supplier_ledger.dart';
import '../../models/supplier_payment.dart';
import '../authentication/auth_state.dart';
import '../customers/customers_provider.dart';
import '../reports/analytics_logic.dart';
import '../reports/reports_provider.dart';
import '../suppliers/suppliers_provider.dart';
import 'finance_logic.dart';

/// Week 2 Day 5 finance state.
///
/// [ExpensesNotifier] owns the operating expenses: recording one
/// also writes the matching `financialTransactions` entry of type
/// `expense` (negative amount), so the P&L and the transaction feed
/// never diverge. [SupplierPaymentsNotifier] owns supplier
/// payments: recording one allocates it against the open payables
/// (oldest first), writes the payment record, the matching negative
/// supplier-ledger entry, and the matching `financialTransactions`
/// entry of type `supplierPayment` — one payment, three records,
/// all written by the same call.
///
/// Writes are gated on the SRS §5.1 matrix: expenses need
/// `financeEntry`, supplier payments need `supplierPay` (Owner /
/// HO Admin / Accountant only — a Branch Manager may NOT pay a
/// supplier, D89). A denied caller gets an error string, not a
/// silent no-op.

class ExpensesNotifier extends AsyncNotifier<List<Expense>> {
  @override
  Future<List<Expense>> build() async {
    final repo = ref.read(expenseRepositoryProvider);
    return repo.getExpenses();
  }

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(
      () => ref.read(expenseRepositoryProvider).getExpenses(),
    );
  }

  /// Records an expense (amount in int paisa, unsigned) plus its
  /// financial-transaction mirror. Writes through the production
  /// data layer (Week 4 Day 5, D145 — closes D129): the layer
  /// creates the expense + mirror and enqueues one sync payload, so
  /// the sync-status chip moves for cashbook work. Returns the saved
  /// expense, or `null` + an error message.
  Future<({Expense? expense, String? error})> recordExpense({
    required String branchId,
    required String category,
    required int amountMinor,
    String description = '',
    required DateTime expenseDate,
  }) async {
    final user = ref.read(authProvider);
    if (!permissionService.canWrite(user, 'financeEntry', branchId)) {
      return (expense: null, error: 'You do not have permission to record expenses in this branch (SRS §5.1: finance entry).');
    }
    final errors = validateExpense(
      category: category,
      amountMinor: amountMinor,
      description: description,
    );
    if (errors.isNotEmpty) {
      return (expense: null, error: errors.first);
    }
    final created = await ref
        .read(productionDataLayerProvider)
        .recordExpense(
          branchId: branchId,
          category: category,
          amountMinor: amountMinor,
          description: description,
          expenseDate: expenseDate,
          createdBy: user?.uid,
        );
    await refresh();
    ref.invalidate(financialTransactionsProvider);
    ref.invalidate(advancedReportDataProvider);
    ref.invalidate(syncStatusProvider);
    return (expense: created, error: null);
  }
}

final expensesProvider =
    AsyncNotifierProvider<ExpensesNotifier, List<Expense>>(
      ExpensesNotifier.new,
    );

class FinancialTransactionsNotifier
    extends AsyncNotifier<List<FinancialTransaction>> {
  @override
  Future<List<FinancialTransaction>> build() async {
    final repo = ref.read(financialTransactionRepositoryProvider);
    return repo.getTransactions();
  }

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(
      () => ref.read(financialTransactionRepositoryProvider).getTransactions(),
    );
  }

  /// Records a cashbook income entry (Week 4 Day 3, D125): a
  /// `financialTransactions` entry of type `income` with a positive
  /// amount. Gated on `financeEntry` write like an expense — an
  /// income entry is a finance entry per the SRS §5.1 matrix. The
  /// entry date is the transaction's business date (a backdated
  /// entry lands in its own day's cashbook and P&L window — the
  /// repositories keep a caller-supplied `createdAt`, D125).
  /// Writes through the production data layer (Week 4 Day 5, D145
  /// — closes D129): one sync payload is enqueued, so the
  /// sync-status chip moves for cashbook work.
  /// Returns the saved transaction, or `null` + an error message.
  Future<({FinancialTransaction? transaction, String? error})> recordIncome({
    required String branchId,
    required String category,
    required int amountMinor,
    required DateTime date,
  }) async {
    final user = ref.read(authProvider);
    if (!permissionService.canWrite(user, 'financeEntry', branchId)) {
      return (transaction: null, error: 'You do not have permission to record income in this branch (SRS §5.1: finance entry).');
    }
    final errors = validateCashbookEntry(
      isIncome: true,
      category: category,
      amountMinor: amountMinor,
      date: date,
    );
    if (errors.isNotEmpty) {
      return (transaction: null, error: errors.first);
    }
    final created = await ref
        .read(productionDataLayerProvider)
        .recordIncome(
          branchId: branchId,
          category: category,
          amountMinor: amountMinor,
          date: date,
          createdBy: user?.uid,
        );
    await refresh();
    ref.invalidate(advancedReportDataProvider);
    ref.invalidate(syncStatusProvider);
    return (transaction: created, error: null);
  }
}

final financialTransactionsProvider =
    AsyncNotifierProvider<
      FinancialTransactionsNotifier,
      List<FinancialTransaction>
    >(FinancialTransactionsNotifier.new);

class SupplierPaymentsNotifier extends AsyncNotifier<List<SupplierPayment>> {
  @override
  Future<List<SupplierPayment>> build() async {
    final repo = ref.read(supplierPaymentRepositoryProvider);
    return repo.getPayments();
  }

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(
      () => ref.read(supplierPaymentRepositoryProvider).getPayments(),
    );
  }

  /// Records a supplier payment (amount in int paisa, unsigned):
  /// allocates it against the open payables oldest-first, saves
  /// the payment record, the supplier-ledger payment entry and the
  /// financial-transaction entry. Returns the saved payment, or
  /// `null` + an error message (no permission, overpayment, or an
  /// allocation shortfall).
  Future<({SupplierPayment? payment, String? error})> recordPayment({
    required String supplierId,
    required String branchId,
    required int amountMinor,
    SupplierPaymentMethod method = SupplierPaymentMethod.cash,
    String reference = '',
    String reason = '',
  }) async {
    final user = ref.read(authProvider);
    if (!permissionService.canWrite(user, 'supplierPay', branchId)) {
      return (payment: null, error: 'Only the Owner, HO Admin or Accountant may pay a supplier (SRS §5.1: supplier payment).');
    }
    final ledger = await ref
        .read(supplierRepositoryProvider)
        .getLedgerEntries(supplierId);
    final open = openPayableBalances(supplierLedgerSignedEntries(ledger));
    final outstanding = open.fold(
      0,
      (sum, payable) => sum + payable.remainingMinor,
    );
    final allocations = allocateSupplierPayment(
      open: open,
      paymentMinor: amountMinor,
    );
    final errors = validateSupplierPayment(
      amountMinor: amountMinor,
      outstandingMinor: outstanding,
      allocations: allocations,
    );
    if (errors.isNotEmpty) {
      return (payment: null, error: errors.first);
    }
    final methodLabel = supplierPaymentMethodLabel(method);
    final created = await ref
        .read(supplierPaymentRepositoryProvider)
        .createPayment(
          SupplierPayment(
            id: '',
            branchId: branchId,
            supplierId: supplierId,
            amountMinor: amountMinor,
            method: method,
            reference: reference.trim(),
            paidBy: user?.uid,
            paidAt: DateTime.now(),
            allocations: allocations,
          ),
        );
    final ledgerReason = reason.trim().isEmpty
        ? 'Payment made — $methodLabel'
              '${reference.trim().isEmpty ? '' : ' (${reference.trim()})'}'
        : reason.trim();
    await ref.read(supplierRepositoryProvider).addLedgerEntry(
      SupplierLedgerEntry(
        id: '',
        supplierId: supplierId,
        kind: SupplierLedgerEntryKind.payment,
        amountMinor: -amountMinor,
        reason: ledgerReason,
        referenceId: created.id,
        balanceAfterMinor: 0, // set by the repository
        createdAt: DateTime.now(),
      ),
    );
    await ref
        .read(financialTransactionRepositoryProvider)
        .addTransaction(
          FinancialTransaction(
            id: '',
            branchId: branchId,
            type: FinancialTransactionType.supplierPayment,
            amountMinor: -amountMinor,
            category: 'Supplier payment',
            referenceType: 'supplierPayment',
            referenceId: created.id,
            createdBy: user?.uid,
            createdAt: DateTime.now(),
          ),
        );
    await refresh();
    ref.invalidate(supplierLedgerProvider(supplierId));
    ref.invalidate(supplierOutstandingProvider(supplierId));
    ref.invalidate(financialTransactionsProvider);
    ref.invalidate(advancedReportDataProvider);
    return (payment: created, error: null);
  }
}

final supplierPaymentsProvider =
    AsyncNotifierProvider<SupplierPaymentsNotifier, List<SupplierPayment>>(
      SupplierPaymentsNotifier.new,
    );

/// Payments made to one supplier, newest first.
final supplierPaymentsForSupplierProvider =
    Provider.family<List<SupplierPayment>, String>((ref, supplierId) {
      final payments =
          ref.watch(supplierPaymentsProvider).asData?.value ?? const [];
      final scoped = payments
          .where((payment) => payment.supplierId == supplierId)
          .toList();
      scoped.sort((a, b) {
        final aTime = a.paidAt;
        final bTime = b.paidAt;
        return bTime.compareTo(aTime);
      });
      return scoped;
    });

/// Payable aging for one supplier (current / 30 / 60 / 90+ days),
/// computed from the supplier's ledger with payments applied
/// oldest-first.
final supplierAgingProvider = Provider.family<AgingSummary, String>((
  ref,
  supplierId,
) {
  final entries =
      ref.watch(supplierLedgerProvider(supplierId)).asData?.value ?? const [];
  return computeAging(
    entries: supplierLedgerSignedEntries(entries),
    now: DateTime.now(),
  );
});

/// Khata aging for one customer (same buckets as the supplier
/// payables), computed from the customer's ledger with payments
/// applied oldest-first.
final customerAgingProvider = Provider.family<AgingSummary, String>((
  ref,
  customerId,
) {
  final entries =
      ref.watch(ledgerProvider(customerId)).asData?.value ?? const [];
  return computeAging(
    entries: [
      for (final entry in entries)
        (
          id: entry.id,
          date: entry.createdAt ?? DateTime.now(),
          amountMinor: entry.amountMinor,
        ),
    ],
    now: DateTime.now(),
  );
});

/// Daily cashbook closings (Week 4 Day 3, D126 — SRS D-24).
///
/// [DailyClosingsNotifier] owns the closing records: closing a day
/// snapshots that day's cashbook totals (computed from the live
/// entries at close time) with the opening balance carried from the
/// previous closing. Writes are gated on `financeEntry` (same as
/// recording an entry — closing is a finance-entry action); a denied
/// caller gets an error string, not a silent no-op.
class DailyClosingsNotifier extends AsyncNotifier<List<DailyClosing>> {
  @override
  Future<List<DailyClosing>> build() async {
    final repo = ref.read(dailyClosingRepositoryProvider);
    return repo.getClosings();
  }

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(
      () => ref.read(dailyClosingRepositoryProvider).getClosings(),
    );
  }

  /// Closes [date] for [branchId]: totals are computed from the
  /// branch's live cashbook entries (read fresh from the
  /// repositories, not from the screen's possibly stale list), the
  /// opening balance comes from the previous closing, and the record
  /// is saved. Returns the saved closing, or `null` + an error
  /// message (no permission, future day, or already closed).
  Future<({DailyClosing? closing, String? error})> closeDay({
    required String branchId,
    required DateTime date,
    String note = '',
  }) async {
    final user = ref.read(authProvider);
    if (!permissionService.canWrite(user, 'financeEntry', branchId)) {
      return (closing: null, error: 'You do not have permission to close a day in this branch (SRS §5.1: finance entry).');
    }
    final day = DateTime(date.year, date.month, date.day);
    final existing = state.asData?.value ?? const <DailyClosing>[];
    final errors = validateDailyClosing(
      date: day,
      existing: existing,
      branchId: branchId,
    );
    if (errors.isNotEmpty) {
      return (closing: null, error: errors.first);
    }
    final expenses = await ref
        .read(expenseRepositoryProvider)
        .getExpenses(branchId: branchId);
    final transactions = await ref
        .read(financialTransactionRepositoryProvider)
        .getTransactions(branchId: branchId);
    final entries = cashbookEntries(
      expenses: expenses,
      transactions: transactions,
      branchId: branchId,
    );
    final opening = previousClosingBalance(
      closings: existing,
      branchId: branchId,
      date: day,
    );
    final totals = computeDailyClosing(
      entries: entries,
      date: day,
      openingBalanceMinor: opening,
    );
    final created = await ref
        .read(productionDataLayerProvider)
        .recordDailyClosing(
          closing: DailyClosing(
            id: '',
            branchId: branchId,
            date: day,
            totalIncomeMinor: totals.incomeMinor,
            totalExpenseMinor: totals.expenseMinor,
            openingBalanceMinor: totals.openingBalanceMinor,
            closingBalanceMinor: totals.closingBalanceMinor,
            closedBy: user?.uid,
            closedAt: DateTime.now(),
            note: note.trim(),
          ),
        );
    await refresh();
    ref.invalidate(syncStatusProvider);
    return (closing: created, error: null);
  }
}

final dailyClosingsProvider =
    AsyncNotifierProvider<DailyClosingsNotifier, List<DailyClosing>>(
      DailyClosingsNotifier.new,
    );

/// The cashbook list for a branch (`null` = all branches): expenses
/// + income transactions unified, newest first (D124). The screen
/// filters this by date; the notifier reads it fresh for closing.
final cashbookEntriesProvider =
    Provider.family<List<CashbookEntry>, String?>((ref, branchId) {
      final expenses =
          ref.watch(expensesProvider).asData?.value ?? const [];
      final transactions =
          ref.watch(financialTransactionsProvider).asData?.value ?? const [];
      return cashbookEntries(
        expenses: expenses,
        transactions: transactions,
        branchId: branchId,
      );
    });

/// One branch's P&L statement (Week 4 Day 3, D128 — SRS D-26).
///
/// This is NOT a second P&L computation: it reads the exact
/// [AdvancedReportData] the Reports hub reads for the same
/// (branch, window) and returns its `profitLoss`. The finance
/// statements screen and the Reports hub can therefore never
/// disagree for the same window/branch — the agreement is pinned by
/// the Day 3 test. `branchId == null` is the consolidated (all
/// branches) statement.
final branchStatementProvider =
    FutureProvider.family<ProfitLoss, (String?, int)>((ref, args) async {
      final (branchId, days) = args;
      final data = await ref.watch(
        advancedReportDataProvider((branchId, days)).future,
      );
      return data.profitLoss;
    });

/// Payables aging for every supplier (D127): supplier id →
/// [AgingSummary] from the D92 ledger computation. Parties with a
/// zero outstanding are included with a zero summary — the screen
/// filters them out of the list and counts them as settled.
final allPayablesAgingProvider = Provider<Map<String, AgingSummary>>((
  ref,
) {
  final suppliers = ref.watch(suppliersProvider).asData?.value ?? const [];
  return {
    for (final supplier in suppliers)
      supplier.id: ref.watch(supplierAgingProvider(supplier.id)),
  };
});

/// Receivables aging for every customer (D127): customer id →
/// [AgingSummary] from the same D92 computation over the khata
/// ledger.
final allReceivablesAgingProvider = Provider<Map<String, AgingSummary>>((
  ref,
) {
  final customers = ref.watch(customersProvider).asData?.value ?? const [];
  return {
    for (final customer in customers)
      customer.id: ref.watch(customerAgingProvider(customer.id)),
  };
});
