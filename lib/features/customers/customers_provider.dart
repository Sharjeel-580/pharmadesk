import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/repositories.dart';
import '../../models/customer.dart';
import '../../models/customer_ledger.dart';
import 'customer_logic.dart';

/// Day 6 customer state.
///
/// [CustomerDirectoryNotifier] owns the in-memory customer list:
/// it loads from the (mock) repository once, and adding a customer
/// writes through to the repository and refreshes, so the new
/// customer appears in the directory and in the POS picker
/// immediately.
///
/// [LedgerNotifier] owns one customer's khata: it loads the ledger
/// entries once and every entry (payment / credit / adjustment)
/// writes through to the repository and refreshes. The outstanding
/// balance is always computed from the entries — never stored
/// separately (see `customer_logic.dart`).

class CustomerDirectoryNotifier extends AsyncNotifier<List<Customer>> {
  @override
  Future<List<Customer>> build() async {
    final repo = ref.read(customerRepositoryProvider);
    return repo.getCustomers();
  }

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(
      () => ref.read(customerRepositoryProvider).getCustomers(),
    );
  }

  /// Adds a customer after validation. Returns the saved customer, or
  /// `null` customer + an error message when validation or the
  /// repository (duplicate phone) rejects it.
  Future<({Customer? customer, String? error})> addCustomer({
    required String name,
    required String phone,
    String address = '',
    String city = 'Lahore',
  }) async {
    final existing = state.asData?.value ?? const <Customer>[];
    final errors = validateNewCustomer(
      name: name,
      phone: phone,
      existingPhones: existing.map((c) => c.phone).toList(),
    );
    if (errors.isNotEmpty) {
      return (customer: null, error: errors.first);
    }
    try {
      final created = await ref
          .read(customerRepositoryProvider)
          .createCustomer(
            Customer(
              id: '',
              name: name.trim(),
              phone: phone.trim(),
              addresses: address.trim().isEmpty
                  ? const []
                  : [
                      CustomerAddress(
                        label: 'Home',
                        address: address.trim(),
                        city: city.trim().isEmpty ? 'Lahore' : city.trim(),
                        isDefault: true,
                      ),
                    ],
            ),
          );
      await refresh();
      return (customer: created, error: null);
    } on ArgumentError catch (error) {
      return (customer: null, error: error.message?.toString());
    }
  }
}

final customersProvider =
    AsyncNotifierProvider<CustomerDirectoryNotifier, List<Customer>>(
      CustomerDirectoryNotifier.new,
    );

/// One customer by id, from the directory (refreshes when it does).
final customerByIdProvider = Provider.family<Customer?, String>((ref, id) {
  final customers = ref.watch(customersProvider).asData?.value ?? const [];
  for (final customer in customers) {
    if (customer.id == id) return customer;
  }
  return null;
});

class LedgerNotifier extends AsyncNotifier<List<LedgerEntry>> {
  /// Riverpod 3 family notifiers take their argument as a constructor
  /// parameter (there is no `arg` getter).
  LedgerNotifier(this.customerId);

  /// The customer this notifier's ledger belongs to.
  final String customerId;

  @override
  Future<List<LedgerEntry>> build() async {
    final repo = ref.read(customerRepositoryProvider);
    return repo.getLedgerEntries(customerId);
  }

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(
      () => ref.read(customerRepositoryProvider).getLedgerEntries(customerId),
    );
  }

  /// Records one khata entry. [amountMinor] is the UNSIGNED amount
  /// the staff typed (int paisa); the sign comes from [kind] (+
  /// [isIncrease] for adjustments). Returns the saved entry, or
  /// `null` entry + an error message when validation rejects it
  /// (e.g. a payment larger than the outstanding balance).
  Future<({LedgerEntry? entry, String? error})> recordEntry({
    required LedgerEntryKind kind,
    required int amountMinor,
    String reason = '',
    bool isIncrease = true,
    String? referenceId,
  }) async {
    final entries = state.asData?.value ?? const <LedgerEntry>[];
    final outstanding = outstandingMinor(entries);
    final errors = validateLedgerEntry(
      kind: kind,
      amountMinor: amountMinor,
      reason: reason,
      outstandingMinor: outstanding,
    );
    if (errors.isNotEmpty) {
      return (entry: null, error: errors.first);
    }
    try {
      final created = await ref
          .read(customerRepositoryProvider)
          .addLedgerEntry(
            LedgerEntry(
              id: '',
              customerId: customerId,
              kind: kind,
              amountMinor: signedLedgerAmount(
                kind: kind,
                amountMinor: amountMinor,
                isIncrease: isIncrease,
              ),
              reason: reason.trim().isEmpty && kind == LedgerEntryKind.payment
                  ? 'Payment received'
                  : reason.trim(),
              referenceId: referenceId,
              balanceAfterMinor: 0, // set by the repository
              createdAt: DateTime.now(),
            ),
          );
      await refresh();
      return (entry: created, error: null);
    } on ArgumentError catch (error) {
      return (entry: null, error: error.message?.toString());
    }
  }
}

final ledgerProvider = AsyncNotifierProvider.family<
  LedgerNotifier,
  List<LedgerEntry>,
  String
>(LedgerNotifier.new);

/// Outstanding khata balance for one customer, in int paisa —
/// computed from the ledger, never stored.
final outstandingProvider = Provider.family<int, String>((ref, customerId) {
  final entries = ref.watch(ledgerProvider(customerId)).asData?.value ?? const [];
  return outstandingMinor(entries);
});
