// Week 7 Day 1 tests — quarantine outcome queue persistence (D171).
//
// - D171: schema + mapper for `branches/{branchId}/quarantineOutcomes`.
// - D171: layer file / load / update round-trips; same-id re-file
//   dedupes; a fresh layer instance over the same repo dedupes too.
// - D171: the outcome lands on the batch row exactly once — a
//   replay after a restart (empty key registry) returns the batch
//   without a second stock move, audit entry or sync payload.
// - D171: the queue survives a notifier rebuild AND a full restart
//   (new container + new layer over the same persisted stores);
//   the old session-only behaviour (empty queue after a restart)
//   is gone.
// - D171: FR-HO-08 (D149/D161) — approving on a deactivated branch
//   is refused and the request stays pending; reactivation lets
//   the same approval through, exactly once. Filing a request is
//   unguarded (D149 posture — a request moves no stock).

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
import 'package:pharmadesk/features/authentication/auth_state.dart';
import 'package:pharmadesk/features/inventory/inventory_provider.dart';
import 'package:pharmadesk/features/inventory/quarantine_outcome_queue.dart';
import 'package:pharmadesk/models/inventory_item.dart';
import 'package:pharmadesk/models/quarantine_outcome_request.dart';

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

QuarantineOutcomeRequest _request({
  String id = 'qo-1',
  QuarantineOutcome outcome = QuarantineOutcome.dispose,
}) {
  return QuarantineOutcomeRequest(
    id: id,
    batchId: 'batch-1',
    batchNo: 'B-1001',
    medicineId: 'med-panadol-extra',
    medicineName: 'Panadol Extra',
    branchId: _dha,
    outcome: outcome,
    reason: 'Damaged beyond use',
    quantityAtRequest: 12,
    requesterId: 'test-inventory_manager',
    requesterName: 'Test inventory_manager',
    requestedAt: DateTime(2026, 11, 26, 10, 0),
  );
}

/// Production layer over shared mock stores, with the stores
/// exposed so tests can simulate a restart: a fresh layer over the
/// same repos is a new app session over the same persisted data.
class _Harness {
  _Harness()
    : inventoryRepo = MockInventoryRepository(),
      outcomeRepo = MockQuarantineOutcomeRequestRepository(),
      branchRepo = MockBranchRepository(),
      audit = InMemoryAuditLogWriter() {
    layer = _buildLayer();
  }

  final MockInventoryRepository inventoryRepo;
  final MockQuarantineOutcomeRequestRepository outcomeRepo;
  final MockBranchRepository branchRepo;
  final InMemoryAuditLogWriter audit;
  late final ProductionDataLayer layer;

  ProductionDataLayer _buildLayer() {
    return ProductionDataLayer(
      organizationId: _org,
      inventoryRepo: inventoryRepo,
      saleRepo: MockSaleRepository(),
      orderRepo: MockOrderRepository(),
      customerRepo: MockCustomerRepository(),
      medicineRepo: MockMedicineRepository(),
      supplierRepo: MockSupplierRepository(),
      prescriptionRepo: MockPrescriptionRepository(),
      purchaseOrderRepo: MockPurchaseOrderRepository(),
      riderRepo: MockRiderRepository(),
      quarantineOutcomeRequestRepo: outcomeRepo,
      branchRepo: branchRepo,
      audit: audit,
      syncQueue: SyncQueue(InMemorySyncStore()),
      engine: InventoryEngine(organizationId: _org, audit: audit),
    );
  }

  /// A fresh layer instance over the same persisted stores — the
  /// app-restart simulation (new registries, same repos).
  ProductionDataLayer restartedLayer() => _buildLayer();
}

Future<void> _deactivate(_Harness h, String branchId) async {
  final branch = await h.branchRepo.getById(branchId);
  await h.branchRepo.updateBranch(branch!.copyWith(active: false));
}

Future<void> _reactivate(_Harness h, String branchId) async {
  final branch = await h.branchRepo.getById(branchId);
  await h.branchRepo.updateBranch(branch!.copyWith(active: true));
}

/// A container whose queue notifier + inventory read through the
/// harness layer and its shared inventory repo (the app wiring,
/// with the layer swapped in — the productionDataLayerProvider
/// override is what the app provider does with the bundle).
Future<ProviderContainer> _container(
  _Harness h,
  ProductionDataLayer layer, {
  required _MutableAuthNotifier auth,
}) async {
  final container = ProviderContainer(
    overrides: [
      productionDataLayerProvider.overrideWithValue(layer),
      inventoryRepositoryProvider.overrideWithValue(h.inventoryRepo),
      authProvider.overrideWith(() => auth),
    ],
  );
  addTearDown(container.dispose);
  // Initialize the auth notifier now: a later mid-test user swap
  // (`auth.user = …`) writes `state`, which throws on a notifier
  // that was never instantiated (a fresh container that has not
  // read auth yet — e.g. right after a restart).
  container.read(authProvider);
  await container.read(inventoryProvider.future);
  return container;
}

Future<InventoryItem> _quarantinePanadol(ProviderContainer c) async {
  final batch = (await c
          .read(inventoryRepositoryProvider)
          .getInventory(branchId: _dha))
      .firstWhere((item) => item.medicineId == 'med-panadol-extra');
  final updated = await c
      .read(inventoryProvider.notifier)
      .quarantineBatch(batchId: batch.id, reason: 'Suspected damage');
  return updated!;
}

/// Reads the queue after a (re)build has had time to load: the
/// notifier build starts `refresh()` async, so the first read
/// triggers it and the delay lets the load land (D146 pattern).
Future<List<QuarantineOutcomeRequest>> _readQueue(
  ProviderContainer container,
) async {
  container.read(quarantineOutcomeQueueProvider);
  await Future<void>.delayed(const Duration(milliseconds: 100));
  return container.read(quarantineOutcomeQueueProvider);
}

/// Minimal in-memory [FirestoreTransport] for the Firestore
/// quarantine-outcome repository test: only the calls that
/// repository makes are implemented (`queryCollection` for the
/// branch list + the collection scan, `getDocument` /
/// `setDocument`, `newDocumentId`); the rest throw, because the
/// repo never calls them (no counters, no transactions, no batched
/// writes).
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
  group('D171 — quarantine outcome schema + mapper', () {
    test('schema contract accepts the mapper output; paths are branch-scoped',
        () {
      final request = _request();
      final doc = quarantineOutcomeRequestToFirestore(request, orgId: _org);
      expect(
        FirestoreSchema.validateDocument(
          'branches/{branchId}/quarantineOutcomes',
          doc,
        ),
        isEmpty,
      );
      expect(
        FirestoreSchema.quarantineOutcomesPath(_dha),
        'branches/$_dha/quarantineOutcomes',
      );
      expect(
        FirestoreSchema.quarantineOutcomeDocPath(_dha, 'qo-1'),
        'branches/$_dha/quarantineOutcomes/qo-1',
      );
      expect(doc['branchId'], _dha);
      expect(doc['status'], 'pending');
      expect(doc['outcome'], 'dispose');
      expect(doc['quantityAtRequest'], 12);
    });

    test('mapper round-trips a decided request exactly', () {
      final decided = _request().copyWith(
        status: QuarantineOutcomeStatus.approved,
        decidedById: 'test-owner',
        decidedByName: 'Test owner',
        decidedAt: DateTime(2026, 11, 26, 11, 30),
        decisionNote: 'Verified against the count',
      );
      final doc = quarantineOutcomeRequestToFirestore(decided, orgId: _org);
      final back = quarantineOutcomeRequestFromFirestore('qo-1', doc);
      expect(back.id, 'qo-1');
      expect(back.batchId, 'batch-1');
      expect(back.batchNo, 'B-1001');
      expect(back.medicineId, 'med-panadol-extra');
      expect(back.medicineName, 'Panadol Extra');
      expect(back.branchId, _dha);
      expect(back.outcome, QuarantineOutcome.dispose);
      expect(back.reason, 'Damaged beyond use');
      expect(back.quantityAtRequest, 12);
      expect(back.requesterId, 'test-inventory_manager');
      expect(back.requesterName, 'Test inventory_manager');
      expect(back.requestedAt, DateTime(2026, 11, 26, 10, 0));
      expect(back.status, QuarantineOutcomeStatus.approved);
      expect(back.decidedById, 'test-owner');
      expect(back.decidedByName, 'Test owner');
      expect(back.decidedAt, DateTime(2026, 11, 26, 11, 30));
      expect(back.decisionNote, 'Verified against the count');
    });

    test('model toMap/fromMap round-trips (dates via Timestamp)', () {
      final request = _request();
      final back = QuarantineOutcomeRequest.fromMap('qo-1', request.toMap());
      expect(back.id, 'qo-1');
      expect(back.outcome, QuarantineOutcome.dispose);
      expect(back.status, QuarantineOutcomeStatus.pending);
      expect(back.requestedAt, DateTime(2026, 11, 26, 10, 0));
      expect(back.decidedAt, isNull);
      expect(back.decisionNote, isNull);
    });
  });

  group('D171 — layer queue persistence', () {
    test('file → load round-trip through the mock repo', () async {
      final h = _Harness();
      final saved = await h.layer.fileQuarantineOutcomeRequest(_request());
      expect(saved.id, 'qo-1');
      expect(saved.status, QuarantineOutcomeStatus.pending);
      final loaded = await h.layer.loadQuarantineOutcomeRequests(
        branchId: _dha,
      );
      expect(loaded.length, 1);
      expect(loaded.first.id, 'qo-1');
      expect(loaded.first.reason, 'Damaged beyond use');
      final stored = await h.outcomeRepo.getRequests(branchId: _dha);
      expect(stored.length, 1);
      expect(await h.layer.syncQueue.pendingCount(), 1);
      // The one payload is the request doc.
      final ops = await h.layer.syncQueue.pendingOperations();
      expect(ops.length, 1);
      expect(ops.first.entityType, 'quarantineOutcomeRequest');
      expect((ops.first.payload['operations'] as List).length, 1);
    });

    test('same-id re-file dedupes: one doc, one sync payload', () async {
      final h = _Harness();
      final first = await h.layer.fileQuarantineOutcomeRequest(_request());
      final second = await h.layer.fileQuarantineOutcomeRequest(_request());
      expect(second.id, first.id);
      expect((await h.outcomeRepo.getRequests()).length, 1);
      expect(await h.layer.syncQueue.pendingCount(), 1);
    });

    test('decision update persists: load shows the approved request',
        () async {
      final h = _Harness();
      await h.layer.fileQuarantineOutcomeRequest(_request());
      final approved = _request().copyWith(
        status: QuarantineOutcomeStatus.approved,
        decidedById: 'test-owner',
        decidedByName: 'Test owner',
        decidedAt: DateTime(2026, 11, 26, 11, 30),
        decisionNote: 'Verified against the count',
      );
      final saved = await h.layer.updateQuarantineOutcomeRequest(approved);
      expect(saved.status, QuarantineOutcomeStatus.approved);
      expect(saved.decisionNote, 'Verified against the count');
      final loaded = await h.layer.loadQuarantineOutcomeRequests(
        branchId: _dha,
      );
      expect(loaded.length, 1);
      expect(loaded.first.status, QuarantineOutcomeStatus.approved);
      expect(loaded.first.decidedByName, 'Test owner');
      // File (1) + decision update (1) = 2 payloads, still one doc.
      expect(await h.layer.syncQueue.pendingCount(), 2);
      expect((await h.outcomeRepo.getRequests()).length, 1);
    });

    test('a fresh layer instance sharing the repo dedupes on the store',
        () async {
      final h = _Harness();
      await h.layer.fileQuarantineOutcomeRequest(_request());
      final secondLayer = h.restartedLayer();
      final again = await secondLayer.fileQuarantineOutcomeRequest(
        _request(),
      );
      expect(again.id, 'qo-1');
      expect((await h.outcomeRepo.getRequests()).length, 1);
      // The second layer wrote nothing and enqueued nothing.
      expect(await secondLayer.syncQueue.pendingCount(), 0);
    });

    test('Firestore repo round-trips over a fake transport', () async {
      final repo = FirestoreQuarantineOutcomeRequestRepository(
        transport: _MemoryTransport(),
        organizationId: _org,
      );
      final saved = await repo.saveRequest(_request());
      expect(saved.id, 'qo-1');
      expect((await repo.getRequests(branchId: _dha)).length, 1);
      expect((await repo.getById('qo-1'))?.reason, 'Damaged beyond use');
      // A re-save (the decision) overwrites the same doc.
      final decided = _request().copyWith(
        status: QuarantineOutcomeStatus.rejected,
        decidedById: 'test-owner',
        decidedByName: 'Test owner',
        decidedAt: DateTime(2026, 11, 26, 11, 30),
        decisionNote: 'Restore it instead',
      );
      await repo.saveRequest(decided);
      expect((await repo.getRequests(branchId: _dha)).length, 1);
      final back = await repo.getById('qo-1');
      expect(back?.status, QuarantineOutcomeStatus.rejected);
      expect(back?.decisionNote, 'Restore it instead');
      expect(back?.requestedAt, DateTime(2026, 11, 26, 10, 0));
    });
  });

  group('D171 — outcome applied exactly once', () {
    Future<InventoryItem> quarantinedBatch(_Harness h) async {
      final batch =
          (await h.inventoryRepo.getInventory(branchId: _dha)).firstWhere(
            (item) => item.medicineId == 'med-panadol-extra',
          );
      return h.layer.quarantineBatch(
        batchId: batch.id,
        reason: 'Suspected damage',
        idempotencyKey: 'quarantine-d171-setup-${batch.id}',
      );
    }

    test('layer replay after a restart applies nothing twice', () async {
      final h = _Harness();
      final parked = await quarantinedBatch(h);
      final disposed = await h.layer.applyQuarantineOutcome(
        batchId: parked.id,
        outcome: QuarantineOutcome.dispose,
        reason: 'Damaged beyond use',
        idempotencyKey: 'quarantine-outcome-qo-1',
      );
      expect(disposed.status, BatchStatus.disposed);
      expect(disposed.quantity, parked.quantity);
      expect(
        (await h.audit.entries(action: 'batch.disposed')).length,
        1,
      );
      expect(await h.layer.syncQueue.pendingCount(), 2);
      // Restart: a fresh layer instance (empty key registry) replays
      // the same key — the batch row is already disposed, so it
      // returns the batch without moving stock, auditing or
      // enqueuing a second time.
      final replayedLayer = h.restartedLayer();
      final replayed = await replayedLayer.applyQuarantineOutcome(
        batchId: parked.id,
        outcome: QuarantineOutcome.dispose,
        reason: 'Damaged beyond use',
        idempotencyKey: 'quarantine-outcome-qo-1',
      );
      expect(replayed.status, BatchStatus.disposed);
      expect(replayed.quantity, parked.quantity);
      expect(
        (await h.audit.entries(action: 'batch.disposed')).length,
        1,
      );
      expect(await replayedLayer.syncQueue.pendingCount(), 0);
      final still =
          (await h.inventoryRepo.getInventory(branchId: _dha)).firstWhere(
            (item) => item.id == parked.id,
          );
      expect(still.status, BatchStatus.disposed);
      expect(still.quantity, parked.quantity);
    });

    test('replay with a mismatched outcome still throws', () async {
      final h = _Harness();
      final parked = await quarantinedBatch(h);
      await h.layer.applyQuarantineOutcome(
        batchId: parked.id,
        outcome: QuarantineOutcome.dispose,
        reason: 'Damaged beyond use',
        idempotencyKey: 'quarantine-outcome-qo-1',
      );
      // The batch is disposed, not quarantined — a return for it is
      // not a replay of the dispose, it is a new outcome on a batch
      // that can no longer be decided.
      final replayedLayer = h.restartedLayer();
      await expectLater(
        () => replayedLayer.applyQuarantineOutcome(
          batchId: parked.id,
          outcome: QuarantineOutcome.returnToSupplier,
          reason: 'Supplier agreed to take it back',
          idempotencyKey: 'quarantine-outcome-qo-2',
        ),
        throwsArgumentError,
      );
      expect(
        (await h.audit.entries(action: 'batch.returned')).length,
        0,
      );
    });

    test('an outcome on a non-quarantined batch still throws', () async {
      final h = _Harness();
      final batch =
          (await h.inventoryRepo.getInventory(branchId: _dha)).firstWhere(
            (item) => item.medicineId == 'med-panadol-extra',
          );
      expect(batch.status, BatchStatus.available);
      await expectLater(
        () => h.layer.applyQuarantineOutcome(
          batchId: batch.id,
          outcome: QuarantineOutcome.dispose,
          reason: 'Damaged beyond use',
          idempotencyKey: 'quarantine-outcome-qo-1',
        ),
        throwsArgumentError,
      );
    });
  });

  group('D171 — notifier re-read + restart', () {
    test('request survives a notifier rebuild; sequence resumes past it',
        () async {
      final h = _Harness();
      final auth = _MutableAuthNotifier(_userFor('inventory_manager'));
      final container = await _container(h, h.layer, auth: auth);
      final parked = await _quarantinePanadol(container);
      final request = await container
          .read(quarantineOutcomeQueueProvider.notifier)
          .requestOutcome(
            batch: parked,
            medicineName: 'Panadol Extra',
            outcome: QuarantineOutcome.dispose,
            reason: 'Damaged beyond use',
          );
      expect(request, isNotNull);
      expect(request!.id, 'qo-1');
      // Rebuild the notifier: the fresh instance re-reads the
      // persisted queue from the layer. The rebuild is lazy — the
      // read below triggers it (and its load), then the delay lets
      // the load land before the state is read again.
      container.invalidate(quarantineOutcomeQueueProvider);
      final restored = await _readQueue(container);
      expect(restored.length, 1);
      expect(restored.first.id, 'qo-1');
      expect(restored.first.status, QuarantineOutcomeStatus.pending);
      expect(restored.first.reason, 'Damaged beyond use');
      // The next request does not reuse qo-1.
      final second = await container
          .read(quarantineOutcomeQueueProvider.notifier)
          .requestOutcome(
            batch: parked,
            medicineName: 'Panadol Extra',
            outcome: QuarantineOutcome.returnToSupplier,
            reason: 'Supplier agreed to take it back',
          );
      expect(second!.id, 'qo-2');
    });

    test('queue survives a full restart; approval lands exactly once',
        () async {
      final h = _Harness();
      final auth = _MutableAuthNotifier(_userFor('inventory_manager'));
      final container = await _container(h, h.layer, auth: auth);
      final parked = await _quarantinePanadol(container);
      final request = await container
          .read(quarantineOutcomeQueueProvider.notifier)
          .requestOutcome(
            batch: parked,
            medicineName: 'Panadol Extra',
            outcome: QuarantineOutcome.returnToSupplier,
            reason: 'Supplier agreed to take it back',
          );
      expect(request!.id, 'qo-1');
      // Restart: new container + new layer over the same persisted
      // stores. The session-only queue would come back empty here.
      final restarted = h.restartedLayer();
      final auth2 = _MutableAuthNotifier(_userFor('inventory_manager'));
      final container2 = await _container(h, restarted, auth: auth2);
      final restored = await _readQueue(container2);
      expect(restored.length, 1);
      expect(restored.first.id, 'qo-1');
      expect(restored.first.isPending, isTrue);
      expect(restored.first.reason, 'Supplier agreed to take it back');
      // A different approver (Owner) approves after the restart —
      // the batch leaves stock exactly once.
      auth2.user = _userFor('owner', uid: 'test-owner');
      final approved = await container2
          .read(quarantineOutcomeQueueProvider.notifier)
          .approveOutcome(requestId: 'qo-1');
      expect(approved, isNotNull);
      expect(approved!.status, QuarantineOutcomeStatus.approved);
      final moved =
          (await h.inventoryRepo.getInventory(branchId: _dha)).firstWhere(
            (item) => item.id == parked.id,
          );
      expect(moved.status, BatchStatus.returned);
      expect(moved.quantity, 0);
      expect(
        (await h.audit.entries(action: 'batch.returned')).length,
        1,
      );
      // Approving again is a no-op (not pending any more).
      final again = await container2
          .read(quarantineOutcomeQueueProvider.notifier)
          .approveOutcome(requestId: 'qo-1');
      expect(again, isNull);
    });

    test('a decided request survives a restart', () async {
      final h = _Harness();
      final auth = _MutableAuthNotifier(_userFor('inventory_manager'));
      final container = await _container(h, h.layer, auth: auth);
      final parked = await _quarantinePanadol(container);
      await container
          .read(quarantineOutcomeQueueProvider.notifier)
          .requestOutcome(
            batch: parked,
            medicineName: 'Panadol Extra',
            outcome: QuarantineOutcome.dispose,
            reason: 'Damaged beyond use',
          );
      auth.user = _userFor('owner', uid: 'test-owner');
      final approved = await container
          .read(quarantineOutcomeQueueProvider.notifier)
          .approveOutcome(requestId: 'qo-1');
      expect(approved!.status, QuarantineOutcomeStatus.approved);
      // Restart: the decision is still there — the queue is a
      // historical record, not a session list.
      final restarted = h.restartedLayer();
      final auth2 = _MutableAuthNotifier(_userFor('owner'));
      final container2 = await _container(h, restarted, auth: auth2);
      final restored = await _readQueue(container2);
      expect(restored.length, 1);
      expect(restored.first.status, QuarantineOutcomeStatus.approved);
      expect(restored.first.decidedByName, 'Test owner');
      final moved =
          (await h.inventoryRepo.getInventory(branchId: _dha)).firstWhere(
            (item) => item.id == parked.id,
          );
      expect(moved.status, BatchStatus.disposed);
    });

    test('approve after a restart replays an already-applied outcome once',
        () async {
      final h = _Harness();
      final auth = _MutableAuthNotifier(_userFor('inventory_manager'));
      final container = await _container(h, h.layer, auth: auth);
      final parked = await _quarantinePanadol(container);
      await container
          .read(quarantineOutcomeQueueProvider.notifier)
          .requestOutcome(
            batch: parked,
            medicineName: 'Panadol Extra',
            outcome: QuarantineOutcome.dispose,
            reason: 'Damaged beyond use',
          );
      // The lost-decision window: the outcome landed on the batch
      // row (via the layer, e.g. a retry after a crashed approve)
      // but the decision was never persisted — the request is
      // still pending in the store.
      await h.layer.applyQuarantineOutcome(
        batchId: parked.id,
        outcome: QuarantineOutcome.dispose,
        reason: 'Damaged beyond use',
        idempotencyKey: 'quarantine-outcome-qo-1',
      );
      expect(
        (await h.audit.entries(action: 'batch.disposed')).length,
        1,
      );
      // Restart, then approve: the apply replays as a duplicate
      // (no second stock move, no second audit entry) and the
      // decision is persisted.
      final restarted = h.restartedLayer();
      final auth2 = _MutableAuthNotifier(_userFor('owner'));
      final container2 = await _container(h, restarted, auth: auth2);
      final restored = await _readQueue(container2);
      expect(restored.first.isPending, isTrue);
      final approved = await container2
          .read(quarantineOutcomeQueueProvider.notifier)
          .approveOutcome(requestId: 'qo-1');
      expect(approved, isNotNull);
      expect(approved!.status, QuarantineOutcomeStatus.approved);
      expect(
        (await h.audit.entries(action: 'batch.disposed')).length,
        1,
      );
      // The restarted layer enqueued only the decision update.
      expect(await restarted.syncQueue.pendingCount(), 1);
      final moved =
          (await h.inventoryRepo.getInventory(branchId: _dha)).firstWhere(
            (item) => item.id == parked.id,
          );
      expect(moved.status, BatchStatus.disposed);
      expect(moved.quantity, parked.quantity);
    });

    test('a rejection survives a restart; the batch stays quarantined',
        () async {
      final h = _Harness();
      final auth = _MutableAuthNotifier(_userFor('inventory_manager'));
      final container = await _container(h, h.layer, auth: auth);
      final parked = await _quarantinePanadol(container);
      await container
          .read(quarantineOutcomeQueueProvider.notifier)
          .requestOutcome(
            batch: parked,
            medicineName: 'Panadol Extra',
            outcome: QuarantineOutcome.dispose,
            reason: 'Damaged beyond use',
          );
      auth.user = _userFor('owner', uid: 'test-owner');
      final rejected = await container
          .read(quarantineOutcomeQueueProvider.notifier)
          .rejectOutcome(requestId: 'qo-1', note: 'Restore it instead');
      expect(rejected!.status, QuarantineOutcomeStatus.rejected);
      final restarted = h.restartedLayer();
      final auth2 = _MutableAuthNotifier(_userFor('owner'));
      final container2 = await _container(h, restarted, auth: auth2);
      final restored = await _readQueue(container2);
      expect(restored.length, 1);
      expect(restored.first.status, QuarantineOutcomeStatus.rejected);
      expect(restored.first.decisionNote, 'Restore it instead');
      final still =
          (await h.inventoryRepo.getInventory(branchId: _dha)).firstWhere(
            (item) => item.id == parked.id,
          );
      expect(still.status, BatchStatus.quarantined);
      expect(still.quantity, parked.quantity);
    });
  });

  group('D171 — deactivated-branch refusal (FR-HO-08)', () {
    test('layer: an outcome on a deactivated branch throws, nothing moves',
        () async {
      final h = _Harness();
      final batch =
          (await h.inventoryRepo.getInventory(branchId: _dha)).firstWhere(
            (item) => item.medicineId == 'med-panadol-extra',
          );
      final parked = await h.layer.quarantineBatch(
        batchId: batch.id,
        reason: 'Suspected damage',
        idempotencyKey: 'quarantine-d171-deact-${batch.id}',
      );
      await _deactivate(h, _dha);
      await expectLater(
        () => h.layer.applyQuarantineOutcome(
          batchId: parked.id,
          outcome: QuarantineOutcome.dispose,
          reason: 'Damaged beyond use',
          idempotencyKey: 'quarantine-outcome-qo-1',
        ),
        throwsArgumentError,
      );
      final still =
          (await h.inventoryRepo.getInventory(branchId: _dha)).firstWhere(
            (item) => item.id == parked.id,
          );
      expect(still.status, BatchStatus.quarantined);
      expect(
        (await h.audit.entries(action: 'batch.disposed')).length,
        0,
      );
      expect(await h.layer.syncQueue.pendingCount(), 1);
    });

    test(
      'notifier: approve refused while deactivated, then succeeds exactly once after reactivation',
      () async {
        final h = _Harness();
        final auth = _MutableAuthNotifier(_userFor('inventory_manager'));
        final container = await _container(h, h.layer, auth: auth);
        final parked = await _quarantinePanadol(container);
        await container
            .read(quarantineOutcomeQueueProvider.notifier)
            .requestOutcome(
              batch: parked,
              medicineName: 'Panadol Extra',
              outcome: QuarantineOutcome.dispose,
              reason: 'Damaged beyond use',
            );
        await _deactivate(h, _dha);
        auth.user = _userFor('owner', uid: 'test-owner');
        final refused = await container
            .read(quarantineOutcomeQueueProvider.notifier)
            .approveOutcome(requestId: 'qo-1');
        expect(refused, isNull);
        expect(
          container.read(quarantineOutcomeQueueProvider).first.isPending,
          isTrue,
        );
        final still =
            (await h.inventoryRepo.getInventory(branchId: _dha)).firstWhere(
              (item) => item.id == parked.id,
            );
        expect(still.status, BatchStatus.quarantined);
        // Reactivate: the same approval goes through and applies
        // the outcome exactly once.
        await _reactivate(h, _dha);
        final approved = await container
            .read(quarantineOutcomeQueueProvider.notifier)
            .approveOutcome(requestId: 'qo-1');
        expect(approved, isNotNull);
        expect(approved!.status, QuarantineOutcomeStatus.approved);
        final moved =
            (await h.inventoryRepo.getInventory(branchId: _dha)).firstWhere(
              (item) => item.id == parked.id,
            );
        expect(moved.status, BatchStatus.disposed);
        expect(
          (await h.audit.entries(action: 'batch.disposed')).length,
          1,
        );
      },
    );

    test('filing a request on a deactivated branch is still allowed',
        () async {
      // D149 posture, unchanged: filing moves no stock — only the
      // approval apply is guarded. The request waits, pending,
      // until the branch is active again.
      final h = _Harness();
      final auth = _MutableAuthNotifier(_userFor('inventory_manager'));
      final container = await _container(h, h.layer, auth: auth);
      final parked = await _quarantinePanadol(container);
      await _deactivate(h, _dha);
      final request = await container
          .read(quarantineOutcomeQueueProvider.notifier)
          .requestOutcome(
            batch: parked,
            medicineName: 'Panadol Extra',
            outcome: QuarantineOutcome.dispose,
            reason: 'Damaged beyond use',
          );
      expect(request, isNotNull);
      expect(request!.isPending, isTrue);
      expect((await h.outcomeRepo.getRequests()).length, 1);
    });

    test('unknown branch ids are NOT refused (D149 posture, unchanged)',
        () async {
      final h = _Harness();
      final seeded =
          (await h.inventoryRepo.getInventory(branchId: _dha)).firstWhere(
            (item) => item.medicineId == 'med-panadol-extra',
          );
      // A batch under a branch id the directory never saw: the
      // guard cannot know it deactivated, so it lets it through.
      final ghost = seeded.copyWith(
        id: 'inv-ghost-1',
        branchId: 'branch-never-in-directory',
        status: BatchStatus.quarantined,
      );
      await h.inventoryRepo.upsertInventoryItem(ghost);
      final applied = await h.layer.applyQuarantineOutcome(
        batchId: ghost.id,
        outcome: QuarantineOutcome.dispose,
        reason: 'Damaged beyond use',
        idempotencyKey: 'quarantine-outcome-ghost',
      );
      expect(applied.status, BatchStatus.disposed);
    });
  });
}
