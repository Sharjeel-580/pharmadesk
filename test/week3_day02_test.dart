// Week 3 Day 2 tests — goodsReceipts through the production data
// layer (D103) + salary screen (D102).
//
// - `goodsReceipts` document written when a PO line is received, and
//   receiving routed through `ProductionDataLayer.receiveGoods`
//   (idempotency / no double-write / audit + sync payload), with the
//   Day 7 receiving UI + behaviour intact (the notifier calls the
//   layer now — the same Day 7 flows are re-run through it).
// - Salary figures live in a separate payroll record
//   ([SalaryRecord]), never on the [Staff] model: pure logic,
//   repositories (mock + Firestore over the in-memory fake
//   transport, copied from the Day 3 / Week 3 Day 1 tests — there
//   is still no Firebase project, D13), the `hrSalary` gate, and
//   the salary screen (rows + monthly totals + demo labelling).

import 'package:cloud_firestore/cloud_firestore.dart' hide Order;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:pharmadesk/core/data/audit_log.dart';
import 'package:pharmadesk/core/data/auth_repository.dart';
import 'package:pharmadesk/core/data/firestore_mappers.dart';
import 'package:pharmadesk/core/data/firestore_repositories.dart';
import 'package:pharmadesk/core/data/firestore_schema.dart';
import 'package:pharmadesk/core/data/firestore_transport.dart';
import 'package:pharmadesk/core/data/inventory_engine.dart';
import 'package:pharmadesk/core/data/production_data_layer.dart';
import 'package:pharmadesk/core/data/repository_factory.dart';
import 'package:pharmadesk/core/data/sync_queue.dart';
import 'package:pharmadesk/core/routing/app_router.dart';
import 'package:pharmadesk/core/services/demo_seed_data.dart';
import 'package:pharmadesk/core/services/repositories.dart';
import 'package:pharmadesk/core/theme/app_theme.dart';
import 'package:pharmadesk/core/theme/white_label.dart';
import 'package:pharmadesk/features/authentication/auth_state.dart';
import 'package:pharmadesk/features/purchases/purchases_logic.dart';
import 'package:pharmadesk/features/purchases/purchases_provider.dart';
import 'package:pharmadesk/features/staff/salary_logic.dart';
import 'package:pharmadesk/models/goods_receipt.dart';
import 'package:pharmadesk/models/purchase_order.dart';
import 'package:pharmadesk/models/salary_record.dart';
import 'package:pharmadesk/models/staff.dart';

const _dha = 'branch-dha-main';
const _glb = 'branch-demo-gulberg';
const _org = demoOrganizationId;

/// In-memory [FirestoreTransport]: documents live in a map keyed by
/// full path. Same behaviour as the Day 3 / Week 3 Day 1 fake.
class FakeFirestoreTransport implements FirestoreTransport {
  final Map<String, Map<String, dynamic>> docs = {};

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

  @override
  Future<void> runBatchedWrites(List<WriteOperation> operations) async {
    for (var i = 0; i < operations.length; i += maxFirestoreBatchWrites) {
      final end = (i + maxFirestoreBatchWrites).clamp(0, operations.length);
      final chunk = operations.sublist(i, end);
      for (final operation in chunk) {
        switch (operation.kind) {
          case WriteOperationKind.set:
            docs[operation.path] = Map<String, dynamic>.from(
              operation.data ?? const {},
            );
          case WriteOperationKind.update:
            final existing = docs[operation.path];
            if (existing == null) {
              throw StateError('No document at ${operation.path} to update.');
            }
            docs[operation.path] = {...existing, ...?operation.data};
          case WriteOperationKind.delete:
            docs.remove(operation.path);
        }
      }
    }
  }

  @override
  Future<T> runTransaction<T>(
    Future<T> Function(FirestoreTransaction tx) action,
  ) async {
    return action(_FakeTransaction(docs));
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
/// `branches` for branch-less reads).
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

// -- Sample builders ------------------------------------------------------

AppUser _userFor(String roleKey, [List<String> branches = const [_dha]]) {
  return AppUser(
    uid: 'u-$roleKey',
    email: '$roleKey@fazaldin.pk',
    displayName: roleKey,
    orgId: demoOrganizationId,
    branchIds: branches,
    roleKey: roleKey,
  );
}

PurchaseOrderItem _poItem({
  String medicineId = 'med-panadol-extra',
  String medicineName = 'Panadol Extra',
  int quantityOrdered = 10,
  int unitCostMinor = 10000,
}) => PurchaseOrderItem(
  medicineId: medicineId,
  medicineName: medicineName,
  quantityOrdered: quantityOrdered,
  unitCostMinor: unitCostMinor,
);

GoodsReceiptItem _receiptItem({
  String medicineId = 'med-panadol-extra',
  String medicineName = 'Panadol Extra',
  int quantityReceived = 10,
  String batchNo = 'B-TEST-1',
  int unitCostMinor = 10000,
}) => GoodsReceiptItem(
  medicineId: medicineId,
  medicineName: medicineName,
  quantityReceived: quantityReceived,
  batchNo: batchNo,
  mfgDate: DateTime(2026, 1, 1),
  expiryDate: DateTime(2027, 1, 1),
  unitCostMinor: unitCostMinor,
);

GoodsReceipt _receipt({
  String id = '',
  String poId = 'po-1',
  String branchId = _dha,
  List<GoodsReceiptItem>? items,
}) => GoodsReceipt(
  id: id,
  poId: poId,
  supplierId: 'sup-sami',
  branchId: branchId,
  receivedBy: 'Test Receiver',
  receivedAt: DateTime(2026, 11, 25, 10, 30),
  items: items ?? [_receiptItem()],
);

SalaryRecord _salary({
  String id = '',
  String employeeId = 'staff-1',
  String branchId = _dha,
  String month = '2026-11',
  int base = 10000000,
  int allowances = 500000,
  int deductions = 0,
  bool isDemo = false,
}) => SalaryRecord(
  id: id,
  employeeId: employeeId,
  branchId: branchId,
  month: month,
  baseSalaryMinor: base,
  allowancesMinor: allowances,
  deductionsMinor: deductions,
  isDemo: isDemo,
);

/// Production layer over fresh mocks, with the repos + engine kept
/// so tests can assert against them (same helper shape as the
/// Week 2 Day 1 layer tests).
({
  ProductionDataLayer layer,
  MockInventoryRepository inventoryRepo,
  MockSupplierRepository supplierRepo,
  MockPurchaseOrderRepository purchaseOrderRepo,
  MockGoodsReceiptRepository goodsReceiptRepo,
  InventoryEngine engine,
  InMemoryAuditLogWriter audit,
  SyncQueue queue,
})
_layer() {
  final audit = InMemoryAuditLogWriter();
  final queue = SyncQueue(InMemorySyncStore());
  final engine = InventoryEngine(organizationId: _org, audit: audit);
  final inventoryRepo = MockInventoryRepository();
  final supplierRepo = MockSupplierRepository();
  final purchaseOrderRepo = MockPurchaseOrderRepository();
  final goodsReceiptRepo = MockGoodsReceiptRepository();
  final layer = ProductionDataLayer(
    organizationId: _org,
    inventoryRepo: inventoryRepo,
    saleRepo: MockSaleRepository(),
    orderRepo: MockOrderRepository(),
    customerRepo: MockCustomerRepository(),
    medicineRepo: MockMedicineRepository(),
    supplierRepo: supplierRepo,
    prescriptionRepo: MockPrescriptionRepository(),
    purchaseOrderRepo: purchaseOrderRepo,
    riderRepo: MockRiderRepository(),
    goodsReceiptRepo: goodsReceiptRepo,
    audit: audit,
    syncQueue: queue,
    engine: engine,
  );
  return (
    layer: layer,
    inventoryRepo: inventoryRepo,
    supplierRepo: supplierRepo,
    purchaseOrderRepo: purchaseOrderRepo,
    goodsReceiptRepo: goodsReceiptRepo,
    engine: engine,
    audit: audit,
    queue: queue,
  );
}

/// An approved PO in the layer's mock PO repo (create is Draft, so
/// approve by update — the same transition the notifier performs).
Future<PurchaseOrder> _approvedPo(
  MockPurchaseOrderRepository repo, {
  String branchId = _dha,
  String supplierId = 'sup-sami',
  int quantityOrdered = 10,
}) async {
  final created = await repo.createPurchaseOrder(
    buildNewPurchaseOrder(
      branchId: branchId,
      supplierId: supplierId,
      items: [_poItem(quantityOrdered: quantityOrdered)],
    ),
  );
  final approved = created.copyWith(status: PurchaseOrderStatus.approved);
  await repo.updatePurchaseOrder(approved);
  return approved;
}

/// Pumps the ungated router app with a fresh container the test owns
/// (same harness as the Week 2 Day 5 widget tests).
Future<(ProviderContainer, GoRouter)> pumpRouterApp(
  WidgetTester tester, {
  Size size = const Size(1280, 900),
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

void main() {
  group('GoodsReceipt model', () {
    test('totalValueMinor sums line totals; toMap/fromMap round-trips', () {
      final receipt = _receipt(
        items: [
          _receiptItem(quantityReceived: 4, unitCostMinor: 10000),
          _receiptItem(
            medicineId: 'med-brufen',
            medicineName: 'Brufen',
            quantityReceived: 6,
            batchNo: 'B-TEST-2',
            unitCostMinor: 5000,
          ),
        ],
      );
      expect(receipt.totalValueMinor, 4 * 10000 + 6 * 5000);
      final restored = GoodsReceipt.fromMap('gr-1', receipt.toMap());
      expect(restored.poId, 'po-1');
      expect(restored.supplierId, 'sup-sami');
      expect(restored.branchId, _dha);
      expect(restored.receivedBy, 'Test Receiver');
      expect(restored.receivedAt, DateTime(2026, 11, 25, 10, 30));
      expect(restored.items.length, 2);
      expect(restored.items[1].batchNo, 'B-TEST-2');
      expect(restored.items[1].mfgDate, DateTime(2026, 1, 1));
      expect(restored.items[1].expiryDate, DateTime(2027, 1, 1));
      expect(restored.totalValueMinor, receipt.totalValueMinor);
    });

    test('copyWith keeps the rest; empty items total zero', () {
      final receipt = _receipt().copyWith(receiptNumber: 'GR-DHA-1001');
      expect(receipt.receiptNumber, 'GR-DHA-1001');
      expect(receipt.status, 'received');
      expect(_receipt(items: []).totalValueMinor, 0);
    });
  });

  group('MockGoodsReceiptRepository', () {
    test('create assigns GR number; retry with same id returns original',
        () async {
      final repo = MockGoodsReceiptRepository();
      final saved = await repo.createGoodsReceipt(
        _receipt(id: 'receipt-1'),
      );
      expect(saved.id, 'receipt-1');
      expect(saved.receiptNumber, 'GR-DHA-1001');
      final again = await repo.createGoodsReceipt(_receipt(id: 'receipt-1'));
      expect(again.receiptNumber, 'GR-DHA-1001');
      expect((await repo.getGoodsReceipts()).length, 1);
      final second = await repo.createGoodsReceipt(
        _receipt(id: 'receipt-2', branchId: _glb),
      );
      expect(second.receiptNumber, 'GR-GLB-1002');
    });

    test('getGoodsReceipts filters by branch and PO', () async {
      final repo = MockGoodsReceiptRepository();
      await repo.createGoodsReceipt(_receipt(id: 'r1', poId: 'po-1'));
      await repo.createGoodsReceipt(_receipt(id: 'r2', poId: 'po-1'));
      await repo.createGoodsReceipt(
        _receipt(id: 'r3', poId: 'po-2', branchId: _glb),
      );
      expect((await repo.getGoodsReceipts()).length, 3);
      expect((await repo.getGoodsReceipts(branchId: _dha)).length, 2);
      expect((await repo.getGoodsReceipts(poId: 'po-1')).length, 2);
      expect((await repo.getGoodsReceipts(poId: 'po-2')).length, 1);
      expect((await repo.getById('r2'))?.poId, 'po-1');
      expect(await repo.getById('missing'), isNull);
    });
  });

  group('ProductionDataLayer.receiveGoods (D103)', () {
    test('receive writes receipt + batch + ledger + PO + audit + sync',
        () async {
      final t = _layer();
      final po = await _approvedPo(t.purchaseOrderRepo);
      final beforeQty = (await t.inventoryRepo.getInventory(
        branchId: _dha,
      ))
          .where((i) => i.medicineId == 'med-panadol-extra')
          .fold(0, (acc, i) => acc + i.quantity);
      final beforeOutstanding = (await t.supplierRepo.getLedgerEntries(
        'sup-sami',
      )).fold(0, (acc, e) => acc + e.amountMinor);

      final result = await t.layer.receiveGoods(
        order: po,
        lines: [
          ReceivingLine(
            item: po.items.first,
            quantityReceivedNow: 10,
            batchNo: 'B-TEST-1',
            mfgDate: DateTime.now().subtract(const Duration(days: 30)),
            expiryDate: DateTime.now().add(const Duration(days: 365)),
          ),
        ],
        idempotencyKey: 'receipt-day2-1',
      );
      expect(result.isDuplicate, false);
      expect(result.receipt.id, 'receipt-day2-1');
      expect(result.receipt.receiptNumber, 'GR-DHA-1001');
      expect(result.receipt.poId, po.id);
      expect(result.receipt.totalValueMinor, 100000);
      expect(result.order.status, PurchaseOrderStatus.received);

      // The receipt is on file in the repo.
      final stored = await t.goodsReceiptRepo.getGoodsReceipts(poId: po.id);
      expect(stored.length, 1);
      expect(stored.first.items.first.batchNo, 'B-TEST-1');
      expect(stored.first.items.first.quantityReceived, 10);

      // Stock + ledger moved exactly once.
      final afterQty = (await t.inventoryRepo.getInventory(
        branchId: _dha,
      ))
          .where((i) => i.medicineId == 'med-panadol-extra')
          .fold(0, (acc, i) => acc + i.quantity);
      expect(afterQty, beforeQty + 10);
      expect(
        (await t.inventoryRepo.getInventory(branchId: _dha)).any(
          (i) => i.batchNo == 'B-TEST-1' && i.medicineId == 'med-panadol-extra',
        ),
        true,
      );
      final afterOutstanding = (await t.supplierRepo.getLedgerEntries(
        'sup-sami',
      )).fold(0, (acc, e) => acc + e.amountMinor);
      expect(afterOutstanding, beforeOutstanding + 100000);

      // Engine: one receive movement, counter up.
      expect(result.movements.length, 1);
      expect(result.movements.first.type, StockMovementType.receive);
      expect(result.movements.first.quantity, 10);
      expect(result.movements.first.referenceId, result.receipt.id);
      expect(
        t.engine.counterFor('med-panadol-extra').quantityOnHand,
        afterQty,
      );

      // Audit + sync payload name the receipt.
      final audits = await t.layer.auditEntries(action: 'goods.received');
      expect(audits.length, 1);
      expect(audits.first.entityId, result.receipt.id);
      expect(await t.layer.pendingSyncCount(), 1);
      final ops = await t.layer.pendingSyncOperations();
      expect(ops.single.entityType, 'goodsReceipt');
      expect(
        (ops.single.payload['path'] as String).contains('goodsReceipts'),
        true,
      );
      final operations =
          (ops.single.payload['operations'] as List).cast<Map>();
      expect(
        operations.any(
          (op) => (op['path'] as String).contains('/goodsReceipts/'),
        ),
        true,
      );
      expect(
        operations.any((op) => (op['path'] as String).contains('/items/')),
        true,
      );
    });

    test('partial receiving: two receipts, PO partially then received',
        () async {
      final t = _layer();
      final po = await _approvedPo(t.purchaseOrderRepo);
      final first = await t.layer.receiveGoods(
        order: po,
        lines: [
          ReceivingLine(
            item: po.items.first,
            quantityReceivedNow: 4,
            batchNo: 'B-2',
            mfgDate: DateTime(2026, 1, 1),
            expiryDate: DateTime(2027, 1, 1),
          ),
        ],
        idempotencyKey: 'receipt-day2-part-1',
      );
      expect(first.order.status, PurchaseOrderStatus.partiallyReceived);
      expect(first.receipt.totalValueMinor, 40000);
      final second = await t.layer.receiveGoods(
        order: first.order,
        lines: [
          ReceivingLine(
            item: first.order.items.first,
            quantityReceivedNow: 6,
            batchNo: 'B-3',
            mfgDate: DateTime(2026, 1, 1),
            expiryDate: DateTime(2027, 1, 1),
          ),
        ],
        idempotencyKey: 'receipt-day2-part-2',
      );
      expect(second.order.status, PurchaseOrderStatus.received);
      expect(second.receipt.receiptNumber, 'GR-DHA-1002');
      expect(
        (await t.goodsReceiptRepo.getGoodsReceipts(poId: po.id)).length,
        2,
      );
    });

    test('duplicate key returns original, moves nothing twice', () async {
      final t = _layer();
      final po = await _approvedPo(t.purchaseOrderRepo);
      final line = ReceivingLine(
        item: po.items.first,
        quantityReceivedNow: 10,
        batchNo: 'B-DUP-1',
        mfgDate: DateTime(2026, 1, 1),
        expiryDate: DateTime(2027, 1, 1),
      );
      final first = await t.layer.receiveGoods(
        order: po,
        lines: [line],
        idempotencyKey: 'receipt-day2-dup',
      );
      final qtyAfterFirst = (await t.inventoryRepo.getInventory(
        branchId: _dha,
      ))
          .where((i) => i.medicineId == 'med-panadol-extra')
          .fold(0, (acc, i) => acc + i.quantity);
      final outstandingAfterFirst = (await t.supplierRepo.getLedgerEntries(
        'sup-sami',
      )).fold(0, (acc, e) => acc + e.amountMinor);

      final duplicate = await t.layer.receiveGoods(
        order: po,
        lines: [line],
        idempotencyKey: 'receipt-day2-dup',
      );
      expect(duplicate.isDuplicate, true);
      expect(duplicate.receipt.id, first.receipt.id);
      expect(duplicate.movements, isEmpty);
      expect(
        (await t.goodsReceiptRepo.getGoodsReceipts(poId: po.id)).length,
        1,
      );
      final qtyAfterDup = (await t.inventoryRepo.getInventory(
        branchId: _dha,
      ))
          .where((i) => i.medicineId == 'med-panadol-extra')
          .fold(0, (acc, i) => acc + i.quantity);
      expect(qtyAfterDup, qtyAfterFirst);
      final outstandingAfterDup = (await t.supplierRepo.getLedgerEntries(
        'sup-sami',
      )).fold(0, (acc, e) => acc + e.amountMinor);
      expect(outstandingAfterDup, outstandingAfterFirst);
      expect(await t.layer.pendingSyncCount(), 1);
    });

    test('guards: invalid key, draft PO, over-receive all throw', () async {
      final t = _layer();
      final po = await _approvedPo(t.purchaseOrderRepo);
      final line = ReceivingLine(
        item: po.items.first,
        quantityReceivedNow: 5,
        batchNo: 'B-G-1',
        mfgDate: DateTime(2026, 1, 1),
        expiryDate: DateTime(2027, 1, 1),
      );
      await expectLater(
        t.layer.receiveGoods(order: po, lines: [line], idempotencyKey: ''),
        throwsArgumentError,
      );
      final draft = await t.purchaseOrderRepo.createPurchaseOrder(
        buildNewPurchaseOrder(
          branchId: _dha,
          supplierId: 'sup-sami',
          items: [_poItem()],
        ),
      );
      await expectLater(
        t.layer.receiveGoods(
          order: draft,
          lines: [line],
          idempotencyKey: 'receipt-day2-draft',
        ),
        throwsArgumentError,
      );
      await expectLater(
        t.layer.receiveGoods(
          order: po,
          lines: [
            ReceivingLine(
              item: po.items.first,
              quantityReceivedNow: 11,
              batchNo: 'B-G-2',
              mfgDate: DateTime(2026, 1, 1),
              expiryDate: DateTime(2027, 1, 1),
            ),
          ],
          idempotencyKey: 'receipt-day2-over',
        ),
        throwsArgumentError,
      );
      // Nothing was written by the rejected attempts.
      expect((await t.goodsReceiptRepo.getGoodsReceipts()).length, 0);
    });

    test('orphan receipt: a key already on file fails loudly, no stock',
        () async {
      final t = _layer();
      final po = await _approvedPo(t.purchaseOrderRepo);
      await t.goodsReceiptRepo.createGoodsReceipt(
        _receipt(id: 'receipt-day2-orphan', poId: po.id),
      );
      final beforeQty = (await t.inventoryRepo.getInventory(
        branchId: _dha,
      ))
          .where((i) => i.medicineId == 'med-panadol-extra')
          .fold(0, (acc, i) => acc + i.quantity);
      await expectLater(
        t.layer.receiveGoods(
          order: po,
          lines: [
            ReceivingLine(
              item: po.items.first,
              quantityReceivedNow: 5,
              batchNo: 'B-ORPHAN',
              mfgDate: DateTime(2026, 1, 1),
              expiryDate: DateTime(2027, 1, 1),
            ),
          ],
          idempotencyKey: 'receipt-day2-orphan',
        ),
        throwsStateError,
      );
      final afterQty = (await t.inventoryRepo.getInventory(
        branchId: _dha,
      ))
          .where((i) => i.medicineId == 'med-panadol-extra')
          .fold(0, (acc, i) => acc + i.quantity);
      expect(afterQty, beforeQty);
    });
  });

  group('Purchases notifier receives through the layer (Day 7 flows)', () {
    test('receiveOrder writes the receipt; same-key retry is a no-op',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final inventoryRepo = container.read(inventoryRepositoryProvider);
      final supplierRepo = container.read(supplierRepositoryProvider);
      final receiptRepo = container.read(goodsReceiptRepositoryProvider);
      final beforeQty = (await inventoryRepo.getInventory(
        branchId: _dha,
      ))
          .where((i) => i.medicineId == 'med-panadol-extra')
          .fold(0, (acc, i) => acc + i.quantity);

      final notifier = container.read(purchaseOrdersProvider.notifier);
      final created = await notifier.createOrder(
        branchId: _dha,
        supplierId: 'sup-sami',
        items: [_poItem(quantityOrdered: 10, unitCostMinor: 10000)],
      );
      expect(created.error, isNull);
      final po = created.order!;
      expect(await notifier.approveOrder(po), true);
      final approved = container.read(purchaseOrderByIdProvider(po.id))!;

      final received = await notifier.receiveOrder(
        approved,
        [
          ReceivingLine(
            item: approved.items.first,
            quantityReceivedNow: 10,
            batchNo: 'B-NOT-1',
            mfgDate: DateTime.now().subtract(const Duration(days: 30)),
            expiryDate: DateTime.now().add(const Duration(days: 365)),
          ),
        ],
        idempotencyKey: 'receipt-notifier-1',
      );
      expect(received.error, isNull);
      expect(received.order!.status, PurchaseOrderStatus.received);
      final receipts = await receiptRepo.getGoodsReceipts(poId: po.id);
      expect(receipts.length, 1);
      expect(receipts.first.receiptNumber, startsWith('GR-DHA-'));

      // Same key again through the notifier: duplicate, no more stock.
      final retry = await notifier.receiveOrder(
        received.order!,
        [
          ReceivingLine(
            item: received.order!.items.first,
            quantityReceivedNow: 0,
            batchNo: 'B-NOT-1',
            mfgDate: DateTime(2026, 1, 1),
            expiryDate: DateTime(2027, 1, 1),
          ),
        ],
        idempotencyKey: 'receipt-notifier-1',
      );
      // The PO is already fully received, so the guard stops it
      // before the layer: same outcome (no second receipt, no
      // second stock move) via the guard path.
      expect(retry.order, isNull);
      expect((await receiptRepo.getGoodsReceipts(poId: po.id)).length, 1);
      final afterQty = (await inventoryRepo.getInventory(
        branchId: _dha,
      ))
          .where((i) => i.medicineId == 'med-panadol-extra')
          .fold(0, (acc, i) => acc + i.quantity);
      expect(afterQty, beforeQty + 10);
      final outstanding = (await supplierRepo.getLedgerEntries(
        'sup-sami',
      )).fold(0, (acc, e) => acc + e.amountMinor);
      expect(outstanding, greaterThan(0));
    });

    test('receiveOrder without a key still writes the receipt', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final receiptRepo = container.read(goodsReceiptRepositoryProvider);
      final notifier = container.read(purchaseOrdersProvider.notifier);
      final created = await notifier.createOrder(
        branchId: _glb,
        supplierId: 'sup-medserve',
        items: [_poItem(quantityOrdered: 5, unitCostMinor: 20000)],
      );
      final po = created.order!;
      expect(await notifier.approveOrder(po), true);
      final approved = container.read(purchaseOrderByIdProvider(po.id))!;
      final received = await notifier.receiveOrder(approved, [
        ReceivingLine(
          item: approved.items.first,
          quantityReceivedNow: 5,
          batchNo: 'B-NOT-2',
          mfgDate: DateTime(2026, 1, 1),
          expiryDate: DateTime(2027, 1, 1),
        ),
      ]);
      expect(received.error, isNull);
      expect(received.order!.status, PurchaseOrderStatus.received);
      expect((await receiptRepo.getGoodsReceipts(poId: po.id)).length, 1);
    });
  });

  group('FirestoreGoodsReceiptRepository', () {
    test('mapper round-trips receipt + items with Timestamps', () {
      final receipt = _receipt();
      final doc = goodsReceiptToFirestore(receipt, orgId: _org);
      expect(doc['poId'], 'po-1');
      expect(doc['supplierId'], 'sup-sami');
      expect(doc['totalValueMinor'], 100000);
      expect(doc['receivedAt'], isA<Timestamp>());
      final itemDoc = goodsReceiptItemToFirestore(
        receipt.items.first,
        orgId: _org,
        branchId: _dha,
      );
      expect(itemDoc['batchNo'], 'B-TEST-1');
      expect(itemDoc['quantityReceived'], 10);
      expect(itemDoc['mfgDate'], isA<Timestamp>());
      final restored = goodsReceiptFromFirestore(
        'gr-1',
        doc,
        itemDocs: [itemDoc],
      );
      expect(restored.poId, 'po-1');
      expect(restored.receivedAt, DateTime(2026, 11, 25, 10, 30));
      expect(restored.items.first.batchNo, 'B-TEST-1');
      expect(restored.totalValueMinor, 100000);
    });

    test('create assigns sequential GR numbers; retry returns original',
        () async {
      final transport = FakeFirestoreTransport();
      await seedBranches(transport);
      final repo = FirestoreGoodsReceiptRepository(
        transport: transport,
        organizationId: _org,
      );
      final first = await repo.createGoodsReceipt(_receipt(id: 'gr-a'));
      expect(first.receiptNumber, 'GR-DHA-1001');
      final again = await repo.createGoodsReceipt(_receipt(id: 'gr-a'));
      expect(again.receiptNumber, 'GR-DHA-1001');
      expect(transport.countIn('branches/$_dha/goodsReceipts'), 1);
      final second = await repo.createGoodsReceipt(_receipt(id: 'gr-b'));
      // The retry consumed no counter value.
      expect(second.receiptNumber, 'GR-DHA-1002');
      final fetched = await repo.getById('gr-a');
      expect(fetched?.items.first.batchNo, 'B-TEST-1');
      expect(
        (await repo.getGoodsReceipts(branchId: _dha, poId: 'po-1')).length,
        2,
      );
      expect((await repo.getGoodsReceipts(poId: 'no-such-po')).length, 0);
    });

    test('create rejects a receipt without PO or branch', () async {
      final transport = FakeFirestoreTransport();
      await seedBranches(transport);
      final repo = FirestoreGoodsReceiptRepository(
        transport: transport,
        organizationId: _org,
      );
      await expectLater(
        repo.createGoodsReceipt(_receipt(poId: '')),
        throwsArgumentError,
      );
      await expectLater(
        repo.createGoodsReceipt(_receipt(branchId: '')),
        throwsArgumentError,
      );
    });
  });

  group('SalaryRecord model + salary_logic', () {
    test('net is base + allowances − deductions; round-trips', () {
      final record = _salary(base: 10000000, allowances: 500000, deductions: 200000);
      expect(record.netMinor, 10300000);
      final restored = SalaryRecord.fromMap('sal-1', record.toMap());
      expect(restored.netMinor, 10300000);
      expect(restored.month, '2026-11');
      expect(restored.isDemo, false);
    });

    test('month keys and labels', () {
      expect(salaryMonthKey(DateTime(2026, 11, 25)), '2026-11');
      expect(salaryMonthLabel('2026-11'), 'November 2026');
      expect(salaryMonthLabel('2026-01'), 'January 2026');
      expect(salaryMonthLabel('garbage'), 'garbage');
      expect(previousSalaryMonth('2026-11'), '2026-10');
      expect(previousSalaryMonth('2026-01'), '2025-12');
      expect(nextSalaryMonth('2026-11'), '2026-12');
      expect(nextSalaryMonth('2026-12'), '2027-01');
    });

    test('validateSalaryRecord catches bad amounts and months', () {
      expect(validateSalaryRecord(_salary()), isEmpty);
      expect(
        validateSalaryRecord(_salary(base: -1)),
        contains('Base salary cannot be negative.'),
      );
      expect(
        validateSalaryRecord(_salary(allowances: -1)),
        contains('Allowances cannot be negative.'),
      );
      expect(
        validateSalaryRecord(_salary(month: '2026-13')),
        contains('Month must look like YYYY-MM (e.g. 2026-11).'),
      );
      expect(
        validateSalaryRecord(_salary(month: 'Nov 2026')),
        contains('Month must look like YYYY-MM (e.g. 2026-11).'),
      );
      expect(
        validateSalaryRecord(
          _salary(base: 100000, allowances: 0, deductions: 200000),
        ),
        contains(
          'Net salary cannot be negative — deductions exceed pay.',
        ),
      );
    });

    test('canViewSalary follows the hrSalary matrix', () {
      expect(canViewSalary(_userFor('owner'), _dha), true);
      expect(canViewSalary(_userFor('ho_admin'), _dha), true);
      expect(canViewSalary(_userFor('accountant'), _dha), true);
      // Auditor is read-only: may view, never change.
      expect(canViewSalary(_userFor('auditor'), _dha), true);
      expect(canManageSalary(_userFor('auditor'), _dha), false);
      expect(canViewSalary(_userFor('branch_manager'), _dha), false);
      expect(canViewSalary(_userFor('pharmacist'), _dha), false);
      expect(canViewSalary(_userFor('cashier'), _dha), false);
      expect(canViewSalary(_userFor('inventory_manager'), _dha), false);
      expect(canViewSalary(null, _dha), true);
      expect(canManageSalary(_userFor('owner'), _dha), true);
      expect(canManageSalary(_userFor('branch_manager'), _dha), false);
    });

    test('salaryRowsFor: active staff only, branch-scoped, sorted', () {
      final staff = demoStaff;
      final records = demoSalaryRecords();
      final month = salaryMonthKey(DateTime.now());
      final rows = salaryRowsFor(
        staff: staff,
        records: records,
        month: month,
        branchId: _dha,
      );
      // 7 active DHA staff, sorted by name; all have a record.
      expect(rows.length, 7);
      expect(rows.map((r) => r.employee.name).toList(), [
        'Ayesha Khan',
        'Bilal Aslam',
        'Fatima Noor',
        'Hassan Raza',
        'Kamran Sheikh',
        'Omar Siddiqui',
        'Sana Tariq',
      ]);
      expect(rows.every((r) => r.hasRecord), true);
      expect(rows.every((r) => r.isDemo), true);
      final totals = monthlySalaryTotals(rows);
      expect(totals.employeeCount, 7);
      expect(totals.recordedCount, 7);
      expect(totals.isComplete, true);
      expect(totals.baseMinor, 83500000);
      expect(totals.allowancesMinor, 3000000);
      expect(totals.deductionsMinor, 300000);
      expect(totals.netMinor, 86200000);

      // A month with no records: rows exist, totals are zero.
      final empty = salaryRowsFor(
        staff: staff,
        records: records,
        month: '2026-01',
        branchId: _dha,
      );
      expect(empty.every((r) => !r.hasRecord), true);
      final emptyTotals = monthlySalaryTotals(empty);
      expect(emptyTotals.recordedCount, 0);
      expect(emptyTotals.netMinor, 0);
      expect(emptyTotals.isComplete, false);

      // All branches: all 10 staff.
      final all = salaryRowsFor(
        staff: staff,
        records: records,
        month: month,
      );
      expect(all.length, 10);
      expect(monthlySalaryTotals(all).netMinor, 118550000);

      // Inactive staff never appear.
      final withInactive = salaryRowsFor(
        staff: [
          ...staff,
          const Staff(
            id: 'staff-off',
            name: 'Zed Off',
            email: 'zed@fazaldin-demo.pk',
            role: StaffRole.counter,
            branchId: _dha,
            active: false,
          ),
        ],
        records: records,
        month: month,
        branchId: _dha,
      );
      expect(withInactive.length, 7);
    });

    test('demoSalaryRecords: 10 demo records for the current month', () {
      final records = demoSalaryRecords();
      expect(records.length, 10);
      expect(records.every((r) => r.isDemo), true);
      expect(records.every((r) => r.month == salaryMonthKey(DateTime.now())), true);
      expect(
        records.map((r) => r.employeeId).toSet(),
        demoStaff.map((s) => s.id).toSet(),
      );
      for (final record in records) {
        expect(
          record.netMinor,
          record.baseSalaryMinor +
              record.allowancesMinor -
              record.deductionsMinor,
        );
        expect(validateSalaryRecord(record), isEmpty);
      }
    });
  });

  group('Salary repositories', () {
    test('mock: seeded demo records; save upserts by employee+month',
        () async {
      final repo = MockSalaryRepository();
      final month = salaryMonthKey(DateTime.now());
      expect((await repo.getSalaryRecords()).length, 10);
      expect((await repo.getSalaryRecords(branchId: _dha)).length, 7);
      expect((await repo.getSalaryRecords(month: month)).length, 10);
      expect((await repo.getSalaryRecords(month: '2026-01')).length, 0);

      // Re-save staff-1 for the same month: replaces, no duplicate.
      final saved = await repo.saveSalaryRecord(
        _salary(employeeId: 'staff-1', base: 26000000),
      );
      expect(saved.id, 'sal-staff-1-$month');
      expect((await repo.getSalaryRecords()).length, 10);
      expect((await repo.getById(saved.id))?.baseSalaryMinor, 26000000);

      // A new month is a new record.
      await repo.saveSalaryRecord(
        _salary(employeeId: 'staff-1', month: '2026-12', base: 26000000),
      );
      expect((await repo.getSalaryRecords()).length, 11);

      await expectLater(
        repo.saveSalaryRecord(_salary(base: -1)),
        throwsArgumentError,
      );
      await expectLater(
        repo.saveSalaryRecord(_salary(month: 'bad')),
        throwsArgumentError,
      );
    });

    test('firestore: mapper round-trip; save is idempotent by doc id',
        () async {
      final transport = FakeFirestoreTransport();
      await seedBranches(transport);
      final repo = FirestoreSalaryRepository(
        transport: transport,
        organizationId: _org,
      );
      final record = _salary();
      final doc = salaryRecordToFirestore(record, orgId: _org);
      expect(doc['netMinor'], 10500000);
      final restored = salaryRecordFromFirestore('sal-1', doc);
      expect(restored.netMinor, 10500000);
      expect(restored.month, '2026-11');

      final saved = await repo.saveSalaryRecord(record);
      expect(saved.id, 'sal-staff-1-2026-11');
      final again = await repo.saveSalaryRecord(
        _salary(base: 11000000),
      );
      expect(again.id, saved.id);
      expect(
        transport.countIn('branches/$_dha/salaries'),
        1,
      );
      expect((await repo.getById(saved.id))?.baseSalaryMinor, 11000000);
      expect((await repo.getSalaryRecords(month: '2026-11')).length, 1);
      expect((await repo.getSalaryRecords(month: '2026-12')).length, 0);
      await expectLater(
        repo.saveSalaryRecord(_salary(month: 'bad')),
        throwsArgumentError,
      );
    });
  });

  group('Salary storage decision (D102)', () {
    test('Staff model carries no salary field — mapper writes none', () {
      const member = Staff(
        id: 'staff-1',
        name: 'Ayesha Khan',
        email: 'ayesha@fazaldin-demo.pk',
        role: StaffRole.owner,
        branchId: _dha,
        phone: '0300-1112233',
        jobTitle: 'Owner',
        roleKey: 'owner',
      );
      expect(member.toMap().containsKey('salary'), false);
      expect(member.toMap().containsKey('salaryMinor'), false);
      final doc = staffToFirestore(member, orgId: _org);
      expect(doc.containsKey('salary'), false);
      expect(doc.containsKey('salaryMinor'), false);
    });

    test('salary figures come from the salary repo, not the directory',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final repo = container.read(salaryRepositoryProvider);
      final records = await repo.getSalaryRecords(
        branchId: _dha,
        month: salaryMonthKey(DateTime.now()),
      );
      final owner = records.firstWhere((r) => r.employeeId == 'staff-1');
      expect(owner.baseSalaryMinor, 25000000);
      expect(owner.isDemo, true);
      // …while the directory record for the same person has none.
      final staffRepo = container.read(staffRepositoryProvider);
      final member = (await staffRepo.getStaff()).firstWhere(
        (s) => s.id == 'staff-1',
      );
      expect(member.toMap().containsKey('salary'), false);
    });

    test('factory: mock bundle has both new repos; firestore kind too',
        () async {
      final mockBundle = createRepositoryBundle();
      expect(mockBundle.goodsReceipts, isA<MockGoodsReceiptRepository>());
      expect(mockBundle.salary, isA<MockSalaryRepository>());
      final transport = FakeFirestoreTransport();
      await seedBranches(transport);
      final firestoreBundle = createRepositoryBundle(
        kind: BackendKind.firestore,
        transport: transport,
      );
      expect(
        firestoreBundle.goodsReceipts,
        isA<FirestoreGoodsReceiptRepository>(),
      );
      expect(firestoreBundle.salary, isA<FirestoreSalaryRepository>());
      expect(
        () => createRepositoryBundle(kind: BackendKind.firestore),
        throwsStateError,
      );
    });
  });

  group('Salary screen widgets', () {
    testWidgets('owner sees rows, demo banner and monthly totals',
        (WidgetTester tester) async {
      final (container, router) = await pumpRouterApp(tester);
      await container
          .read(authProvider.notifier)
          .signInAsDemo(DemoRole.owner);
      await tester.pumpAndSettle();
      router.go('/staff/salary');
      await tester.pumpAndSettle();

      expect(find.text('Salary'), findsWidgets);
      // Demo figures are labelled as demo/sample.
      expect(find.textContaining('Demo data'), findsOneWidget);
      expect(find.textContaining('fictional sample figures'), findsOneWidget);
      // DHA rows (the active branch for the owner demo).
      expect(find.text('Ayesha Khan'), findsOneWidget);
      expect(find.text('Hassan Raza'), findsOneWidget);
      expect(find.text('Rs 250,000.00'), findsOneWidget);
      // Monthly totals for the DHA branch.
      expect(find.textContaining('Monthly total'), findsOneWidget);
      expect(find.text('Rs 86,200.00'), findsNothing);
      expect(find.text('Rs 862,000.00'), findsOneWidget);
      expect(find.text('7 of 7 staff have a record for this month.'),
          findsOneWidget);
      // The demo badge marks each seeded row.
      expect(find.text('Demo'), findsWidgets);
    });

    testWidgets('branch manager is stopped by the route gate',
        (WidgetTester tester) async {
      final (container, router) = await pumpRouterApp(tester);
      await container
          .read(authProvider.notifier)
          .signInAsDemo(DemoRole.branchManager);
      await tester.pumpAndSettle();
      router.go('/staff/salary');
      await tester.pumpAndSettle();

      expect(find.text('No permission for Staff & HR'), findsOneWidget);
      expect(find.text('Ayesha Khan'), findsNothing);
      expect(find.textContaining('Rs 862,000.00'), findsNothing);
    });

    testWidgets('previous month shows the empty state, next is disabled',
        (WidgetTester tester) async {
      final (container, router) = await pumpRouterApp(tester);
      await container
          .read(authProvider.notifier)
          .signInAsDemo(DemoRole.owner);
      await tester.pumpAndSettle();
      router.go('/staff/salary');
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Previous month'));
      await tester.pumpAndSettle();
      final previousLabel = salaryMonthLabel(
        previousSalaryMonth(salaryMonthKey(DateTime.now())),
      );
      expect(
        find.text('No salary records for $previousLabel yet.'),
        findsOneWidget,
      );
      // Back to the current month: the rows return.
      await tester.tap(find.byTooltip('Next month'));
      await tester.pumpAndSettle();
      expect(find.text('Ayesha Khan'), findsOneWidget);
    });

    testWidgets('Salary entry shows for owner, not for branch manager',
        (WidgetTester tester) async {
      final (container, router) = await pumpRouterApp(tester);
      await container
          .read(authProvider.notifier)
          .signInAsDemo(DemoRole.owner);
      await tester.pumpAndSettle();
      router.go('/staff');
      await tester.pumpAndSettle();
      // Directory chip + sidebar sub-item (desktop width).
      expect(find.text('Salary'), findsWidgets);

      await container.read(authProvider.notifier).signOut();
      await tester.pumpAndSettle();
      await container
          .read(authProvider.notifier)
          .signInAsDemo(DemoRole.branchManager);
      await tester.pumpAndSettle();
      router.go('/staff');
      await tester.pumpAndSettle();
      expect(find.text('Salary'), findsNothing);
    });
  });
}
