// Money handling for PharmaDesk.
//
// RULE: all money is stored and calculated in **minor units (paisa)** as
// `int`. Never use `double` for money — binary floating point cannot
// represent decimal currency exactly and will produce wrong totals.
//
// The foundation data models still store `price`/`totalAmount` as `double`
// (Day 0); POS and billing code must convert at the boundary with
// [rupeesToMinorUnits] and never do arithmetic on doubles. A Week 2
// decision is recorded in docs/technical-decisions.md to migrate the
// models to int minor units.

/// Converts a rupee amount to minor units (paisa), rounding to the paisa.
int rupeesToMinorUnits(num rupees) => (rupees * 100).round();

/// Converts minor units back to rupees (display only).
double minorUnitsToRupees(int minorUnits) => minorUnits / 100;

/// Formats minor units as Pakistani rupees, e.g. `Rs 1,250.00`.
String formatPkr(int minorUnits) {
  final isNegative = minorUnits < 0;
  final abs = minorUnits.abs();
  final rupees = abs ~/ 100;
  final paisa = abs % 100;
  final rupeesText = _withThousandsSeparators(rupees);
  final paisaText = paisa.toString().padLeft(2, '0');
  return '${isNegative ? '-' : ''}Rs $rupeesText.$paisaText';
}

/// Line total: unit price (minor) x quantity.
int lineTotalMinor(int unitPriceMinor, int quantity) =>
    unitPriceMinor * quantity;

/// Subtotal of line totals (minor units).
int subtotalMinor(Iterable<int> lineTotals) =>
    lineTotals.fold(0, (sum, value) => sum + value);

/// Total after discount and tax (all minor units). Never below zero.
int totalAfterDiscountAndTax({
  required int subtotalMinorUnits,
  int discountMinor = 0,
  int taxMinor = 0,
}) {
  final total = subtotalMinorUnits - discountMinor + taxMinor;
  return total < 0 ? 0 : total;
}

String _withThousandsSeparators(int value) {
  final text = value.toString();
  final buffer = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    final fromEnd = text.length - i;
    if (i > 0 && fromEnd % 3 == 0) buffer.write(',');
    buffer.write(text[i]);
  }
  return buffer.toString();
}
