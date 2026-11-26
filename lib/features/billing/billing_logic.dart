import '../../core/utils/money.dart';
import '../../models/inventory_item.dart';
import '../../models/sale.dart';
import '../inventory/inventory_logic.dart';

/// Day 6 POS / billing logic — pure functions over plain values, so
/// they are unit-testable without pumping anything.
///
/// All money is int minor units (paisa) — never doubles (D6).
/// Batch selection uses the Day 5 shared guard
/// ([canSellMedicine] / [fefoBatchFor] / [isBatchSellable] in
/// `inventory_logic.dart`): expired batches are never sellable, and
/// the rule is NOT re-implemented here (D30).

/// One line in the POS cart: a medicine, a quantity, a unit price and
/// an optional per-line discount. The cart holds [CartLine]s; a
/// completed sale holds [SaleItem]s (snapshots with batch info).
class CartLine {
  const CartLine({
    required this.medicineId,
    required this.medicineName,
    required this.unitPriceMinor,
    this.quantity = 1,
    this.lineDiscountMinor = 0,
  });

  final String medicineId;
  final String medicineName;

  /// Unit sale price in int minor units (paisa).
  final int unitPriceMinor;
  final int quantity;

  /// Per-line discount in int minor units (paisa).
  final int lineDiscountMinor;

  /// Gross for this line: qty × unit price (before line discount).
  int get grossMinor => unitPriceMinor * quantity;

  /// Line total in int minor units: gross − discount, never below zero.
  int get lineTotalMinor {
    final total = grossMinor - lineDiscountMinor;
    return total < 0 ? 0 : total;
  }

  CartLine copyWith({int? quantity, int? lineDiscountMinor}) {
    return CartLine(
      medicineId: medicineId,
      medicineName: medicineName,
      unitPriceMinor: unitPriceMinor,
      quantity: quantity ?? this.quantity,
      lineDiscountMinor: lineDiscountMinor ?? this.lineDiscountMinor,
    );
  }
}

/// Gross of the whole cart (qty × unit price, before any discount).
int cartGrossMinor(Iterable<CartLine> lines) =>
    lines.fold(0, (sum, line) => sum + line.grossMinor);

/// Sum of per-line discounts (int paisa).
int cartLineDiscountsMinor(Iterable<CartLine> lines) =>
    lines.fold(0, (sum, line) => sum + line.lineDiscountMinor);

/// Subtotal: gross − line discounts, never below zero.
int cartSubtotalMinor(Iterable<CartLine> lines) {
  final subtotal = cartGrossMinor(lines) - cartLineDiscountsMinor(lines);
  return subtotal < 0 ? 0 : subtotal;
}

/// Tax on a taxable amount at a whole-percent rate, in int paisa.
/// Integer division truncates — the demo never rounds tax up.
int computeTaxMinor({required int taxableMinor, required int taxRatePercent}) {
  if (taxableMinor <= 0 || taxRatePercent <= 0) return 0;
  return taxableMinor * taxRatePercent ~/ 100;
}

/// Grand total: subtotal − bill discount + tax, never below zero.
int billTotalMinor({
  required int subtotalMinor,
  int billDiscountMinor = 0,
  int taxMinor = 0,
}) {
  final total = subtotalMinor - billDiscountMinor + taxMinor;
  return total < 0 ? 0 : total;
}

/// Change owed to a cash customer: received − total, or 0 when the
/// customer paid exact or short.
int changeDueMinor({required int totalMinor, required int cashReceivedMinor}) {
  final change = cashReceivedMinor - totalMinor;
  return change < 0 ? 0 : change;
}

/// How much more cash is needed: total − received, or 0 when covered.
int cashShortfallMinor({
  required int totalMinor,
  required int cashReceivedMinor,
}) {
  final shortfall = totalMinor - cashReceivedMinor;
  return shortfall < 0 ? 0 : shortfall;
}

/// Validates a split payment (Week 4 Day 5, D137 — FR-POS-05).
/// Returns the problems (empty = the split is valid):
///
/// - At least one leg; every leg positive; no method twice.
/// - The legs must sum to the sale total exactly — no shortfall, no
///   overpayment (a cash leg that is overpaid is change, handled by
///   the cash-received check in [validateSale], not here).
List<String> validateSplitPayments({
  required int totalMinor,
  required List<SalePayment> splits,
}) {
  final errors = <String>[];
  if (splits.isEmpty) {
    errors.add('Add at least one payment method to the split.');
    return errors;
  }
  final seen = <SalePaymentMethod>{};
  var sum = 0;
  for (final leg in splits) {
    if (leg.amountMinor <= 0) {
      errors.add(
        '${salePaymentMethodLabel(leg.method)} amount must be above zero.',
      );
    }
    if (!seen.add(leg.method)) {
      errors.add(
        '${salePaymentMethodLabel(leg.method)} appears twice in the split.',
      );
    }
    sum += leg.amountMinor;
  }
  if (sum != totalMinor) {
    errors.add(
      'Split payments (${formatPkr(sum)}) must add up to the total '
      '(${formatPkr(totalMinor)}).',
    );
  }
  return errors;
}

/// Validates a sale before it is completed. Returns the list of
/// problems (empty = the sale may complete).
///
/// - The cart must not be empty; every line needs qty ≥ 1 and a line
///   discount no larger than its gross.
/// - Quantities may not exceed the sellable stock for the medicine
///   ([sellableStockByMedicine], from the Day 5 guard — expired
///   batches don't count).
/// - The bill discount may not exceed the subtotal; the tax rate must
///   be 0–100.
/// - Cash needs enough received to cover the total.
/// - Credit needs a customer, and (when the customer has a limit) the
///   new outstanding must stay within it.
/// - [splitPayments] (D137): when given, the split rules replace the
///   single-method rules — the legs must sum to the total, a cash leg
///   needs enough cash received for that leg, and a credit leg needs
///   a customer with headroom for that leg only (not the full total).
List<String> validateSale({
  required List<CartLine> lines,
  int billDiscountMinor = 0,
  int taxRatePercent = 0,
  required SalePaymentMethod paymentMethod,
  int cashReceivedMinor = 0,
  String? customerId,
  int outstandingMinor = 0,
  int creditLimitMinor = 0,
  Map<String, int> sellableStockByMedicine = const {},
  List<SalePayment>? splitPayments,
}) {
  final errors = <String>[];
  if (lines.isEmpty) {
    errors.add('Add at least one medicine to the cart.');
    return errors;
  }
  for (final line in lines) {
    if (line.quantity < 1) {
      errors.add('${line.medicineName}: quantity must be at least 1.');
    }
    if (line.lineDiscountMinor < 0) {
      errors.add('${line.medicineName}: line discount cannot be negative.');
    }
    if (line.lineDiscountMinor > line.grossMinor) {
      errors.add(
        '${line.medicineName}: line discount cannot exceed the line total.',
      );
    }
    final sellable = sellableStockByMedicine[line.medicineId];
    if (sellable != null && line.quantity > sellable) {
      errors.add(
        '${line.medicineName}: only $sellable unit(s) sellable in stock.',
      );
    }
  }
  final subtotal = cartSubtotalMinor(lines);
  if (billDiscountMinor < 0) {
    errors.add('Bill discount cannot be negative.');
  }
  if (billDiscountMinor > subtotal) {
    errors.add('Bill discount cannot exceed the subtotal.');
  }
  if (taxRatePercent < 0 || taxRatePercent > 100) {
    errors.add('Tax rate must be between 0% and 100%.');
  }
  final tax = computeTaxMinor(
    taxableMinor: subtotal - billDiscountMinor,
    taxRatePercent: taxRatePercent,
  );
  final total = billTotalMinor(
    subtotalMinor: subtotal,
    billDiscountMinor: billDiscountMinor,
    taxMinor: tax,
  );
  final splits = splitPayments;
  if (splits != null && splits.isNotEmpty) {
    errors.addAll(
      validateSplitPayments(totalMinor: total, splits: splits),
    );
    final cashLeg = splits
        .where((leg) => leg.method == SalePaymentMethod.cash)
        .fold(0, (sum, leg) => sum + leg.amountMinor);
    if (cashLeg > 0 && cashReceivedMinor < cashLeg) {
      errors.add(
        'Cash received (${formatPkr(cashReceivedMinor)}) is less than '
        'the cash part (${formatPkr(cashLeg)}).',
      );
    }
    final creditLeg = splits
        .where((leg) => leg.method == SalePaymentMethod.credit)
        .fold(0, (sum, leg) => sum + leg.amountMinor);
    if (creditLeg > 0) {
      if (customerId == null || customerId.isEmpty) {
        errors.add('The credit part needs a customer — pick one first.');
      }
      if (creditLimitMinor > 0 &&
          outstandingMinor + creditLeg > creditLimitMinor) {
        errors.add(
          'Credit limit exceeded: outstanding ${formatPkr(outstandingMinor)} '
          '+ this credit part ${formatPkr(creditLeg)} is over the limit '
          '${formatPkr(creditLimitMinor)}.',
        );
      }
    }
    return errors;
  }
  switch (paymentMethod) {
    case SalePaymentMethod.cash:
      if (cashReceivedMinor < total) {
        errors.add(
          'Cash received (${formatPkr(cashReceivedMinor)}) is less than '
          'the total (${formatPkr(total)}).',
        );
      }
    case SalePaymentMethod.card:
      break;
    case SalePaymentMethod.credit:
      if (customerId == null || customerId.isEmpty) {
        errors.add('Credit sales need a customer — pick one first.');
      }
      if (creditLimitMinor > 0 && outstandingMinor + total > creditLimitMinor) {
        errors.add(
          'Credit limit exceeded: outstanding ${formatPkr(outstandingMinor)} '
          '+ this sale ${formatPkr(total)} is over the limit '
          '${formatPkr(creditLimitMinor)}.',
        );
      }
  }
  return errors;
}

/// FEFO allocation for a cart: which batches to decrement, and the
/// sale items to save.
///
/// For each cart line, sellable batches are walked in FEFO order
/// (earliest expiry first — the Day 5 shared guard decides what is
/// sellable, so expired batches are skipped here, never re-checked).
/// A line that spans two batches becomes two [SaleItem]s (one per
/// batch chunk); the first chunk carries the line discount so the
/// discount total is preserved exactly.
///
/// Throws [ArgumentError] when a line needs more sellable stock than
/// the branch has — the caller shows the message and completes nothing.
({List<SaleItem> items, List<({String batchId, int quantity})> decrements})
allocateFefo({
  required List<CartLine> lines,
  required Map<String, List<InventoryItem>> batchesByMedicine,
  DateTime? now,
}) {
  final items = <SaleItem>[];
  final decrements = <({String batchId, int quantity})>[];
  for (final line in lines) {
    final batches = batchesByMedicine[line.medicineId] ?? const [];
    var remaining = line.quantity;
    var firstChunk = true;
    for (final batch in fefoBatches(batches)) {
      if (remaining <= 0) break;
      if (!isBatchSellable(batch, now: now)) continue;
      final take = remaining < batch.quantity ? remaining : batch.quantity;
      if (take <= 0) continue;
      items.add(
        SaleItem(
          medicineId: line.medicineId,
          medicineName: line.medicineName,
          quantity: take,
          unitPriceMinor: line.unitPriceMinor,
          lineDiscountMinor: firstChunk ? line.lineDiscountMinor : 0,
          batchId: batch.id,
          batchNo: batch.batchNo,
          batchExpiryDate: batch.expiryDate,
        ),
      );
      decrements.add((batchId: batch.id, quantity: take));
      remaining -= take;
      firstChunk = false;
    }
    if (remaining > 0) {
      final sellable = sellableStockFor(batches, now: now);
      throw ArgumentError(
        '${line.medicineName}: only $sellable unit(s) sellable in stock, '
        'need ${line.quantity}.',
      );
    }
  }
  return (items: items, decrements: decrements);
}

/// Builds the [Sale] to save from a validated cart. The id and invoice
/// number are assigned by the repository; [idempotencyKey] is
/// client-generated (SRS FR-POS-11) so a retried write can never
/// duplicate the sale. When omitted a fresh key is minted — callers
/// that retry (the POS notifier, D54) pass the key they minted on the
/// first attempt so the retry dedupes against the original commit.
///
/// [splitPayments] (D137): when given, the sale carries those legs
/// and [paymentMethod] is the primary method (the largest leg).
/// Without it the sale is single-method, with one leg settling the
/// whole total. Change is computed against the cash leg only: a
/// split sale's cash is exact (the leg amount is what was handed
/// over), so split cash never produces change.
Sale buildSale({
  required String branchId,
  String? customerId,
  required String cashierName,
  required List<SaleItem> items,
  required int billDiscountMinor,
  required int taxRatePercent,
  required SalePaymentMethod paymentMethod,
  int cashReceivedMinor = 0,
  List<SalePayment>? splitPayments,
  String? idempotencyKey,
}) {
  final subtotal = items.fold(0, (sum, item) => sum + item.lineTotalMinor);
  final tax = computeTaxMinor(
    taxableMinor: subtotal - billDiscountMinor,
    taxRatePercent: taxRatePercent,
  );
  final total = billTotalMinor(
    subtotalMinor: subtotal,
    billDiscountMinor: billDiscountMinor,
    taxMinor: tax,
  );
  final payments = splitPayments ??
      [SalePayment(method: paymentMethod, amountMinor: total)];
  var primaryMethod = paymentMethod;
  var largestLeg = 0;
  for (final leg in payments) {
    if (leg.amountMinor > largestLeg) {
      largestLeg = leg.amountMinor;
      primaryMethod = leg.method;
    }
  }
  final cashLeg = payments
      .where((leg) => leg.method == SalePaymentMethod.cash)
      .fold(0, (sum, leg) => sum + leg.amountMinor);
  final received = cashLeg > 0 ? cashReceivedMinor : 0;
  final change = cashLeg > 0
      ? changeDueMinor(totalMinor: cashLeg, cashReceivedMinor: received)
      : 0;
  final key =
      idempotencyKey ??
      'sale-$branchId-${DateTime.now().millisecondsSinceEpoch}';
  return Sale(
    id: '',
    invoiceNumber: '',
    branchId: branchId,
    customerId: customerId,
    cashierName: cashierName,
    items: List.unmodifiable(items),
    subtotalMinor: subtotal,
    billDiscountMinor: billDiscountMinor,
    taxMinor: tax,
    totalMinor: total,
    paymentMethod: primaryMethod,
    payments: List.unmodifiable(payments),
    cashReceivedMinor: received,
    changeMinor: change,
    idempotencyKey: key,
  );
}

/// Plain-text receipt for the Share action (copied to the clipboard)
/// and for the print preview. All money in int paisa, formatted with
/// [formatPkr].
String receiptText({
  required Sale sale,
  required String branchName,
  required String branchAddress,
  required String brandHeader,
  String? customerName,
}) {
  final buffer = StringBuffer();
  buffer.writeln(brandHeader);
  buffer.writeln(branchName);
  buffer.writeln(branchAddress);
  buffer.writeln('Invoice: ${sale.invoiceNumber}');
  buffer.writeln(
    'Date: ${formatReceiptDateTime(sale.createdAt ?? DateTime.now())}',
  );
  buffer.writeln('Cashier: ${sale.cashierName}');
  if (customerName != null) buffer.writeln('Customer: $customerName');
  buffer.writeln('--------------------------------');
  for (final item in sale.items) {
    buffer.writeln(
      '${item.medicineName} x${item.quantity} — ${formatPkr(item.lineTotalMinor)}',
    );
    final batchLabel = item.batchNo == null
        ? ''
        : '  Batch ${item.batchNo}'
              '${item.batchExpiryDate == null ? '' : ' (exp ${item.batchExpiryDate!.day}/${item.batchExpiryDate!.month}/${item.batchExpiryDate!.year})'}';
    if (batchLabel.isNotEmpty) buffer.writeln(batchLabel);
    if (item.lineDiscountMinor > 0) {
      buffer.writeln('  Discount: -${formatPkr(item.lineDiscountMinor)}');
    }
  }
  buffer.writeln('--------------------------------');
  buffer.writeln('Subtotal: ${formatPkr(sale.subtotalMinor)}');
  if (sale.billDiscountMinor > 0) {
    buffer.writeln('Bill discount: -${formatPkr(sale.billDiscountMinor)}');
  }
  if (sale.taxMinor > 0) {
    buffer.writeln('Tax: ${formatPkr(sale.taxMinor)}');
  }
  buffer.writeln('TOTAL: ${formatPkr(sale.totalMinor)}');
  buffer.writeln('Payment: ${salePaymentSummary(sale)}');
  if (sale.isSplit) {
    for (final leg in sale.payments) {
      buffer.writeln(
        '  ${salePaymentMethodLabel(leg.method)}: ${formatPkr(leg.amountMinor)}',
      );
    }
  }
  if (sale.cashReceivedMinor > 0) {
    buffer.writeln('Cash received: ${formatPkr(sale.cashReceivedMinor)}');
    buffer.writeln('Change: ${formatPkr(sale.changeMinor)}');
  }
  if (sale.hasCreditLeg) {
    buffer.writeln(
      'On credit — ${formatPkr(sale.creditMinor)} added to the customer khata.',
    );
  }
  buffer.writeln('Thank you for shopping with us!');
  buffer.writeln('DEMO — not a real receipt.');
  return buffer.toString();
}
