import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'sync_queue.dart';

/// Creates the platform sync store: sqflite-backed on mobile.
SyncStore createSyncStore() => SqfliteSyncStore();

/// SQLite-backed sync store (Android/iOS).
///
/// One row per operation, keyed by idempotency key — the PRIMARY KEY
/// itself enforces dedupe at the storage layer, so a retried enqueue
/// can never create a second row for the same document.
///
/// The database opens lazily on first use. If opening fails (for
/// example on Windows, where sqflite needs `sqflite_common_ffi`
/// wiring — see D5), the store falls back to an in-memory map and
/// [durable] reports `false`, so the queue keeps working instead of
/// crashing the app. The fallback is visible, not silent: callers can
/// read [durable] and the backup export lists the queue state.
class SqfliteSyncStore implements SyncStore {
  SqfliteSyncStore({this._databaseName = 'pharmadesk_sync.db'});

  final String _databaseName;
  Database? _db;
  bool _openFailed = false;
  final Map<String, SyncOperation> _memoryFallback = {};

  /// True when operations are durably persisted in SQLite.
  bool get durable => _db != null && !_openFailed;

  Future<Database?> _database() async {
    if (_db != null) return _db;
    if (_openFailed) return null;
    try {
      final path = '${await getDatabasesPath()}/$_databaseName';
      _db = await openDatabase(
        path,
        version: 1,
        onCreate: (db, version) async {
          await db.execute(
            'CREATE TABLE sync_operations('
            'idempotency_key TEXT PRIMARY KEY, '
            'payload_json TEXT NOT NULL)',
          );
        },
      );
      return _db;
    } catch (_) {
      // Platform without a working sqflite (e.g. Windows before
      // sqflite_common_ffi is wired): fall back to memory.
      _openFailed = true;
      return null;
    }
  }

  @override
  Future<SyncOperation> enqueue(SyncOperation operation) async {
    final db = await _database();
    if (db == null) {
      final existing = _memoryFallback[operation.idempotencyKey];
      if (existing != null) return existing;
      _memoryFallback[operation.idempotencyKey] = operation;
      return operation;
    }
    final existing = await byIdempotencyKey(operation.idempotencyKey);
    if (existing != null) return existing;
    await db.insert('sync_operations', {
      'idempotency_key': operation.idempotencyKey,
      'payload_json': jsonEncode(operation.toMap()),
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    return operation;
  }

  @override
  Future<SyncOperation?> byIdempotencyKey(String key) async {
    final db = await _database();
    if (db == null) return _memoryFallback[key];
    final rows = await db.query(
      'sync_operations',
      where: 'idempotency_key = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _decode(rows.first);
  }

  @override
  Future<List<SyncOperation>> pending({DateTime? now}) async {
    final reference = now ?? DateTime.now();
    final ops = await all();
    final due = ops.where((op) => op.isDue(reference)).toList()
      ..sort(
        (a, b) =>
            (a.createdAt ?? DateTime(0)).compareTo(b.createdAt ?? DateTime(0)),
      );
    return List.unmodifiable(due);
  }

  @override
  Future<List<SyncOperation>> all() async {
    final db = await _database();
    if (db == null) return List.unmodifiable(_memoryFallback.values.toList());
    final rows = await db.query('sync_operations');
    return List.unmodifiable(rows.map(_decode));
  }

  @override
  Future<void> update(SyncOperation operation) async {
    final db = await _database();
    if (db == null) {
      _memoryFallback[operation.idempotencyKey] = operation;
      return;
    }
    await db.update(
      'sync_operations',
      {'payload_json': jsonEncode(operation.toMap())},
      where: 'idempotency_key = ?',
      whereArgs: [operation.idempotencyKey],
    );
  }

  @override
  Future<int> pendingCount() async {
    final due = await pending();
    return due.length;
  }

  SyncOperation _decode(Map<String, Object?> row) {
    final json =
        jsonDecode(row['payload_json'] as String) as Map<String, dynamic>;
    return SyncOperation.fromMap(row['idempotency_key'] as String, json);
  }
}
