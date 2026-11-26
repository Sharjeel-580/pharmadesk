// Week 7 Day 3 tests — cross-backend restore re-key by idempotencyKey
// (D173, brief §3, closes the Day 24 / D169 edge).
//
// - D173: the live restore (`ProductionDataLayer.importBackup`)
//   re-keys the sales and orders sections by the payload's
//   `idempotencyKey` before it measures existence, records the sink,
//   or writes — the doc id IS the key (D53, SRS §2.5, enforced by
//   the Firestore rules). A mock export carries the mock-assigned id
//   (`sale-DHA-1001`) while the key is the client key, so restoring
//   under the exported id used to breach the invariant. The export
//   itself is unchanged; only the restore re-keys.
// - The mock's `upsertSale` matches by id OR by key, so a restore
//   of a sale the mock already holds under its mock id REPLACES it
//   in place under the key instead of duplicating it.
// - ImportReport counting stays correct: a re-keyed sale counts
//   once — created on the first restore, skipped / overwritten on
//   a re-restore, never created twice.
// - D169 semantics intact: restore never deletes, counters and
//   sale-payment legs stay unrestored.
// - Full end-to-end verification against live Firestore stays
//   BLOCKED on a live Firebase project (a Dazy-only step); the
//   tests below run the restore through the Day 34 fake transport
//   (`FakeFirestoreTransport`, with `runTransaction` +
//   `runBatchedWrites`), which is the verification available here.
//
// The fake transport, `seedBranches` and `sampleSale` live in
// `test/week2_day03_test.dart` (the canonical fake); this file
// imports them rather than carrying a second copy.

import 'package:flutter_test/flutter_test.dart';
import 'package:pharmadesk/core/data/audit_log.dart';
import 'package:pharmadesk/core/data/backup_export.dart';
import 'package:pharmadesk/core/data/firestore_repositories.dart';
import 'package:pharmadesk/core/data/firestore_schema.dart';
import 'package:pharmadesk/core/data/inventory_engine.dart';
import 'package:pharmadesk/core/data/production_data_layer.dart';
import 'package:pharmadesk/core/data/sync_queue.dart';
import 'package:pharmadesk/core/services/repositories.dart';
import 'package:pharmadesk/models/sale.dart';

import 'week2_day03_test.dart';

const _dha = 'branch-dha-main';
const _org = demoOrganizationId;

/// A sale with a client idempotency key that differs from any id a
/// repo assigns — the Day 24 edge shape. Two payment legs, so the
/// D169 Firestore-only leg gap is exercised too (the split survives
/// in the mock, not on Firestore).
Sale _keyedSale({required String key, int totalMinor = 1000000}) {
  return Sale(
    id: '',
    invoiceNumber: '',
    branchId: _dha,
    cashierName: 'Test Cashier',
    items: const [
      SaleItem(
        medicineId: 'med-1',
        medicineName: 'Panadol',
        quantity: 2,
        unitPriceMinor: 10000,
        batchId: 'batch-1',
        batchNo: 'B-100',
      ),
    ],
    subtotalMinor: totalMinor,
    totalMinor: totalMinor,
    paymentMethod: SalePaymentMethod.cash,
    payments: [
      SalePayment(
        method: SalePaymentMethod.cash,
        amountMinor: totalMinor * 6 ~/ 10,
      ),
      SalePayment(
        method: SalePaymentMethod.card,
        amountMinor: totalMinor * 4 ~/ 10,
      ),
    ],
    cashReceivedMinor: totalMinor * 6 ~/ 10,
    idempotencyKey: key,
    createdAt: DateTime(2026, 11, 26, 10, 0),
  );
}

/// Production layer over fresh mocks (same helper shape as the
/// Week 6 Day 5 harness).
class _MockHarness {
  _MockHarness()
    : branchRepo = MockBranchRepository(),
      audit = InMemoryAuditLogWriter() {
    layer = ProductionDataLayer(
      organizationId: _org,
      inventoryRepo: MockInventoryRepository(),
      saleRepo: MockSaleRepository(),
      orderRepo: MockOrderRepository(),
      customerRepo: MockCustomerRepository(),
      medicineRepo: MockMedicineRepository(),
      supplierRepo: MockSupplierRepository(),
      prescriptionRepo: MockPrescriptionRepository(),
      purchaseOrderRepo: MockPurchaseOrderRepository(),
      riderRepo: MockRiderRepository(),
      branchRepo: branchRepo,
      audit: audit,
      syncQueue: SyncQueue(InMemorySyncStore()),
      engine: InventoryEngine(organizationId: _org, audit: audit),
    );
  }

  final MockBranchRepository branchRepo;
  final InMemoryAuditLogWriter audit;
  late final ProductionDataLayer layer;
}

/// Production layer whose sale + order repos are the Firestore
/// implementations over the Day 34 fake transport; every other repo
/// is a mock. `seedBranches` runs first so the Firestore repos can
/// enumerate branches and read branch codes.
class _FirestoreHarness {
  _FirestoreHarness._(this.transport, this.layer);

  static Future<_FirestoreHarness> create() async {
    final transport = FakeFirestoreTransport();
    await seedBranches(transport);
    final audit = InMemoryAuditLogWriter();
    final layer = ProductionDataLayer(
      organizationId: _org,
      inventoryRepo: MockInventoryRepository(),
      saleRepo: FirestoreSaleRepository(
        transport: transport,
        organizationId: _org,
      ),
      orderRepo: FirestoreOrderRepository(
        transport: transport,
        organizationId: _org,
      ),
      customerRepo: MockCustomerRepository(),
      medicineRepo: MockMedicineRepository(),
      supplierRepo: MockSupplierRepository(),
      prescriptionRepo: MockPrescriptionRepository(),
      purchaseOrderRepo: MockPurchaseOrderRepository(),
      riderRepo: MockRiderRepository(),
      branchRepo: MockBranchRepository(),
      audit: audit,
      syncQueue: SyncQueue(InMemorySyncStore()),
      engine: InventoryEngine(organizationId: _org, audit: audit),
    );
    return _FirestoreHarness._(transport, layer);
  }

  final FakeFirestoreTransport transport;
  final ProductionDataLayer layer;
}

/// A minimal backup holding exactly one sale doc (taken from a real
/// export), so ImportReport counts are the sale's alone.
Map<String, dynamic> _saleOnlyBackup(Map<String, dynamic> saleDoc) {
  return {
    'format': BackupFormat.format,
    'formatVersion': BackupFormat.currentVersion,
    'organizationId': _org,
    'exportedAt': DateTime.now().toIso8601String(),
    'sections': {
      'sales': [saleDoc],
    },
  };
}

Future<Map<String, dynamic>> _exportedSaleDoc(
  _MockHarness source,
  String mockId,
) async {
  final backup = await source.layer.exportBackup();
  final sales = (backup['sections'] as Map)['sales'] as List;
  return Map<String, dynamic>.from(
    sales.firstWhere((doc) => (doc as Map)['id'] == mockId) as Map,
  );
}

void main() {
  group('D173 — mock export restored into the Firestore layer', () {
    test('sale lands under the idempotency key, not the mock id',
        () async {
      final source = _MockHarness();
      final saved = await source.layer.saleRepo.createSale(
        _keyedSale(key: 'sale-d173-mock-1'),
      );
      expect(saved.id, isNot('sale-d173-mock-1'));
      expect(saved.id, startsWith('sale-DHA-'));

      final target = await _FirestoreHarness.create();
      final report = await target.layer.importBackup(
        await source.layer.exportBackup(),
      );
      expect(report.errors, isEmpty);

      // The doc is under the key in the fake Firestore store…
      final keyedDoc = await target.transport.getDocument(
        FirestoreSchema.saleDocPath(_dha, 'sale-d173-mock-1'),
      );
      expect(keyedDoc, isNotNull);
      // …and nothing landed under the exported mock id.
      expect(
        await target.transport.getDocument(
          FirestoreSchema.saleDocPath(_dha, saved.id),
        ),
        isNull,
      );
      // The repo reads it back by key, with totals + items intact.
      final restored =
          await target.layer.saleRepo.getById('sale-d173-mock-1');
      expect(restored, isNotNull);
      expect(restored!.id, 'sale-d173-mock-1');
      expect(restored.idempotencyKey, 'sale-d173-mock-1');
      expect(restored.totalMinor, 1000000);
      expect(restored.items, hasLength(1));
      expect(await target.layer.saleRepo.getById(saved.id), isNull);
    });

    test('stored Firestore doc satisfies the D53 / rules invariant',
        () async {
      final source = _MockHarness();
      await source.layer.saleRepo.createSale(
        _keyedSale(key: 'sale-d173-rule-1'),
      );
      final target = await _FirestoreHarness.create();
      await target.layer.importBackup(await source.layer.exportBackup());

      final doc = await target.transport.getDocument(
        FirestoreSchema.saleDocPath(_dha, 'sale-d173-rule-1'),
      );
      expect(doc, isNotNull);
      // Doc id == stored idempotencyKey — the rule
      // `saleId == request.resource.data.idempotencyKey` holds.
      expect(doc!['idempotencyKey'], 'sale-d173-rule-1');
      expect(doc['organizationId'], _org);
    });

    test('split-payment totals survive on Firestore; the per-leg '
        'split is lost there (D169 gap) and the payments '
        'subcollection is NOT restored', () async {
      final source = _MockHarness();
      await source.layer.saleRepo.createSale(
        _keyedSale(key: 'sale-d173-legs-1'),
      );
      final target = await _FirestoreHarness.create();
      await target.layer.importBackup(await source.layer.exportBackup());

      final restored =
          await target.layer.saleRepo.getById('sale-d173-legs-1');
      expect(restored, isNotNull);
      // Totals survive the Firestore restore — the sale doc
      // carries the total, method and cash received.
      expect(restored!.totalMinor, 1000000);
      expect(restored.paymentMethod, SalePaymentMethod.cash);
      expect(restored.cashReceivedMinor, 600000);
      // The per-leg split does NOT survive on Firestore:
      // `saleToFirestore` writes no `payments` list into the doc
      // (legs live only in the `payments` subcollection), and the
      // restore deliberately never rewrites that subcollection
      // (D169) — so a read-back has no legs. In the mock the legs
      // DO round-trip, because `Sale.toMap` carries the list
      // inside the doc (pinned in week6_day05).
      expect(restored.payments, isEmpty);
      // The Firestore `payments` subcollection is a write-time
      // mirror, not part of the backup — a restore never writes it.
      expect(
        target.transport.countIn(
          FirestoreSchema.salePaymentsPath(_dha, 'sale-d173-legs-1'),
        ),
        0,
      );
    });

    test('re-restore under skipExisting counts the sale once',
        () async {
      final source = _MockHarness();
      final saved = await source.layer.saleRepo.createSale(
        _keyedSale(key: 'sale-d173-count-1'),
      );
      final saleDoc = await _exportedSaleDoc(source, saved.id);
      final target = await _FirestoreHarness.create();

      final first = await target.layer.importBackup(
        _saleOnlyBackup(saleDoc),
      );
      expect(first.errors, isEmpty);
      expect(first.created, 1);
      expect(first.overwritten, 0);
      expect(first.skipped, 0);

      final second = await target.layer.importBackup(
        _saleOnlyBackup(saleDoc),
      );
      expect(second.errors, isEmpty);
      expect(second.created, 0);
      expect(second.overwritten, 0);
      expect(second.skipped, 1);
      expect(
        (await target.layer.saleRepo.getSales()).length,
        1,
        reason: 'the re-restore must not duplicate the sale',
      );
    });

    test('re-restore under overwrite counts the sale once', () async {
      final source = _MockHarness();
      final saved = await source.layer.saleRepo.createSale(
        _keyedSale(key: 'sale-d173-count-2'),
      );
      final saleDoc = await _exportedSaleDoc(source, saved.id);
      final target = await _FirestoreHarness.create();

      final first = await target.layer.importBackup(
        _saleOnlyBackup(saleDoc),
        policy: ImportPolicy.overwrite,
      );
      expect(first.created, 1);

      final second = await target.layer.importBackup(
        _saleOnlyBackup(saleDoc),
        policy: ImportPolicy.overwrite,
      );
      expect(second.errors, isEmpty);
      expect(second.created, 0);
      expect(second.overwritten, 1);
      expect(second.skipped, 0);
      expect((await target.layer.saleRepo.getSales()).length, 1);
    });
  });

  group('D173 — Firestore export restored into the mock layer', () {
    test('Firestore sale restores into the mock under its key',
        () async {
      final source = await _FirestoreHarness.create();
      final created = await source.layer.saleRepo.createSale(
        sampleSale(key: 'sale-d173-fs-1'),
      );
      // A Firestore-native sale already has doc id == key.
      expect(created.id, 'sale-d173-fs-1');

      final target = _MockHarness();
      final report = await target.layer.importBackup(
        await source.layer.exportBackup(),
      );
      expect(report.errors, isEmpty);
      final restored =
          await target.layer.saleRepo.getById('sale-d173-fs-1');
      expect(restored, isNotNull);
      expect(restored!.id, 'sale-d173-fs-1');
      expect(restored.idempotencyKey, 'sale-d173-fs-1');
      expect(restored.totalMinor, 20000);
      expect(restored.items, hasLength(1));
    });

    test('re-restore into the mock counts the sale once', () async {
      final source = await _FirestoreHarness.create();
      await source.layer.saleRepo.createSale(
        sampleSale(key: 'sale-d173-fs-2'),
      );
      final backup = await source.layer.exportBackup();
      final sales = (backup['sections'] as Map)['sales'] as List;
      final saleDoc = Map<String, dynamic>.from(sales.first as Map);
      final target = _MockHarness();

      final first = await target.layer.importBackup(
        _saleOnlyBackup(saleDoc),
      );
      expect(first.created, 1);
      final second = await target.layer.importBackup(
        _saleOnlyBackup(saleDoc),
      );
      expect(second.created, 0);
      expect(second.skipped, 1);
      expect((await target.layer.saleRepo.getSales()).length, 1);
    });
  });

  group('D173 — same-layer mock re-import (the D169 overwrite flow)',
      () {
    test('re-import replaces the committed sale in place, no '
        'duplicate, counted as overwritten', () async {
      final h = _MockHarness();
      final committed = await h.layer.saleRepo.createSale(
        _keyedSale(key: 'sale-d173-same-1'),
      );
      final saleDoc = await _exportedSaleDoc(h, committed.id);
      saleDoc['totalMinor'] = 1000100;

      final report = await h.layer.importBackup(
        _saleOnlyBackup(saleDoc),
        policy: ImportPolicy.overwrite,
      );
      expect(report.errors, isEmpty);
      // The sale already lived here under its mock id — the
      // restore matched it by KEY, so it counts as overwritten,
      // not created, and there is still exactly one sale.
      expect(report.created, 0);
      expect(report.overwritten, 1);
      expect((await h.layer.saleRepo.getSales()).length, 1);
      expect(await h.layer.saleRepo.getById(committed.id), isNull);
      final restored =
          await h.layer.saleRepo.getById('sale-d173-same-1');
      expect(restored, isNotNull);
      expect(restored!.totalMinor, 1000100);
    });

    test('re-import under skipExisting leaves the sale alone',
        () async {
      final h = _MockHarness();
      final committed = await h.layer.saleRepo.createSale(
        _keyedSale(key: 'sale-d173-same-2'),
      );
      final saleDoc = await _exportedSaleDoc(h, committed.id);
      saleDoc['totalMinor'] = 1000100;

      final report = await h.layer.importBackup(
        _saleOnlyBackup(saleDoc),
      );
      expect(report.errors, isEmpty);
      expect(report.created, 0);
      expect(report.overwritten, 0);
      expect(report.skipped, 1);
      expect((await h.layer.saleRepo.getSales()).length, 1);
      final kept = await h.layer.saleRepo.getById(committed.id);
      expect(kept, isNotNull);
      expect(kept!.totalMinor, 1000000);
    });
  });

  group('D173 — D169 semantics intact', () {
    test('restore never deletes: a sale made after the export '
        'survives it', () async {
      final source = _MockHarness();
      await source.layer.saleRepo.createSale(
        _keyedSale(key: 'sale-d173-keep-1'),
      );
      final backup = await source.layer.exportBackup();

      final target = await _FirestoreHarness.create();
      await target.layer.saleRepo.createSale(
        sampleSale(key: 'sale-d173-keep-2'),
      );
      final report = await target.layer.importBackup(backup);
      expect(report.errors, isEmpty);
      expect(
        await target.layer.saleRepo.getById('sale-d173-keep-2'),
        isNotNull,
      );
      expect(
        await target.layer.saleRepo.getById('sale-d173-keep-1'),
        isNotNull,
      );
      expect((await target.layer.saleRepo.getSales()).length, 2);
    });

    test('counters are not restored: no counters section, no '
        'counter doc written', () async {
      final source = _MockHarness();
      final saved = await source.layer.saleRepo.createSale(
        _keyedSale(key: 'sale-d173-nocount-1'),
      );
      final backup = await source.layer.exportBackup();
      final sections = backup['sections'] as Map;
      expect(sections.containsKey('counters'), isFalse);
      expect(sections.containsKey('inventoryCounters'), isFalse);
      expect(sections.containsKey('salePayments'), isFalse);

      // The sale alone restores with no counter write: the sale
      // upsert touches no counter doc (order restores do mint
      // numbers, which is why the sale-only backup is used here).
      final target = await _FirestoreHarness.create();
      await target.layer.importBackup(
        _saleOnlyBackup(await _exportedSaleDoc(source, saved.id)),
      );
      expect(
        target.transport.countIn('branches/$_dha/counters'),
        0,
      );
    });

    test('the sink records the effective (re-keyed) id', () async {
      final source = _MockHarness();
      final saved = await source.layer.saleRepo.createSale(
        _keyedSale(key: 'sale-d173-sink-1'),
      );
      final target = await _FirestoreHarness.create();
      await target.layer.importBackup(await source.layer.exportBackup());

      final sink = target.layer.restoredData;
      expect(sink.count('sales'), 1);
      final sales = sink.snapshot['sales']!;
      expect(sales.containsKey('sale-d173-sink-1'), isTrue);
      expect(sales.containsKey(saved.id), isFalse);
    });
  });

  group('D173 — edges', () {
    test('a sale doc without an idempotencyKey restores under its '
        'exported id', () async {
      final target = _MockHarness();
      final report = await target.layer.importBackup({
        'format': BackupFormat.format,
        'formatVersion': BackupFormat.currentVersion,
        'organizationId': _org,
        'exportedAt': DateTime.now().toIso8601String(),
        'sections': {
          'sales': [
            {
              'id': 'sale-legacy-1',
              'branchId': _dha,
              'cashierName': 'Test Cashier',
              'items': [],
              'subtotalMinor': 50000,
              'totalMinor': 50000,
              'paymentMethod': 'cash',
              'payments': [],
              'cashReceivedMinor': 50000,
              'createdAt': DateTime(2026, 11, 26, 10, 0).toIso8601String(),
            },
          ],
        },
      });
      expect(report.errors, isEmpty);
      expect(report.created, 1);
      // Sale.fromMap falls back to the id as the key, so no
      // re-key is possible — the doc keeps its exported id.
      final restored =
          await target.layer.saleRepo.getById('sale-legacy-1');
      expect(restored, isNotNull);
      expect(restored!.idempotencyKey, 'sale-legacy-1');
    });

    test('a sale whose key already equals its id restores unchanged',
        () async {
      final target = _MockHarness();
      final saleDoc = {
        'id': 'sale-d173-noop-1',
        'branchId': _dha,
        'cashierName': 'Test Cashier',
        'items': [],
        'subtotalMinor': 50000,
        'totalMinor': 50000,
        'paymentMethod': 'cash',
        'payments': [],
        'cashReceivedMinor': 50000,
        'idempotencyKey': 'sale-d173-noop-1',
        'createdAt': DateTime(2026, 11, 26, 10, 0).toIso8601String(),
      };
      final first = await target.layer.importBackup(
        _saleOnlyBackup(saleDoc),
      );
      expect(first.created, 1);
      final second = await target.layer.importBackup(
        _saleOnlyBackup(saleDoc),
      );
      expect(second.created, 0);
      expect(second.skipped, 1);
      expect(
        (await target.layer.saleRepo.getById('sale-d173-noop-1'))!.id,
        'sale-d173-noop-1',
      );
    });

    test('orders re-key is a no-op: a mock order restores into the '
        'Firestore layer under its id (== key), counted once',
        () async {
      final source = _MockHarness();
      final created = await source.layer.orderRepo.createOrder(
        sampleOrder(),
      );
      // The mock mints the key equal to the id.
      expect(created.idempotencyKey, created.id);

      final target = await _FirestoreHarness.create();
      final first = await target.layer.importBackup(
        await source.layer.exportBackup(),
      );
      expect(first.errors, isEmpty);
      final doc = await target.transport.getDocument(
        FirestoreSchema.orderDocPath(_dha, created.id),
      );
      expect(doc, isNotNull);
      expect(doc!['idempotencyKey'], created.id);

      final second = await target.layer.importBackup(
        await source.layer.exportBackup(),
      );
      expect(second.errors, isEmpty);
      expect(second.created, 0);
      final orders = await target.layer.orderRepo.getOrders();
      expect(
        orders.where((order) => order.id == created.id),
        hasLength(1),
      );
    });
  });
}
