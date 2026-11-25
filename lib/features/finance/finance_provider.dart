import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/data/permission_service.dart';
import '../../core/services/repositories.dart';
import '../../models/expense.dart';
import '../../models/financial_transaction.dart';
import '../../models/supplier_ledger.dart';
import '../../models/supplier_payment.dart';
import '../authentication/auth_state.dart';
import '../customers/customers_provider.dart';
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
  /// financial-transaction mirror. Returns the saved expense, or
  /// `null` + an error message.
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
    final created = await ref.read(expenseRepositoryProvider).createExpense(
      Expense(
        id: '',
        branchId: branchId,
        category: category,
        amountMinor: amountMinor,
        description: description.trim(),
        expenseDate: expenseDate,
        createdBy: user?.uid,
      ),
    );
    await ref
        .read(financialTransactionRepositoryProvider)
        .addTransaction(
          FinancialTransaction(
            id: '',
            branchId: branchId,
            type: FinancialTransactionType.expense,
            amountMinor: -amountMinor,
            category: category,
            referenceType: 'expense',
            referenceId: created.id,
            createdBy: user?.uid,
            createdAt: DateTime.now(),
          ),
        );
    await refresh();
    ref.invalidate(financialTransactionsProvider);
    ref.invalidate(advancedReportDataProvider);
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
