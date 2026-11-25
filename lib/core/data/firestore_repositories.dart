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
import '../services/repositories.dart';
import 'firestore_mappers.dart';
import 'firestore_schema.dart';
import 'firestore_transport.dart';
import 'inventory_engine.dart' show WriteOperation, WriteOperationKind;

/// Firestore-backed repositories (Week 2 Day 3, D73).
///
/// The same interfaces the screens already use
/// (`core/services/repositories.dart`) — no screen rewrites. Each
/// class here talks to Firestore ONLY through a [FirestoreTransport],
/// so the whole set runs against the in-memory fake transport in
/// tests and against `cloud_firestore` in production
/// ([FirebaseFirestoreTransport]).
///
/// **Not live yet:** there is no Firebase project (D13), so these
/// classes have never talked to a real Firestore. The factory
/// (`repository_factory.dart`) keeps the app on the mocks until the
/// project exists; flipping the switch is a provider override.
/// Live verification (rules unit tests, emulator runs) is still open.
///
/// Conventions, per SRS §3 and `firestore_schema.dart`:
///
/// - **Paths** come from [FirestoreSchema] (branch subcollections
///   under `branches/{branchId}/`, root collections for the
///   catalogue / suppliers / users).
/// - **Doc id = idempotency key** for sales (the sale's key) and
///   orders / POs (the caller-supplied client id, D65). Creating
///   with an existing key returns the existing document — a retry
///   can never duplicate.
/// - **Sequential numbers** (invoice / order / PO) come from counter
///   docs (`branches/{branchId}/counters/{invoices|orders|
///   purchaseOrders}`), incremented in a transaction. A reserved
///   number whose batch write then fails leaves a *gap*, never a
///   duplicate — gaps are acceptable, duplicates are not.
/// - **Batched writes chunked ≤500**: multi-doc writes go through
///   [FirestoreTransport.runBatchedWrites], which chunks.
/// - **Paginated reads**: list methods page through the collection
///   (200 docs per page internally); the `*Page` methods expose
///   explicit pages (default 50) for screens that page.
/// - **Append-only ledgers**: entries are created, never updated or
///   deleted; `balanceAfter` is computed from the current sum.
/// - **Branch scoping**: branch-scoped reads need a branch id. When
///   the interface call passes none, the repository enumerates the
///   org's branches (one `branches` list read) and fans out — the
///   mock returns everything in one list, and this preserves that
///   semantic at 8-branch scale. `getById` searches branches the
///   same way when the branch is unknown.
/// - **Client-side filters** where Firestore cannot compare two
///   fields: low-stock (`quantity <= lowStockThreshold`) and
///   expiring-within are filtered after the branch fetch.
/// - **No hard deletes**: update methods rewrite documents; item
///   subcollections are rewritten by index and trailing stale item
///   docs are removed via batch deletes (the only deletes in this
///   file — subcollection maintenance, not document deletion).

/// Page size for the internal fetch-all loop.
const _fetchPageSize = 200;

/// Sequential counter documents (`branches/{branchId}/counters/*`).
const _invoicesCounterId = 'invoices';
const _ordersCounterId = 'orders';
const _purchaseOrdersCounterId = 'purchaseOrders';

/// Shared helpers for the Firestore repositories.
mixin _FirestoreRepositoryHelper {
  FirestoreTransport get transport;
  String get organizationId;

  /// Branch ids in this org (one `branches` list read).
  Future<List<String>> branchIds() async {
    final docs = await transport.queryCollection(
      FirestoreSchema.branches,
      orderBy: 'name',
    );
    return [for (final doc in docs) doc.id];
  }

  /// Fetches a whole collection by paging (200 docs per page).
  Future<List<FirestoreDocument>> fetchAll(
    String collectionPath, {
    Map<String, Object?> whereEquals = const {},
    String? orderBy,
  }) async {
    final all = <FirestoreDocument>[];
    String? startAfterId;
    while (true) {
      final page = await transport.queryCollection(
        collectionPath,
        whereEquals: whereEquals,
        orderBy: orderBy,
        limit: _fetchPageSize,
        startAfterId: startAfterId,
      );
      all.addAll(page);
      if (page.length < _fetchPageSize) break;
      startAfterId = page.last.id;
    }
    return all;
  }

  /// Finds a branch-scoped document by id, searching branches in
  /// order. Returns the (branchId, document) pair, or `null`.
  Future<({String branchId, FirestoreDocument doc})?> findInBranches(
    String subcollection,
    String docId,
  ) async {
    for (final branchId in await branchIds()) {
      final data = await transport.getDocument(
        FirestoreSchema.branchDocPath(branchId, subcollection, docId),
      );
      if (data != null) {
        return (
          branchId: branchId,
          doc: FirestoreDocument(id: docId, data: data),
        );
      }
    }
    return null;
  }

  /// Atomically reserves the next sequential number for [counterId]
  /// in [branchId] (starting at 1001). Returns the new value.
  Future<int> nextCounterValue(String branchId, String counterId) async {
    final path = FirestoreSchema.counterDocPath(branchId, counterId);
    return transport.runTransaction((tx) async {
      final current = await tx.get(path);
      final next = counterValueFromFirestore(current) + 1;
      // Counters start at 1001 (same as the mock sequences).
      final value = next < 1001 ? 1001 : next;
      tx.set(path, {
        'value': value,
        'organizationId': organizationId,
        'branchId': branchId,
      });
      return value;
    });
  }

  /// Branch code for sequential numbers (`INV-DHA-1001`): the
  /// branch doc's `code` field when present, else a demo fallback
  /// derived from the branch id.
  final Map<String, String> _branchCodes = {};

  Future<String> branchCode(String branchId) async {
    final cached = _branchCodes[branchId];
    if (cached != null) return cached;
    final doc = await transport.getDocument(
      FirestoreSchema.branchDoc(branchId),
    );
    var code = doc?['code'] as String?;
    code ??= _fallbackBranchCode(branchId);
    _branchCodes[branchId] = code;
    return code;
  }

  static String _fallbackBranchCode(String branchId) {
    if (branchId.contains('dha')) return 'DHA';
    if (branchId.contains('gulberg') || branchId.contains('glb')) {
      return 'GLB';
    }
    final segments = branchId.split('-').where((s) => s.isNotEmpty);
    final last = segments.isEmpty ? branchId : segments.last;
    return last.length >= 3
        ? last.substring(0, 3).toUpperCase()
        : last.toUpperCase();
  }
}

// -- Medicines ------------------------------------------------------------

class FirestoreMedicineRepository
    with _FirestoreRepositoryHelper
    implements MedicineRepository {
  FirestoreMedicineRepository({
    required this.transport,
    required this.organizationId,
  });

  @override
  final FirestoreTransport transport;
  @override
  final String organizationId;

  /// One explicit page of the catalogue (document-id order).
  Future<({List<Medicine> items, String? lastId, bool hasMore})>
  getMedicinesPage({int pageSize = 50, String? startAfterId}) async {
    final docs = await transport.queryCollection(
      FirestoreSchema.medicines,
      limit: pageSize,
      startAfterId: startAfterId,
    );
    return (
      items: [for (final doc in docs) medicineFromFirestore(doc.id, doc.data)],
      lastId: docs.isEmpty ? null : docs.last.id,
      hasMore: docs.length == pageSize,
    );
  }

  @override
  Future<List<Medicine>> getMedicines({String? branchId}) async {
    // The catalogue is org-wide; the branch filter is accepted for
    // interface compatibility and ignored (as in the mock).
    final docs = await fetchAll(FirestoreSchema.medicines);
    return [for (final doc in docs) medicineFromFirestore(doc.id, doc.data)];
  }

  @override
  Future<Medicine?> getById(String id) async {
    final data = await transport.getDocument(
      '${FirestoreSchema.medicines}/$id',
    );
    if (data == null) return null;
    return medicineFromFirestore(id, data);
  }

  @override
  Future<Medicine?> getByBarcode(String barcode) async {
    final needle = barcode.trim();
    if (needle.isEmpty) return null;
    final docs = await transport.queryCollection(
      FirestoreSchema.medicines,
      whereEquals: {'barcode': needle},
      limit: 1,
    );
    if (docs.isEmpty) return null;
    return medicineFromFirestore(docs.first.id, docs.first.data);
  }
}

// -- Orders ---------------------------------------------------------------

class FirestoreOrderRepository
    with _FirestoreRepositoryHelper
    implements OrderRepository {
  FirestoreOrderRepository({
    required this.transport,
    required this.organizationId,
  });

  @override
  final FirestoreTransport transport;
  @override
  final String organizationId;

  /// One explicit page of a branch's orders (document-id order).
  Future<({List<Order> items, String? lastId, bool hasMore})> getOrdersPage({
    required String branchId,
    int pageSize = 50,
    String? startAfterId,
  }) async {
    final docs = await transport.queryCollection(
      FirestoreSchema.ordersPath(branchId),
      limit: pageSize,
      startAfterId: startAfterId,
    );
    final items = <Order>[];
    for (final doc in docs) {
      items.add(await _withItems(branchId, doc));
    }
    return (
      items: items,
      lastId: docs.isEmpty ? null : docs.last.id,
      hasMore: docs.length == pageSize,
    );
  }

  Future<Order> _withItems(String branchId, FirestoreDocument doc) async {
    final itemDocs = await fetchAll(
      FirestoreSchema.nestedCollection(
        branchId,
        FirestoreSchema.orders,
        doc.id,
        FirestoreSchema.orderItems,
      ),
    );
    return orderFromFirestore(
      doc.id,
      doc.data,
      itemDocs: [for (final item in itemDocs) item.data],
    );
  }

  @override
  Future<List<Order>> getOrders({String? branchId}) async {
    final branches = branchId == null ? await branchIds() : [branchId];
    final orders = <Order>[];
    for (final id in branches) {
      final docs = await fetchAll(FirestoreSchema.ordersPath(id));
      for (final doc in docs) {
        orders.add(await _withItems(id, doc));
      }
    }
    return orders;
  }

  @override
  Future<Order?> getById(String id) async {
    final found = await findInBranches(FirestoreSchema.orders, id);
    if (found == null) return null;
    return _withItems(found.branchId, found.doc);
  }

  @override
  Future<void> updateStatus(String id, OrderStatus status) async {
    final found = await findInBranches(FirestoreSchema.orders, id);
    if (found == null) return;
    await transport.updateDocument(
      FirestoreSchema.orderDocPath(found.branchId, id),
      stampUpdate({'status': orderStatusToFirestore(status)}),
    );
  }

  @override
  Future<Order> createOrder(Order order) async {
    final docId = order.id.isNotEmpty
        ? order.id
        : transport.newDocumentId(FirestoreSchema.ordersPath(order.branchId));
    // Client id = doc id (D65 pattern): a retry returns the original.
    final existing = await transport.getDocument(
      FirestoreSchema.orderDocPath(order.branchId, docId),
    );
    if (existing != null) {
      return _withItems(
        order.branchId,
        FirestoreDocument(id: docId, data: existing),
      );
    }
    final sequence = await nextCounterValue(order.branchId, _ordersCounterId);
    final code = await branchCode(order.branchId);
    final doc = orderToFirestore(
      order,
      orgId: organizationId,
      orderNumber: 'ORD-$code-$sequence',
      idempotencyKey: docId,
    );
    final operations = <WriteOperation>[
      WriteOperation(
        path: FirestoreSchema.orderDocPath(order.branchId, docId),
        kind: WriteOperationKind.set,
        data: doc,
      ),
      for (var i = 0; i < order.items.length; i++)
        WriteOperation(
          path:
              '${FirestoreSchema.nestedCollection(order.branchId, FirestoreSchema.orders, docId, FirestoreSchema.orderItems)}/item-$i',
          kind: WriteOperationKind.set,
          data: orderItemToFirestore(order.items[i]),
        ),
    ];
    await transport.runBatchedWrites(operations);
    return order.copyWith(id: docId);
  }

  @override
  Future<void> updateOrder(Order order) async {
    final found = await findInBranches(FirestoreSchema.orders, order.id);
    if (found == null) return;
    final branchId = found.branchId;
    final itemsPath = FirestoreSchema.nestedCollection(
      branchId,
      FirestoreSchema.orders,
      order.id,
      FirestoreSchema.orderItems,
    );
    final existingItems = await fetchAll(itemsPath);
    final doc = orderToFirestore(
      order,
      orgId: organizationId,
      orderNumber: found.doc.data['orderNumber'] as String? ?? order.id,
      idempotencyKey: found.doc.data['idempotencyKey'] as String? ?? order.id,
    );
    // A rewrite keeps the original `createdAt` (the mapper stamps
    // "now" — that is only correct for creates).
    doc['createdAt'] = found.doc.data['createdAt'];
    final operations = <WriteOperation>[
      WriteOperation(
        path: FirestoreSchema.orderDocPath(branchId, order.id),
        kind: WriteOperationKind.set,
        data: doc,
      ),
      for (var i = 0; i < order.items.length; i++)
        WriteOperation(
          path: '$itemsPath/item-$i',
          kind: WriteOperationKind.set,
          data: orderItemToFirestore(order.items[i]),
        ),
      // Trailing stale item docs from a shrunk list are removed.
      for (var i = order.items.length; i < existingItems.length; i++)
        WriteOperation(
          path: '$itemsPath/${existingItems[i].id}',
          kind: WriteOperationKind.delete,
        ),
    ];
    await transport.runBatchedWrites(operations);
  }
}

// -- Inventory ------------------------------------------------------------

class FirestoreInventoryRepository
    with _FirestoreRepositoryHelper
    implements InventoryRepository {
  FirestoreInventoryRepository({
    required this.transport,
    required this.organizationId,
  });

  @override
  final FirestoreTransport transport;
  @override
  final String organizationId;

  /// One explicit page of a branch's batch rows.
  Future<({List<InventoryItem> items, String? lastId, bool hasMore})>
  getInventoryPage({
    required String branchId,
    int pageSize = 50,
    String? startAfterId,
  }) async {
    final docs = await transport.queryCollection(
      FirestoreSchema.batchesPath(branchId),
      limit: pageSize,
      startAfterId: startAfterId,
    );
    return (
      items: [for (final doc in docs) batchFromFirestore(doc.id, doc.data)],
      lastId: docs.isEmpty ? null : docs.last.id,
      hasMore: docs.length == pageSize,
    );
  }

  @override
  Future<List<InventoryItem>> getInventory({String? branchId}) async {
    final branches = branchId == null ? await branchIds() : [branchId];
    final items = <InventoryItem>[];
    for (final id in branches) {
      final docs = await fetchAll(FirestoreSchema.batchesPath(id));
      items.addAll([
        for (final doc in docs) batchFromFirestore(doc.id, doc.data),
      ]);
    }
    return items;
  }

  @override
  Future<List<InventoryItem>> getLowStock({String? branchId}) async {
    // Firestore cannot compare two fields (`quantity` <=
    // `lowStockThreshold`), so this filters after the branch fetch.
    final items = await getInventory(branchId: branchId);
    return items.where((item) => item.isLowStock).toList();
  }

  @override
  Future<List<InventoryItem>> getExpiringWithin({
    int days = 30,
    String? branchId,
  }) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final limit = today.add(Duration(days: days));
    final items = await getInventory(branchId: branchId);
    return items.where((item) {
      final expiry = item.expiryDate;
      if (expiry == null) return false;
      final expiryDay = DateTime(expiry.year, expiry.month, expiry.day);
      return !expiryDay.isBefore(today) && !expiryDay.isAfter(limit);
    }).toList();
  }

  @override
  Future<InventoryItem> receiveStock({
    required String branchId,
    required String medicineId,
    required String batchNo,
    required DateTime mfgDate,
    required DateTime expiryDate,
    required int quantity,
    required int costMinor,
  }) async {
    if (quantity <= 0) {
      throw ArgumentError('Received quantity must be above zero.');
    }
    if (costMinor < 0) {
      throw ArgumentError('Cost price cannot be negative.');
    }
    if (!expiryDate.isAfter(mfgDate)) {
      throw ArgumentError('Expiry date must be after the manufacture date.');
    }
    final created = InventoryItem(
      id: '',
      medicineId: medicineId,
      branchId: branchId,
      quantity: quantity,
      lowStockThreshold: 10,
      batchNo: batchNo,
      expiryDate: expiryDate,
      mfgDate: mfgDate,
      costMinor: costMinor,
      status: BatchStatus.available,
      updatedAt: DateTime.now(),
    );
    final batchId = transport.newDocumentId(
      FirestoreSchema.batchesPath(branchId),
    );
    final batchPath = FirestoreSchema.branchDocPath(
      branchId,
      FirestoreSchema.batches,
      batchId,
    );
    final stockTxId = transport.newDocumentId(
      FirestoreSchema.stockTransactionsPath(branchId),
    );
    await transport.runTransaction((tx) async {
      tx.set(batchPath, batchToFirestore(created, orgId: organizationId));
      await _applyCounterDelta(tx, branchId, medicineId, quantity);
      tx.set(
        '${FirestoreSchema.stockTransactionsPath(branchId)}/$stockTxId',
        stampNewDocument(
          {
            'medicineId': medicineId,
            'batchId': batchId,
            'type': 'receive',
            'quantity': quantity,
            'unitCost': costMinor,
            'referenceType': 'purchase_order',
            'reason': 'Goods received',
          },
          orgId: organizationId,
          branchId: branchId,
        ),
      );
    });
    return created.copyWith(id: batchId);
  }

  @override
  Future<InventoryItem> adjustStock({
    required String batchId,
    required int deltaQty,
    required String reason,
  }) async {
    if (deltaQty == 0) {
      throw ArgumentError('Adjustment quantity cannot be zero.');
    }
    if (reason.trim().isEmpty) {
      throw ArgumentError('An adjustment reason is required.');
    }
    return _mutateBatch(
      batchId: batchId,
      reason: reason,
      transactionType: 'adjustment',
      computeNewQuantity: (old) {
        final next = old.quantity + deltaQty;
        if (next < 0) {
          throw ArgumentError(
            'Cannot remove $deltaQty units — only ${old.quantity} on hand.',
          );
        }
        return next;
      },
      signedQuantity: deltaQty,
    );
  }

  @override
  Future<InventoryItem> recordStockCount({
    required String batchId,
    required int countedQty,
    String? note,
  }) async {
    if (countedQty < 0) {
      throw ArgumentError('Counted quantity cannot be negative.');
    }
    return _mutateBatch(
      batchId: batchId,
      reason: note?.trim().isEmpty ?? true ? 'Stock count' : note!.trim(),
      transactionType: 'adjustment',
      computeNewQuantity: (_) => countedQty,
      signedQuantityBuilder: (old) => countedQty - old.quantity,
    );
  }

  /// Reads a batch, recomputes its quantity, writes the batch +
  /// counter delta + append-only stock transaction in one
  /// transaction. Returns the updated row.
  Future<InventoryItem> _mutateBatch({
    required String batchId,
    required String reason,
    required String transactionType,
    required int Function(InventoryItem old) computeNewQuantity,
    int? signedQuantity,
    int Function(InventoryItem old)? signedQuantityBuilder,
  }) async {
    final found = await findInBranches(FirestoreSchema.batches, batchId);
    if (found == null) {
      throw ArgumentError('No batch with id "$batchId".');
    }
    final branchId = found.branchId;
    final old = batchFromFirestore(found.doc.id, found.doc.data);
    final newQuantity = computeNewQuantity(old);
    final signed = signedQuantity ?? signedQuantityBuilder!(old);
    final batchPath = FirestoreSchema.branchDocPath(
      branchId,
      FirestoreSchema.batches,
      batchId,
    );
    final stockTxId = transport.newDocumentId(
      FirestoreSchema.stockTransactionsPath(branchId),
    );
    await transport.runTransaction((tx) async {
      tx.update(batchPath, {
        'quantityRemaining': newQuantity,
        'updatedAt': Timestamp.fromDate(DateTime.now()),
      });
      await _applyCounterDelta(tx, branchId, old.medicineId, signed);
      tx.set(
        '${FirestoreSchema.stockTransactionsPath(branchId)}/$stockTxId',
        stampNewDocument(
          {
            'medicineId': old.medicineId,
            'batchId': batchId,
            'type': transactionType,
            'quantity': signed,
            'unitCost': old.costMinor,
            'referenceType': transactionType,
            'reason': reason,
          },
          orgId: organizationId,
          branchId: branchId,
        ),
      );
    });
    return old.copyWith(quantity: newQuantity, updatedAt: DateTime.now());
  }

  /// Applies a signed on-hand delta to the per-(branch, medicine)
  /// inventory counter doc inside [tx] (creates it at zero first).
  Future<void> _applyCounterDelta(
    FirestoreTransaction tx,
    String branchId,
    String medicineId,
    int delta,
  ) async {
    final path = FirestoreSchema.inventoryDocPath(branchId, medicineId);
    final current = await tx.get(path);
    final onHand = (current?['quantityOnHand'] as num?)?.toInt() ?? 0;
    final reserved = (current?['quantityReserved'] as num?)?.toInt() ?? 0;
    tx.set(path, {
      ...inventoryCounterToFirestore(
        quantityOnHand: onHand + delta,
        quantityReserved: reserved,
      ),
      'organizationId': organizationId,
      'branchId': branchId,
      'updatedAt': Timestamp.fromDate(DateTime.now()),
    });
  }
}

// -- Customers + khata ----------------------------------------------------

class FirestoreCustomerRepository
    with _FirestoreRepositoryHelper
    implements CustomerRepository {
  FirestoreCustomerRepository({
    required this.transport,
    required this.organizationId,
  });

  @override
  final FirestoreTransport transport;
  @override
  final String organizationId;

  @override
  Future<List<Customer>> getCustomers() async {
    final customers = <Customer>[];
    for (final branchId in await branchIds()) {
      final docs = await fetchAll(
        FirestoreSchema.branchCollection(branchId, FirestoreSchema.customers),
      );
      customers.addAll([
        for (final doc in docs) customerFromFirestore(doc.id, doc.data),
      ]);
    }
    return customers;
  }

  @override
  Future<Customer?> getById(String id) async {
    final found = await findInBranches(FirestoreSchema.customers, id);
    if (found == null) return null;
    return customerFromFirestore(found.doc.id, found.doc.data);
  }

  @override
  Future<Customer> createCustomer(Customer customer, {String? branchId}) async {
    final branch =
        branchId ??
        (throw ArgumentError(
          'A branchId is required to create a customer in Firestore.',
        ));
    final digits = _phoneDigits(customer.phone);
    if (digits.isEmpty) {
      throw ArgumentError('A phone number is required.');
    }
    // Phone uniqueness is org-wide: check every branch's customers.
    for (final id in await branchIds()) {
      final matches = await transport.queryCollection(
        FirestoreSchema.branchCollection(id, FirestoreSchema.customers),
        whereEquals: {'phone': customer.phone.trim()},
        limit: 1,
      );
      if (matches.isNotEmpty) {
        throw ArgumentError(
          'A customer with phone ${customer.phone} already exists.',
        );
      }
    }
    final id = await transport.addDocument(
      FirestoreSchema.branchCollection(branch, FirestoreSchema.customers),
      customerToFirestore(customer, orgId: organizationId, branchId: branch),
    );
    return customer.copyWith(id: id, createdAt: DateTime.now());
  }

  @override
  Future<List<LedgerEntry>> getLedgerEntries(String customerId) async {
    final found = await findInBranches(FirestoreSchema.customers, customerId);
    if (found == null) return const [];
    final docs = await fetchAll(
      FirestoreSchema.customerLedgerPath(found.branchId, customerId),
      orderBy: 'createdAt',
    );
    return [
      for (final doc in docs)
        customerLedgerEntryFromFirestore(doc.id, doc.data),
    ];
  }

  @override
  Future<LedgerEntry> addLedgerEntry(LedgerEntry entry) async {
    if (entry.amountMinor == 0) {
      throw ArgumentError('A ledger entry amount cannot be zero.');
    }
    final found = await findInBranches(
      FirestoreSchema.customers,
      entry.customerId,
    );
    if (found == null) {
      throw ArgumentError('No customer with id "${entry.customerId}".');
    }
    final branchId = found.branchId;
    final existing = await getLedgerEntries(entry.customerId);
    final outstanding = existing.fold(0, (total, e) => total + e.amountMinor);
    final withBalance = entry.copyWith(
      balanceAfterMinor: outstanding + entry.amountMinor,
      createdAt: DateTime.now(),
    );
    final id = await transport.addDocument(
      FirestoreSchema.customerLedgerPath(branchId, entry.customerId),
      customerLedgerEntryToFirestore(
        withBalance,
        orgId: organizationId,
        branchId: branchId,
      ),
    );
    return withBalance.copyWith(id: id);
  }

  static String _phoneDigits(String phone) =>
      phone.replaceAll(RegExp(r'[^0-9]'), '');
}

// -- Sales ----------------------------------------------------------------

class FirestoreSaleRepository
    with _FirestoreRepositoryHelper
    implements SaleRepository {
  FirestoreSaleRepository({
    required this.transport,
    required this.organizationId,
  });

  @override
  final FirestoreTransport transport;
  @override
  final String organizationId;

  /// One explicit page of a branch's sales (document-id order).
  Future<({List<Sale> items, String? lastId, bool hasMore})> getSalesPage({
    required String branchId,
    int pageSize = 50,
    String? startAfterId,
  }) async {
    final docs = await transport.queryCollection(
      FirestoreSchema.salesPath(branchId),
      limit: pageSize,
      startAfterId: startAfterId,
    );
    final items = <Sale>[];
    for (final doc in docs) {
      items.add(await _withItems(branchId, doc));
    }
    return (
      items: items,
      lastId: docs.isEmpty ? null : docs.last.id,
      hasMore: docs.length == pageSize,
    );
  }

  Future<Sale> _withItems(String branchId, FirestoreDocument doc) async {
    final itemDocs = await fetchAll(
      FirestoreSchema.saleItemsPath(branchId, doc.id),
    );
    return saleFromFirestore(
      doc.id,
      doc.data,
      itemDocs: [for (final item in itemDocs) item.data],
    );
  }

  @override
  Future<List<Sale>> getSales({String? branchId}) async {
    final branches = branchId == null ? await branchIds() : [branchId];
    final sales = <Sale>[];
    for (final id in branches) {
      final docs = await fetchAll(FirestoreSchema.salesPath(id));
      for (final doc in docs) {
        sales.add(await _withItems(id, doc));
      }
    }
    return sales;
  }

  @override
  Future<Sale?> getById(String id) async {
    final found = await findInBranches(FirestoreSchema.sales, id);
    if (found == null) return null;
    return _withItems(found.branchId, found.doc);
  }

  @override
  Future<Sale> createSale(Sale sale) async {
    final key = sale.idempotencyKey;
    if (!FirestoreSchema.isValidIdempotencyKey(key)) {
      throw ArgumentError('Sale has no valid idempotency key.');
    }
    // Doc id = idempotency key (SRS §2.5): a retry returns the
    // original sale — no duplicate, no second stock movement.
    final existing = await transport.getDocument(
      FirestoreSchema.saleDocPath(sale.branchId, key),
    );
    if (existing != null) {
      return _withItems(
        sale.branchId,
        FirestoreDocument(id: key, data: existing),
      );
    }
    final sequence = await nextCounterValue(sale.branchId, _invoicesCounterId);
    final code = await branchCode(sale.branchId);
    final stamped = sale.copyWith(
      id: key,
      invoiceNumber: 'INV-$code-$sequence',
      createdAt: DateTime.now(),
    );
    final operations = <WriteOperation>[
      WriteOperation(
        path: FirestoreSchema.saleDocPath(sale.branchId, key),
        kind: WriteOperationKind.set,
        data: saleToFirestore(stamped, orgId: organizationId),
      ),
      for (var i = 0; i < stamped.items.length; i++)
        WriteOperation(
          path: '${FirestoreSchema.saleItemsPath(sale.branchId, key)}/item-$i',
          kind: WriteOperationKind.set,
          data: saleItemToFirestore(stamped.items[i]),
        ),
      // Settled payments live in the payments subcollection; a
      // credit sale has no payment doc (the khata entry is the
      // record of what is owed).
      if (!stamped.isCredit)
        WriteOperation(
          path:
              '${FirestoreSchema.nestedCollection(sale.branchId, FirestoreSchema.sales, key, FirestoreSchema.salePayments)}/payment-0',
          kind: WriteOperationKind.set,
          data: salePaymentToFirestore(
            method: stamped.paymentMethod,
            amountMinor: stamped.paymentMethod == SalePaymentMethod.cash
                ? stamped.cashReceivedMinor
                : stamped.totalMinor,
          ),
        ),
    ];
    await transport.runBatchedWrites(operations);
    return stamped;
  }

  @override
  Future<void> updateSale(Sale sale) async {
    // Only the lifecycle status changes after a sale is saved
    // (returns, FR-POS-08) — the invoice number, totals and
    // idempotency key are immutable history, so a merge update of
    // the status field is the whole write.
    await transport.updateDocument(
      FirestoreSchema.saleDocPath(sale.branchId, sale.id),
      {'status': saleStatusToFirestore(sale.status)},
    );
  }
}

// -- Sale returns ---------------------------------------------------------

class FirestoreSaleReturnRepository
    with _FirestoreRepositoryHelper
    implements SaleReturnRepository {
  FirestoreSaleReturnRepository({
    required this.transport,
    required this.organizationId,
  });

  @override
  final FirestoreTransport transport;
  @override
  final String organizationId;

  Future<SaleReturn> _withItems(
    String branchId,
    FirestoreDocument doc,
  ) async {
    final itemDocs = await fetchAll(
      FirestoreSchema.saleReturnItemsPath(branchId, doc.id),
    );
    return saleReturnFromFirestore(
      doc.id,
      doc.data,
      itemDocs: [for (final item in itemDocs) item.data],
    );
  }

  @override
  Future<List<SaleReturn>> getReturns({String? branchId}) async {
    final branches = branchId == null ? await branchIds() : [branchId];
    final returns = <SaleReturn>[];
    for (final id in branches) {
      final docs = await fetchAll(FirestoreSchema.saleReturnsPath(id));
      for (final doc in docs) {
        returns.add(await _withItems(id, doc));
      }
    }
    return returns;
  }

  @override
  Future<List<SaleReturn>> getReturnsForSale(String saleId) async {
    final all = await getReturns();
    return all.where((r) => r.saleId == saleId).toList();
  }

  @override
  Future<SaleReturn> createReturn(SaleReturn saleReturn) async {
    final returnId = transport.newDocumentId(
      FirestoreSchema.saleReturnsPath(saleReturn.branchId),
    );
    final stamped = saleReturn.copyWith(
      id: returnId,
      createdAt: DateTime.now(),
    );
    final operations = <WriteOperation>[
      WriteOperation(
        path: FirestoreSchema.saleReturnDocPath(
          saleReturn.branchId,
          returnId,
        ),
        kind: WriteOperationKind.set,
        data: saleReturnToFirestore(stamped, orgId: organizationId),
      ),
      for (var i = 0; i < stamped.items.length; i++)
        WriteOperation(
          path:
              '${FirestoreSchema.saleReturnItemsPath(saleReturn.branchId, returnId)}/item-$i',
          kind: WriteOperationKind.set,
          data: saleReturnItemToFirestore(stamped.items[i]),
        ),
    ];
    await transport.runBatchedWrites(operations);
    return stamped;
  }
}

// -- Suppliers + payables ledger ------------------------------------------

class FirestoreSupplierRepository
    with _FirestoreRepositoryHelper
    implements SupplierRepository {
  FirestoreSupplierRepository({
    required this.transport,
    required this.organizationId,
  });

  @override
  final FirestoreTransport transport;
  @override
  final String organizationId;

  @override
  Future<List<Supplier>> getSuppliers() async {
    final docs = await fetchAll(FirestoreSchema.suppliers);
    return [for (final doc in docs) supplierFromFirestore(doc.id, doc.data)];
  }

  @override
  Future<Supplier?> getById(String id) async {
    final data = await transport.getDocument(
      '${FirestoreSchema.suppliers}/$id',
    );
    if (data == null) return null;
    return supplierFromFirestore(id, data);
  }

  @override
  Future<Supplier> createSupplier(Supplier supplier) async {
    final digits = _phoneDigits(supplier.phone);
    if (digits.isEmpty) {
      throw ArgumentError('A phone number is required.');
    }
    final matches = await transport.queryCollection(
      FirestoreSchema.suppliers,
      whereEquals: {'phone': supplier.phone.trim()},
      limit: 1,
    );
    if (matches.isNotEmpty) {
      throw ArgumentError(
        'A supplier with phone ${supplier.phone} already exists.',
      );
    }
    final id = await transport.addDocument(
      FirestoreSchema.suppliers,
      supplierToFirestore(supplier, orgId: organizationId),
    );
    return supplier.copyWith(id: id);
  }

  @override
  Future<void> updateSupplier(Supplier supplier) async {
    final data = await transport.getDocument(
      '${FirestoreSchema.suppliers}/${supplier.id}',
    );
    if (data == null) return;
    // Merge-update: keep the original `createdAt`, refresh `updatedAt`.
    final doc = supplierToFirestore(supplier, orgId: organizationId)
      ..remove('createdAt');
    await transport.setDocument(
      '${FirestoreSchema.suppliers}/${supplier.id}',
      doc,
      merge: true,
    );
  }

  @override
  Future<List<SupplierLedgerEntry>> getLedgerEntries(String supplierId) async {
    final docs = await fetchAll(
      FirestoreSchema.supplierLedgerPath(supplierId),
      orderBy: 'createdAt',
    );
    return [
      for (final doc in docs)
        supplierLedgerEntryFromFirestore(doc.id, doc.data),
    ];
  }

  @override
  Future<SupplierLedgerEntry> addLedgerEntry(SupplierLedgerEntry entry) async {
    if (entry.amountMinor == 0) {
      throw ArgumentError('A ledger entry amount cannot be zero.');
    }
    final existing = await getLedgerEntries(entry.supplierId);
    final outstanding = existing.fold(0, (total, e) => total + e.amountMinor);
    final withBalance = entry.copyWith(
      balanceAfterMinor: outstanding + entry.amountMinor,
      createdAt: DateTime.now(),
    );
    final id = await transport.addDocument(
      FirestoreSchema.supplierLedgerPath(entry.supplierId),
      supplierLedgerEntryToFirestore(withBalance, orgId: organizationId),
    );
    return withBalance.copyWith(id: id);
  }

  static String _phoneDigits(String phone) =>
      phone.replaceAll(RegExp(r'[^0-9]'), '');
}

// -- Prescriptions --------------------------------------------------------

class FirestorePrescriptionRepository
    with _FirestoreRepositoryHelper
    implements PrescriptionRepository {
  FirestorePrescriptionRepository({
    required this.transport,
    required this.organizationId,
  });

  @override
  final FirestoreTransport transport;
  @override
  final String organizationId;

  @override
  Future<List<Prescription>> getPrescriptions({String? branchId}) async {
    final branches = branchId == null ? await branchIds() : [branchId];
    final records = <Prescription>[];
    for (final id in branches) {
      final docs = await fetchAll(
        FirestoreSchema.branchCollection(id, FirestoreSchema.prescriptions),
      );
      records.addAll([
        for (final doc in docs) prescriptionFromFirestore(doc.id, doc.data),
      ]);
    }
    return records;
  }

  @override
  Future<List<Prescription>> getPending({String? branchId}) async {
    final records = await getPrescriptions(branchId: branchId);
    return records
        .where((rx) => rx.status == PrescriptionStatus.pending)
        .toList();
  }

  @override
  Future<Prescription?> getById(String id) async {
    final found = await findInBranches(FirestoreSchema.prescriptions, id);
    if (found == null) return null;
    return prescriptionFromFirestore(found.doc.id, found.doc.data);
  }

  @override
  Future<Prescription?> reviewPrescription({
    required String id,
    required PrescriptionStatus status,
    required String reviewedBy,
    String? reviewNotes,
  }) async {
    final found = await findInBranches(FirestoreSchema.prescriptions, id);
    if (found == null) return null;
    // The rules keep `photoStoragePath` immutable on update — the
    // update map below never touches it.
    await transport.updateDocument(
      FirestoreSchema.branchDocPath(
        found.branchId,
        FirestoreSchema.prescriptions,
        id,
      ),
      stampUpdate({
        'reviewStatus': status.name,
        'reviewedBy': reviewedBy,
        'reviewedAt': Timestamp.fromDate(DateTime.now()),
        'notes': reviewNotes?.trim().isEmpty ?? true
            ? null
            : reviewNotes!.trim(),
      }),
    );
    final updated = await getById(id);
    return updated;
  }

  @override
  Future<Prescription?> resubmitPrescription({
    required String id,
    required DateTime validUntil,
  }) async {
    final found = await findInBranches(FirestoreSchema.prescriptions, id);
    if (found == null) return null;
    final current = await getById(id);
    await transport.updateDocument(
      FirestoreSchema.branchDocPath(
        found.branchId,
        FirestoreSchema.prescriptions,
        id,
      ),
      stampUpdate({
        'reviewStatus': PrescriptionStatus.pending.name,
        'reviewedBy': null,
        'reviewedAt': null,
        'notes': null,
        'validUntil': Timestamp.fromDate(validUntil),
        'resubmissionCount': (current?.resubmissionCount ?? 0) + 1,
      }),
    );
    final updated = await getById(id);
    return updated;
  }

  @override
  Future<Prescription> createPrescription(
    Prescription prescription, {
    String? branchId,
  }) async {
    final branch =
        branchId ??
        prescription.branchId ??
        _branchFromIdPrefix(prescription.id);
    if (branch == null) {
      throw ArgumentError(
        'A branchId is required to create a prescription in Firestore.',
      );
    }
    final docId = prescription.id.isNotEmpty && !prescription.id.endsWith('-')
        ? prescription.id
        : transport.newDocumentId(
            FirestoreSchema.branchCollection(
              branch,
              FirestoreSchema.prescriptions,
            ),
          );
    final record = prescription.copyWith(
      id: docId,
      branchId: branch,
      status: PrescriptionStatus.pending,
      createdAt: DateTime.now(),
    );
    await transport.setDocument(
      FirestoreSchema.branchDocPath(
        branch,
        FirestoreSchema.prescriptions,
        docId,
      ),
      prescriptionToFirestore(record, orgId: organizationId, branchId: branch),
    );
    return record;
  }

  /// Legacy branch inference from the demo id prefix (`rx-dha-…` /
  /// `rx-glb-…`, D21). Returns `null` when the id carries no prefix.
  static String? _branchFromIdPrefix(String id) {
    if (id.startsWith('rx-dha-')) return 'branch-dha-main';
    if (id.startsWith('rx-glb-')) return 'branch-demo-gulberg';
    return null;
  }
}

// -- Purchase orders ------------------------------------------------------

class FirestorePurchaseOrderRepository
    with _FirestoreRepositoryHelper
    implements PurchaseOrderRepository {
  FirestorePurchaseOrderRepository({
    required this.transport,
    required this.organizationId,
  });

  @override
  final FirestoreTransport transport;
  @override
  final String organizationId;

  Future<PurchaseOrder> _withItems(
    String branchId,
    FirestoreDocument doc,
  ) async {
    final itemDocs = await fetchAll(
      FirestoreSchema.nestedCollection(
        branchId,
        FirestoreSchema.purchaseOrders,
        doc.id,
        FirestoreSchema.purchaseOrderItems,
      ),
    );
    return purchaseOrderFromFirestore(
      doc.id,
      doc.data,
      itemDocs: [for (final item in itemDocs) item.data],
    );
  }

  @override
  Future<List<PurchaseOrder>> getPurchaseOrders({
    String? branchId,
    String? supplierId,
  }) async {
    final branches = branchId == null ? await branchIds() : [branchId];
    final orders = <PurchaseOrder>[];
    for (final id in branches) {
      final docs = await fetchAll(
        FirestoreSchema.branchCollection(id, FirestoreSchema.purchaseOrders),
      );
      for (final doc in docs) {
        final order = await _withItems(id, doc);
        if (supplierId == null || order.supplierId == supplierId) {
          orders.add(order);
        }
      }
    }
    return orders;
  }

  @override
  Future<PurchaseOrder?> getById(String id) async {
    final found = await findInBranches(FirestoreSchema.purchaseOrders, id);
    if (found == null) return null;
    return _withItems(found.branchId, found.doc);
  }

  @override
  Future<PurchaseOrder> createPurchaseOrder(PurchaseOrder order) async {
    final docId = order.id.isNotEmpty
        ? order.id
        : transport.newDocumentId(
            FirestoreSchema.branchCollection(
              order.branchId,
              FirestoreSchema.purchaseOrders,
            ),
          );
    // Client id = doc id (D65): a retry returns the original PO.
    final existing = await transport.getDocument(
      FirestoreSchema.branchDocPath(
        order.branchId,
        FirestoreSchema.purchaseOrders,
        docId,
      ),
    );
    if (existing != null) {
      return _withItems(
        order.branchId,
        FirestoreDocument(id: docId, data: existing),
      );
    }
    final sequence = await nextCounterValue(
      order.branchId,
      _purchaseOrdersCounterId,
    );
    final code = await branchCode(order.branchId);
    final stamped = order.copyWith(
      id: docId,
      poNumber: 'PO-$code-$sequence',
      status: PurchaseOrderStatus.draft,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    final itemsPath = FirestoreSchema.nestedCollection(
      order.branchId,
      FirestoreSchema.purchaseOrders,
      docId,
      FirestoreSchema.purchaseOrderItems,
    );
    final operations = <WriteOperation>[
      WriteOperation(
        path: FirestoreSchema.branchDocPath(
          order.branchId,
          FirestoreSchema.purchaseOrders,
          docId,
        ),
        kind: WriteOperationKind.set,
        data: purchaseOrderToFirestore(
          stamped,
          orgId: organizationId,
          poNumber: stamped.poNumber,
        ),
      ),
      for (var i = 0; i < stamped.items.length; i++)
        WriteOperation(
          path: '$itemsPath/item-$i',
          kind: WriteOperationKind.set,
          data: purchaseOrderItemToFirestore(stamped.items[i]),
        ),
    ];
    await transport.runBatchedWrites(operations);
    return stamped;
  }

  @override
  Future<void> updatePurchaseOrder(PurchaseOrder order) async {
    final found = await findInBranches(
      FirestoreSchema.purchaseOrders,
      order.id,
    );
    if (found == null) return;
    final branchId = found.branchId;
    final itemsPath = FirestoreSchema.nestedCollection(
      branchId,
      FirestoreSchema.purchaseOrders,
      order.id,
      FirestoreSchema.purchaseOrderItems,
    );
    final existingItems = await fetchAll(itemsPath);
    final doc = purchaseOrderToFirestore(
      order,
      orgId: organizationId,
      poNumber: found.doc.data['poNumber'] as String? ?? order.poNumber,
    );
    // A rewrite keeps the original `createdAt` (see updateOrder).
    doc['createdAt'] = found.doc.data['createdAt'];
    final operations = <WriteOperation>[
      WriteOperation(
        path: FirestoreSchema.branchDocPath(
          branchId,
          FirestoreSchema.purchaseOrders,
          order.id,
        ),
        kind: WriteOperationKind.set,
        data: doc,
      ),
      for (var i = 0; i < order.items.length; i++)
        WriteOperation(
          path: '$itemsPath/item-$i',
          kind: WriteOperationKind.set,
          data: purchaseOrderItemToFirestore(order.items[i]),
        ),
      for (var i = order.items.length; i < existingItems.length; i++)
        WriteOperation(
          path: '$itemsPath/${existingItems[i].id}',
          kind: WriteOperationKind.delete,
        ),
    ];
    await transport.runBatchedWrites(operations);
  }
}

// -- Riders ---------------------------------------------------------------

class FirestoreRiderRepository
    with _FirestoreRepositoryHelper
    implements RiderRepository {
  FirestoreRiderRepository({
    required this.transport,
    required this.organizationId,
  });

  @override
  final FirestoreTransport transport;
  @override
  final String organizationId;

  @override
  Future<List<Rider>> getRiders() async {
    final riders = <Rider>[];
    for (final branchId in await branchIds()) {
      final docs = await fetchAll(
        FirestoreSchema.branchCollection(branchId, FirestoreSchema.riders),
      );
      riders.addAll([
        for (final doc in docs) riderFromFirestore(doc.id, doc.data),
      ]);
    }
    return riders;
  }

  @override
  Future<Rider?> getById(String id) async {
    final found = await findInBranches(FirestoreSchema.riders, id);
    if (found == null) return null;
    return riderFromFirestore(found.doc.id, found.doc.data);
  }
}
