// Week 4 Day 2 tests — stock transfer (D-16) + riders & delivery (D-21).
//
// - Transfer lifecycle (layer, D118): request → approve → dispatch →
//   receive moves real stock FEFO out of the source and into the
//   destination (transfer_out / transfer_in ledger movements +
//   audit), with the status guards, approval separation (SRS §5.2),
//   insufficient-stock rollback and per-step idempotency retries.
// - Rider assignment (layer, D121): one write path — the order's
//   `riderId` and the rider's `currentOrderId` move together, with
//   the inactive / cross-branch / busy / pickup / delivered guards.
// - Gates + validation (pure): the `stockTransfer` matrix row
//   (SRS §5.1) and `validateTransferRequest`; rider availability.
// - Firestore transfer repo (fake transport): create → number,
//   branch-scoped reads (source + destination), update round-trip;
//   rider `updateRider` round-trip.
// - Screens + routes (widget): all five new routes resolve, the
//   seeded transfers/riders render labelled demo/sample, the
//   Pharmacist is stopped at the transfer route, the sidebar carries
//   both entries, the transfer form creates end to end, and the
//   Order Detail assign flow assigns a rider.

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
import 'package:pharmadesk/core/data/permission_service.dart';
import 'package:pharmadesk/core/data/production_data_layer.dart';
import 'package:pharmadesk/core/data/sync_queue.dart';
import 'package:pharmadesk/core/routing/app_router.dart';
import 'package:pharmadesk/core/services/demo_seed_data.dart';
import 'package:pharmadesk/core/services/repositories.dart';
import 'package:pharmadesk/core/theme/app_theme.dart';
import 'package:pharmadesk/core/theme/white_label.dart';
import 'package:pharmadesk/features/authentication/auth_state.dart';
import 'package:pharmadesk/features/inventory/transfer_logic.dart';
import 'package:pharmadesk/features/riders/rider_logic.dart';
import 'package:pharmadesk/features/settings/roles_permissions.dart';
import 'package:pharmadesk/models/order.dart';
import 'package:pharmadesk/models/rider.dart';
import 'package:pharmadesk/models/stock_transfer.dart';

const _dha = 'branch-dha-main';
const _glb = 'branch-demo-gulberg';
const _org = demoOrganizationId;
const _panadol = 'med-panadol-extra';

/// Production layer over fresh mocks, with the repos + engine kept
/// so tests can assert against them (same helper shape as the
/// Week 3 Day 2/4 layer tests).
({
  ProductionDataLayer layer,
  MockInventoryRepository inventoryRepo,
  MockOrderRepository orderRepo,
  MockRiderRepository riderRepo,
  MockStockTransferRepository transferRepo,
  MockMedicineRepository medicineRepo,
  InventoryEngine engine,
  InMemoryAuditLogWriter audit,
  SyncQueue queue,
})
_layer() {
  final audit = InMemoryAuditLogWriter();
  final queue = SyncQueue(InMemorySyncStore());
  final engine = InventoryEngine(organizationId: _org, audit: audit);
  final inventoryRepo = MockInventoryRepository();
  final orderRepo = MockOrderRepository();
  final riderRepo = MockRiderRepository();
  final transferRepo = MockStockTransferRepository();
  final medicineRepo = MockMedicineRepository();
  final layer = ProductionDataLayer(
    organizationId: _org,
    inventoryRepo: inventoryRepo,
    saleRepo: MockSaleRepository(),
    orderRepo: orderRepo,
    customerRepo: MockCustomerRepository(),
    medicineRepo: medicineRepo,
    supplierRepo: MockSupplierRepository(),
    prescriptionRepo: MockPrescriptionRepository(),
    purchaseOrderRepo: MockPurchaseOrderRepository(),
    riderRepo: riderRepo,
    stockTransferRepo: transferRepo,
    audit: audit,
    syncQueue: queue,
    engine: engine,
  );
  return (
    layer: layer,
    inventoryRepo: inventoryRepo,
    orderRepo: orderRepo,
    riderRepo: riderRepo,
    transferRepo: transferRepo,
    medicineRepo: medicineRepo,
    engine: engine,
    audit: audit,
    queue: queue,
  );
}

/// On-hand units of one medicine in one branch, from the repo.
Future<int> _onHand(
  MockInventoryRepository repo,
  String branchId,
  String medicineId,
) async {
  final rows = await repo.getInventory(branchId: branchId);
  return rows
      .where((row) => row.medicineId == medicineId)
      .fold<int>(0, (sum, row) => sum + row.quantity);
}

/// Receives 50 sellable Panadol into DHA, then requests 20 of them
/// for Gulberg — the standard approved-transfer setup. Returns the
/// requested transfer.
Future<StockTransfer> _approvedTransfer(
  ProductionDataLayer layer, {
  String actorId = 'demo-owner',
}) async {
  final now = DateTime.now();
  await layer.receiveStock(
    branchId: _dha,
    medicineId: _panadol,
    batchNo: 'TEST-TRANSFER-1',
    mfgDate: now.subtract(const Duration(days: 30)),
    expiryDate: now.add(const Duration(days: 365)),
    quantity: 50,
    costMinor: 10000,
  );
  final created = await layer.createTransfer(
    fromBranchId: _dha,
    toBranchId: _glb,
    items: const [
      TransferItem(
        medicineId: _panadol,
        medicineName: 'Panadol Extra',
        quantity: 20,
      ),
    ],
    actorId: actorId,
  );
  return layer.approveTransfer(
    created.transfer.id,
    actorId: 'demo-branch_manager',
    actorName: 'Branch Manager',
  );
}

/// An editable delivery order with no rider yet (the seed
/// guarantees live ones: New orders of the day carry no rider).
Future<Order> _unassignedDeliveryOrder(MockOrderRepository repo) async {
  final orders = await repo.getOrders(branchId: _dha);
  return orders.firstWhere(
    (order) =>
        order.fulfillment == FulfillmentType.delivery &&
        order.riderId == null &&
        order.status != OrderStatus.delivered &&
        order.status != OrderStatus.cancelled,
  );
}

void main() {
  group('Transfer lifecycle (layer, D118)', () {
    test('request creates a Requested transfer and moves no stock', () async {
      final t = _layer();
      final before = await _onHand(t.inventoryRepo, _dha, _panadol);
      final beforeSync = await t.layer.pendingSyncCount();
      final result = await t.layer.createTransfer(
        fromBranchId: _dha,
        toBranchId: _glb,
        items: const [
          TransferItem(
            medicineId: _panadol,
            medicineName: 'Panadol Extra',
            quantity: 5,
          ),
        ],
        note: 'Test request',
        actorId: 'demo-owner',
      );
      expect(result.isDuplicate, isFalse);
      expect(result.transfer.status, StockTransferStatus.requested);
      expect(result.transfer.transferNumber, startsWith('TR-DHA-GLB-'));
      expect(result.transfer.items.single.medicineName, 'Panadol Extra');
      expect(result.transfer.note, 'Test request');
      expect(await _onHand(t.inventoryRepo, _dha, _panadol), before);
      expect(await t.layer.pendingSyncCount(), beforeSync + 1);
      final entries = await t.audit.entries(action: 'transfer.requested');
      expect(entries, hasLength(1));
    });

    test('request validation: same branch, empty lines, bad medicine, zero qty',
        () async {
      final t = _layer();
      await expectLater(
        t.layer.createTransfer(
          fromBranchId: _dha,
          toBranchId: _dha,
          items: const [
            TransferItem(
              medicineId: _panadol,
              medicineName: 'Panadol Extra',
              quantity: 1,
            ),
          ],
        ),
        throwsArgumentError,
      );
      await expectLater(
        t.layer.createTransfer(
          fromBranchId: _dha,
          toBranchId: _glb,
          items: const [],
        ),
        throwsArgumentError,
      );
      await expectLater(
        t.layer.createTransfer(
          fromBranchId: _dha,
          toBranchId: _glb,
          items: const [
            TransferItem(
              medicineId: 'med-nope',
              medicineName: 'Nope',
              quantity: 1,
            ),
          ],
        ),
        throwsArgumentError,
      );
      await expectLater(
        t.layer.createTransfer(
          fromBranchId: _dha,
          toBranchId: _glb,
          items: const [
            TransferItem(
              medicineId: _panadol,
              medicineName: 'Panadol Extra',
              quantity: 0,
            ),
          ],
        ),
        throwsArgumentError,
      );
    });

    test('request retry with the same key returns the original', () async {
      final t = _layer();
      const key = 'transfer-test-dup-1';
      final first = await t.layer.createTransfer(
        fromBranchId: _dha,
        toBranchId: _glb,
        items: const [
          TransferItem(
            medicineId: _panadol,
            medicineName: 'Panadol Extra',
            quantity: 5,
          ),
        ],
        idempotencyKey: key,
      );
      final second = await t.layer.createTransfer(
        fromBranchId: _dha,
        toBranchId: _glb,
        items: const [
          TransferItem(
            medicineId: _panadol,
            medicineName: 'Panadol Extra',
            quantity: 5,
          ),
        ],
        idempotencyKey: key,
      );
      expect(second.isDuplicate, isTrue);
      expect(second.transfer.id, first.transfer.id);
      final all = await t.transferRepo.getTransfers();
      // 3 seeded + 1 created (the retry created nothing).
      expect(all.length, 4);
    });

    test('approve / reject / cancel follow the status order', () async {
      final t = _layer();
      final created = await t.layer.createTransfer(
        fromBranchId: _dha,
        toBranchId: _glb,
        items: const [
          TransferItem(
            medicineId: _panadol,
            medicineName: 'Panadol Extra',
            quantity: 5,
          ),
        ],
        actorId: 'demo-owner',
      );
      // The requester cannot approve their own transfer (SRS §5.2).
      await expectLater(
        t.layer.approveTransfer(
          created.transfer.id,
          actorId: 'demo-owner',
        ),
        throwsArgumentError,
      );
      final approved = await t.layer.approveTransfer(
        created.transfer.id,
        actorId: 'demo-branch_manager',
        actorName: 'Branch Manager',
      );
      expect(approved.status, StockTransferStatus.approved);
      expect(approved.approvedBy, 'Branch Manager');
      // An Approved transfer can no longer be rejected…
      await expectLater(
        t.layer.rejectTransfer(created.transfer.id),
        throwsArgumentError,
      );
      // …but it can be cancelled.
      final cancelled = await t.layer.cancelTransfer(
        created.transfer.id,
        actorId: 'demo-owner',
      );
      expect(cancelled.status, StockTransferStatus.cancelled);
      // A Cancelled transfer cannot be approved or cancelled again.
      await expectLater(
        t.layer.approveTransfer(
          created.transfer.id,
          actorId: 'demo-branch_manager',
        ),
        throwsArgumentError,
      );
      await expectLater(
        t.layer.cancelTransfer(created.transfer.id),
        throwsArgumentError,
      );

      final rejected = await t.layer.createTransfer(
        fromBranchId: _glb,
        toBranchId: _dha,
        items: const [
          TransferItem(
            medicineId: _panadol,
            medicineName: 'Panadol Extra',
            quantity: 5,
          ),
        ],
        actorId: 'demo-owner',
      );
      final rejectedTransfer = await t.layer.rejectTransfer(
        rejected.transfer.id,
        actorId: 'demo-branch_manager',
      );
      expect(rejectedTransfer.status, StockTransferStatus.rejected);
    });

    test('dispatch moves FEFO stock out of the source branch', () async {
      final t = _layer();
      final approved = await _approvedTransfer(t.layer);
      final beforeSource = await _onHand(t.inventoryRepo, _dha, _panadol);
      final beforeDest = await _onHand(t.inventoryRepo, _glb, _panadol);
      final dispatched = await t.layer.dispatchTransfer(
        transferId: approved.id,
        actorId: 'demo-inventory_manager',
        actorName: 'Inventory Manager',
      );
      expect(dispatched.isDuplicate, isFalse);
      expect(dispatched.transfer.status, StockTransferStatus.dispatched);
      expect(dispatched.transfer.dispatchedBy, 'Inventory Manager');
      final allocations = dispatched.transfer.dispatchAllocations;
      expect(
        allocations.fold(0, (sum, a) => sum + a.quantity),
        20,
      );
      expect(allocations.every((a) => a.batchNo.isNotEmpty), isTrue);
      expect(
        dispatched.movements.every(
          (m) => m.type == StockMovementType.transferOut && m.quantity < 0,
        ),
        isTrue,
      );
      expect(
        dispatched.movements.fold(0, (sum, m) => sum + m.quantity),
        -20,
      );
      expect(await _onHand(t.inventoryRepo, _dha, _panadol), beforeSource - 20);
      expect(await _onHand(t.inventoryRepo, _glb, _panadol), beforeDest);
      // A Requested transfer cannot dispatch; a Dispatched one cannot
      // dispatch again.
      final requested = await t.layer.createTransfer(
        fromBranchId: _dha,
        toBranchId: _glb,
        items: const [
          TransferItem(
            medicineId: _panadol,
            medicineName: 'Panadol Extra',
            quantity: 1,
          ),
        ],
      );
      await expectLater(
        t.layer.dispatchTransfer(transferId: requested.transfer.id),
        throwsArgumentError,
      );
      await expectLater(
        t.layer.dispatchTransfer(transferId: approved.id),
        throwsArgumentError,
      );
    });

    test('dispatch short of stock throws and holds nothing', () async {
      final t = _layer();
      final onHand = await _onHand(t.inventoryRepo, _dha, _panadol);
      final created = await t.layer.createTransfer(
        fromBranchId: _dha,
        toBranchId: _glb,
        items: [
          TransferItem(
            medicineId: _panadol,
            medicineName: 'Panadol Extra',
            quantity: onHand + 100,
          ),
        ],
        actorId: 'demo-owner',
      );
      await t.layer.approveTransfer(
        created.transfer.id,
        actorId: 'demo-branch_manager',
      );
      await expectLater(
        t.layer.dispatchTransfer(transferId: created.transfer.id),
        throwsArgumentError,
      );
      expect(await _onHand(t.inventoryRepo, _dha, _panadol), onHand);
      expect(t.engine.counterFor(_panadol).quantityReserved, 0);
      final stillApproved = await t.transferRepo.getById(
        created.transfer.id,
      );
      expect(stillApproved!.status, StockTransferStatus.approved);
    });

    test('dispatch retry with the same key moves no stock twice', () async {
      final t = _layer();
      final approved = await _approvedTransfer(t.layer);
      const key = 'transfer-dispatch-dup-1';
      final first = await t.layer.dispatchTransfer(
        transferId: approved.id,
        idempotencyKey: key,
      );
      final afterFirst = await _onHand(t.inventoryRepo, _dha, _panadol);
      final second = await t.layer.dispatchTransfer(
        transferId: approved.id,
        idempotencyKey: key,
      );
      expect(second.isDuplicate, isTrue);
      expect(second.movements, isEmpty);
      expect(second.transfer.id, first.transfer.id);
      expect(await _onHand(t.inventoryRepo, _dha, _panadol), afterFirst);
    });

    test('receive creates destination batches and closes the transfer',
        () async {
      final t = _layer();
      final approved = await _approvedTransfer(t.layer);
      final dispatched = await t.layer.dispatchTransfer(
        transferId: approved.id,
      );
      final beforeDest = await _onHand(t.inventoryRepo, _glb, _panadol);
      final destBatchesBefore = (await t.inventoryRepo.getInventory(
        branchId: _glb,
      )).where((row) => row.medicineId == _panadol).length;
      final received = await t.layer.receiveTransfer(
        transferId: approved.id,
        actorId: 'demo-branch_manager',
        actorName: 'Branch Manager',
      );
      expect(received.isDuplicate, isFalse);
      expect(received.transfer.status, StockTransferStatus.received);
      expect(received.transfer.receivedBy, 'Branch Manager');
      expect(
        received.movements.every(
          (m) => m.type == StockMovementType.transferIn && m.quantity > 0,
        ),
        isTrue,
      );
      expect(
        received.movements.fold(0, (sum, m) => sum + m.quantity),
        20,
      );
      expect(await _onHand(t.inventoryRepo, _glb, _panadol), beforeDest + 20);
      final destBatchesAfter = (await t.inventoryRepo.getInventory(
        branchId: _glb,
      )).where((row) => row.medicineId == _panadol).toList();
      expect(destBatchesAfter.length, greaterThan(destBatchesBefore));
      // The new destination batch keeps the source batch number.
      final sourceBatchNos = {
        for (final a in dispatched.transfer.dispatchAllocations) a.batchNo,
      };
      expect(
        destBatchesAfter.any((row) => sourceBatchNos.contains(row.batchNo)),
        isTrue,
      );
      // A Received transfer cannot receive or dispatch again.
      await expectLater(
        t.layer.receiveTransfer(transferId: approved.id),
        throwsArgumentError,
      );
      await expectLater(
        t.layer.dispatchTransfer(transferId: approved.id),
        throwsArgumentError,
      );
    });

    test('receive retry with the same key creates no second batch set',
        () async {
      final t = _layer();
      final approved = await _approvedTransfer(t.layer);
      await t.layer.dispatchTransfer(transferId: approved.id);
      const key = 'transfer-receive-dup-1';
      final first = await t.layer.receiveTransfer(
        transferId: approved.id,
        idempotencyKey: key,
      );
      final afterFirst = await _onHand(t.inventoryRepo, _glb, _panadol);
      final second = await t.layer.receiveTransfer(
        transferId: approved.id,
        idempotencyKey: key,
      );
      expect(second.isDuplicate, isTrue);
      expect(second.movements, isEmpty);
      expect(second.transfer.id, first.transfer.id);
      expect(await _onHand(t.inventoryRepo, _glb, _panadol), afterFirst);
    });

    test('seeded transfers cover Requested / Dispatched / Received',
        () async {
      final t = _layer();
      final all = await t.transferRepo.getTransfers();
      expect(
        all.map((transfer) => transfer.status).toSet(),
        containsAll([
          StockTransferStatus.requested,
          StockTransferStatus.dispatched,
          StockTransferStatus.received,
        ]),
      );
      expect(all.every((transfer) => transfer.isDemo), isTrue);
      final dha = await t.transferRepo.getTransfers(branchId: _dha);
      // Every seeded transfer touches DHA (source or destination).
      expect(dha.length, all.length);
    });
  });

  group('Rider assignment (layer, D121)', () {
    test('assign sets the order rider and the rider live order together',
        () async {
      final t = _layer();
      final order = await _unassignedDeliveryOrder(t.orderRepo);
      final updated = await t.layer.assignRider(
        orderId: order.id,
        riderId: 'rider-1',
        actorId: 'demo-owner',
        actorName: 'Owner',
      );
      expect(updated.riderId, 'rider-1');
      final rider = await t.riderRepo.getById('rider-1');
      expect(rider!.currentOrderId, order.id);
      final entries = await t.audit.entries(action: 'order.rider_assigned');
      expect(entries, hasLength(1));
    });

    test('reassign clears the old rider; unassign clears both', () async {
      final t = _layer();
      final order = await _unassignedDeliveryOrder(t.orderRepo);
      await t.layer.assignRider(orderId: order.id, riderId: 'rider-1');
      await t.layer.assignRider(orderId: order.id, riderId: 'rider-2');
      expect((await t.riderRepo.getById('rider-1'))!.currentOrderId, isNull);
      expect(
        (await t.riderRepo.getById('rider-2'))!.currentOrderId,
        order.id,
      );
      final cleared = await t.layer.assignRider(
        orderId: order.id,
        riderId: null,
      );
      expect(cleared.riderId, isNull);
      expect((await t.riderRepo.getById('rider-2'))!.currentOrderId, isNull);
    });

    test('assign guards: inactive, cross-branch, busy, pickup, delivered',
        () async {
      final t = _layer();
      final order = await _unassignedDeliveryOrder(t.orderRepo);
      // Inactive rider.
      await expectLater(
        t.layer.assignRider(orderId: order.id, riderId: 'rider-4'),
        throwsArgumentError,
      );
      // Rider from the other branch.
      await expectLater(
        t.layer.assignRider(orderId: order.id, riderId: 'rider-3'),
        throwsArgumentError,
      );
      // Unknown rider / unknown order.
      await expectLater(
        t.layer.assignRider(orderId: order.id, riderId: 'rider-nope'),
        throwsArgumentError,
      );
      await expectLater(
        t.layer.assignRider(orderId: 'order-nope', riderId: 'rider-1'),
        throwsArgumentError,
      );
      // Busy rider: already out on another order.
      final orders = await t.orderRepo.getOrders(branchId: _dha);
      final second = orders.firstWhere(
        (candidate) =>
            candidate.id != order.id &&
            candidate.fulfillment == FulfillmentType.delivery &&
            candidate.riderId == null &&
            candidate.status != OrderStatus.delivered &&
            candidate.status != OrderStatus.cancelled,
      );
      await t.layer.assignRider(orderId: order.id, riderId: 'rider-1');
      await expectLater(
        t.layer.assignRider(orderId: second.id, riderId: 'rider-1'),
        throwsArgumentError,
      );
      // Pickup order.
      final pickup = orders.firstWhere(
        (candidate) => candidate.fulfillment == FulfillmentType.pickup,
      );
      await expectLater(
        t.layer.assignRider(orderId: pickup.id, riderId: 'rider-1'),
        throwsArgumentError,
      );
      // Delivered order.
      await t.orderRepo.updateStatus(order.id, OrderStatus.delivered);
      await expectLater(
        t.layer.assignRider(orderId: order.id, riderId: 'rider-2'),
        throwsArgumentError,
      );
    });
  });

  group('Transfer gates + validation (pure, D118)', () {
    test('stockTransfer matrix row follows SRS §5.1', () {
      final row = rolePermissionMatrix['stockTransfer']!;
      expect(row[demoRoles.indexOf('Owner')], RolePermission.allowed);
      expect(row[demoRoles.indexOf('HO Admin')], RolePermission.allowed);
      expect(
        row[demoRoles.indexOf('Regional Mgr')],
        RolePermission.allowed,
      );
      expect(row[demoRoles.indexOf('Branch Mgr')], RolePermission.own);
      expect(row[demoRoles.indexOf('Pharmacist')], RolePermission.none);
      expect(row[demoRoles.indexOf('Cashier')], RolePermission.none);
      expect(row[demoRoles.indexOf('Inventory Mgr')], RolePermission.own);
      expect(row[demoRoles.indexOf('Accountant')], RolePermission.none);
      expect(row[demoRoles.indexOf('Auditor')], RolePermission.readOnly);
      expect(
        roleCapabilities.any(
          (capability) => capability.key == 'stockTransfer',
        ),
        isTrue,
      );
    });

    test('canView / canWrite follow the matrix per role', () async {
      final auth = MockAuthRepository();
      final owner = await auth.signInAsDemo(DemoRole.owner);
      final manager = await auth.signInAsDemo(DemoRole.branchManager);
      final pharmacist = await auth.signInAsDemo(DemoRole.pharmacist);
      final inventoryManager =
          await auth.signInAsDemo(DemoRole.inventoryManager);
      expect(canViewTransfers(owner, _dha), isTrue);
      expect(canWriteTransfer(owner, _dha), isTrue);
      expect(canViewTransfers(manager, _dha), isTrue);
      expect(canWriteTransfer(manager, _dha), isTrue);
      expect(canViewTransfers(pharmacist, _dha), isFalse);
      expect(canWriteTransfer(pharmacist, _dha), isFalse);
      // The demo Inventory Manager's home branch is Gulberg, not
      // DHA — `own` scope means she may write there, not here.
      expect(canWriteTransfer(inventoryManager, _glb), isTrue);
      expect(canWriteTransfer(inventoryManager, _dha), isFalse);
      // Same for the Branch Manager (home branch DHA).
      expect(canWriteTransfer(manager, _glb), isFalse);
      // Auditor: read-only — may view, never write.
      const auditor = AppUser(
        uid: 'demo-auditor',
        email: 'auditor@demo.pharmadesk',
        displayName: 'Auditor',
        orgId: _org,
        branchIds: [_dha],
        roleKey: 'auditor',
      );
      expect(canViewTransfers(auditor, _dha), isTrue);
      expect(canWriteTransfer(auditor, _dha), isFalse);
      // Route gating: the transfer routes carry the capability.
      expect(routeCapability('/inventory/transfers'), 'stockTransfer');
      expect(
        routeCapability('/inventory/transfers/new'),
        'stockTransfer',
      );
      expect(routeCapability('/inventory'), isNull);
      expect(routeCapability('/riders'), isNull);
    });

    test('validateTransferRequest catches the bad requests', () {
      const items = [
        TransferItem(
          medicineId: _panadol,
          medicineName: 'Panadol Extra',
          quantity: 5,
        ),
      ];
      expect(
        validateTransferRequest(
          fromBranchId: _dha,
          toBranchId: _dha,
          items: items,
        ),
        contains('different branches'),
      );
      expect(
        validateTransferRequest(
          fromBranchId: _dha,
          toBranchId: _glb,
          items: const [],
        ),
        contains('at least one medicine'),
      );
      expect(
        validateTransferRequest(
          fromBranchId: _dha,
          toBranchId: _glb,
          items: const [
            TransferItem(
              medicineId: _panadol,
              medicineName: 'Panadol Extra',
              quantity: 0,
            ),
          ],
        ),
        contains('above zero'),
      );
      expect(
        validateTransferRequest(
          fromBranchId: _dha,
          toBranchId: _glb,
          items: items,
        ),
        isNull,
      );
    });

    test('rider availability derives from active + live order', () {
      expect(riderAvailability(demoRiders[0]), RiderAvailability.available);
      expect(riderAvailability(demoRiders[3]), RiderAvailability.inactive);
      expect(
        riderAvailability(
          demoRiders[0].copyWith(currentOrderId: 'ord-dha-1001'),
        ),
        RiderAvailability.onDelivery,
      );
      expect(
        canAssignRiderToOrder(
          demoRiders[3],
          const Order(
            id: 'ord-test',
            customerId: 'walk-in',
            branchId: _dha,
            items: [],
            deliveryAddress: 'Test address',
            fulfillment: FulfillmentType.delivery,
            status: OrderStatus.newOrder,
            totalAmount: 0,
          ),
        ),
        isFalse,
      );
    });

    test('transfer mapper round-trips through Firestore shape', () {
      const transfer = StockTransfer(
        id: 'tr-test-1',
        transferNumber: 'TR-DHA-GLB-1001',
        fromBranchId: _dha,
        toBranchId: _glb,
        status: StockTransferStatus.dispatched,
        items: [
          TransferItem(
            medicineId: _panadol,
            medicineName: 'Panadol Extra',
            quantity: 20,
          ),
        ],
        requestedBy: 'demo-owner',
        approvedBy: 'demo-branch_manager',
        dispatchedBy: 'demo-inventory_manager',
        dispatchAllocations: [
          TransferAllocation(
            medicineId: _panadol,
            batchId: 'inv-DHA-1',
            batchNo: 'DHA-1-1-100',
            quantity: 20,
            unitCostMinor: 10000,
          ),
        ],
        isDemo: true,
      );
      final doc = stockTransferToFirestore(transfer, orgId: _org);
      expect(
        FirestoreSchema.validateDocument(
          'branches/{branchId}/stockTransfers',
          doc,
        ),
        isEmpty,
      );
      final back = stockTransferFromFirestore('tr-test-1', doc);
      expect(back.transferNumber, 'TR-DHA-GLB-1001');
      expect(back.status, StockTransferStatus.dispatched);
      expect(back.items.single.quantity, 20);
      expect(back.dispatchAllocations.single.batchNo, 'DHA-1-1-100');
      expect(back.isDemo, isTrue);
    });
  });

  group('Firestore transfer + rider repos (fake transport, D118/D121)',
      () {
    test('transfer create numbers, reads both directions, updates', () async {
      final transport = _FakeFirestoreTransport();
      await transport.setDocument('branches/$_dha', {
        'name': 'Demo Branch — DHA',
        'code': 'DHA',
        'organizationId': _org,
      });
      await transport.setDocument('branches/$_glb', {
        'name': 'Demo Branch — Gulberg',
        'code': 'GLB',
        'organizationId': _org,
      });
      final repo = FirestoreStockTransferRepository(
        transport: transport,
        organizationId: _org,
      );
      final created = await repo.createTransfer(
        const StockTransfer(
          id: 'tr-fake-1',
          transferNumber: '',
          fromBranchId: _dha,
          toBranchId: _glb,
          status: StockTransferStatus.requested,
          items: [
            TransferItem(
              medicineId: _panadol,
              medicineName: 'Panadol Extra',
              quantity: 5,
            ),
          ],
        ),
      );
      expect(created.transferNumber, 'TR-DHA-GLB-1001');
      // Same id again returns the original (D65 pattern).
      final again = await repo.createTransfer(
        const StockTransfer(
          id: 'tr-fake-1',
          transferNumber: '',
          fromBranchId: _dha,
          toBranchId: _glb,
          status: StockTransferStatus.requested,
          items: [
            TransferItem(
              medicineId: _panadol,
              medicineName: 'Panadol Extra',
              quantity: 5,
            ),
          ],
        ),
      );
      expect(again.id, created.id);
      expect(again.transferNumber, 'TR-DHA-GLB-1001');
      final byId = await repo.getById('tr-fake-1');
      expect(byId!.status, StockTransferStatus.requested);
      // Destination-branch read finds it too (it lives under DHA).
      final atGlb = await repo.getTransfers(branchId: _glb);
      expect(atGlb.map((t) => t.id), contains('tr-fake-1'));
      final atDha = await repo.getTransfers(branchId: _dha);
      expect(atDha.map((t) => t.id), contains('tr-fake-1'));
      await repo.updateTransfer(
        byId.copyWith(status: StockTransferStatus.approved),
      );
      expect(
        (await repo.getById('tr-fake-1'))!.status,
        StockTransferStatus.approved,
      );
    });

    test('rider updateRider round-trips the live order', () async {
      final transport = _FakeFirestoreTransport();
      await transport.setDocument('branches/$_dha', {
        'name': 'Demo Branch — DHA',
        'code': 'DHA',
        'organizationId': _org,
      });
      await transport.setDocument('branches/$_glb', {
        'name': 'Demo Branch — Gulberg',
        'code': 'GLB',
        'organizationId': _org,
      });
      final repo = FirestoreRiderRepository(
        transport: transport,
        organizationId: _org,
      );
      const rider = Rider(
        id: 'rider-fake-1',
        name: 'Test Rider',
        phone: '0300-0000000',
        branchId: _dha,
      );
      await transport.setDocument(
        'branches/$_dha/riders/rider-fake-1',
        riderToFirestore(rider, orgId: _org, branchId: _dha),
      );
      await repo.updateRider(rider.copyWith(currentOrderId: 'ord-dha-1'));
      expect(
        (await repo.getById('rider-fake-1'))!.currentOrderId,
        'ord-dha-1',
      );
      await expectLater(
        repo.updateRider(
          rider.copyWith(id: 'rider-nope'),
        ),
        throwsArgumentError,
      );
    });
  });

  group('Screens + routes (widget)', () {
    testWidgets('all five new routes resolve to their screens', (
      tester,
    ) async {
      final (router, _) = await _pumpRouterApp(tester);
      final cases = <String, String>{
        '/inventory/transfers': 'Stock Transfers',
        '/inventory/transfers/new': 'New Transfer',
        '/inventory/transfers/tr-demo-1': 'TR-DHA-GLB-1001',
        '/riders': 'Riders & Delivery',
        '/riders/rider-1': 'Bilal Ahmed',
      };
      for (final entry in cases.entries) {
        router.go(entry.key);
        await tester.pumpAndSettle();
        expect(
          find.text(entry.value),
          findsWidgets,
          reason: '${entry.key} should show "${entry.value}"',
        );
        expect(find.text('Page not found'), findsNothing);
      }
    });

    testWidgets('seeded transfers + riders render labelled demo/sample', (
      tester,
    ) async {
      final (router, _) = await _pumpRouterApp(tester);
      router.go('/inventory/transfers');
      await tester.pumpAndSettle();
      expect(find.text('TR-DHA-GLB-1001'), findsOneWidget);
      expect(find.text('TR-GLB-DHA-1002'), findsOneWidget);
      expect(find.text('TR-DHA-GLB-1003'), findsOneWidget);
      // Status labels appear twice each — once as a filter chip,
      // once as the row badge.
      expect(find.text('Requested'), findsWidgets);
      expect(find.text('Dispatched'), findsWidgets);
      expect(find.text('Received'), findsWidgets);
      expect(find.text('Demo'), findsWidgets);
      router.go('/riders');
      await tester.pumpAndSettle();
      expect(find.text('Bilal Ahmed'), findsOneWidget);
      expect(find.text('Usman Khalid'), findsOneWidget);
      expect(find.text('Ahmed Nawaz'), findsOneWidget);
      expect(find.text('Zahid Hussain'), findsOneWidget);
      expect(find.text('Available'), findsWidgets);
      // 'Inactive' is a filter chip as well as a row badge.
      expect(find.text('Inactive'), findsWidgets);
    });

    testWidgets('seeded transfer detail is read-only sample data', (
      tester,
    ) async {
      final (router, _) = await _pumpRouterApp(tester);
      router.go('/inventory/transfers/tr-demo-1');
      await tester.pumpAndSettle();
      expect(find.text('TR-DHA-GLB-1001'), findsOneWidget);
      expect(find.text('Demo — sample record'), findsOneWidget);
      expect(find.text('Approve'), findsNothing);
      expect(find.text('Dispatch — move stock out'), findsNothing);
    });

    testWidgets('pharmacist is stopped at the transfer route', (
      tester,
    ) async {
      final (router, _) = await _pumpRouterApp(
        tester,
        role: DemoRole.pharmacist,
      );
      router.go('/inventory/transfers');
      await tester.pumpAndSettle();
      expect(find.text('No permission for Inventory'), findsOneWidget);
      expect(find.textContaining('stockTransfer'), findsOneWidget);
      // The same role still reaches the riders screens (no §5.1
      // capability governs rider viewing).
      router.go('/riders');
      await tester.pumpAndSettle();
      expect(find.text('Riders & Delivery'), findsWidgets);
    });

    testWidgets('sidebar carries both entries at desktop width', (
      tester,
    ) async {
      final (_, _) = await _pumpRouterApp(tester);
      expect(find.text('Stock Transfers'), findsOneWidget);
      expect(find.text('Riders & Delivery'), findsOneWidget);
    });

    testWidgets('transfer form creates a transfer end to end', (
      tester,
    ) async {
      final (router, _) = await _pumpRouterApp(tester);
      router.go('/inventory/transfers/new');
      await tester.pumpAndSettle();
      expect(find.text('New Transfer'), findsOneWidget);
      // Pick the first medicine with sellable source stock.
      final firstCheckbox = find.byType(Checkbox).first;
      expect(firstCheckbox, findsOneWidget);
      await tester.tap(firstCheckbox);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Request Transfer'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Request Transfer'));
      await tester.pumpAndSettle();
      // Lands on the new transfer's detail screen.
      expect(find.textContaining('TR-DHA-GLB-'), findsOneWidget);
      expect(find.text('Requested'), findsOneWidget);
      expect(find.text('Approve'), findsOneWidget);
    });

    testWidgets('order detail assigns a rider through the dialog', (
      tester,
    ) async {
      final (router, container) = await _pumpRouterApp(tester);
      final orders = await container
          .read(orderRepositoryProvider)
          .getOrders(branchId: _dha);
      final order = orders.firstWhere(
        (candidate) =>
            candidate.fulfillment == FulfillmentType.delivery &&
            candidate.riderId == null &&
            candidate.status != OrderStatus.delivered &&
            candidate.status != OrderStatus.cancelled,
      );
      router.go('/orders/${order.id}');
      await tester.pumpAndSettle();
      expect(find.text('Assign Rider'), findsOneWidget);
      await tester.ensureVisible(find.text('Assign Rider'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Assign Rider'));
      await tester.pumpAndSettle();
      expect(find.text('Assign rider'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('assign-rider-rider-1')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Rider assigned to order'), findsOneWidget);
      final updated = await container
          .read(orderRepositoryProvider)
          .getById(order.id);
      expect(updated!.riderId, 'rider-1');
      final rider = await container.read(riderRepositoryProvider).getById(
        'rider-1',
      );
      expect(rider!.currentOrderId, order.id);
    });
  });
}

/// Pumps the ungated router app with a fresh container the test owns
/// (same harness as the Week 4 Day 1 widget tests), signed in as
/// [role] (Owner by default).
Future<(GoRouter, ProviderContainer)> _pumpRouterApp(
  WidgetTester tester, {
  DemoRole role = DemoRole.owner,
  Size size = const Size(1920, 1080),
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final container = ProviderContainer();
  addTearDown(container.dispose);
  await container.read(authProvider.notifier).signInAsDemo(role);
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
  return (router, container);
}

/// Minimal map-backed fake transport (same shape as the
/// Week 3 Day 1 fake — in-memory docs, counters via transactions).
class _FakeFirestoreTransport implements FirestoreTransport {
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
    var found = [
      for (final entry in entries)
        FirestoreDocument(
          id: entry.key.split('/').last,
          data: Map<String, dynamic>.from(entry.value),
        ),
    ]..sort((a, b) => a.id.compareTo(b.id));
    if (startAfterId != null) {
      final index = found.indexWhere((doc) => doc.id == startAfterId);
      if (index != -1) found = found.sublist(index + 1);
    }
    if (limit != null && found.length > limit) {
      found = found.sublist(0, limit);
    }
    return found;
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
    final id = 'auto-${++_autoId}';
    await setDocument('$collectionPath/$id', data);
    return id;
  }

  @override
  Future<void> runBatchedWrites(List<WriteOperation> operations) async {
    for (final operation in operations) {
      switch (operation.kind) {
        case WriteOperationKind.set:
          await setDocument(operation.path, operation.data ?? {});
        case WriteOperationKind.update:
          await updateDocument(operation.path, operation.data ?? {});
        case WriteOperationKind.delete:
          docs.remove(operation.path);
      }
    }
  }

  @override
  Future<T> runTransaction<T>(
    Future<T> Function(FirestoreTransaction tx) action,
  ) async {
    return action(_FakeFirestoreTransaction(this));
  }

  @override
  String newDocumentId(String collectionPath) => 'auto-${++_autoId}';
}

class _FakeFirestoreTransaction implements FirestoreTransaction {
  _FakeFirestoreTransaction(this.transport);

  final _FakeFirestoreTransport transport;

  @override
  Future<Map<String, dynamic>?> get(String path) =>
      transport.getDocument(path);

  @override
  void set(String path, Map<String, dynamic> data, {bool merge = false}) {
    if (merge && transport.docs.containsKey(path)) {
      transport.docs[path] = {...transport.docs[path]!, ...data};
    } else {
      transport.docs[path] = Map<String, dynamic>.from(data);
    }
  }

  @override
  void update(String path, Map<String, dynamic> data) {
    final existing = transport.docs[path];
    if (existing == null) {
      throw StateError('No document at $path to update.');
    }
    transport.docs[path] = {...existing, ...data};
  }
}
