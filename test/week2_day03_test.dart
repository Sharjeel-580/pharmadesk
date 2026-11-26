// Week 2 Day 3 tests — Firestore implementations + auth wiring.
//
// The Firestore repositories run against an in-memory fake transport
// (there is no Firebase project yet — D13), so every test below runs
// offline: mapper round-trips, batch chunking (≤500), pagination,
// idempotency doc ids, the batch-status guard, the mock auth
// repository + claims mapping, the permission service, the
// factory switch, the prescription photo upload rules, the
// FeatureGate permission state, and the POS key-holding rule (D54).

import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart' hide Order;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmadesk/core/data/auth_repository.dart';
import 'package:pharmadesk/core/data/firestore_mappers.dart';
import 'package:pharmadesk/core/data/firestore_repositories.dart';
import 'package:pharmadesk/core/data/firestore_schema.dart';
import 'package:pharmadesk/core/data/firestore_transport.dart';
import 'package:pharmadesk/core/data/inventory_engine.dart'
    show WriteOperation, WriteOperationKind;
import 'package:pharmadesk/core/data/permission_service.dart';
import 'package:pharmadesk/core/data/prescription_storage.dart';
import 'package:pharmadesk/core/data/repository_factory.dart';
import 'package:pharmadesk/core/services/repositories.dart';
import 'package:pharmadesk/core/widgets/buttons.dart';
import 'package:pharmadesk/features/authentication/auth_state.dart';
import 'package:pharmadesk/features/billing/billing_logic.dart';
import 'package:pharmadesk/features/billing/billing_provider.dart';
import 'package:pharmadesk/features/inventory/inventory_logic.dart';
import 'package:pharmadesk/features/prescriptions/prescription_detail_screen.dart';
import 'package:pharmadesk/features/settings/feature_gate.dart';
import 'package:pharmadesk/features/settings/roles_permissions.dart';
import 'package:pharmadesk/models/customer.dart';
import 'package:pharmadesk/models/customer_ledger.dart';
import 'package:pharmadesk/models/inventory_item.dart';
import 'package:pharmadesk/models/medicine.dart';
import 'package:pharmadesk/models/order.dart';
import 'package:pharmadesk/models/prescription.dart';
import 'package:pharmadesk/models/purchase_order.dart';
import 'package:pharmadesk/models/rider.dart';
import 'package:pharmadesk/models/sale.dart';
import 'package:pharmadesk/models/supplier.dart';
import 'package:pharmadesk/models/supplier_ledger.dart';


/// In-memory [FirestoreTransport]: documents live in a map keyed by
/// full path. Behaves like Firestore for the operations the
/// repositories use (get / query with equality filter + document-id
/// ordering + startAfter / limit / batch chunking at 500 /
/// transactions).
///
/// Week 7 Day 2 (D172): [runTransaction] and [runBatchedWrites] are
/// atomic — both work on a copy of the store and commit it only when
/// every write succeeds, so a failed transaction or batch applies
/// nothing. (Real Firestore is atomic per 500-op batch chunk, not
/// across chunks — the fake is deliberately stricter: a whole
/// `runBatchedWrites` call is all-or-nothing. No repo call in the app
/// builds a multi-chunk list whose middle chunk can fail, so the
/// stricter fake never hides a real partial commit.)
class FakeFirestoreTransport implements FirestoreTransport {
  final Map<String, Map<String, dynamic>> docs = {};

  /// Chunk sizes of every [runBatchedWrites] call (test seam).
  final List<List<int>> batchChunks = [];

  int _autoId = 0;

  @override
  Future<Map<String, dynamic>?> getDocument(String path) async {
    final data = docs[path];
    return data == null ? null : Map<String, dynamic>.from(data);
  }

  @override
  Future<List<FirestoreDocument>> queryCollection(
    String collectionPath, {
    Map<String, Object?> whereEquals = const {},
    String? orderBy,
    bool descending = false,
    int? limit,
    String? startAfterId,
  }) async {
    var entries = docs.entries.where((entry) {
      if (!entry.key.startsWith('$collectionPath/')) return false;
      // Direct children only — deeper paths are subcollections.
      return !entry.key.substring(collectionPath.length + 1).contains('/');
    }).toList();
    for (final filter in whereEquals.entries) {
      entries = entries
          .where((entry) => entry.value[filter.key] == filter.value)
          .toList();
    }
    int compare(FirestoreDocument a, FirestoreDocument b) {
      if (orderBy == null) return a.id.compareTo(b.id);
      final cmp = _compareValues(a.data[orderBy], b.data[orderBy]);
      return descending ? -cmp : cmp;
    }

    final found = [
      for (final entry in entries)
        FirestoreDocument(
          id: entry.key.split('/').last,
          data: Map<String, dynamic>.from(entry.value),
        ),
    ]..sort(compare);
    var page = found;
    if (startAfterId != null) {
      final index = page.indexWhere((doc) => doc.id == startAfterId);
      if (index != -1) page = page.sublist(index + 1);
    }
    if (limit != null && page.length > limit) {
      page = page.sublist(0, limit);
    }
    return page;
  }

  static int _compareValues(dynamic a, dynamic b) {
    if (a is Comparable && b is Comparable) {
      try {
        return a.compareTo(b);
      } on Object {
        // Mixed types (e.g. Timestamp vs String): fall through.
      }
    }
    return a.toString().compareTo(b.toString());
  }

  @override
  Future<void> setDocument(
    String path,
    Map<String, dynamic> data, {
    bool merge = false,
  }) async {
    if (merge && docs.containsKey(path)) {
      docs[path] = {...docs[path]!, ...data};
    } else {
      docs[path] = Map<String, dynamic>.from(data);
    }
  }

  @override
  Future<void> updateDocument(String path, Map<String, dynamic> data) async {
    final existing = docs[path];
    if (existing == null) {
      throw StateError('No document at $path to update.');
    }
    docs[path] = {...existing, ...data};
  }

  @override
  Future<String> addDocument(
    String collectionPath,
    Map<String, dynamic> data,
  ) async {
    final id = newDocumentId(collectionPath);
    docs['$collectionPath/$id'] = Map<String, dynamic>.from(data);
    return id;
  }

  /// A copy of [docs] with each document map copied too, so a
  /// transaction or batch can work on it and commit it only on
  /// success (D172 — a failed transaction / batch applies nothing).
  static Map<String, Map<String, dynamic>> _copyDocs(
    Map<String, Map<String, dynamic>> source,
  ) => {
    for (final entry in source.entries)
      entry.key: Map<String, dynamic>.from(entry.value),
  };

  @override
  Future<void> runBatchedWrites(List<WriteOperation> operations) async {
    // All-or-nothing (D172): apply every operation — across all
    // 500-op chunks — to a working copy and commit it only when the
    // whole list succeeds. A single bad operation (e.g. an update
    // of a missing document) leaves the store exactly as it was,
    // including the operations in earlier chunks.
    final working = _copyDocs(docs);
    for (var i = 0; i < operations.length; i += maxFirestoreBatchWrites) {
      final end = (i + maxFirestoreBatchWrites).clamp(0, operations.length);
      final chunk = operations.sublist(i, end);
      batchChunks.add([chunk.length]);
      for (final operation in chunk) {
        switch (operation.kind) {
          case WriteOperationKind.set:
            working[operation.path] = Map<String, dynamic>.from(
              operation.data ?? const {},
            );
          case WriteOperationKind.update:
            final existing = working[operation.path];
            if (existing == null) {
              throw StateError('No document at ${operation.path} to update.');
            }
            working[operation.path] = {...existing, ...?operation.data};
          case WriteOperationKind.delete:
            working.remove(operation.path);
        }
      }
    }
    docs
      ..clear()
      ..addAll(working);
  }

  @override
  Future<T> runTransaction<T>(
    Future<T> Function(FirestoreTransaction tx) action,
  ) async {
    // Commit/rollback (D172): the transaction works on a copy, so
    // its reads see its own writes and a throw discards every write
    // it made — the store is untouched. Only a completed action
    // commits, all at once.
    final working = _copyDocs(docs);
    final result = await action(_FakeTransaction(working));
    docs
      ..clear()
      ..addAll(working);
    return result;
  }

  @override
  String newDocumentId(String collectionPath) {
    _autoId += 1;
    return 'auto-$_autoId';
  }

  /// Counts documents directly under [collectionPath].
  int countIn(String collectionPath) {
    return docs.keys.where((path) {
      if (!path.startsWith('$collectionPath/')) return false;
      return !path.substring(collectionPath.length + 1).contains('/');
    }).length;
  }
}

class _FakeTransaction implements FirestoreTransaction {
  _FakeTransaction(this.docs);

  final Map<String, Map<String, dynamic>> docs;

  @override
  Future<Map<String, dynamic>?> get(String path) async {
    final data = docs[path];
    return data == null ? null : Map<String, dynamic>.from(data);
  }

  @override
  void set(String path, Map<String, dynamic> data, {bool merge = false}) {
    if (merge && docs.containsKey(path)) {
      docs[path] = {...docs[path]!, ...data};
    } else {
      docs[path] = Map<String, dynamic>.from(data);
    }
  }

  @override
  void update(String path, Map<String, dynamic> data) {
    final existing = docs[path];
    if (existing == null) {
      throw StateError('No document at $path to update.');
    }
    docs[path] = {...existing, ...data};
  }
}

/// Seeds the two demo branch docs (the repositories enumerate
/// `branches` for branch-less reads and read `code` for numbers).
Future<void> seedBranches(FakeFirestoreTransport transport) async {
  await transport.setDocument('branches/branch-dha-main', {
    'organizationId': demoOrganizationId,
    'name': 'Demo Branch — DHA',
    'code': 'DHA',
    'type': 'own',
    'status': 'active',
  });
  await transport.setDocument('branches/branch-demo-gulberg', {
    'organizationId': demoOrganizationId,
    'name': 'Demo Branch — Gulberg',
    'code': 'GLB',
    'type': 'own',
    'status': 'active',
  });
}

Sale sampleSale({String key = 'sale-test-1'}) {
  return Sale(
    id: '',
    invoiceNumber: '',
    branchId: 'branch-dha-main',
    customerId: 'cust-1',
    cashierName: 'Usman Tariq',
    items: const [
      SaleItem(
        medicineId: 'med-1',
        medicineName: 'Panadol',
        quantity: 2,
        unitPriceMinor: 10000,
        batchId: 'batch-1',
        batchNo: 'B-100',
      ),
    ],
    subtotalMinor: 20000,
    billDiscountMinor: 0,
    taxMinor: 0,
    totalMinor: 20000,
    paymentMethod: SalePaymentMethod.cash,
    cashReceivedMinor: 20000,
    idempotencyKey: key,
    createdAt: DateTime(2026, 11, 25, 10, 0),
  );
}

Order sampleOrder({String id = ''}) {
  return Order(
    id: id,
    customerId: 'cust-1',
    branchId: 'branch-dha-main',
    items: const [
      OrderItem(
        medicineId: 'med-1',
        medicineName: 'Panadol',
        quantity: 2,
        unitPrice: 100.0,
      ),
    ],
    deliveryAddress: 'Street 1, DHA',
    totalAmount: 200.0,
    discountMinor: 500,
    status: OrderStatus.newOrder,
    source: OrderSource.walkIn,
    createdAt: DateTime(2026, 11, 25, 10, 0),
  );
}

void main() {
  group('Firestore mappers — round-trips use the SRS §3 field names', () {
    test('sale: schema names, extras, and an exact rebuild', () {
      final sale = sampleSale();
      final doc = saleToFirestore(sale, orgId: demoOrganizationId);
      expect(doc['grandTotal'], 20000);
      expect(doc['subtotal'], 20000);
      expect(doc['discountTotal'], 0);
      expect(doc['taxTotal'], 0);
      expect(doc['idempotencyKey'], 'sale-test-1');
      expect(doc['status'], 'completed');
      expect(doc['organizationId'], demoOrganizationId);
      expect(doc['branchId'], 'branch-dha-main');
      expect(doc['createdAt'], isA<Timestamp>());
      // No embedded items on the doc — they live in the subcollection.
      expect(doc.containsKey('items'), isFalse);

      final itemDoc = saleItemToFirestore(sale.items.first);
      expect(itemDoc['unitPrice'], 10000);
      expect(itemDoc['discount'], 0);
      expect(itemDoc['lineTotal'], 20000);
      expect(itemDoc['batchNo'], 'B-100');

      final rebuilt = saleFromFirestore(
        'sale-test-1',
        doc,
        itemDocs: [itemDoc],
      );
      expect(rebuilt.invoiceNumber, sale.invoiceNumber);
      expect(rebuilt.totalMinor, 20000);
      expect(rebuilt.paymentMethod, SalePaymentMethod.cash);
      expect(rebuilt.cashReceivedMinor, 20000);
      expect(rebuilt.items.single.unitPriceMinor, 10000);
      expect(rebuilt.items.single.batchNo, 'B-100');
      expect(rebuilt.idempotencyKey, 'sale-test-1');
    });

    test('order: status/source mapping + paisa conversion', () {
      final order = sampleOrder();
      final doc = orderToFirestore(
        order,
        orgId: demoOrganizationId,
        orderNumber: 'ORD-DHA-1001',
      );
      expect(doc['status'], 'pending');
      expect(doc['source'], 'walk_in');
      expect(doc['grandTotal'], 19500);
      expect(doc['subtotal'], 20000);
      expect(doc['discountMinor'], 500);

      final itemDoc = orderItemToFirestore(order.items.first);
      expect(itemDoc['unitPrice'], 10000);
      expect(itemDoc['lineTotal'], 20000);

      final rebuilt = orderFromFirestore('order-1', doc, itemDocs: [itemDoc]);
      expect(rebuilt.status, OrderStatus.newOrder);
      expect(rebuilt.source, OrderSource.walkIn);
      expect(rebuilt.totalMinor, 19500);
      expect(rebuilt.items.single.unitPrice, 100.0);

      // `ready` has no §3 equivalent: it writes as `preparing`
      // and reads back as `processing` (documented lossy mapping).
      expect(orderStatusToFirestore(OrderStatus.ready), 'preparing');
      expect(orderStatusFromFirestore('preparing'), OrderStatus.processing);
      expect(
        orderStatusToFirestore(OrderStatus.dispatched),
        'out_for_delivery',
      );
      expect(
        orderStatusFromFirestore('out_for_delivery'),
        OrderStatus.dispatched,
      );
    });

    test('medicine: selling price in paisa, prescription class', () {
      const medicine = Medicine(
        id: 'med-1',
        name: 'Panadol',
        brand: 'GSK',
        categoryId: 'cat-1',
        strength: '500mg',
        packSize: '20 tablets',
        price: 250.0,
        purchasePriceMinor: 20000,
        barcode: '1234567890123',
        requiresPrescription: true,
      );
      final doc = medicineToFirestore(medicine, orgId: demoOrganizationId);
      expect(doc['sellingPrice'], 25000);
      expect(doc['purchasePrice'], 20000);
      expect(doc['prescriptionClass'], 'prescription');
      expect(doc['barcode'], '1234567890123');

      final rebuilt = medicineFromFirestore('med-1', doc);
      expect(rebuilt.price, 250.0);
      expect(rebuilt.purchasePriceMinor, 20000);
      expect(rebuilt.requiresPrescription, isTrue);
      expect(rebuilt.barcode, '1234567890123');
    });

    test('batch: status + quantities survive the round-trip', () {
      final batch = InventoryItem(
        id: 'batch-1',
        medicineId: 'med-1',
        branchId: 'branch-dha-main',
        quantity: 10,
        lowStockThreshold: 5,
        expiryDate: DateTime(2027, 6, 1),
        batchNo: 'B-100',
        mfgDate: DateTime(2026, 1, 1),
        costMinor: 8000,
        status: BatchStatus.quarantined,
      );
      final doc = batchToFirestore(batch, orgId: demoOrganizationId);
      expect(doc['status'], 'quarantined');
      expect(doc['quantityReceived'], 10);
      expect(doc['quantityRemaining'], 10);
      expect(doc['purchasePrice'], 8000);
      expect(doc['batchNumber'], 'B-100');

      final rebuilt = batchFromFirestore('batch-1', doc);
      expect(rebuilt.status, BatchStatus.quarantined);
      expect(rebuilt.quantity, 10);
      expect(rebuilt.costMinor, 8000);
      expect(rebuilt.lowStockThreshold, 5);

      // Unknown / missing status parses as available (legacy rows).
      expect(batchStatusFromString(null), BatchStatus.available);
      expect(batchStatusFromString('weird'), BatchStatus.available);
      final legacy = batchFromFirestore('batch-2', {
        'medicineId': 'med-1',
        'quantityRemaining': 3,
      });
      expect(legacy.status, BatchStatus.available);
      expect(legacy.quantity, 3);
    });

    test('customer + ledgers: §3 amount/balanceAfter names', () {
      const customer = Customer(
        id: 'cust-1',
        name: 'Ali',
        phone: '03001234567',
        addresses: [
          CustomerAddress(
            label: 'Home',
            address: 'St 1',
            city: 'Lahore',
            isDefault: true,
          ),
        ],
        creditLimitMinor: 100000,
      );
      final doc = customerToFirestore(
        customer,
        orgId: demoOrganizationId,
        branchId: 'branch-dha-main',
      );
      expect(doc['creditLimit'], 100000);
      expect(doc['phone'], '03001234567');
      final rebuilt = customerFromFirestore('cust-1', doc);
      expect(rebuilt.creditLimitMinor, 100000);
      expect(rebuilt.addresses.single.city, 'Lahore');

      final entry = LedgerEntry(
        id: 'led-1',
        customerId: 'cust-1',
        kind: LedgerEntryKind.creditSale,
        amountMinor: 50000,
        reason: 'Credit sale INV-1',
        referenceId: 'sale-1',
        balanceAfterMinor: 50000,
        createdAt: DateTime(2026, 11, 25),
      );
      final entryDoc = customerLedgerEntryToFirestore(
        entry,
        orgId: demoOrganizationId,
        branchId: 'branch-dha-main',
      );
      expect(entryDoc['amount'], 50000);
      expect(entryDoc['balanceAfter'], 50000);
      expect(entryDoc['type'], 'creditSale');
      final rebuiltEntry = customerLedgerEntryFromFirestore('led-1', entryDoc);
      expect(rebuiltEntry.amountMinor, 50000);
      expect(rebuiltEntry.balanceAfterMinor, 50000);
      expect(rebuiltEntry.reason, 'Credit sale INV-1');

      const supplierEntry = SupplierLedgerEntry(
        id: 'sled-1',
        supplierId: 'sup-1',
        kind: SupplierLedgerEntryKind.purchase,
        amountMinor: 80000,
        reason: 'PO received',
        referenceId: 'po-1',
        balanceAfterMinor: 80000,
      );
      final supplierDoc = supplierLedgerEntryToFirestore(
        supplierEntry,
        orgId: demoOrganizationId,
      );
      expect(supplierDoc['amount'], 80000);
      expect(supplierDoc['balanceAfter'], 80000);
      final rebuiltSupplier = supplierLedgerEntryFromFirestore(
        'sled-1',
        supplierDoc,
      );
      expect(rebuiltSupplier.amountMinor, 80000);
      expect(rebuiltSupplier.kind, SupplierLedgerEntryKind.purchase);
    });

    test('supplier + rider round-trips', () {
      const supplier = Supplier(
        id: 'sup-1',
        name: 'Pharma Distributors',
        contactPerson: 'Ahmed',
        phone: '03007654321',
      );
      final supplierDoc = supplierToFirestore(
        supplier,
        orgId: demoOrganizationId,
      );
      expect(supplierFromFirestore('sup-1', supplierDoc).phone, '03007654321');

      const rider = Rider(
        id: 'rider-1',
        name: 'Bilal',
        phone: '03001112222',
        vehicle: 'Bike',
      );
      final riderDoc = riderToFirestore(
        rider,
        orgId: demoOrganizationId,
        branchId: 'branch-dha-main',
      );
      expect(riderDoc['status'], 'active');
      final rebuilt = riderFromFirestore('rider-1', riderDoc);
      expect(rebuilt.active, isTrue);
      expect(rebuilt.vehicle, 'Bike');
    });

    test('prescription: reviewStatus + Storage metadata', () {
      final rx = Prescription(
        id: 'rx-1',
        customerId: 'cust-1',
        orderId: 'ord-1',
        imageUrl: 'assets/images/prescriptions/sample-prescription-1.png',
        status: PrescriptionStatus.pending,
        branchId: 'branch-dha-main',
        photoStoragePath: 'organizations/org-x/branches/branch-dha-main/prescriptions/rx-1.jpg',
        photoContentType: 'image/jpeg',
        photoUploadedAt: DateTime(2026, 11, 25, 9, 0),
        photoUploadedBy: 'demo-pharmacist',
        localPhotoPath: 'prescriptions/rx-1.jpg',
        medicinesText: 'Panadol 2x daily',
      );
      final doc = prescriptionToFirestore(
        rx,
        orgId: 'org-x',
        branchId: 'branch-dha-main',
      );
      expect(doc['reviewStatus'], 'pending');
      expect(
        doc['photoStoragePath'],
        'organizations/org-x/branches/branch-dha-main/prescriptions/rx-1.jpg',
      );
      expect(doc['photoContentType'], 'image/jpeg');
      expect(doc['photoUploadedBy'], 'demo-pharmacist');
      final rebuilt = prescriptionFromFirestore('rx-1', doc);
      expect(rebuilt.status, PrescriptionStatus.pending);
      expect(rebuilt.branchId, 'branch-dha-main');
      expect(rebuilt.photoStoragePath, rx.photoStoragePath);
      expect(rebuilt.localPhotoPath, 'prescriptions/rx-1.jpg');
      expect(rebuilt.medicinesText, 'Panadol 2x daily');
    });

    test('purchase order: snake_case status + items separate', () {
      const po = PurchaseOrder(
        id: 'po-1',
        poNumber: '',
        supplierId: 'sup-1',
        branchId: 'branch-dha-main',
        status: PurchaseOrderStatus.partiallyReceived,
        items: [
          PurchaseOrderItem(
            medicineId: 'med-1',
            medicineName: 'Panadol',
            quantityOrdered: 10,
            quantityReceived: 4,
            unitCostMinor: 8000,
          ),
        ],
      );
      final doc = purchaseOrderToFirestore(
        po,
        orgId: demoOrganizationId,
        poNumber: 'PO-DHA-1001',
      );
      expect(doc['status'], 'partially_received');
      expect(doc['totalAmount'], 80000);
      expect(doc.containsKey('items'), isFalse);
      final itemDoc = purchaseOrderItemToFirestore(po.items.first);
      final rebuilt = purchaseOrderFromFirestore(
        'po-1',
        doc,
        itemDocs: [itemDoc],
      );
      expect(rebuilt.status, PurchaseOrderStatus.partiallyReceived);
      expect(rebuilt.items.single.quantityReceived, 4);
      expect(rebuilt.totalMinor, 80000);
    });

    test('validateOrThrow rejects a doc missing a required field', () {
      expect(
        () => validateOrThrow('branches/{branchId}/sales', {
          'invoiceNumber': 'INV-1',
        }),
        throwsArgumentError,
      );
      expect(
        FirestoreSchema.validateDocument('branches/{branchId}/sales', {
          'invoiceNumber': 'INV-1',
          'subtotal': 100,
          'grandTotal': 100,
          'idempotencyKey': 'k',
          'organizationId': demoOrganizationId,
          'createdAt': Timestamp.now(),
          'updatedAt': Timestamp.now(),
        }),
        isEmpty,
      );
    });

    test('idempotency keys: slash breaks the doc id, empty is invalid', () {
      expect(FirestoreSchema.isValidIdempotencyKey('sale-dha-123'), isTrue);
      expect(FirestoreSchema.isValidIdempotencyKey(''), isFalse);
      expect(FirestoreSchema.isValidIdempotencyKey('a/b'), isFalse);
      expect(counterValueFromFirestore(null), 0);
      expect(counterValueFromFirestore({'value': 1005}), 1005);
    });
  });

  group('Fake transport — batch chunking + pagination', () {
    test('1200 writes chunk into 500 / 500 / 200', () async {
      final transport = FakeFirestoreTransport();
      final operations = [
        for (var i = 0; i < 1200; i++)
          WriteOperation(
            path: 'medicines/doc-$i',
            kind: WriteOperationKind.set,
            data: {'name': 'Med $i'},
          ),
      ];
      await transport.runBatchedWrites(operations);
      expect(transport.batchChunks.expand((chunk) => chunk).toList(), [
        500,
        500,
        200,
      ]);
      expect(transport.countIn('medicines'), 1200);
    });

    test('a batch that fits stays a single chunk', () async {
      final transport = FakeFirestoreTransport();
      await transport.runBatchedWrites([
        WriteOperation(
          path: 'medicines/doc-1',
          kind: WriteOperationKind.set,
          data: {'name': 'Med 1'},
        ),
      ]);
      expect(transport.batchChunks.expand((chunk) => chunk).toList(), [1]);
    });

    test('query pages by document id with startAfter', () async {
      final transport = FakeFirestoreTransport();
      for (var i = 0; i < 120; i++) {
        await transport.setDocument(
          'medicines/med-${i.toString().padLeft(3, '0')}',
          {'name': 'Med $i', 'sellingPrice': 1000 + i},
        );
      }
      final first = await transport.queryCollection('medicines', limit: 50);
      expect(first.length, 50);
      final second = await transport.queryCollection(
        'medicines',
        limit: 50,
        startAfterId: first.last.id,
      );
      expect(second.length, 50);
      final third = await transport.queryCollection(
        'medicines',
        limit: 50,
        startAfterId: second.last.id,
      );
      expect(third.length, 20);
      final allIds = [
        ...first.map((doc) => doc.id),
        ...second.map((doc) => doc.id),
        ...third.map((doc) => doc.id),
      ];
      expect(allIds.toSet().length, 120);

      final byBarcode = await transport.queryCollection(
        'medicines',
        whereEquals: {'name': 'Med 7'},
      );
      expect(byBarcode.length, 1);
      expect(byBarcode.single.id, 'med-007');
    });
  });

  group('Firestore repositories — fake transport, real code paths', () {
    late FakeFirestoreTransport transport;

    setUp(() async {
      transport = FakeFirestoreTransport();
      await seedBranches(transport);
    });

    FirestoreSaleRepository salesRepo() => FirestoreSaleRepository(
      transport: transport,
      organizationId: demoOrganizationId,
    );
    FirestoreOrderRepository ordersRepo() => FirestoreOrderRepository(
      transport: transport,
      organizationId: demoOrganizationId,
    );
    FirestorePurchaseOrderRepository poRepo() =>
        FirestorePurchaseOrderRepository(
          transport: transport,
          organizationId: demoOrganizationId,
        );
    FirestoreMedicineRepository medicineRepo() => FirestoreMedicineRepository(
      transport: transport,
      organizationId: demoOrganizationId,
    );
    FirestoreInventoryRepository inventoryRepo() =>
        FirestoreInventoryRepository(
          transport: transport,
          organizationId: demoOrganizationId,
        );
    FirestoreCustomerRepository customerRepo() => FirestoreCustomerRepository(
      transport: transport,
      organizationId: demoOrganizationId,
    );
    FirestorePrescriptionRepository rxRepo() => FirestorePrescriptionRepository(
      transport: transport,
      organizationId: demoOrganizationId,
    );

    test(
      'sale: idempotency key is the doc id, numbers are sequential',
      () async {
        final repo = salesRepo();
        final first = await repo.createSale(sampleSale());
        expect(first.invoiceNumber, 'INV-DHA-1001');
        expect(first.id, 'sale-test-1');

        // Same key again: the original sale, no second doc, no
        // second invoice number consumed.
        final retry = await repo.createSale(sampleSale());
        expect(retry.invoiceNumber, 'INV-DHA-1001');
        expect(retry.id, 'sale-test-1');
        expect(transport.countIn('branches/branch-dha-main/sales'), 1);

        final second = await repo.createSale(sampleSale(key: 'sale-test-2'));
        expect(second.invoiceNumber, 'INV-DHA-1002');

        // The item lives in the subcollection, not on the sale doc.
        final items = await transport.queryCollection(
          'branches/branch-dha-main/sales/sale-test-1/items',
        );
        expect(items.length, 1);
        expect(items.single.data['lineTotal'], 20000);

        // Branch-less read finds the sale in either branch.
        expect(
          (await repo.getById('sale-test-2'))?.invoiceNumber,
          'INV-DHA-1002',
        );
      },
    );

    test('sale + order + PO pages paginate and report hasMore', () async {
      final sales = salesRepo();
      for (var i = 0; i < 3; i++) {
        await sales.createSale(sampleSale(key: 'sale-page-$i'));
      }
      final pageOne = await sales.getSalesPage(
        branchId: 'branch-dha-main',
        pageSize: 2,
      );
      expect(pageOne.items.length, 2);
      expect(pageOne.hasMore, isTrue);
      final pageTwo = await sales.getSalesPage(
        branchId: 'branch-dha-main',
        pageSize: 2,
        startAfterId: pageOne.lastId,
      );
      expect(pageTwo.items.length, 1);
      expect(pageTwo.hasMore, isFalse);
      expect((await sales.getSales(branchId: 'branch-dha-main')).length, 3);
    });

    test(
      'order: client id is the doc id, duplicate returns the original',
      () async {
        final repo = ordersRepo();
        final first = await repo.createOrder(sampleOrder(id: 'order-client-1'));
        expect(first.id, 'order-client-1');
        final firstDoc = await transport.getDocument(
          'branches/branch-dha-main/orders/order-client-1',
        );
        expect(firstDoc?['orderNumber'], 'ORD-DHA-1001');
        final retry = await repo.createOrder(sampleOrder(id: 'order-client-1'));
        expect(retry.id, 'order-client-1');
        expect(transport.countIn('branches/branch-dha-main/orders'), 1);
        final second = await repo.createOrder(
          sampleOrder(id: 'order-client-2'),
        );
        final secondDoc = await transport.getDocument(
          'branches/branch-dha-main/orders/order-client-2',
        );
        expect(secondDoc?['orderNumber'], 'ORD-DHA-1002');
        expect(second.status, OrderStatus.newOrder);
      },
    );

    test('purchase order: client id dedupes, numbers are sequential', () async {
      final repo = poRepo();
      const po = PurchaseOrder(
        id: 'po-client-1',
        poNumber: '',
        supplierId: 'sup-1',
        branchId: 'branch-dha-main',
        status: PurchaseOrderStatus.draft,
        items: [
          PurchaseOrderItem(
            medicineId: 'med-1',
            medicineName: 'Panadol',
            quantityOrdered: 10,
            unitCostMinor: 8000,
          ),
        ],
      );
      final first = await repo.createPurchaseOrder(po);
      expect(first.poNumber, 'PO-DHA-1001');
      final retry = await repo.createPurchaseOrder(po);
      expect(retry.poNumber, 'PO-DHA-1001');
      expect(transport.countIn('branches/branch-dha-main/purchaseOrders'), 1);
    });

    test('medicines: 120 seeded rows page 50 / 50 / 20', () async {
      final repo = medicineRepo();
      for (var i = 0; i < 120; i++) {
        await transport.setDocument(
          'medicines/med-${i.toString().padLeft(3, '0')}',
          medicineToFirestore(
            Medicine(
              id: 'med-${i.toString().padLeft(3, '0')}',
              name: 'Med $i',
              brand: 'Brand',
              categoryId: 'cat-1',
              strength: '500mg',
              packSize: '10 tablets',
              price: 10.0 + i,
            ),
            orgId: demoOrganizationId,
          ),
        );
      }
      final first = await repo.getMedicinesPage(pageSize: 50);
      expect(first.items.length, 50);
      expect(first.hasMore, isTrue);
      final second = await repo.getMedicinesPage(
        pageSize: 50,
        startAfterId: first.lastId,
      );
      expect(second.items.length, 50);
      expect(second.hasMore, isTrue);
      final third = await repo.getMedicinesPage(
        pageSize: 50,
        startAfterId: second.lastId,
      );
      expect(third.items.length, 20);
      expect(third.hasMore, isFalse);
      expect((await repo.getMedicines()).length, 120);

      final byBarcode = await repo.getByBarcode('not-a-barcode');
      expect(byBarcode, isNull);
    });

    test('inventory: receive / adjust / count writes batch + ledger', () async {
      final repo = inventoryRepo();
      final received = await repo.receiveStock(
        branchId: 'branch-dha-main',
        medicineId: 'med-1',
        batchNo: 'B-200',
        mfgDate: DateTime(2026, 1, 1),
        expiryDate: DateTime(2027, 6, 1),
        quantity: 10,
        costMinor: 8000,
      );
      expect(received.quantity, 10);
      expect(received.status, BatchStatus.available);
      expect(received.batchNo, 'B-200');
      // One append-only stock transaction per mutation.
      expect(
        transport.countIn('branches/branch-dha-main/stockTransactions'),
        1,
      );

      final adjusted = await repo.adjustStock(
        batchId: received.id,
        deltaQty: -3,
        reason: 'Damaged',
      );
      expect(adjusted.quantity, 7);
      expect(
        transport.countIn('branches/branch-dha-main/stockTransactions'),
        2,
      );
      await expectLater(
        repo.adjustStock(batchId: received.id, deltaQty: -8, reason: 'X'),
        throwsArgumentError,
      );

      final counted = await repo.recordStockCount(
        batchId: received.id,
        countedQty: 4,
        note: 'Monthly count',
      );
      expect(counted.quantity, 4);
      expect(
        transport.countIn('branches/branch-dha-main/stockTransactions'),
        3,
      );
    });

    test('inventory: low-stock is a client-side filter on the guard', () async {
      final repo = inventoryRepo();
      await transport.setDocument(
        'branches/branch-dha-main/batches/batch-low',
        batchToFirestore(
          InventoryItem(
            id: 'batch-low',
            medicineId: 'med-1',
            branchId: 'branch-dha-main',
            quantity: 2,
            lowStockThreshold: 10,
            expiryDate: DateTime(2027, 6, 1),
            batchNo: 'B-300',
            mfgDate: DateTime(2026, 1, 1),
          ),
          orgId: demoOrganizationId,
        ),
      );
      final low = await repo.getLowStock(branchId: 'branch-dha-main');
      expect(low.map((item) => item.id), contains('batch-low'));
    });

    test(
      'customer: duplicate phone rejected, ledger balance accumulates',
      () async {
        final repo = customerRepo();
        const customer = Customer(
          id: '',
          name: 'Ali',
          phone: '03001234567',
          creditLimitMinor: 100000,
        );
        final created = await repo.createCustomer(
          customer,
          branchId: 'branch-dha-main',
        );
        expect(created.id, isNotEmpty);
        await expectLater(
          repo.createCustomer(customer, branchId: 'branch-dha-main'),
          throwsArgumentError,
        );

        final first = await repo.addLedgerEntry(
          LedgerEntry(
            id: '',
            customerId: created.id,
            kind: LedgerEntryKind.creditSale,
            amountMinor: 50000,
            balanceAfterMinor: 0,
            reason: 'Credit sale INV-1',
            referenceId: 'sale-1',
          ),
        );
        expect(first.balanceAfterMinor, 50000);
        final second = await repo.addLedgerEntry(
          LedgerEntry(
            id: '',
            customerId: created.id,
            kind: LedgerEntryKind.payment,
            amountMinor: -20000,
            balanceAfterMinor: 0,
            reason: 'Partial payment',
          ),
        );
        expect(second.balanceAfterMinor, 30000);
        expect((await repo.getLedgerEntries(created.id)).length, 2);
      },
    );

    test(
      'prescription: create with branch, review keeps the photo path',
      () async {
        final repo = rxRepo();
        final created = await repo.createPrescription(
          const Prescription(
            id: 'rx-dha-99',
            customerId: 'cust-1',
            imageUrl: 'assets/images/prescriptions/sample-prescription-1.png',
            status: PrescriptionStatus.pending,
          ),
          branchId: 'branch-dha-main',
        );
        expect(created.branchId, 'branch-dha-main');
        expect((await repo.getPending(branchId: 'branch-dha-main')).length, 1);

        final reviewed = await repo.reviewPrescription(
          id: 'rx-dha-99',
          status: PrescriptionStatus.approved,
          reviewedBy: 'demo-pharmacist',
          reviewNotes: 'Verified.',
        );
        expect(reviewed?.status, PrescriptionStatus.approved);
        expect((await repo.getPending(branchId: 'branch-dha-main')), isEmpty);
        final stored = await transport.getDocument(
          'branches/branch-dha-main/prescriptions/rx-dha-99',
        );
        // The review update never rewrites the photo path.
        expect(stored?['photoStoragePath'], isNull);
      },
    );
  });

  group('Batch status guard — quarantined stock is never sellable', () {
    InventoryItem batchWith(BatchStatus status, int quantity) {
      return InventoryItem(
        id: 'batch-${status.name}',
        medicineId: 'med-1',
        branchId: 'branch-dha-main',
        quantity: quantity,
        lowStockThreshold: 2,
        expiryDate: DateTime(2027, 6, 1),
        batchNo: 'B-${status.name}',
        mfgDate: DateTime(2026, 1, 1),
        status: status,
      );
    }

    test('isBatchSellable requires status == available', () {
      expect(isBatchSellable(batchWith(BatchStatus.available, 5)), isTrue);
      expect(isBatchSellable(batchWith(BatchStatus.quarantined, 5)), isFalse);
      expect(isBatchSellable(batchWith(BatchStatus.expired, 5)), isFalse);
      expect(isBatchSellable(batchWith(BatchStatus.returned, 5)), isFalse);
      // Zero stock is still not sellable even when available.
      expect(isBatchSellable(batchWith(BatchStatus.available, 0)), isFalse);
      // Expired by date is not sellable even when available.
      final past = batchWith(
        BatchStatus.available,
        5,
      ).copyWith(expiryDate: DateTime(2020, 1, 1));
      expect(isBatchSellable(past), isFalse);
    });

    test('sellableStockFor excludes quarantined / expired / returned', () {
      final batches = [
        batchWith(BatchStatus.available, 10),
        batchWith(BatchStatus.quarantined, 5),
        batchWith(BatchStatus.expired, 3),
        batchWith(BatchStatus.returned, 2),
      ];
      expect(sellableStockFor(batches), 10);
      expect(sellableStockFor([batchWith(BatchStatus.quarantined, 5)]), 0);
    });

    test('InventoryItem carries status through fromMap/toMap', () {
      final item = batchWith(BatchStatus.quarantined, 7);
      final restored = InventoryItem.fromMap('batch-quarantined', item.toMap());
      expect(restored.status, BatchStatus.quarantined);
      expect(restored.isQuarantined, isTrue);
      expect(batchWith(BatchStatus.available, 1).isQuarantined, isFalse);
    });
  });

  group('Auth repository — mock login, claims, roles', () {
    test('mock login returns a full AppUser for every demo account', () async {
      final repo = MockAuthRepository();
      final owner = await repo.signInWithEmail(
        'owner@demo.pharmadesk',
        demoPassword,
      );
      expect(owner.uid, 'demo-owner');
      expect(owner.roleKey, 'owner');
      expect(owner.orgId, demoOrganizationId);
      expect(
        owner.branchIds,
        containsAll(['branch-dha-main', 'branch-demo-gulberg']),
      );
      expect(owner.seesAllBranches, isTrue);
      expect(owner.demoRole, DemoRole.owner);
      expect(owner.homeBranchId, isNull);

      final cashier = await repo.signInWithEmail(
        'cashier@demo.pharmadesk',
        demoPassword,
      );
      expect(cashier.roleKey, 'cashier');
      expect(cashier.homeBranchId, 'branch-demo-gulberg');
      expect(cashier.seesAllBranches, isFalse);
      expect(cashier.demoRole, DemoRole.cashier);
    });

    test('mock login rejects bad passwords and unknown emails', () async {
      final repo = MockAuthRepository();
      await expectLater(
        repo.signInWithEmail('owner@demo.pharmadesk', 'wrong'),
        throwsA(isA<AuthException>()),
      );
      await expectLater(
        repo.signInWithEmail('nobody@demo.pharmadesk', demoPassword),
        throwsA(isA<AuthException>()),
      );
      expect(await repo.currentUser(), isNull);
    });

    test('signInAsDemo works for all five demo roles', () async {
      final repo = MockAuthRepository();
      for (final role in DemoRole.values) {
        final user = await repo.signInAsDemo(role);
        expect(user.demoRole, role);
        expect(user.roleKey, role.roleKey);
      }
      expect(
        (await repo.signInAsDemo(DemoRole.branchManager)).roleKey,
        'branch_manager',
      );
      expect(
        (await repo.signInAsDemo(DemoRole.pharmacist)).roleKey,
        'pharmacist',
      );
      expect(
        (await repo.signInAsDemo(DemoRole.inventoryManager)).roleKey,
        'inventory_manager',
      );
    });

    test(
      'password reset: deterministic code, then the new password works',
      () async {
        final repo = MockAuthRepository();
        final email = 'owner@demo.pharmadesk';
        expect(await repo.requestPasswordReset(email), isNotNull);
        expect(
          await repo.requestPasswordReset('nobody@demo.pharmadesk'),
          isNull,
        );
        final code = MockAuthRepository.resetCodeFor(email);
        expect(code.length, 6);
        expect(MockAuthRepository.resetCodeFor(email), code);

        await expectLater(
          repo.resetPassword(
            email: email,
            code: '000000',
            newPassword: 'newpass1',
          ),
          throwsA(isA<AuthException>()),
        );
        await expectLater(
          repo.resetPassword(email: email, code: code, newPassword: 'short'),
          throwsA(isA<AuthException>()),
        );
        await repo.resetPassword(
          email: email,
          code: code,
          newPassword: 'newpass1',
        );
        final signedIn = await repo.signInWithEmail(email, 'newpass1');
        expect(signedIn.uid, 'demo-owner');
        await repo.signOut();
        expect(await repo.currentUser(), isNull);
      },
    );

    test('appUserFromClaims maps branch_manager claims to the demo role', () {
      final manager = appUserFromClaims(
        uid: 'u-1',
        email: 'bilal@fazaldin.pk',
        displayName: 'Bilal Ahmed',
        claims: {
          'orgId': demoOrganizationId,
          'branchIds': ['branch-dha-main'],
          'role': 'branch_manager',
        },
      );
      expect(manager.demoRole, DemoRole.branchManager);
      expect(manager.seesAllBranches, isFalse);
      expect(manager.homeBranchId, 'branch-dha-main');
      expect(manager.branchIds, contains('branch-dha-main'));
      expect(manager.branchIds, isNot(contains('branch-demo-gulberg')));

      final owner = appUserFromClaims(
        uid: 'u-2',
        email: 'owner@demo.pharmadesk',
        displayName: 'Hassan Raza',
        claims: {
          'orgId': demoOrganizationId,
          'branchIds': ['branch-dha-main', 'branch-demo-gulberg'],
          'role': 'owner',
        },
      );
      expect(owner.branchIds, contains('branch-demo-gulberg'));

      // Missing claims degrade to an empty role, never a crash.
      final bare = appUserFromClaims(uid: 'u-3', email: 'x@y.z', claims: {});
      expect(bare.roleKey, '');
      expect(bare.demoRole, isNull);
      expect(bare.branchIds, isEmpty);
      expect(bare.seesAllBranches, isFalse);
    });

    test('roleDisplayName covers every SRS role key', () {
      expect(roleDisplayName('super_admin'), 'Super Admin');
      expect(roleDisplayName('ho_admin'), 'HO Admin');
      expect(roleDisplayName('branch_manager'), 'Branch Mgr');
      expect(roleDisplayName('inventory_manager'), 'Inventory Mgr');
      expect(roleDisplayName('auditor'), 'Auditor');
      expect(roleDisplayName('unknown_key'), 'unknown_key');
    });
  });

  group('Permission service — SRS §5.1 matrix is the UX gate', () {
    const service = PermissionService();

    AppUser userFor(
      String roleKey, [
      List<String> branches = const ['branch-dha-main'],
    ]) {
      return AppUser(
        uid: 'u-$roleKey',
        email: '$roleKey@fazaldin.pk',
        displayName: roleKey,
        orgId: demoOrganizationId,
        branchIds: branches,
        roleKey: roleKey,
      );
    }

    test('owner can do everything except prescription review', () {
      final owner = userFor('owner', [
        'branch-dha-main',
        'branch-demo-gulberg',
      ]);
      expect(service.can(owner, 'posSell'), isTrue);
      expect(service.can(owner, 'medicineCrud'), isTrue);
      expect(service.can(owner, 'reports'), isTrue);
      expect(service.can(owner, 'rxReview'), isFalse);
      expect(service.canWrite(owner, 'posSell', 'branch-dha-main'), isTrue);
      expect(service.isReadOnly(owner, 'reports'), isFalse);
    });

    test('cashier sells only in the home branch, never manages stock', () {
      final cashier = userFor('cashier', ['branch-demo-gulberg']);
      expect(service.can(cashier, 'posSell'), isTrue);
      expect(
        service.canInBranch(cashier, 'posSell', 'branch-demo-gulberg'),
        isTrue,
      );
      expect(
        service.canInBranch(cashier, 'posSell', 'branch-dha-main'),
        isFalse,
      );
      expect(service.can(cashier, 'stockReceive'), isFalse);
      // Reports are `own` for a cashier: viewable in the home branch.
      expect(service.can(cashier, 'reports'), isTrue);
      expect(
        service.canInBranch(cashier, 'reports', 'branch-demo-gulberg'),
        isTrue,
      );
      expect(
        service.canInBranch(cashier, 'reports', 'branch-dha-main'),
        isFalse,
      );
    });

    test('pharmacist reviews prescriptions in the home branch only', () {
      final pharmacist = userFor('pharmacist');
      expect(service.can(pharmacist, 'rxReview'), isTrue);
      expect(
        service.canWrite(pharmacist, 'rxReview', 'branch-dha-main'),
        isTrue,
      );
      expect(
        service.canWrite(pharmacist, 'rxReview', 'branch-demo-gulberg'),
        isFalse,
      );
      // POS is `own` for a pharmacist too (same matrix row).
      expect(service.can(pharmacist, 'posSell'), isTrue);
      expect(
        service.canInBranch(pharmacist, 'posSell', 'branch-dha-main'),
        isTrue,
      );
      expect(
        service.canInBranch(pharmacist, 'posSell', 'branch-demo-gulberg'),
        isFalse,
      );
    });

    test(
      'auditor is read-only; unknown roles get nothing; null user is allowed',
      () {
        final auditor = userFor('auditor', [
          'branch-dha-main',
          'branch-demo-gulberg',
        ]);
        expect(service.can(auditor, 'reports'), isTrue);
        expect(service.isReadOnly(auditor, 'reports'), isTrue);
        expect(
          service.canWrite(auditor, 'reports', 'branch-dha-main'),
          isFalse,
        );

        expect(service.can(userFor('mystery_role'), 'posSell'), isFalse);
        expect(service.can(userFor('cashier'), 'no_such_capability'), isFalse);
        // Null user: the router redirect is the signed-out guard;
        // the service must not lock the app out before auth resolves.
        expect(service.can(null, 'posSell'), isTrue);
        expect(service.permissionFor(null, 'posSell'), RolePermission.allowed);
      },
    );

    test('routeCapability maps only the matrix-gated routes', () {
      expect(routeCapability('/billing'), 'posSell');
      expect(routeCapability('/billing/receipt/INV-1'), 'posSell');
      expect(routeCapability('/medicines'), 'medicineCrud');
      expect(routeCapability('/customers'), 'khata');
      expect(routeCapability('/suppliers'), 'supplierPay');
      expect(routeCapability('/purchases'), 'poManage');
      expect(routeCapability('/purchases/auto'), 'poManage');
      expect(routeCapability('/reports'), 'reports');
      // Viewing the queue / stock / orders is not a matrix capability.
      expect(routeCapability('/prescriptions'), isNull);
      expect(routeCapability('/inventory'), isNull);
      expect(routeCapability('/orders'), isNull);
      expect(routeCapability('/dashboard'), isNull);
      expect(routeCapability('/notifications'), isNull);
    });
  });

  group(
    'Repository factory — default is mock, Firestore needs a transport',
    () {
      test('createRepositoryBundle() defaults to the mock bundle', () {
        final bundle = createRepositoryBundle();
        expect(bundle.kind, BackendKind.mock);
        expect(bundle.medicines, isA<MockMedicineRepository>());
        expect(bundle.sales, isA<MockSaleRepository>());
        expect(bundle.auth, isA<MockAuthRepository>());
        expect(bundle.photoUploader, isA<LocalPrescriptionPhotoUploader>());
      });

      test('firestore kind without a transport throws with an explanation', () {
        expect(
          () => createRepositoryBundle(kind: BackendKind.firestore),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('Firebase project'),
            ),
          ),
        );
      });

      test('firestore kind with a fake transport builds Firestore repos', () {
        final transport = FakeFirestoreTransport();
        final bundle = createRepositoryBundle(
          kind: BackendKind.firestore,
          transport: transport,
        );
        expect(bundle.kind, BackendKind.firestore);
        expect(bundle.medicines, isA<FirestoreMedicineRepository>());
        expect(bundle.sales, isA<FirestoreSaleRepository>());
        // No FirebaseAuth instance was passed, so auth stays mock —
        // it switches to FirebaseAuthRepository only when the caller
        // hands the factory a FirebaseAuth (i.e. once a project exists).
        expect(bundle.auth, isA<MockAuthRepository>());
        // Same for the uploader: it stays local until a
        // FirebaseStorage instance is handed to the factory.
        expect(bundle.photoUploader, isA<LocalPrescriptionPhotoUploader>());
      });

      test(
        'providers read the bundle: default mock, overridable to Firestore',
        () {
          final defaultContainer = ProviderContainer();
          addTearDown(defaultContainer.dispose);
          expect(
            defaultContainer.read(medicineRepositoryProvider),
            isA<MockMedicineRepository>(),
          );
          expect(
            defaultContainer.read(authRepositoryProvider),
            isA<MockAuthRepository>(),
          );
          expect(
            defaultContainer.read(prescriptionPhotoUploaderProvider),
            isA<LocalPrescriptionPhotoUploader>(),
          );

          final firestoreBundle = createRepositoryBundle(
            kind: BackendKind.firestore,
            transport: FakeFirestoreTransport(),
          );
          final firestoreContainer = ProviderContainer(
            overrides: [
              repositoryBundleProvider.overrideWithValue(firestoreBundle),
            ],
          );
          addTearDown(firestoreContainer.dispose);
          expect(
            firestoreContainer.read(medicineRepositoryProvider),
            isA<FirestoreMedicineRepository>(),
          );
          // Auth stays mock here too (no FirebaseAuth instance passed).
          expect(
            firestoreContainer.read(authRepositoryProvider),
            isA<MockAuthRepository>(),
          );
          // And the uploader stays local (no FirebaseStorage passed).
          expect(
            firestoreContainer.read(prescriptionPhotoUploaderProvider),
            isA<LocalPrescriptionPhotoUploader>(),
          );
          expect(
            firestoreContainer.read(prescriptionPhotoUploaderProvider),
            isA<LocalPrescriptionPhotoUploader>(),
          );
        },
      );
    },
  );

  group('Prescription photo upload — path + metadata rules', () {
    test('buildPrescriptionPhotoUpload builds the branch-scoped path', () {
      final request = buildPrescriptionPhotoUpload(
        orgId: 'org-x',
        branchId: 'branch-dha-main',
        prescriptionId: 'rx-1',
        bytes: Uint8List.fromList([1, 2, 3]),
        contentType: 'image/jpeg',
        uploadedBy: 'demo-pharmacist',
      );
      expect(
        request.storagePath,
        'organizations/org-x/branches/branch-dha-main/prescriptions/rx-1.jpg',
      );
      expect(request.contentType, 'image/jpeg');
      expect(request.uploadedBy, 'demo-pharmacist');
    });

    test(
      'non-image content type, 10 MB or more, and empty id are rejected',
      () {
        expect(
          () => buildPrescriptionPhotoUpload(
            orgId: 'org-x',
            branchId: 'branch-dha-main',
            prescriptionId: 'rx-1',
            bytes: Uint8List.fromList([1]),
            contentType: 'application/pdf',
            uploadedBy: 'demo-pharmacist',
          ),
          throwsArgumentError,
        );
        expect(
          () => buildPrescriptionPhotoUpload(
            orgId: 'org-x',
            branchId: 'branch-dha-main',
            prescriptionId: 'rx-1',
            bytes: Uint8List(10 * 1024 * 1024),
            contentType: 'image/jpeg',
            uploadedBy: 'demo-pharmacist',
          ),
          throwsArgumentError,
        );
        expect(
          () => buildPrescriptionPhotoUpload(
            orgId: 'org-x',
            branchId: 'branch-dha-main',
            prescriptionId: '',
            bytes: Uint8List.fromList([1]),
            contentType: 'image/jpeg',
            uploadedBy: 'demo-pharmacist',
          ),
          throwsArgumentError,
        );
        // Just under the limit passes.
        final justUnder = buildPrescriptionPhotoUpload(
          orgId: 'org-x',
          branchId: 'branch-dha-main',
          prescriptionId: 'rx-1',
          bytes: Uint8List(10 * 1024 * 1024 - 1),
          contentType: 'image/png',
          uploadedBy: 'demo-pharmacist',
        );
        expect(justUnder.contentType, 'image/png');
      },
    );

    test(
      'local uploader keeps the bytes and never fakes a cloud path',
      () async {
        final uploader = LocalPrescriptionPhotoUploader();
        final bytes = Uint8List.fromList([10, 20, 30]);
        final result = await uploader.uploadPrescriptionPhoto(
          orgId: 'org-x',
          branchId: 'branch-dha-main',
          prescriptionId: 'rx-1',
          bytes: bytes,
          contentType: 'image/jpeg',
          uploadedBy: 'demo-pharmacist',
        );
        expect(result.localPath, 'prescriptions/rx-1.jpg');
        expect(result.storagePath, isNull);
        expect(result.uploadedBy, 'demo-pharmacist');
        expect(uploader.storedBytes['rx-1'], bytes);
      },
    );
  });

  group('FeatureGate + prescription review — permission in the UI', () {
    testWidgets('FeatureGate blocks a module the role cannot use', (
      tester,
    ) async {
      // A pharmacist has no `supplierPay`: /suppliers is blocked.
      final pharmacistContainer = ProviderContainer();
      addTearDown(pharmacistContainer.dispose);
      await pharmacistContainer
          .read(authProvider.notifier)
          .signInAsDemo(DemoRole.pharmacist);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: pharmacistContainer,
          child: const MaterialApp(
            home: FeatureGate(
              route: '/suppliers',
              child: Text('Suppliers content'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Suppliers content'), findsNothing);
      expect(find.textContaining('No permission for'), findsOneWidget);
      expect(find.textContaining('Pharmacist'), findsOneWidget);

      // The owner passes the same gate.
      final ownerContainer = ProviderContainer();
      addTearDown(ownerContainer.dispose);
      await ownerContainer
          .read(authProvider.notifier)
          .signInAsDemo(DemoRole.owner);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: ownerContainer,
          child: const MaterialApp(
            home: FeatureGate(
              route: '/suppliers',
              child: Text('Suppliers content'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Suppliers content'), findsOneWidget);

      // A cashier may sell in the home branch (Gulberg): /billing passes.
      final cashierContainer = ProviderContainer();
      addTearDown(cashierContainer.dispose);
      await cashierContainer
          .read(authProvider.notifier)
          .signInAsDemo(DemoRole.cashier);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: cashierContainer,
          child: const MaterialApp(
            home: FeatureGate(route: '/billing', child: Text('POS content')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('POS content'), findsOneWidget);
    });

    testWidgets('owner cannot approve a prescription; pharmacist can', (
      tester,
    ) async {
      // Owner: the buttons are disabled with an explanation.
      final ownerContainer = ProviderContainer();
      addTearDown(ownerContainer.dispose);
      await ownerContainer
          .read(authProvider.notifier)
          .signInAsDemo(DemoRole.owner);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: ownerContainer,
          child: const MaterialApp(
            home: PrescriptionDetailScreen(prescriptionId: 'rx-dha-1'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Only a pharmacist'), findsOneWidget);
      expect(
        tester
            .widget<PharmaButton>(find.widgetWithText(PharmaButton, 'Approve'))
            .onPressed,
        isNull,
      );

      // Pharmacist (DHA home branch): the buttons are live.
      final pharmacistContainer = ProviderContainer();
      addTearDown(pharmacistContainer.dispose);
      await pharmacistContainer
          .read(authProvider.notifier)
          .signInAsDemo(DemoRole.pharmacist);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: pharmacistContainer,
          child: const MaterialApp(
            home: PrescriptionDetailScreen(prescriptionId: 'rx-dha-1'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Only a pharmacist'), findsNothing);
      expect(
        tester
            .widget<PharmaButton>(find.widgetWithText(PharmaButton, 'Approve'))
            .onPressed,
        isNotNull,
      );
    });
  });

  group('D54 — the POS idempotency key survives a failed attempt', () {
    testWidgets(
      'pendingSaleKey is held across a retry and cleared on success',
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final notifier = container.read(salesProvider.notifier);

        // First attempt fails validation (empty cart) — a key is
        // minted anyway and held.
        final failed = await notifier.completeSale(
          branchId: 'branch-dha-main',
          cashierName: 'Usman Tariq',
          lines: const [],
          paymentMethod: SalePaymentMethod.cash,
        );
        expect(failed.sale, isNull);
        final heldKey = notifier.pendingSaleKey;
        expect(heldKey, isNotNull);

        // Retry with a real line: the SAME key is used.
        final inventory = await container
            .read(inventoryRepositoryProvider)
            .getInventory(branchId: 'branch-dha-main');
        final stocked = inventory.firstWhere((item) => item.quantity > 0);
        final medicine = await container
            .read(medicineRepositoryProvider)
            .getById(stocked.medicineId);
        final sale = await notifier.completeSale(
          branchId: 'branch-dha-main',
          cashierName: 'Usman Tariq',
          lines: [
            CartLine(
              medicineId: stocked.medicineId,
              medicineName: medicine?.name ?? stocked.medicineId,
              unitPriceMinor: 10000,
              quantity: 1,
            ),
          ],
          paymentMethod: SalePaymentMethod.cash,
          cashReceivedMinor: 10000,
        );
        expect(sale.sale, isNotNull);
        expect(sale.sale!.idempotencyKey, heldKey);
        // Success clears the held key; the next sale mints a new one.
        expect(notifier.pendingSaleKey, isNull);
        final next = await notifier.completeSale(
          branchId: 'branch-dha-main',
          cashierName: 'Usman Tariq',
          lines: [
            CartLine(
              medicineId: stocked.medicineId,
              medicineName: medicine?.name ?? stocked.medicineId,
              unitPriceMinor: 10000,
              quantity: 1,
            ),
          ],
          paymentMethod: SalePaymentMethod.cash,
          cashReceivedMinor: 10000,
        );
        expect(next.sale, isNotNull);
        expect(next.sale!.idempotencyKey, isNot(heldKey));
      },
    );
  });
}
