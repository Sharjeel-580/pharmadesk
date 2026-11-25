import 'model_utils.dart';

/// Payment methods a POS sale can be settled with (Day 6, SRS
/// FR-POS-04/FR-POS-09).
///
/// - Cash / card: settled at the counter.
/// - Credit: the sale goes on the customer's khata (credit ledger) —
///   the customer is recorded as owing the total until they pay it
///   back. Requires a customer (never walk-in).
enum SalePaymentMethod { cash, card, credit }

SalePaymentMethod salePaymentMethodFromString(String? value) {
  switch (value) {
    case 'card':
      return SalePaymentMethod.card;
    case 'credit':
      return SalePaymentMethod.credit;
    case 'cash':
    default:
      return SalePaymentMethod.cash;
  }
}

String salePaymentMethodLabel(SalePaymentMethod method) => switch (method) {
  SalePaymentMethod.cash => 'Cash',
  SalePaymentMethod.card => 'Card',
  SalePaymentMethod.credit => 'Credit (khata)',
};

/// Lifecycle of a completed sale (SRS §3.4 `sales.status`, Week 2
/// Day 4 — FR-POS-08 returns).
///
/// A sale is `completed` when rung through the POS. Returning items
/// moves it to `partiallyReturned` (some items back) or `returned`
/// (everything back). `voided` is reserved for a future void flow —
/// returns never void a sale, they restock and refund it.
enum SaleStatus { completed, partiallyReturned, returned, voided }

SaleStatus saleStatusFromString(String? value) => switch (value) {
  // Snake_case is the Firestore spelling (SRS §3.4); camelCase is
  // the local toMap spelling — both read back to the same status.
  'partially_returned' || 'partiallyReturned' => SaleStatus.partiallyReturned,
  'returned' => SaleStatus.returned,
  'voided' => SaleStatus.voided,
  _ => SaleStatus.completed,
};

String saleStatusLabel(SaleStatus status) => switch (status) {
  SaleStatus.completed => 'Completed',
  SaleStatus.partiallyReturned => 'Partially returned',
  SaleStatus.returned => 'Returned',
  SaleStatus.voided => 'Voided',
};

/// One line of a completed sale: a snapshot of the medicine at sale
/// time (name + unit price are copied so later price changes don't
/// rewrite history), plus the batch it was picked from.
///
/// A cart line that spans two FEFO batches becomes two [SaleItem]s
/// (one per batch chunk) — the first chunk carries the line discount,
/// so the discount total is preserved exactly. See
/// `allocateFefo` in `billing_logic.dart`.
class SaleItem {
  final String medicineId;
  final String medicineName;
  final int quantity;

  /// Unit sale price in int minor units (paisa).
  final int unitPriceMinor;

  /// Discount on this line in int minor units (paisa).
  final int lineDiscountMinor;

  /// The batch this chunk was picked from (FEFO, Day 5 guard).
  final String? batchId;
  final String? batchNo;
  final DateTime? batchExpiryDate;

  const SaleItem({
    required this.medicineId,
    required this.medicineName,
    required this.quantity,
    required this.unitPriceMinor,
    this.lineDiscountMinor = 0,
    this.batchId,
    this.batchNo,
    this.batchExpiryDate,
  });

  factory SaleItem.fromMap(Map<String, dynamic> map) {
    return SaleItem(
      medicineId: map['medicineId'] as String? ?? '',
      medicineName: map['medicineName'] as String? ?? '',
      quantity: (map['quantity'] as num?)?.toInt() ?? 0,
      unitPriceMinor: (map['unitPriceMinor'] as num?)?.toInt() ?? 0,
      lineDiscountMinor: (map['lineDiscountMinor'] as num?)?.toInt() ?? 0,
      batchId: map['batchId'] as String?,
      batchNo: map['batchNo'] as String?,
      batchExpiryDate: parseDate(map['batchExpiryDate']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'medicineId': medicineId,
      'medicineName': medicineName,
      'quantity': quantity,
      'unitPriceMinor': unitPriceMinor,
      'lineDiscountMinor': lineDiscountMinor,
      'batchId': batchId,
      'batchNo': batchNo,
      'batchExpiryDate': dateToMap(batchExpiryDate),
    };
  }

  /// Line total in int minor units: qty × unit price − discount,
  /// never below zero.
  int get lineTotalMinor {
    final total = unitPriceMinor * quantity - lineDiscountMinor;
    return total < 0 ? 0 : total;
  }

  SaleItem copyWith({
    String? medicineId,
    String? medicineName,
    int? quantity,
    int? unitPriceMinor,
    int? lineDiscountMinor,
    String? batchId,
    String? batchNo,
    DateTime? batchExpiryDate,
  }) {
    return SaleItem(
      medicineId: medicineId ?? this.medicineId,
      medicineName: medicineName ?? this.medicineName,
      quantity: quantity ?? this.quantity,
      unitPriceMinor: unitPriceMinor ?? this.unitPriceMinor,
      lineDiscountMinor: lineDiscountMinor ?? this.lineDiscountMinor,
      batchId: batchId ?? this.batchId,
      batchNo: batchNo ?? this.batchNo,
      batchExpiryDate: batchExpiryDate ?? this.batchExpiryDate,
    );
  }
}

/// A completed counter (POS) sale.
///
/// Firestore collection (Week 2): `branches/{branchId}/sales/{saleId}`
/// — doc id = the client-generated [idempotencyKey] (SRS FR-POS-11: a
/// retried sale can never duplicate). All money is int minor units
/// (paisa); [subtotalMinor] is after line discounts, [totalMinor] is
/// subtotal − bill discount + tax, never below zero.
///
/// A sale is always completed when saved: there is no draft/voided
/// state in the Day 6 demo (returns/refunds are FR-POS-08, Day 7+).
class Sale {
  final String id;

  /// Human invoice number, sequential per branch (e.g. `INV-DHA-1001`).
  final String invoiceNumber;
  final String branchId;

  /// `null` = walk-in customer (no khata). A credit sale always has a
  /// customer.
  final String? customerId;
  final String cashierName;
  final List<SaleItem> items;

  /// Subtotal in int minor units, after line discounts.
  final int subtotalMinor;

  /// Bill-level discount in int minor units (paisa).
  final int billDiscountMinor;

  /// Tax in int minor units (paisa).
  final int taxMinor;

  /// Grand total in int minor units: subtotal − bill discount + tax.
  final int totalMinor;
  final SalePaymentMethod paymentMethod;

  /// Cash handed over, int minor units — cash sales only (0 otherwise).
  final int cashReceivedMinor;

  /// Change given back, int minor units — cash sales only (0 otherwise).
  final int changeMinor;

  /// Client-generated idempotency key (FR-POS-11): the repository uses
  /// it as the document id in Week 2, so a retried write can never
  /// create a duplicate sale.
  final String idempotencyKey;

  /// Lifecycle status (SRS §3.4): `completed` until items are
  /// returned, then `partiallyReturned` / `returned` (FR-POS-08).
  final SaleStatus status;
  final DateTime? createdAt;

  const Sale({
    required this.id,
    required this.invoiceNumber,
    required this.branchId,
    this.customerId,
    required this.cashierName,
    required this.items,
    required this.subtotalMinor,
    this.billDiscountMinor = 0,
    this.taxMinor = 0,
    required this.totalMinor,
    required this.paymentMethod,
    this.cashReceivedMinor = 0,
    this.changeMinor = 0,
    required this.idempotencyKey,
    this.status = SaleStatus.completed,
    this.createdAt,
  });

  factory Sale.fromMap(String id, Map<String, dynamic> map) {
    final rawItems = map['items'] as List<dynamic>? ?? [];
    return Sale(
      id: id,
      invoiceNumber: map['invoiceNumber'] as String? ?? '',
      branchId: map['branchId'] as String? ?? '',
      customerId: map['customerId'] as String?,
      cashierName: map['cashierName'] as String? ?? '',
      items: rawItems
          .whereType<Map<String, dynamic>>()
          .map(SaleItem.fromMap)
          .toList(),
      subtotalMinor: (map['subtotalMinor'] as num?)?.toInt() ?? 0,
      billDiscountMinor: (map['billDiscountMinor'] as num?)?.toInt() ?? 0,
      taxMinor: (map['taxMinor'] as num?)?.toInt() ?? 0,
      totalMinor: (map['totalMinor'] as num?)?.toInt() ?? 0,
      paymentMethod: salePaymentMethodFromString(
        map['paymentMethod'] as String?,
      ),
      cashReceivedMinor: (map['cashReceivedMinor'] as num?)?.toInt() ?? 0,
      changeMinor: (map['changeMinor'] as num?)?.toInt() ?? 0,
      idempotencyKey: map['idempotencyKey'] as String? ?? id,
      status: saleStatusFromString(map['status'] as String?),
      createdAt: parseDate(map['createdAt']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'invoiceNumber': invoiceNumber,
      'branchId': branchId,
      'customerId': customerId,
      'cashierName': cashierName,
      'items': items.map((item) => item.toMap()).toList(),
      'subtotalMinor': subtotalMinor,
      'billDiscountMinor': billDiscountMinor,
      'taxMinor': taxMinor,
      'totalMinor': totalMinor,
      'paymentMethod': paymentMethod.name,
      'cashReceivedMinor': cashReceivedMinor,
      'changeMinor': changeMinor,
      'idempotencyKey': idempotencyKey,
      'status': status.name,
      'createdAt': dateToMap(createdAt),
    };
  }

  /// True when this sale went on the customer's khata.
  bool get isCredit => paymentMethod == SalePaymentMethod.credit;

  /// Total discount on the bill (line discounts + bill discount).
  int get discountTotalMinor =>
      items.fold(0, (sum, item) => sum + item.lineDiscountMinor) +
      billDiscountMinor;

  Sale copyWith({
    String? id,
    String? invoiceNumber,
    String? branchId,
    String? customerId,
    bool clearCustomerId = false,
    String? cashierName,
    List<SaleItem>? items,
    int? subtotalMinor,
    int? billDiscountMinor,
    int? taxMinor,
    int? totalMinor,
    SalePaymentMethod? paymentMethod,
    int? cashReceivedMinor,
    int? changeMinor,
    String? idempotencyKey,
    SaleStatus? status,
    DateTime? createdAt,
  }) {
    return Sale(
      id: id ?? this.id,
      invoiceNumber: invoiceNumber ?? this.invoiceNumber,
      branchId: branchId ?? this.branchId,
      customerId: clearCustomerId ? null : (customerId ?? this.customerId),
      cashierName: cashierName ?? this.cashierName,
      items: items ?? this.items,
      subtotalMinor: subtotalMinor ?? this.subtotalMinor,
      billDiscountMinor: billDiscountMinor ?? this.billDiscountMinor,
      taxMinor: taxMinor ?? this.taxMinor,
      totalMinor: totalMinor ?? this.totalMinor,
      paymentMethod: paymentMethod ?? this.paymentMethod,
      cashReceivedMinor: cashReceivedMinor ?? this.cashReceivedMinor,
      changeMinor: changeMinor ?? this.changeMinor,
      idempotencyKey: idempotencyKey ?? this.idempotencyKey,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}

/// Formats a sale's created time for the receipt, e.g.
/// `24 Nov 2026, 01:54`.
String formatReceiptDateTime(DateTime value) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final day = value.day.toString().padLeft(2, '0');
  final hour = value.hour.toString().padLeft(2, '0');
  final minute = value.minute.toString().padLeft(2, '0');
  return '$day ${months[value.month - 1]} ${value.year}, $hour:$minute';
}
