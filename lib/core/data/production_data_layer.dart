import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/customer_ledger.dart';
import '../../models/order.dart';
import '../../models/sale.dart';
import '../services/repositories.dart';
import 'audit_log.dart';
import 'backup_export.dart';
import 'firestore_schema.dart';
import 'inventory_engine.dart';
import 'sync_queue.dart';
import 'sync_store.dart';

/// Production data layer (Week 2 Day 1, SRS Phase 6 adapted).
///
/// Wraps the existing repository interfaces and becomes the WRITE path
/// for POS sale completion and order creation. Screens do not change:
/// the notifiers call this layer instead of the repositories directly,
/// and the layer does the production work around the same mock writes:
///
/// 1. **Idempotency** — the sale/order's client key is the Firestore
///    document id (SRS §2.5). A commit retried with the same key
///    returns the original sale/order and moves NO stock or money.
/// 2. **Stock reservation** — the engine reserves FEFO batches, the
///    sale is saved, then the reservation is confirmed (stock
///    decremented + ledger entries + audit). On any failure the
///    reservation is released, so a failed sale never holds stock.
/// 3. **Audit** — every stock/money mutation leaves an audit entry.
/// 4. **Sync queue** — every committed write is enqueued as one
///    batched-write payload (chunked at ≤500 ops) for the future
///    Firestore sync; on the web the queue is in-memory only.
///
/// Until the Firebase project exists there is NO cloud write: the
/// "sync" side only enqueues. The Firestore implementation (Week 2
/// Day 2+) executes the same batched-write payloads against Firestore
/// in one transaction per chunk.
///
/// ACTOR IDENTITY: `actorId` / `actorName` default to the demo
/// placeholder (`demo-user` / `Demo staff`). Day 9 wires the real
/// Firebase Auth uid + display name through; audit entries already
/// carry the actor fields, so nothing else changes.

/// Demo placeholder actor (no Firebase Auth yet — D13).
const demoActorId = 'demo-user';
const demoActorName = 'Demo staff';

/// Result of [ProductionDataLayer.commitSale].
class SaleCommitResult {
  const SaleCommitResult({
    required this.sale,
    required this.isDuplicate,
    required this.movements,
  });

  /// The saved sale (the original, when [isDuplicate] is true).
  final Sale sale;

  /// True when this key was already committed: no stock or money moved.
  final bool isDuplicate;

  /// Stock ledger movements written by the confirmation (empty on a
  /// duplicate — the original commit already wrote them).
  final List<StockMovement> movements;
}

/// Result of [ProductionDataLayer.createOrder].
class OrderCreateResult {
  const OrderCreateResult({required this.order, required this.isDuplicate});

  final Order order;
  final bool isDuplicate;
}

class ProductionDataLayer {
  ProductionDataLayer({
    required this.organizationId,
    required this.inventoryRepo,
    required this.saleRepo,
    required this.orderRepo,
    required this.customerRepo,
    required this.medicineRepo,
    required this.supplierRepo,
    required this.prescriptionRepo,
    required this.purchaseOrderRepo,
    required this.riderRepo,
    required this.audit,
    required this.syncQueue,
    required this.engine,
  });

  final String organizationId;
  final InventoryRepository inventoryRepo;
  final SaleRepository saleRepo;
  final OrderRepository orderRepo;
  final CustomerRepository customerRepo;
  final MedicineRepository medicineRepo;
  final SupplierRepository supplierRepo;
  final PrescriptionRepository prescriptionRepo;
  final PurchaseOrderRepository purchaseOrderRepo;
  final RiderRepository riderRepo;
  final AuditLogWriter audit;
  final SyncQueue syncQueue;
  final InventoryEngine engine;

  /// Committed sales by idempotency key (the local dedupe registry;
  /// Firestore enforces the same by document id).
  final Map<String, Sale> _committedSaleKeys = {};

  /// Committed orders by idempotency key.
  final Map<String, Order> _committedOrderKeys = {};

  /// Restore target for backup imports (see `backup_export.dart`).
  final InMemoryRestoreSink _restoreSink = InMemoryRestoreSink();

  InMemoryRestoreSink get restoredData => _restoreSink;

  /// Commits a POS sale end to end.
  ///
  /// [sale] is the sale built by `buildSale` (its `idempotencyKey` is
  /// the dedupe key); [decrements] are the FEFO batch chunks from
  /// `allocateFefo`. [creditLedgerEntry] is appended to the customer's
  /// khata for a credit sale (its `referenceId` is set to the saved
  /// sale id here).
  ///
  /// Duplicate commit (same key): returns the original sale with
  /// [SaleCommitResult.isDuplicate] true — stock is NOT decremented a
  /// second time and no second audit/sync entry is written.
  Future<SaleCommitResult> commitSale({
    required Sale sale,
    required List<({String batchId, int quantity})> decrements,
    String actorId = demoActorId,
    String actorName = demoActorName,
    LedgerEntry? creditLedgerEntry,
  }) async {
    final key = sale.idempotencyKey;
    if (!FirestoreSchema.isValidIdempotencyKey(key)) {
      throw ArgumentError('Sale has no valid idempotency key.');
    }
    final existing = _committedSaleKeys[key];
    if (existing != null) {
      await audit.write(
        AuditLogEntry.duplicateSale(
          organizationId: organizationId,
          branchId: sale.branchId,
          userId: actorId,
          actorName: actorName,
          saleId: existing.id,
          idempotencyKey: key,
        ),
      );
      return SaleCommitResult(
        sale: existing,
        isDuplicate: true,
        movements: const [],
      );
    }

    // Load the engine from live stock, then reserve the exact FEFO
    // batches the POS allocated. The reserve validates sellability
    // (expired-never-sellable guard, D30) and availability.
    final batches = await inventoryRepo.getInventory(branchId: sale.branchId);
    engine.loadBatches(batches);
    final reservations = engine.reserveBatches(
      branchId: sale.branchId,
      saleKey: key,
      decrements: decrements,
    );
    try {
      // Decrement the repository (the screens' source of truth).
      for (final decrement in decrements) {
        await inventoryRepo.adjustStock(
          batchId: decrement.batchId,
          deltaQty: -decrement.quantity,
          reason: 'POS sale',
        );
      }
      final saved = await saleRepo.createSale(sale);

      // Confirm the reservation: engine mirror + ledger + audit.
      final movements = await engine.confirm(
        reservations: reservations,
        saleId: saved.id,
        userId: actorId,
        actorName: actorName,
      );

      // Credit sale → khata entry, with audit.
      LedgerEntry? savedCreditEntry;
      if (creditLedgerEntry != null) {
        final entry = await customerRepo.addLedgerEntry(
          creditLedgerEntry.copyWith(
            referenceId: saved.id,
            reason: 'Credit sale ${saved.invoiceNumber}',
          ),
        );
        savedCreditEntry = entry;
        await audit.write(
          AuditLogEntry.moneyMovement(
            organizationId: organizationId,
            branchId: sale.branchId,
            userId: actorId,
            actorName: actorName,
            ledgerType: 'customerLedger',
            ledgerOwnerId: entry.customerId,
            entryKind: 'credit_sale',
            amountMinor: entry.amountMinor,
            balanceAfterMinor: entry.balanceAfterMinor,
            referenceId: saved.id,
          ),
        );
      }

      await audit.write(
        AuditLogEntry.saleCommitted(
          organizationId: organizationId,
          branchId: sale.branchId,
          userId: actorId,
          actorName: actorName,
          saleId: saved.id,
          invoiceNumber: saved.invoiceNumber,
          totalMinor: saved.totalMinor,
        ),
      );

      // Enqueue the Firestore batched write for the future sync.
      await _enqueueSaleSync(saved, movements, savedCreditEntry);

      _committedSaleKeys[key] = saved;
      return SaleCommitResult(
        sale: saved,
        isDuplicate: false,
        movements: movements,
      );
    } catch (error) {
      // A failed sale holds no stock: release the reservation.
      await engine.release(
        reservations: reservations,
        userId: actorId,
        actorName: actorName,
        reason: 'Sale failed: $error',
      );
      rethrow;
    }
  }

  /// Releases every open reservation held for one sale key (sale
  /// cancelled before payment).
  Future<void> releaseSaleReservations(
    String saleKey, {
    String actorId = demoActorId,
    String actorName = demoActorName,
    String reason = 'Sale cancelled',
  }) {
    return engine.releaseAllForSale(
      saleKey,
      userId: actorId,
      actorName: actorName,
      reason: reason,
    );
  }

  /// Creates an order through the production write path: idempotency
  /// dedupe, audit entry, sync enqueue. The order itself carries no
  /// idempotency key on the Day 0 model, so the caller passes one
  /// (generated per user intent — the same key on retry returns the
  /// original order); when omitted a fresh key is generated.
  Future<OrderCreateResult> createOrder({
    required Order order,
    String? idempotencyKey,
    String actorId = demoActorId,
    String actorName = demoActorName,
  }) async {
    final key = idempotencyKey ?? newIdempotencyKey('order-${order.branchId}');
    if (!FirestoreSchema.isValidIdempotencyKey(key)) {
      throw ArgumentError('Order idempotency key is not valid.');
    }
    final existing = _committedOrderKeys[key];
    if (existing != null) {
      return OrderCreateResult(order: existing, isDuplicate: true);
    }
    final saved = await orderRepo.createOrder(order);
    _committedOrderKeys[key] = saved;
    await audit.write(
      AuditLogEntry.create(
        organizationId: organizationId,
        branchId: order.branchId,
        userId: actorId,
        actorName: actorName,
        action: 'order.created',
        entityType: 'order',
        entityId: saved.id,
        summary:
            'Order ${saved.id} created (${order.items.length} items, '
            'total ${order.totalMinor} paisa)',
      ),
    );
    await syncQueue.enqueue(
      idempotencyKey: key,
      entityType: 'order',
      entityId: saved.id,
      branchId: order.branchId,
      organizationId: organizationId,
      kind: SyncOperationKind.create,
      payload: {
        'path': FirestoreSchema.orderDocPath(order.branchId, key),
        'document': _stamped(order.toMap(), order.branchId),
      },
    );
    return OrderCreateResult(order: saved, isDuplicate: false);
  }

  /// Adjusts one batch's quantity through the engine (validation +
  /// ledger + audit) and the repository (screens' source of truth).
  Future<StockMovement> adjustStock({
    required String batchId,
    required int deltaQty,
    required String reason,
    String actorId = demoActorId,
    String actorName = demoActorName,
    String? referenceId,
  }) async {
    final batch = (await inventoryRepo.getInventory()).firstWhere(
      (item) => item.id == batchId,
      orElse: () => throw ArgumentError('No batch with id "$batchId".'),
    );
    engine.loadBatches(
      await inventoryRepo.getInventory(branchId: batch.branchId),
    );
    final movement = await engine.adjust(
      batchId: batchId,
      deltaQty: deltaQty,
      reason: reason,
      userId: actorId,
      actorName: actorName,
      referenceId: referenceId,
    );
    await inventoryRepo.adjustStock(
      batchId: batchId,
      deltaQty: deltaQty,
      reason: reason,
    );
    return movement;
  }

  /// Audit entries (optionally filtered).
  Future<List<AuditLogEntry>> auditEntries({
    String? branchId,
    String? entityType,
    String? entityId,
    String? action,
  }) {
    return audit.entries(
      branchId: branchId,
      entityType: entityType,
      entityId: entityId,
      action: action,
    );
  }

  /// Pending sync operations (due now).
  Future<List<SyncOperation>> pendingSyncOperations() =>
      syncQueue.pendingOperations();

  Future<int> pendingSyncCount() => syncQueue.pendingCount();

  /// Attempts to drain the queue with [send] (the Firestore transport
  /// in production; a fake sender in tests). Returns how many ops
  /// synced.
  Future<int> processSyncQueue(
    Future<bool> Function(SyncOperation operation) send,
  ) {
    return syncQueue.processAll(send, audit: audit);
  }

  /// Full JSON backup (per-branch when [branchId] is given, org-wide
  /// otherwise). See `backup_export.dart`.
  Future<Map<String, dynamic>> exportBackup({String? branchId}) {
    return _exporter.exportAll(branchId: branchId);
  }

  Future<String> exportBackupJson({String? branchId}) {
    return _exporter.exportJson(branchId: branchId);
  }

  /// Downloads the backup as a JSON file on web (no-op elsewhere).
  Future<void> downloadBackup({String? branchId}) {
    return _exporter.downloadBackup(branchId: branchId);
  }

  /// Restores a backup document into the restore sink (see
  /// `backup_export.dart` for the policy). Returns the import report.
  ImportReport importBackup(
    Map<String, dynamic> json, {
    ImportPolicy policy = ImportPolicy.skipExisting,
  }) {
    return DataImporter().importBackup(json, _restoreSink, policy: policy);
  }

  DataExporter get _exporter => DataExporter(
    medicines: medicineRepo,
    orders: orderRepo,
    inventory: inventoryRepo,
    customers: customerRepo,
    sales: saleRepo,
    suppliers: supplierRepo,
    prescriptions: prescriptionRepo,
    purchaseOrders: purchaseOrderRepo,
    riders: riderRepo,
    audit: audit,
    syncQueue: syncQueue,
    organizationId: organizationId,
  );

  /// Builds the Firestore batched-write payload for a committed sale
  /// and enqueues it as one sync operation. The payload is the list of
  /// write operations (sale doc + items + inventory updates + stock
  /// transactions + khata entry), chunked at 500 ops by the batch
  /// abstraction — the future Firestore transport executes one chunk
  /// per real batched write.
  Future<void> _enqueueSaleSync(
    Sale saved,
    List<StockMovement> movements,
    LedgerEntry? creditLedgerEntry,
  ) async {
    final batch = LocalWriteBatch();
    final saleDoc = _stamped(saved.toMap(), saved.branchId);
    batch.set(
      FirestoreSchema.saleDocPath(saved.branchId, saved.idempotencyKey),
      saleDoc,
    );
    for (var i = 0; i < saved.items.length; i++) {
      batch.set(
        '${FirestoreSchema.saleItemsPath(saved.branchId, saved.idempotencyKey)}/item-$i',
        saved.items[i].toMap(),
      );
    }
    for (final movement in movements) {
      batch.set(
        '${FirestoreSchema.stockTransactionsPath(saved.branchId)}/${movement.id}',
        movement.toMap(),
      );
      batch.update(
        FirestoreSchema.inventoryDocPath(saved.branchId, movement.medicineId),
        {
          'quantityOnHand': engine
              .counterFor(movement.medicineId)
              .quantityOnHand,
          'quantityReserved': engine
              .counterFor(movement.medicineId)
              .quantityReserved,
          'updatedAt': DateTime.now().toIso8601String(),
        },
      );
    }
    if (creditLedgerEntry != null && saved.customerId != null) {
      batch.set(
        '${FirestoreSchema.customerLedgerPath(saved.branchId, saved.customerId!)}/${creditLedgerEntry.id}',
        creditLedgerEntry.toMap(),
      );
    }
    final chunks = batch.chunks();
    await syncQueue.enqueue(
      idempotencyKey: saved.idempotencyKey,
      entityType: 'sale',
      entityId: saved.id,
      branchId: saved.branchId,
      organizationId: organizationId,
      kind: SyncOperationKind.create,
      payload: {
        'path': FirestoreSchema.saleDocPath(
          saved.branchId,
          saved.idempotencyKey,
        ),
        'operations': batch.toMap()['operations'],
        'chunks': chunks.length,
        'operationCount': batch.operationCount,
      },
    );
  }

  /// Adds the common Firestore fields to a document map.
  Map<String, dynamic> _stamped(Map<String, dynamic> doc, String branchId) {
    return {
      ...doc,
      'organizationId': organizationId,
      'branchId': branchId,
      'createdAt': DateTime.now().toIso8601String(),
      'updatedAt': DateTime.now().toIso8601String(),
    };
  }
}

/// The production data layer for the app: wraps the (mock, for now)
/// repositories with the in-memory audit writer, the platform sync
/// store and the inventory engine. Screens and notifiers read this
/// provider — never construct the layer by hand in app code.
final productionDataLayerProvider = Provider<ProductionDataLayer>((ref) {
  final audit = InMemoryAuditLogWriter();
  final syncQueue = SyncQueue(createSyncStore());
  final engine = InventoryEngine(
    organizationId: demoOrganizationId,
    audit: audit,
  );
  return ProductionDataLayer(
    organizationId: demoOrganizationId,
    inventoryRepo: ref.read(inventoryRepositoryProvider),
    saleRepo: ref.read(saleRepositoryProvider),
    orderRepo: ref.read(orderRepositoryProvider),
    customerRepo: ref.read(customerRepositoryProvider),
    medicineRepo: ref.read(medicineRepositoryProvider),
    supplierRepo: ref.read(supplierRepositoryProvider),
    prescriptionRepo: ref.read(prescriptionRepositoryProvider),
    purchaseOrderRepo: ref.read(purchaseOrderRepositoryProvider),
    riderRepo: ref.read(riderRepositoryProvider),
    audit: audit,
    syncQueue: syncQueue,
    engine: engine,
  );
});
