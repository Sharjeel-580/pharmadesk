import 'package:cloud_firestore/cloud_firestore.dart';

import 'firestore_schema.dart';
import 'inventory_engine.dart' show WriteOperation, WriteOperationKind;

/// Firestore transport (Week 2 Day 3, D71).
///
/// The Firestore repositories (`firestore_repositories.dart`) talk to
/// Firestore ONLY through this interface — never through
/// `FirebaseFirestore` directly. That keeps the repositories
/// unit-testable without a Firebase project (there is none yet — D13):
/// tests run them against the in-memory fake transport in
/// `test/week2_day03_test.dart`, while production uses
/// [FirebaseFirestoreTransport].
///
/// The transport owns two Firestore mechanics the repositories must
/// not re-implement:
///
/// - **Batched writes chunked at ≤500 operations**
///   ([maxFirestoreBatchWrites], SRS §3): [runBatchedWrites] splits
///   any operation list into 500-op chunks and executes one real
///   batch per chunk.
/// - **Pagination**: [queryCollection] pages with `orderBy` +
///   `startAfterId` (document-id ordering by default), so list reads
///   never pull a whole collection in one query.
///
/// Dates: documents carry `Timestamp` values (the mappers stamp
/// `Timestamp.fromDate`); the fake stores maps verbatim, so mapper
/// round-trips run identically on both transports.
///
/// No document is ever hard-deleted through this transport — the app
/// soft-deletes via `status` / `deletedAt` (SRS §3). There is
/// deliberately no `deleteDocument` method.
class FirestoreDocument {
  const FirestoreDocument({required this.id, required this.data});

  final String id;
  final Map<String, dynamic> data;
}

abstract class FirestoreTransport {
  /// Reads one document, or `null` when it does not exist.
  Future<Map<String, dynamic>?> getDocument(String path);

  /// Lists documents in [collectionPath], ordered by [orderBy]
  /// (default: document id) with an optional equality filter, limit
  /// and pagination cursor. Returns documents in page order.
  Future<List<FirestoreDocument>> queryCollection(
    String collectionPath, {
    Map<String, Object?> whereEquals,
    String? orderBy,
    bool descending = false,
    int? limit,
    String? startAfterId,
  });

  /// Creates / overwrites a document (`merge` updates only the given
  /// fields, like `SetOptions(merge: true)`).
  Future<void> setDocument(
    String path,
    Map<String, dynamic> data, {
    bool merge = false,
  });

  /// Updates fields of an existing document.
  Future<void> updateDocument(String path, Map<String, dynamic> data);

  /// Creates a document with a fresh auto-id and returns the id.
  Future<String> addDocument(String collectionPath, Map<String, dynamic> data);

  /// Executes [operations] as Firestore batched writes, chunked at
  /// [maxFirestoreBatchWrites] (500) operations per batch. A list
  /// that fits is a single batch.
  Future<void> runBatchedWrites(List<WriteOperation> operations);

  /// Runs [action] in a Firestore transaction. The transaction
  /// exposes get / set / update on document paths.
  Future<T> runTransaction<T>(
    Future<T> Function(FirestoreTransaction tx) action,
  );

  /// A fresh auto-id for [collectionPath] (client-generated, so the
  /// caller can use it as a doc id before writing).
  String newDocumentId(String collectionPath);
}

/// The transaction handle handed to [FirestoreTransport.runTransaction].
abstract class FirestoreTransaction {
  Future<Map<String, dynamic>?> get(String path);
  void set(String path, Map<String, dynamic> data, {bool merge = false});
  void update(String path, Map<String, dynamic> data);
}

/// The real transport: thin wrappers over `cloud_firestore`.
///
/// Constructed only by the repository factory when the Firebase
/// project exists — never at app start (there is no project yet).
class FirebaseFirestoreTransport implements FirestoreTransport {
  FirebaseFirestoreTransport({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  @override
  Future<Map<String, dynamic>?> getDocument(String path) async {
    final snapshot = await _firestore.doc(path).get();
    return snapshot.data();
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
    Query<Map<String, dynamic>> query = _firestore.collection(collectionPath);
    for (final filter in whereEquals.entries) {
      query = query.where(filter.key, isEqualTo: filter.value);
    }
    final orderField = orderBy ?? FieldPath.documentId;
    query = query.orderBy(orderField, descending: descending);
    if (startAfterId != null) {
      query = query.startAfter([startAfterId]);
    }
    if (limit != null) {
      query = query.limit(limit);
    }
    final snapshot = await query.get();
    return [
      for (final doc in snapshot.docs)
        FirestoreDocument(id: doc.id, data: doc.data()),
    ];
  }

  @override
  Future<void> setDocument(
    String path,
    Map<String, dynamic> data, {
    bool merge = false,
  }) {
    return _firestore.doc(path).set(data, SetOptions(merge: merge));
  }

  @override
  Future<void> updateDocument(String path, Map<String, dynamic> data) {
    return _firestore.doc(path).update(data);
  }

  @override
  Future<String> addDocument(
    String collectionPath,
    Map<String, dynamic> data,
  ) async {
    final ref = await _firestore.collection(collectionPath).add(data);
    return ref.id;
  }

  @override
  Future<void> runBatchedWrites(List<WriteOperation> operations) async {
    for (var i = 0; i < operations.length; i += maxFirestoreBatchWrites) {
      final end = (i + maxFirestoreBatchWrites).clamp(0, operations.length);
      final chunk = operations.sublist(i, end);
      final batch = _firestore.batch();
      for (final operation in chunk) {
        final ref = _firestore.doc(operation.path);
        switch (operation.kind) {
          case WriteOperationKind.set:
            batch.set(ref, operation.data ?? const {});
          case WriteOperationKind.update:
            batch.update(ref, operation.data ?? const {});
          case WriteOperationKind.delete:
            batch.delete(ref);
        }
      }
      await batch.commit();
    }
  }

  @override
  Future<T> runTransaction<T>(
    Future<T> Function(FirestoreTransaction tx) action,
  ) {
    return _firestore.runTransaction((transaction) async {
      return action(_FirebaseFirestoreTransaction(_firestore, transaction));
    });
  }

  @override
  String newDocumentId(String collectionPath) =>
      _firestore.collection(collectionPath).doc().id;
}

class _FirebaseFirestoreTransaction implements FirestoreTransaction {
  _FirebaseFirestoreTransaction(this._firestore, this._transaction);

  final FirebaseFirestore _firestore;
  final Transaction _transaction;

  @override
  Future<Map<String, dynamic>?> get(String path) async {
    final snapshot = await _transaction.get(_firestore.doc(path));
    return snapshot.data();
  }

  @override
  void set(String path, Map<String, dynamic> data, {bool merge = false}) {
    _transaction.set(_firestore.doc(path), data, SetOptions(merge: merge));
  }

  @override
  void update(String path, Map<String, dynamic> data) {
    _transaction.update(_firestore.doc(path), data);
  }
}
