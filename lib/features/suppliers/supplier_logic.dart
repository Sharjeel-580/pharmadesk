import '../../models/supplier.dart';
import '../../models/supplier_ledger.dart';
import '../customers/customer_logic.dart' show normalizePhoneDigits;

/// Day 7 supplier logic — pure functions over plain lists, mirroring
/// the customer khata pattern (D37).
///
/// Supplier payables: ledger amounts are signed int paisa (positive =
/// the pharmacy owes the supplier more, negative = paid). The
/// outstanding balance is always the SUM of the entries — never a
/// stored field that can drift.

/// Outstanding payable in int minor units (paisa): the sum of the
/// ledger's signed amounts. Zero when the ledger is empty or settled.
int supplierOutstandingMinor(Iterable<SupplierLedgerEntry> entries) =>
    entries.fold(0, (sum, entry) => sum + entry.amountMinor);

/// Searches the supplier directory by name, contact person or phone.
///
/// - Name/contact matches are case-insensitive substrings.
/// - Phone matches compare digits only.
/// - An empty query returns the whole directory.
List<Supplier> searchSuppliers(
  List<Supplier> suppliers, {
  String query = '',
}) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return suppliers.toList();
  final queryDigits = normalizePhoneDigits(query);
  return suppliers.where((supplier) {
    if (supplier.name.toLowerCase().contains(needle)) return true;
    if (supplier.contactPerson.toLowerCase().contains(needle)) {
      return true;
    }
    if (queryDigits.isEmpty) return false;
    return normalizePhoneDigits(supplier.phone).contains(queryDigits);
  }).toList();
}

/// Validates a new supplier before saving. Returns the list of
/// problems (empty = valid). [existingPhones] are the directory's
/// phones — a duplicate number (digits compared) is rejected.
List<String> validateNewSupplier({
  required String name,
  required String contactPerson,
  required String phone,
  List<String> existingPhones = const [],
}) {
  final errors = <String>[];
  if (name.trim().isEmpty) {
    errors.add('Supplier name is required.');
  }
  if (contactPerson.trim().isEmpty) {
    errors.add('Contact person is required.');
  }
  final digits = normalizePhoneDigits(phone);
  if (digits.isEmpty) {
    errors.add('Phone number is required.');
  } else if (digits.length < 10) {
    errors.add('Phone number looks too short (need at least 10 digits).');
  }
  if (digits.isNotEmpty &&
      existingPhones.any(
        (existing) => normalizePhoneDigits(existing) == digits,
      )) {
    errors.add('A supplier with this phone number already exists.');
  }
  return errors;
}

/// Validates a supplier ledger entry before it is recorded.
///
/// - [amountMinor] is the UNSIGNED amount the staff typed (whole
///   rupees converted to paisa by the caller); it must be above zero.
/// - A payment may not exceed the outstanding payable.
/// - Payment / return / adjustment entries need a reason.
List<String> validateSupplierLedgerEntry({
  required SupplierLedgerEntryKind kind,
  required int amountMinor,
  required String reason,
  int outstandingMinor = 0,
}) {
  final errors = <String>[];
  if (amountMinor <= 0) {
    errors.add('Amount must be more than zero.');
  }
  if ((kind == SupplierLedgerEntryKind.payment ||
          kind == SupplierLedgerEntryKind.purchaseReturn) &&
      amountMinor > outstandingMinor) {
    errors.add(
      'Amount cannot exceed the outstanding payable.',
    );
  }
  if (kind != SupplierLedgerEntryKind.purchase && reason.trim().isEmpty) {
    errors.add('A reason is required for this entry.');
  }
  return errors;
}

/// Signed amount for a new entry from the unsigned amount the staff
/// typed: purchase adds to what the pharmacy owes (positive);
/// payment / return reduce it (negative); adjustment follows
/// [isIncrease].
int signedSupplierLedgerAmount({
  required SupplierLedgerEntryKind kind,
  required int amountMinor,
  bool isIncrease = true,
}) {
  switch (kind) {
    case SupplierLedgerEntryKind.purchase:
      return amountMinor;
    case SupplierLedgerEntryKind.payment:
    case SupplierLedgerEntryKind.purchaseReturn:
      return -amountMinor;
    case SupplierLedgerEntryKind.adjustment:
      return isIncrease ? amountMinor : -amountMinor;
  }
}
