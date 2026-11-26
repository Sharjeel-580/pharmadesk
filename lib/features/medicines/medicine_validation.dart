import '../medicines/medicine_logic.dart';

/// Medicine master edit validation (Week 5 Day 3, D151).
///
/// There is no medicine-creation flow in the app to copy rules from
/// — the catalogue is seed-only (verified before writing this: no
/// add-medicine UI, no `validateMedicine` anywhere). These rules are
/// therefore taken from the constraints that DO exist, and recorded
/// here so a future creation flow reuses the same function instead
/// of inventing a second set:
///
/// - Firestore schema (§3 `medicines`): `name`, `purchasePrice` and
///   `sellingPrice` are required; `purchasePrice` / `sellingPrice`
///   are int paisa (D76).
/// - Money is int paisa, never floats (D6): the form takes rupee
///   text and converts at the boundary with [parseRupeesToMinor].
/// - Seed data: every barcode is 13 digits (`890…`, EAN-13) and
///   every `categoryId` is a key of [medicineCategoryLabels] (a Day 5
///   test enforces the category rule on the seed); every seeded MRP
///   is null or 1.1× the sale price — never below it.
/// - `location` is free text (D138); empty clears it.
///
/// [validateMedicineEdit] returns one error string per invalid field,
/// keyed by field name (`name`, `salePrice`, `purchasePrice`, `mrp`,
/// `barcode`, `categoryId`); an empty map means the form is valid.

/// Parses rupee text into int paisa. Accepts whole rupees (`120`) or
/// up to two decimal places (`120.50`); rejects anything else
/// (letters, a negative sign, more than two decimals, empty text)
/// with `null` — the caller decides the message.
int? parseRupeesToMinor(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;
  if (!RegExp(r'^\d+(\.\d{1,2})?$').hasMatch(trimmed)) return null;
  final parts = trimmed.split('.');
  final rupees = int.parse(parts[0]);
  final paisa = parts.length == 2 ? int.parse(parts[1].padRight(2, '0')) : 0;
  return rupees * 100 + paisa;
}

/// Formats int paisa back to the rupee text the form shows
/// (`12000` → `120`, `12050` → `120.50`).
String formatMinorUnitsAsRupees(int minorUnits) {
  final rupees = minorUnits ~/ 100;
  final paisa = minorUnits % 100;
  if (paisa == 0) return '$rupees';
  return '$rupees.${paisa.toString().padLeft(2, '0')}';
}

Map<String, String> validateMedicineEdit({
  required String name,
  required String salePrice,
  required String purchasePrice,
  required String mrp,
  required String barcode,
  required String categoryId,
}) {
  final errors = <String, String>{};

  if (name.trim().isEmpty) {
    errors['name'] = 'Enter a medicine name.';
  }

  final saleMinor = parseRupeesToMinor(salePrice);
  if (salePrice.trim().isEmpty) {
    errors['salePrice'] = 'Enter the sale price in rupees.';
  } else if (saleMinor == null) {
    errors['salePrice'] =
        'Enter the sale price in rupees, e.g. 120 or 120.50.';
  } else if (saleMinor <= 0) {
    errors['salePrice'] = 'Sale price must be above Rs 0.';
  }

  final purchaseMinor = parseRupeesToMinor(purchasePrice);
  if (purchasePrice.trim().isEmpty) {
    errors['purchasePrice'] =
        'Enter the purchase price in rupees (0 when unknown).';
  } else if (purchaseMinor == null) {
    errors['purchasePrice'] =
        'Enter the purchase price in rupees, e.g. 90 or 90.50.';
  } else if (purchaseMinor < 0) {
    errors['purchasePrice'] = 'Purchase price cannot be negative.';
  }

  final mrpTrimmed = mrp.trim();
  if (mrpTrimmed.isNotEmpty) {
    final mrpMinor = parseRupeesToMinor(mrpTrimmed);
    if (mrpMinor == null) {
      errors['mrp'] = 'Enter the MRP in rupees, e.g. 130 or 130.50.';
    } else if (saleMinor != null && mrpMinor < saleMinor) {
      errors['mrp'] = 'MRP cannot be below the sale price.';
    }
  }

  final barcodeTrimmed = barcode.trim();
  if (barcodeTrimmed.isNotEmpty) {
    if (!RegExp(r'^\d+$').hasMatch(barcodeTrimmed)) {
      errors['barcode'] = 'Barcode must contain digits only.';
    } else if (barcodeTrimmed.length < 8 || barcodeTrimmed.length > 14) {
      errors['barcode'] = 'Barcode must be 8–14 digits (EAN-8 / EAN-13).';
    }
  }

  if (!medicineCategoryLabels.containsKey(categoryId)) {
    errors['categoryId'] = 'Choose a category.';
  }

  return errors;
}
