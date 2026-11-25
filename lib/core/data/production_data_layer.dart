import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/customer_ledger.dart';
import '../../models/goods_receipt.dart';
import '../../models/inventory_item.dart';
import '../../models/order.dart';
import '../../models/purchase_order.dart';
import '../../models/sale.dart';
import '../../models/supplier_ledger.dart';
import '../../features/purchases/purchases_logic.dart';
import '../services/repositories.dart';
import 'audit_log.dart';
import 'backup_export.dart';
import 'firestore_mappers.dart';
import 'firestore_schema.dart';
import 'inventory_engine.dart';
import 'sync_queue.dart';
import 'sync_store.dart';

/// Production data layer (Week 2 Day 1, SRS Phase 6 adapted).
///
/// Wraps the existing repository interfaces and becomes the WRITE path
/// for POS sale completion, order creation and — since Week 3 Day 2
/// (D103) — goods receiving, and — since Week 3 Day 4 (D111) —
/// standalone stock receive / adjust (including returns restock,
/// which calls `adjustStock`), and — since Week 3 Day 5 (D114) —
/// stock counts. Screens do not change: the notifiers
/// call this layer instead of the repositories directly, and the
/// layer does the production work around the same mock writes:
///
/// 1. **Idempotency** — the sale/order/receipt client key is the
///    Firestore document id (SRS §2.5). A commit retried with the
///    same key returns the original sale/order/receipt and moves NO
///    stock or money.
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

/// Result of [ProductionDataLayer.receiveStock].
class StockReceiveResult {
  const StockReceiveResult({
    required this.batch,
    required this.movements,
    required this.isDuplicate,
  });

  /// The batch row the repository created (the original, when
  /// [isDuplicate] is true).
  final InventoryItem batch;

  /// Stock ledger movements the engine booked for the receive
  /// (empty on a duplicate — the original receive already wrote
  /// them).
  final List<StockMovement> movements;

  /// True when this key was already received: no stock moved a
  /// second time.
  final bool isDuplicate;
}
/// Result of [ProductionDataLayer.recordStockCount].
class StockCountResult {
  const StockCountResult({
    required this.item,
    required this.variance,
    required this.movement,
    required this.isDuplicate,
  });

  /// The batch row after the count (the original, when
  /// [isDuplicate] is true).
  final InventoryItem item;

  /// Counted quantity minus the system quantity before the count.
  final int variance;

  /// The engine movement booked for the correction — `null` when the
  /// count matched the system (variance 0: nothing to correct, so
  /// no ledger movement and no sync payload).
  final StockMovement? movement;

  /// True when this key was already counted: no stock moved twice.
  final bool isDuplicate;
}

class GoodsReceiptResult {
  const GoodsReceiptResult({
    required this.receipt,
    required this.order,
    required this.movements,
    required this.isDuplicate,
  });

  /// The saved goods receipt (the original, when [isDuplicate] is
  /// true).
  final GoodsReceipt receipt;

  /// The PO after this receiving step (the original's post-receive
  /// state, when [isDuplicate] is true).
  final PurchaseOrder order;

  /// Stock ledger movements written by the receive (empty on a
  /// duplicate — the original receive already wrote them).
  final List<StockMovement> movements;

  /// True when this key was already received: no stock or money
  /// moved a second time.
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
    GoodsReceiptRepository? goodsReceiptRepo,
    required this.audit,
    required this.syncQueue,
    required this.engine,
  }) : goodsReceiptRepo =
           goodsReceiptRepo ?? MockGoodsReceiptRepository();

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

  /// The goods-receipts store. Optional in the constructor so
  /// direct constructions (Week 2 Day 1 tests) keep working — they
  /// get a fresh mock; the app provider passes the bundle's repo,
  /// so the receipts the layer writes are the ones the app reads.
  final GoodsReceiptRepository goodsReceiptRepo;

  final AuditLogWriter audit;
  final SyncQueue syncQueue;
  final InventoryEngine engine;

  /// Committed sales by idempotency key (the local dedupe registry;
  /// Firestore enforces the same by document id).
  final Map<String, Sale> _committedSaleKeys = {};

  /// Committed orders by idempotency key.
  final Map<String, Order> _committedOrderKeys = {};

  /// Committed receiving events by idempotency key: the full
  /// result, so a duplicate retry returns the original receipt AND
  /// the PO state that receive produced.
  final Map<String, GoodsReceiptResult> _committedReceiptKeys = {};

  /// Committed standalone stock adjustments by idempotency key
  /// (Week 3 Day 4, D111): a retry with the same key returns the
  /// original movement instead of applying the delta twice.
  final Map<String, StockMovement> _committedAdjustKeys = {};

  /// Committed standalone stock receives by idempotency key
  /// (Week 3 Day 4, D111): a retry with the same key returns the
  /// original batch instead of creating a second batch row.
  final Map<String, StockReceiveResult> _committedReceiveKeys = {};

  /// Committed stock counts by idempotency key (Week 3 Day 5,
  /// D114): a retry with the same key returns the original count
  /// instead of applying the correction twice.
  final Map<String, StockCountResult> _committedCountKeys = {};

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

  /// Receives goods against a purchase order through the production
  /// write path (Week 3 Day 2, D103 — closes D95).
  ///
  /// The Day 7 receiving flow (per-line quantity, batch number,
  /// mfg/expiry, partial receiving) is unchanged for the user; what
  /// changes is WHERE the write happens. Before this, the purchases
  /// notifier wrote straight to the inventory / PO / supplier repos
  /// (the mock path only). Now the notifier calls this method and
  /// the layer is the single write path:
  ///
  /// 1. **Idempotency** — [idempotencyKey] (minted once per receiving
  ///    dialog submit, held across retries in the dialog) is the
  ///    receipt's document id. A retry with the same key returns the
  ///    original receipt and moves NO stock or money.
  /// 2. **Receipt document** — one `goodsReceipts` doc (+ its `items`
  ///    subcollection docs) for this delivery, via the
  ///    [GoodsReceiptRepository] interface (mock now, Firestore when
  ///    the bundle switches).
  /// 3. **Stock** — one batch per received line via the inventory
  ///    repo, booked into the engine (`receive` ledger movements +
  ///    audit, one per batch).
  /// 4. **Money** — the received value is charged to the supplier
  ///    ledger as a purchase entry (same as before).
  /// 5. **PO** — received quantities + Partially received / Received
  ///    status, via the PO repo.
  /// 6. **Audit + sync** — one audit entry for the receipt, and one
  ///    batched-write sync payload (receipt doc + items + batch docs
  ///    + stock transactions + ledger entry + PO update).
  ///
  /// Throws [ArgumentError] when the PO cannot receive, the lines
  /// fail validation, or the key is invalid — the caller (the
  /// purchases notifier) turns that into the error it already
  /// returns, and nothing is partially applied: validation runs
  /// before the first write.
  Future<GoodsReceiptResult> receiveGoods({
    required PurchaseOrder order,
    required List<ReceivingLine> lines,
    String? idempotencyKey,
    String actorId = demoActorId,
    String actorName = demoActorName,
  }) async {
    final key =
        idempotencyKey ?? newIdempotencyKey('receipt-${order.branchId}');
    if (!FirestoreSchema.isValidIdempotencyKey(key)) {
      throw ArgumentError('Receiving idempotency key is not valid.');
    }
    final existing = _committedReceiptKeys[key];
    if (existing != null) {
      await audit.write(
        AuditLogEntry.create(
          organizationId: organizationId,
          branchId: order.branchId,
          userId: actorId,
          actorName: actorName,
          action: 'goods.duplicate_receipt',
          entityType: 'goodsReceipt',
          entityId: existing.receipt.id,
          summary:
              'Duplicate receiving ignored for ${order.poNumber} '
              '(key $key) — original receipt ${existing.receipt.receiptNumber} kept.',
        ),
      );
      return GoodsReceiptResult(
        receipt: existing.receipt,
        order: existing.order,
        movements: const [],
        isDuplicate: true,
      );
    }
    // A receipt with this key already in the store but NOT in the
    // registry means a previous attempt wrote the receipt and then
    // failed before finishing (stock / PO / ledger): retrying the
    // same key would receive the stock a second time (the inventory
    // repo creates a new batch row per call). Fail loudly instead
    // of double-receiving — the receipt on file says what arrived.
    final orphan = await goodsReceiptRepo.getById(key);
    if (orphan != null) {
      throw StateError(
        'A previous receiving for ${order.poNumber} with this key '
        'did not complete (receipt ${orphan.receiptNumber} is on '
        'file). Check the receipt before receiving again.',
      );
    }
    if (!canReceivePo(order)) {
      throw ArgumentError(
        'This purchase order cannot receive goods in its current state.',
      );
    }
    final errors = validateReceiving(lines);
    if (errors.isNotEmpty) {
      throw ArgumentError(errors.first);
    }
    final receivedLines = lines
        .where((line) => line.quantityReceivedNow > 0)
        .toList();
    final receivedValueMinor = receivedLines.fold(
      0,
      (sum, line) => sum + line.quantityReceivedNow * line.item.unitCostMinor,
    );

    // The receipt documents this delivery (id = the idempotency key).
    final receipt = GoodsReceipt(
      id: key,
      poId: order.id,
      supplierId: order.supplierId,
      branchId: order.branchId,
      receivedBy: actorName,
      receivedAt: DateTime.now(),
      items: [
        for (final line in receivedLines)
          GoodsReceiptItem(
            medicineId: line.item.medicineId,
            medicineName: line.item.medicineName,
            quantityReceived: line.quantityReceivedNow,
            batchNo: line.batchNo.trim(),
            mfgDate: line.mfgDate!,
            expiryDate: line.expiryDate!,
            unitCostMinor: line.item.unitCostMinor,
          ),
      ],
    );
    final saved = await goodsReceiptRepo.createGoodsReceipt(receipt);

    // Load the engine from live stock, then receive each line: the
    // repo creates the batch row, the engine books it (counter +
    // receive ledger movement + audit).
    final batches = await inventoryRepo.getInventory(
      branchId: order.branchId,
    );
    engine.loadBatches(batches);
    final createdBatches = <InventoryItem>[];
    for (final line in receivedLines) {
      final created = await inventoryRepo.receiveStock(
        branchId: order.branchId,
        medicineId: line.item.medicineId,
        batchNo: line.batchNo.trim(),
        mfgDate: line.mfgDate!,
        expiryDate: line.expiryDate!,
        quantity: line.quantityReceivedNow,
        costMinor: line.item.unitCostMinor,
      );
      createdBatches.add(created);
    }
    final movements = await engine.receive(
      batches: createdBatches,
      receiptId: saved.id,
      userId: actorId,
      actorName: actorName,
      reason: 'Goods received — ${order.poNumber}',
    );

    // PO: received quantities + new status.
    final updatedItems = applyReceiving(order.items, lines);
    final updated = order.copyWith(
      items: updatedItems,
      status: statusAfterReceiving(order.copyWith(items: updatedItems)),
    );
    await purchaseOrderRepo.updatePurchaseOrder(updated);

    // Supplier ledger: the received value is charged as a purchase.
    SupplierLedgerEntry? ledgerEntry;
    if (receivedValueMinor > 0) {
      ledgerEntry = await supplierRepo.addLedgerEntry(
        SupplierLedgerEntry(
          id: '',
          supplierId: order.supplierId,
          kind: SupplierLedgerEntryKind.purchase,
          amountMinor: receivedValueMinor,
          reason: 'Goods received — ${order.poNumber}',
          referenceId: order.id,
          balanceAfterMinor: 0, // set by the repository
          createdAt: DateTime.now(),
        ),
      );
      await audit.write(
        AuditLogEntry.moneyMovement(
          organizationId: organizationId,
          branchId: order.branchId,
          userId: actorId,
          actorName: actorName,
          ledgerType: 'supplierLedger',
          ledgerOwnerId: order.supplierId,
          entryKind: 'purchase',
          amountMinor: ledgerEntry.amountMinor,
          balanceAfterMinor: ledgerEntry.balanceAfterMinor,
          referenceId: saved.id,
        ),
      );
    }

    await audit.write(
      AuditLogEntry.create(
        organizationId: organizationId,
        branchId: order.branchId,
        userId: actorId,
        actorName: actorName,
        action: 'goods.received',
        entityType: 'goodsReceipt',
        entityId: saved.id,
        summary:
            'Received ${receivedLines.length} line(s) against '
            '${order.poNumber} (${saved.receiptNumber}) — '
            '$receivedValueMinor paisa, ${createdBatches.length} batch(es)',
      ),
    );

    await _enqueueReceiveSync(
      saved,
      updated,
      movements,
      ledgerEntry,
      createdBatches,
    );

    final result = GoodsReceiptResult(
      receipt: saved,
      order: updated,
      movements: movements,
      isDuplicate: false,
    );
    _committedReceiptKeys[key] = result;
    return result;
  }

  /// Receives new stock through the production write path (Week 3
  /// Day 4, D111 — closes the D109 inventory-receive follow-up).
  ///
  /// The standalone receive dialog used to write straight to the
  /// inventory repo, so the sync queue never saw it. Now the layer
  /// is the single write path, like `receiveGoods`:
  ///
  /// 1. **Idempotency** — [idempotencyKey] (minted per call when
  ///    omitted) is the dedupe key: a retry with the same key
  ///    returns the original batch and creates NO second batch row
  ///    (the inventory repo creates a new row per call, so the
  ///    registry check runs BEFORE the repo write).
  /// 2. **Stock** — the repo creates the batch row, the engine
  ///    books it (`receive` ledger movement + audit). The movement's
  ///    reference is this key — a manual receive has no
  ///    `goodsReceipts` document, so the key stands in for a receipt
  ///    id (reference type `stockReceive`, not `goodsReceipt`).
  /// 3. **Sync** — one batched-write payload (batch doc + stock
  ///    transaction) is enqueued, so the Day 3 sync-status chip
  ///    moves for stock work.
  ///
  /// Throws [ArgumentError] when the repository rejects the receive
  /// (e.g. a non-positive quantity) — nothing is enqueued then.
  Future<StockReceiveResult> receiveStock({
    required String branchId,
    required String medicineId,
    required String batchNo,
    required DateTime mfgDate,
    required DateTime expiryDate,
    required int quantity,
    required int costMinor,
    String? idempotencyKey,
    String actorId = demoActorId,
    String actorName = demoActorName,
    String reason = 'Stock received',
  }) async {
    final key =
        idempotencyKey ?? newIdempotencyKey('stock-receive-$branchId');
    if (!FirestoreSchema.isValidIdempotencyKey(key)) {
      throw ArgumentError('Stock receive idempotency key is not valid.');
    }
    final existing = _committedReceiveKeys[key];
    if (existing != null) {
      return StockReceiveResult(
        batch: existing.batch,
        movements: const [],
        isDuplicate: true,
      );
    }
    // Load the engine from live stock BEFORE the repo creates the
    // batch: `loadBatches` resets the counters from the physical
    // rows, so loading after the create (which already includes the
    // new batch) and then booking it would count the batch twice.
    // Same order as `receiveGoods` (D103).
    engine.loadBatches(
      await inventoryRepo.getInventory(branchId: branchId),
    );
    final created = await inventoryRepo.receiveStock(
      branchId: branchId,
      medicineId: medicineId,
      batchNo: batchNo,
      mfgDate: mfgDate,
      expiryDate: expiryDate,
      quantity: quantity,
      costMinor: costMinor,
    );
    final movements = await engine.receive(
      batches: [created],
      receiptId: key,
      userId: actorId,
      actorName: actorName,
      reason: reason,
      referenceType: 'stockReceive',
    );
    await _enqueueStockReceiveSync(created, movements, key);
    final result = StockReceiveResult(
      batch: created,
      movements: movements,
      isDuplicate: false,
    );
    _committedReceiveKeys[key] = result;
    return result;
  }

  /// Adjusts one batch's quantity through the engine (validation +
  /// ledger + audit) and the repository (screens' source of truth).
  ///
  /// Week 3 Day 4 (D111 — closes the D109 inventory-adjust
  /// follow-up): the adjustment now also enqueues one sync payload
  /// (stock transaction + inventory-doc update), so the Day 3
  /// sync-status chip moves for stock work — and so do returns
  /// restocks, which already call this method
  /// (`returns_provider.dart`). A retry with the same
  /// [idempotencyKey] returns the original movement instead of
  /// applying the delta twice.
  Future<StockMovement> adjustStock({
    required String batchId,
    required int deltaQty,
    required String reason,
    String actorId = demoActorId,
    String actorName = demoActorName,
    String? referenceId,
    String? idempotencyKey,
  }) async {
    final key =
        idempotencyKey ?? newIdempotencyKey('stock-adjust-$batchId');
    if (!FirestoreSchema.isValidIdempotencyKey(key)) {
      throw ArgumentError('Stock adjustment idempotency key is not valid.');
    }
    final existing = _committedAdjustKeys[key];
    if (existing != null) return existing;
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
    await _enqueueAdjustSync(movement, key);
    _committedAdjustKeys[key] = movement;
    return movement;
  }

  /// Records a physical stock count through the production write
  /// path (Week 3 Day 5, D114 — closes the D111 follow-up).
  ///
  /// The count dialog used to write straight to the inventory repo,
  /// so the sync queue never saw it. Now the layer is the single
  /// write path, like `adjustStock`:
  ///
  /// 1. **Idempotency** — [idempotencyKey] (minted per call when
  ///    omitted; the dialog holds one key across retries, D115) is
  ///    the dedupe key: a retry with the same key returns the
  ///    original count and applies NO correction twice.
  /// 2. **Correction** — the variance (counted − system) is booked
  ///    through the engine (`adjust`, reason "Stock count", ledger
  ///    movement + audit) and the repository is set to the counted
  ///    quantity — the same end state as the old repo-direct write,
  ///    now with a ledger trail.
  /// 3. **Sync** — a non-zero correction enqueues one sync payload
  ///    (stock transaction + inventory-doc update, the same payload
  ///    as an adjustment), so the Day 3 sync-status chip moves for
  ///    stock counts. A count that matches the system (variance 0)
  ///    books no movement and enqueues nothing — there is no
  ///    quantity change to sync.
  ///
  /// Throws [ArgumentError] when the batch is missing or the counted
  /// quantity is negative — nothing is written then.
  Future<StockCountResult> recordStockCount({
    required String batchId,
    required int countedQty,
    String? note,
    String? idempotencyKey,
    String actorId = demoActorId,
    String actorName = demoActorName,
  }) async {
    final key =
        idempotencyKey ?? newIdempotencyKey('stock-count-$batchId');
    if (!FirestoreSchema.isValidIdempotencyKey(key)) {
      throw ArgumentError('Stock count idempotency key is not valid.');
    }
    final existing = _committedCountKeys[key];
    if (existing != null) {
      return StockCountResult(
        item: existing.item,
        variance: existing.variance,
        movement: existing.movement,
        isDuplicate: true,
      );
    }
    final batch = (await inventoryRepo.getInventory()).firstWhere(
      (item) => item.id == batchId,
      orElse: () => throw ArgumentError('No batch with id "$batchId".'),
    );
    if (countedQty < 0) {
      throw ArgumentError('Counted quantity cannot be negative.');
    }
    final variance = countedQty - batch.quantity;
    if (variance == 0) {
      // Count matches the system: record it (the repo stamps
      // updatedAt) but book no movement and enqueue nothing.
      final updated = await inventoryRepo.recordStockCount(
        batchId: batchId,
        countedQty: countedQty,
        note: note,
      );
      final result = StockCountResult(
        item: updated,
        variance: 0,
        movement: null,
        isDuplicate: false,
      );
      _committedCountKeys[key] = result;
      return result;
    }
    engine.loadBatches(
      await inventoryRepo.getInventory(branchId: batch.branchId),
    );
    final movement = await engine.adjust(
      batchId: batchId,
      deltaQty: variance,
      reason: note == null || note.trim().isEmpty
          ? 'Stock count'
          : 'Stock count — ${note.trim()}',
      userId: actorId,
      actorName: actorName,
      referenceId: key,
    );
    final updated = await inventoryRepo.recordStockCount(
      batchId: batchId,
      countedQty: countedQty,
      note: note,
    );
    await _enqueueAdjustSync(movement, key);
    final result = StockCountResult(
      item: updated,
      variance: variance,
      movement: movement,
      isDuplicate: false,
    );
    _committedCountKeys[key] = result;
    return result;
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

  /// When the queue last synced an operation successfully (`null` =
  /// nothing has synced yet). Week 3 Day 3 (D108): the sync-status
  /// UI shows this; it is `null` in the demo until a sync sender
  /// exists, and the UI says "Never synced" instead of inventing a
  /// time.
  DateTime? get lastSyncAt => syncQueue.lastSyncedAt;

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

  /// Builds the Firestore batched-write payload for a committed
  /// receiving event and enqueues it as one sync operation: the
  /// receipt doc + its item docs + the new batch docs + the stock
  /// transactions + the supplier-ledger entry + the PO status
  /// update. The future Firestore transport executes one chunk per
  /// real batched write — atomically, so a retried sync can never
  /// double-receive the way a retried local call could (D103).
  Future<void> _enqueueReceiveSync(
    GoodsReceipt receipt,
    PurchaseOrder updatedOrder,
    List<StockMovement> movements,
    SupplierLedgerEntry? ledgerEntry,
    List<InventoryItem> batches,
  ) async {
    final batch = LocalWriteBatch();
    batch.set(
      FirestoreSchema.goodsReceiptDocPath(receipt.branchId, receipt.id),
      goodsReceiptToFirestore(receipt, orgId: organizationId),
    );
    for (var i = 0; i < receipt.items.length; i++) {
      batch.set(
        '${FirestoreSchema.goodsReceiptItemsPath(receipt.branchId, receipt.id)}/item-$i',
        goodsReceiptItemToFirestore(
          receipt.items[i],
          orgId: organizationId,
          branchId: receipt.branchId,
        ),
      );
    }
    for (final item in batches) {
      batch.set(
        FirestoreSchema.branchDocPath(
          receipt.branchId,
          FirestoreSchema.batches,
          item.id,
        ),
        _stamped(item.toMap(), receipt.branchId),
      );
    }
    for (final movement in movements) {
      batch.set(
        '${FirestoreSchema.stockTransactionsPath(receipt.branchId)}/${movement.id}',
        movement.toMap(),
      );
    }
    if (ledgerEntry != null) {
      batch.set(
        '${FirestoreSchema.supplierLedgerPath(receipt.supplierId)}/${ledgerEntry.id}',
        supplierLedgerEntryToFirestore(ledgerEntry, orgId: organizationId),
      );
    }
    batch.update(
      FirestoreSchema.branchDocPath(
        receipt.branchId,
        FirestoreSchema.purchaseOrders,
        updatedOrder.id,
      ),
      {
        'status': purchaseOrderStatusToFirestore(updatedOrder.status),
        'updatedAt': DateTime.now().toIso8601String(),
      },
    );
    final chunks = batch.chunks();
    await syncQueue.enqueue(
      idempotencyKey: receipt.id,
      entityType: 'goodsReceipt',
      entityId: receipt.id,
      branchId: receipt.branchId,
      organizationId: organizationId,
      kind: SyncOperationKind.create,
      payload: {
        'path': FirestoreSchema.goodsReceiptDocPath(
          receipt.branchId,
          receipt.id,
        ),
        'operations': batch.toMap()['operations'],
        'chunks': chunks.length,
        'operationCount': batch.operationCount,
      },
    );
  }

  /// Builds the Firestore batched-write payload for one stock
  /// adjustment and enqueues it as one sync operation (Week 3 Day
  /// 4, D111): the stock-transaction doc + the inventory-doc
  /// quantity update. Stock is money-or-stock (SRS §2.5.4), so a
  /// sync conflict on it is flagged for a human, never silently
  /// overwritten — the queue's conflict policy already covers
  /// `stockTransaction` entities.
  Future<void> _enqueueAdjustSync(StockMovement movement, String key) async {
    final batch = LocalWriteBatch();
    batch.set(
      '${FirestoreSchema.stockTransactionsPath(movement.branchId)}/${movement.id}',
      movement.toMap(),
    );
    batch.update(
      FirestoreSchema.inventoryDocPath(
        movement.branchId,
        movement.medicineId,
      ),
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
    final chunks = batch.chunks();
    await syncQueue.enqueue(
      idempotencyKey: key,
      entityType: 'stockTransaction',
      entityId: movement.id,
      branchId: movement.branchId,
      organizationId: organizationId,
      kind: SyncOperationKind.update,
      payload: {
        'path':
            '${FirestoreSchema.stockTransactionsPath(movement.branchId)}/${movement.id}',
        'operations': batch.toMap()['operations'],
        'chunks': chunks.length,
        'operationCount': batch.operationCount,
      },
    );
  }

  /// Builds the Firestore batched-write payload for one standalone
  /// stock receive and enqueues it as one sync operation (Week 3
  /// Day 4, D111): the new batch doc + the stock-transaction doc.
  Future<void> _enqueueStockReceiveSync(
    InventoryItem created,
    List<StockMovement> movements,
    String key,
  ) async {
    final batch = LocalWriteBatch();
    batch.set(
      FirestoreSchema.branchDocPath(
        created.branchId,
        FirestoreSchema.batches,
        created.id,
      ),
      _stamped(created.toMap(), created.branchId),
    );
    for (final movement in movements) {
      batch.set(
        '${FirestoreSchema.stockTransactionsPath(movement.branchId)}/${movement.id}',
        movement.toMap(),
      );
    }
    final chunks = batch.chunks();
    await syncQueue.enqueue(
      idempotencyKey: key,
      entityType: 'stockTransaction',
      entityId: created.id,
      branchId: created.branchId,
      organizationId: organizationId,
      kind: SyncOperationKind.create,
      payload: {
        'path': FirestoreSchema.branchDocPath(
          created.branchId,
          FirestoreSchema.batches,
          created.id,
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
    goodsReceiptRepo: ref.read(goodsReceiptRepositoryProvider),
    audit: audit,
    syncQueue: syncQueue,
    engine: engine,
  );
});
