import '../../models/model_utils.dart';

/// Append-only audit log (SRS §3.1 `auditLogs`).
///
/// Every stock or money mutation the production data layer makes leaves
/// one entry here: who did it, what changed, on which entity, in which
/// branch, and when. Entries are NEVER edited or deleted — corrections
/// are new entries. The local writer is in-memory until the Firebase
/// project exists; the Firestore implementation writes to the root
/// `auditLogs` collection (same shape, same field names).

/// One audit entry. `before` / `after` are short human-readable
/// summaries (e.g. `qty 12 -> 9`), not full document snapshots — full
/// snapshots would burn the Firestore write quota and 1 MiB doc limit.
class AuditLogEntry {
  const AuditLogEntry({
    required this.id,
    required this.organizationId,
    required this.branchId,
    required this.userId,
    required this.actorName,
    required this.action,
    required this.entityType,
    required this.entityId,
    this.summary = '',
    this.before,
    this.after,
    this.createdAt,
  });

  factory AuditLogEntry.create({
    required String organizationId,
    required String branchId,
    required String userId,
    required String actorName,
    required String action,
    required String entityType,
    required String entityId,
    String summary = '',
    String? before,
    String? after,
    DateTime? createdAt,
  }) {
    return AuditLogEntry(
      id: '',
      organizationId: organizationId,
      branchId: branchId,
      userId: userId,
      actorName: actorName,
      action: action,
      entityType: entityType,
      entityId: entityId,
      summary: summary,
      before: before,
      after: after,
      createdAt: createdAt ?? DateTime.now(),
    );
  }

  /// Stock movement on a batch (sale / receive / adjustment / count).
  factory AuditLogEntry.stockMovement({
    required String organizationId,
    required String branchId,
    required String userId,
    required String actorName,
    required String movementType,
    required String batchId,
    required String medicineId,
    required int quantityDelta,
    required int quantityBefore,
    required int quantityAfter,
    String? referenceId,
  }) {
    return AuditLogEntry.create(
      organizationId: organizationId,
      branchId: branchId,
      userId: userId,
      actorName: actorName,
      action: 'stock.$movementType',
      entityType: 'batch',
      entityId: batchId,
      summary:
          '$movementType $quantityDelta units of $medicineId'
          '${referenceId == null ? '' : ' (ref $referenceId)'}',
      before: 'qty $quantityBefore',
      after: 'qty $quantityAfter',
    );
  }

  /// A sale was committed (or a duplicate commit was recognised and
  /// skipped — see [AuditLogEntry.duplicateSale]).
  factory AuditLogEntry.saleCommitted({
    required String organizationId,
    required String branchId,
    required String userId,
    required String actorName,
    required String saleId,
    required String invoiceNumber,
    required int totalMinor,
  }) {
    return AuditLogEntry.create(
      organizationId: organizationId,
      branchId: branchId,
      userId: userId,
      actorName: actorName,
      action: 'sale.committed',
      entityType: 'sale',
      entityId: saleId,
      summary: 'Sale $invoiceNumber committed, total $totalMinor paisa',
    );
  }

  /// A retried commit arrived with an idempotency key that was already
  /// committed: no stock or money moved, the original sale was returned.
  factory AuditLogEntry.duplicateSale({
    required String organizationId,
    required String branchId,
    required String userId,
    required String actorName,
    required String saleId,
    required String idempotencyKey,
  }) {
    return AuditLogEntry.create(
      organizationId: organizationId,
      branchId: branchId,
      userId: userId,
      actorName: actorName,
      action: 'sale.duplicate_skipped',
      entityType: 'sale',
      entityId: saleId,
      summary: 'Duplicate commit skipped for key $idempotencyKey',
    );
  }

  /// A money movement on a ledger (customer khata / supplier ledger).
  factory AuditLogEntry.moneyMovement({
    required String organizationId,
    required String branchId,
    required String userId,
    required String actorName,
    required String ledgerType,
    required String ledgerOwnerId,
    required String entryKind,
    required int amountMinor,
    required int balanceAfterMinor,
    String? referenceId,
  }) {
    return AuditLogEntry.create(
      organizationId: organizationId,
      branchId: branchId,
      userId: userId,
      actorName: actorName,
      action: 'ledger.$entryKind',
      entityType: ledgerType,
      entityId: ledgerOwnerId,
      summary:
          '$entryKind $amountMinor paisa'
          '${referenceId == null ? '' : ' (ref $referenceId)'}',
      after: 'balance $balanceAfterMinor',
    );
  }

  /// A sync conflict was flagged for human review (money/stock docs
  /// are never silently overwritten — see `sync_queue.dart`).
  factory AuditLogEntry.syncConflict({
    required String organizationId,
    required String branchId,
    required String userId,
    required String actorName,
    required String entityType,
    required String entityId,
    required String reason,
  }) {
    return AuditLogEntry.create(
      organizationId: organizationId,
      branchId: branchId,
      userId: userId,
      actorName: actorName,
      action: 'sync.conflict',
      entityType: entityType,
      entityId: entityId,
      summary: reason,
    );
  }

  final String id;
  final String organizationId;
  final String branchId;
  final String userId;
  final String actorName;
  final String action;
  final String entityType;
  final String entityId;
  final String summary;
  final String? before;
  final String? after;
  final DateTime? createdAt;

  factory AuditLogEntry.fromMap(String id, Map<String, dynamic> map) {
    return AuditLogEntry(
      id: id,
      organizationId: map['organizationId'] as String? ?? '',
      branchId: map['branchId'] as String? ?? '',
      userId: map['userId'] as String? ?? '',
      actorName: map['actorName'] as String? ?? '',
      action: map['action'] as String? ?? '',
      entityType: map['entityType'] as String? ?? '',
      entityId: map['entityId'] as String? ?? '',
      summary: map['summary'] as String? ?? '',
      before: map['oldValues'] as String?,
      after: map['newValues'] as String?,
      createdAt: parseDate(map['createdAt']),
    );
  }

  /// Firestore shape (SRS §3.1): `oldValues` / `newValues` hold the
  /// before/after summaries.
  Map<String, dynamic> toMap() {
    return {
      'organizationId': organizationId,
      'branchId': branchId,
      'userId': userId,
      'actorName': actorName,
      'action': action,
      'entityType': entityType,
      'entityId': entityId,
      'summary': summary,
      'oldValues': before,
      'newValues': after,
      'createdAt': dateToMap(createdAt),
    };
  }

  AuditLogEntry copyWith({String? id, DateTime? createdAt}) {
    return AuditLogEntry(
      id: id ?? this.id,
      organizationId: organizationId,
      branchId: branchId,
      userId: userId,
      actorName: actorName,
      action: action,
      entityType: entityType,
      entityId: entityId,
      summary: summary,
      before: before,
      after: after,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}

/// Writes audit entries. The Firestore implementation appends to the
/// root `auditLogs` collection; the local one keeps them in memory for
/// the session (they are included in the JSON backup export).
abstract class AuditLogWriter {
  Future<AuditLogEntry> write(AuditLogEntry entry);
  Future<List<AuditLogEntry>> entries({
    String? branchId,
    String? entityType,
    String? entityId,
    String? action,
  });
}

/// In-memory audit writer (works on web and in tests). Append-only:
/// entries are added, never edited or removed.
class InMemoryAuditLogWriter implements AuditLogWriter {
  final List<AuditLogEntry> _entries = [];

  @override
  Future<AuditLogEntry> write(AuditLogEntry entry) async {
    final saved = entry.copyWith(
      id: 'audit-${_entries.length + 1}',
      createdAt: entry.createdAt ?? DateTime.now(),
    );
    _entries.add(saved);
    return saved;
  }

  @override
  Future<List<AuditLogEntry>> entries({
    String? branchId,
    String? entityType,
    String? entityId,
    String? action,
  }) async {
    return List.unmodifiable(
      _entries.where((entry) {
        if (branchId != null && entry.branchId != branchId) return false;
        if (entityType != null && entry.entityType != entityType) {
          return false;
        }
        if (entityId != null && entry.entityId != entityId) return false;
        if (action != null && entry.action != action) return false;
        return true;
      }),
    );
  }

  /// All entries, oldest first — used by the backup export.
  List<AuditLogEntry> get all => List.unmodifiable(_entries);
}
