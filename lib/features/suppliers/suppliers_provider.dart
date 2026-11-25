import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/repositories.dart';
import '../../models/supplier.dart';
import '../../models/supplier_ledger.dart';
import 'supplier_logic.dart';

/// Day 7 supplier state.
///
/// [SupplierDirectoryNotifier] owns the in-memory supplier list:
/// it loads from the (mock) repository once, and adding/editing a
/// supplier writes through to the repository and refreshes, so the new
/// supplier appears in the directory and in the PO form immediately.
///
/// [SupplierLedgerNotifier] owns one supplier's payables ledger:
/// every entry (purchase / payment / return / adjustment) writes
/// through to the repository and refreshes. The outstanding payable
/// is always computed from the entries — never stored separately
/// (see `supplier_logic.dart`).

class SupplierDirectoryNotifier extends AsyncNotifier<List<Supplier>> {
  @override
  Future<List<Supplier>> build() async {
    final repo = ref.read(supplierRepositoryProvider);
    return repo.getSuppliers();
  }

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(
      () => ref.read(supplierRepositoryProvider).getSuppliers(),
    );
  }

  /// Adds a supplier after validation. Returns the saved supplier, or
  /// `null` supplier + an error message when validation or the
  /// repository (duplicate phone) rejects it.
  Future<({Supplier? supplier, String? error})> addSupplier({
    required String name,
    required String contactPerson,
    required String phone,
    String email = '',
    String address = '',
    String taxNumber = '',
    String paymentTerms = '',
  }) async {
    final existing = state.asData?.value ?? const <Supplier>[];
    final errors = validateNewSupplier(
      name: name,
      contactPerson: contactPerson,
      phone: phone,
      existingPhones: existing.map((s) => s.phone).toList(),
    );
    if (errors.isNotEmpty) {
      return (supplier: null, error: errors.first);
    }
    try {
      final created = await ref
          .read(supplierRepositoryProvider)
          .createSupplier(
            Supplier(
              id: '',
              name: name.trim(),
              contactPerson: contactPerson.trim(),
              phone: phone.trim(),
              email: email.trim().isEmpty ? null : email.trim(),
              address: address.trim().isEmpty ? null : address.trim(),
              taxNumber: taxNumber.trim().isEmpty ? null : taxNumber.trim(),
              paymentTerms: paymentTerms.trim().isEmpty
                  ? null
                  : paymentTerms.trim(),
            ),
          );
      await refresh();
      return (supplier: created, error: null);
    } on ArgumentError catch (error) {
      return (supplier: null, error: error.message?.toString());
    }
  }

  /// Saves an edited supplier (contact details only — the ledger is
  /// append-only and is never edited). Returns `false` when the
  /// supplier is not in the directory.
  Future<bool> updateSupplier(Supplier supplier) async {
    final existing = state.asData?.value ?? const <Supplier>[];
    if (!existing.any((s) => s.id == supplier.id)) return false;
    await ref.read(supplierRepositoryProvider).updateSupplier(supplier);
    await refresh();
    return true;
  }
}

final suppliersProvider =
    AsyncNotifierProvider<SupplierDirectoryNotifier, List<Supplier>>(
      SupplierDirectoryNotifier.new,
    );

/// One supplier by id, from the directory (refreshes when it does).
final supplierByIdProvider = Provider.family<Supplier?, String>((ref, id) {
  final suppliers = ref.watch(suppliersProvider).asData?.value ?? const [];
  for (final supplier in suppliers) {
    if (supplier.id == id) return supplier;
  }
  return null;
});

class SupplierLedgerNotifier extends AsyncNotifier<List<SupplierLedgerEntry>> {
  /// Riverpod 3 family notifiers take their argument as a constructor
  /// parameter (there is no `arg` getter).
  SupplierLedgerNotifier(this.supplierId);

  /// The supplier this notifier's ledger belongs to.
  final String supplierId;

  @override
  Future<List<SupplierLedgerEntry>> build() async {
    final repo = ref.read(supplierRepositoryProvider);
    return repo.getLedgerEntries(supplierId);
  }

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(
      () =>
          ref.read(supplierRepositoryProvider).getLedgerEntries(supplierId),
    );
  }

  /// Records one ledger entry. [amountMinor] is the UNSIGNED amount
  /// the staff typed (int paisa); the sign comes from [kind] (+
  /// [isIncrease] for adjustments). Returns the saved entry, or
  /// `null` entry + an error message when validation rejects it
  /// (e.g. a payment larger than the outstanding payable).
  Future<({SupplierLedgerEntry? entry, String? error})> recordEntry({
    required SupplierLedgerEntryKind kind,
    required int amountMinor,
    String reason = '',
    bool isIncrease = true,
    String? referenceId,
  }) async {
    final entries = state.asData?.value ?? const <SupplierLedgerEntry>[];
    final outstanding = supplierOutstandingMinor(entries);
    final errors = validateSupplierLedgerEntry(
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
          .read(supplierRepositoryProvider)
          .addLedgerEntry(
            SupplierLedgerEntry(
              id: '',
              supplierId: supplierId,
              kind: kind,
              amountMinor: signedSupplierLedgerAmount(
                kind: kind,
                amountMinor: amountMinor,
                isIncrease: isIncrease,
              ),
              reason: reason.trim().isEmpty && kind == SupplierLedgerEntryKind.payment
                  ? 'Payment made'
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

final supplierLedgerProvider = AsyncNotifierProvider.family<
  SupplierLedgerNotifier,
  List<SupplierLedgerEntry>,
  String
>(SupplierLedgerNotifier.new);

/// Outstanding payable for one supplier, in int paisa — computed
/// from the ledger, never stored.
final supplierOutstandingProvider = Provider.family<int, String>((
  ref,
  supplierId,
) {
  final entries =
      ref.watch(supplierLedgerProvider(supplierId)).asData?.value ?? const [];
  return supplierOutstandingMinor(entries);
});
