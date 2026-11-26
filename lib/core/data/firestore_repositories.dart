import 'package:cloud_firestore/cloud_firestore.dart' hide Order;

import '../../models/attendance.dart';
import '../../models/branch.dart';
import '../../models/branch_inventory_location.dart';
import '../../models/cash_reconciliation.dart';
import '../../models/closing_correction.dart';
import '../../models/customer.dart';
import '../../models/customer_ledger.dart';
import '../../models/daily_closing.dart';
import '../../models/expense.dart';
import '../../models/financial_transaction.dart';
import '../../models/goods_receipt.dart';
import '../../models/inventory_item.dart';
import '../../models/medicine.dart';
import '../../models/order.dart';
import '../../models/prescription.dart';
import '../../models/purchase_order.dart';
import '../../models/rider.dart';
import '../../models/sale.dart';
import '../../models/sale_return.dart';
import '../../models/salary_record.dart';
import '../../models/shift.dart';
import '../../models/staff.dart';
import '../../models/stock_adjustment_request.dart';
import '../../models/stock_transfer.dart';
import '../../models/supplier.dart';
import '../../models/supplier_ledger.dart';
import '../../models/supplier_payment.dart';
import '../services/repositories.dart';
import 'firestore_mappers.dart';
import 'firestore_schema.dart';
import 'firestore_transport.dart';
import 'report_counters.dart';
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
const _goodsReceiptsCounterId = 'goodsReceipts';
const _stockTransfersCounterId = 'stockTransfers';

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

  /// First branch id in the org (name order) — the fallback branch
  /// for restore upserts of records that carry no branch of their
  /// own (customers are org-wide in the demo model, D150). Throws
  /// [ArgumentError] when the org has no branches at all.
  Future<String> firstBranchId() async {
    final ids = await branchIds();
    if (ids.isEmpty) {
      throw ArgumentError('No branches exist in this organization yet.');
    }
    return ids.first;
  }

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

  @override
  Future<Medicine> updateMedicine(Medicine medicine) async {
    final path = '${FirestoreSchema.medicines}/${medicine.id}';
    final existing = await transport.getDocument(path);
    if (existing == null) {
      throw ArgumentError('No medicine with id "${medicine.id}".');
    }
    final doc = medicineToFirestore(medicine, orgId: organizationId);
    // A rewrite keeps the original `createdAt` (the mapper stamps
    // "now" — that is only correct for creates, D138).
    doc['createdAt'] = existing['createdAt'];
    await transport.setDocument(path, doc);
    return medicine.copyWith(updatedAt: DateTime.now());
  }

  @override
  Future<Medicine> upsertMedicine(Medicine medicine) async {
    final id = medicine.id.isNotEmpty
        ? medicine.id
        : transport.newDocumentId(FirestoreSchema.medicines);
    final path = '${FirestoreSchema.medicines}/$id';
    final existing = await transport.getDocument(path);
    final doc = medicineToFirestore(medicine, orgId: organizationId);
    if (existing != null) {
      doc['createdAt'] = existing['createdAt'];
    }
    await transport.setDocument(path, doc);
    return medicineFromFirestore(id, doc);
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

  @override
  Future<Order> upsertOrder(Order order) async {
    // A restore replays the order as given: the doc id is the
    // order's id (never re-minted), the number comes from the
    // per-branch counter only for a genuinely new doc, and the
    // items subcollection is rewritten by index like `updateOrder`
    // (a shrunk list drops its trailing stale item docs).
    final docId = order.id.isNotEmpty
        ? order.id
        : transport.newDocumentId(FirestoreSchema.ordersPath(order.branchId));
    final existing = await transport.getDocument(
      FirestoreSchema.orderDocPath(order.branchId, docId),
    );
    final orderNumber = existing == null
        ? 'ORD-${await branchCode(order.branchId)}-'
              '${await nextCounterValue(order.branchId, _ordersCounterId)}'
        : existing['orderNumber'] as String? ?? docId;
    final doc = orderToFirestore(
      order,
      orgId: organizationId,
      orderNumber: orderNumber,
      idempotencyKey: existing?['idempotencyKey'] as String? ?? docId,
    );
    if (existing != null) {
      doc['createdAt'] = existing['createdAt'];
    }
    final itemsPath = FirestoreSchema.nestedCollection(
      order.branchId,
      FirestoreSchema.orders,
      docId,
      FirestoreSchema.orderItems,
    );
    final existingItems = await fetchAll(itemsPath);
    final operations = <WriteOperation>[
      WriteOperation(
        path: FirestoreSchema.orderDocPath(order.branchId, docId),
        kind: WriteOperationKind.set,
        data: doc,
      ),
      for (var i = 0; i < order.items.length; i++)
        WriteOperation(
          path: '$itemsPath/item-$i',
          kind: WriteOperationKind.set,
          data: orderItemToFirestore(order.items[i]),
        ),
      for (var i = order.items.length; i < existingItems.length; i++)
        WriteOperation(
          path: '$itemsPath/${existingItems[i].id}',
          kind: WriteOperationKind.delete,
        ),
    ];
    await transport.runBatchedWrites(operations);
    return order.copyWith(id: docId);
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

  @override
  Future<InventoryItem> updateBatchStatus({
    required String batchId,
    required BatchStatus status,
    String? reason,
  }) async {
    // A status change moves no stock, so no stock transaction is
    // written — the audit entry is the layer's job (D140), and the
    // sync payload is one batch-doc update enqueued by the layer.
    final found = await findInBranches(FirestoreSchema.batches, batchId);
    if (found == null) {
      throw ArgumentError('No batch with id "$batchId".');
    }
    final batchPath = FirestoreSchema.branchDocPath(
      found.branchId,
      FirestoreSchema.batches,
      batchId,
    );
    await transport.updateDocument(batchPath, {
      'status': status.name,
      'updatedAt': Timestamp.fromDate(DateTime.now()),
    });
    return batchFromFirestore(
      found.doc.id,
      found.doc.data,
    ).copyWith(status: status, updatedAt: DateTime.now());
  }

  @override
  Future<InventoryItem> upsertInventoryItem(InventoryItem item) async {
    // A restore replays the batch row as given (quantity, status
    // and dates) — no stock transaction is written and the
    // per-(branch, medicine) on-hand counter is NOT recomputed:
    // counters are rollup state and are not part of a backup.
    final batchId = item.id.isNotEmpty
        ? item.id
        : transport.newDocumentId(FirestoreSchema.batchesPath(item.branchId));
    final batchPath = FirestoreSchema.branchDocPath(
      item.branchId,
      FirestoreSchema.batches,
      batchId,
    );
    final existing = await transport.getDocument(batchPath);
    final doc = batchToFirestore(item, orgId: organizationId);
    if (existing != null) {
      doc['createdAt'] = existing['createdAt'];
    }
    await transport.setDocument(batchPath, doc);
    return batchFromFirestore(batchId, doc);
  }

  /// Per-branch rack / shelf override (Week 5 Day 3, D152): the doc
  /// id is the medicine id under `branches/{branchId}/inventory`.
  /// A doc whose rack/shelf are both empty is no override (the
  /// branch falls back to the master location).
  @override
  Future<BranchInventoryLocation?> getBranchLocation({
    required String branchId,
    required String medicineId,
  }) async {
    final data = await transport.getDocument(
      FirestoreSchema.inventoryDocPath(branchId, medicineId),
    );
    if (data == null) return null;
    final location = branchInventoryLocationFromFirestore(
      branchId,
      medicineId,
      data,
    );
    return location.isEmpty ? null : location;
  }

  @override
  Future<List<BranchInventoryLocation>> getBranchLocations({
    String? branchId,
  }) async {
    final branches = branchId == null ? await branchIds() : [branchId];
    final locations = <BranchInventoryLocation>[];
    for (final id in branches) {
      final docs = await fetchAll(FirestoreSchema.inventoryPath(id));
      locations.addAll([
        for (final doc in docs)
          branchInventoryLocationFromFirestore(id, doc.id, doc.data),
      ]);
    }
    return locations.where((location) => !location.isEmpty).toList();
  }

  @override
  Future<BranchInventoryLocation> saveBranchLocation(
    BranchInventoryLocation location,
  ) async {
    // Merge-set: the inventory doc also carries the quantity
    // counters, which this write must never drop — only rack/shelf
    // (and the stamp) change. Clearing writes nulls, so the doc
    // keeps its counters and the override reads back as "none".
    await transport.setDocument(
      FirestoreSchema.inventoryDocPath(location.branchId, location.medicineId),
      branchInventoryLocationToFirestore(location, orgId: organizationId),
      merge: true,
    );
    return location;
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

  @override
  Future<Customer> upsertCustomer(Customer customer, {String? branchId}) async {
    // Customers carry no branch on the model (org-wide in the
    // demo) — the restore files the doc under the given branch, or
    // the first branch when none is given. No phone-uniqueness
    // check: a restore replays data that was valid when exported.
    final branch = branchId ?? await firstBranchId();
    final id = customer.id.isNotEmpty
        ? customer.id
        : transport.newDocumentId(
            FirestoreSchema.branchCollection(branch, FirestoreSchema.customers),
          );
    final path = FirestoreSchema.branchDocPath(
      branch,
      FirestoreSchema.customers,
      id,
    );
    final existing = await transport.getDocument(path);
    final doc = customerToFirestore(
      customer,
      orgId: organizationId,
      branchId: branch,
    );
    if (existing != null) {
      doc['createdAt'] = existing['createdAt'];
    }
    await transport.setDocument(path, doc);
    return customerFromFirestore(id, doc);
  }

  @override
  Future<LedgerEntry> upsertLedgerEntry(
    LedgerEntry entry, {
    String? branchId,
  }) async {
    // Unlike `addLedgerEntry` the balance is kept exactly as given
    // — a restore replays history, it does not recompute it. The
    // branch is the customer's branch when the entry's customer is
    // on file, else the given branch, else the first branch.
    final found = await findInBranches(
      FirestoreSchema.customers,
      entry.customerId,
    );
    final branch = found?.branchId ?? branchId ?? await firstBranchId();
    final ledgerPath = FirestoreSchema.customerLedgerPath(
      branch,
      entry.customerId,
    );
    final id = entry.id.isNotEmpty
        ? entry.id
        : transport.newDocumentId(ledgerPath);
    final path = '$ledgerPath/$id';
    final existing = await transport.getDocument(path);
    final doc = customerLedgerEntryToFirestore(
      entry,
      orgId: organizationId,
      branchId: branch,
    );
    if (existing != null) {
      doc['createdAt'] = existing['createdAt'];
    }
    await transport.setDocument(path, doc);
    return customerLedgerEntryFromFirestore(id, doc);
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

  @override
  Future<Sale> upsertSale(Sale sale) async {
    // A restore replays the sale as given (status, totals, items,
    // invoice number and idempotency key) under the exported id as
    // the doc id. The payments subcollection is NOT restored — it
    // is not part of the backup (the sale doc carries the payment
    // method and cash received, which is what the screens read).
    // Items are rewritten by index like `updateOrder` (a shrunk
    // list drops its trailing stale item docs).
    final docId = sale.id.isNotEmpty
        ? sale.id
        : transport.newDocumentId(FirestoreSchema.salesPath(sale.branchId));
    final docPath = FirestoreSchema.saleDocPath(sale.branchId, docId);
    final existing = await transport.getDocument(docPath);
    final stamped = sale.copyWith(
      id: docId,
      createdAt: sale.createdAt ?? DateTime.now(),
    );
    final doc = saleToFirestore(stamped, orgId: organizationId);
    if (existing != null) {
      doc['createdAt'] = existing['createdAt'];
    }
    final itemsPath = FirestoreSchema.saleItemsPath(sale.branchId, docId);
    final existingItems = await fetchAll(itemsPath);
    final operations = <WriteOperation>[
      WriteOperation(path: docPath, kind: WriteOperationKind.set, data: doc),
      for (var i = 0; i < stamped.items.length; i++)
        WriteOperation(
          path: '$itemsPath/item-$i',
          kind: WriteOperationKind.set,
          data: saleItemToFirestore(stamped.items[i]),
        ),
      for (var i = stamped.items.length; i < existingItems.length; i++)
        WriteOperation(
          path: '$itemsPath/${existingItems[i].id}',
          kind: WriteOperationKind.delete,
        ),
    ];
    await transport.runBatchedWrites(operations);
    return stamped;
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

  Future<SaleReturn> _withItems(String branchId, FirestoreDocument doc) async {
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
        path: FirestoreSchema.saleReturnDocPath(saleReturn.branchId, returnId),
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

  @override
  Future<Supplier> upsertSupplier(Supplier supplier) async {
    // No phone-uniqueness check: a restore replays data that was
    // valid when exported.
    final id = supplier.id.isNotEmpty
        ? supplier.id
        : transport.newDocumentId(FirestoreSchema.suppliers);
    final path = '${FirestoreSchema.suppliers}/$id';
    final existing = await transport.getDocument(path);
    final doc = supplierToFirestore(supplier, orgId: organizationId);
    if (existing != null) {
      doc['createdAt'] = existing['createdAt'];
    }
    await transport.setDocument(path, doc);
    return supplierFromFirestore(id, doc);
  }

  @override
  Future<SupplierLedgerEntry> upsertLedgerEntry(
    SupplierLedgerEntry entry,
  ) async {
    // Unlike `addLedgerEntry` the balance is kept exactly as given
    // — a restore replays history, it does not recompute it.
    final ledgerPath = FirestoreSchema.supplierLedgerPath(entry.supplierId);
    final id = entry.id.isNotEmpty
        ? entry.id
        : transport.newDocumentId(ledgerPath);
    final path = '$ledgerPath/$id';
    final existing = await transport.getDocument(path);
    final doc = supplierLedgerEntryToFirestore(entry, orgId: organizationId);
    if (existing != null) {
      doc['createdAt'] = existing['createdAt'];
    }
    await transport.setDocument(path, doc);
    return supplierLedgerEntryFromFirestore(id, doc);
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

  @override
  Future<Prescription> upsertPrescription(
    Prescription prescription, {
    String? branchId,
  }) async {
    // Unlike `createPrescription` the status is kept as given — a
    // restore replays the review state, it does not reset it to
    // Pending. The branch falls back to the id prefix, then to the
    // first branch (a restored record always has a branch on file
    // or in its id; the fallback only covers hand-built docs).
    final docId = prescription.id.isNotEmpty
        ? prescription.id
        : transport.newDocumentId(
            FirestoreSchema.branchCollection(
              branchId ?? prescription.branchId ?? await firstBranchId(),
              FirestoreSchema.prescriptions,
            ),
          );
    final branch =
        branchId ??
        prescription.branchId ??
        _branchFromIdPrefix(docId) ??
        await firstBranchId();
    final path = FirestoreSchema.branchDocPath(
      branch,
      FirestoreSchema.prescriptions,
      docId,
    );
    final existing = await transport.getDocument(path);
    final record = prescription.copyWith(
      id: docId,
      branchId: branch,
      createdAt: prescription.createdAt ?? DateTime.now(),
    );
    final doc = prescriptionToFirestore(
      record,
      orgId: organizationId,
      branchId: branch,
    );
    if (existing != null) {
      doc['createdAt'] = existing['createdAt'];
    }
    await transport.setDocument(path, doc);
    return prescriptionFromFirestore(docId, doc);
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

  @override
  Future<PurchaseOrder> upsertPurchaseOrder(PurchaseOrder order) async {
    // A restore replays the PO as given: the status is kept (unlike
    // `createPurchaseOrder`, which resets it to Draft) and the PO
    // number is kept when given — a new doc without one gets a fresh
    // counter number, like a create. Items are rewritten by index
    // like `updatePurchaseOrder`.
    final docId = order.id.isNotEmpty
        ? order.id
        : transport.newDocumentId(
            FirestoreSchema.branchCollection(
              order.branchId,
              FirestoreSchema.purchaseOrders,
            ),
          );
    final existing = await transport.getDocument(
      FirestoreSchema.branchDocPath(
        order.branchId,
        FirestoreSchema.purchaseOrders,
        docId,
      ),
    );
    final poNumber = order.poNumber.isNotEmpty
        ? order.poNumber
        : existing?['poNumber'] as String? ??
              'PO-${await branchCode(order.branchId)}-'
                  '${await nextCounterValue(order.branchId, _purchaseOrdersCounterId)}';
    final doc = purchaseOrderToFirestore(
      order,
      orgId: organizationId,
      poNumber: poNumber,
    );
    if (existing != null) {
      doc['createdAt'] = existing['createdAt'];
    }
    final itemsPath = FirestoreSchema.nestedCollection(
      order.branchId,
      FirestoreSchema.purchaseOrders,
      docId,
      FirestoreSchema.purchaseOrderItems,
    );
    final existingItems = await fetchAll(itemsPath);
    final operations = <WriteOperation>[
      WriteOperation(
        path: FirestoreSchema.branchDocPath(
          order.branchId,
          FirestoreSchema.purchaseOrders,
          docId,
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
    return order.copyWith(id: docId, poNumber: poNumber);
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

  @override
  Future<void> updateRider(Rider rider) async {
    final found = await findInBranches(FirestoreSchema.riders, rider.id);
    if (found == null) {
      throw ArgumentError('No rider with id "${rider.id}".');
    }
    final branchId = rider.branchId ?? found.branchId;
    final doc = riderToFirestore(
      rider,
      orgId: organizationId,
      branchId: branchId,
    );
    // A rewrite keeps the original `createdAt` (the mapper stamps
    // "now" — that is only correct for creates).
    doc['createdAt'] = found.doc.data['createdAt'];
    await transport.setDocument(
      FirestoreSchema.branchDocPath(branchId, FirestoreSchema.riders, rider.id),
      doc,
    );
  }

  @override
  Future<Rider> upsertRider(Rider rider, {String? branchId}) async {
    // The branch is the given one, the record's own, the branch of
    // the stored doc on a replace, else the first branch.
    final found = rider.id.isEmpty
        ? null
        : await findInBranches(FirestoreSchema.riders, rider.id);
    final branch =
        branchId ?? rider.branchId ?? found?.branchId ?? await firstBranchId();
    final id = rider.id.isNotEmpty
        ? rider.id
        : transport.newDocumentId(
            FirestoreSchema.branchCollection(branch, FirestoreSchema.riders),
          );
    final path = FirestoreSchema.branchDocPath(
      branch,
      FirestoreSchema.riders,
      id,
    );
    final existing = await transport.getDocument(path);
    final doc = riderToFirestore(
      rider,
      orgId: organizationId,
      branchId: branch,
    );
    if (existing != null) {
      doc['createdAt'] = existing['createdAt'];
    }
    await transport.setDocument(path, doc);
    return riderFromFirestore(id, doc);
  }
}

// -- Stock transfers (Week 4 Day 2, D118) ---------------------------------

/// Firestore stock transfers: one doc per transfer under the source
/// branch (`branches/{fromBranchId}/stockTransfers/{id}`), lines and
/// dispatch allocations embedded on the doc (D120). Same conventions
/// as the Day 3 repos (D73): a caller-supplied non-empty id is the
/// doc id (D65 pattern), the transfer number comes from the
/// per-branch counter, and a rewrite keeps the original `createdAt`.
class FirestoreStockTransferRepository
    with _FirestoreRepositoryHelper
    implements StockTransferRepository {
  FirestoreStockTransferRepository({
    required this.transport,
    required this.organizationId,
  });

  @override
  final FirestoreTransport transport;
  @override
  final String organizationId;

  @override
  Future<List<StockTransfer>> getTransfers({String? branchId}) async {
    final transfers = <StockTransfer>[];
    final branches = branchId == null ? await branchIds() : [branchId];
    for (final id in branches) {
      final docs = await fetchAll(FirestoreSchema.stockTransfersPath(id));
      transfers.addAll([
        for (final doc in docs) stockTransferFromFirestore(doc.id, doc.data),
      ]);
    }
    if (branchId != null) {
      // A branch-scoped read also returns transfers where this
      // branch is the destination — those live under the OTHER
      // branch's collection, so they are fetched by scanning the
      // org's branches and filtering (same shape as the mock).
      final seen = {for (final t in transfers) t.id};
      for (final id in await branchIds()) {
        if (id == branchId) continue;
        final docs = await fetchAll(FirestoreSchema.stockTransfersPath(id));
        for (final doc in docs) {
          final transfer = stockTransferFromFirestore(doc.id, doc.data);
          if (transfer.toBranchId == branchId && !seen.contains(transfer.id)) {
            transfers.add(transfer);
            seen.add(transfer.id);
          }
        }
      }
    }
    return transfers;
  }

  @override
  Future<StockTransfer?> getById(String id) async {
    final found = await findInBranches(FirestoreSchema.stockTransfers, id);
    if (found == null) return null;
    return stockTransferFromFirestore(found.doc.id, found.doc.data);
  }

  @override
  Future<StockTransfer> createTransfer(StockTransfer transfer) async {
    final docId = transfer.id.isNotEmpty
        ? transfer.id
        : transport.newDocumentId(
            FirestoreSchema.stockTransfersPath(transfer.fromBranchId),
          );
    // Client id = doc id (D65 pattern): a retry returns the original.
    final existing = await transport.getDocument(
      FirestoreSchema.stockTransferDocPath(transfer.fromBranchId, docId),
    );
    if (existing != null) {
      return stockTransferFromFirestore(docId, existing);
    }
    final sequence = await nextCounterValue(
      transfer.fromBranchId,
      _stockTransfersCounterId,
    );
    final fromCode = await branchCode(transfer.fromBranchId);
    final toCode = await branchCode(transfer.toBranchId);
    final numbered = transfer.copyWith(
      id: docId,
      transferNumber: transfer.transferNumber.isEmpty
          ? 'TR-$fromCode-$toCode-$sequence'
          : transfer.transferNumber,
    );
    final doc = stockTransferToFirestore(numbered, orgId: organizationId);
    await transport.setDocument(
      FirestoreSchema.stockTransferDocPath(transfer.fromBranchId, docId),
      doc,
    );
    return numbered;
  }

  @override
  Future<void> updateTransfer(StockTransfer transfer) async {
    final found = await findInBranches(
      FirestoreSchema.stockTransfers,
      transfer.id,
    );
    if (found == null) {
      throw ArgumentError('No transfer with id "${transfer.id}".');
    }
    final doc = stockTransferToFirestore(transfer, orgId: organizationId);
    // A rewrite keeps the original `createdAt` (the mapper stamps
    // "now" — that is only correct for creates).
    doc['createdAt'] = found.doc.data['createdAt'];
    await transport.setDocument(
      FirestoreSchema.stockTransferDocPath(found.branchId, transfer.id),
      doc,
    );
  }
}

/// Adjustment approval queue (Week 5 Day 1, D146 —
/// `branches/{branchId}/stockAdjustments/{id}`), one doc per
/// request, doc id = request id. Same conventions as the transfer
/// repo (D73/D118): a caller-supplied non-empty id is the doc id
/// (D65 pattern — filing and deciding share one upsert, so a retry
/// overwrites the same document instead of writing a second one),
/// and a rewrite keeps the original `createdAt`.
class FirestoreStockAdjustmentRequestRepository
    with _FirestoreRepositoryHelper
    implements StockAdjustmentRequestRepository {
  FirestoreStockAdjustmentRequestRepository({
    required this.transport,
    required this.organizationId,
  });

  @override
  final FirestoreTransport transport;
  @override
  final String organizationId;

  @override
  Future<List<StockAdjustmentRequest>> getRequests({String? branchId}) async {
    final requests = <StockAdjustmentRequest>[];
    final branches = branchId == null ? await branchIds() : [branchId];
    for (final id in branches) {
      final docs = await fetchAll(FirestoreSchema.stockAdjustmentsPath(id));
      requests.addAll([
        for (final doc in docs)
          stockAdjustmentRequestFromFirestore(doc.id, doc.data),
      ]);
    }
    return requests;
  }

  @override
  Future<StockAdjustmentRequest?> getById(String id) async {
    final found = await findInBranches(FirestoreSchema.stockAdjustments, id);
    if (found == null) return null;
    return stockAdjustmentRequestFromFirestore(found.doc.id, found.doc.data);
  }

  @override
  Future<StockAdjustmentRequest> saveRequest(
    StockAdjustmentRequest request,
  ) async {
    if (request.branchId.isEmpty) {
      throw ArgumentError(
        'A branchId is required to save a stock adjustment request '
        'in Firestore.',
      );
    }
    final docId = request.id.isNotEmpty
        ? request.id
        : transport.newDocumentId(
            FirestoreSchema.stockAdjustmentsPath(request.branchId),
          );
    final saved = request.id.isEmpty
        ? StockAdjustmentRequest.fromMap(docId, request.toMap())
        : request;
    final existing = await transport.getDocument(
      FirestoreSchema.stockAdjustmentDocPath(request.branchId, docId),
    );
    final doc = stockAdjustmentRequestToFirestore(saved, orgId: organizationId);
    if (existing != null) {
      // A rewrite keeps the original `createdAt` (the mapper stamps
      // "now" — that is only correct for creates).
      doc['createdAt'] = existing['createdAt'];
    }
    await transport.setDocument(
      FirestoreSchema.stockAdjustmentDocPath(request.branchId, docId),
      doc,
    );
    return saved;
  }
}

// -- Branches (Week 5 Day 2, D148 — SRS §3.1 `branches`) -----------------
//
// One doc per branch under the root `branches` collection (branches
// are org-wide, not branch-scoped — a branch cannot live under
// itself). Same conventions as the Day 3 repos (D73): a
// caller-supplied non-empty id is the doc id (D65 pattern — the
// directory mints `branch-<slug>`, so a retry returns the existing
// document instead of writing a second one), an empty id gets a
// Firestore auto-id, and a rewrite keeps the original `createdAt`.
// The mock is seeded from the same two demo branches, so the
// directory reads identically on either backend.
class FirestoreBranchRepository
    with _FirestoreRepositoryHelper
    implements BranchRepository {
  FirestoreBranchRepository({
    required this.transport,
    required this.organizationId,
  });

  @override
  final FirestoreTransport transport;
  @override
  final String organizationId;

  @override
  Future<List<Branch>> getBranches() async {
    final docs = await transport.queryCollection(
      FirestoreSchema.branches,
      orderBy: 'name',
    );
    return [for (final doc in docs) branchFromFirestore(doc.id, doc.data)];
  }

  @override
  Future<Branch?> getById(String id) async {
    final data = await transport.getDocument(FirestoreSchema.branchDoc(id));
    if (data == null) return null;
    return branchFromFirestore(id, data);
  }

  @override
  Future<Branch> createBranch(Branch branch) async {
    final id = branch.id.isNotEmpty
        ? branch.id
        : transport.newDocumentId(FirestoreSchema.branches);
    final existing = await transport.getDocument(FirestoreSchema.branchDoc(id));
    if (existing != null) {
      throw ArgumentError('A branch with id "$id" already exists.');
    }
    final doc = branchToFirestore(branch, orgId: organizationId);
    await transport.setDocument(FirestoreSchema.branchDoc(id), doc);
    return branchFromFirestore(id, doc);
  }

  @override
  Future<Branch> updateBranch(Branch branch) async {
    final existing = await transport.getDocument(
      FirestoreSchema.branchDoc(branch.id),
    );
    if (existing == null) {
      throw ArgumentError('No branch with id "${branch.id}".');
    }
    final doc = branchToFirestore(branch, orgId: organizationId);
    // A rewrite keeps the original `createdAt` (the mapper stamps
    // "now" — that is only correct for creates).
    doc['createdAt'] = existing['createdAt'];
    await transport.setDocument(FirestoreSchema.branchDoc(branch.id), doc);
    return branchFromFirestore(branch.id, doc);
  }

  @override
  Future<Branch> saveBranch(Branch branch) async {
    final id = branch.id.isNotEmpty
        ? branch.id
        : transport.newDocumentId(FirestoreSchema.branches);
    final existing = await transport.getDocument(FirestoreSchema.branchDoc(id));
    final doc = branchToFirestore(branch, orgId: organizationId);
    if (existing != null) {
      doc['createdAt'] = existing['createdAt'];
    }
    await transport.setDocument(FirestoreSchema.branchDoc(id), doc);
    return branchFromFirestore(id, doc);
  }
}

// -- Staff & HR (Week 3 Day 1, D100/D101) ---------------------------------
//
// The six Day 5 repos behind the same interfaces the screens
// already use. Same conventions as the Day 3 repos (D73):
//
// - **Doc id = idempotency key** for creates: a caller-supplied
//   non-empty id is the doc id — a retry with the same id returns
//   the existing document instead of writing a second one (D65
//   pattern). An empty id gets a Firestore auto-id, like the mocks
//   assigning `staff-N` / `exp-N` / …
// - **Attendance upsert is idempotent by construction:** the same
//   id overwrites the same doc (check-in creates, check-out
//   rewrites), so a retried check-out can never duplicate a day.
// - **Branch scoping:** branch-scoped reads need a branch id; a
//   null branch enumerates the org's branches (same as Day 3).
//   Attendance date / employee filters and the payment supplier
//   filter are applied client-side after the branch fetch.
// - **Validation mirrors the mocks + the providers' pure
//   validators** (`hr_logic.dart`, `finance_logic.dart`): the
//   screens validate first, the repository re-checks the rules it
//   owns (phone uniqueness, positive amounts, allocation sums) so
//   a direct caller cannot write a bad document.
// - **No hard deletes, no salary:** staff salary / joining date
//   are never written (D99 — the model has neither); updates
//   preserve the original `createdAt` like the Day 3 updates.

/// Digits-only phone comparison (formatting ignored), same as the
/// mocks for customers / suppliers / staff.
String _phoneDigits(String phone) => phone.replaceAll(RegExp(r'[^0-9]'), '');

class FirestoreStaffRepository
    with _FirestoreRepositoryHelper
    implements StaffRepository {
  FirestoreStaffRepository({
    required this.transport,
    required this.organizationId,
  });

  @override
  final FirestoreTransport transport;
  @override
  final String organizationId;

  /// True when another staff member (any branch, id != [excludeId])
  /// already has this phone number (digits compared).
  Future<bool> _phoneTaken(String phone, {String? excludeId}) async {
    final digits = _phoneDigits(phone);
    if (digits.isEmpty) return false;
    for (final member in await getStaff()) {
      if (member.id != excludeId && _phoneDigits(member.phone) == digits) {
        return true;
      }
    }
    return false;
  }

  @override
  Future<List<Staff>> getStaff({String? branchId}) async {
    final branches = branchId == null ? await branchIds() : [branchId];
    final staff = <Staff>[];
    for (final id in branches) {
      final docs = await fetchAll(
        FirestoreSchema.branchCollection(id, FirestoreSchema.employees),
      );
      staff.addAll([
        for (final doc in docs) staffFromFirestore(doc.id, doc.data),
      ]);
    }
    return staff;
  }

  @override
  Future<Staff?> getById(String id) async {
    final found = await findInBranches(FirestoreSchema.employees, id);
    if (found == null) return null;
    return staffFromFirestore(found.doc.id, found.doc.data);
  }

  @override
  Future<Staff> createStaff(Staff staff) async {
    if (staff.name.trim().isEmpty) {
      throw ArgumentError('Staff name is required.');
    }
    if (staff.branchId.isEmpty) {
      throw ArgumentError(
        'A branchId is required to create a staff member in Firestore.',
      );
    }
    final docId = staff.id.isNotEmpty
        ? staff.id
        : transport.newDocumentId(
            FirestoreSchema.branchCollection(
              staff.branchId,
              FirestoreSchema.employees,
            ),
          );
    // Caller id = doc id (D65 pattern): a retry returns the original.
    final existing = await transport.getDocument(
      FirestoreSchema.branchDocPath(
        staff.branchId,
        FirestoreSchema.employees,
        docId,
      ),
    );
    if (existing != null) {
      return staffFromFirestore(docId, existing);
    }
    if (await _phoneTaken(staff.phone)) {
      throw ArgumentError(
        'A staff member with phone ${staff.phone} already exists.',
      );
    }
    final created = staff.copyWith(id: docId, createdAt: DateTime.now());
    await transport.setDocument(
      FirestoreSchema.branchDocPath(
        staff.branchId,
        FirestoreSchema.employees,
        docId,
      ),
      staffToFirestore(created, orgId: organizationId),
    );
    return created;
  }

  @override
  Future<void> updateStaff(Staff staff) async {
    final found = await findInBranches(FirestoreSchema.employees, staff.id);
    if (found == null) return;
    if (staff.name.trim().isEmpty) {
      throw ArgumentError('Staff name is required.');
    }
    if (await _phoneTaken(staff.phone, excludeId: staff.id)) {
      throw ArgumentError(
        'A staff member with phone ${staff.phone} already exists.',
      );
    }
    final doc = staffToFirestore(staff, orgId: organizationId);
    // A rewrite keeps the original `createdAt` (see updateOrder).
    doc['createdAt'] = found.doc.data['createdAt'];
    await transport.setDocument(
      FirestoreSchema.branchDocPath(
        found.branchId,
        FirestoreSchema.employees,
        staff.id,
      ),
      doc,
    );
  }
}

class FirestoreAttendanceRepository
    with _FirestoreRepositoryHelper
    implements AttendanceRepository {
  FirestoreAttendanceRepository({
    required this.transport,
    required this.organizationId,
  });

  @override
  final FirestoreTransport transport;
  @override
  final String organizationId;

  @override
  Future<List<Attendance>> getAttendances({
    String? branchId,
    DateTime? date,
    String? employeeId,
  }) async {
    final branches = branchId == null ? await branchIds() : [branchId];
    final records = <Attendance>[];
    for (final id in branches) {
      final docs = await fetchAll(
        FirestoreSchema.branchCollection(id, FirestoreSchema.attendances),
      );
      records.addAll([
        for (final doc in docs) attendanceFromFirestore(doc.id, doc.data),
      ]);
    }
    // Date matches the calendar day; employee filters client-side
    // (same as the mock).
    return records.where((record) {
      if (employeeId != null && record.employeeId != employeeId) {
        return false;
      }
      if (date != null) {
        if (record.date.year != date.year ||
            record.date.month != date.month ||
            record.date.day != date.day) {
          return false;
        }
      }
      return true;
    }).toList();
  }

  @override
  Future<Attendance> upsertAttendance(Attendance attendance) async {
    if (attendance.employeeId.isEmpty) {
      throw ArgumentError('An attendance record needs an employeeId.');
    }
    if (attendance.branchId.isEmpty) {
      throw ArgumentError(
        'A branchId is required to save attendance in Firestore.',
      );
    }
    final path = FirestoreSchema.branchCollection(
      attendance.branchId,
      FirestoreSchema.attendances,
    );
    if (attendance.id.isEmpty) {
      final id = await transport.addDocument(
        path,
        attendanceToFirestore(attendance, orgId: organizationId),
      );
      return attendance.copyWith(id: id, createdAt: DateTime.now());
    }
    // Same id = same doc: a retried check-out overwrites, never
    // duplicates (D100). Preserve the original `createdAt`.
    final docPath = FirestoreSchema.branchDocPath(
      attendance.branchId,
      FirestoreSchema.attendances,
      attendance.id,
    );
    final existing = await transport.getDocument(docPath);
    final doc = attendanceToFirestore(attendance, orgId: organizationId);
    if (existing != null) doc['createdAt'] = existing['createdAt'];
    await transport.setDocument(docPath, doc);
    return attendance.copyWith(
      createdAt: existing == null
          ? DateTime.now()
          : attendance.createdAt ?? _parseCreatedAt(existing),
    );
  }

  static DateTime? _parseCreatedAt(Map<String, dynamic> doc) {
    final value = doc['createdAt'];
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    return null;
  }
}

class FirestoreShiftRepository
    with _FirestoreRepositoryHelper
    implements ShiftRepository {
  FirestoreShiftRepository({
    required this.transport,
    required this.organizationId,
  });

  @override
  final FirestoreTransport transport;
  @override
  final String organizationId;

  @override
  Future<List<Shift>> getShifts({String? branchId}) async {
    final branches = branchId == null ? await branchIds() : [branchId];
    final shifts = <Shift>[];
    for (final id in branches) {
      final docs = await fetchAll(
        FirestoreSchema.branchCollection(id, FirestoreSchema.shifts),
      );
      shifts.addAll([
        for (final doc in docs) shiftFromFirestore(doc.id, doc.data),
      ]);
    }
    return shifts;
  }

  @override
  Future<Shift?> getById(String id) async {
    final found = await findInBranches(FirestoreSchema.shifts, id);
    if (found == null) return null;
    return shiftFromFirestore(found.doc.id, found.doc.data);
  }

  @override
  Future<Shift> createShift(Shift shift) async {
    if (shift.name.trim().isEmpty) {
      throw ArgumentError('Shift name is required.');
    }
    if (shift.branchId.isEmpty) {
      throw ArgumentError(
        'A branchId is required to create a shift in Firestore.',
      );
    }
    final docId = shift.id.isNotEmpty
        ? shift.id
        : transport.newDocumentId(
            FirestoreSchema.branchCollection(
              shift.branchId,
              FirestoreSchema.shifts,
            ),
          );
    // Caller id = doc id (D65 pattern): a retry returns the original.
    final existing = await transport.getDocument(
      FirestoreSchema.branchDocPath(
        shift.branchId,
        FirestoreSchema.shifts,
        docId,
      ),
    );
    if (existing != null) {
      return shiftFromFirestore(docId, existing);
    }
    final created = shift.copyWith(id: docId, createdAt: DateTime.now());
    await transport.setDocument(
      FirestoreSchema.branchDocPath(
        shift.branchId,
        FirestoreSchema.shifts,
        docId,
      ),
      shiftToFirestore(created, orgId: organizationId),
    );
    return created;
  }

  @override
  Future<void> updateShift(Shift shift) async {
    final found = await findInBranches(FirestoreSchema.shifts, shift.id);
    if (found == null) return;
    if (shift.name.trim().isEmpty) {
      throw ArgumentError('Shift name is required.');
    }
    final doc = shiftToFirestore(shift, orgId: organizationId);
    // A rewrite keeps the original `createdAt` (see updateOrder).
    doc['createdAt'] = found.doc.data['createdAt'];
    await transport.setDocument(
      FirestoreSchema.branchDocPath(
        found.branchId,
        FirestoreSchema.shifts,
        shift.id,
      ),
      doc,
    );
  }
}

class FirestoreExpenseRepository
    with _FirestoreRepositoryHelper
    implements ExpenseRepository {
  FirestoreExpenseRepository({
    required this.transport,
    required this.organizationId,
  });

  @override
  final FirestoreTransport transport;
  @override
  final String organizationId;

  @override
  Future<List<Expense>> getExpenses({String? branchId}) async {
    final branches = branchId == null ? await branchIds() : [branchId];
    final expenses = <Expense>[];
    for (final id in branches) {
      final docs = await fetchAll(
        FirestoreSchema.branchCollection(id, FirestoreSchema.expenses),
      );
      expenses.addAll([
        for (final doc in docs) expenseFromFirestore(doc.id, doc.data),
      ]);
    }
    return expenses;
  }

  @override
  Future<Expense> createExpense(Expense expense) async {
    if (expense.amountMinor <= 0) {
      throw ArgumentError('Expense amount must be more than zero.');
    }
    if (!expenseCategories.contains(expense.category)) {
      throw ArgumentError('Unknown expense category "${expense.category}".');
    }
    if (expense.branchId.isEmpty) {
      throw ArgumentError(
        'A branchId is required to create an expense in Firestore.',
      );
    }
    final docId = expense.id.isNotEmpty
        ? expense.id
        : transport.newDocumentId(
            FirestoreSchema.branchCollection(
              expense.branchId,
              FirestoreSchema.expenses,
            ),
          );
    // Caller id = doc id (D65 pattern): a retry returns the original.
    final existing = await transport.getDocument(
      FirestoreSchema.branchDocPath(
        expense.branchId,
        FirestoreSchema.expenses,
        docId,
      ),
    );
    if (existing != null) {
      return expenseFromFirestore(docId, existing);
    }
    final created = expense.copyWith(id: docId, createdAt: DateTime.now());
    await transport.setDocument(
      FirestoreSchema.branchDocPath(
        expense.branchId,
        FirestoreSchema.expenses,
        docId,
      ),
      expenseToFirestore(created, orgId: organizationId),
    );
    return created;
  }
}

class FirestoreFinancialTransactionRepository
    with _FirestoreRepositoryHelper
    implements FinancialTransactionRepository {
  FirestoreFinancialTransactionRepository({
    required this.transport,
    required this.organizationId,
  });

  @override
  final FirestoreTransport transport;
  @override
  final String organizationId;

  @override
  Future<List<FinancialTransaction>> getTransactions({String? branchId}) async {
    final branches = branchId == null ? await branchIds() : [branchId];
    final txns = <FinancialTransaction>[];
    for (final id in branches) {
      final docs = await fetchAll(
        FirestoreSchema.branchCollection(
          id,
          FirestoreSchema.financialTransactions,
        ),
      );
      txns.addAll([
        for (final doc in docs)
          financialTransactionFromFirestore(doc.id, doc.data),
      ]);
    }
    return txns;
  }

  @override
  Future<FinancialTransaction> addTransaction(FinancialTransaction txn) async {
    // Amounts are signed (money in / out) — but a zero-amount
    // transaction records nothing, so it is refused.
    if (txn.amountMinor == 0) {
      throw ArgumentError('A financial transaction amount cannot be zero.');
    }
    if (txn.branchId.isEmpty) {
      throw ArgumentError(
        'A branchId is required to add a financial transaction in '
        'Firestore.',
      );
    }
    final docId = txn.id.isNotEmpty
        ? txn.id
        : transport.newDocumentId(
            FirestoreSchema.branchCollection(
              txn.branchId,
              FirestoreSchema.financialTransactions,
            ),
          );
    // Caller id = doc id (D65 pattern): a retry returns the
    // original — an append-only collection must never double-append.
    final existing = await transport.getDocument(
      FirestoreSchema.branchDocPath(
        txn.branchId,
        FirestoreSchema.financialTransactions,
        docId,
      ),
    );
    if (existing != null) {
      return financialTransactionFromFirestore(docId, existing);
    }
    final created = txn.copyWith(
      id: docId,
      // Week 4 Day 3 (D125): keep a caller-supplied `createdAt` —
      // a backdated cashbook income entry lands on its entry date.
      createdAt: txn.createdAt ?? DateTime.now(),
    );
    await transport.setDocument(
      FirestoreSchema.branchDocPath(
        txn.branchId,
        FirestoreSchema.financialTransactions,
        docId,
      ),
      financialTransactionToFirestore(created, orgId: organizationId),
    );
    return created;
  }
}

/// Daily cashbook closings (Week 4 Day 3, D126 — Firestore
/// implementation of [DailyClosingRepository], D101 pattern).
class FirestoreDailyClosingRepository
    with _FirestoreRepositoryHelper
    implements DailyClosingRepository {
  FirestoreDailyClosingRepository({
    required this.transport,
    required this.organizationId,
  });

  @override
  final FirestoreTransport transport;
  @override
  final String organizationId;

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  @override
  Future<List<DailyClosing>> getClosings({String? branchId}) async {
    final branches = branchId == null ? await branchIds() : [branchId];
    final closings = <DailyClosing>[];
    for (final id in branches) {
      final docs = await fetchAll(
        FirestoreSchema.branchCollection(id, FirestoreSchema.dailyClosings),
      );
      closings.addAll([
        for (final doc in docs) dailyClosingFromFirestore(doc.id, doc.data),
      ]);
    }
    return closings;
  }

  @override
  Future<DailyClosing?> getClosing({
    required String branchId,
    required DateTime date,
  }) async {
    final closings = await getClosings(branchId: branchId);
    for (final closing in closings) {
      if (_sameDay(closing.date, date)) return closing;
    }
    return null;
  }

  @override
  Future<DailyClosing> createClosing(DailyClosing closing) async {
    if (closing.branchId.isEmpty) {
      throw ArgumentError(
        'A branchId is required to create a daily closing in Firestore.',
      );
    }
    if (await getClosing(branchId: closing.branchId, date: closing.date) !=
        null) {
      throw ArgumentError('A closing already exists for this branch and day.');
    }
    final docId = closing.id.isNotEmpty
        ? closing.id
        : transport.newDocumentId(
            FirestoreSchema.branchCollection(
              closing.branchId,
              FirestoreSchema.dailyClosings,
            ),
          );
    final created = closing.copyWith(
      id: docId,
      closedAt: closing.closedAt ?? DateTime.now(),
    );
    await transport.setDocument(
      FirestoreSchema.branchDocPath(
        closing.branchId,
        FirestoreSchema.dailyClosings,
        docId,
      ),
      dailyClosingToFirestore(created, orgId: organizationId),
    );
    return created;
  }
}

/// Firestore implementation of [ClosingCorrectionRepository]
/// (Week 5 Day 4, D156 — D101 pattern).
class FirestoreClosingCorrectionRepository
    with _FirestoreRepositoryHelper
    implements ClosingCorrectionRepository {
  FirestoreClosingCorrectionRepository({
    required this.transport,
    required this.organizationId,
  });

  @override
  final FirestoreTransport transport;
  @override
  final String organizationId;

  @override
  Future<List<ClosingCorrection>> getCorrections({String? branchId}) async {
    final branches = branchId == null ? await branchIds() : [branchId];
    final corrections = <ClosingCorrection>[];
    for (final id in branches) {
      final docs = await fetchAll(
        FirestoreSchema.branchCollection(
          id,
          FirestoreSchema.closingCorrections,
        ),
      );
      corrections.addAll([
        for (final doc in docs)
          closingCorrectionFromFirestore(doc.id, doc.data),
      ]);
    }
    return corrections;
  }

  @override
  Future<List<ClosingCorrection>> getCorrectionsForClosing(
    String originalClosingId,
  ) async {
    final all = await getCorrections();
    final scoped = all
        .where((c) => c.originalClosingId == originalClosingId)
        .toList();
    scoped.sort((a, b) {
      final aAt = a.correctedAt;
      final bAt = b.correctedAt;
      if (aAt == null && bAt == null) return 0;
      if (aAt == null) return 1;
      if (bAt == null) return -1;
      return aAt.compareTo(bAt);
    });
    return scoped;
  }

  @override
  Future<ClosingCorrection> createCorrection(
    ClosingCorrection correction,
  ) async {
    if (correction.branchId.isEmpty) {
      throw ArgumentError(
        'A branchId is required to create a closing correction in Firestore.',
      );
    }
    final docId = correction.id.isNotEmpty
        ? correction.id
        : transport.newDocumentId(
            FirestoreSchema.branchCollection(
              correction.branchId,
              FirestoreSchema.closingCorrections,
            ),
          );
    final created = correction.copyWith(
      id: docId,
      correctedAt: correction.correctedAt ?? DateTime.now(),
    );
    await transport.setDocument(
      FirestoreSchema.branchDocPath(
        correction.branchId,
        FirestoreSchema.closingCorrections,
        docId,
      ),
      closingCorrectionToFirestore(created, orgId: organizationId),
    );
    return created;
  }
}

/// Firestore implementation of [CashReconciliationRepository]
/// (Week 5 Day 4, D157 — D101 pattern).
class FirestoreCashReconciliationRepository
    with _FirestoreRepositoryHelper
    implements CashReconciliationRepository {
  FirestoreCashReconciliationRepository({
    required this.transport,
    required this.organizationId,
  });

  @override
  final FirestoreTransport transport;
  @override
  final String organizationId;

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  @override
  Future<List<CashReconciliation>> getReconciliations({
    String? branchId,
  }) async {
    final branches = branchId == null ? await branchIds() : [branchId];
    final reconciliations = <CashReconciliation>[];
    for (final id in branches) {
      final docs = await fetchAll(
        FirestoreSchema.branchCollection(
          id,
          FirestoreSchema.cashReconciliations,
        ),
      );
      reconciliations.addAll([
        for (final doc in docs)
          cashReconciliationFromFirestore(doc.id, doc.data),
      ]);
    }
    return reconciliations;
  }

  @override
  Future<List<CashReconciliation>> getReconciliationsForDay({
    required String branchId,
    required DateTime date,
  }) async {
    final all = await getReconciliations(branchId: branchId);
    return all.where((r) => _sameDay(r.date, date)).toList();
  }

  @override
  Future<CashReconciliation> createReconciliation(
    CashReconciliation reconciliation,
  ) async {
    if (reconciliation.branchId.isEmpty) {
      throw ArgumentError(
        'A branchId is required to create a cash reconciliation in Firestore.',
      );
    }
    final docId = reconciliation.id.isNotEmpty
        ? reconciliation.id
        : transport.newDocumentId(
            FirestoreSchema.branchCollection(
              reconciliation.branchId,
              FirestoreSchema.cashReconciliations,
            ),
          );
    final created = reconciliation.copyWith(
      id: docId,
      countedAt: reconciliation.countedAt ?? DateTime.now(),
    );
    await transport.setDocument(
      FirestoreSchema.branchDocPath(
        reconciliation.branchId,
        FirestoreSchema.cashReconciliations,
        docId,
      ),
      cashReconciliationToFirestore(created, orgId: organizationId),
    );
    return created;
  }
}

class FirestoreSupplierPaymentRepository
    with _FirestoreRepositoryHelper
    implements SupplierPaymentRepository {
  FirestoreSupplierPaymentRepository({
    required this.transport,
    required this.organizationId,
  });

  @override
  final FirestoreTransport transport;
  @override
  final String organizationId;

  @override
  Future<List<SupplierPayment>> getPayments({
    String? branchId,
    String? supplierId,
  }) async {
    final branches = branchId == null ? await branchIds() : [branchId];
    final payments = <SupplierPayment>[];
    for (final id in branches) {
      final docs = await fetchAll(
        FirestoreSchema.branchCollection(id, FirestoreSchema.supplierPayments),
      );
      payments.addAll([
        for (final doc in docs) supplierPaymentFromFirestore(doc.id, doc.data),
      ]);
    }
    return payments
        .where(
          (payment) => supplierId == null || payment.supplierId == supplierId,
        )
        .toList();
  }

  @override
  Future<SupplierPayment> createPayment(SupplierPayment payment) async {
    if (payment.supplierId.isEmpty) {
      throw ArgumentError('A supplier payment needs a supplierId.');
    }
    if (payment.amountMinor <= 0) {
      throw ArgumentError('Payment amount must be more than zero.');
    }
    // The FIFO allocations must sum to the payment (D92 /
    // `validateSupplierPayment`): a shortfall means the outstanding
    // figure moved under the caller — refuse, never record
    // half-allocated. An empty allocation list is accepted (the
    // caller may allocate later); a non-empty one must add up.
    final allocated = payment.allocations.fold(
      0,
      (total, allocation) => total + allocation.amountMinor,
    );
    if (payment.allocations.isNotEmpty && allocated != payment.amountMinor) {
      throw ArgumentError(
        'Payment allocations ($allocated paisa) do not sum to the '
        'payment amount (${payment.amountMinor} paisa).',
      );
    }
    if (payment.branchId.isEmpty) {
      throw ArgumentError(
        'A branchId is required to create a supplier payment in '
        'Firestore.',
      );
    }
    final docId = payment.id.isNotEmpty
        ? payment.id
        : transport.newDocumentId(
            FirestoreSchema.branchCollection(
              payment.branchId,
              FirestoreSchema.supplierPayments,
            ),
          );
    // Caller id = doc id (D65 pattern): a retry returns the original.
    final existing = await transport.getDocument(
      FirestoreSchema.branchDocPath(
        payment.branchId,
        FirestoreSchema.supplierPayments,
        docId,
      ),
    );
    if (existing != null) {
      return supplierPaymentFromFirestore(docId, existing);
    }
    final created = payment.copyWith(id: docId, createdAt: DateTime.now());
    await transport.setDocument(
      FirestoreSchema.branchDocPath(
        payment.branchId,
        FirestoreSchema.supplierPayments,
        docId,
      ),
      supplierPaymentToFirestore(created, orgId: organizationId),
    );
    return created;
  }
}

// -- Goods receipts + salaries (Week 3 Day 2, D102/D103) ------------------
//
// Same conventions as the Day 3 / Day 1 repos (D73/D100): doc id =
// idempotency key on create (a retry returns the existing document),
// sequential numbers from counter docs starting at 1001, branch
// enumeration for null-branch reads, updates preserve `createdAt`
// and no-op on a missing id, no hard deletes.

class FirestoreGoodsReceiptRepository
    with _FirestoreRepositoryHelper
    implements GoodsReceiptRepository {
  FirestoreGoodsReceiptRepository({
    required this.transport,
    required this.organizationId,
  });

  @override
  final FirestoreTransport transport;
  @override
  final String organizationId;

  Future<GoodsReceipt> _withItems(
    String branchId,
    FirestoreDocument doc,
  ) async {
    final itemDocs = await fetchAll(
      FirestoreSchema.goodsReceiptItemsPath(branchId, doc.id),
    );
    return goodsReceiptFromFirestore(
      doc.id,
      doc.data,
      itemDocs: [for (final item in itemDocs) item.data],
    );
  }

  @override
  Future<List<GoodsReceipt>> getGoodsReceipts({
    String? branchId,
    String? poId,
  }) async {
    final branches = branchId == null ? await branchIds() : [branchId];
    final receipts = <GoodsReceipt>[];
    for (final id in branches) {
      final docs = await fetchAll(FirestoreSchema.goodsReceiptsPath(id));
      for (final doc in docs) {
        final receipt = await _withItems(id, doc);
        if (poId == null || receipt.poId == poId) {
          receipts.add(receipt);
        }
      }
    }
    return receipts;
  }

  @override
  Future<GoodsReceipt?> getById(String id) async {
    final found = await findInBranches(FirestoreSchema.goodsReceipts, id);
    if (found == null) return null;
    return _withItems(found.branchId, found.doc);
  }

  @override
  Future<GoodsReceipt> createGoodsReceipt(GoodsReceipt receipt) async {
    if (receipt.poId.isEmpty) {
      throw ArgumentError('A goods receipt needs a purchase order.');
    }
    if (receipt.branchId.isEmpty) {
      throw ArgumentError(
        'A branchId is required to create a goods receipt in Firestore.',
      );
    }
    final docId = receipt.id.isNotEmpty
        ? receipt.id
        : transport.newDocumentId(
            FirestoreSchema.goodsReceiptsPath(receipt.branchId),
          );
    // Caller id = doc id (D65 pattern): a retry returns the original.
    final existing = await transport.getDocument(
      FirestoreSchema.goodsReceiptDocPath(receipt.branchId, docId),
    );
    if (existing != null) {
      return _withItems(
        receipt.branchId,
        FirestoreDocument(id: docId, data: existing),
      );
    }
    final sequence = await nextCounterValue(
      receipt.branchId,
      _goodsReceiptsCounterId,
    );
    final code = await branchCode(receipt.branchId);
    final created = receipt.copyWith(
      id: docId,
      receiptNumber: 'GR-$code-$sequence',
      receivedAt: receipt.receivedAt ?? DateTime.now(),
      createdAt: DateTime.now(),
    );
    final operations = <WriteOperation>[
      WriteOperation(
        path: FirestoreSchema.goodsReceiptDocPath(receipt.branchId, docId),
        kind: WriteOperationKind.set,
        data: goodsReceiptToFirestore(created, orgId: organizationId),
      ),
      for (var i = 0; i < created.items.length; i++)
        WriteOperation(
          path:
              '${FirestoreSchema.goodsReceiptItemsPath(receipt.branchId, docId)}/item-$i',
          kind: WriteOperationKind.set,
          data: goodsReceiptItemToFirestore(
            created.items[i],
            orgId: organizationId,
            branchId: receipt.branchId,
          ),
        ),
    ];
    await transport.runBatchedWrites(operations);
    return created;
  }
}

class FirestoreSalaryRepository
    with _FirestoreRepositoryHelper
    implements SalaryRepository {
  FirestoreSalaryRepository({
    required this.transport,
    required this.organizationId,
  });

  @override
  final FirestoreTransport transport;
  @override
  final String organizationId;

  @override
  Future<List<SalaryRecord>> getSalaryRecords({
    String? branchId,
    String? month,
  }) async {
    final branches = branchId == null ? await branchIds() : [branchId];
    final records = <SalaryRecord>[];
    for (final id in branches) {
      final docs = await fetchAll(FirestoreSchema.salariesPath(id));
      for (final doc in docs) {
        final record = salaryRecordFromFirestore(doc.id, doc.data);
        if (month == null || record.month == month) {
          records.add(record);
        }
      }
    }
    return records;
  }

  @override
  Future<SalaryRecord?> getById(String id) async {
    final found = await findInBranches(FirestoreSchema.salaries, id);
    if (found == null) return null;
    return salaryRecordFromFirestore(found.doc.id, found.doc.data);
  }

  @override
  Future<SalaryRecord> saveSalaryRecord(SalaryRecord record) async {
    // Repository re-checks (D100 pattern — mirrors the pure
    // `validateSalaryRecord` in salary_logic.dart): negative
    // amounts, a bad month, or a negative net never reach the store.
    if (record.employeeId.isEmpty || record.branchId.isEmpty) {
      throw ArgumentError('A salary record needs an employee and a branch.');
    }
    if (!RegExp(r'^\d{4}-(0[1-9]|1[0-2])$').hasMatch(record.month)) {
      throw ArgumentError('Month must look like YYYY-MM (e.g. 2026-11).');
    }
    if (record.baseSalaryMinor < 0 ||
        record.allowancesMinor < 0 ||
        record.deductionsMinor < 0) {
      throw ArgumentError('Salary amounts cannot be negative.');
    }
    if (record.netMinor < 0) {
      throw ArgumentError(
        'Net salary cannot be negative — deductions exceed pay.',
      );
    }
    // Doc id is derived from (employee, month) when the caller did
    // not supply one: a re-save overwrites the same record, never
    // a duplicate — idempotent by construction (D102).
    final docId = record.id.isNotEmpty
        ? record.id
        : 'sal-${record.employeeId}-${record.month}';
    final existing = await transport.getDocument(
      FirestoreSchema.salaryDocPath(record.branchId, docId),
    );
    final saved = record.copyWith(
      id: docId,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    final doc = salaryRecordToFirestore(saved, orgId: organizationId);
    // A rewrite keeps the original `createdAt` (see updateOrder).
    if (existing != null) {
      doc['createdAt'] = existing['createdAt'];
    }
    await transport.setDocument(
      FirestoreSchema.salaryDocPath(record.branchId, docId),
      doc,
    );
    return saved;
  }
}

/// Daily report counters (Week 3 Day 3, D105/D106).
///
/// Reads ONLY — the rollup Function owns the writes (Job 3). There
/// is deliberately no create/update method here: a client that could
/// write its own counters could fake the reports, so the repository
/// surface is read-only and the rules draft must deny client writes
/// to `counters/daily-*` (see `firebase/firestore.rules`).
class FirestoreReportCounterRepository
    with _FirestoreRepositoryHelper
    implements ReportCounterRepository {
  FirestoreReportCounterRepository({
    required this.transport,
    required this.organizationId,
  });

  @override
  final FirestoreTransport transport;
  @override
  final String organizationId;

  @override
  Future<DailyCounter?> getDailyCounter({
    required String branchId,
    required DateTime date,
  }) async {
    final data = await transport.getDocument(
      FirestoreSchema.dailyCounterDocPath(branchId, date),
    );
    if (data == null) return null;
    return dailyCounterFromFirestore(
      FirestoreSchema.dailyCounterDocId(date),
      data,
    );
  }

  @override
  Future<List<DailyCounter>> getDailyCounters({
    required String branchId,
    required DateTime start,
    required DateTime end,
  }) async {
    // Deterministic doc ids (`daily-{yyyy-MM-dd}`) mean a range read
    // is one exact document read per day — at most 31 reads for a
    // 30-day window, no collection scan, no composite index. Days
    // with no rollup doc are omitted (never zero-filled): a short
    // list is incomplete coverage and the reports provider falls
    // back to the live computation (D106).
    final counters = <DailyCounter>[];
    final startDay = DateTime(start.year, start.month, start.day);
    final endDay = DateTime(end.year, end.month, end.day);
    var day = startDay;
    while (!day.isAfter(endDay)) {
      final counter = await getDailyCounter(branchId: branchId, date: day);
      if (counter != null) counters.add(counter);
      day = day.add(const Duration(days: 1));
    }
    return counters;
  }

  @override
  Future<CounterPage> listDailyCountersPaged({
    required String branchId,
    int pageSize = reportPageSize,
    String? startAfterId,
  }) async {
    // The transport's paged fetch (document-id order, oldest first).
    // The counters collection also holds the sequential-number docs
    // (`invoices`, `orders`, …), so pages are filtered to `daily-*`
    // ids and fetching continues until the page is full or the
    // collection is exhausted — a page of daily counters is never
    // short just because a sequential counter sorted in between.
    final counters = <DailyCounter>[];
    var cursor = startAfterId;
    var hasMore = false;
    for (
      var attempt = 0;
      attempt < 10 && counters.length < pageSize;
      attempt++
    ) {
      final page = await transport.queryCollection(
        FirestoreSchema.countersPath(branchId),
        limit: pageSize,
        startAfterId: cursor,
      );
      if (page.isEmpty) break;
      for (final doc in page) {
        if (doc.id.startsWith('daily-')) {
          counters.add(dailyCounterFromFirestore(doc.id, doc.data));
          if (counters.length == pageSize) break;
        }
      }
      hasMore = page.length == pageSize;
      cursor = page.last.id;
      if (page.length < pageSize) break;
    }
    return CounterPage(
      counters: counters,
      nextCursor: hasMore && counters.isNotEmpty ? cursor : null,
      hasMore: hasMore,
    );
  }
}
