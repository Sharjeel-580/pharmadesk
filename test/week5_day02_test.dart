// Week 5 Day 2 tests — data-layer completion, part 2 (D148, D149, D150).
//
// - D148 (closes the D131 follow-up): the branch directory reads and
//   writes through a real `BranchRepository` (mock + Firestore) via
//   the production data layer — the notifier is no longer an
//   in-memory list seeded from the demo branches.
// - D149 (FR-HO-08): a deactivated branch cannot transact — the
//   production data layer refuses the write at every transaction
//   write path (sale, order, goods receiving, stock receive /
//   adjust / count, quarantine, transfer request / dispatch /
//   receive), with an `ArgumentError` the notifiers already surface.
// - D150 (closes the D133 follow-up): restore upserts by id into the
//   LIVE repositories — a validated restore overwrites a changed
//   record and inserts a new one, per entity, with the report
//   counting against the live repos.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharmadesk/core/data/audit_log.dart';
import 'package:pharmadesk/core/data/backup_export.dart';
import 'package:pharmadesk/core/data/firestore_mappers.dart';
import 'package:pharmadesk/core/data/firestore_repositories.dart';
import 'package:pharmadesk/core/data/firestore_schema.dart';
import 'package:pharmadesk/core/data/firestore_transport.dart';
import 'package:pharmadesk/core/data/inventory_engine.dart';
import 'package:pharmadesk/core/data/production_data_layer.dart';
import 'package:pharmadesk/core/data/sync_queue.dart';
import 'package:pharmadesk/core/services/repositories.dart';
import 'package:pharmadesk/features/branches/branch_directory.dart';
import 'package:pharmadesk/features/branches/branch_list_screen.dart';
import 'package:pharmadesk/features/orders/orders_provider.dart';
import 'package:pharmadesk/features/purchases/purchases_logic.dart';
import 'package:pharmadesk/models/branch.dart';
import 'package:pharmadesk/models/inventory_item.dart';
import 'package:pharmadesk/models/order.dart';
import 'package:pharmadesk/models/purchase_order.dart';
import 'package:pharmadesk/models/sale.dart';
import 'package:pharmadesk/models/stock_transfer.dart';

const _dha = 'branch-dha-main';
const _glb = 'branch-demo-gulberg';
const _org = demoOrganizationId;
const _panadol = 'med-panadol-extra';

/// Production layer over fresh mocks, with the branch repo exposed
/// so tests can deactivate a branch and watch the guard refuse.
class _Harness {
  _Harness({MockBranchRepository? branchRepo})
    : branchRepo = branchRepo ?? MockBranchRepository(),
      inventoryRepo = MockInventoryRepository(),
      saleRepo = MockSaleRepository(),
      orderRepo = MockOrderRepository(),
      customerRepo = MockCustomerRepository(),
      medicineRepo = MockMedicineRepository(),
      supplierRepo = MockSupplierRepository(),
      prescriptionRepo = MockPrescriptionRepository(),
      purchaseOrderRepo = MockPurchaseOrderRepository(),
      riderRepo = MockRiderRepository(),
      stockTransferRepo = MockStockTransferRepository(),
      goodsReceiptRepo = MockGoodsReceiptRepository(),
      audit = InMemoryAuditLogWriter() {
    layer = ProductionDataLayer(
      organizationId: _org,
      inventoryRepo: inventoryRepo,
      saleRepo: saleRepo,
      orderRepo: orderRepo,
      customerRepo: customerRepo,
      medicineRepo: medicineRepo,
      supplierRepo: supplierRepo,
      prescriptionRepo: prescriptionRepo,
      purchaseOrderRepo: purchaseOrderRepo,
      riderRepo: riderRepo,
      stockTransferRepo: stockTransferRepo,
      goodsReceiptRepo: goodsReceiptRepo,
      branchRepo: this.branchRepo,
      audit: audit,
      syncQueue: SyncQueue(InMemorySyncStore()),
      engine: InventoryEngine(organizationId: _org, audit: audit),
    );
  }

  final MockBranchRepository branchRepo;
  final MockInventoryRepository inventoryRepo;
  final MockSaleRepository saleRepo;
  final MockOrderRepository orderRepo;
  final MockCustomerRepository customerRepo;
  final MockMedicineRepository medicineRepo;
  final MockSupplierRepository supplierRepo;
  final MockPrescriptionRepository prescriptionRepo;
  final MockPurchaseOrderRepository purchaseOrderRepo;
  final MockRiderRepository riderRepo;
  final MockStockTransferRepository stockTransferRepo;
  final MockGoodsReceiptRepository goodsReceiptRepo;
  final InMemoryAuditLogWriter audit;
  late final ProductionDataLayer layer;
}

Future<void> _deactivate(_Harness h, String branchId) async {
  final branch = await h.branchRepo.getById(branchId);
  await h.branchRepo.updateBranch(branch!.copyWith(active: false));
}

Future<void> _reactivate(_Harness h, String branchId) async {
  final branch = await h.branchRepo.getById(branchId);
  await h.branchRepo.updateBranch(branch!.copyWith(active: true));
}

Sale _sale({
  required String key,
  required String medicineId,
  required String batchId,
  String branchId = _dha,
  int qty = 2,
  int unitPriceMinor = 10000,
}) {
  return Sale(
    id: '',
    invoiceNumber: '',
    branchId: branchId,
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

PurchaseOrderItem _poItem({
  String medicineId = _panadol,
  String medicineName = 'Panadol Extra',
  int quantityOrdered = 10,
  int unitCostMinor = 10000,
}) => PurchaseOrderItem(
  medicineId: medicineId,
  medicineName: medicineName,
  quantityOrdered: quantityOrdered,
  unitCostMinor: unitCostMinor,
);

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

/// Minimal in-memory [FirestoreTransport] for the Firestore branch
/// repository test: only the calls that repository makes
/// (`queryCollection` for the branch list, `getDocument` /
/// `setDocument`, `newDocumentId`); the rest throw, because the repo
/// never calls them (no counters, no transactions, no batched
/// writes). The `branches` collection sorts by the `orderBy` field
/// when one is given, like Firestore.
class _MemoryTransport implements FirestoreTransport {
  final Map<String, Map<String, dynamic>> _docs = {};
  var _sequence = 0;

  @override
  Future<Map<String, dynamic>?> getDocument(String path) async =>
      _docs[path] == null
          ? null
          : Map<String, dynamic>.from(_docs[path]!);

  @override
  Future<List<FirestoreDocument>> queryCollection(
    String collectionPath, {
    Map<String, Object?> whereEquals = const {},
    String? orderBy,
    bool descending = false,
    int? limit,
    String? startAfterId,
  }) async {
    final prefix = '$collectionPath/';
    final docs = [
      for (final entry in _docs.entries)
        if (entry.key.startsWith(prefix) &&
            !entry.key.substring(prefix.length).contains('/'))
          FirestoreDocument(
            id: entry.key.substring(prefix.length),
            data: Map<String, dynamic>.from(entry.value),
          ),
    ];
    for (final filter in whereEquals.entries) {
      docs.retainWhere((doc) => doc.data[filter.key] == filter.value);
    }
    if (orderBy != null) {
      docs.sort(
        (a, b) => (a.data[orderBy]?.toString() ?? '').compareTo(
          b.data[orderBy]?.toString() ?? '',
        ),
      );
    } else {
      docs.sort((a, b) => a.id.compareTo(b.id));
    }
    if (descending) return docs.reversed.toList();
    var page = docs;
    if (startAfterId != null) {
      final index = page.indexWhere((doc) => doc.id == startAfterId);
      if (index != -1) page = page.sublist(index + 1);
    }
    if (limit != null && page.length > limit) {
      page = page.sublist(0, limit);
    }
    return page;
  }

  @override
  Future<void> setDocument(
    String path,
    Map<String, dynamic> data, {
    bool merge = false,
  }) async {
    _docs[path] = Map<String, dynamic>.from(data);
  }

  @override
  String newDocumentId(String collectionPath) {
    _sequence++;
    return 'auto-$_sequence';
  }

  @override
  Future<void> updateDocument(String path, Map<String, dynamic> data) =>
      throw UnimplementedError();

  @override
  Future<String> addDocument(
    String collectionPath,
    Map<String, dynamic> data,
  ) => throw UnimplementedError();

  @override
  Future<void> runBatchedWrites(List<WriteOperation> operations) =>
      throw UnimplementedError();

  @override
  Future<T> runTransaction<T>(
    Future<T> Function(FirestoreTransaction tx) update,
  ) => throw UnimplementedError();
}

void main() {
  group('Branch repository — mock (D148)', () {
    test('seeds from the two demo branches', () async {
      final repo = MockBranchRepository();
      final branches = await repo.getBranches();
      expect(branches.length, 2);
      expect(
        branches.map((b) => b.id),
        containsAll([_dha, _glb]),
      );
      expect(await repo.getById('branch-nope'), isNull);
    });

    test('createBranch adds with the given id; a duplicate id throws',
        () async {
      final repo = MockBranchRepository();
      final created = await repo.createBranch(
        const Branch(
          id: 'branch-model-town',
          name: 'Demo Branch — Model Town',
          address: 'Model Town, Lahore',
          phone: '0300-3333333',
        ),
      );
      expect(created.id, 'branch-model-town');
      expect((await repo.getBranches()).length, 3);
      await expectLater(
        repo.createBranch(
          const Branch(id: _dha, name: 'Copy', address: '', phone: ''),
        ),
        throwsArgumentError,
      );
    });

    test('createBranch with an empty id mints branch-<slug>', () async {
      final repo = MockBranchRepository();
      final created = await repo.createBranch(
        const Branch(
          id: '',
          name: 'Model Town',
          address: '',
          phone: '',
        ),
      );
      expect(created.id, 'branch-model-town');
    });

    test('updateBranch replaces; a missing id throws', () async {
      final repo = MockBranchRepository();
      final branch = (await repo.getById(_dha))!;
      final updated = await repo.updateBranch(
        branch.copyWith(address: 'New address', phone: '0300-0000000'),
      );
      expect(updated.address, 'New address');
      expect((await repo.getById(_dha))!.phone, '0300-0000000');
      await expectLater(
        repo.updateBranch(
          const Branch(id: 'branch-nope', name: 'X', address: '', phone: ''),
        ),
        throwsArgumentError,
      );
    });

    test('saveBranch upserts: new id inserts, existing id replaces',
        () async {
      final repo = MockBranchRepository();
      final inserted = await repo.saveBranch(
        const Branch(
          id: 'branch-franchise-1',
          name: 'Franchise One',
          address: '',
          phone: '',
          type: 'franchise',
          franchiseFeeRateBps: 250,
          royaltyRateBps: 500,
        ),
      );
      expect(inserted.type, 'franchise');
      expect(inserted.franchiseFeeRateBps, 250);
      expect(inserted.royaltyRateBps, 500);
      expect((await repo.getBranches()).length, 3);
      final replaced = await repo.saveBranch(
        inserted.copyWith(
          franchiseFeeRateBps: 300,
          clearRoyaltyRateBps: true,
        ),
      );
      expect(replaced.franchiseFeeRateBps, 300);
      expect(replaced.royaltyRateBps, isNull);
      expect((await repo.getBranches()).length, 3);
      expect((await repo.getById('branch-franchise-1'))!.type, 'franchise');
    });

    test('a null rate stays null — never an invented 0%', () async {
      final repo = MockBranchRepository();
      final branch = (await repo.getById(_dha))!;
      expect(branch.franchiseFeeRateBps, isNull);
      expect(branch.royaltyRateBps, isNull);
      expect(branchRateLabel(branch.franchiseFeeRateBps), 'Not set');
    });
  });

  group('Branch repository — Firestore mapper + repo (D148)', () {
    test('mapper round-trips every field, including the rates', () {
      const branch = Branch(
        id: 'branch-x',
        name: 'Franchise X',
        address: 'Somewhere',
        phone: '0300-1',
        deliveryAreas: ['Area 1', 'Area 2'],
        active: false,
        type: 'franchise',
        managerId: 'staff-1',
        franchiseFeeRateBps: 250,
        royaltyRateBps: 500,
      );
      final doc = branchToFirestore(branch, orgId: _org);
      expect(doc['organizationId'], _org);
      expect(doc['status'], 'closed');
      final back = branchFromFirestore('branch-x', doc);
      expect(back.name, 'Franchise X');
      expect(back.active, isFalse);
      expect(back.type, 'franchise');
      expect(back.managerId, 'staff-1');
      expect(back.deliveryAreas, ['Area 1', 'Area 2']);
      expect(back.franchiseFeeRateBps, 250);
      expect(back.royaltyRateBps, 500);
    });

    test('mapper reads a closed status and the §3 rate names', () {
      final back = branchFromFirestore('branch-y', {
        'name': 'Legacy',
        'type': 'franchise',
        'status': 'closed',
        'franchiseFeeRate': 100,
        'royaltyRate': 200,
      });
      expect(back.active, isFalse);
      expect(back.franchiseFeeRateBps, 100);
      expect(back.royaltyRateBps, 200);
    });

    test('Firestore repo round-trips over the memory transport', () async {
      final repo = FirestoreBranchRepository(
        transport: _MemoryTransport(),
        organizationId: _org,
      );
      expect(await repo.getBranches(), isEmpty);
      final created = await repo.createBranch(
        const Branch(
          id: 'branch-z',
          name: 'Zulu Branch',
          address: 'Zulu Street',
          phone: '0300-9',
          type: 'franchise',
          franchiseFeeRateBps: 150,
        ),
      );
      expect(created.id, 'branch-z');
      expect(created.franchiseFeeRateBps, 150);
      final read = await repo.getById('branch-z');
      expect(read!.name, 'Zulu Branch');
      expect(read.franchiseFeeRateBps, 150);
      await repo.updateBranch(read.copyWith(active: false));
      expect((await repo.getById('branch-z'))!.active, isFalse);
      await expectLater(
        repo.createBranch(
          const Branch(id: 'branch-z', name: 'Copy', address: '', phone: ''),
        ),
        throwsArgumentError,
      );
      final saved = await repo.saveBranch(
        const Branch(
          id: 'branch-z',
          name: 'Zulu Branch',
          address: 'Moved',
          phone: '0300-9',
          active: true,
        ),
      );
      expect(saved.address, 'Moved');
      expect(saved.active, isTrue);
      expect((await repo.getBranches()).length, 1);
    });

    test('Firestore repo lists branches in name order', () async {
      final repo = FirestoreBranchRepository(
        transport: _MemoryTransport(),
        organizationId: _org,
      );
      await repo.createBranch(
        const Branch(id: 'branch-b', name: 'Beta', address: '', phone: ''),
      );
      await repo.createBranch(
        const Branch(id: 'branch-a', name: 'Alpha', address: '', phone: ''),
      );
      final names = (await repo.getBranches()).map((b) => b.name).toList();
      expect(names, ['Alpha', 'Beta']);
    });
  });

  group('Branch directory notifier (D148)', () {
    test('seeds from the two demo branches; add keeps order', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(branchDirectoryProvider.notifier);
      expect(container.read(branchDirectoryProvider).length, 2);
      final errors = await notifier.addBranch(
        const Branch(
          id: 'branch-model-town',
          name: 'Demo Branch — Model Town',
          address: 'Model Town, Lahore',
          phone: '0300-3333333',
        ),
      );
      expect(errors, isEmpty);
      final branches = container.read(branchDirectoryProvider);
      expect(branches.length, 3);
      expect(branches.last.id, 'branch-model-town');
      expect(notifier.byId('branch-model-town')!.name,
          'Demo Branch — Model Town');
    });

    test('add persists across a notifier rebuild', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(branchDirectoryProvider.notifier);
      await notifier.addBranch(
        const Branch(
          id: 'branch-model-town',
          name: 'Demo Branch — Model Town',
          address: 'Model Town, Lahore',
          phone: '0300-3333333',
        ),
      );
      container.invalidate(branchDirectoryProvider);
      // The rebuild starts from the demo seeds; the refresh re-reads
      // the persisted directory.
      await container.read(branchDirectoryProvider.notifier).refresh();
      expect(container.read(branchDirectoryProvider).length, 3);
      expect(
        container
            .read(branchDirectoryProvider)
            .map((b) => b.id),
        contains('branch-model-town'),
      );
    });

    test('deactivation persists across a rebuild; last-active protected',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(branchDirectoryProvider.notifier);
      expect(await notifier.setActive(_glb, false), isEmpty);
      container.invalidate(branchDirectoryProvider);
      await container.read(branchDirectoryProvider.notifier).refresh();
      expect(notifier.byId(_glb)!.active, isFalse);
      final errors = await notifier.setActive(_dha, false);
      expect(
        errors,
        contains('The last active branch cannot be deactivated.'),
      );
      expect(notifier.byId(_dha)!.active, isTrue);
    });

    testWidgets('branch list pages at 10 (D107 regression)',
        (WidgetTester tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(branchDirectoryProvider.notifier);
      for (var i = 1; i <= 9; i++) {
        await notifier.addBranch(
          Branch(
            id: 'branch-extra-$i',
            name: 'Extra Branch $i',
            address: 'Lahore',
            phone: '0300-000000$i',
          ),
        );
      }
      expect(container.read(branchDirectoryProvider).length, 11);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: BranchListScreen()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Page 1 of 2'), findsOneWidget);
      expect(find.text('Extra Branch 8'), findsOneWidget);
      expect(find.text('Extra Branch 9'), findsNothing);
      // The pager sits below ten branch cards, so it starts
      // off-screen in the test viewport — scroll it into view first.
      await tester.ensureVisible(find.byKey(const ValueKey('page-next')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('page-next')));
      await tester.pumpAndSettle();
      expect(find.text('Page 2 of 2'), findsOneWidget);
      expect(find.text('Extra Branch 9'), findsOneWidget);
      expect(find.text('Demo Branch — DHA'), findsNothing);
    });
  });

  group('FR-HO-08 deactivation enforcement (D149)', () {
    test('commitSale refused on a deactivated branch; stock untouched',
        () async {
      final h = _Harness();
      final batches = await h.inventoryRepo.getInventory(branchId: _dha);
      final batch = batches.firstWhere((item) => item.quantity >= 2);
      final beforeQty = batch.quantity;
      final beforeSales = (await h.saleRepo.getSales(branchId: _dha)).length;
      await _deactivate(h, _dha);
      await expectLater(
        h.layer.commitSale(
          sale: _sale(
            key: 'sale-d149-1',
            medicineId: batch.medicineId,
            batchId: batch.id,
          ),
          decrements: [(batchId: batch.id, quantity: 1)],
        ),
        throwsArgumentError,
      );
      expect(
        (await h.inventoryRepo.getInventory(branchId: _dha))
            .firstWhere((item) => item.id == batch.id)
            .quantity,
        beforeQty,
      );
      expect(
        (await h.saleRepo.getSales(branchId: _dha)).length,
        beforeSales,
      );
      // The active branch is unaffected.
      await _reactivate(h, _dha);
      final ok = await h.layer.commitSale(
        sale: _sale(
          key: 'sale-d149-1',
          medicineId: batch.medicineId,
          batchId: batch.id,
        ),
        decrements: [(batchId: batch.id, quantity: 1)],
      );
      expect(ok.isDuplicate, isFalse);
      expect(
        (await h.saleRepo.getSales(branchId: _dha)).length,
        beforeSales + 1,
      );
    });

    test('a duplicate retry after deactivation still returns the original',
        () async {
      final h = _Harness();
      final batches = await h.inventoryRepo.getInventory(branchId: _dha);
      final batch = batches.firstWhere((item) => item.quantity >= 2);
      final first = await h.layer.commitSale(
        sale: _sale(
          key: 'sale-d149-dupe',
          medicineId: batch.medicineId,
          batchId: batch.id,
        ),
        decrements: [(batchId: batch.id, quantity: 1)],
      );
      expect(first.isDuplicate, isFalse);
      await _deactivate(h, _dha);
      // The guard sits after the idempotency check: a retried key is
      // not a new transaction, so it returns the original sale
      // instead of an error.
      final retry = await h.layer.commitSale(
        sale: _sale(
          key: 'sale-d149-dupe',
          medicineId: batch.medicineId,
          batchId: batch.id,
        ),
        decrements: [(batchId: batch.id, quantity: 1)],
      );
      expect(retry.isDuplicate, isTrue);
      expect(retry.sale.id, first.sale.id);
      expect((await h.saleRepo.getSales(branchId: _dha)).length, 1);
    });

    test('createOrder refused on a deactivated branch', () async {
      final h = _Harness();
      await _deactivate(h, _dha);
      final before = (await h.orderRepo.getOrders(branchId: _dha)).length;
      await expectLater(
        h.layer.createOrder(
          order: buildNewOrder(
            branchId: _dha,
            items: [
              OrderItem(
                medicineId: _panadol,
                medicineName: 'Panadol Extra',
                quantity: 1,
                unitPrice: 100,
              ),
            ],
            source: OrderSource.phone,
            fulfillment: FulfillmentType.delivery,
          ),
          idempotencyKey: 'order-d149-1',
        ),
        throwsArgumentError,
      );
      expect((await h.orderRepo.getOrders(branchId: _dha)).length, before);
      await _reactivate(h, _dha);
      final ok = await h.layer.createOrder(
        order: buildNewOrder(
          branchId: _dha,
          items: [
            OrderItem(
              medicineId: _panadol,
              medicineName: 'Panadol Extra',
              quantity: 1,
              unitPrice: 100,
            ),
          ],
          source: OrderSource.phone,
          fulfillment: FulfillmentType.delivery,
        ),
        idempotencyKey: 'order-d149-1',
      );
      expect(ok.isDuplicate, isFalse);
    });

    test('receiveGoods refused on a deactivated branch', () async {
      final h = _Harness();
      final po = await _approvedPo(h.purchaseOrderRepo);
      await _deactivate(h, _dha);
      final beforeQty = (await h.inventoryRepo.getInventory(branchId: _dha))
          .where((i) => i.medicineId == _panadol)
          .fold(0, (acc, i) => acc + i.quantity);
      await expectLater(
        h.layer.receiveGoods(
          order: po,
          lines: [
            ReceivingLine(
              item: po.items.first,
              quantityReceivedNow: 2,
              batchNo: 'B-D149',
              mfgDate: DateTime(2026, 1, 1),
              expiryDate: DateTime(2027, 1, 1),
            ),
          ],
          idempotencyKey: 'receipt-d149-1',
        ),
        throwsArgumentError,
      );
      expect(
        (await h.goodsReceiptRepo.getGoodsReceipts()).length,
        0,
      );
      expect(
        (await h.inventoryRepo.getInventory(branchId: _dha))
            .where((i) => i.medicineId == _panadol)
            .fold(0, (acc, i) => acc + i.quantity),
        beforeQty,
      );
      await _reactivate(h, _dha);
      final ok = await h.layer.receiveGoods(
        order: po,
        lines: [
          ReceivingLine(
            item: po.items.first,
            quantityReceivedNow: 2,
            batchNo: 'B-D149',
            mfgDate: DateTime(2026, 1, 1),
            expiryDate: DateTime(2027, 1, 1),
          ),
        ],
        idempotencyKey: 'receipt-d149-1',
      );
      expect(ok.isDuplicate, isFalse);
    });

    test('receiveStock / adjustStock / recordStockCount refused', () async {
      final h = _Harness();
      final batches = await h.inventoryRepo.getInventory(branchId: _dha);
      final batch = batches.firstWhere((item) => item.quantity >= 2);
      final beforeQty = batch.quantity;
      await _deactivate(h, _dha);
      await expectLater(
        h.layer.receiveStock(
          branchId: _dha,
          medicineId: _panadol,
          batchNo: 'B-D149-R',
          mfgDate: DateTime(2026, 1, 1),
          expiryDate: DateTime(2027, 1, 1),
          quantity: 5,
          costMinor: 10000,
          idempotencyKey: 'stock-receive-d149-1',
        ),
        throwsArgumentError,
      );
      await expectLater(
        h.layer.adjustStock(
          batchId: batch.id,
          deltaQty: -1,
          reason: 'Damaged',
          idempotencyKey: 'stock-adjust-d149-1',
        ),
        throwsArgumentError,
      );
      await expectLater(
        h.layer.recordStockCount(
          batchId: batch.id,
          countedQty: beforeQty + 1,
          idempotencyKey: 'stock-count-d149-1',
        ),
        throwsArgumentError,
      );
      expect(
        (await h.inventoryRepo.getInventory(branchId: _dha))
            .firstWhere((item) => item.id == batch.id)
            .quantity,
        beforeQty,
      );
      // The active branch still adjusts.
      await _reactivate(h, _dha);
      await h.layer.adjustStock(
        batchId: batch.id,
        deltaQty: -1,
        reason: 'Damaged',
        idempotencyKey: 'stock-adjust-d149-1',
      );
      expect(
        (await h.inventoryRepo.getInventory(branchId: _dha))
            .firstWhere((item) => item.id == batch.id)
            .quantity,
        beforeQty - 1,
      );
    });

    test('quarantine refused on a deactivated branch', () async {
      final h = _Harness();
      final batches = await h.inventoryRepo.getInventory(branchId: _dha);
      final batch = batches.firstWhere(
        (item) => item.status == BatchStatus.available,
      );
      await _deactivate(h, _dha);
      await expectLater(
        h.layer.quarantineBatch(
          batchId: batch.id,
          reason: 'Suspect',
          idempotencyKey: 'batch-status-d149-1',
        ),
        throwsArgumentError,
      );
      expect(
        (await h.inventoryRepo.getInventory(branchId: _dha))
            .firstWhere((item) => item.id == batch.id)
            .status,
        BatchStatus.available,
      );
    });

    test('transfer request refused when either end is deactivated',
        () async {
      final h = _Harness();
      // The mock transfer repo is seeded (demo transfers) — the
      // refused requests must add none.
      final before = (await h.stockTransferRepo.getTransfers()).length;
      await _deactivate(h, _dha);
      await expectLater(
        h.layer.createTransfer(
          fromBranchId: _dha,
          toBranchId: _glb,
          items: const [
            TransferItem(
              medicineId: _panadol,
              medicineName: 'Panadol Extra',
              quantity: 5,
            ),
          ],
          idempotencyKey: 'transfer-d149-1',
        ),
        throwsArgumentError,
      );
      await _reactivate(h, _dha);
      await _deactivate(h, _glb);
      await expectLater(
        h.layer.createTransfer(
          fromBranchId: _dha,
          toBranchId: _glb,
          items: const [
            TransferItem(
              medicineId: _panadol,
              medicineName: 'Panadol Extra',
              quantity: 5,
            ),
          ],
          idempotencyKey: 'transfer-d149-2',
        ),
        throwsArgumentError,
      );
      expect((await h.stockTransferRepo.getTransfers()).length, before);
      await _reactivate(h, _glb);
      final ok = await h.layer.createTransfer(
        fromBranchId: _dha,
        toBranchId: _glb,
        items: const [
          TransferItem(
            medicineId: _panadol,
            medicineName: 'Panadol Extra',
            quantity: 5,
          ),
        ],
        idempotencyKey: 'transfer-d149-3',
      );
      expect(ok.isDuplicate, isFalse);
      expect(ok.transfer.status, StockTransferStatus.requested);
    });

    test('dispatch refused from a deactivated source; receive refused '
        'into a deactivated destination', () async {
      final h = _Harness();
      final created = await h.layer.createTransfer(
        fromBranchId: _dha,
        toBranchId: _glb,
        items: const [
          TransferItem(
            medicineId: _panadol,
            medicineName: 'Panadol Extra',
            quantity: 5,
          ),
        ],
        idempotencyKey: 'transfer-d149-flow',
      );
      final approved = await h.layer.approveTransfer(
        created.transfer.id,
        actorId: 'demo-branch_manager',
        actorName: 'Branch Manager',
      );
      expect(approved.status, StockTransferStatus.approved);
      await _deactivate(h, _dha);
      await expectLater(
        h.layer.dispatchTransfer(
          transferId: created.transfer.id,
          idempotencyKey: 'dispatch-d149-1',
        ),
        throwsArgumentError,
      );
      await _reactivate(h, _dha);
      final dispatched = await h.layer.dispatchTransfer(
        transferId: created.transfer.id,
        idempotencyKey: 'dispatch-d149-1',
      );
      expect(dispatched.transfer.status, StockTransferStatus.dispatched);
      await _deactivate(h, _glb);
      await expectLater(
        h.layer.receiveTransfer(
          transferId: created.transfer.id,
          idempotencyKey: 'receive-d149-1',
        ),
        throwsArgumentError,
      );
      await _reactivate(h, _glb);
      final received = await h.layer.receiveTransfer(
        transferId: created.transfer.id,
        idempotencyKey: 'receive-d149-1',
      );
      expect(received.transfer.status, StockTransferStatus.received);
    });

    test('an unknown branch id is not refused (D149 boundary)', () async {
      final h = _Harness();
      // The directory is the source of truth for deactivation; an id
      // it never saw cannot be known-deactivated, so the write goes
      // through exactly as before.
      final result = await h.layer.receiveStock(
        branchId: 'branch-unknown',
        medicineId: _panadol,
        batchNo: 'B-D149-U',
        mfgDate: DateTime(2026, 1, 1),
        expiryDate: DateTime(2027, 1, 1),
        quantity: 3,
        costMinor: 10000,
        idempotencyKey: 'stock-receive-d149-unknown',
      );
      expect(result.isDuplicate, isFalse);
      expect(result.batch.branchId, 'branch-unknown');
    });
  });

  group('Restore upsert-by-id into the live repos (D150)', () {
    test('restore overwrites a changed medicine (overwrite policy)',
        () async {
      final h = _Harness();
      final doc = await h.layer.exportBackup();
      final total = (doc['sections'] as Map<String, dynamic>).values.fold(
        0,
        (sum, list) => sum + (list as List).length,
      );
      expect(total, greaterThan(0));
      final original = (await h.medicineRepo.getById(_panadol))!;
      await h.medicineRepo.updateMedicine(
        original.copyWith(name: 'Changed Name'),
      );
      expect((await h.medicineRepo.getById(_panadol))!.name, 'Changed Name');
      final report = await h.layer.importBackup(
        doc,
        policy: ImportPolicy.overwrite,
      );
      expect(report.success, isTrue);
      expect(report.created, 0);
      expect(report.overwritten, total);
      expect((await h.medicineRepo.getById(_panadol))!.name, original.name);
    });

    test('restore leaves a changed record alone under skip policy',
        () async {
      final h = _Harness();
      final doc = await h.layer.exportBackup();
      final original = (await h.medicineRepo.getById(_panadol))!;
      await h.medicineRepo.updateMedicine(
        original.copyWith(name: 'Changed Name'),
      );
      final report = await h.layer.importBackup(doc);
      expect(report.success, isTrue);
      expect(report.created, 0);
      expect(report.skipped, greaterThan(0));
      expect((await h.medicineRepo.getById(_panadol))!.name, 'Changed Name');
      // Tidy the shared catalogue for the other tests in this file.
      await h.medicineRepo.updateMedicine(original);
    });

    test('restore adds a new medicine and a new sale (either policy)',
        () async {
      final h = _Harness();
      final backup = {
        'format': BackupFormat.format,
        'formatVersion': BackupFormat.currentVersion,
        'organizationId': _org,
        'exportedAt': DateTime.now().toIso8601String(),
        'sections': {
          'medicines': [
            {
              'id': 'med-restore-new-1',
              'name': 'Restored Medicine',
              'brand': 'Test',
              'price': 5.0,
            },
          ],
          'sales': <Map<String, dynamic>>[],
        },
      };
      final report = await h.layer.importBackup(backup);
      expect(report.success, isTrue);
      expect(report.created, 1);
      expect(report.overwritten, 0);
      final restored = await h.medicineRepo.getById('med-restore-new-1');
      expect(restored!.name, 'Restored Medicine');
      expect(restored.price, 5.0);
    });

    test('restore overwrites a changed sale record', () async {
      final h = _Harness();
      final batches = await h.inventoryRepo.getInventory(branchId: _dha);
      final batch = batches.firstWhere((item) => item.quantity >= 2);
      final committed = await h.layer.commitSale(
        sale: _sale(
          key: 'sale-d150-1',
          medicineId: batch.medicineId,
          batchId: batch.id,
        ),
        decrements: [(batchId: batch.id, quantity: 1)],
      );
      final saleId = committed.sale.id;
      final doc = await h.layer.exportBackup();
      final sections = doc['sections'] as Map<String, dynamic>;
      final salesSection = sections['sales'] as List;
      final exportedSale = (salesSection.firstWhere(
        (s) => (s as Map<String, dynamic>)['id'] == saleId,
      ) as Map<String, dynamic>);
      final changedTotal = committed.sale.totalMinor + 100;
      exportedSale['totalMinor'] = changedTotal;
      final report = await h.layer.importBackup(
        doc,
        policy: ImportPolicy.overwrite,
      );
      expect(report.success, isTrue);
      expect(report.errors, isEmpty);
      // Week 7 Day 3 (D173): the restore re-keys the sale by its
      // idempotencyKey, so the changed sale comes back under the
      // key — not under the mock-assigned id it was committed
      // with. The mock upsert matches by key, so the committed
      // sale is REPLACED in place: no duplicate, and the report
      // counts it as overwritten, not created.
      expect(await h.saleRepo.getById(saleId), isNull);
      final restored = (await h.saleRepo.getById('sale-d150-1'))!;
      expect(restored.totalMinor, changedTotal);
      expect(restored.invoiceNumber, committed.sale.invoiceNumber);
      expect((await h.saleRepo.getSales()).length, 1);
    });

    test('restore upserts branches: a deactivated branch reactivates',
        () async {
      final h = _Harness();
      final doc = await h.layer.exportBackup();
      final sections = doc['sections'] as Map<String, dynamic>;
      expect((sections['branches'] as List).length, 2);
      await _deactivate(h, _glb);
      final report = await h.layer.importBackup(
        doc,
        policy: ImportPolicy.overwrite,
      );
      expect(report.success, isTrue);
      expect((await h.branchRepo.getById(_glb))!.active, isTrue);
    });

    test('validation still aborts before any write', () async {
      final h = _Harness();
      final before = (await h.medicineRepo.getMedicines()).length;
      final report = await h.layer.importBackup({
        'format': 'other',
        'formatVersion': 1,
      });
      expect(report.success, isFalse);
      expect(report.created, 0);
      expect((await h.medicineRepo.getMedicines()).length, before);
      expect(h.layer.restoredData.count('medicines'), 0);
    });

    test('a malformed doc is recorded and skipped; the rest import',
        () async {
      final h = _Harness();
      final backup = {
        'format': BackupFormat.format,
        'formatVersion': BackupFormat.currentVersion,
        'organizationId': _org,
        'sections': {
          'medicines': [
            {
              'id': 'med-restore-good-1',
              'name': 'Good Medicine',
              'price': 2.0,
            },
            {
              'id': 'med-restore-bad-1',
              'name': 'Bad Medicine',
              'price': 'not-a-number',
            },
          ],
        },
      };
      final report = await h.layer.importBackup(
        backup,
        policy: ImportPolicy.overwrite,
      );
      expect(report.success, isFalse);
      expect(report.errors, hasLength(1));
      expect(report.errors.first, contains('med-restore-bad-1'));
      expect(report.created, 1);
      expect(
        (await h.medicineRepo.getById('med-restore-good-1'))!.name,
        'Good Medicine',
      );
      expect(await h.medicineRepo.getById('med-restore-bad-1'), isNull);
    });

    test('auditLogs / syncQueue restore into the sink only', () async {
      final h = _Harness();
      final backup = {
        'format': BackupFormat.format,
        'formatVersion': BackupFormat.currentVersion,
        'organizationId': _org,
        'sections': {
          'auditLogs': [
            {'id': 'audit-restore-1', 'action': 'sale.committed'},
          ],
          'syncQueue': [
            {'id': 'sync-restore-1', 'entityType': 'sale'},
          ],
          'medicines': <Map<String, dynamic>>[],
        },
      };
      final report = await h.layer.importBackup(backup);
      expect(report.success, isTrue);
      expect(report.created, 2);
      expect(h.layer.restoredData.count('auditLogs'), 1);
      expect(h.layer.restoredData.count('syncQueue'), 1);
    });
  });
}
