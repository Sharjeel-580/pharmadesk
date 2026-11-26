import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../../core/services/repositories.dart';
import '../../core/utils/file_download.dart';
import 'audit_log.dart';
import 'sync_queue.dart';

/// Manual export / backup (SRS §2.6).
///
/// On Blaze, a scheduled Cloud Function also exports Firestore to
/// Cloud Storage weekly/daily (see `firebase/functions-design.md`,
/// Job 4). This in-app JSON export remains the manual path the client
/// can always run from the app, and the fallback if the scheduled job
/// is down. The export covers every repository's data (per-branch
/// or org-wide), downloads on web through the existing `file_download`
/// util, and restores through [DataImporter] with validation +
/// idempotency (doc ids are the keys; restore overwrites or skips by
/// policy, never duplicates).
///
/// RESTORE TARGET (Week 5 Day 2, D150 — closes D133): the import
/// writes into the LIVE repositories by upsert-by-id (existing id →
/// replaced, new id → inserted) through
/// `ProductionDataLayer.importBackup`. The `auditLogs` / `syncQueue`
/// sections are local state, not repo data, so they still land in
/// the [InMemoryRestoreSink] — as does every section, so the sink
/// stays the full record of the last restore. [DataImporter] itself
/// is unchanged: it still imports into a sink with the same policy,
/// and its unit tests still pin that behaviour.

/// Backup file format.
class BackupFormat {
  static const String format = 'pharmadesk-backup';
  static const int currentVersion = 1;
}

/// Recursively converts a Firestore-shaped map into JSON-safe values:
/// [Timestamp] / [DateTime] → ISO-8601 strings, maps and lists walked.
/// Models' `toMap()` emits Timestamps via `dateToMap`, so every export
/// passes through here.
dynamic jsonSafe(dynamic value) {
  if (value is Timestamp) return value.toDate().toIso8601String();
  if (value is DateTime) return value.toIso8601String();
  if (value is Map) {
    return <String, dynamic>{
      for (final entry in value.entries)
        entry.key.toString(): jsonSafe(entry.value),
    };
  }
  if (value is List) return value.map(jsonSafe).toList();
  return value;
}

/// Exports all repository data to one JSON backup document.
///
/// Pass [branchId] for a per-branch export (branch-scoped sections
/// filtered to that branch); omit it for an org-wide export (every
/// branch + the org-wide catalogue). Money stays int paisa throughout;
/// dates are ISO strings.
class DataExporter {
  DataExporter({
    required this.medicines,
    required this.orders,
    required this.inventory,
    required this.customers,
    required this.sales,
    required this.suppliers,
    required this.prescriptions,
    required this.purchaseOrders,
    required this.riders,
    required this.branches,
    required this.audit,
    required this.syncQueue,
    required this.organizationId,
  });

  final MedicineRepository medicines;
  final OrderRepository orders;
  final InventoryRepository inventory;
  final CustomerRepository customers;
  final SaleRepository sales;
  final SupplierRepository suppliers;
  final PrescriptionRepository prescriptions;
  final PurchaseOrderRepository purchaseOrders;
  final RiderRepository riders;
  final BranchRepository branches;
  final AuditLogWriter audit;
  final SyncQueue syncQueue;
  final String organizationId;

  Future<Map<String, dynamic>> exportAll({String? branchId}) async {
    final sections = <String, List<Map<String, dynamic>>>{};

    // Org-wide catalogue — included in full in either export.
    final medicineList = await medicines.getMedicines();
    sections['medicines'] = medicineList
        .map((medicine) => _doc(medicine.id, medicine.toMap()))
        .toList();
    final supplierList = await suppliers.getSuppliers();
    sections['suppliers'] = supplierList
        .map((supplier) => _doc(supplier.id, supplier.toMap()))
        .toList();
    final supplierLedger = <Map<String, dynamic>>[];
    for (final supplier in supplierList) {
      final entries = await suppliers.getLedgerEntries(supplier.id);
      supplierLedger.addAll(
        entries.map((entry) => _doc(entry.id, entry.toMap())),
      );
    }
    sections['supplierLedger'] = supplierLedger;
    sections['riders'] = (await riders.getRiders())
        .map((rider) => _doc(rider.id, rider.toMap()))
        .toList();
    sections['branches'] = (await branches.getBranches())
        .map((branch) => _doc(branch.id, branch.toMap()))
        .toList();

    // Branch-scoped sections.
    final orderList = await orders.getOrders(branchId: branchId);
    sections['orders'] = orderList
        .map((order) => _doc(order.id, order.toMap()))
        .toList();
    final saleList = await sales.getSales(branchId: branchId);
    sections['sales'] = saleList
        .map((sale) => _doc(sale.id, sale.toMap()))
        .toList();
    final inventoryList = await inventory.getInventory(branchId: branchId);
    sections['inventory'] = inventoryList
        .map((item) => _doc(item.id, item.toMap()))
        .toList();
    final prescriptionList = await prescriptions.getPrescriptions(
      branchId: branchId,
    );
    sections['prescriptions'] = prescriptionList
        .map((rx) => _doc(rx.id, rx.toMap()))
        .toList();
    final poList = await purchaseOrders.getPurchaseOrders(branchId: branchId);
    sections['purchaseOrders'] = poList
        .map((po) => _doc(po.id, po.toMap()))
        .toList();

    final customerList = await customers.getCustomers();
    sections['customers'] = customerList
        .map((customer) => _doc(customer.id, customer.toMap()))
        .toList();
    final customerLedger = <Map<String, dynamic>>[];
    for (final customer in customerList) {
      final entries = await customers.getLedgerEntries(customer.id);
      customerLedger.addAll(
        entries.map((entry) => _doc(entry.id, entry.toMap())),
      );
    }
    sections['customerLedger'] = customerLedger;

    // Audit trail + pending sync queue (local state, not in a repo).
    final auditEntries = await audit.entries(branchId: branchId);
    sections['auditLogs'] = auditEntries
        .map((entry) => _doc(entry.id, entry.toMap()))
        .toList();
    final pendingOps = await syncQueue.pendingOperations();
    sections['syncQueue'] = pendingOps
        .map((op) => _doc(op.idempotencyKey, op.toMap()))
        .toList();

    return {
      'format': BackupFormat.format,
      'formatVersion': BackupFormat.currentVersion,
      'exportedAt': DateTime.now().toIso8601String(),
      'organizationId': organizationId,
      'branchId': branchId,
      'sections': sections,
    };
  }

  /// Serialises the export to a JSON string (pretty-printed).
  Future<String> exportJson({String? branchId}) async {
    final doc = await exportAll(branchId: branchId);
    return const JsonEncoder.withIndent('  ').convert(doc);
  }

  /// Downloads the export as a JSON file on web. On non-web targets
  /// the download util is a no-op (see `file_download.dart`); the
  /// caller should show the JSON instead.
  Future<void> downloadBackup({String? branchId}) async {
    final json = await exportJson(branchId: branchId);
    final stamp = DateTime.now()
        .toIso8601String()
        .substring(0, 16)
        .replaceAll(RegExp(r'[^0-9]'), '');
    final scope = branchId ?? 'org';
    downloadTextFile(
      'pharmadesk-backup-$scope-$stamp.json',
      json,
      'application/json',
    );
  }

  Map<String, dynamic> _doc(String id, Map<String, dynamic> map) {
    final safe = jsonSafe(map) as Map<String, dynamic>;
    return {'id': id, ...safe};
  }
}

/// Where a restore writes. Keyed by (collection, doc id) so the
/// idempotency policy can be enforced: the same doc id is never
/// stored twice.
abstract class RestoreSink {
  bool contains(String collection, String docId);
  void put(String collection, String docId, Map<String, dynamic> doc);
  int count(String collection);
  Map<String, Map<String, Map<String, dynamic>>> get snapshot;
}

/// In-memory restore target (used by tests and until the live repos
/// gain upsert-by-id).
class InMemoryRestoreSink implements RestoreSink {
  final Map<String, Map<String, Map<String, dynamic>>> _data = {};

  @override
  bool contains(String collection, String docId) =>
      _data[collection]?.containsKey(docId) ?? false;

  @override
  void put(String collection, String docId, Map<String, dynamic> doc) {
    (_data[collection] ??= {})[docId] = Map<String, dynamic>.from(doc);
  }

  @override
  int count(String collection) => _data[collection]?.length ?? 0;

  @override
  Map<String, Map<String, Map<String, dynamic>>> get snapshot =>
      Map.unmodifiable(_data);
}

/// How a restore treats a doc id that already exists in the sink.
enum ImportPolicy {
  /// Existing doc is left untouched; the incoming one is skipped.
  skipExisting,

  /// Existing doc is replaced by the incoming one.
  overwrite,
}

/// Result of one import run.
class ImportReport {
  const ImportReport({
    required this.created,
    required this.overwritten,
    required this.skipped,
    required this.errors,
  });

  final int created;
  final int overwritten;
  final int skipped;

  /// Structural problems found (bad format, bad version, malformed
  /// docs). Docs with errors are skipped, never partially applied.
  final List<String> errors;

  bool get success => errors.isEmpty;
  int get totalApplied => created + overwritten;
}

/// Validates a backup document and restores it into [sink].
///
/// Validation runs BEFORE any write: wrong format, wrong version or a
/// missing `sections` map aborts the whole import. Individual malformed
/// docs are recorded in [ImportReport.errors] and skipped; the rest
/// still import. Idempotency: a doc id already in the sink is skipped
/// or overwritten per [policy] — importing the same backup twice never
/// duplicates a document.
class DataImporter {
  /// Structural validation only (no writes). Returns the problems
  /// found; empty = the backup is well-formed.
  static List<String> validateBackup(Map<String, dynamic> json) {
    final errors = <String>[];
    if (json['format'] != BackupFormat.format) {
      errors.add('Not a PharmaDesk backup (format is "${json['format']}").');
    }
    if (json['formatVersion'] != BackupFormat.currentVersion) {
      errors.add(
        'Unsupported backup version "${json['formatVersion']}" '
        '(expected ${BackupFormat.currentVersion}).',
      );
    }
    if (json['organizationId'] is! String ||
        (json['organizationId'] as String).isEmpty) {
      errors.add('Missing organizationId.');
    }
    final sections = json['sections'];
    if (sections is! Map) {
      errors.add('Missing sections map.');
      return errors;
    }
    for (final entry in sections.entries) {
      final docs = entry.value;
      if (docs is! List) {
        errors.add('Section "${entry.key}" is not a list.');
        continue;
      }
      for (var i = 0; i < docs.length; i++) {
        final doc = docs[i];
        if (doc is! Map) {
          errors.add('Section "${entry.key}" doc $i is not an object.');
          continue;
        }
        final id = doc['id'];
        if (id is! String || id.isEmpty) {
          errors.add('Section "${entry.key}" doc $i has no id.');
        }
      }
    }
    return errors;
  }

  ImportReport importBackup(
    Map<String, dynamic> json,
    RestoreSink sink, {
    ImportPolicy policy = ImportPolicy.skipExisting,
  }) {
    var created = 0;
    var overwritten = 0;
    var skipped = 0;
    final errors = validateBackup(json);
    if (errors.isNotEmpty) {
      return ImportReport(
        created: 0,
        overwritten: 0,
        skipped: 0,
        errors: errors,
      );
    }
    final sections = json['sections'] as Map;
    for (final entry in sections.entries) {
      final collection = entry.key as String;
      final docs = entry.value as List;
      for (final rawDoc in docs) {
        final doc = rawDoc as Map;
        final id = doc['id'] as String;
        final payload = Map<String, dynamic>.from(doc)..remove('id');
        if (sink.contains(collection, id)) {
          if (policy == ImportPolicy.overwrite) {
            sink.put(collection, id, payload);
            overwritten++;
          } else {
            skipped++;
          }
        } else {
          sink.put(collection, id, payload);
          created++;
        }
      }
    }
    return ImportReport(
      created: created,
      overwritten: overwritten,
      skipped: skipped,
      errors: const [],
    );
  }
}
