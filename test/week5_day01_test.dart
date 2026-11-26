// Week 5 Day 1 tests — data-layer completion, part 1 (D146, D147).
//
// - D146 (closes the D141 follow-up): the adjustment approval queue
//   is persisted through the production data layer — collection
//   contract + repository (mock + Firestore) + layer file/load/
//   update + notifier re-read on start. Semantics preserved:
//   request → approve (approver ≠ requester, §5.2.4) / reject,
//   re-validation at approval time, request id as idempotency key.
// - D147 (closes the D145 follow-up): supplier payments move
//   through the production data layer — one layer method, one
//   batched-write sync payload per payment, same three records,
//   same ledger / aging / statement numbers as the old repo-direct
//   path (a wiring move, not a computation change).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharmadesk/core/data/audit_log.dart';
import 'package:pharmadesk/core/data/auth_repository.dart';
import 'package:pharmadesk/core/data/firestore_mappers.dart';
import 'package:pharmadesk/core/data/firestore_repositories.dart';
import 'package:pharmadesk/core/data/firestore_schema.dart';
import 'package:pharmadesk/core/data/firestore_transport.dart';
import 'package:pharmadesk/core/data/inventory_engine.dart';
import 'package:pharmadesk/core/data/production_data_layer.dart';
import 'package:pharmadesk/core/data/sync_queue.dart';
import 'package:pharmadesk/core/services/repositories.dart';
import 'package:pharmadesk/core/theme/app_theme.dart';
import 'package:pharmadesk/core/theme/white_label.dart';
import 'package:pharmadesk/features/authentication/auth_state.dart';
import 'package:pharmadesk/features/finance/finance_logic.dart';
import 'package:pharmadesk/features/finance/finance_provider.dart';
import 'package:pharmadesk/features/inventory/adjustment_queue_screen.dart';
import 'package:pharmadesk/features/inventory/stock_adjustment_queue.dart';
import 'package:pharmadesk/features/suppliers/supplier_logic.dart';
import 'package:pharmadesk/features/suppliers/suppliers_provider.dart';
import 'package:pharmadesk/models/financial_transaction.dart';
import 'package:pharmadesk/models/stock_adjustment_request.dart';
import 'package:pharmadesk/models/supplier_payment.dart';

const _dha = 'branch-dha-main';
const _org = demoOrganizationId;

AppUser _userFor(
  String roleKey, {
  List<String> branchIds = const [_dha],
  String? uid,
}) {
  return AppUser(
    uid: uid ?? 'test-$roleKey',
    email: '$roleKey@test.pharmadesk',
    displayName: 'Test $roleKey',
    orgId: _org,
    branchIds: branchIds,
    roleKey: roleKey,
  );
}

class _FixedAuthNotifier extends AuthNotifier {
  _FixedAuthNotifier(this.user);

  final AppUser user;

  @override
  AppUser? build() => user;
}

/// An auth notifier whose user can be swapped mid-test — the
/// approval queue needs two different users in one container (the
/// requester, then a different approver).
class _MutableAuthNotifier extends AuthNotifier {
  _MutableAuthNotifier(this._user);

  AppUser? _user;

  set user(AppUser? value) {
    _user = value;
    state = value;
  }

  @override
  AppUser? build() => _user;
}

/// Production layer over fresh mocks (same helper shape as the
/// Week 4 Day 5 layer tests). The [audit] writer is exposed so
/// tests can read the audit trail the layer writes.
ProductionDataLayer _layer({InMemoryAuditLogWriter? audit}) {
  final writer = audit ?? InMemoryAuditLogWriter();
  final queue = SyncQueue(InMemorySyncStore());
  final engine = InventoryEngine(organizationId: _org, audit: writer);
  return ProductionDataLayer(
    organizationId: _org,
    inventoryRepo: MockInventoryRepository(),
    saleRepo: MockSaleRepository(),
    orderRepo: MockOrderRepository(),
    customerRepo: MockCustomerRepository(),
    medicineRepo: MockMedicineRepository(),
    supplierRepo: MockSupplierRepository(),
    prescriptionRepo: MockPrescriptionRepository(),
    purchaseOrderRepo: MockPurchaseOrderRepository(),
    riderRepo: MockRiderRepository(),
    stockTransferRepo: MockStockTransferRepository(),
    audit: writer,
    syncQueue: queue,
    engine: engine,
  );
}

StockAdjustmentRequest _request({
  String id = 'adj-1',
  int deltaQty = -2,
}) {
  return StockAdjustmentRequest(
    id: id,
    batchId: 'batch-1',
    batchNo: 'B-1001',
    medicineId: 'med-panadol-extra',
    medicineName: 'Panadol Extra',
    branchId: _dha,
    deltaQty: deltaQty,
    reason: 'Damaged in transit',
    requesterId: 'test-owner',
    requesterName: 'Test owner',
    requestedAt: DateTime(2026, 11, 26, 10, 0),
  );
}

/// Minimal in-memory [FirestoreTransport] for the Firestore
/// adjustment-queue repository test: only the calls that repository
/// makes are implemented (`queryCollection` for the branch list +
/// the collection scan, `getDocument` / `setDocument`,
/// `newDocumentId`); the rest throw, because the repo never calls
/// them (no counters, no transactions, no batched writes).
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
    if (collectionPath == FirestoreSchema.branches) {
      return [
        FirestoreDocument(id: _dha, data: {'name': 'DHA Main'}),
      ];
    }
    final prefix = '$collectionPath/';
    final docs = [
      for (final entry in _docs.entries)
        if (entry.key.startsWith(prefix))
          FirestoreDocument(
            id: entry.key.substring(prefix.length),
            data: Map<String, dynamic>.from(entry.value),
          ),
    ];
    docs.sort((a, b) => a.id.compareTo(b.id));
    return docs;
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
    Future<T> Function(FirestoreTransaction tx) action,
  ) => throw UnimplementedError();
}

void main() {
  group('D146 — adjustment-queue schema + mapper', () {
    test('schema contract accepts the mapper output; paths are branch-scoped',
        () {
      final request = _request();
      final doc = stockAdjustmentRequestToFirestore(
        request,
        orgId: _org,
      );
      expect(
        FirestoreSchema.validateDocument(
          'branches/{branchId}/stockAdjustments',
          doc,
        ),
        isEmpty,
      );
      expect(
        FirestoreSchema.stockAdjustmentsPath(_dha),
        'branches/$_dha/stockAdjustments',
      );
      expect(
        FirestoreSchema.stockAdjustmentDocPath(_dha, 'adj-1'),
        'branches/$_dha/stockAdjustments/adj-1',
      );
      expect(doc['branchId'], _dha);
      expect(doc['status'], 'pending');
      expect(doc['deltaQty'], -2);
    });

    test('mapper round-trips a decided request exactly', () {
      final decided = _request().copyWith(
        status: StockAdjustmentStatus.approved,
        decidedById: 'test-owner-2',
        decidedByName: 'Test owner 2',
        decidedAt: DateTime(2026, 11, 26, 11, 30),
        decisionNote: 'Verified against the count',
        movementId: 'mv-1',
      );
      final doc = stockAdjustmentRequestToFirestore(decided, orgId: _org);
      final back = stockAdjustmentRequestFromFirestore('adj-1', doc);
      expect(back.id, 'adj-1');
      expect(back.batchId, 'batch-1');
      expect(back.batchNo, 'B-1001');
      expect(back.medicineId, 'med-panadol-extra');
      expect(back.medicineName, 'Panadol Extra');
      expect(back.branchId, _dha);
      expect(back.deltaQty, -2);
      expect(back.reason, 'Damaged in transit');
      expect(back.requesterId, 'test-owner');
      expect(back.requesterName, 'Test owner');
      expect(back.requestedAt, DateTime(2026, 11, 26, 10, 0));
      expect(back.status, StockAdjustmentStatus.approved);
      expect(back.decidedById, 'test-owner-2');
      expect(back.decidedByName, 'Test owner 2');
      expect(back.decidedAt, DateTime(2026, 11, 26, 11, 30));
      expect(back.decisionNote, 'Verified against the count');
      expect(back.movementId, 'mv-1');
    });

    test('model toMap/fromMap round-trips (dates via Timestamp)', () {
      final request = _request();
      final back = StockAdjustmentRequest.fromMap('adj-1', request.toMap());
      expect(back.id, 'adj-1');
      expect(back.deltaQty, -2);
      expect(back.status, StockAdjustmentStatus.pending);
      expect(back.requestedAt, DateTime(2026, 11, 26, 10, 0));
      expect(back.decidedAt, isNull);
      expect(back.movementId, isNull);
    });
  });

  group('D146 — layer queue persistence', () {
    test('file → load round-trip through the mock repo', () async {
      final layer = _layer();
      final saved = await layer.fileAdjustmentRequest(_request());
      expect(saved.id, 'adj-1');
      expect(saved.status, StockAdjustmentStatus.pending);
      final loaded = await layer.loadAdjustmentRequests(branchId: _dha);
      expect(loaded.length, 1);
      expect(loaded.first.id, 'adj-1');
      expect(loaded.first.reason, 'Damaged in transit');
      final stored = await layer.stockAdjustmentRequestRepo.getRequests(
        branchId: _dha,
      );
      expect(stored.length, 1);
      expect(await layer.syncQueue.pendingCount(), 1);
      // The one payload is the request doc.
      final ops = await layer.syncQueue.pendingOperations();
      expect(ops.length, 1);
      expect(ops.first.entityType, 'stockAdjustmentRequest');
      expect(
        (ops.first.payload['operations'] as List).length,
        1,
      );
    });

    test('same-id re-file dedupes: one doc, one sync payload', () async {
      final layer = _layer();
      final first = await layer.fileAdjustmentRequest(_request());
      final second = await layer.fileAdjustmentRequest(_request());
      expect(second.id, first.id);
      expect(
        (await layer.stockAdjustmentRequestRepo.getRequests()).length,
        1,
      );
      expect(await layer.syncQueue.pendingCount(), 1);
    });

    test('decision update persists: load shows the approved request',
        () async {
      final layer = _layer();
      await layer.fileAdjustmentRequest(_request());
      final approved = _request().copyWith(
        status: StockAdjustmentStatus.approved,
        decidedById: 'test-owner-2',
        decidedByName: 'Test owner 2',
        decidedAt: DateTime(2026, 11, 26, 11, 30),
        movementId: 'mv-1',
      );
      final saved = await layer.updateAdjustmentRequest(approved);
      expect(saved.status, StockAdjustmentStatus.approved);
      expect(saved.movementId, 'mv-1');
      final loaded = await layer.loadAdjustmentRequests(branchId: _dha);
      expect(loaded.length, 1);
      expect(loaded.first.status, StockAdjustmentStatus.approved);
      expect(loaded.first.decidedByName, 'Test owner 2');
      // File (1) + decision update (1) = 2 payloads, still one doc.
      expect(await layer.syncQueue.pendingCount(), 2);
      expect(
        (await layer.stockAdjustmentRequestRepo.getRequests()).length,
        1,
      );
    });

    test('a fresh layer instance sharing the repo dedupes on the store',
        () async {
      final layer = _layer();
      await layer.fileAdjustmentRequest(_request());
      final secondLayer = ProductionDataLayer(
        organizationId: _org,
        inventoryRepo: MockInventoryRepository(),
        saleRepo: MockSaleRepository(),
        orderRepo: MockOrderRepository(),
        customerRepo: MockCustomerRepository(),
        medicineRepo: MockMedicineRepository(),
        supplierRepo: MockSupplierRepository(),
        prescriptionRepo: MockPrescriptionRepository(),
        purchaseOrderRepo: MockPurchaseOrderRepository(),
        riderRepo: MockRiderRepository(),
        stockAdjustmentRequestRepo: layer.stockAdjustmentRequestRepo,
        audit: InMemoryAuditLogWriter(),
        syncQueue: SyncQueue(InMemorySyncStore()),
        engine: InventoryEngine(
          organizationId: _org,
          audit: InMemoryAuditLogWriter(),
        ),
      );
      final again = await secondLayer.fileAdjustmentRequest(_request());
      expect(again.id, 'adj-1');
      expect(
        (await layer.stockAdjustmentRequestRepo.getRequests()).length,
        1,
      );
      // The second layer wrote nothing and enqueued nothing.
      expect(await secondLayer.syncQueue.pendingCount(), 0);
    });

    test('Firestore repo round-trips over a fake transport', () async {
      final repo = FirestoreStockAdjustmentRequestRepository(
        transport: _MemoryTransport(),
        organizationId: _org,
      );
      final saved = await repo.saveRequest(_request());
      expect(saved.id, 'adj-1');
      expect((await repo.getRequests(branchId: _dha)).length, 1);
      expect((await repo.getById('adj-1'))?.reason, 'Damaged in transit');
      // A re-save (the decision) overwrites the same doc.
      final decided = _request().copyWith(
        status: StockAdjustmentStatus.rejected,
        decidedById: 'test-owner-2',
        decidedByName: 'Test owner 2',
        decidedAt: DateTime(2026, 11, 26, 11, 30),
        decisionNote: 'Count does not match',
      );
      await repo.saveRequest(decided);
      expect((await repo.getRequests(branchId: _dha)).length, 1);
      final back = await repo.getById('adj-1');
      expect(back?.status, StockAdjustmentStatus.rejected);
      expect(back?.decisionNote, 'Count does not match');
      expect(back?.requestedAt, DateTime(2026, 11, 26, 10, 0));
    });
  });

  group('D146 — notifier re-read + preserved semantics', () {
    test('request survives a notifier rebuild; sequence resumes past it',
        () async {
      final container = ProviderContainer(
        overrides: [
          authProvider.overrideWith(
            () => _FixedAuthNotifier(_userFor('owner')),
          ),
        ],
      );
      addTearDown(container.dispose);
      final inventory = await container
          .read(inventoryRepositoryProvider)
          .getInventory(branchId: _dha);
      final batch = inventory.firstWhere(
        (item) => item.medicineId == 'med-panadol-extra',
      );
      final notifier = container.read(
        stockAdjustmentQueueProvider.notifier,
      );
      final request = await notifier.requestAdjustment(
        batchId: batch.id,
        batchNo: batch.batchNo ?? '—',
        medicineId: batch.medicineId,
        medicineName: 'Panadol Extra',
        branchId: _dha,
        deltaQty: -2,
        reason: 'Damaged in transit',
        onHandQty: batch.quantity,
      );
      expect(request, isNotNull);
      expect(request!.id, 'adj-1');
      // Rebuild the notifier: the fresh instance re-reads the
      // persisted queue from the layer. The rebuild is lazy — the
      // read below triggers it (and its load), then the delay lets
      // the load land before the state is read again.
      container.invalidate(stockAdjustmentQueueProvider);
      container.read(stockAdjustmentQueueProvider);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final restored = container.read(stockAdjustmentQueueProvider);
      expect(restored.length, 1);
      expect(restored.first.id, 'adj-1');
      expect(restored.first.status, StockAdjustmentStatus.pending);
      expect(restored.first.reason, 'Damaged in transit');
      // The next request does not reuse adj-1.
      final second = await container
          .read(stockAdjustmentQueueProvider.notifier)
          .requestAdjustment(
            batchId: batch.id,
            batchNo: batch.batchNo ?? '—',
            medicineId: batch.medicineId,
            medicineName: 'Panadol Extra',
            branchId: _dha,
            deltaQty: 1,
            reason: 'Found on shelf',
            onHandQty: batch.quantity,
          );
      expect(second!.id, 'adj-2');
    });

    test('queue: request → approve applies stock via the layer (D141)',
        () async {
      final auth = _MutableAuthNotifier(_userFor('owner'));
      final container = ProviderContainer(
        overrides: [authProvider.overrideWith(() => auth)],
      );
      addTearDown(container.dispose);
      final layer = container.read(productionDataLayerProvider);
      final inventory = await container
          .read(inventoryRepositoryProvider)
          .getInventory(branchId: _dha);
      final batch = inventory.firstWhere(
        (item) => item.medicineId == 'med-panadol-extra',
      );
      final beforeQty = batch.quantity;
      final notifier = container.read(
        stockAdjustmentQueueProvider.notifier,
      );
      final request = await notifier.requestAdjustment(
        batchId: batch.id,
        batchNo: batch.batchNo ?? '—',
        medicineId: batch.medicineId,
        medicineName: 'Panadol Extra',
        branchId: _dha,
        deltaQty: -2,
        reason: 'Damaged in transit',
        onHandQty: beforeQty,
      );
      expect(request, isNotNull);
      // The request is already persisted while still pending.
      expect(
        (await layer.loadAdjustmentRequests(branchId: _dha)).length,
        1,
      );
      // The requester cannot approve their own request.
      expect(
        await notifier.approveAdjustment(requestId: request!.id),
        isNull,
      );
      // A different Owner approves: the layer applies it.
      auth.user = _userFor('owner', uid: 'test-owner-2');
      final approved = await notifier.approveAdjustment(
        requestId: request.id,
      );
      expect(approved, isNotNull);
      expect(approved!.status, StockAdjustmentStatus.approved);
      expect(approved.movementId, isNotNull);
      expect(
        (await container
                .read(inventoryRepositoryProvider)
                .getInventory(branchId: _dha))
            .firstWhere((item) => item.id == batch.id)
            .quantity,
        beforeQty - 2,
      );
      // File (1) + apply (1) + decision update (1) = 3 payloads.
      expect(await layer.syncQueue.pendingCount(), 3);
      // The persisted copy is approved too.
      final persisted = await layer.loadAdjustmentRequests(branchId: _dha);
      expect(persisted.first.status, StockAdjustmentStatus.approved);
      expect(persisted.first.movementId, approved.movementId);
      // Approving twice is a no-op (already decided).
      expect(
        await notifier.approveAdjustment(requestId: request.id),
        isNull,
      );
      expect(await layer.syncQueue.pendingCount(), 3);
    });

    test('queue: reject records the decision, persists it, applies nothing',
        () async {
      final auth = _MutableAuthNotifier(_userFor('owner'));
      final container = ProviderContainer(
        overrides: [authProvider.overrideWith(() => auth)],
      );
      addTearDown(container.dispose);
      final layer = container.read(productionDataLayerProvider);
      final inventory = await container
          .read(inventoryRepositoryProvider)
          .getInventory(branchId: _dha);
      final batch = inventory.firstWhere(
        (item) => item.medicineId == 'med-panadol-extra',
      );
      final beforeQty = batch.quantity;
      final notifier = container.read(
        stockAdjustmentQueueProvider.notifier,
      );
      final request = await notifier.requestAdjustment(
        batchId: batch.id,
        batchNo: batch.batchNo ?? '—',
        medicineId: batch.medicineId,
        medicineName: 'Panadol Extra',
        branchId: _dha,
        deltaQty: 3,
        reason: 'Found on shelf',
        onHandQty: beforeQty,
      );
      expect(request, isNotNull);
      // The requester cannot reject their own request either.
      expect(
        await notifier.rejectAdjustment(
          requestId: request!.id,
          note: 'No',
        ),
        isNull,
      );
      auth.user = _userFor('owner', uid: 'test-owner-2');
      final rejected = await notifier.rejectAdjustment(
        requestId: request.id,
        note: 'Count does not match',
      );
      expect(rejected, isNotNull);
      expect(rejected!.status, StockAdjustmentStatus.rejected);
      expect(rejected.decisionNote, 'Count does not match');
      expect(
        (await container
                .read(inventoryRepositoryProvider)
                .getInventory(branchId: _dha))
            .firstWhere((item) => item.id == batch.id)
            .quantity,
        beforeQty,
      );
      // The persisted copy is rejected too.
      final persisted = await layer.loadAdjustmentRequests(branchId: _dha);
      expect(persisted.first.status, StockAdjustmentStatus.rejected);
      expect(persisted.first.decisionNote, 'Count does not match');
    });

    test('queue: approval re-validates — stock moved, approve fails',
        () async {
      final auth = _MutableAuthNotifier(_userFor('owner'));
      final container = ProviderContainer(
        overrides: [authProvider.overrideWith(() => auth)],
      );
      addTearDown(container.dispose);
      final layer = container.read(productionDataLayerProvider);
      final inventory = await container
          .read(inventoryRepositoryProvider)
          .getInventory(branchId: _dha);
      final batch = inventory.firstWhere(
        (item) => item.medicineId == 'med-panadol-extra',
      );
      final beforeQty = batch.quantity;
      final notifier = container.read(
        stockAdjustmentQueueProvider.notifier,
      );
      final request = await notifier.requestAdjustment(
        batchId: batch.id,
        batchNo: batch.batchNo ?? '—',
        medicineId: batch.medicineId,
        medicineName: 'Panadol Extra',
        branchId: _dha,
        deltaQty: -2,
        reason: 'Damaged in transit',
        onHandQty: beforeQty,
      );
      expect(request, isNotNull);
      // Stock moves after the request: only 1 unit is left, so the
      // −2 approval no longer validates.
      await layer.adjustStock(
        batchId: batch.id,
        deltaQty: -(beforeQty - 1),
        reason: 'Test drain',
        idempotencyKey: 'drain-day23-1',
      );
      auth.user = _userFor('owner', uid: 'test-owner-2');
      expect(
        await notifier.approveAdjustment(requestId: request!.id),
        isNull,
      );
      expect(
        container
            .read(stockAdjustmentQueueProvider)
            .first
            .status,
        StockAdjustmentStatus.pending,
      );
      expect(
        (await container
                .read(inventoryRepositoryProvider)
                .getInventory(branchId: _dha))
            .firstWhere((item) => item.id == batch.id)
            .quantity,
        1,
      );
    });

    testWidgets('queue screen shows the persisted request after a rebuild',
        (tester) async {
      final layer = _layer();
      final container = ProviderContainer(
        overrides: [
          authProvider.overrideWith(
            () => _FixedAuthNotifier(_userFor('owner')),
          ),
          productionDataLayerProvider.overrideWithValue(layer),
        ],
      );
      addTearDown(container.dispose);
      final inventory = await container
          .read(inventoryRepositoryProvider)
          .getInventory(branchId: _dha);
      final batch = inventory.firstWhere(
        (item) => item.medicineId == 'med-panadol-extra',
      );
      final request = await container
          .read(stockAdjustmentQueueProvider.notifier)
          .requestAdjustment(
            batchId: batch.id,
            batchNo: batch.batchNo ?? '—',
            medicineId: batch.medicineId,
            medicineName: 'Panadol Extra',
            branchId: _dha,
            deltaQty: -2,
            reason: 'Damaged in transit',
            onHandQty: batch.quantity,
          );
      expect(request, isNotNull);
      // Rebuild the notifier before pumping the screen.
      container.invalidate(stockAdjustmentQueueProvider);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.light(BrandConfig.defaults),
            home: const Scaffold(body: AdjustmentQueueScreen()),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(find.text('Adjustment Approvals'), findsOneWidget);
      expect(find.textContaining('Damaged in transit'), findsOneWidget);
      expect(find.text('Pending'), findsWidgets);
    });
  });

  group('D147 — supplier payments through the layer', () {
    test('layer: full payment writes the same three records (old-path numbers)',
        () async {
      final layer = _layer();
      // Seeded opening ledger (D92): MedServe owes Rs 48,250
      // (Rs 60,000 purchase − Rs 11,750 paid).
      final ledger = await layer.supplierRepo.getLedgerEntries(
        'sup-medserve',
      );
      final open = openPayableBalances(supplierLedgerSignedEntries(ledger));
      expect(open.length, 1);
      expect(open.first.id, 'sled-2');
      expect(open.first.remainingMinor, 4825000);
      final agingBefore = computeAging(
        entries: supplierLedgerSignedEntries(ledger),
        now: DateTime.now(),
      );
      expect(agingBefore.totalMinor, 4825000);
      final allocations = allocateSupplierPayment(
        open: open,
        paymentMinor: 4825000,
      );
      expect(allocations.length, 1);
      expect(allocations.first.ledgerEntryId, 'sled-2');
      expect(allocations.first.amountMinor, 4825000);

      final result = await layer.recordSupplierPayment(
        supplierId: 'sup-medserve',
        branchId: _dha,
        amountMinor: 4825000,
        method: SupplierPaymentMethod.bankTransfer,
        reference: 'TXN-TEST-1',
        allocations: allocations,
        idempotencyKey: 'spay-day23-1',
      );
      expect(result.isDuplicate, isFalse);
      // The payment id IS the idempotency key (D65, like receipts).
      expect(result.payment.id, 'spay-day23-1');
      expect(result.payment.unallocatedMinor, 0);
      expect(result.payment.allocations.first.ledgerEntryId, 'sled-2');
      // Ledger entry: same values the old repo-direct path wrote.
      expect(result.ledgerEntry.amountMinor, -4825000);
      expect(result.ledgerEntry.balanceAfterMinor, 0);
      expect(
        result.ledgerEntry.reason,
        'Payment made — Bank transfer (TXN-TEST-1)',
      );
      expect(result.ledgerEntry.referenceId, result.payment.id);
      // Financial-transaction mirror.
      expect(
        result.transaction.type,
        FinancialTransactionType.supplierPayment,
      );
      expect(result.transaction.amountMinor, -4825000);
      expect(result.transaction.category, 'Supplier payment');
      expect(result.transaction.referenceId, result.payment.id);
      // Ledger / aging numbers: settled in full, same as the old
      // path's week2_day05 pin (outstanding 0).
      final after = await layer.supplierRepo.getLedgerEntries('sup-medserve');
      expect(supplierOutstandingMinor(after), 0);
      expect(
        computeAging(
          entries: supplierLedgerSignedEntries(after),
          now: DateTime.now(),
        ).totalMinor,
        0,
      );
      // One sync payload holding all three docs.
      expect(await layer.syncQueue.pendingCount(), 1);
      final ops = await layer.syncQueue.pendingOperations();
      expect(ops.length, 1);
      expect(ops.first.entityType, 'supplierPayment');
      final paths = (ops.first.payload['operations'] as List)
          .map((op) => (op as Map)['path'] as String)
          .toList();
      expect(paths.length, 3);
      expect(
        paths,
        contains('branches/$_dha/supplierPayments/spay-day23-1'),
      );
      expect(paths, contains('suppliers/sup-medserve/ledger/${result.ledgerEntry.id}'));
      expect(
        paths,
        contains(
          'branches/$_dha/financialTransactions/${result.transaction.id}',
        ),
      );
    });

    test('layer: same-key retry pays once (duplicate, no new records)',
        () async {
      final layer = _layer();
      final ledger = await layer.supplierRepo.getLedgerEntries(
        'sup-medserve',
      );
      final open = openPayableBalances(supplierLedgerSignedEntries(ledger));
      final allocations = allocateSupplierPayment(
        open: open,
        paymentMinor: 4825000,
      );
      final txnsBefore = await layer.financialTransactionRepo.getTransactions(
        branchId: _dha,
      );
      final first = await layer.recordSupplierPayment(
        supplierId: 'sup-medserve',
        branchId: _dha,
        amountMinor: 4825000,
        method: SupplierPaymentMethod.bankTransfer,
        reference: 'TXN-TEST-1',
        allocations: allocations,
        idempotencyKey: 'spay-day23-2',
      );
      expect(first.isDuplicate, isFalse);
      final second = await layer.recordSupplierPayment(
        supplierId: 'sup-medserve',
        branchId: _dha,
        amountMinor: 4825000,
        method: SupplierPaymentMethod.bankTransfer,
        reference: 'TXN-TEST-1',
        allocations: allocations,
        idempotencyKey: 'spay-day23-2',
      );
      expect(second.isDuplicate, isTrue);
      expect(second.payment.id, first.payment.id);
      expect(second.ledgerEntry.id, first.ledgerEntry.id);
      expect(second.transaction.id, first.transaction.id);
      expect(
        (await layer.supplierPaymentRepo.getPayments()).length,
        1,
      );
      expect(
        (await layer.supplierRepo.getLedgerEntries('sup-medserve')).length,
        ledger.length + 1,
      );
      final txnsAfter = await layer.financialTransactionRepo.getTransactions(
        branchId: _dha,
      );
      expect(txnsAfter.length, txnsBefore.length + 1);
      expect(await layer.syncQueue.pendingCount(), 1);
      final after = await layer.supplierRepo.getLedgerEntries('sup-medserve');
      expect(supplierOutstandingMinor(after), 0);
    });

    test('layer: invalid payment rejected before any write', () async {
      final layer = _layer();
      expect(
        () => layer.recordSupplierPayment(
          supplierId: 'sup-medserve',
          branchId: _dha,
          amountMinor: 0,
          allocations: const [],
        ),
        throwsArgumentError,
      );
      expect(
        () => layer.recordSupplierPayment(
          supplierId: 'sup-medserve',
          branchId: _dha,
          amountMinor: 4825000,
          allocations: const [
            PaymentAllocation(ledgerEntryId: 'sled-2', amountMinor: 100000),
          ],
        ),
        throwsArgumentError,
      );
      expect(
        (await layer.supplierPaymentRepo.getPayments()).isEmpty,
        isTrue,
      );
      expect(await layer.syncQueue.pendingCount(), 0);
    });

    test('notifier routes through the layer (sync enqueued, numbers kept)',
        () async {
      final container = ProviderContainer(
        overrides: [
          authProvider.overrideWith(
            () => _FixedAuthNotifier(_userFor('owner')),
          ),
        ],
      );
      addTearDown(container.dispose);
      final layer = container.read(productionDataLayerProvider);
      // Same numbers the old repo-direct path pinned in week2_day05:
      // MedServe owes Rs 48,250; paying it in full settles it.
      final result = await container
          .read(supplierPaymentsProvider.notifier)
          .recordPayment(
            supplierId: 'sup-medserve',
            branchId: _dha,
            amountMinor: 4825000,
            method: SupplierPaymentMethod.bankTransfer,
            reference: 'TXN-TEST-1',
          );
      expect(result.error, isNull);
      expect(result.payment?.unallocatedMinor, 0);
      expect(result.payment?.allocations.length, 1);
      expect(
        result.payment?.allocations.first.ledgerEntryId,
        'sled-2',
      );
      expect(result.payment?.allocations.first.amountMinor, 4825000);
      expect(await layer.syncQueue.pendingCount(), 1);
      await container.read(supplierLedgerProvider('sup-medserve').future);
      final outstanding = container.read(
        supplierOutstandingProvider('sup-medserve'),
      );
      expect(outstanding, 0);
      final txns = await container.read(financialTransactionsProvider.future);
      expect(
        txns.any(
          (t) =>
              t.referenceId == result.payment!.id &&
              t.type == FinancialTransactionType.supplierPayment &&
              t.amountMinor == -4825000,
        ),
        true,
      );
      final payments = await container.read(supplierPaymentsProvider.future);
      expect(payments.any((p) => p.id == result.payment!.id), isTrue);
    });

    test('notifier: overpayment refused, branch mgr denied (unchanged)',
        () async {
      final container = ProviderContainer(
        overrides: [
          authProvider.overrideWith(
            () => _FixedAuthNotifier(_userFor('owner')),
          ),
        ],
      );
      addTearDown(container.dispose);
      final over = await container
          .read(supplierPaymentsProvider.notifier)
          .recordPayment(
            supplierId: 'sup-sami',
            branchId: _dha,
            amountMinor: 999999999,
          );
      expect(over.payment, isNull);
      expect(over.error, contains('cannot exceed the outstanding payable'));

      final container2 = ProviderContainer(
        overrides: [
          authProvider.overrideWith(
            () => _FixedAuthNotifier(_userFor('branch_manager')),
          ),
        ],
      );
      addTearDown(container2.dispose);
      final denied = await container2
          .read(supplierPaymentsProvider.notifier)
          .recordPayment(
            supplierId: 'sup-sami',
            branchId: _dha,
            amountMinor: 100000,
          );
      expect(denied.payment, isNull);
      expect(
        denied.error,
        contains('Only the Owner, HO Admin or Accountant'),
      );
    });
  });
}
