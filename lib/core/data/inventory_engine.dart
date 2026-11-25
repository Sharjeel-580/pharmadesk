import '../../features/inventory/inventory_logic.dart';
import '../../models/inventory_item.dart';
import '../../models/model_utils.dart';
import 'audit_log.dart';
import 'firestore_schema.dart';

/// Production inventory engine (SRS §2.5.4, §3.3).
///
/// Owns the local stock state for one branch session: batch snapshots,
/// per-medicine counters (`quantityOnHand` / `quantityReserved`),
/// reservations, and the append-only stock-transactions ledger.
///
/// THE RULES:
/// - The expired-never-sellable guard is NOT re-implemented here: every
///   allocation walks [fefoBatches] / [isBatchSellable] from
///   `inventory_logic.dart` (D30). An expired batch can never be
///   reserved or sold, in any code path.
/// - Reserve → confirm on payment / release on cancel. A reservation
///   holds units out of the sellable pool without moving stock; only
///   `confirm` decrements `quantityOnHand` and writes ledger entries.
/// - Every confirmed movement updates the batch snapshot, the counter
///   and the ledger together, synchronously, before any `await` — so
///   the three can never drift apart in the local layer.
/// - Writes are expressed as a [LocalWriteBatch] and chunked at
///   [FirestoreSchema.maxFirestoreBatchWrites] (500), the same limit
///   Firestore enforces server-side (SRS §3).

/// Stock movement kind. [firestoreValue] is the string SRS §3.3
/// stores in `stockTransactions.type`.
enum StockMovementType {
  receive,
  sale,
  saleReturn,
  adjustment,
  transferIn,
  transferOut,
  damage,
  expiry,
}

extension StockMovementTypeFirestore on StockMovementType {
  String get firestoreValue => switch (this) {
    StockMovementType.receive => 'receive',
    StockMovementType.sale => 'sale',
    StockMovementType.saleReturn => 'return',
    StockMovementType.adjustment => 'adjustment',
    StockMovementType.transferIn => 'transfer_in',
    StockMovementType.transferOut => 'transfer_out',
    StockMovementType.damage => 'damage',
    StockMovementType.expiry => 'expiry',
  };
}

StockMovementType stockMovementTypeFromFirestore(String? value) =>
    switch (value) {
      'receive' => StockMovementType.receive,
      'sale' => StockMovementType.sale,
      'return' => StockMovementType.saleReturn,
      'adjustment' => StockMovementType.adjustment,
      'transfer_in' => StockMovementType.transferIn,
      'transfer_out' => StockMovementType.transferOut,
      'damage' => StockMovementType.damage,
      'expiry' => StockMovementType.expiry,
      _ => StockMovementType.adjustment,
    };

/// One row of the append-only stock-transactions ledger (SRS §3.3).
/// `quantity` is signed: negative = stock out (sale), positive =
/// stock in (receive / return).
class StockMovement {
  const StockMovement({
    required this.id,
    required this.organizationId,
    required this.branchId,
    required this.medicineId,
    this.batchId,
    required this.type,
    required this.quantity,
    this.unitCostMinor = 0,
    this.referenceType,
    this.referenceId,
    this.userId,
    this.reason,
    this.approvedBy,
    this.createdAt,
  });

  factory StockMovement.create({
    required String organizationId,
    required String branchId,
    required String medicineId,
    String? batchId,
    required StockMovementType type,
    required int quantity,
    int unitCostMinor = 0,
    String? referenceType,
    String? referenceId,
    String? userId,
    String? reason,
    String? approvedBy,
    DateTime? createdAt,
  }) {
    return StockMovement(
      id: '',
      organizationId: organizationId,
      branchId: branchId,
      medicineId: medicineId,
      batchId: batchId,
      type: type,
      quantity: quantity,
      unitCostMinor: unitCostMinor,
      referenceType: referenceType,
      referenceId: referenceId,
      userId: userId,
      reason: reason,
      approvedBy: approvedBy,
      createdAt: createdAt ?? DateTime.now(),
    );
  }

  final String id;
  final String organizationId;
  final String branchId;
  final String medicineId;
  final String? batchId;
  final StockMovementType type;

  /// Signed units.
  final int quantity;
  final int unitCostMinor;
  final String? referenceType;
  final String? referenceId;
  final String? userId;
  final String? reason;
  final String? approvedBy;
  final DateTime? createdAt;

  factory StockMovement.fromMap(String id, Map<String, dynamic> map) {
    return StockMovement(
      id: id,
      organizationId: map['organizationId'] as String? ?? '',
      branchId: map['branchId'] as String? ?? '',
      medicineId: map['medicineId'] as String? ?? '',
      batchId: map['batchId'] as String?,
      type: stockMovementTypeFromFirestore(map['type'] as String?),
      quantity: (map['quantity'] as num?)?.toInt() ?? 0,
      unitCostMinor: (map['unitCost'] as num?)?.toInt() ?? 0,
      referenceType: map['referenceType'] as String?,
      referenceId: map['referenceId'] as String?,
      userId: map['userId'] as String?,
      reason: map['reason'] as String?,
      approvedBy: map['approvedBy'] as String?,
      createdAt: parseDate(map['createdAt']),
    );
  }

  /// Firestore shape (SRS §3.3 `stockTransactions`).
  Map<String, dynamic> toMap() {
    return {
      'organizationId': organizationId,
      'branchId': branchId,
      'medicineId': medicineId,
      'batchId': batchId,
      'type': type.firestoreValue,
      'quantity': quantity,
      'unitCost': unitCostMinor,
      'referenceType': referenceType,
      'referenceId': referenceId,
      'userId': userId,
      'reason': reason,
      'approvedBy': approvedBy,
      'createdAt': dateToMap(createdAt),
      'updatedAt': dateToMap(createdAt),
    };
  }
}

/// Append-only stock-transactions ledger. Entries are added, never
/// edited or removed — the ledger is the source of truth for stock
/// (SRS §3, "history collections are append-only").
class StockLedger {
  final List<StockMovement> _entries = [];

  StockMovement append(StockMovement movement) {
    final saved = StockMovement(
      id: 'txn-${_entries.length + 1}',
      organizationId: movement.organizationId,
      branchId: movement.branchId,
      medicineId: movement.medicineId,
      batchId: movement.batchId,
      type: movement.type,
      quantity: movement.quantity,
      unitCostMinor: movement.unitCostMinor,
      referenceType: movement.referenceType,
      referenceId: movement.referenceId,
      userId: movement.userId,
      reason: movement.reason,
      approvedBy: movement.approvedBy,
      createdAt: movement.createdAt ?? DateTime.now(),
    );
    _entries.add(saved);
    return saved;
  }

  List<StockMovement> get all => List.unmodifiable(_entries);

  List<StockMovement> entriesFor({String? medicineId, String? batchId}) =>
      List.unmodifiable(
        _entries.where((entry) {
          if (medicineId != null && entry.medicineId != medicineId) {
            return false;
          }
          if (batchId != null && entry.batchId != batchId) return false;
          return true;
        }),
      );
}

/// Per-medicine stock counters (SRS §3.3 `inventory` doc):
/// on hand, reserved, and sellable = on hand − reserved.
class StockCounter {
  const StockCounter({
    required this.quantityOnHand,
    required this.quantityReserved,
  });

  final int quantityOnHand;
  final int quantityReserved;

  /// Units that may still be sold or reserved.
  int get available => quantityOnHand - quantityReserved;

  StockCounter copyWith({int? quantityOnHand, int? quantityReserved}) {
    return StockCounter(
      quantityOnHand: quantityOnHand ?? this.quantityOnHand,
      quantityReserved: quantityReserved ?? this.quantityReserved,
    );
  }

  Map<String, dynamic> toMap() => {
    'quantityOnHand': quantityOnHand,
    'quantityReserved': quantityReserved,
  };
}

/// Lifecycle of a stock reservation.
enum ReservationStatus { reserved, confirmed, released }

/// Units held out of the sellable pool for one in-flight sale, taken
/// from one FEFO batch. A reservation moves no stock — only `confirm`
/// decrements, only `release` frees the hold.
class StockReservation {
  const StockReservation({
    required this.id,
    required this.saleKey,
    required this.branchId,
    required this.medicineId,
    required this.batchId,
    required this.quantity,
    this.status = ReservationStatus.reserved,
    this.createdAt,
  });

  final String id;
  final String saleKey;
  final String branchId;
  final String medicineId;
  final String batchId;
  final int quantity;
  final ReservationStatus status;
  final DateTime? createdAt;

  StockReservation copyWith({ReservationStatus? status}) {
    return StockReservation(
      id: id,
      saleKey: saleKey,
      branchId: branchId,
      medicineId: medicineId,
      batchId: batchId,
      quantity: quantity,
      status: status ?? this.status,
      createdAt: createdAt,
    );
  }
}

/// One operation inside a [LocalWriteBatch].
enum WriteOperationKind { set, update, delete }

class WriteOperation {
  const WriteOperation({required this.path, required this.kind, this.data});

  factory WriteOperation.fromMap(Map<String, dynamic> map) {
    return WriteOperation(
      path: map['path'] as String? ?? '',
      kind: WriteOperationKind.values.firstWhere(
        (kind) => kind.name == map['kind'],
        orElse: () => WriteOperationKind.set,
      ),
      data: map['data'] == null
          ? null
          : Map<String, dynamic>.from(map['data'] as Map),
    );
  }

  final String path;
  final WriteOperationKind kind;
  final Map<String, dynamic>? data;

  Map<String, dynamic> toMap() => {
    'path': path,
    'kind': kind.name,
    'data': data,
  };
}

/// A batched write, expressed locally before it is executed.
///
/// Mirrors Firestore's `WriteBatch`: a list of set/update/delete
/// operations applied as one unit, chunked at 500 operations
/// ([FirestoreSchema.maxFirestoreBatchWrites]). The production
/// Firestore implementation executes each chunk as one real batched
/// write; the local layer executes the equivalent repository calls.
/// Chunking is pure and unit-tested — a 1,200-op batch becomes
/// 500 / 500 / 200, never a 501-op write.
class LocalWriteBatch {
  LocalWriteBatch([List<WriteOperation>? operations])
    : _operations = List.of(operations ?? const []);

  final List<WriteOperation> _operations;

  void set(String path, Map<String, dynamic> data) {
    _operations.add(
      WriteOperation(path: path, kind: WriteOperationKind.set, data: data),
    );
  }

  void update(String path, Map<String, dynamic> data) {
    _operations.add(
      WriteOperation(path: path, kind: WriteOperationKind.update, data: data),
    );
  }

  void delete(String path) {
    _operations.add(
      WriteOperation(path: path, kind: WriteOperationKind.delete),
    );
  }

  int get operationCount => _operations.length;
  bool get isEmpty => _operations.isEmpty;
  List<WriteOperation> get operations => List.unmodifiable(_operations);

  /// Splits the batch into chunks of at most [maxOps] operations
  /// (default 500). A batch that fits stays a single chunk.
  List<LocalWriteBatch> chunks({int maxOps = maxFirestoreBatchWrites}) {
    if (_operations.length <= maxOps) return [this];
    final result = <LocalWriteBatch>[];
    for (var i = 0; i < _operations.length; i += maxOps) {
      final end = (i + maxOps).clamp(0, _operations.length);
      result.add(LocalWriteBatch(_operations.sublist(i, end)));
    }
    return result;
  }

  Map<String, dynamic> toMap() => {
    'operations': _operations.map((op) => op.toMap()).toList(),
  };
}

/// The inventory engine: reservations, FEFO allocation, counters and
/// the append-only ledger, over a snapshot of the branch's batches.
///
/// The engine is the ONLY place that decides which batch a sale takes
/// from, and it reuses the Day 5 shared guard
/// ([isBatchSellable] / [fefoBatches]) — expired batches are never
/// sellable here, exactly as in the POS and the order form (D30).
class InventoryEngine {
  InventoryEngine({
    required this.organizationId,
    required this.audit,
    DateTime Function()? nowProvider,
  }) : _now = nowProvider ?? DateTime.now;

  final String organizationId;
  final AuditLogWriter audit;
  final DateTime Function() _now;

  final Map<String, InventoryItem> _batches = {};
  final Map<String, StockCounter> _counters = {};
  final Map<String, StockReservation> _reservations = {};
  final StockLedger ledger = StockLedger();

  DateTime get now => _now();

  /// Loads the branch's batch rows (from the inventory repository).
  /// Counters start at the physical quantities; nothing is reserved.
  void loadBatches(List<InventoryItem> batches) {
    _batches.clear();
    _counters.clear();
    _reservations.clear();
    for (final batch in batches) {
      _batches[batch.id] = batch;
      final counter =
          _counters[batch.medicineId] ??
          const StockCounter(quantityOnHand: 0, quantityReserved: 0);
      _counters[batch.medicineId] = counter.copyWith(
        quantityOnHand: counter.quantityOnHand + batch.quantity,
      );
    }
  }

  InventoryItem? batchById(String batchId) => _batches[batchId];

  StockCounter counterFor(String medicineId) =>
      _counters[medicineId] ??
      const StockCounter(quantityOnHand: 0, quantityReserved: 0);

  /// Units of one batch already held by open reservations.
  int reservedForBatch(String batchId) {
    var reserved = 0;
    for (final reservation in _reservations.values) {
      if (reservation.batchId == batchId &&
          reservation.status == ReservationStatus.reserved) {
        reserved += reservation.quantity;
      }
    }
    return reserved;
  }

  /// Units of one batch that may still be sold right now:
  /// on hand, sellable by the Day 5 guard, minus open reservations.
  int sellableAvailableForBatch(String batchId, {DateTime? now}) {
    final batch = _batches[batchId];
    if (batch == null) return 0;
    if (!isBatchSellable(batch, now: now ?? this.now)) return 0;
    final available = batch.quantity - reservedForBatch(batchId);
    return available < 0 ? 0 : available;
  }

  /// Reserves [quantity] units of [medicineId] for the sale identified
  /// by [saleKey], taking FEFO batches first (earliest expiry first,
  /// expired never). Returns one reservation per batch chunk.
  ///
  /// Throws [ArgumentError] when the sellable, unreserved stock is
  /// short — the caller completes nothing and no reservation is kept.
  List<StockReservation> reserve({
    required String branchId,
    required String medicineId,
    required int quantity,
    required String saleKey,
    DateTime? now,
  }) {
    final reference = now ?? this.now;
    if (quantity <= 0) {
      throw ArgumentError('Reservation quantity must be above zero.');
    }
    final batches = _batches.values
        .where((batch) => batch.medicineId == medicineId)
        .toList();
    // FEFO order, sellable only — the Day 5 guard decides.
    final candidates = fefoBatches(batches)
        .where((batch) => isBatchSellable(batch, now: reference))
        .toList();
    var remaining = quantity;
    final created = <StockReservation>[];
    for (final batch in candidates) {
      if (remaining <= 0) break;
      final available = batch.quantity - reservedForBatch(batch.id);
      if (available <= 0) continue;
      final take = remaining < available ? remaining : available;
      final reservation = StockReservation(
        id: 'res-$saleKey-${batch.id}',
        saleKey: saleKey,
        branchId: branchId,
        medicineId: medicineId,
        batchId: batch.id,
        quantity: take,
        createdAt: reference,
      );
      _reservations[reservation.id] = reservation;
      created.add(reservation);
      remaining -= take;
    }
    if (remaining > 0) {
      // Roll back the partial hold: a failed reservation holds nothing.
      for (final reservation in created) {
        _reservations.remove(reservation.id);
      }
      final sellable = candidates.fold(
        0,
        (sum, batch) => sum + (batch.quantity - reservedForBatch(batch.id)),
      );
      throw ArgumentError(
        'Only $sellable unit(s) of $medicineId sellable in stock, '
        'need $quantity.',
      );
    }
    // Counters move with the reservation, synchronously.
    final counter = counterFor(medicineId);
    _counters[medicineId] = counter.copyWith(
      quantityReserved: counter.quantityReserved + quantity,
    );
    return List.unmodifiable(created);
  }

  /// Reserves the EXACT batches a caller already allocated (e.g. the
  /// FEFO chunks from `allocateFefo` in the POS). Each batch is
  /// re-validated here — sellable by the Day 5 guard, with enough
  /// unreserved stock — so a stale allocation can never reserve an
  /// expired or short batch. Throws [ArgumentError] on the first bad
  /// batch; a failed call holds nothing.
  List<StockReservation> reserveBatches({
    required String branchId,
    required String saleKey,
    required List<({String batchId, int quantity})> decrements,
    DateTime? now,
  }) {
    final reference = now ?? this.now;
    for (final decrement in decrements) {
      if (decrement.quantity <= 0) {
        throw ArgumentError('Reservation quantity must be above zero.');
      }
      final batch = _batches[decrement.batchId];
      if (batch == null) {
        throw ArgumentError('No batch with id "${decrement.batchId}".');
      }
      if (!isBatchSellable(batch, now: reference)) {
        throw ArgumentError(
          'Batch ${batch.batchNo ?? batch.id} is not sellable '
          '(expired or empty).',
        );
      }
      final available = batch.quantity - reservedForBatch(batch.id);
      if (decrement.quantity > available) {
        throw ArgumentError(
          'Batch ${batch.batchNo ?? batch.id}: only $available unit(s) '
          'available, need ${decrement.quantity}.',
        );
      }
    }
    final created = <StockReservation>[];
    for (final decrement in decrements) {
      final batch = _batches[decrement.batchId]!;
      final reservation = StockReservation(
        id: 'res-$saleKey-${batch.id}',
        saleKey: saleKey,
        branchId: branchId,
        medicineId: batch.medicineId,
        batchId: batch.id,
        quantity: decrement.quantity,
        createdAt: reference,
      );
      _reservations[reservation.id] = reservation;
      created.add(reservation);
      final counter = counterFor(batch.medicineId);
      _counters[batch.medicineId] = counter.copyWith(
        quantityReserved: counter.quantityReserved + decrement.quantity,
      );
    }
    return List.unmodifiable(created);
  }

  /// Confirms open reservations: the held units leave the shelf.
  /// Batch quantities and counters drop together, one ledger entry per
  /// batch chunk (type `sale`, signed negative) and one audit entry
  /// per batch chunk are written. Returns the ledger movements.
  Future<List<StockMovement>> confirm({
    required List<StockReservation> reservations,
    required String saleId,
    required String userId,
    required String actorName,
  }) async {
    final movements = <StockMovement>[];
    for (final reservation in reservations) {
      final held = _reservations[reservation.id];
      if (held == null || held.status != ReservationStatus.reserved) {
        continue;
      }
      final batch = _batches[held.batchId];
      if (batch == null) continue;
      // Batch snapshot, counter and ledger move together.
      final before = batch.quantity;
      final after = before - held.quantity;
      _batches[held.batchId] = batch.copyWith(quantity: after, updatedAt: now);
      final counter = counterFor(held.medicineId);
      _counters[held.medicineId] = counter.copyWith(
        quantityOnHand: counter.quantityOnHand - held.quantity,
        quantityReserved: counter.quantityReserved - held.quantity,
      );
      _reservations[held.id] = held.copyWith(
        status: ReservationStatus.confirmed,
      );
      final movement = ledger.append(
        StockMovement.create(
          organizationId: organizationId,
          branchId: held.branchId,
          medicineId: held.medicineId,
          batchId: held.batchId,
          type: StockMovementType.sale,
          quantity: -held.quantity,
          unitCostMinor: batch.costMinor,
          referenceType: 'sale',
          referenceId: saleId,
          userId: userId,
          reason: 'POS sale',
          createdAt: now,
        ),
      );
      movements.add(movement);
      await audit.write(
        AuditLogEntry.stockMovement(
          organizationId: organizationId,
          branchId: held.branchId,
          userId: userId,
          actorName: actorName,
          movementType: 'sale',
          batchId: held.batchId,
          medicineId: held.medicineId,
          quantityDelta: -held.quantity,
          quantityBefore: before,
          quantityAfter: after,
          referenceId: saleId,
        ),
      );
    }
    return movements;
  }

  /// Releases open reservations (sale cancelled / failed): the held
  /// units return to the sellable pool. No stock moves, so no ledger
  /// entry — the release is recorded in the audit log only.
  Future<void> release({
    required List<StockReservation> reservations,
    required String userId,
    required String actorName,
    String reason = 'Sale cancelled',
  }) async {
    for (final reservation in reservations) {
      final held = _reservations[reservation.id];
      if (held == null || held.status != ReservationStatus.reserved) {
        continue;
      }
      _reservations[held.id] = held.copyWith(
        status: ReservationStatus.released,
      );
      final counter = counterFor(held.medicineId);
      _counters[held.medicineId] = counter.copyWith(
        quantityReserved: counter.quantityReserved - held.quantity,
      );
      await audit.write(
        AuditLogEntry.create(
          organizationId: organizationId,
          branchId: held.branchId,
          userId: userId,
          actorName: actorName,
          action: 'stock.reservation_released',
          entityType: 'sale',
          entityId: held.saleKey,
          summary:
              '$reason — ${held.quantity} unit(s) of '
              '${held.medicineId} released from batch ${held.batchId}',
        ),
      );
    }
  }

  /// Releases every open reservation held for one sale key.
  Future<void> releaseAllForSale(
    String saleKey, {
    required String userId,
    required String actorName,
    String reason = 'Sale cancelled',
  }) async {
    final open = _reservations.values
        .where(
          (reservation) =>
              reservation.saleKey == saleKey &&
              reservation.status == ReservationStatus.reserved,
        )
        .toList();
    await release(
      reservations: open,
      userId: userId,
      actorName: actorName,
      reason: reason,
    );
  }

  /// Adjusts one batch's quantity (damage / found / write-off / count
  /// correction). Never below zero. Updates the batch snapshot, the
  /// counter and the ledger together, plus one audit entry.
  Future<StockMovement> adjust({
    required String batchId,
    required int deltaQty,
    required String reason,
    required String userId,
    required String actorName,
    String? referenceId,
  }) async {
    final batch = _batches[batchId];
    if (batch == null) {
      throw ArgumentError('No batch with id "$batchId".');
    }
    if (deltaQty == 0) {
      throw ArgumentError('Adjustment quantity cannot be zero.');
    }
    final before = batch.quantity;
    final after = before + deltaQty;
    if (after < 0) {
      throw ArgumentError(
        'Cannot remove $deltaQty units — only $before on hand.',
      );
    }
    _batches[batchId] = batch.copyWith(quantity: after, updatedAt: now);
    final counter = counterFor(batch.medicineId);
    _counters[batch.medicineId] = counter.copyWith(
      quantityOnHand: counter.quantityOnHand + deltaQty,
    );
    final movement = ledger.append(
      StockMovement.create(
        organizationId: organizationId,
        branchId: batch.branchId,
        medicineId: batch.medicineId,
        batchId: batchId,
        type: StockMovementType.adjustment,
        quantity: deltaQty,
        unitCostMinor: batch.costMinor,
        referenceType: 'adjustment',
        referenceId: referenceId,
        userId: userId,
        reason: reason,
        createdAt: now,
      ),
    );
    await audit.write(
      AuditLogEntry.stockMovement(
        organizationId: organizationId,
        branchId: batch.branchId,
        userId: userId,
        actorName: actorName,
        movementType: 'adjustment',
        batchId: batchId,
        medicineId: batch.medicineId,
        quantityDelta: deltaQty,
        quantityBefore: before,
        quantityAfter: after,
        referenceId: referenceId,
      ),
    );
    return movement;
  }

  /// Open reservations for one sale key (used by the data layer to
  /// apply the same decrements to the repository).
  List<StockReservation> reservationsForSale(String saleKey) =>
      List.unmodifiable(
        _reservations.values.where(
          (reservation) => reservation.saleKey == saleKey,
        ),
      );
}
