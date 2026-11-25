import 'package:cloud_firestore/cloud_firestore.dart' hide Order;

import '../../models/customer.dart';
import '../../models/customer_ledger.dart';
import '../../models/inventory_item.dart';
import '../../models/medicine.dart';
import '../../models/order.dart';
import '../../models/prescription.dart';
import '../../models/purchase_order.dart';
import '../../models/rider.dart';
import '../../models/sale.dart';
import '../../models/sale_return.dart';
import '../../models/supplier.dart';
import '../../models/supplier_ledger.dart';
import 'firestore_schema.dart';

/// Firestore document mappers (Week 2 Day 3, D72).
///
/// Pure functions: local model <-> Firestore document (SRS §3 field
/// contracts in `firestore_schema.dart`). The repositories build
/// every write from these functions and parse every read through
/// them, so the Firestore shape is defined in exactly one place.
///
/// Where the local model and the §3 contract differ, the mapper
/// translates and the difference is documented at the function —
/// the model is NEVER changed to fit Firestore silently:
///
/// - **Money:** all Firestore money fields are int paisa. The Day 0
///   models still store some prices as `double` rupees
///   (`OrderItem.unitPrice`, `Order.totalAmount`, `Medicine.price`);
///   the mappers convert at the boundary (`(rupees * 100).round()`)
///   and back (`paisa / 100`). Sale / ledger money is already int.
/// - **Sale doc:** §3 keeps payments in the `payments` subcollection
///   and items in `items`; the mapper writes the doc without embedded
///   items. `paymentMethod`, `cashierName`, `cashReceivedMinor` and
///   `changeMinor` are stored as *extra* fields on the doc (the
///   rules use `hasAll`, not `hasOnly`, so extras are allowed) —
///   they are needed to reconstruct the local [Sale] exactly.
/// - **Order status:** the Week 1 vocabulary (D25) has no 1:1 §3
///   match: `newOrder`/`placed` → `pending`, `ready` → `preparing`
///   (lossy — a `ready` order reads back as `processing`), and the
///   read side maps `pending` → `newOrder`, `preparing` →
///   `processing`, `out_for_delivery` → `dispatched`.
/// - **Order source:** `walkIn` → `walk_in` (§3), the rest identical.
/// - **Order discount:** §3 lists no discount field on orders, so
///   `discountMinor` is stored as an extra field (needed to
///   reconstruct the total exactly).
/// - **Inventory batch:** the model tracks only the *current*
///   quantity, so on create `quantityReceived == quantityRemaining ==
///   quantity`. Later updates change only `quantityRemaining`;
///   `quantityReceived` is informational and dropped on read.
///   `lowStockThreshold` is an extra field (needed for `isLowStock`).
/// - **Prescription review:** §3 names the field `reviewStatus` and
///   the note field `notes`; the local map historically used `status`
///   / `reviewNotes` — the mapper writes §3 names and the model
///   parser accepts both.
/// - **Ledger amounts:** §3 names them `amount` / `balanceAfter`;
///   the local models name them `amountMinor` / `balanceAfterMinor`.
///   The mapper translates both ways and accepts both on read.
/// - **Timestamps:** mappers stamp `Timestamp.fromDate(now)` (client
///   clock). The Firebase-wiring chunk may switch creates to
///   `FieldValue.serverTimestamp()` once the project exists; the
///   fake transport stores maps verbatim, so client timestamps keep
///   mapper round-trips identical on both transports.
///
/// Every mapper validates its output against
/// [FirestoreSchema.validateDocument] via [validateOrThrow] — a
/// write that would fail the rules fails loudly in the repository,
/// never silently in Firestore.

/// Stamps a new document with the common §3 fields.
Map<String, dynamic> stampNewDocument(
  Map<String, dynamic> doc, {
  required String orgId,
  String? branchId,
  DateTime? now,
}) {
  final at = Timestamp.fromDate(now ?? DateTime.now());
  final stamped = <String, dynamic>{
    ...doc,
    'organizationId': orgId,
    'createdAt': at,
    'updatedAt': at,
  };
  if (branchId != null) stamped['branchId'] = branchId;
  return stamped;
}

/// Stamps an update with a fresh `updatedAt`.
Map<String, dynamic> stampUpdate(Map<String, dynamic> doc, {DateTime? now}) {
  return {...doc, 'updatedAt': Timestamp.fromDate(now ?? DateTime.now())};
}

/// Throws [ArgumentError] when [doc] fails the §3 contract for
/// [collectionPattern] (missing required fields).
void validateOrThrow(String collectionPattern, Map<String, dynamic> doc) {
  final errors = FirestoreSchema.validateDocument(collectionPattern, doc);
  if (errors.isNotEmpty) {
    throw ArgumentError(
      'Invalid $collectionPattern document: ${errors.join(' ')}',
    );
  }
}

// -- Sales --------------------------------------------------------------

/// Sale doc (§3 `branches/{branchId}/sales`): schema names
/// (`subtotal`, `discountTotal`, `taxTotal`, `grandTotal`) + extras
/// needed to rebuild the local model. Items and payments live in
/// subcollections and are mapped separately.
Map<String, dynamic> saleToFirestore(
  Sale sale, {
  required String orgId,
  DateTime? now,
}) {
  final doc = stampNewDocument(
    {
      'invoiceNumber': sale.invoiceNumber,
      'customerId': sale.customerId,
      'cashierName': sale.cashierName,
      'subtotal': sale.subtotalMinor,
      'discountTotal': sale.discountTotalMinor,
      'taxTotal': sale.taxMinor,
      'grandTotal': sale.totalMinor,
      'status': saleStatusToFirestore(sale.status),
      'idempotencyKey': sale.idempotencyKey,
      // Extras (rules allow them): needed to rebuild the local Sale.
      'paymentMethod': sale.paymentMethod.name,
      'cashReceivedMinor': sale.cashReceivedMinor,
      'changeMinor': sale.changeMinor,
      'billDiscountMinor': sale.billDiscountMinor,
    },
    orgId: orgId,
    branchId: sale.branchId,
    now: now,
  );
  validateOrThrow('branches/{branchId}/sales', doc);
  return doc;
}

/// Sale item doc (§3 `sales/{saleId}/items`).
Map<String, dynamic> saleItemToFirestore(SaleItem item) {
  return {
    'medicineId': item.medicineId,
    'batchId': item.batchId,
    'medicineName': item.medicineName,
    'unitPrice': item.unitPriceMinor,
    'quantity': item.quantity,
    'discount': item.lineDiscountMinor,
    'lineTotal': item.lineTotalMinor,
    // Extras: the receipt shows batch + expiry per chunk (D35).
    'batchNo': item.batchNo,
    'batchExpiryDate': item.batchExpiryDate == null
        ? null
        : Timestamp.fromDate(item.batchExpiryDate!),
  };
}

/// Sale payment doc (§3 `sales/{saleId}/payments`).
Map<String, dynamic> salePaymentToFirestore({
  required SalePaymentMethod method,
  required int amountMinor,
  String? reference,
}) {
  return {'method': method.name, 'amount': amountMinor, 'reference': reference};
}

Sale saleFromFirestore(
  String id,
  Map<String, dynamic> doc, {
  List<Map<String, dynamic>> itemDocs = const [],
}) {
  return Sale(
    id: id,
    invoiceNumber: doc['invoiceNumber'] as String? ?? '',
    branchId: doc['branchId'] as String? ?? '',
    customerId: doc['customerId'] as String?,
    cashierName: doc['cashierName'] as String? ?? '',
    items: itemDocs.map(_saleItemFromFirestore).toList(),
    subtotalMinor: (doc['subtotal'] as num?)?.toInt() ?? 0,
    billDiscountMinor: (doc['billDiscountMinor'] as num?)?.toInt() ?? 0,
    taxMinor: (doc['taxTotal'] as num?)?.toInt() ?? 0,
    totalMinor: (doc['grandTotal'] as num?)?.toInt() ?? 0,
    paymentMethod: salePaymentMethodFromString(doc['paymentMethod'] as String?),
    cashReceivedMinor: (doc['cashReceivedMinor'] as num?)?.toInt() ?? 0,
    changeMinor: (doc['changeMinor'] as num?)?.toInt() ?? 0,
    idempotencyKey: doc['idempotencyKey'] as String? ?? id,
    status: saleStatusFromFirestore(doc['status'] as String?),
    createdAt: _parseDate(doc['createdAt']),
  );
}

/// Local sale status → §3 status (snake_case, SRS §3.4).
String saleStatusToFirestore(SaleStatus status) => switch (status) {
  SaleStatus.completed => 'completed',
  SaleStatus.partiallyReturned => 'partially_returned',
  SaleStatus.returned => 'returned',
  SaleStatus.voided => 'voided',
};

/// §3 status → local sale status (defaults to `completed` for legacy
/// docs written before the status field existed — D76 pattern: the
/// Day 3 mapper hardcoded `'completed'` on every write).
SaleStatus saleStatusFromFirestore(String? value) =>
    saleStatusFromString(value);

// -- Sale returns --------------------------------------------------------

/// Sale return doc (§3 `branches/{branchId}/saleReturns`): schema
/// names (`saleId`, `reason`, `status`, `refundedAmount`,
/// `approvedBy`) + extras needed to rebuild the local model
/// (invoice number, approver name). Items live in the `items`
/// subcollection and are mapped separately.
Map<String, dynamic> saleReturnToFirestore(
  SaleReturn saleReturn, {
  required String orgId,
  DateTime? now,
}) {
  final doc = stampNewDocument(
    {
      'saleId': saleReturn.saleId,
      'reason': saleReturn.reason,
      'status': saleReturn.status.name,
      'refundedAmount': saleReturn.refundedAmountMinor,
      'approvedBy': saleReturn.approvedBy,
      // Extras (rules allow them): needed to rebuild the local model.
      'invoiceNumber': saleReturn.invoiceNumber,
      'approvedByName': saleReturn.approvedByName,
    },
    orgId: orgId,
    branchId: saleReturn.branchId,
    now: now,
  );
  validateOrThrow('branches/{branchId}/saleReturns', doc);
  return doc;
}

/// Sale return item doc (§3 `saleReturns/{returnId}/items`).
Map<String, dynamic> saleReturnItemToFirestore(SaleReturnItem item) {
  return {
    'saleItemId': item.saleBatchId == null
        ? item.medicineId
        : '${item.medicineId}|${item.saleBatchId}',
    'medicineId': item.medicineId,
    'medicineName': item.medicineName,
    'quantity': item.quantity,
    'unitPrice': item.unitPriceMinor,
    'lineDiscount': item.lineDiscountMinor,
    'refundMinor': item.refundMinor,
    'restockBatchId': item.restockBatchId,
    'restockBatchNo': item.restockBatchNo,
  };
}

SaleReturn saleReturnFromFirestore(
  String id,
  Map<String, dynamic> doc, {
  List<Map<String, dynamic>> itemDocs = const [],
}) {
  return SaleReturn(
    id: id,
    branchId: doc['branchId'] as String? ?? '',
    saleId: doc['saleId'] as String? ?? '',
    invoiceNumber: doc['invoiceNumber'] as String? ?? '',
    items: itemDocs.map(_saleReturnItemFromFirestore).toList(),
    reason: doc['reason'] as String? ?? '',
    refundedAmountMinor: (doc['refundedAmount'] as num?)?.toInt() ?? 0,
    approvedBy: doc['approvedBy'] as String? ?? '',
    approvedByName: doc['approvedByName'] as String? ?? '',
    status: saleReturnStatusFromString(doc['status'] as String?),
    createdAt: _parseDate(doc['createdAt']),
  );
}

SaleReturnItem _saleReturnItemFromFirestore(Map<String, dynamic> map) {
  // `saleItemId` was written as `medicineId|saleBatchId` (or the bare
  // medicine id for chunks sold without a batch); split it back.
  final saleItemId = map['saleItemId'] as String?;
  final saleBatchId = saleItemId != null && saleItemId.contains('|')
      ? saleItemId.split('|').last
      : null;
  return SaleReturnItem(
    medicineId: map['medicineId'] as String? ?? '',
    medicineName: map['medicineName'] as String? ?? '',
    quantity: (map['quantity'] as num?)?.toInt() ?? 0,
    unitPriceMinor:
        (map['unitPrice'] as num?)?.toInt() ??
        (map['unitPriceMinor'] as num?)?.toInt() ??
        0,
    lineDiscountMinor:
        (map['lineDiscount'] as num?)?.toInt() ??
        (map['lineDiscountMinor'] as num?)?.toInt() ??
        0,
    refundMinor: (map['refundMinor'] as num?)?.toInt() ?? 0,
    saleBatchId: saleBatchId,
    restockBatchId: map['restockBatchId'] as String?,
    restockBatchNo: map['restockBatchNo'] as String?,
  );
}

SaleItem _saleItemFromFirestore(Map<String, dynamic> map) {
  return SaleItem(
    medicineId: map['medicineId'] as String? ?? '',
    medicineName: map['medicineName'] as String? ?? '',
    quantity: (map['quantity'] as num?)?.toInt() ?? 0,
    unitPriceMinor:
        (map['unitPrice'] as num?)?.toInt() ??
        (map['unitPriceMinor'] as num?)?.toInt() ??
        0,
    lineDiscountMinor:
        (map['discount'] as num?)?.toInt() ??
        (map['lineDiscountMinor'] as num?)?.toInt() ??
        0,
    batchId: map['batchId'] as String?,
    batchNo: map['batchNo'] as String?,
    batchExpiryDate: _parseDate(map['batchExpiryDate']),
  );
}

// -- Orders -------------------------------------------------------------

/// Week 1 order status → §3 status (lossy: `ready` → `preparing`).
String orderStatusToFirestore(OrderStatus status) => switch (status) {
  OrderStatus.newOrder || OrderStatus.placed => 'pending',
  OrderStatus.confirmed => 'confirmed',
  OrderStatus.processing ||
  OrderStatus.preparing ||
  OrderStatus.ready => 'preparing',
  OrderStatus.dispatched || OrderStatus.outForDelivery => 'out_for_delivery',
  OrderStatus.delivered => 'delivered',
  OrderStatus.cancelled => 'cancelled',
};

/// §3 status → Week 1 order status (`pending` → `newOrder`).
OrderStatus orderStatusFromFirestore(String? value) => switch (value) {
  'pending' => OrderStatus.newOrder,
  'confirmed' => OrderStatus.confirmed,
  'preparing' => OrderStatus.processing,
  'out_for_delivery' => OrderStatus.dispatched,
  'delivered' => OrderStatus.delivered,
  'cancelled' => OrderStatus.cancelled,
  'placed' => OrderStatus.placed,
  _ => OrderStatus.newOrder,
};

String orderSourceToFirestore(OrderSource source) => switch (source) {
  OrderSource.phone => 'phone',
  OrderSource.whatsapp => 'whatsapp',
  OrderSource.walkIn => 'walk_in',
};

OrderSource orderSourceFromFirestore(String? value) => switch (value) {
  'whatsapp' => OrderSource.whatsapp,
  'walk_in' => OrderSource.walkIn,
  _ => OrderSource.phone,
};

/// Order doc (§3 `branches/{branchId}/orders`). Items live in the
/// `items` subcollection. [orderNumber] is assigned by the repository
/// counter before this is called; [idempotencyKey] defaults to the
/// document id the repository uses.
Map<String, dynamic> orderToFirestore(
  Order order, {
  required String orgId,
  required String orderNumber,
  String? idempotencyKey,
  DateTime? now,
}) {
  final doc = stampNewDocument(
    {
      'orderNumber': orderNumber,
      'customerId': order.customerId,
      'source': orderSourceToFirestore(order.source),
      'status': orderStatusToFirestore(order.status),
      'deliveryAddress': order.deliveryAddress,
      'subtotal': order.subtotalMinor,
      'grandTotal': order.totalMinor,
      'paymentMethod': order.paymentMethod.name,
      'riderId': order.riderId,
      'prescriptionId': order.prescriptionId,
      'idempotencyKey': idempotencyKey ?? order.id,
      // Extras: §3 lists no discount field; the local total needs it.
      'discountMinor': order.discountMinor,
      'orderNotes': order.orderNotes,
      'fulfillment': order.fulfillment.name,
    },
    orgId: orgId,
    branchId: order.branchId,
    now: now,
  );
  validateOrThrow('branches/{branchId}/orders', doc);
  return doc;
}

/// Order item doc (§3 `orders/{orderId}/items`): unit price as int
/// paisa (the local model stores double rupees — D6 boundary).
Map<String, dynamic> orderItemToFirestore(OrderItem item) {
  return {
    'medicineId': item.medicineId,
    'medicineName': item.medicineName,
    'quantity': item.quantity,
    'unitPrice': (item.unitPrice * 100).round(),
    'lineTotal': item.lineTotalMinor,
  };
}

Order orderFromFirestore(
  String id,
  Map<String, dynamic> doc, {
  List<Map<String, dynamic>> itemDocs = const [],
}) {
  final items = itemDocs.map(_orderItemFromFirestore).toList();
  final grandTotalMinor = (doc['grandTotal'] as num?)?.toInt() ?? 0;
  return Order(
    id: id,
    customerId: doc['customerId'] as String? ?? '',
    branchId: doc['branchId'] as String? ?? '',
    riderId: doc['riderId'] as String?,
    items: items,
    deliveryAddress: doc['deliveryAddress'] as String? ?? '',
    paymentMethod: paymentMethodFromString(doc['paymentMethod'] as String?),
    status: orderStatusFromFirestore(doc['status'] as String?),
    orderNotes: doc['orderNotes'] as String?,
    prescriptionId: doc['prescriptionId'] as String?,
    totalAmount: grandTotalMinor / 100,
    discountMinor: (doc['discountMinor'] as num?)?.toInt() ?? 0,
    source: orderSourceFromFirestore(doc['source'] as String?),
    fulfillment: fulfillmentTypeFromString(doc['fulfillment'] as String?),
    createdAt: _parseDate(doc['createdAt']),
    updatedAt: _parseDate(doc['updatedAt']),
  );
}

OrderItem _orderItemFromFirestore(Map<String, dynamic> map) {
  final unitPriceMinor = (map['unitPrice'] as num?)?.toInt() ?? 0;
  return OrderItem(
    medicineId: map['medicineId'] as String? ?? '',
    medicineName: map['medicineName'] as String? ?? '',
    quantity: (map['quantity'] as num?)?.toInt() ?? 0,
    unitPrice: unitPriceMinor / 100,
  );
}

// -- Medicines ----------------------------------------------------------

/// Medicine doc (§3 root `medicines`): selling + purchase price as
/// int paisa. `purchasePrice` is a required §3 field (D76) — it comes
/// from `Medicine.purchasePriceMinor`, 0 when unknown (demo seed rows).
/// The local model has no generic name / dosage form, so those
/// optional §3 fields are omitted (never invented).
Map<String, dynamic> medicineToFirestore(
  Medicine medicine, {
  required String orgId,
  DateTime? now,
}) {
  final doc = stampNewDocument(
    {
      'name': medicine.name,
      'brand': medicine.brand,
      'categoryId': medicine.categoryId,
      'strength': medicine.strength,
      'packSize': medicine.packSize,
      'sellingPrice': medicine.priceMinor,
      'purchasePrice': medicine.purchasePriceMinor,
      'barcode': medicine.barcode,
      'prescriptionClass': medicine.requiresPrescription
          ? 'prescription'
          : 'otc',
      'imagePath': medicine.imageUrl,
      'isActive': true,
    },
    orgId: orgId,
    now: now,
  );
  validateOrThrow('medicines', doc);
  return doc;
}

Medicine medicineFromFirestore(String id, Map<String, dynamic> doc) {
  final sellingPriceMinor =
      (doc['sellingPrice'] as num?)?.toInt() ??
      ((doc['price'] as num?)?.toDouble() ?? 0) * 100;
  return Medicine(
    id: id,
    name: doc['name'] as String? ?? '',
    brand: doc['brand'] as String? ?? '',
    categoryId: doc['categoryId'] as String? ?? '',
    strength: doc['strength'] as String? ?? '',
    packSize: doc['packSize'] as String? ?? '',
    price: sellingPriceMinor / 100,
    purchasePriceMinor: (doc['purchasePrice'] as num?)?.toInt() ?? 0,
    requiresPrescription:
        (doc['prescriptionClass'] as String?) == 'prescription' ||
        (doc['requiresPrescription'] as bool? ?? false),
    imageUrl: doc['imagePath'] as String? ?? doc['imageUrl'] as String?,
    barcode: doc['barcode'] as String?,
    createdAt: _parseDate(doc['createdAt']),
    updatedAt: _parseDate(doc['updatedAt']),
  );
}

// -- Inventory batches + counters ---------------------------------------

/// Batch doc (§3 `branches/{branchId}/batches`). On create
/// `quantityReceived == quantityRemaining == quantity`; later
/// updates change only `quantityRemaining` (see the header note).
Map<String, dynamic> batchToFirestore(
  InventoryItem batch, {
  required String orgId,
  DateTime? now,
}) {
  final doc = stampNewDocument(
    {
      'medicineId': batch.medicineId,
      'batchNumber': batch.batchNo,
      'manufacturingDate': batch.mfgDate == null
          ? null
          : Timestamp.fromDate(batch.mfgDate!),
      'expiryDate': batch.expiryDate == null
          ? null
          : Timestamp.fromDate(batch.expiryDate!),
      'purchasePrice': batch.costMinor,
      'quantityReceived': batch.quantity,
      'quantityRemaining': batch.quantity,
      'status': batch.status.name,
      // Extra: needed to rebuild `isLowStock` on read.
      'lowStockThreshold': batch.lowStockThreshold,
    },
    orgId: orgId,
    branchId: batch.branchId,
    now: now,
  );
  validateOrThrow('branches/{branchId}/batches', doc);
  return doc;
}

InventoryItem batchFromFirestore(String id, Map<String, dynamic> doc) {
  return InventoryItem(
    id: id,
    medicineId: doc['medicineId'] as String? ?? '',
    branchId: doc['branchId'] as String? ?? '',
    quantity:
        (doc['quantityRemaining'] as num?)?.toInt() ??
        (doc['quantity'] as num?)?.toInt() ??
        0,
    lowStockThreshold: (doc['lowStockThreshold'] as num?)?.toInt() ?? 0,
    expiryDate: _parseDate(doc['expiryDate']),
    batchNo: doc['batchNumber'] as String? ?? doc['batchNo'] as String?,
    mfgDate: _parseDate(doc['manufacturingDate'] ?? doc['mfgDate']),
    costMinor:
        (doc['purchasePrice'] as num?)?.toInt() ??
        (doc['costMinor'] as num?)?.toInt() ??
        0,
    updatedAt: _parseDate(doc['updatedAt']),
    status: batchStatusFromString(doc['status'] as String?),
  );
}

/// Inventory counter doc (§3 `branches/{branchId}/counters`): one doc
/// per (branch, medicine) with on-hand + reserved quantities.
Map<String, dynamic> inventoryCounterToFirestore({
  required int quantityOnHand,
  required int quantityReserved,
}) {
  return {
    'quantityOnHand': quantityOnHand,
    'quantityReserved': quantityReserved,
  };
}

/// Counter value from a `counters/{id}` doc (`value` field, §3).
int counterValueFromFirestore(Map<String, dynamic>? doc) =>
    (doc?['value'] as num?)?.toInt() ?? 0;

// -- Customers + khata --------------------------------------------------

/// Customer doc (§3 `branches/{branchId}/customers`). The address
/// list is stored as an extra (`addresses`) so the local model
/// rebuilds exactly; `address` carries the first address for §3
/// readers.
Map<String, dynamic> customerToFirestore(
  Customer customer, {
  required String orgId,
  required String branchId,
  DateTime? now,
}) {
  final firstAddress = customer.addresses.isEmpty
      ? null
      : customer.addresses.first;
  final doc = stampNewDocument(
    {
      'name': customer.name,
      'phone': customer.phone,
      'address': firstAddress == null
          ? null
          : '${firstAddress.address}, ${firstAddress.city}',
      'creditLimit': customer.creditLimitMinor,
      'isActive': true,
      // Extra: the full address list, for an exact rebuild.
      'addresses': [for (final address in customer.addresses) address.toMap()],
    },
    orgId: orgId,
    branchId: branchId,
    now: now,
  );
  validateOrThrow('branches/{branchId}/customers', doc);
  return doc;
}

Customer customerFromFirestore(String id, Map<String, dynamic> doc) {
  final rawAddresses = doc['addresses'] as List<dynamic>? ?? [];
  var addresses = rawAddresses
      .whereType<Map<String, dynamic>>()
      .map(CustomerAddress.fromMap)
      .toList();
  if (addresses.isEmpty && (doc['address'] as String?)?.isNotEmpty == true) {
    addresses = [
      CustomerAddress(
        label: 'Address',
        address: doc['address'] as String,
        city: doc['city'] as String? ?? '',
      ),
    ];
  }
  return Customer(
    id: id,
    name: doc['name'] as String? ?? '',
    phone: doc['phone'] as String? ?? '',
    addresses: addresses,
    creditLimitMinor:
        (doc['creditLimit'] as num?)?.toInt() ??
        (doc['creditLimitMinor'] as num?)?.toInt() ??
        0,
    createdAt: _parseDate(doc['createdAt']),
  );
}

/// Khata entry doc (§3 `customers/{id}/ledger`): §3 names
/// `amount` / `balanceAfter`; `reason` is an extra (the statement
/// shows it). Append-only — never updated or deleted.
Map<String, dynamic> customerLedgerEntryToFirestore(
  LedgerEntry entry, {
  required String orgId,
  required String branchId,
  DateTime? now,
}) {
  final doc = stampNewDocument(
    {
      'type': entry.kind.name,
      'amount': entry.amountMinor,
      'referenceType': entry.kind == LedgerEntryKind.creditSale
          ? 'sale'
          : 'manual',
      'referenceId': entry.referenceId,
      'balanceAfter': entry.balanceAfterMinor,
      'reason': entry.reason,
      'customerId': entry.customerId,
    },
    orgId: orgId,
    branchId: branchId,
    now: now,
  );
  validateOrThrow('branches/{branchId}/customers/{customerId}/ledger', doc);
  return doc;
}

LedgerEntry customerLedgerEntryFromFirestore(
  String id,
  Map<String, dynamic> doc,
) {
  return LedgerEntry(
    id: id,
    customerId: doc['customerId'] as String? ?? '',
    kind: ledgerEntryKindFromString(doc['type'] as String?),
    amountMinor:
        (doc['amount'] as num?)?.toInt() ??
        (doc['amountMinor'] as num?)?.toInt() ??
        0,
    reason: doc['reason'] as String? ?? '',
    referenceId: doc['referenceId'] as String?,
    balanceAfterMinor:
        (doc['balanceAfter'] as num?)?.toInt() ??
        (doc['balanceAfterMinor'] as num?)?.toInt() ??
        0,
    createdAt: _parseDate(doc['createdAt']),
  );
}

// -- Suppliers + payables ledger ----------------------------------------

/// Supplier doc (§3 root `suppliers`).
Map<String, dynamic> supplierToFirestore(
  Supplier supplier, {
  required String orgId,
  DateTime? now,
}) {
  final doc = stampNewDocument(
    {
      'name': supplier.name,
      'contactPerson': supplier.contactPerson,
      'phone': supplier.phone,
      'email': supplier.email,
      'address': supplier.address,
      'taxNumber': supplier.taxNumber,
      'paymentTerms': supplier.paymentTerms,
      'isActive': supplier.isActive,
    },
    orgId: orgId,
    now: now,
  );
  validateOrThrow('suppliers', doc);
  return doc;
}

Supplier supplierFromFirestore(String id, Map<String, dynamic> doc) {
  return Supplier(
    id: id,
    name: doc['name'] as String? ?? '',
    contactPerson: doc['contactPerson'] as String? ?? '',
    phone: doc['phone'] as String? ?? '',
    email: doc['email'] as String?,
    address: doc['address'] as String?,
    taxNumber: doc['taxNumber'] as String?,
    paymentTerms: doc['paymentTerms'] as String?,
    isActive: doc['isActive'] as bool? ?? true,
  );
}

/// Supplier ledger entry doc (§3 `suppliers/{id}/ledger`).
/// Append-only, same pattern as the khata.
Map<String, dynamic> supplierLedgerEntryToFirestore(
  SupplierLedgerEntry entry, {
  required String orgId,
  DateTime? now,
}) {
  final doc = stampNewDocument(
    {
      'type': entry.kind.name,
      'amount': entry.amountMinor,
      'referenceType': switch (entry.kind) {
        SupplierLedgerEntryKind.purchase => 'purchase_order',
        SupplierLedgerEntryKind.payment => 'payment',
        SupplierLedgerEntryKind.purchaseReturn => 'purchase_return',
        SupplierLedgerEntryKind.adjustment => 'adjustment',
      },
      'referenceId': entry.referenceId,
      'balanceAfter': entry.balanceAfterMinor,
      'reason': entry.reason,
      'supplierId': entry.supplierId,
    },
    orgId: orgId,
    now: now,
  );
  validateOrThrow('suppliers/{supplierId}/ledger', doc);
  return doc;
}

SupplierLedgerEntry supplierLedgerEntryFromFirestore(
  String id,
  Map<String, dynamic> doc,
) {
  return SupplierLedgerEntry(
    id: id,
    supplierId: doc['supplierId'] as String? ?? '',
    kind: supplierLedgerEntryKindFromString(doc['type'] as String?),
    amountMinor:
        (doc['amount'] as num?)?.toInt() ??
        (doc['amountMinor'] as num?)?.toInt() ??
        0,
    reason: doc['reason'] as String? ?? '',
    referenceId: doc['referenceId'] as String?,
    balanceAfterMinor:
        (doc['balanceAfter'] as num?)?.toInt() ??
        (doc['balanceAfterMinor'] as num?)?.toInt() ??
        0,
    createdAt: _parseDate(doc['createdAt']),
  );
}

// -- Riders ---------------------------------------------------------------

/// Rider doc (§3 `branches/{branchId}/riders`): §3 `status` is a
/// string (`active` / `inactive`); `currentOrderId` is an extra.
Map<String, dynamic> riderToFirestore(
  Rider rider, {
  required String orgId,
  required String branchId,
  DateTime? now,
}) {
  final doc = stampNewDocument(
    {
      'name': rider.name,
      'phone': rider.phone,
      'vehicle': rider.vehicle,
      'status': rider.active ? 'active' : 'inactive',
      'currentOrderId': rider.currentOrderId,
    },
    orgId: orgId,
    branchId: branchId,
    now: now,
  );
  validateOrThrow('branches/{branchId}/riders', doc);
  return doc;
}

Rider riderFromFirestore(String id, Map<String, dynamic> doc) {
  return Rider(
    id: id,
    name: doc['name'] as String? ?? '',
    phone: doc['phone'] as String? ?? '',
    vehicle: doc['vehicle'] as String?,
    active:
        (doc['status'] as String? ?? 'active') != 'inactive' &&
        (doc['active'] as bool? ?? true),
    currentOrderId: doc['currentOrderId'] as String?,
    createdAt: _parseDate(doc['createdAt']),
  );
}

// -- Prescriptions --------------------------------------------------------

/// Prescription doc (§3 `branches/{branchId}/prescriptions`): §3
/// names (`reviewStatus`, `notes`) + the Storage metadata fields.
/// `imageUrl` is kept as an extra (demo display fallback).
Map<String, dynamic> prescriptionToFirestore(
  Prescription rx, {
  required String orgId,
  required String branchId,
  DateTime? now,
}) {
  final doc = stampNewDocument(
    {
      'customerId': rx.customerId,
      'orderId': rx.orderId,
      'photoStoragePath': rx.photoStoragePath,
      'photoContentType': rx.photoContentType,
      'photoUploadedAt': rx.photoUploadedAt == null
          ? null
          : Timestamp.fromDate(rx.photoUploadedAt!),
      'photoUploadedBy': rx.photoUploadedBy,
      'localPhotoPath': rx.localPhotoPath,
      'reviewStatus': rx.status.name,
      'reviewedBy': rx.reviewedBy,
      'reviewedAt': rx.reviewedAt == null
          ? null
          : Timestamp.fromDate(rx.reviewedAt!),
      'notes': rx.reviewNotes,
      'validUntil': rx.validUntil == null
          ? null
          : Timestamp.fromDate(rx.validUntil!),
      'resubmissionCount': rx.resubmissionCount,
      'imageUrl': rx.imageUrl,
      'medicinesText': rx.medicinesText,
    },
    orgId: orgId,
    branchId: branchId,
    now: now,
  );
  validateOrThrow('branches/{branchId}/prescriptions', doc);
  return doc;
}

Prescription prescriptionFromFirestore(String id, Map<String, dynamic> doc) {
  return Prescription(
    id: id,
    customerId: doc['customerId'] as String? ?? '',
    orderId: doc['orderId'] as String?,
    imageUrl: doc['imageUrl'] as String? ?? '',
    status: prescriptionStatusFromString(
      doc['reviewStatus'] as String? ?? doc['status'] as String?,
    ),
    reviewedBy: doc['reviewedBy'] as String?,
    reviewedAt: _parseDate(doc['reviewedAt']),
    reviewNotes: doc['notes'] as String? ?? doc['reviewNotes'] as String?,
    validUntil: _parseDate(doc['validUntil']),
    resubmissionCount: (doc['resubmissionCount'] as num?)?.toInt() ?? 0,
    branchId: doc['branchId'] as String?,
    photoStoragePath: doc['photoStoragePath'] as String?,
    photoContentType: doc['photoContentType'] as String?,
    photoUploadedAt: _parseDate(doc['photoUploadedAt']),
    photoUploadedBy: doc['photoUploadedBy'] as String?,
    localPhotoPath: doc['localPhotoPath'] as String?,
    medicinesText: doc['medicinesText'] as String?,
    createdAt: _parseDate(doc['createdAt']),
  );
}

// -- Purchase orders ------------------------------------------------------

/// PO status → §3 status (`partially_received` is snake_case in §3).
String purchaseOrderStatusToFirestore(PurchaseOrderStatus status) =>
    switch (status) {
      PurchaseOrderStatus.draft => 'draft',
      PurchaseOrderStatus.approved => 'approved',
      PurchaseOrderStatus.partiallyReceived => 'partially_received',
      PurchaseOrderStatus.received => 'received',
      PurchaseOrderStatus.cancelled => 'cancelled',
    };

PurchaseOrderStatus purchaseOrderStatusFromFirestore(String? value) =>
    switch (value) {
      'approved' => PurchaseOrderStatus.approved,
      'partially_received' => PurchaseOrderStatus.partiallyReceived,
      'received' => PurchaseOrderStatus.received,
      'cancelled' => PurchaseOrderStatus.cancelled,
      _ => PurchaseOrderStatus.draft,
    };

/// PO doc (§3 `branches/{branchId}/purchaseOrders`). Items live in
/// the `items` subcollection — never embedded in the doc.
/// [poNumber] is assigned by the repository counter first.
Map<String, dynamic> purchaseOrderToFirestore(
  PurchaseOrder order, {
  required String orgId,
  required String poNumber,
  DateTime? now,
}) {
  final doc = stampNewDocument(
    {
      'poNumber': poNumber,
      'supplierId': order.supplierId,
      'status': purchaseOrderStatusToFirestore(order.status),
      'totalAmount': order.totalMinor,
      'approvedBy': order.approvedBy,
      'notes': order.notes,
    },
    orgId: orgId,
    branchId: order.branchId,
    now: now,
  );
  validateOrThrow('branches/{branchId}/purchaseOrders', doc);
  return doc;
}

/// PO item doc (§3 `purchaseOrders/{poId}/items`).
Map<String, dynamic> purchaseOrderItemToFirestore(PurchaseOrderItem item) {
  return {
    'medicineId': item.medicineId,
    'medicineName': item.medicineName,
    'quantityOrdered': item.quantityOrdered,
    'quantityReceived': item.quantityReceived,
    'unitCostMinor': item.unitCostMinor,
  };
}

PurchaseOrder purchaseOrderFromFirestore(
  String id,
  Map<String, dynamic> doc, {
  List<Map<String, dynamic>> itemDocs = const [],
}) {
  return PurchaseOrder(
    id: id,
    poNumber: doc['poNumber'] as String? ?? '',
    supplierId: doc['supplierId'] as String? ?? '',
    branchId: doc['branchId'] as String? ?? '',
    status: purchaseOrderStatusFromFirestore(doc['status'] as String?),
    items: itemDocs.map(_purchaseOrderItemFromFirestore).toList(),
    approvedBy: doc['approvedBy'] as String?,
    notes: doc['notes'] as String?,
    createdAt: _parseDate(doc['createdAt']),
    updatedAt: _parseDate(doc['updatedAt']),
  );
}

PurchaseOrderItem _purchaseOrderItemFromFirestore(Map<String, dynamic> map) {
  return PurchaseOrderItem(
    medicineId: map['medicineId'] as String? ?? '',
    medicineName: map['medicineName'] as String? ?? '',
    quantityOrdered: (map['quantityOrdered'] as num?)?.toInt() ?? 0,
    quantityReceived: (map['quantityReceived'] as num?)?.toInt() ?? 0,
    unitCostMinor: (map['unitCostMinor'] as num?)?.toInt() ?? 0,
  );
}

// -- Shared ---------------------------------------------------------------

/// Parses a Firestore timestamp (or ISO string / epoch millis, for
/// JSON backups) into a [DateTime]. Accepts [Timestamp], [DateTime],
/// [int] and [String]; anything else is `null`.
DateTime? _parseDate(dynamic value) {
  if (value == null) return null;
  if (value is DateTime) return value;
  if (value is Timestamp) return value.toDate();
  if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
  if (value is String) return DateTime.tryParse(value);
  return null;
}
