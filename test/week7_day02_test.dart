// Week 7 Day 2 tests — fake transport runTransaction + runBatchedWrites
// (D172, brief §2).
//
// - D172: the fake transport's transactions commit or roll back as a
//   whole (a failed transaction applies nothing, a successful one
//   applies every write at once, and reads inside it see its own
//   writes); batched writes are all-or-nothing, including across the
//   500-op chunk boundary.
// - D165 (closed here): the Firestore order repo's return values are
//   now verified end-to-end through the fake transport instead of by
//   code inspection — `createOrder` / `upsertOrder` return the order
//   number + idempotencyKey they assign, and the stored doc agrees.
//   A failed counter transaction consumes no number, so the next
//   order still gets the next sequence value.
//
// The fake transport, `seedBranches` and `sampleOrder` live in
// `test/week2_day03_test.dart` (the canonical fake — see
// `firestore_transport.dart`); this file imports them rather than
// carrying a second copy.

import 'package:flutter_test/flutter_test.dart';
import 'package:pharmadesk/core/data/firestore_repositories.dart';
import 'package:pharmadesk/core/data/firestore_schema.dart';
import 'package:pharmadesk/core/data/inventory_engine.dart'
    show WriteOperation, WriteOperationKind;

import 'week2_day03_test.dart';

const _dha = 'branch-dha-main';

void main() {
  group('Fake transport — transaction commit/rollback (D172)', () {
    test('commit: writes land together, reads see own writes', () async {
      final transport = FakeFirestoreTransport();
      await transport.setDocument('medicines/med-1', {
        'name': 'Panadol',
        'sellingPrice': 25000,
      });

      final result = await transport.runTransaction((tx) async {
        expect(await tx.get('medicines/med-1'), isNotNull);
        expect(await tx.get('medicines/med-2'), isNull);
        tx.set('medicines/med-2', {'name': 'Brufen'});
        // A read inside the transaction sees the write just made.
        expect((await tx.get('medicines/med-2'))?['name'], 'Brufen');
        tx.update('medicines/med-1', {'sellingPrice': 26000});
        tx.set(
          'medicines/med-1',
          {'requiresPrescription': true},
          merge: true,
        );
        return 'done';
      });
      expect(result, 'done');

      final updated = await transport.getDocument('medicines/med-1');
      expect(updated?['sellingPrice'], 26000);
      // The merge-set kept the original fields.
      expect(updated?['name'], 'Panadol');
      expect(updated?['requiresPrescription'], isTrue);
      expect(
        (await transport.getDocument('medicines/med-2'))?['name'],
        'Brufen',
      );
    });

    test('rollback: a throw discards every write it made', () async {
      final transport = FakeFirestoreTransport();
      await transport.setDocument('medicines/med-1', {'name': 'Before'});

      await expectLater(
        transport.runTransaction((tx) async {
          tx.set('medicines/med-2', {'name': 'Never lands'});
          tx.update('medicines/med-1', {'name': 'After'});
          // The transaction's own reads see the uncommitted writes…
          expect((await tx.get('medicines/med-2'))?['name'], 'Never lands');
          throw StateError('boom');
        }),
        throwsStateError,
      );

      // …but the store is exactly as it was before the transaction.
      expect(
        (await transport.getDocument('medicines/med-1'))?['name'],
        'Before',
      );
      expect(await transport.getDocument('medicines/med-2'), isNull);
    });

    test('rollback: a failed counter increment consumes no value', () async {
      final transport = FakeFirestoreTransport();
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

      expect(
        (await transport.getDocument(counterPath))?['value'],
        1001,
      );
    });

    test('a committed transaction is visible to the next one', () async {
      final transport = FakeFirestoreTransport();
      await transport.runTransaction((tx) async {
        tx.set('medicines/med-1', {'name': 'Panadol'});
      });
      final seen = await transport.runTransaction((tx) async {
        return (await tx.get('medicines/med-1'))?['name'];
      });
      expect(seen, 'Panadol');
    });

    test('transaction get reads pre-existing data, null when missing',
        () async {
      final transport = FakeFirestoreTransport();
      await transport.setDocument('medicines/med-1', {'name': 'Panadol'});
      final found = await transport.runTransaction(
        (tx) => tx.get('medicines/med-1'),
      );
      expect(found?['name'], 'Panadol');
      final missing = await transport.runTransaction(
        (tx) => tx.get('medicines/nope'),
      );
      expect(missing, isNull);
    });

    test('an update of a missing doc inside a transaction rolls back',
        () async {
      final transport = FakeFirestoreTransport();
      await expectLater(
        transport.runTransaction((tx) async {
          tx.set('medicines/med-1', {'name': 'Panadol'});
          // Throws: nothing in the transaction survives, not even
          // the set above it.
          tx.update('medicines/missing', {'name': 'Nope'});
        }),
        throwsStateError,
      );
      expect(await transport.getDocument('medicines/med-1'), isNull);
    });
  });

  group('Fake transport — batched-write atomicity (D172)', () {
    test('a successful batch applies set + update + delete together',
        () async {
      final transport = FakeFirestoreTransport();
      await transport.setDocument('medicines/med-1', {
        'name': 'Panadol',
        'sellingPrice': 25000,
      });
      await transport.setDocument('medicines/med-2', {'name': 'Brufen'});

      await transport.runBatchedWrites([
        WriteOperation(
          path: 'medicines/med-3',
          kind: WriteOperationKind.set,
          data: {'name': 'Augmentin'},
        ),
        WriteOperation(
          path: 'medicines/med-1',
          kind: WriteOperationKind.update,
          data: {'sellingPrice': 26000},
        ),
        WriteOperation(
          path: 'medicines/med-2',
          kind: WriteOperationKind.delete,
        ),
      ]);

      expect(
        (await transport.getDocument('medicines/med-3'))?['name'],
        'Augmentin',
      );
      expect(
        (await transport.getDocument('medicines/med-1'))?['sellingPrice'],
        26000,
      );
      expect(await transport.getDocument('medicines/med-2'), isNull);
    });

    test('a failing batch applies nothing — not even the sets before it',
        () async {
      final transport = FakeFirestoreTransport();
      await expectLater(
        transport.runBatchedWrites([
          WriteOperation(
            path: 'medicines/med-1',
            kind: WriteOperationKind.set,
            data: {'name': 'Panadol'},
          ),
          WriteOperation(
            path: 'medicines/med-2',
            kind: WriteOperationKind.set,
            data: {'name': 'Brufen'},
          ),
          // Update of a missing document throws mid-batch.
          WriteOperation(
            path: 'medicines/missing',
            kind: WriteOperationKind.update,
            data: {'name': 'Nope'},
          ),
        ]),
        throwsStateError,
      );
      expect(transport.countIn('medicines'), 0);
    });

    test('all-or-nothing holds across the 500-op chunk boundary', () async {
      final transport = FakeFirestoreTransport();
      final operations = [
        for (var i = 0; i < 501; i++)
          WriteOperation(
            path: 'medicines/doc-$i',
            kind: WriteOperationKind.set,
            data: {'name': 'Med $i'},
          ),
        // The bad operation sits in the second chunk — the first
        // chunk's 500 sets must still not land.
        WriteOperation(
          path: 'medicines/missing',
          kind: WriteOperationKind.update,
          data: {'name': 'Nope'},
        ),
      ];
      await expectLater(
        transport.runBatchedWrites(operations),
        throwsStateError,
      );
      expect(transport.countIn('medicines'), 0);
      // The chunk seam still recorded what was attempted.
      expect(
        transport.batchChunks.expand((chunk) => chunk).toList(),
        [500, 2],
      );
    });

    test('an empty batch is a no-op', () async {
      final transport = FakeFirestoreTransport();
      await transport.runBatchedWrites([]);
      expect(transport.batchChunks, isEmpty);
      expect(transport.countIn('medicines'), 0);
    });
  });

  group(
    'Firestore order repo — return values through the fake transport (D165/D172)',
    () {
      late FakeFirestoreTransport transport;

      setUp(() async {
        transport = FakeFirestoreTransport();
        await seedBranches(transport);
      });

      FirestoreOrderRepository ordersRepo() => FirestoreOrderRepository(
        transport: transport,
        organizationId: demoOrganizationId,
      );

      test(
        'createOrder with a client id returns its number + key',
        () async {
          final repo = ordersRepo();
          final created = await repo.createOrder(
            sampleOrder(id: 'order-client-1'),
          );
          expect(created.id, 'order-client-1');
          expect(created.orderNumber, 'ORD-DHA-1001');
          expect(created.idempotencyKey, 'order-client-1');

          // The stored doc agrees with what was returned.
          final stored = await transport.getDocument(
            'branches/$_dha/orders/order-client-1',
          );
          expect(stored?['orderNumber'], 'ORD-DHA-1001');
          expect(stored?['idempotencyKey'], 'order-client-1');
          // …and the read-back model does too.
          final readBack = await repo.getById('order-client-1');
          expect(readBack?.orderNumber, 'ORD-DHA-1001');
          expect(readBack?.idempotencyKey, 'order-client-1');
        },
      );

      test('createOrder with no id mints one and keys off it', () async {
        final repo = ordersRepo();
        final created = await repo.createOrder(sampleOrder());
        expect(created.id, isNotEmpty);
        expect(created.orderNumber, 'ORD-DHA-1001');
        expect(created.idempotencyKey, created.id);

        final stored = await transport.getDocument(
          'branches/$_dha/orders/${created.id}',
        );
        expect(stored?['orderNumber'], 'ORD-DHA-1001');
        expect(stored?['idempotencyKey'], created.id);
      });

      test(
        'duplicate createOrder returns the original and consumes no number',
        () async {
          final repo = ordersRepo();
          final first = await repo.createOrder(
            sampleOrder(id: 'order-client-1'),
          );
          expect(first.orderNumber, 'ORD-DHA-1001');

          final retry = await repo.createOrder(
            sampleOrder(id: 'order-client-1'),
          );
          expect(retry.orderNumber, 'ORD-DHA-1001');
          expect(retry.idempotencyKey, 'order-client-1');
          expect(transport.countIn('branches/$_dha/orders'), 1);

          // The retry consumed no counter value: the next new order
          // is 1002, not 1003.
          final second = await repo.createOrder(
            sampleOrder(id: 'order-client-2'),
          );
          expect(second.orderNumber, 'ORD-DHA-1002');
        },
      );

      test('upsertOrder for a new order returns the assigned number + key',
          () async {
        final repo = ordersRepo();
        final upserted = await repo.upsertOrder(
          sampleOrder(id: 'order-restore-1'),
        );
        expect(upserted.id, 'order-restore-1');
        expect(upserted.orderNumber, 'ORD-DHA-1001');
        expect(upserted.idempotencyKey, 'order-restore-1');

        final stored = await transport.getDocument(
          'branches/$_dha/orders/order-restore-1',
        );
        expect(stored?['orderNumber'], 'ORD-DHA-1001');
        expect(stored?['idempotencyKey'], 'order-restore-1');
      });

      test('upsertOrder keeps an existing order’s number and key',
          () async {
        final repo = ordersRepo();
        final created = await repo.createOrder(
          sampleOrder(id: 'order-client-1'),
        );
        expect(created.orderNumber, 'ORD-DHA-1001');

        // A restore replay of the same order (e.g. a changed
        // address) never re-numbers it and consumes no counter.
        final replayed = await repo.upsertOrder(
          created.copyWith(deliveryAddress: 'Street 2, DHA'),
        );
        expect(replayed.orderNumber, 'ORD-DHA-1001');
        expect(replayed.idempotencyKey, 'order-client-1');

        final next = await repo.createOrder(
          sampleOrder(id: 'order-client-2'),
        );
        expect(next.orderNumber, 'ORD-DHA-1002');
      });

      test('upsertOrder with no id mints one and assigns a number',
          () async {
        final repo = ordersRepo();
        final upserted = await repo.upsertOrder(sampleOrder());
        expect(upserted.id, isNotEmpty);
        expect(upserted.orderNumber, 'ORD-DHA-1001');
        expect(upserted.idempotencyKey, upserted.id);
      });

      test('getById returns the same number/key the create returned',
          () async {
        final repo = ordersRepo();
        final created = await repo.createOrder(
          sampleOrder(id: 'order-client-1'),
        );
        final readBack = await repo.getById('order-client-1');
        expect(readBack?.orderNumber, created.orderNumber);
        expect(readBack?.idempotencyKey, created.idempotencyKey);
        expect(readBack?.effectiveOrderNumber, 'ORD-DHA-1001');
      });

      test(
        'a failed counter transaction consumes no number for the next order',
        () async {
          final repo = ordersRepo();
          final first = await repo.createOrder(
            sampleOrder(id: 'order-client-1'),
          );
          expect(first.orderNumber, 'ORD-DHA-1001');

          // Bump the counter inside a transaction, then fail it:
          // the rollback (D172) must leave the counter at 1001.
          final counterPath = FirestoreSchema.counterDocPath(
            _dha,
            'orders',
          );
          await expectLater(
            transport.runTransaction((tx) async {
              final current = await tx.get(counterPath);
              tx.set(counterPath, {
                'value': (current?['value'] as int) + 1,
                'organizationId': demoOrganizationId,
                'branchId': _dha,
              });
              throw StateError('boom');
            }),
            throwsStateError,
          );
          expect(
            (await transport.getDocument(counterPath))?['value'],
            1001,
          );

          final second = await repo.createOrder(
            sampleOrder(id: 'order-client-2'),
          );
          expect(second.orderNumber, 'ORD-DHA-1002');
        },
      );
    },
  );
}
