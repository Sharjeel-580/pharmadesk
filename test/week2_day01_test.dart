import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:pharmadesk/core/data/audit_log.dart';
import 'package:pharmadesk/core/data/backup_export.dart';
import 'package:pharmadesk/core/data/firestore_schema.dart';
import 'package:pharmadesk/core/data/inventory_engine.dart';
import 'package:pharmadesk/core/data/production_data_layer.dart';
import 'package:pharmadesk/core/data/sync_queue.dart';
import 'package:pharmadesk/core/data/sync_store.dart';
import 'package:pharmadesk/core/data/sync_store_io.dart';
import 'package:pharmadesk/core/routing/app_router.dart';
import 'package:pharmadesk/core/services/repositories.dart';
import 'package:pharmadesk/core/theme/app_theme.dart';
import 'package:pharmadesk/core/theme/white_label.dart';
import 'package:pharmadesk/features/orders/orders_provider.dart';
import 'package:pharmadesk/models/customer_ledger.dart';
import 'package:pharmadesk/models/inventory_item.dart';
import 'package:pharmadesk/models/order.dart';
import 'package:pharmadesk/models/sale.dart';

/// Week 2 Day 1 — production data layer tests.
///
/// Covers: schema paths + field contracts, sale/order idempotency and
/// dedupe, reservation confirm/release, FEFO + the expired-never-
/// sellable guard, batch chunking at 500, audit entries, export/import
/// round-trip, queue retry/back-off and the money/stock conflict
/// policy. All tests run against the mock repositories — there is no
/// Firebase project yet, so nothing here touches the cloud.

const _org = demoOrganizationId;
const _branch = 'branch-dha-main';

InventoryItem _batch({
  required String id,
  required String medicineId,
  required int qty,
  DateTime? expiry,
  String? batchNo,
}) {
  return InventoryItem(
    id: id,
    medicineId: medicineId,
    branchId: _branch,
    quantity: qty,
    lowStockThreshold: 2,
    batchNo: batchNo ?? id,
    expiryDate: expiry,
    mfgDate: DateTime(2026, 1, 1),
    costMinor: 5000,
  );
}

InventoryEngine _engine() => InventoryEngine(
  organizationId: _org,
  audit: InMemoryAuditLogWriter(),
);

ProductionDataLayer _layer({
  MockInventoryRepository? inventoryRepo,
  MockSaleRepository? saleRepo,
  MockOrderRepository? orderRepo,
  MockCustomerRepository? customerRepo,
  SyncStore? syncStore,
}) {
  final audit = InMemoryAuditLogWriter();
  final queue = SyncQueue(syncStore ?? InMemorySyncStore());
  return ProductionDataLayer(
    organizationId: _org,
    inventoryRepo: inventoryRepo ?? MockInventoryRepository(),
    saleRepo: saleRepo ?? MockSaleRepository(),
    orderRepo: orderRepo ?? MockOrderRepository(),
    customerRepo: customerRepo ?? MockCustomerRepository(),
    medicineRepo: MockMedicineRepository(),
    supplierRepo: MockSupplierRepository(),
    prescriptionRepo: MockPrescriptionRepository(),
    purchaseOrderRepo: MockPurchaseOrderRepository(),
    riderRepo: MockRiderRepository(),
    audit: audit,
    syncQueue: queue,
    engine: InventoryEngine(organizationId: _org, audit: audit),
  );
}

Sale _sale({
  required String key,
  required String medicineId,
  required String batchId,
  int qty = 2,
  int unitPriceMinor = 10000,
}) {
  return Sale(
    id: '',
    invoiceNumber: '',
    branchId: _branch,
    cashierName: 'Test Cashier',
    items: [
      SaleItem(
        medicineId: medicineId,
        medicineName: 'Test Medicine',
        quantity: qty,
        unitPriceMinor: unitPriceMinor,
        batchId: batchId,
      ),
    ],
    subtotalMinor: qty * unitPriceMinor,
    totalMinor: qty * unitPriceMinor,
    paymentMethod: SalePaymentMethod.cash,
    idempotencyKey: key,
  );
}

void main() {
  group('Firestore schema (SRS §3)', () {
    test('branch subcollection paths', () {
      expect(
        FirestoreSchema.salesPath(_branch),
        'branches/branch-dha-main/sales',
      );
      expect(
        FirestoreSchema.saleDocPath(_branch, 'sale-x'),
        'branches/branch-dha-main/sales/sale-x',
      );
      expect(
        FirestoreSchema.orderDocPath(_branch, 'ord-x'),
        'branches/branch-dha-main/orders/ord-x',
      );
      expect(
        FirestoreSchema.inventoryDocPath(_branch, 'med-1'),
        'branches/branch-dha-main/inventory/med-1',
      );
      expect(
        FirestoreSchema.customerLedgerPath(_branch, 'cust-1'),
        'branches/branch-dha-main/customers/cust-1/ledger',
      );
      expect(
        FirestoreSchema.supplierLedgerPath('sup-1'),
        'suppliers/sup-1/ledger',
      );
      expect(
        FirestoreSchema.counterDocPath(_branch, 'invoice'),
        'branches/branch-dha-main/counters/invoice',
      );
      expect(
        FirestoreSchema.saleItemsPath(_branch, 'sale-x'),
        'branches/branch-dha-main/sales/sale-x/items',
      );
    });

    test('idempotency keys are valid doc ids', () {
      expect(FirestoreSchema.isValidIdempotencyKey('sale-x-123'), isTrue);
      expect(FirestoreSchema.isValidIdempotencyKey(''), isFalse);
      expect(FirestoreSchema.isValidIdempotencyKey('a/b'), isFalse);
      expect(maxFirestoreBatchWrites, 500);
    });

    test('Cloud Storage paths are branch-scoped (Blaze, D62)', () {
      expect(
        FirestoreSchema.storagePrescriptionPath(
          'org-1',
          'branch-dha-main',
          'rx-1',
        ),
        'organizations/org-1/branches/branch-dha-main/prescriptions/rx-1.jpg',
      );
      expect(
        FirestoreSchema.storageMedicineImagePath('org-1', 'med-1'),
        'organizations/org-1/medicines/med-1.jpg',
      );
      expect(
        FirestoreSchema.storageBrandLogoPath('org-1'),
        'organizations/org-1/brand/logo.png',
      );
      expect(
        FirestoreSchema.storageBackupPrefix('org-1', '2026-11-25'),
        'organizations/org-1/backups/2026-11-25/',
      );
      // Prescription field contract carries the Storage metadata.
      final fields = FirestoreSchema
          .fieldsByCollection['branches/{branchId}/prescriptions']!;
      expect(
        fields.any((field) => field.name == 'photoStoragePath'),
        isTrue,
      );
      expect(
        fields.any((field) => field.name == 'photoUploadedAt'),
        isTrue,
      );
    });

    test('field contracts cover every branch subcollection', () {
      const expected = [
        'batches',
        'inventory',
        'stockTransactions',
        'stockTransfers',
        'stockCounts',
        'customers',
        'sales',
        'saleReturns',
        'prescriptions',
        'orders',
        'riders',
        'purchaseOrders',
        'goodsReceipts',
        'purchaseReturns',
        'supplierPayments',
        'employees',
        'attendances',
        'shifts',
        'expenses',
        'financialTransactions',
        'notifications',
        'cashDrawers',
        'counters',
      ];
      final patterns = FirestoreSchema.fieldsByCollection.keys.toList();
      for (final name in expected) {
        expect(
          patterns.any((pattern) => pattern.endsWith('/$name')),
          isTrue,
          reason: 'Missing field contract for $name',
        );
      }
      // Root collections from SRS §3.1–§3.2.
      for (final name in [
        'organizations',
        'branches',
        'users',
        'medicines',
        'suppliers',
        'auditLogs',
      ]) {
        expect(patterns.contains(name), isTrue, reason: 'Missing $name');
      }
    });

    test('money fields are int paisa in the sales contract', () {
      final fields =
          FirestoreSchema.fieldsByCollection['branches/{branchId}/sales']!;
      final grandTotal = fields.firstWhere(
        (field) => field.name == 'grandTotal',
      );
      expect(grandTotal.type, contains('paisa'));
      expect(grandTotal.required, isTrue);
    });

    test('validateDocument flags missing required fields', () {
      final errors = FirestoreSchema.validateDocument(
        'branches/{branchId}/sales',
        {'invoiceNumber': 'INV-1'},
      );
      expect(errors, isNotEmpty);
      expect(errors.any((error) => error.contains('grandTotal')), isTrue);
      expect(errors.any((error) => error.contains('organizationId')), isTrue);
      final ok = FirestoreSchema.validateDocument(
        'branches/{branchId}/sales',
        {
          'organizationId': _org,
          'branchId': _branch,
          'createdAt': DateTime.now().toIso8601String(),
          'updatedAt': DateTime.now().toIso8601String(),
          'invoiceNumber': 'INV-1',
          'subtotal': 1000,
          'grandTotal': 1000,
          'idempotencyKey': 'sale-x',
        },
      );
      expect(ok, isEmpty);
      expect(
        FirestoreSchema.validateDocument('nope', {}),
        isNotEmpty,
      );
    });
  });

  group('Inventory engine — reservations + FEFO + expired guard', () {
    test('reserve takes FEFO batches, confirm decrements, counters move', () async {
      final engine = _engine();
      final soon = _batch(
        id: 'b-soon',
        medicineId: 'med-1',
        qty: 5,
        expiry: DateTime.now().add(const Duration(days: 30)),
      );
      final later = _batch(
        id: 'b-later',
        medicineId: 'med-1',
        qty: 10,
        expiry: DateTime.now().add(const Duration(days: 300)),
      );
      engine.loadBatches([soon, later]);
      expect(engine.counterFor('med-1').quantityOnHand, 15);
      expect(engine.counterFor('med-1').available, 15);

      final reservations = engine.reserve(
        branchId: _branch,
        medicineId: 'med-1',
        quantity: 7,
        saleKey: 'sale-test-1',
      );
      expect(reservations.length, 2);
      expect(reservations[0].batchId, 'b-soon');
      expect(reservations[0].quantity, 5);
      expect(reservations[1].batchId, 'b-later');
      expect(reservations[1].quantity, 2);
      // Reserved units are out of the sellable pool, on hand unchanged.
      expect(engine.counterFor('med-1').quantityReserved, 7);
      expect(engine.counterFor('med-1').quantityOnHand, 15);
      expect(engine.counterFor('med-1').available, 8);

      final movements = await engine.confirm(
        reservations: reservations,
        saleId: 'sale-1',
        userId: 'u1',
        actorName: 'Tester',
      );
      expect(movements.length, 2);
      expect(movements[0].type, StockMovementType.sale);
      expect(movements[0].quantity, -5);
      expect(movements[1].quantity, -2);
      expect(engine.batchById('b-soon')!.quantity, 0);
      expect(engine.batchById('b-later')!.quantity, 8);
      expect(engine.counterFor('med-1').quantityOnHand, 8);
      expect(engine.counterFor('med-1').quantityReserved, 0);
      expect(engine.ledger.all.length, 2);
    });

    test('release returns reserved units, writes no ledger entry', () async {
      final engine = _engine();
      engine.loadBatches([
        _batch(
          id: 'b-1',
          medicineId: 'med-1',
          qty: 10,
          expiry: DateTime.now().add(const Duration(days: 90)),
        ),
      ]);
      final reservations = engine.reserve(
        branchId: _branch,
        medicineId: 'med-1',
        quantity: 4,
        saleKey: 'sale-test-2',
      );
      expect(engine.counterFor('med-1').available, 6);
      await engine.release(
        reservations: reservations,
        userId: 'u1',
        actorName: 'Tester',
        reason: 'Sale cancelled',
      );
      expect(engine.counterFor('med-1').quantityReserved, 0);
      expect(engine.counterFor('med-1').available, 10);
      expect(engine.batchById('b-1')!.quantity, 10);
      expect(engine.ledger.all, isEmpty);
    });

    test('expired batch is never reserved (shared Day 5 guard)', () {
      final engine = _engine();
      final expired = _batch(
        id: 'b-expired',
        medicineId: 'med-1',
        qty: 100,
        expiry: DateTime.now().subtract(const Duration(days: 1)),
      );
      final fresh = _batch(
        id: 'b-fresh',
        medicineId: 'med-1',
        qty: 3,
        expiry: DateTime.now().add(const Duration(days: 90)),
      );
      engine.loadBatches([expired, fresh]);
      // Only the fresh batch counts: 3 available, not 103.
      expect(engine.sellableAvailableForBatch('b-expired'), 0);
      expect(engine.sellableAvailableForBatch('b-fresh'), 3);
      final reservations = engine.reserve(
        branchId: _branch,
        medicineId: 'med-1',
        quantity: 3,
        saleKey: 'sale-test-3',
      );
      expect(reservations.length, 1);
      expect(reservations.first.batchId, 'b-fresh');
      // Asking for more than the fresh stock fails, despite 100 expired.
      expect(
        () => engine.reserve(
          branchId: _branch,
          medicineId: 'med-1',
          quantity: 4,
          saleKey: 'sale-test-4',
        ),
        throwsArgumentError,
      );
    });

    test('reserveBatches re-validates the exact batches', () {
      final engine = _engine();
      engine.loadBatches([
        _batch(
          id: 'b-exp',
          medicineId: 'med-1',
          qty: 5,
          expiry: DateTime.now().subtract(const Duration(days: 5)),
        ),
      ]);
      expect(
        () => engine.reserveBatches(
          branchId: _branch,
          saleKey: 'sale-test-5',
          decrements: [(batchId: 'b-exp', quantity: 1)],
        ),
        throwsArgumentError,
      );
      expect(engine.counterFor('med-1').quantityReserved, 0);
    });

    test('adjust never goes below zero and writes ledger + audit', () async {
      final engine = _engine();
      engine.loadBatches([
        _batch(
          id: 'b-1',
          medicineId: 'med-1',
          qty: 3,
          expiry: DateTime.now().add(const Duration(days: 90)),
        ),
      ]);
      expect(
        () => engine.adjust(
          batchId: 'b-1',
          deltaQty: -4,
          reason: 'Damage',
          userId: 'u1',
          actorName: 'Tester',
        ),
        throwsArgumentError,
      );
      final movement = await engine.adjust(
        batchId: 'b-1',
        deltaQty: -2,
        reason: 'Damage',
        userId: 'u1',
        actorName: 'Tester',
      );
      expect(movement.type, StockMovementType.adjustment);
      expect(movement.quantity, -2);
      expect(engine.batchById('b-1')!.quantity, 1);
      expect(engine.counterFor('med-1').quantityOnHand, 1);
      expect(engine.ledger.all.length, 1);
    });
  });

  group('WriteBatch chunking (≤500 ops)', () {
    test('1200 ops chunk into 500 / 500 / 200', () {
      final batch = LocalWriteBatch();
      for (var i = 0; i < 1200; i++) {
        batch.set('branches/b/sales/sale-$i', {'i': i});
      }
      expect(batch.operationCount, 1200);
      final chunks = batch.chunks();
      expect(chunks.length, 3);
      expect(chunks[0].operationCount, 500);
      expect(chunks[1].operationCount, 500);
      expect(chunks[2].operationCount, 200);
      for (final chunk in chunks) {
        expect(chunk.operationCount, lessThanOrEqualTo(500));
      }
    });

    test('500 ops stay one chunk; operations round-trip to maps', () {
      final batch = LocalWriteBatch();
      for (var i = 0; i < 500; i++) {
        batch.update('branches/b/inventory/med-$i', {'quantityOnHand': i});
      }
      expect(batch.chunks().length, 1);
      final map = batch.toMap();
      expect((map['operations'] as List).length, 500);
      final first = WriteOperation.fromMap(
        (map['operations'] as List).first as Map<String, dynamic>,
      );
      expect(first.kind, WriteOperationKind.update);
    });
  });

  group('Production data layer — sale commit + idempotency', () {
    test('duplicate commit with the same key does not double-charge stock',
        () async {
      final inventoryRepo = MockInventoryRepository();
      final saleRepo = MockSaleRepository();
      final layer = _layer(
        inventoryRepo: inventoryRepo,
        saleRepo: saleRepo,
      );
      final batches = await inventoryRepo.getInventory(branchId: _branch);
      final batch = batches.firstWhere((item) => item.quantity >= 5);
      final before = batch.quantity;

      final sale = _sale(
        key: 'sale-dedupe-1',
        medicineId: batch.medicineId,
        batchId: batch.id,
        qty: 2,
      );
      final first = await layer.commitSale(
        sale: sale,
        decrements: [(batchId: batch.id, quantity: 2)],
      );
      expect(first.isDuplicate, isFalse);
      expect(first.movements.length, 1);
      expect(first.movements.first.quantity, -2);

      final second = await layer.commitSale(
        sale: sale,
        decrements: [(batchId: batch.id, quantity: 2)],
      );
      expect(second.isDuplicate, isTrue);
      expect(second.sale.id, first.sale.id);
      expect(second.movements, isEmpty);

      final after = (await inventoryRepo.getInventory(branchId: _branch))
          .firstWhere((item) => item.id == batch.id);
      expect(after.quantity, before - 2);
      expect((await saleRepo.getSales(branchId: _branch)).length, 1);

      // Audit: one commit + one duplicate-skipped, plus stock entries.
      final auditEntries = await layer.auditEntries(branchId: _branch);
      expect(
        auditEntries.where((e) => e.action == 'sale.committed').length,
        1,
      );
      expect(
        auditEntries
            .where((e) => e.action == 'sale.duplicate_skipped')
            .length,
        1,
      );
      expect(
        auditEntries.where((e) => e.action == 'stock.sale').length,
        1,
      );

      // One sync op enqueued for the sale, with the batched payload.
      final pending = await layer.pendingSyncOperations();
      expect(pending.length, 1);
      expect(pending.first.entityType, 'sale');
      expect(pending.first.idempotencyKey, 'sale-dedupe-1');
      final payload = pending.first.payload;
      expect(payload['operationCount'] as int, greaterThan(0));
      expect(payload['chunks'], 1);
    });

    test('credit sale appends khata + money audit entry', () async {
      final inventoryRepo = MockInventoryRepository();
      final customerRepo = MockCustomerRepository();
      final layer = _layer(
        inventoryRepo: inventoryRepo,
        customerRepo: customerRepo,
      );
      final batches = await inventoryRepo.getInventory(branchId: _branch);
      final batch = batches.firstWhere((item) => item.quantity >= 2);
      final customer = (await customerRepo.getCustomers()).first;
      final sale = _sale(
        key: 'sale-credit-1',
        medicineId: batch.medicineId,
        batchId: batch.id,
        qty: 1,
      ).copyWith(
        paymentMethod: SalePaymentMethod.credit,
        customerId: customer.id,
      );
      final result = await layer.commitSale(
        sale: sale,
        decrements: [(batchId: batch.id, quantity: 1)],
        creditLedgerEntry: LedgerEntry(
          id: '',
          customerId: customer.id,
          kind: LedgerEntryKind.creditSale,
          amountMinor: sale.totalMinor,
          reason: 'Credit sale',
          balanceAfterMinor: 0,
          createdAt: DateTime.now(),
        ),
      );
      expect(result.isDuplicate, isFalse);
      final entries = await customerRepo.getLedgerEntries(customer.id);
      expect(
        entries.where((e) => e.referenceId == result.sale.id).length,
        1,
      );
      final auditEntries = await layer.auditEntries(
        branchId: _branch,
        action: 'ledger.credit_sale',
      );
      expect(auditEntries.length, 1);
      expect(auditEntries.first.entityType, 'customerLedger');
    });

    test('failed commit releases the reservation', () async {
      final inventoryRepo = MockInventoryRepository();
      final layer = _layer(inventoryRepo: inventoryRepo);
      final batches = await inventoryRepo.getInventory(branchId: _branch);
      final batch = batches.firstWhere((item) => item.quantity >= 2);
      final before = batch.quantity;
      // An expired batch in the decrements fails the reserve, so the
      // sale never commits and no stock moves.
      final sale = _sale(
        key: 'sale-fail-1',
        medicineId: batch.medicineId,
        batchId: batch.id,
        qty: 1,
      );
      await expectLater(
        layer.commitSale(
          sale: sale,
          decrements: [(batchId: 'no-such-batch', quantity: 1)],
        ),
        throwsArgumentError,
      );
      final after = (await inventoryRepo.getInventory(branchId: _branch))
          .firstWhere((item) => item.id == batch.id);
      expect(after.quantity, before);
    });

    test('createOrder dedupes on the same idempotency key', () async {
      final orderRepo = MockOrderRepository();
      final layer = _layer(orderRepo: orderRepo);
      final before = (await orderRepo.getOrders(branchId: _branch)).length;
      final order = buildNewOrder(
        branchId: _branch,
        items: [
          OrderItem(
            medicineId: 'med-1',
            medicineName: 'Test',
            quantity: 1,
            unitPrice: 100,
          ),
        ],
        source: OrderSource.phone,
        fulfillment: FulfillmentType.delivery,
      );
      final first = await layer.createOrder(
        order: order,
        idempotencyKey: 'order-dedupe-1',
      );
      expect(first.isDuplicate, isFalse);
      final second = await layer.createOrder(
        order: order,
        idempotencyKey: 'order-dedupe-1',
      );
      expect(second.isDuplicate, isTrue);
      expect(second.order.id, first.order.id);
      final after = (await orderRepo.getOrders(branchId: _branch)).length;
      expect(after, before + 1);
      final auditEntries = await layer.auditEntries(
        branchId: _branch,
        action: 'order.created',
      );
      expect(auditEntries.length, 1);
      final pending = await layer.pendingSyncOperations();
      expect(
        pending.where((op) => op.entityType == 'order').length,
        1,
      );
    });

    test('adjustStock flows through engine + repo with audit', () async {
      final inventoryRepo = MockInventoryRepository();
      final layer = _layer(inventoryRepo: inventoryRepo);
      final batches = await inventoryRepo.getInventory(branchId: _branch);
      final batch = batches.first;
      final before = batch.quantity;
      final movement = await layer.adjustStock(
        batchId: batch.id,
        deltaQty: -1,
        reason: 'Damaged',
      );
      expect(movement.quantity, -1);
      final after = (await inventoryRepo.getInventory(branchId: _branch))
          .firstWhere((item) => item.id == batch.id);
      expect(after.quantity, before - 1);
      final auditEntries = await layer.auditEntries(
        branchId: _branch,
        action: 'stock.adjustment',
      );
      expect(auditEntries.length, 1);
    });
  });

  group('Sync queue — dedupe, retry/back-off, conflicts', () {
    test('backoff doubles and caps at 5 minutes', () {
      expect(backoffForAttempt(0), Duration.zero);
      expect(backoffForAttempt(1), const Duration(seconds: 2));
      expect(backoffForAttempt(2), const Duration(seconds: 4));
      expect(backoffForAttempt(3), const Duration(seconds: 8));
      expect(backoffForAttempt(8), const Duration(seconds: 256));
      expect(backoffForAttempt(9), const Duration(seconds: 300));
      expect(backoffForAttempt(20), const Duration(seconds: 300));
    });

    test('enqueue dedupes on idempotency key', () async {
      final store = InMemorySyncStore();
      final queue = SyncQueue(store);
      final first = await queue.enqueue(
        idempotencyKey: 'op-1',
        entityType: 'sale',
        entityId: 's1',
        branchId: _branch,
        organizationId: _org,
        kind: SyncOperationKind.create,
        payload: const {'a': 1},
      );
      final second = await queue.enqueue(
        idempotencyKey: 'op-1',
        entityType: 'sale',
        entityId: 's1',
        branchId: _branch,
        organizationId: _org,
        kind: SyncOperationKind.create,
        payload: const {'a': 2},
      );
      expect(identical(first, second), isTrue);
      expect((await store.all()).length, 1);
      expect(await queue.pendingCount(), 1);
    });

    test('failed ops retry with back-off, then sync', () async {
      var now = DateTime(2026, 11, 25, 10, 0, 0);
      final queue = SyncQueue(
        InMemorySyncStore(),
        nowProvider: () => now,
      );
      await queue.enqueue(
        idempotencyKey: 'op-retry-1',
        entityType: 'order',
        entityId: 'o1',
        branchId: _branch,
        organizationId: _org,
        kind: SyncOperationKind.create,
        payload: const {},
      );
      var attempts = 0;
      Future<bool> flaky(SyncOperation op) async {
        attempts++;
        if (attempts <= 2) throw Exception('offline');
        return true;
      }
      final first = await queue.processNext(flaky);
      expect(first.outcome, SyncProcessOutcome.failed);
      expect(first.operation!.attemptCount, 1);
      expect(
        first.operation!.nextRetryAt,
        now.add(const Duration(seconds: 2)),
      );
      // Not due yet — nothing to process.
      final idle = await queue.processNext(flaky);
      expect(idle.outcome, SyncProcessOutcome.nothingPending);
      expect(attempts, 1);
      // After the back-off window it retries and fails again (4s).
      now = now.add(const Duration(seconds: 3));
      final second = await queue.processNext(flaky);
      expect(second.outcome, SyncProcessOutcome.failed);
      expect(second.operation!.attemptCount, 2);
      expect(
        second.operation!.nextRetryAt,
        now.add(const Duration(seconds: 4)),
      );
      // After that window it syncs.
      now = now.add(const Duration(seconds: 5));
      final third = await queue.processNext(flaky);
      expect(third.outcome, SyncProcessOutcome.synced);
      expect(third.operation!.status, SyncOperationStatus.synced);
      expect(await queue.pendingCount(), 0);
    });

    test('money/stock conflict is flagged, never silently retried', () async {
      final audit = InMemoryAuditLogWriter();
      final queue = SyncQueue(InMemorySyncStore());
      await queue.enqueue(
        idempotencyKey: 'op-conflict-1',
        entityType: 'sale',
        entityId: 's1',
        branchId: _branch,
        organizationId: _org,
        kind: SyncOperationKind.create,
        payload: const {},
      );
      Future<bool> conflicting(SyncOperation op) async {
        throw SyncConflictException('Batch quantity insufficient online.');
      }
      final result = await queue.processNext(conflicting, audit: audit);
      expect(result.outcome, SyncProcessOutcome.conflict);
      expect(result.operation!.status, SyncOperationStatus.conflict);
      // A conflicted op is never due again — it waits for a human.
      final idle = await queue.processNext(conflicting, audit: audit);
      expect(idle.outcome, SyncProcessOutcome.nothingPending);
      final auditEntries = await audit.entries(action: 'sync.conflict');
      expect(auditEntries.length, 1);
      expect(auditEntries.first.entityType, 'sale');
    });

    test('processAll drains due ops and reports the synced count', () async {
      final queue = SyncQueue(InMemorySyncStore());
      for (var i = 0; i < 3; i++) {
        await queue.enqueue(
          idempotencyKey: 'op-drain-$i',
          entityType: 'order',
          entityId: 'o$i',
          branchId: _branch,
          organizationId: _org,
          kind: SyncOperationKind.create,
          payload: const {},
        );
      }
      final synced = await queue.processAll((op) async => true);
      expect(synced, 3);
      expect(await queue.pendingCount(), 0);
    });

    test('platform store is sqflite-backed on mobile/VM, in-memory on web',
        () {
      final store = createSyncStore();
      // flutter test runs on the VM (non-web): the io store is used.
      expect(store, isA<SqfliteSyncStore>());
      expect((store as SqfliteSyncStore).durable, isFalse);
    });
  });

  group('Backup export / import', () {
    test('export contains all sections and is valid JSON', () async {
      final layer = _layer();
      final doc = await layer.exportBackup();
      expect(doc['format'], BackupFormat.format);
      expect(doc['formatVersion'], BackupFormat.currentVersion);
      expect(doc['organizationId'], _org);
      final sections = doc['sections'] as Map<String, dynamic>;
      expect((sections['medicines'] as List).length, 180);
      expect((sections['orders'] as List).length, 491);
      expect((sections['sales'] as List).length, 0);
      expect((sections['inventory'] as List).isNotEmpty, isTrue);
      expect((sections['customers'] as List).length, 8);
      expect((sections['customerLedger'] as List).isNotEmpty, isTrue);
      expect((sections['suppliers'] as List).length, 4);
      expect((sections['prescriptions'] as List).length, 20);
      expect((sections['purchaseOrders'] as List).length, 6);
      // JSON-encodes cleanly (dates are ISO strings, not Timestamps).
      final json = await layer.exportBackupJson();
      final decoded = jsonDecode(json) as Map<String, dynamic>;
      expect(decoded['format'], BackupFormat.format);
    });

    test('per-branch export scopes branch sections', () async {
      final layer = _layer();
      final doc = await layer.exportBackup(branchId: _branch);
      expect(doc['branchId'], _branch);
      final sections = doc['sections'] as Map<String, dynamic>;
      final orders = sections['orders'] as List;
      expect(orders.isNotEmpty, isTrue);
      for (final order in orders) {
        expect(
          (order as Map<String, dynamic>)['branchId'],
          _branch,
        );
      }
      // Org-wide catalogue is still included in full.
      expect((sections['medicines'] as List).length, 180);
    });

    test('export after a sale contains the committed sale', () async {
      final inventoryRepo = MockInventoryRepository();
      final saleRepo = MockSaleRepository();
      final layer = _layer(
        inventoryRepo: inventoryRepo,
        saleRepo: saleRepo,
      );
      final batches = await inventoryRepo.getInventory(branchId: _branch);
      final batch = batches.firstWhere((item) => item.quantity >= 2);
      await layer.commitSale(
        sale: _sale(
          key: 'sale-export-1',
          medicineId: batch.medicineId,
          batchId: batch.id,
          qty: 1,
        ),
        decrements: [(batchId: batch.id, quantity: 1)],
      );
      final doc = await layer.exportBackup(branchId: _branch);
      final sections = doc['sections'] as Map<String, dynamic>;
      final sales = sections['sales'] as List;
      expect(sales.length, 1);
      expect(
        (sales.first as Map<String, dynamic>)['idempotencyKey'],
        'sale-export-1',
      );
      // Audit + pending sync op are part of the backup too.
      expect((sections['auditLogs'] as List).isNotEmpty, isTrue);
      expect((sections['syncQueue'] as List).length, 1);
    });

    test('import round-trip: no duplicates, overwrite policy replaces',
        () async {
      final layer = _layer();
      final doc = await layer.exportBackup();
      final total = (doc['sections'] as Map<String, dynamic>).values.fold(
        0,
        (sum, list) => sum + (list as List).length,
      );
      expect(total, greaterThan(0));

      // Week 5 Day 2 (D150): the restore now targets the LIVE repos,
      // so importing an export of the live data itself creates
      // nothing under skip policy — every doc already exists — and
      // replaces everything under overwrite policy, still without
      // duplicating a document.
      final first = await layer.importBackup(doc);
      expect(first.success, isTrue);
      expect(first.created, 0);
      expect(first.skipped, total);

      // Same backup again, skip policy: nothing new, nothing duplicated.
      final second = await layer.importBackup(doc);
      expect(second.created, 0);
      expect(second.skipped, total);

      // Overwrite policy: every doc replaced, still no duplicates.
      final third = await layer.importBackup(
        doc,
        policy: ImportPolicy.overwrite,
      );
      expect(third.overwritten, total);
      expect(third.created, 0);
      expect(layer.restoredData.count('medicines'), 180);
    });

    test('import validation rejects bad backups before any write', () {
      final sink = InMemoryRestoreSink();
      final importer = DataImporter();
      final badFormat = {'format': 'other', 'formatVersion': 1};
      final report = importer.importBackup(badFormat, sink);
      expect(report.success, isFalse);
      expect(report.errors, isNotEmpty);
      expect(report.created, 0);
      expect(sink.count('medicines'), 0);

      final badVersion = {
        'format': BackupFormat.format,
        'formatVersion': 99,
        'organizationId': _org,
        'sections': <String, dynamic>{},
      };
      final report2 = importer.importBackup(badVersion, sink);
      expect(report2.success, isFalse);

      final noId = {
        'format': BackupFormat.format,
        'formatVersion': 1,
        'organizationId': _org,
        'sections': {
          'medicines': [
            {'name': 'No id here'},
          ],
        },
      };
      final report3 = importer.importBackup(noId, sink);
      expect(report3.success, isFalse);
      expect(sink.count('medicines'), 0);
    });
  });

  group('Prescription sample image (Day 1 defect check)', () {
    testWidgets('detail screen renders the bundled sample image',
        (WidgetTester tester) async {
      final (_, router) = await pumpRouterApp(
        tester,
        size: const Size(800, 1600),
      );
      router.go('/prescriptions/rx-dha-1');
      await tester.pumpAndSettle();
      expect(find.text('rx-dha-1'), findsWidgets);
      // The detail screen must show the bundled sample image — an
      // Image widget wired to the sample asset path. That is what a
      // widget test can prove here: the test environment's asset
      // bundle cannot serve app assets at all (probe-verified —
      // even AssetManifest.json fails to load in `flutter test`),
      // so the Image shows its error fallback in tests even though
      // the wiring is correct. The real-bytes half of the check is
      // the web build output containing the PNGs (see
      // docs/day-08-progress.md).
      final imageWidgets = find.byType(Image);
      expect(imageWidgets, findsWidgets);
      var foundSampleAsset = false;
      for (final element in imageWidgets.evaluate()) {
        final widget = element.widget as Image;
        final image = widget.image;
        if (image is AssetImage &&
            image.assetName.startsWith(
              'assets/images/prescriptions/sample-prescription-',
            )) {
          foundSampleAsset = true;
        }
      }
      expect(foundSampleAsset, isTrue);
      expect(find.textContaining('SAMPLE image bundled'), findsOneWidget);
    });
  });
}

/// Pumps the ungated router app with a fresh container the test owns
/// (same helper as Day 7's widget tests).
Future<(ProviderContainer, GoRouter)> pumpRouterApp(
  WidgetTester tester, {
  Size size = const Size(800, 600),
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final container = ProviderContainer();
  addTearDown(container.dispose);
  final router = createAppRouter();
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: AppTheme.light(BrandConfig.defaults),
        darkTheme: AppTheme.dark(BrandConfig.defaults),
        themeMode: ThemeMode.light,
        routerConfig: router,
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 1500));
  await tester.pumpAndSettle();
  return (container, router);
}
