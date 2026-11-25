import '../../models/customer.dart';
import '../../models/customer_ledger.dart';

/// Day 6 customer logic — pure functions over plain lists, so they are
/// unit-testable without pumping anything.
///
/// Khata math: ledger amounts are signed int paisa (positive = the
/// customer owes more, negative = paid). The outstanding balance is
/// always the SUM of the entries — never a stored field that can drift
/// (see `customer_ledger.dart`).

/// Outstanding balance in int minor units (paisa): the sum of the
/// ledger's signed amounts. Zero when the ledger is empty or settled.
int outstandingMinor(Iterable<LedgerEntry> entries) =>
    entries.fold(0, (sum, entry) => sum + entry.amountMinor);

/// Phone digits only — `0300-1112233` and `03001112233` are the same
/// number for search and duplicate checks.
String normalizePhoneDigits(String phone) =>
    phone.replaceAll(RegExp(r'[^0-9]'), '');

/// Searches the customer directory by name or phone.
///
/// - Name matches are case-insensitive substrings.
/// - Phone matches compare digits only, so `0300` finds `0300-1112233`.
/// - An empty query returns the whole directory.
List<Customer> searchCustomers(
  List<Customer> customers, {
  String query = '',
}) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return customers.toList();
  final queryDigits = normalizePhoneDigits(query);
  return customers.where((customer) {
    if (customer.name.toLowerCase().contains(needle)) return true;
    if (queryDigits.isEmpty) return false;
    return normalizePhoneDigits(
      customer.phone,
    ).contains(queryDigits);
  }).toList();
}

/// Validates a new customer before saving. Returns the list of
/// problems (empty = valid). [existingPhones] are the directory's
/// phones — a duplicate number (digits compared) is rejected.
List<String> validateNewCustomer({
  required String name,
  required String phone,
  List<String> existingPhones = const [],
}) {
  final errors = <String>[];
  if (name.trim().isEmpty) {
    errors.add('Customer name is required.');
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
    errors.add('A customer with this phone number already exists.');
  }
  return errors;
}

/// Validates a khata entry before it is recorded. Returns the list of
/// problems (empty = valid).
///
/// - [amountMinor] is the UNSIGNED amount the staff typed (whole
///   rupees converted to paisa by the caller); it must be above zero.
/// - A payment may not exceed the outstanding balance.
/// - Credit and adjustment entries need a reason; a payment gets a
///   default reason when none is given.
List<String> validateLedgerEntry({
  required LedgerEntryKind kind,
  required int amountMinor,
  required String reason,
  int outstandingMinor = 0,
}) {
  final errors = <String>[];
  if (amountMinor <= 0) {
    errors.add('Amount must be more than zero.');
  }
  if (kind == LedgerEntryKind.payment &&
      amountMinor > outstandingMinor) {
    errors.add(
      'Payment cannot exceed the outstanding balance.',
    );
  }
  if ((kind == LedgerEntryKind.credit ||
          kind == LedgerEntryKind.adjustment) &&
      reason.trim().isEmpty) {
    errors.add('A reason is required for this entry.');
  }
  return errors;
}

/// Signed amount for a new entry from the unsigned amount the staff
/// typed: credit/adjustment-increase add to what the customer owes
/// (positive), payment/adjustment-decrease reduce it (negative).
int signedLedgerAmount({
  required LedgerEntryKind kind,
  required int amountMinor,
  bool isIncrease = true,
}) {
  switch (kind) {
    case LedgerEntryKind.credit:
    case LedgerEntryKind.creditSale:
      return amountMinor;
    case LedgerEntryKind.payment:
      return -amountMinor;
    case LedgerEntryKind.adjustment:
      return isIncrease ? amountMinor : -amountMinor;
  }
}
