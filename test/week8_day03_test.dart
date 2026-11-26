// Week 8 Day 3 tests — fake-transport copies sweep (D178, brief §3).
//
// Sweep outcome (see `docs/day-40-progress.md` for the per-copy table):
// 12 non-canonical fake-transport copies were found in `test/`
// (week2_day04, week3_day01–03, week4_day02–03, week5_day01–03,
// week6_day03–04, week7_day01). NONE of them is upgraded: no
// production-layer test in any of those files relies on its copy for
// transaction/batch atomicity — no test in those files would
// pass/fail differently if a transaction or batched write failed
// part-way. Every atomicity-sensitive production test lives in
// week7_day02–05, which import the canonical D172 fake from
// `week2_day03_test.dart`.
//
// These tests therefore pin two things:
//   (A) the canonical D172 atomicity standard itself (failed
//       transaction applies nothing, failed batch applies nothing,
//       reads inside a transaction see its own writes, a failed
//       counter transaction consumes no value) — the standard the
//       sweep holds every copy against; and
//   (B) the untouched PUBLIC copies' behaviour where it matters:
//       each copy's production path still returns exactly what its
//       own file's tests rely on. The private copies
//       (`_FakeTransport`, `_FakeFirestoreTransport`,
//       `_MemoryTransport`) cannot be referenced from another library,
//       so their behaviour is pinned by their own files' tests, which
//       the cumulative suite re-runs — see the progress doc for the
//       test names.

import 'package:flutter_test/flutter_test.dart';
import 'package:pharmadesk/core/data/firestore_mappers.dart';
import 'package:pharmadesk/core/data/firestore_repositories.dart';
import 'package:pharmadesk/core/data/firestore_schema.dart';
import 'package:pharmadesk/core/data/inventory_engine.dart'
    show WriteOperation, WriteOperationKind;
import 'package:pharmadesk/core/data/report_counters.dart';
import 'package:pharmadesk/models/branch_inventory_location.dart';
import 'package:pharmadesk/models/goods_receipt.dart';
import 'package:pharmadesk/models/staff.dart';

import 'week2_day03_test.dart' as canon;
import 'week3_day01_test.dart' as w3d1;
import 'week3_day02_test.dart' as w3d2;
import 'week3_day03_test.dart' as w3d3;
import 'week5_day03_test.dart' as w5d3;

const _dha = 'branch-dha-main';
const _glb = 'branch-demo-gulberg';
const _org = demoOrganizationId;
const _panadol = 'med-panadol-extra';

void main() {
  group('D178 — canonical fake: the D172 atomicity standard', () {
    test('failed transaction applies nothing', () async {
      final transport = canon.FakeFirestoreTransport();
      await transport.setDocument('medicines/med-1', {'name': 'Before'});

      await expectLater(
        transport.runTransaction((tx) async {
          tx.set('medicines/med-2', {'name': 'Never lands'});
          tx.update('medicines/med-1', {'name': 'After'});
          throw StateError('boom');
        }),
        throwsStateError,
      );

      expect(
        (await transport.getDocument('medicines/med-1'))?['name'],
        'Before',
      );
      expect(await transport.getDocument('medicines/med-2'), isNull);
    });

    test('failed batch applies nothing', () async {
      final transport = canon.FakeFirestoreTransport();
      await transport.setDocument('medicines/med-1', {'name': 'Before'});

      await expectLater(
        transport.runBatchedWrites([
          WriteOperation(
            path: 'medicines/med-2',
            kind: WriteOperationKind.set,
            data: {'name': 'Never lands'},
          ),
          WriteOperation(
            path: 'medicines/no-such-doc',
            kind: WriteOperationKind.update,
            data: {'name': 'Boom'},
          ),
        ]),
        throwsStateError,
      );

      // The good set earlier in the batch did not land either.
      expect(await transport.getDocument('medicines/med-2'), isNull);
      expect(
        (await transport.getDocument('medicines/med-1'))?['name'],
        'Before',
      );
    });

    test('reads inside a transaction see its own writes', () async {
      final transport = canon.FakeFirestoreTransport();
      await transport.setDocument('medicines/med-1', {'name': 'Panadol'});

      final seen = await transport.runTransaction((tx) async {
        tx.set('medicines/med-2', {'name': 'Brufen'});
        final own = await tx.get('medicines/med-2');
        final pre = await tx.get('medicines/med-1');
        return (own?['name'], pre?['name']);
      });
      expect(seen, ('Brufen', 'Panadol'));
      expect(
        (await transport.getDocument('medicines/med-2'))?['name'],
        'Brufen',
      );
    });

    test('failed counter transaction consumes no value', () async {
      final transport = canon.FakeFirestoreTransport();
      const counterPath = 'branches/branch-dha-main/counters/orders';
      await transport.setDocument(counterPath, {'value': 1001});

      await expectLater(
        transport.runTransaction((tx) async {
          final current = await tx.get(counterPath);
          tx.set(counterPath, {'value': (current?['value'] as int) + 1});
          throw StateError('boom');
        }),
        throwsStateError,
      );

      expect((await transport.getDocument(counterPath))?['value'], 1001);
    });
  });

  group('D178 — untouched copies: behaviour unchanged where it matters', () {
    test('week3_day01 copy (left as-is): staff create + get round-trips',
        () async {
      // This copy serves only repos whose writes are plain
      // get/set/update — none of them calls runTransaction or
      // runBatchedWrites — so no test can rely on it for atomicity.
      final transport = w3d1.FakeFirestoreTransport();
      await w3d1.seedBranches(transport);
      final repo = FirestoreStaffRepository(
        transport: transport,
        organizationId: _org,
      );
      final created = await repo.createStaff(
        const Staff(
          id: '',
          name: 'Ayesha Khan',
          email: 'ayesha@example.com',
          role: StaffRole.pharmacist,
          branchId: _dha,
          phone: '03001234567',
          roleKey: 'pharmacist',
        ),
      );
      expect(created.id, isNotEmpty);
      expect(created.name, 'Ayesha Khan');
      expect((await repo.getById(created.id))?.phone, '03001234567');
      expect(
        (await repo.getStaff(branchId: _dha)).map((s) => s.id),
        contains(created.id),
      );
      expect(await repo.getStaff(branchId: _glb), isEmpty);
    });

    test(
        'week3_day02 copy (left as-is): goods-receipt create numbers via '
        'counter + batch, retry consumes nothing', () async {
      // The only transaction/batch path this copy serves is
      // `createGoodsReceipt` (counter transaction + batch of sets),
      // exercised here on its success path only — no test in the file
      // makes either operation fail part-way.
      final transport = w3d2.FakeFirestoreTransport();
      await w3d2.seedBranches(transport);
      final repo = FirestoreGoodsReceiptRepository(
        transport: transport,
        organizationId: _org,
      );
      GoodsReceipt receipt(String id) => GoodsReceipt(
            id: id,
            poId: 'po-1',
            supplierId: 'sup-sami',
            branchId: _dha,
            items: [
              GoodsReceiptItem(
                medicineId: _panadol,
                medicineName: 'Panadol Extra',
                quantityReceived: 10,
                batchNo: 'B-TEST-1',
                mfgDate: DateTime(2026, 1, 1),
                expiryDate: DateTime(2027, 1, 1),
                unitCostMinor: 10000,
              ),
            ],
          );
      final first = await repo.createGoodsReceipt(receipt('gr-a'));
      expect(first.receiptNumber, 'GR-DHA-1001');
      final again = await repo.createGoodsReceipt(receipt('gr-a'));
      expect(again.receiptNumber, 'GR-DHA-1001');
      expect(transport.countIn('branches/$_dha/goodsReceipts'), 1);
      // The retry consumed no counter value.
      final second = await repo.createGoodsReceipt(receipt('gr-b'));
      expect(second.receiptNumber, 'GR-DHA-1002');
      expect(
        (await repo.getById('gr-a'))?.items.first.batchNo,
        'B-TEST-1',
      );
    });

    test('week3_day03 copy (left as-is): report-counter reads hit + miss',
        () async {
      // This copy serves a read-only repo — no write, transaction or
      // batch is ever issued through it.
      final transport = w3d3.FakeFirestoreTransport();
      final repo = FirestoreReportCounterRepository(
        transport: transport,
        organizationId: _org,
      );
      final day = DateTime(2026, 11, 25);
      await transport.setDocument(
        FirestoreSchema.dailyCounterDocPath(_dha, day),
        dailyCounterToFirestore(
          DailyCounter(
            branchId: _dha,
            date: day,
            salesTotalMinor: 250000,
            salesCount: 25,
            ordersCount: 25,
            cogsMinor: 100000,
            grossProfitMinor: 150000,
          ),
          orgId: _org,
        ),
      );
      final hit = await repo.getDailyCounter(branchId: _dha, date: day);
      expect(hit, isNotNull);
      expect(hit!.salesTotalMinor, 250000);
      expect(hit.ordersCount, 25);
      expect(
        await repo.getDailyCounter(
          branchId: _dha,
          date: DateTime(2026, 10, 1),
        ),
        isNull,
      );
    });

    test(
        'week5_day03 copy (left as-is): branch-location merge-set keeps '
        'counters', () async {
      // The only Firestore-repo path this copy serves is
      // `saveBranchLocation`, a plain merge-set — no transaction or
      // batch is ever issued through it.
      final transport = w5d3.FakeFirestoreTransport();
      final repo = FirestoreInventoryRepository(
        transport: transport,
        organizationId: _org,
      );
      await transport.setDocument(
        FirestoreSchema.inventoryDocPath(_dha, _panadol),
        {'quantityOnHand': 5, 'quantityReserved': 0, 'rack': 'Old Rack'},
      );
      final saved = await repo.saveBranchLocation(
        const BranchInventoryLocation(
          branchId: _dha,
          medicineId: _panadol,
          rack: 'Rack B',
          shelf: 'Shelf 1',
        ),
      );
      expect(saved.displayLabel, 'Rack B • Shelf 1');
      final raw = await transport.getDocument(
        FirestoreSchema.inventoryDocPath(_dha, _panadol),
      );
      expect(raw!['quantityOnHand'], 5);
      expect(raw['rack'], 'Rack B');
      await repo.saveBranchLocation(
        const BranchInventoryLocation(branchId: _dha, medicineId: _panadol),
      );
      final afterClear = await transport.getDocument(
        FirestoreSchema.inventoryDocPath(_dha, _panadol),
      );
      expect(afterClear!['quantityOnHand'], 5);
    });
  });
}
