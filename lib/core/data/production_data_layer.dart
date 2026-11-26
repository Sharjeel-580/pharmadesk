import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/customer_ledger.dart';
import '../../models/daily_closing.dart';
import '../../models/expense.dart';
import '../../models/financial_transaction.dart';
import '../../models/goods_receipt.dart';
import '../../models/inventory_item.dart';
import '../../models/order.dart';
import '../../models/purchase_order.dart';
import '../../models/rider.dart';
import '../../models/sale.dart';
import '../../models/stock_transfer.dart';
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
/// stock counts, and — since Week 4 Day 5 (D145) — cashbook writes
/// (expense / income / daily closing). Screens do not change: the notifiers
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

/// Result of [ProductionDataLayer.createTransfer].
class StockTransferCreateResult {
  const StockTransferCreateResult({
    required this.transfer,
    required this.isDuplicate,
  });

  /// The saved transfer (the original, when [isDuplicate] is true).
  final StockTransfer transfer;

  /// True when this key was already used to request a transfer: no
  /// second transfer was created.
  final bool isDuplicate;
}

/// Result of [ProductionDataLayer.dispatchTransfer] /
/// [ProductionDataLayer.receiveTransfer].
class StockTransferMoveResult {
  const StockTransferMoveResult({
    required this.transfer,
    required this.movements,
    required this.isDuplicate,
  });

  /// The transfer after the move (the original's post-move state,
  /// when [isDuplicate] is true).
  final StockTransfer transfer;

  /// Stock ledger movements written by the move (empty on a
  /// duplicate — the original move already wrote them).
  final List<StockMovement> movements;

  /// True when this key already moved this transfer: no stock moved
  /// a second time.
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
    StockTransferRepository? stockTransferRepo,
    GoodsReceiptRepository? goodsReceiptRepo,
    ExpenseRepository? expenseRepo,
    FinancialTransactionRepository? financialTransactionRepo,
    DailyClosingRepository? dailyClosingRepo,
    required this.audit,
    required this.syncQueue,
    required this.engine,
  }) : goodsReceiptRepo =
           goodsReceiptRepo ?? MockGoodsReceiptRepository(),
       stockTransferRepo =
           stockTransferRepo ?? MockStockTransferRepository(),
       expenseRepo = expenseRepo ?? MockExpenseRepository(),
       financialTransactionRepo =
           financialTransactionRepo ?? MockFinancialTransactionRepository(),
       dailyClosingRepo = dailyClosingRepo ?? MockDailyClosingRepository();

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

  /// The stock-transfer store. Optional in the constructor so direct
  /// constructions (Week 2 Day 1 tests) keep working — they get a
  /// fresh mock; the app provider passes the bundle's repo, so the
  /// transfers the layer writes are the ones the app reads (same
  /// pattern as [goodsReceiptRepo]).
  final StockTransferRepository stockTransferRepo;

  /// The goods-receipts store. Optional in the constructor so
  /// direct constructions (Week 2 Day 1 tests) keep working — they
  /// get a fresh mock; the app provider passes the bundle's repo,
  /// so the receipts the layer writes are the ones the app reads.
  final GoodsReceiptRepository goodsReceiptRepo;

  /// The cashbook stores (Week 4 Day 5, D145 — closes D129).
  /// Optional in the constructor on the same pattern as
  /// [goodsReceiptRepo]: direct constructions get fresh mocks; the
  /// app provider passes the bundle's repos, so the expenses /
  /// transactions / closings the layer writes are the ones the
  /// cashbook screen reads.
  final ExpenseRepository expenseRepo;
  final FinancialTransactionRepository financialTransactionRepo;
  final DailyClosingRepository dailyClosingRepo;

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

  /// Committed batch quarantine / un-quarantine transitions by
  /// idempotency key (Week 4 Day 5, D140): a retry with the same key
  /// returns the original batch instead of re-applying the
  /// transition (which would throw — the batch no longer being in
  /// the `from` status).
  final Map<String, InventoryItem> _committedQuarantineKeys = {};

  /// Committed cashbook writes by idempotency key (Week 4 Day 5,
  /// D145): a retry with the same key returns the original record
  /// instead of writing a second expense / income / closing.
  final Map<String, Expense> _committedExpenseKeys = {};
  final Map<String, FinancialTransaction> _committedIncomeKeys = {};
  final Map<String, DailyClosing> _committedClosingKeys = {};

  /// Committed standalone stock receives by idempotency key
  /// (Week 3 Day 4, D111): a retry with the same key returns the
  /// original batch instead of creating a second batch row.
  final Map<String, StockReceiveResult> _committedReceiveKeys = {};

  /// Committed stock counts by idempotency key (Week 3 Day 5,
  /// D114): a retry with the same key returns the original count
  /// instead of applying the correction twice.
  final Map<String, StockCountResult> _committedCountKeys = {};

  /// Committed transfer requests by idempotency key (Week 4 Day 2,
  /// D118): a retry with the same key returns the original transfer
  /// instead of creating a second one.
  final Map<String, StockTransferCreateResult> _committedTransferKeys = {};

  /// Committed transfer dispatches by idempotency key (Week 4 Day 2,
  /// D118): a retry with the same key returns the original dispatch
  /// and moves NO stock a second time.
  final Map<String, StockTransferMoveResult> _dispatchedTransferKeys = {};

  /// Committed transfer receives by idempotency key (Week 4 Day 2,
  /// D118): a retry with the same key returns the original receive
  /// and moves NO stock a second time.
  final Map<String, StockTransferMoveResult> _receivedTransferKeys = {};

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

  /// Quarantines one batch — removes it from FEFO saleable stock
  /// (Week 4 Day 5, D140 — SRS D-11 / FR-INV-07).
  ///
  /// 1. **Transition** — only a batch in `available` status can be
  ///    quarantined (an expired batch is already unsellable; a
  ///    quarantined batch is already out of the saleable pool).
  /// 2. **Status** — the repo flips the batch status (D68); the
  ///    engine reloads so the saleable-stock guard sees it at once.
  /// 3. **Audit** — one `batch.quarantined` entry with the reason.
  /// 4. **Sync** — one batch-doc update payload is enqueued, so the
  ///    sync chip moves for quarantine work.
  /// 5. **Idempotency** — a retry with the same key returns the
  ///    original batch instead of re-applying the transition.
  ///
  /// The return / disposal approval that follows a quarantine
  /// (FR-INV-07) is a follow-up, not built here: quarantining only
  /// parks the batch out of the saleable pool.
  Future<InventoryItem> quarantineBatch({
    required String batchId,
    required String reason,
    String? idempotencyKey,
    String actorId = demoActorId,
    String actorName = demoActorName,
  }) {
    return _setBatchStatus(
      batchId: batchId,
      from: BatchStatus.available,
      to: BatchStatus.quarantined,
      action: 'batch.quarantined',
      reason: reason,
      idempotencyKey: idempotencyKey,
      actorId: actorId,
      actorName: actorName,
    );
  }

  /// Restores a quarantined batch to `available` (Week 4 Day 5,
  /// D140 — the un-quarantine action of SRS D-11). Only a batch in
  /// `quarantined` status can be restored; the audit entry is
  /// `batch.unquarantined`.
  Future<InventoryItem> unquarantineBatch({
    required String batchId,
    required String reason,
    String? idempotencyKey,
    String actorId = demoActorId,
    String actorName = demoActorName,
  }) {
    return _setBatchStatus(
      batchId: batchId,
      from: BatchStatus.quarantined,
      to: BatchStatus.available,
      action: 'batch.unquarantined',
      reason: reason,
      idempotencyKey: idempotencyKey,
      actorId: actorId,
      actorName: actorName,
    );
  }

  Future<InventoryItem> _setBatchStatus({
    required String batchId,
    required BatchStatus from,
    required BatchStatus to,
    required String action,
    required String reason,
    String? idempotencyKey,
    String actorId = demoActorId,
    String actorName = demoActorName,
  }) async {
    final key =
        idempotencyKey ??
        newIdempotencyKey('batch-status-$batchId-${to.name}');
    if (!FirestoreSchema.isValidIdempotencyKey(key)) {
      throw ArgumentError('Batch status idempotency key is not valid.');
    }
    final existing = _committedQuarantineKeys[key];
    if (existing != null) return existing;
    final batch = (await inventoryRepo.getInventory()).firstWhere(
      (item) => item.id == batchId,
      orElse: () => throw ArgumentError('No batch with id "$batchId".'),
    );
    if (batch.status != from) {
      throw ArgumentError(
        'Batch ${batch.batchNo} is ${batch.status.name}, not '
        '${from.name} — it cannot be moved to ${to.name}.',
      );
    }
    final updated = await inventoryRepo.updateBatchStatus(
      batchId: batchId,
      status: to,
      reason: reason,
    );
    engine.loadBatches(
      await inventoryRepo.getInventory(branchId: batch.branchId),
    );
    await audit.write(
      AuditLogEntry.create(
        organizationId: organizationId,
        branchId: batch.branchId,
        userId: actorId,
        actorName: actorName,
        action: action,
        entityType: 'batch',
        entityId: batchId,
        summary: 'Batch ${batch.batchNo} ${to.name} — $reason',
        before: from.name,
        after: to.name,
      ),
    );
    await _enqueueBatchStatusSync(updated, key);
    _committedQuarantineKeys[key] = updated;
    return updated;
  }

  /// Builds the Firestore payload for one batch-status change and
  /// enqueues it as one sync operation (D140 — D111 pattern): a
  /// single batch-doc update.
  Future<void> _enqueueBatchStatusSync(
    InventoryItem batch,
    String key,
  ) async {
    final writeBatch = LocalWriteBatch();
    writeBatch.update(
      FirestoreSchema.branchDocPath(
        batch.branchId,
        FirestoreSchema.batches,
        batch.id,
      ),
      {
        'status': batch.status.name,
        'updatedAt': DateTime.now().toIso8601String(),
      },
    );
    final chunks = writeBatch.chunks();
    await syncQueue.enqueue(
      idempotencyKey: key,
      entityType: 'batch',
      entityId: batch.id,
      branchId: batch.branchId,
      organizationId: organizationId,
      kind: SyncOperationKind.update,
      payload: {
        'path': FirestoreSchema.branchDocPath(
          batch.branchId,
          FirestoreSchema.batches,
          batch.id,
        ),
        'operations': writeBatch.toMap()['operations'],
        'chunks': chunks.length,
        'operationCount': writeBatch.operationCount,
      },
    );
  }

  /// Records an expense through the production write path (Week 4
  /// Day 5, D145 — closes the D129 cashbook follow-up).
  ///
  /// 1. **Idempotency** — [idempotencyKey] (minted per call when
  ///    omitted) is the dedupe key: a retry with the same key
  ///    returns the original expense instead of writing a second
  ///    one (the repository assigns the id, so the registry check
  ///    runs BEFORE the repo write — same as `receiveStock`, D111).
  /// 2. **Mirror** — the matching `financialTransactions` entry of
  ///    type `expense` (negative amount) is written in the same
  ///    call, so the P&L and the transaction feed never diverge
  ///    (the notifier used to write both repo-direct).
  /// 3. **Sync** — one batched-write payload (expense doc +
  ///    transaction doc) is enqueued, so the sync-status chip moves
  ///    for cashbook work.
  Future<Expense> recordExpense({
    required String branchId,
    required String category,
    required int amountMinor,
    String description = '',
    required DateTime expenseDate,
    String? createdBy,
    String? idempotencyKey,
  }) async {
    final key =
        idempotencyKey ?? newIdempotencyKey('finance-expense-$branchId');
    if (!FirestoreSchema.isValidIdempotencyKey(key)) {
      throw ArgumentError('Expense idempotency key is not valid.');
    }
    final existing = _committedExpenseKeys[key];
    if (existing != null) return existing;
    final created = await expenseRepo.createExpense(
      Expense(
        id: '',
        branchId: branchId,
        category: category,
        amountMinor: amountMinor,
        description: description.trim(),
        expenseDate: expenseDate,
        createdBy: createdBy,
      ),
    );
    final mirror = await financialTransactionRepo.addTransaction(
      FinancialTransaction(
        id: '',
        branchId: branchId,
        type: FinancialTransactionType.expense,
        amountMinor: -amountMinor,
        category: category,
        referenceType: 'expense',
        referenceId: created.id,
        createdBy: createdBy,
        createdAt: DateTime.now(),
      ),
    );
    await _enqueueFinanceSync(
      entityType: 'expense',
      entityId: created.id,
      branchId: branchId,
      key: key,
      docs: {
        FirestoreSchema.branchDocPath(
          branchId,
          FirestoreSchema.expenses,
          created.id,
        ): expenseToFirestore(created, orgId: organizationId),
        FirestoreSchema.branchDocPath(
          branchId,
          FirestoreSchema.financialTransactions,
          mirror.id,
        ): financialTransactionToFirestore(mirror, orgId: organizationId),
      },
    );
    _committedExpenseKeys[key] = created;
    return created;
  }

  /// Records a cashbook income entry through the production write
  /// path (Week 4 Day 5, D145 — closes the D129 cashbook
  /// follow-up): a `financialTransactions` entry of type `income`
  /// with a positive amount, plus one sync payload. Idempotency
  /// follows the same registry pattern as [recordExpense].
  Future<FinancialTransaction> recordIncome({
    required String branchId,
    required String category,
    required int amountMinor,
    required DateTime date,
    String? createdBy,
    String? idempotencyKey,
  }) async {
    final key =
        idempotencyKey ?? newIdempotencyKey('finance-income-$branchId');
    if (!FirestoreSchema.isValidIdempotencyKey(key)) {
      throw ArgumentError('Income idempotency key is not valid.');
    }
    final existing = _committedIncomeKeys[key];
    if (existing != null) return existing;
    final created = await financialTransactionRepo.addTransaction(
      FinancialTransaction(
        id: '',
        branchId: branchId,
        type: FinancialTransactionType.income,
        amountMinor: amountMinor,
        category: category,
        referenceType: 'cashbookIncome',
        createdBy: createdBy,
        createdAt: date,
      ),
    );
    await _enqueueFinanceSync(
      entityType: 'financialTransaction',
      entityId: created.id,
      branchId: branchId,
      key: key,
      docs: {
        FirestoreSchema.branchDocPath(
          branchId,
          FirestoreSchema.financialTransactions,
          created.id,
        ): financialTransactionToFirestore(created, orgId: organizationId),
      },
    );
    _committedIncomeKeys[key] = created;
    return created;
  }

  /// Records a daily closing through the production write path
  /// (Week 4 Day 5, D145 — closes the D129 cashbook follow-up).
  /// The totals are computed by the caller (the notifier, from the
  /// live entries at close time); the layer writes the record and
  /// enqueues one sync payload. Idempotency follows the same
  /// registry pattern as [recordExpense]. The repository also
  /// throws when a closing already exists for the branch-day.
  Future<DailyClosing> recordDailyClosing({
    required DailyClosing closing,
    String? idempotencyKey,
  }) async {
    final key =
        idempotencyKey ??
        newIdempotencyKey('finance-closing-${closing.branchId}');
    if (!FirestoreSchema.isValidIdempotencyKey(key)) {
      throw ArgumentError('Daily closing idempotency key is not valid.');
    }
    final existing = _committedClosingKeys[key];
    if (existing != null) return existing;
    final created = await dailyClosingRepo.createClosing(closing);
    await _enqueueFinanceSync(
      entityType: 'dailyClosing',
      entityId: created.id,
      branchId: created.branchId,
      key: key,
      docs: {
        FirestoreSchema.branchDocPath(
          created.branchId,
          FirestoreSchema.dailyClosings,
          created.id,
        ): dailyClosingToFirestore(created, orgId: organizationId),
      },
    );
    _committedClosingKeys[key] = created;
    return created;
  }

  /// Builds the Firestore batched-write payload for one cashbook
  /// write and enqueues it as one sync operation (D145 — D111
  /// pattern): one `set` per document in [docs], one queue op.
  Future<void> _enqueueFinanceSync({
    required String entityType,
    required String entityId,
    required String branchId,
    required String key,
    required Map<String, Map<String, dynamic>> docs,
  }) async {
    final writeBatch = LocalWriteBatch();
    for (final entry in docs.entries) {
      writeBatch.set(entry.key, entry.value);
    }
    final chunks = writeBatch.chunks();
    await syncQueue.enqueue(
      idempotencyKey: key,
      entityType: entityType,
      entityId: entityId,
      branchId: branchId,
      organizationId: organizationId,
      kind: SyncOperationKind.create,
      payload: {
        'path': docs.keys.first,
        'operations': writeBatch.toMap()['operations'],
        'chunks': chunks.length,
        'operationCount': writeBatch.operationCount,
      },
    );
  }

  /// Requests a stock transfer between two branches (Week 4 Day 2,
  /// D118 — SRS D-16).
  ///
  /// The single write path for transfer requests, like `receiveGoods`
  /// is for PO receiving:
  ///
  /// 1. **Idempotency** — [idempotencyKey] (minted per call when
  ///    omitted; the form holds one key across retries, D115
  ///    pattern) is the dedupe key AND the transfer's document id:
  ///    a retry with the same key returns the original transfer
  ///    instead of creating a second one.
  /// 2. **Validation** — the branches must differ, every line needs
  ///    a real medicine and a positive quantity. A request moves NO
  ///    stock: availability is checked at dispatch, not here, so a
  ///    branch can request what it needs before the source confirms
  ///    it has it.
  /// 3. **Sync** — one payload (the transfer doc) is enqueued, so
  ///    the sync-status chip moves for transfer work.
  ///
  /// Throws [ArgumentError] when the branches match, a line is
  /// empty, or a medicine does not exist.
  Future<StockTransferCreateResult> createTransfer({
    required String fromBranchId,
    required String toBranchId,
    required List<TransferItem> items,
    String? note,
    String? idempotencyKey,
    String actorId = demoActorId,
    String actorName = demoActorName,
  }) async {
    final key =
        idempotencyKey ?? newIdempotencyKey('transfer-$fromBranchId');
    if (!FirestoreSchema.isValidIdempotencyKey(key)) {
      throw ArgumentError('Transfer idempotency key is not valid.');
    }
    final existing = _committedTransferKeys[key];
    if (existing != null) {
      return StockTransferCreateResult(
        transfer: existing.transfer,
        isDuplicate: true,
      );
    }
    if (fromBranchId == toBranchId) {
      throw ArgumentError(
        'A transfer needs two different branches — source and '
        'destination are the same.',
      );
    }
    if (items.isEmpty) {
      throw ArgumentError('A transfer needs at least one medicine.');
    }
    final lines = <TransferItem>[];
    for (final item in items) {
      if (item.quantity <= 0) {
        throw ArgumentError(
          'Transfer quantity for ${item.medicineName} must be above zero.',
        );
      }
      final medicine = await medicineRepo.getById(item.medicineId);
      if (medicine == null) {
        throw ArgumentError(
          'No medicine with id "${item.medicineId}".',
        );
      }
      lines.add(
        TransferItem(
          medicineId: item.medicineId,
          medicineName: medicine.name,
          quantity: item.quantity,
        ),
      );
    }
    final transfer = StockTransfer(
      id: key,
      transferNumber: '',
      fromBranchId: fromBranchId,
      toBranchId: toBranchId,
      status: StockTransferStatus.requested,
      items: lines,
      note: note?.trim().isEmpty ?? true ? null : note!.trim(),
      requestedBy: actorId,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    final saved = await stockTransferRepo.createTransfer(transfer);
    await audit.write(
      AuditLogEntry.create(
        organizationId: organizationId,
        branchId: fromBranchId,
        userId: actorId,
        actorName: actorName,
        action: 'transfer.requested',
        entityType: 'stockTransfer',
        entityId: saved.id,
        summary:
            'Transfer ${saved.transferNumber} requested: '
            '${saved.totalQuantity} unit(s) in ${saved.items.length} '
            'line(s) from $fromBranchId to $toBranchId',
      ),
    );
    await syncQueue.enqueue(
      idempotencyKey: key,
      entityType: 'stockTransfer',
      entityId: saved.id,
      branchId: fromBranchId,
      organizationId: organizationId,
      kind: SyncOperationKind.create,
      payload: {
        'path': FirestoreSchema.stockTransferDocPath(fromBranchId, saved.id),
        'document': stockTransferToFirestore(saved, orgId: organizationId),
      },
    );
    final result = StockTransferCreateResult(
      transfer: saved,
      isDuplicate: false,
    );
    _committedTransferKeys[key] = result;
    return result;
  }

  /// Moves a transfer Requested → Approved.
  ///
  /// Approval separation (SRS §5.2 rule 4): the user who requested
  /// the transfer cannot approve it — throws [ArgumentError] when
  /// [actorId] matches the requester. The demo accounts have
  /// distinct uids (`demo-owner`, `demo-branch_manager`, …), so the
  /// rule works in the demo too.
  Future<StockTransfer> approveTransfer(
    String transferId, {
    String actorId = demoActorId,
    String actorName = demoActorName,
  }) async {
    final transfer = await _requireTransfer(transferId);
    if (transfer.status != StockTransferStatus.requested) {
      throw ArgumentError(
        'Transfer ${transfer.transferNumber} cannot be approved '
        'in status ${transfer.status.label} — only a Requested '
        'transfer can be approved.',
      );
    }
    if (transfer.requestedBy != null &&
        transfer.requestedBy == actorId) {
      throw ArgumentError(
        'You requested this transfer — someone else must approve it.',
      );
    }
    return _transitionTransfer(
      transfer,
      StockTransferStatus.approved,
      approvedBy: actorName,
      action: 'transfer.approved',
      actorId: actorId,
      actorName: actorName,
      summary:
          'Transfer ${transfer.transferNumber} approved by $actorName',
    );
  }

  /// Moves a transfer Requested → Rejected.
  Future<StockTransfer> rejectTransfer(
    String transferId, {
    String actorId = demoActorId,
    String actorName = demoActorName,
  }) async {
    final transfer = await _requireTransfer(transferId);
    if (transfer.status != StockTransferStatus.requested) {
      throw ArgumentError(
        'Transfer ${transfer.transferNumber} cannot be rejected '
        'in status ${transfer.status.label} — only a Requested '
        'transfer can be rejected.',
      );
    }
    return _transitionTransfer(
      transfer,
      StockTransferStatus.rejected,
      action: 'transfer.rejected',
      actorId: actorId,
      actorName: actorName,
      summary:
          'Transfer ${transfer.transferNumber} rejected by $actorName',
    );
  }

  /// Moves a transfer Requested/Approved → Cancelled.
  Future<StockTransfer> cancelTransfer(
    String transferId, {
    String actorId = demoActorId,
    String actorName = demoActorName,
  }) async {
    final transfer = await _requireTransfer(transferId);
    if (transfer.status != StockTransferStatus.requested &&
        transfer.status != StockTransferStatus.approved) {
      throw ArgumentError(
        'Transfer ${transfer.transferNumber} cannot be cancelled '
        'in status ${transfer.status.label} — only a Requested or '
        'Approved transfer can be cancelled.',
      );
    }
    return _transitionTransfer(
      transfer,
      StockTransferStatus.cancelled,
      action: 'transfer.cancelled',
      actorId: actorId,
      actorName: actorName,
      summary:
          'Transfer ${transfer.transferNumber} cancelled by $actorName',
    );
  }

  Future<StockTransfer> _requireTransfer(String transferId) async {
    final transfer = await stockTransferRepo.getById(transferId);
    if (transfer == null) {
      throw ArgumentError('No transfer with id "$transferId".');
    }
    return transfer;
  }

  /// Applies a status-only transition (approve / reject / cancel):
  /// repository write + audit + one sync payload (the transfer doc
  /// update). The caller owns the status guard.
  Future<StockTransfer> _transitionTransfer(
    StockTransfer transfer,
    StockTransferStatus status, {
    String? approvedBy,
    required String action,
    required String actorId,
    required String actorName,
    required String summary,
  }) async {
    final updated = transfer.copyWith(
      status: status,
      approvedBy: approvedBy,
      updatedAt: DateTime.now(),
    );
    await stockTransferRepo.updateTransfer(updated);
    await audit.write(
      AuditLogEntry.create(
        organizationId: organizationId,
        branchId: transfer.fromBranchId,
        userId: actorId,
        actorName: actorName,
        action: action,
        entityType: 'stockTransfer',
        entityId: transfer.id,
        summary: summary,
      ),
    );
    await _enqueueTransferSync(updated, const [], 'transfer-$action');
    return updated;
  }

  /// Dispatches an Approved transfer: the stock leaves the source
  /// branch (Week 4 Day 2, D118 — SRS D-16).
  ///
  /// 1. **Idempotency** — [idempotencyKey] (minted per call when
  ///    omitted) dedupes the dispatch: a retry with the same key
  ///    returns the original dispatch and moves NO stock twice.
  /// 2. **Stock** — the engine reserves FEFO batches per line from
  ///    live source stock (a short line throws and releases every
  ///    hold — nothing partially dispatches), then `transferOut`
  ///    books `transfer_out` ledger movements + audit per batch
  ///    chunk, and the repository decrements the same batches. The
  ///    FEFO allocations are recorded on the transfer, so the
  ///    receive step recreates the destination batches exactly.
  /// 3. **Sync** — one payload (transfer doc + stock transactions +
  ///    inventory updates) is enqueued.
  ///
  /// Throws [ArgumentError] when the transfer is not Approved or a
  /// line exceeds sellable source stock.
  Future<StockTransferMoveResult> dispatchTransfer({
    required String transferId,
    String? idempotencyKey,
    String actorId = demoActorId,
    String actorName = demoActorName,
  }) async {
    final key =
        idempotencyKey ?? newIdempotencyKey('transfer-dispatch-$transferId');
    if (!FirestoreSchema.isValidIdempotencyKey(key)) {
      throw ArgumentError('Transfer dispatch idempotency key is not valid.');
    }
    final existing = _dispatchedTransferKeys[key];
    if (existing != null) {
      return StockTransferMoveResult(
        transfer: existing.transfer,
        movements: const [],
        isDuplicate: true,
      );
    }
    final transfer = await _requireTransfer(transferId);
    if (transfer.status != StockTransferStatus.approved) {
      throw ArgumentError(
        'Transfer ${transfer.transferNumber} cannot be dispatched '
        'in status ${transfer.status.label} — only an Approved '
        'transfer can be dispatched.',
      );
    }
    // Load the engine from live source stock BEFORE reserving: the
    // reserve walks the engine's snapshots, and a stale engine
    // would dispatch stock another sale already took.
    engine.loadBatches(
      await inventoryRepo.getInventory(branchId: transfer.fromBranchId),
    );
    final saleKey = 'transfer-$transferId';
    final allReservations = <StockReservation>[];
    try {
      for (final item in transfer.items) {
        allReservations.addAll(
          engine.reserve(
            branchId: transfer.fromBranchId,
            medicineId: item.medicineId,
            quantity: item.quantity,
            saleKey: saleKey,
          ),
        );
      }
    } on ArgumentError {
      // A short line rolls the whole dispatch back: release every
      // hold the earlier lines took, so nothing is half-reserved.
      await engine.releaseAllForSale(
        saleKey,
        userId: actorId,
        actorName: actorName,
        reason: 'Transfer dispatch failed — insufficient stock',
      );
      rethrow;
    }
    final movements = await engine.transferOut(
      reservations: allReservations,
      transferId: transfer.id,
      userId: actorId,
      actorName: actorName,
    );
    // The repository is the screens' source of truth: decrement the
    // same batches the engine just booked.
    for (final reservation in allReservations) {
      await inventoryRepo.adjustStock(
        batchId: reservation.batchId,
        deltaQty: -reservation.quantity,
        reason: 'Transfer dispatched — ${transfer.transferNumber}',
      );
    }
    final allocations = <TransferAllocation>[
      for (final reservation in allReservations)
        TransferAllocation(
          medicineId: reservation.medicineId,
          batchId: reservation.batchId,
          batchNo:
              engine.batchById(reservation.batchId)?.batchNo ?? '',
          quantity: reservation.quantity,
          mfgDate: engine.batchById(reservation.batchId)?.mfgDate,
          expiryDate: engine.batchById(reservation.batchId)?.expiryDate,
          unitCostMinor:
              engine.batchById(reservation.batchId)?.costMinor ?? 0,
        ),
    ];
    final updated = transfer.copyWith(
      status: StockTransferStatus.dispatched,
      dispatchedBy: actorName,
      dispatchAllocations: allocations,
      updatedAt: DateTime.now(),
    );
    await stockTransferRepo.updateTransfer(updated);
    await audit.write(
      AuditLogEntry.create(
        organizationId: organizationId,
        branchId: transfer.fromBranchId,
        userId: actorId,
        actorName: actorName,
        action: 'transfer.dispatched',
        entityType: 'stockTransfer',
        entityId: transfer.id,
        summary:
            'Transfer ${transfer.transferNumber} dispatched: '
            '${transfer.totalQuantity} unit(s) left '
            '${transfer.fromBranchId} for ${transfer.toBranchId}',
      ),
    );
    await _enqueueTransferSync(updated, movements, key);
    final result = StockTransferMoveResult(
      transfer: updated,
      movements: movements,
      isDuplicate: false,
    );
    _dispatchedTransferKeys[key] = result;
    return result;
  }

  /// Receives a Dispatched transfer at the destination branch (Week
  /// 4 Day 2, D118 — SRS D-16).
  ///
  /// 1. **Idempotency** — [idempotencyKey] dedupes the receive: a
  ///    retry with the same key returns the original receive and
  ///    creates NO second set of destination batches.
  /// 2. **Stock** — one destination batch per dispatch allocation
  ///    (same batch number, mfg/expiry, unit cost as the source
  ///    batch — the allocations recorded at dispatch), booked into
  ///    the engine as `transfer_in` movements + audit, then the
  ///    repository creates the same rows.
  /// 3. **Sync** — one payload (transfer doc + new batch docs +
  ///    stock transactions) is enqueued.
  ///
  /// Throws [ArgumentError] when the transfer is not Dispatched, or
  /// [StateError] when a Dispatched transfer carries no allocations
  /// (a corrupt record — the dispatch that made it never recorded
  /// where the stock came from).
  Future<StockTransferMoveResult> receiveTransfer({
    required String transferId,
    String? idempotencyKey,
    String actorId = demoActorId,
    String actorName = demoActorName,
  }) async {
    final key =
        idempotencyKey ?? newIdempotencyKey('transfer-receive-$transferId');
    if (!FirestoreSchema.isValidIdempotencyKey(key)) {
      throw ArgumentError('Transfer receive idempotency key is not valid.');
    }
    final existing = _receivedTransferKeys[key];
    if (existing != null) {
      return StockTransferMoveResult(
        transfer: existing.transfer,
        movements: const [],
        isDuplicate: true,
      );
    }
    final transfer = await _requireTransfer(transferId);
    if (transfer.status != StockTransferStatus.dispatched) {
      throw ArgumentError(
        'Transfer ${transfer.transferNumber} cannot be received '
        'in status ${transfer.status.label} — only a Dispatched '
        'transfer can be received.',
      );
    }
    if (transfer.dispatchAllocations.isEmpty) {
      throw StateError(
        'Transfer ${transfer.transferNumber} was dispatched without '
        'batch allocations — check the dispatch record before '
        'receiving it.',
      );
    }
    // Load the engine from live destination stock BEFORE the repo
    // creates the batches: `loadBatches` resets the counters from
    // the physical rows, so loading after the create and then
    // booking the receive would count the new batches twice (D111
    // ordering, same as `receiveStock`).
    engine.loadBatches(
      await inventoryRepo.getInventory(branchId: transfer.toBranchId),
    );
    final createdBatches = <InventoryItem>[];
    for (final allocation in transfer.dispatchAllocations) {
      final created = await inventoryRepo.receiveStock(
        branchId: transfer.toBranchId,
        medicineId: allocation.medicineId,
        batchNo: allocation.batchNo,
        mfgDate:
            allocation.mfgDate ?? DateTime.now().subtract(
              const Duration(days: 30),
            ),
        expiryDate:
            allocation.expiryDate ?? DateTime.now().add(
              const Duration(days: 365),
            ),
        quantity: allocation.quantity,
        costMinor: allocation.unitCostMinor,
      );
      createdBatches.add(created);
    }
    final movements = await engine.transferIn(
      batches: createdBatches,
      transferId: transfer.id,
      userId: actorId,
      actorName: actorName,
      reason: 'Transfer received — ${transfer.transferNumber}',
    );
    final updated = transfer.copyWith(
      status: StockTransferStatus.received,
      receivedBy: actorName,
      updatedAt: DateTime.now(),
    );
    await stockTransferRepo.updateTransfer(updated);
    await audit.write(
      AuditLogEntry.create(
        organizationId: organizationId,
        branchId: transfer.toBranchId,
        userId: actorId,
        actorName: actorName,
        action: 'transfer.received',
        entityType: 'stockTransfer',
        entityId: transfer.id,
        summary:
            'Transfer ${transfer.transferNumber} received at '
            '${transfer.toBranchId}: ${transfer.totalQuantity} '
            'unit(s) in ${createdBatches.length} batch(es)',
      ),
    );
    await _enqueueTransferSync(
      updated,
      movements,
      key,
      destinationBatches: createdBatches,
    );
    final result = StockTransferMoveResult(
      transfer: updated,
      movements: movements,
      isDuplicate: false,
    );
    _receivedTransferKeys[key] = result;
    return result;
  }

  /// Assigns (or unassigns, with [riderId] null) a rider to a
  /// delivery order (Week 4 Day 2, D121 — SRS D-21).
  ///
  /// This is the ONE assignment write path: the Order Detail
  /// "Assign rider" button, the order form's rider picker (which
  /// saves through `updateOrder` — unchanged) and the Rider Detail
  /// "Assign order" action all end here. It writes the order AND
  /// both rider rows together: the previous rider's `currentOrderId`
  /// is cleared, the new rider's is set to this order, and the
  /// order's `riderId` is updated — so the rider list's "On
  /// delivery" state can never disagree with the order queue.
  ///
  /// Throws [ArgumentError] when the order is Delivered/Cancelled
  /// (read-only — `canEdit`), is not a delivery order, the rider
  /// does not exist, or the rider is inactive.
  Future<Order> assignRider({
    required String orderId,
    required String? riderId,
    String actorId = demoActorId,
    String actorName = demoActorName,
  }) async {
    final order = await orderRepo.getById(orderId);
    if (order == null) {
      throw ArgumentError('No order with id "$orderId".');
    }
    if (order.status == OrderStatus.delivered ||
        order.status == OrderStatus.cancelled) {
      throw ArgumentError(
        'Order ${order.id} is ${order.status.name} — its rider '
        'cannot be changed.',
      );
    }
    if (order.fulfillment != FulfillmentType.delivery) {
      throw ArgumentError(
        'Order ${order.id} is a pickup order — only delivery '
        'orders have a rider.',
      );
    }
    Rider? rider;
    if (riderId != null) {
      rider = await riderRepo.getById(riderId);
      if (rider == null) {
        throw ArgumentError('No rider with id "$riderId".');
      }
      if (!rider.active) {
        throw ArgumentError(
          'Rider ${rider.name} is inactive and cannot take deliveries.',
        );
      }
      if (rider.branchId != null && rider.branchId != order.branchId) {
        throw ArgumentError(
          'Rider ${rider.name} belongs to another branch.',
        );
      }
      if (rider.currentOrderId != null &&
          rider.currentOrderId != order.id) {
        throw ArgumentError(
          'Rider ${rider.name} is already out on order '
          '${rider.currentOrderId}.',
        );
      }
    }
    final previousRiderId = order.riderId;
    final updated = order.copyWith(
      riderId: riderId,
      clearRiderId: riderId == null,
      updatedAt: DateTime.now(),
    );
    await orderRepo.updateOrder(updated);
    if (previousRiderId != null && previousRiderId != riderId) {
      final previous = await riderRepo.getById(previousRiderId);
      if (previous != null && previous.currentOrderId == order.id) {
        await riderRepo.updateRider(
          previous.copyWith(clearCurrentOrderId: true),
        );
      }
    }
    if (rider != null) {
      await riderRepo.updateRider(
        rider.copyWith(currentOrderId: order.id),
      );
    }
    await audit.write(
      AuditLogEntry.create(
        organizationId: organizationId,
        branchId: order.branchId,
        userId: actorId,
        actorName: actorName,
        action: riderId == null
            ? 'order.rider_unassigned'
            : 'order.rider_assigned',
        entityType: 'order',
        entityId: order.id,
        summary: riderId == null
            ? 'Rider removed from order ${order.id} by $actorName'
            : 'Order ${order.id} assigned to rider ${rider!.name} '
                'by $actorName',
      ),
    );
    await syncQueue.enqueue(
      idempotencyKey: 'rider-assign-${order.id}-${DateTime.now().millisecondsSinceEpoch}',
      entityType: 'order',
      entityId: order.id,
      branchId: order.branchId,
      organizationId: organizationId,
      kind: SyncOperationKind.update,
      payload: {
        'path': FirestoreSchema.orderDocPath(order.branchId, order.id),
        'document': _stamped(updated.toMap(), order.branchId),
      },
    );
    return updated;
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
    // D137: the SRS §3.4 `payments` subcollection — one doc per leg,
    // so a split sale's legs are queryable without parsing the sale
    // doc. The sale doc itself also carries the `payments` list
    // (Sale.toMap), like the items.
    for (var i = 0; i < saved.payments.length; i++) {
      batch.set(
        '${FirestoreSchema.salePaymentsPath(saved.branchId, saved.idempotencyKey)}/payment-$i',
        saved.payments[i].toMap(),
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

  /// Builds the Firestore batched-write payload for one stock
  /// transfer step and enqueues it as one sync operation (Week 4
  /// Day 2, D118): the transfer doc update + the stock-transaction
  /// docs for the step's movements + the inventory-doc quantity
  /// updates (+ the new destination batch docs on receive). The
  /// create step enqueues its own create payload in
  /// [createTransfer]; this helper covers approve / reject / cancel
  /// (no movements, no batches) and dispatch / receive.
  Future<void> _enqueueTransferSync(
    StockTransfer transfer,
    List<StockMovement> movements,
    String key, {
    List<InventoryItem>? destinationBatches,
  }) async {
    final batch = LocalWriteBatch();
    batch.set(
      FirestoreSchema.stockTransferDocPath(
        transfer.fromBranchId,
        transfer.id,
      ),
      stockTransferToFirestore(transfer, orgId: organizationId),
    );
    for (final created in destinationBatches ?? const []) {
      batch.set(
        FirestoreSchema.branchDocPath(
          created.branchId,
          FirestoreSchema.batches,
          created.id,
        ),
        _stamped(created.toMap(), created.branchId),
      );
    }
    for (final movement in movements) {
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
    }
    final chunks = batch.chunks();
    await syncQueue.enqueue(
      idempotencyKey: key,
      entityType: 'stockTransfer',
      entityId: transfer.id,
      branchId: transfer.fromBranchId,
      organizationId: organizationId,
      kind: SyncOperationKind.update,
      payload: {
        'path': FirestoreSchema.stockTransferDocPath(
          transfer.fromBranchId,
          transfer.id,
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
    stockTransferRepo: ref.read(stockTransferRepositoryProvider),
    goodsReceiptRepo: ref.read(goodsReceiptRepositoryProvider),
    expenseRepo: ref.read(expenseRepositoryProvider),
    financialTransactionRepo: ref.read(
      financialTransactionRepositoryProvider,
    ),
    dailyClosingRepo: ref.read(dailyClosingRepositoryProvider),
    audit: audit,
    syncQueue: syncQueue,
    engine: engine,
  );
});
