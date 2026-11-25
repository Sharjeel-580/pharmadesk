import 'dart:math';

import '../../models/model_utils.dart';
import 'audit_log.dart';

/// Offline sync queue (SRS §2.5).
///
/// Every offline mutation is stored as a queued operation with a
/// client-generated UUID idempotency key — the same key is used as the
/// Firestore document id, so a retried write can never duplicate
/// (FR-POS-11). Statuses: pending → syncing → synced, or
/// pending → failed (retry with back-off) / conflict (needs a human).
///
/// CONFLICT POLICY (SRS §2.5.4): last-writer-wins per document via
/// `updatedAt` — EXCEPT money and stock documents, which must be
/// flagged as a conflict and resolved by the branch manager (re-assign
/// batch, partial fulfilment, or refund). A conflict is NEVER silently
/// overwritten, and no negative stock is ever created silently.
///
/// PLATFORM NOTE: on the web the queue is in-memory only — it resets
/// when the app restarts — until Firestore exists (Firestore's own
/// offline persistence will take over then). On mobile the
/// sqflite-backed store (`sync_store.dart`) persists the queue across
/// restarts. See `docs/known-limitations.md`.

/// Lifecycle of one queued operation.
enum SyncOperationStatus { pending, syncing, synced, conflict, failed }

/// What the operation does to the document.
enum SyncOperationKind { create, update, delete }

/// Thrown by a sync sender when the server state contradicts the
/// queued write (e.g. the batch no longer has enough stock). The queue
/// marks the operation `conflict` and flags it for review instead of
/// retrying or overwriting.
class SyncConflictException implements Exception {
  SyncConflictException(this.message);
  final String message;

  @override
  String toString() => 'SyncConflictException: $message';
}

/// One queued mutation.
class SyncOperation {
  const SyncOperation({
    required this.id,
    required this.idempotencyKey,
    required this.entityType,
    required this.entityId,
    required this.branchId,
    required this.organizationId,
    required this.kind,
    required this.payload,
    this.status = SyncOperationStatus.pending,
    this.attemptCount = 0,
    this.nextRetryAt,
    this.lastError,
    this.createdAt,
    this.updatedAt,
  });

  factory SyncOperation.create({
    required String idempotencyKey,
    required String entityType,
    required String entityId,
    required String branchId,
    required String organizationId,
    required SyncOperationKind kind,
    required Map<String, dynamic> payload,
    DateTime? createdAt,
  }) {
    final now = createdAt ?? DateTime.now();
    return SyncOperation(
      id: idempotencyKey,
      idempotencyKey: idempotencyKey,
      entityType: entityType,
      entityId: entityId,
      branchId: branchId,
      organizationId: organizationId,
      kind: kind,
      payload: Map.unmodifiable(payload),
      createdAt: now,
      updatedAt: now,
    );
  }

  final String id;

  /// Client UUID — also the Firestore document id for sales/orders.
  final String idempotencyKey;
  final String entityType;
  final String entityId;
  final String branchId;
  final String organizationId;
  final SyncOperationKind kind;

  /// The document payload to write when the operation syncs.
  final Map<String, dynamic> payload;
  final SyncOperationStatus status;
  final int attemptCount;
  final DateTime? nextRetryAt;
  final String? lastError;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// True when this operation touches money or stock: such operations
  /// may never be silently overwritten on conflict (SRS §2.5.4).
  bool get isMoneyOrStock =>
      entityType == 'sale' ||
      entityType == 'order' ||
      entityType == 'stockTransaction' ||
      entityType == 'batch' ||
      entityType == 'customerLedger' ||
      entityType == 'supplierLedger' ||
      entityType == 'financialTransaction';

  /// True when the operation is due for another attempt right now.
  bool isDue(DateTime now) {
    if (status != SyncOperationStatus.pending &&
        status != SyncOperationStatus.failed) {
      return false;
    }
    final retryAt = nextRetryAt;
    return retryAt == null || !retryAt.isAfter(now);
  }

  factory SyncOperation.fromMap(String id, Map<String, dynamic> map) {
    return SyncOperation(
      id: id,
      idempotencyKey: map['idempotencyKey'] as String? ?? id,
      entityType: map['entityType'] as String? ?? '',
      entityId: map['entityId'] as String? ?? '',
      branchId: map['branchId'] as String? ?? '',
      organizationId: map['organizationId'] as String? ?? '',
      kind: SyncOperationKind.values.firstWhere(
        (kind) => kind.name == map['kind'],
        orElse: () => SyncOperationKind.create,
      ),
      payload: Map<String, dynamic>.from((map['payload'] as Map?) ?? const {}),
      status: SyncOperationStatus.values.firstWhere(
        (status) => status.name == map['status'],
        orElse: () => SyncOperationStatus.pending,
      ),
      attemptCount: (map['attemptCount'] as num?)?.toInt() ?? 0,
      nextRetryAt: parseDate(map['nextRetryAt']),
      lastError: map['lastError'] as String?,
      createdAt: parseDate(map['createdAt']),
      updatedAt: parseDate(map['updatedAt']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'idempotencyKey': idempotencyKey,
      'entityType': entityType,
      'entityId': entityId,
      'branchId': branchId,
      'organizationId': organizationId,
      'kind': kind.name,
      'payload': payload,
      'status': status.name,
      'attemptCount': attemptCount,
      'nextRetryAt': dateToMap(nextRetryAt),
      'lastError': lastError,
      'createdAt': dateToMap(createdAt),
      'updatedAt': dateToMap(updatedAt),
    };
  }

  SyncOperation copyWith({
    SyncOperationStatus? status,
    int? attemptCount,
    DateTime? nextRetryAt,
    bool clearNextRetryAt = false,
    String? lastError,
    bool clearLastError = false,
    DateTime? updatedAt,
  }) {
    return SyncOperation(
      id: id,
      idempotencyKey: idempotencyKey,
      entityType: entityType,
      entityId: entityId,
      branchId: branchId,
      organizationId: organizationId,
      kind: kind,
      payload: payload,
      status: status ?? this.status,
      attemptCount: attemptCount ?? this.attemptCount,
      nextRetryAt: clearNextRetryAt ? null : (nextRetryAt ?? this.nextRetryAt),
      lastError: clearLastError ? null : (lastError ?? this.lastError),
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

/// Retry back-off: 2s, 4s, 8s, … doubling, capped at 5 minutes
/// (SRS §2.5.6). Attempt 0 has no delay.
Duration backoffForAttempt(int attempt) {
  if (attempt <= 0) return Duration.zero;
  final seconds = min(1 << attempt, 300);
  return Duration(seconds: seconds);
}

/// Generates a client idempotency key: `<prefix>-<epoch-millis>-<random>`.
String newIdempotencyKey(String prefix) {
  final random = Random().nextInt(1 << 32).toRadixString(16).padLeft(8, '0');
  return '$prefix-${DateTime.now().millisecondsSinceEpoch}-$random';
}

/// Pluggable queue storage. Implementations must dedupe on
/// [enqueue]: an operation with an idempotency key that already exists
/// is returned as-is, never stored twice.
abstract class SyncStore {
  Future<SyncOperation> enqueue(SyncOperation operation);
  Future<SyncOperation?> byIdempotencyKey(String key);
  Future<List<SyncOperation>> pending({DateTime? now});
  Future<List<SyncOperation>> all();
  Future<void> update(SyncOperation operation);
  Future<int> pendingCount();
}

/// In-memory store: works on web and in tests. Resets on restart —
/// on the web that is the documented behaviour until Firestore exists.
class InMemorySyncStore implements SyncStore {
  final Map<String, SyncOperation> _ops = {};

  @override
  Future<SyncOperation> enqueue(SyncOperation operation) async {
    final existing = _ops[operation.idempotencyKey];
    if (existing != null) return existing;
    _ops[operation.idempotencyKey] = operation;
    return operation;
  }

  @override
  Future<SyncOperation?> byIdempotencyKey(String key) async => _ops[key];

  @override
  Future<List<SyncOperation>> pending({DateTime? now}) async {
    final reference = now ?? DateTime.now();
    final due = _ops.values.where((op) => op.isDue(reference)).toList()
      ..sort(
        (a, b) =>
            (a.createdAt ?? DateTime(0)).compareTo(b.createdAt ?? DateTime(0)),
      );
    return List.unmodifiable(due);
  }

  @override
  Future<List<SyncOperation>> all() async =>
      List.unmodifiable(_ops.values.toList());

  @override
  Future<void> update(SyncOperation operation) async {
    _ops[operation.idempotencyKey] = operation;
  }

  @override
  Future<int> pendingCount() async {
    final now = DateTime.now();
    return _ops.values.where((op) => op.isDue(now)).length;
  }
}

/// Outcome of one [SyncQueue.processNext] attempt.
enum SyncProcessOutcome { synced, failed, conflict, nothingPending }

class SyncProcessResult {
  const SyncProcessResult({required this.outcome, this.operation, this.error});

  final SyncProcessOutcome outcome;
  final SyncOperation? operation;
  final String? error;
}

/// The queue itself: enqueue + process with retry/back-off.
///
/// [send] is the transport — in production it is the Firestore write
/// (batched write / transaction with the idempotency key as doc id);
/// until Firestore exists the layer enqueues only, and tests inject a
/// fake sender. A `false` return or a thrown exception means "not
/// synced yet, retry later"; a [SyncConflictException] means "flag for
/// human review, never retry silently".
class SyncQueue {
  SyncQueue(this.store, {DateTime Function()? nowProvider})
    : _now = nowProvider ?? DateTime.now;

  final SyncStore store;
  final DateTime Function() _now;

  DateTime get now => _now();

  /// When the last operation synced successfully (`null` = nothing
  /// has synced yet in this session / since the store was created).
  /// Week 3 Day 3 (D108): the sync-status UI reads this — it is the
  /// only "last sync" the app can state honestly, because until the
  /// Firebase project exists the queue is only enqueued, never
  /// drained. Set only on a real successful send, never on enqueue.
  DateTime? lastSyncedAt;

  /// Enqueues a mutation. Dedupe: the same idempotency key always
  /// returns the SAME operation — a retry can never create a second
  /// queued write for the same document.
  Future<SyncOperation> enqueue({
    required String idempotencyKey,
    required String entityType,
    required String entityId,
    required String branchId,
    required String organizationId,
    required SyncOperationKind kind,
    required Map<String, dynamic> payload,
  }) {
    return store.enqueue(
      SyncOperation.create(
        idempotencyKey: idempotencyKey,
        entityType: entityType,
        entityId: entityId,
        branchId: branchId,
        organizationId: organizationId,
        kind: kind,
        payload: payload,
        createdAt: now,
      ),
    );
  }

  Future<int> pendingCount() => store.pendingCount();

  Future<List<SyncOperation>> pendingOperations() => store.pending(now: now);

  /// Attempts the oldest due operation once.
  Future<SyncProcessResult> processNext(
    Future<bool> Function(SyncOperation operation) send, {
    AuditLogWriter? audit,
    String auditUserId = 'system',
    String auditActorName = 'Sync',
  }) async {
    final due = await store.pending(now: now);
    if (due.isEmpty) {
      return const SyncProcessResult(
        outcome: SyncProcessOutcome.nothingPending,
      );
    }
    final operation = due.first;
    await store.update(
      operation.copyWith(status: SyncOperationStatus.syncing, updatedAt: now),
    );
    try {
      final synced = await send(operation);
      if (!synced) {
        final failed = await _fail(operation, 'Sender reported not synced.');
        return failed;
      }
      final done = operation.copyWith(
        status: SyncOperationStatus.synced,
        clearNextRetryAt: true,
        clearLastError: true,
        updatedAt: now,
      );
      await store.update(done);
      lastSyncedAt = now;
      return SyncProcessResult(
        outcome: SyncProcessOutcome.synced,
        operation: done,
      );
    } on SyncConflictException catch (error) {
      // Money/stock conflicts are flagged, never retried silently.
      final conflicted = operation.copyWith(
        status: SyncOperationStatus.conflict,
        lastError: error.message,
        updatedAt: now,
      );
      await store.update(conflicted);
      if (audit != null) {
        await audit.write(
          AuditLogEntry.syncConflict(
            organizationId: operation.organizationId,
            branchId: operation.branchId,
            userId: auditUserId,
            actorName: auditActorName,
            entityType: operation.entityType,
            entityId: operation.entityId,
            reason:
                'Sync conflict for ${operation.entityType} '
                '${operation.entityId}: ${error.message}',
          ),
        );
      }
      return SyncProcessResult(
        outcome: SyncProcessOutcome.conflict,
        operation: conflicted,
        error: error.message,
      );
    } catch (error) {
      return _fail(operation, error.toString());
    }
  }

  /// Drains the queue until nothing is due (each op attempted once
  /// per call). Returns how many operations synced.
  Future<int> processAll(
    Future<bool> Function(SyncOperation operation) send, {
    AuditLogWriter? audit,
  }) async {
    var synced = 0;
    while (true) {
      final result = await processNext(send, audit: audit);
      if (result.outcome == SyncProcessOutcome.synced) {
        synced++;
        continue;
      }
      break;
    }
    return synced;
  }

  Future<SyncProcessResult> _fail(SyncOperation operation, String error) async {
    final attempts = operation.attemptCount + 1;
    final failed = operation.copyWith(
      status: SyncOperationStatus.failed,
      attemptCount: attempts,
      nextRetryAt: now.add(backoffForAttempt(attempts)),
      lastError: error,
      updatedAt: now,
    );
    await store.update(failed);
    return SyncProcessResult(
      outcome: SyncProcessOutcome.failed,
      operation: failed,
      error: error,
    );
  }
}
