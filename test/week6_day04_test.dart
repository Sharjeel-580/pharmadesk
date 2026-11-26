// Week 6 Day 4 tests — model gaps + barcode uniqueness + POS tax
// live-watch + branch code field (D165, D166, D167, D168).
//
// Part A (D165): `Supplier.createdAt`, `Order.orderNumber` +
// `Order.idempotencyKey` — model → Firestore doc → model round-trips
// preserve them; legacy docs without them read back to the documented
// defaults (never a crash). Seeded rows keep the documented defaults.
// Part B (D166): barcode uniqueness is enforced at the medicine
// master repo (mock + Firestore), not the form — a duplicate is
// rejected with a clear message, the medicine's own barcode and an
// empty barcode pass, and the seeded catalogue is checked for
// duplicates (reported, not silently fixed).
// Part C (D167): the POS tax rate is live-watched — a Settings change
// while a sale is open re-rates the sale, unless the cashier already
// picked a rate from the dropdown this sale.
// Part D (D168): the add/edit branch form has a code field with the
// same validation as the mapper (2–8 uppercase alphanumerics);
// blank falls back to the derived default.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:pharmadesk/core/data/auth_repository.dart';
import 'package:pharmadesk/core/data/firestore_mappers.dart';
import 'package:pharmadesk/core/data/firestore_repositories.dart';
import 'package:pharmadesk/core/data/firestore_schema.dart';
import 'package:pharmadesk/core/data/firestore_transport.dart';
import 'package:pharmadesk/core/data/inventory_engine.dart';
import 'package:pharmadesk/core/routing/app_router.dart';
import 'package:pharmadesk/core/services/demo_seed_data.dart';
import 'package:pharmadesk/core/services/repositories.dart';
import 'package:pharmadesk/core/theme/app_theme.dart';
import 'package:pharmadesk/core/theme/white_label.dart';
import 'package:pharmadesk/core/widgets/fields.dart';
import 'package:pharmadesk/features/authentication/auth_state.dart';
import 'package:pharmadesk/features/branches/branch_directory.dart';
import 'package:pharmadesk/features/branches/branch_form_dialog.dart';
import 'package:pharmadesk/features/medicines/medicine_edit_dialog.dart';
import 'package:pharmadesk/features/medicines/medicine_logic.dart';
import 'package:pharmadesk/features/settings/org_settings.dart';
import 'package:pharmadesk/models/branch.dart';
import 'package:pharmadesk/models/medicine.dart';
import 'package:pharmadesk/models/order.dart';
import 'package:pharmadesk/models/supplier.dart';

const _dha = 'branch-dha-main';
const _glb = 'branch-demo-gulberg';
const _org = demoOrganizationId;

Order _order({
  String id = 'ord-dha-1001',
  String orderNumber = '',
  String idempotencyKey = '',
}) {
  return Order(
    id: id,
    customerId: 'cust-1',
    branchId: _dha,
    items: const [
      OrderItem(
        medicineId: 'med-1',
        medicineName: 'Panadol Extra',
        quantity: 2,
        unitPrice: 120,
      ),
    ],
    deliveryAddress: 'Pickup from branch',
    totalAmount: 240,
    orderNumber: orderNumber,
    idempotencyKey: idempotencyKey,
    createdAt: DateTime(2026, 11, 26, 10, 0),
  );
}

Supplier _supplier({DateTime? createdAt}) {
  return Supplier(
    id: 'sup-test',
    name: 'Test Supplier',
    contactPerson: 'Tester',
    phone: '0300-0000001',
    createdAt: createdAt,
  );
}

void main() {
  group('Supplier.createdAt — model + mapper (D165)', () {
    test('model: toMap/fromMap round-trips createdAt', () {
      final supplier = _supplier(
        createdAt: DateTime(2026, 11, 1, 10, 30),
      );
      final back = Supplier.fromMap(supplier.id, supplier.toMap());
      expect(back.createdAt, DateTime(2026, 11, 1, 10, 30));
      expect(back.name, 'Test Supplier');
      expect(supplier.copyWith(name: 'Renamed').createdAt,
          DateTime(2026, 11, 1, 10, 30));
    });

    test('model: a legacy map without createdAt reads back as null',
        () {
      // Seeded / legacy rows predate the field: null means
      // "unknown", never an invented date (D165).
      final back = Supplier.fromMap('sup-sami', {
        'name': 'Sami Pharmaceuticals',
        'contactPerson': 'Sami Ullah',
        'phone': '0300-7778899',
      });
      expect(back.createdAt, isNull);
    });

    test('seeded suppliers carry the documented default (null)', () {
      expect(demoSuppliers.length, 4);
      for (final supplier in demoSuppliers) {
        expect(
          supplier.createdAt,
          isNull,
          reason: '${supplier.id} predates the field (D165)',
        );
      }
    });

    test('mapper: round-trips createdAt; legacy doc reads null', () {
      final supplier = _supplier(
        createdAt: DateTime(2026, 11, 1, 10, 30),
      );
      final doc = supplierToFirestore(supplier, orgId: _org);
      expect(FirestoreSchema.validateDocument('suppliers', doc), isEmpty);
      final back = supplierFromFirestore('sup-test', doc);
      expect(back.createdAt, DateTime(2026, 11, 1, 10, 30));

      final legacy = supplierFromFirestore('sup-legacy', {
        'name': 'Legacy Supplier',
        'contactPerson': 'Nobody',
        'phone': '0300-1',
      });
      expect(legacy.createdAt, isNull);
    });

    test('mapper: a supplier without createdAt is stamped now', () {
      final before = DateTime.now().subtract(
        const Duration(seconds: 5),
      );
      final doc = supplierToFirestore(_supplier(), orgId: _org);
      expect(doc['createdAt'], isNotNull);
      final back = supplierFromFirestore('sup-test', doc);
      expect(back.createdAt, isNotNull);
      expect(back.createdAt!.isAfter(before), isTrue);
    });
  });

  group('Order orderNumber + idempotencyKey — model + mapper (D165)', () {
    test('effective values derive from the id when unset', () {
      final legacy = _order();
      expect(legacy.orderNumber, '');
      expect(legacy.idempotencyKey, '');
      expect(legacy.effectiveOrderNumber, 'ORD-DHA-1001');
      expect(legacy.effectiveIdempotencyKey, 'ord-dha-1001');
      expect(defaultOrderNumberForId('ord-glb-1042'), 'ORD-GLB-1042');
      expect(defaultOrderNumberForId(''), '');
      final assigned = _order(
        orderNumber: 'ORD-DHA-1001',
        idempotencyKey: 'ord-dha-1001',
      );
      expect(assigned.effectiveOrderNumber, 'ORD-DHA-1001');
      expect(assigned.effectiveIdempotencyKey, 'ord-dha-1001');
    });

    test('model: toMap/fromMap round-trips both fields, stably', () {
      final order = _order(
        orderNumber: 'ORD-DHA-1001',
        idempotencyKey: 'ord-dha-1001',
      );
      final back = Order.fromMap(order.id, order.toMap());
      expect(back.orderNumber, 'ORD-DHA-1001');
      expect(back.idempotencyKey, 'ord-dha-1001');
      // Re-serializing keeps the same key (D165): a second
      // round-trip must not mint anything new.
      final again = Order.fromMap(back.id, back.toMap());
      expect(again.orderNumber, 'ORD-DHA-1001');
      expect(again.idempotencyKey, 'ord-dha-1001');
      expect(again.effectiveOrderNumber, 'ORD-DHA-1001');
      expect(again.effectiveIdempotencyKey, 'ord-dha-1001');
      expect(order.copyWith(status: OrderStatus.confirmed).orderNumber,
          'ORD-DHA-1001');
    });

    test('model: a legacy map without the fields reads back safe', () {
      final back = Order.fromMap('ord-dha-1001', {
        'customerId': 'cust-1',
        'branchId': _dha,
        'totalAmount': 240.0,
      });
      expect(back.orderNumber, '');
      expect(back.idempotencyKey, '');
      expect(back.effectiveOrderNumber, 'ORD-DHA-1001');
      expect(back.effectiveIdempotencyKey, 'ord-dha-1001');
    });

    test('mapper: round-trips an assigned number + key', () {
      final order = _order(
        orderNumber: 'ORD-DHA-1001',
        idempotencyKey: 'ord-dha-1001',
      );
      final doc = orderToFirestore(
        order,
        orgId: _org,
        orderNumber: 'ORD-DHA-1001',
        idempotencyKey: 'ord-dha-1001',
      );
      expect(doc['orderNumber'], 'ORD-DHA-1001');
      expect(doc['idempotencyKey'], 'ord-dha-1001');
      expect(
        FirestoreSchema.validateDocument(
          'branches/{branchId}/orders',
          doc,
        ),
        isEmpty,
      );
      final back = orderFromFirestore('ord-dha-1001', doc);
      expect(back.orderNumber, 'ORD-DHA-1001');
      expect(back.idempotencyKey, 'ord-dha-1001');
    });

    test('mapper: no explicit number falls back to the model', () {
      // The repo always passes a number; a direct mapper call with
      // none still writes a valid §3 doc from the model's fields.
      final assigned = _order(
        orderNumber: 'ORD-DHA-1001',
        idempotencyKey: 'ord-dha-1001',
      );
      final doc = orderToFirestore(assigned, orgId: _org);
      expect(doc['orderNumber'], 'ORD-DHA-1001');
      expect(doc['idempotencyKey'], 'ord-dha-1001');
      // A legacy order (empty fields) derives both from its id.
      final legacy = _order();
      final legacyDoc = orderToFirestore(legacy, orgId: _org);
      expect(legacyDoc['orderNumber'], 'ORD-DHA-1001');
      expect(legacyDoc['idempotencyKey'], 'ord-dha-1001');
      expect(
        FirestoreSchema.validateDocument(
          'branches/{branchId}/orders',
          legacyDoc,
        ),
        isEmpty,
      );
    });

    test('mapper: a legacy doc without number/key reads back safe',
        () {
      final back = orderFromFirestore('ord-glb-1042', {
        'customerId': 'cust-1',
        'branchId': _glb,
        'grandTotal': 50000,
      });
      expect(back.orderNumber, '');
      expect(back.idempotencyKey, '');
      expect(back.effectiveOrderNumber, 'ORD-GLB-1042');
      expect(back.effectiveIdempotencyKey, 'ord-glb-1042');
    });

    test('seeded orders: effective number + key derive from the id',
        () {
      final orders = generateDemoOrders();
      expect(orders.length, 491);
      final first = orders.first;
      expect(first.id, 'ord-dha-1001');
      expect(first.orderNumber, '');
      expect(first.effectiveOrderNumber, 'ORD-DHA-1001');
      expect(first.effectiveIdempotencyKey, 'ord-dha-1001');
      for (final order in orders) {
        expect(order.effectiveIdempotencyKey, order.id);
        expect(order.effectiveOrderNumber, startsWith('ORD-'));
        // Re-serialization is stable for every seeded order.
        final back = Order.fromMap(order.id, order.toMap());
        expect(back.effectiveOrderNumber, order.effectiveOrderNumber);
        expect(back.effectiveIdempotencyKey, order.id);
      }
    });
  });

  group('Mock order + supplier repos — numbers and keys (D165)', () {
    test('mock createOrder assigns and RETURNS number + key', () async {
      final repo = MockOrderRepository();
      final saved = await repo.createOrder(_order(id: ''));
      expect(saved.id, startsWith('ord-dha-'));
      expect(saved.orderNumber, defaultOrderNumberForId(saved.id));
      expect(saved.orderNumber, startsWith('ORD-DHA-'));
      expect(saved.idempotencyKey, saved.id);
      final stored = await repo.getById(saved.id);
      expect(stored!.orderNumber, saved.orderNumber);
      expect(stored.idempotencyKey, saved.id);
    });

    test('mock upsertOrder: new gets derived values, existing keeps',
        () async {
      final repo = MockOrderRepository();
      final fresh = await repo.upsertOrder(_order(id: ''));
      expect(fresh.orderNumber, defaultOrderNumberForId(fresh.id));
      expect(fresh.idempotencyKey, fresh.id);
      // A seeded order upserted (restore replay) keeps its
      // derived number and key instead of being re-numbered.
      final seeded = (await repo.getOrders()).first;
      final replayed = await repo.upsertOrder(
        seeded.copyWith(status: OrderStatus.confirmed),
      );
      expect(replayed.orderNumber, seeded.effectiveOrderNumber);
      expect(replayed.idempotencyKey, seeded.id);
      expect(replayed.status, OrderStatus.confirmed);
    });

    test('mock createSupplier stamps createdAt; update keeps it',
        () async {
      final repo = MockSupplierRepository();
      final created = await repo.createSupplier(_supplier());
      expect(created.createdAt, isNotNull);
      // An update that carries no createdAt never rewrites it.
      final edited = Supplier(
        id: created.id,
        name: 'Test Supplier Renamed',
        contactPerson: 'Tester',
        phone: '0300-0000001',
      );
      await repo.updateSupplier(edited);
      final stored = await repo.getById(created.id);
      expect(stored!.name, 'Test Supplier Renamed');
      expect(stored.createdAt, created.createdAt);
    });

    test('mock upsertSupplier keeps the incoming or stored createdAt',
        () async {
      final repo = MockSupplierRepository();
      final stamped = DateTime(2026, 10, 5, 9, 0);
      final saved = await repo.upsertSupplier(
        _supplier(createdAt: stamped),
      );
      expect(saved.createdAt, stamped);
      // A restore replay without createdAt keeps the stored one.
      final replayed = await repo.upsertSupplier(
        Supplier(
          id: saved.id,
          name: 'Test Supplier',
          contactPerson: 'Tester',
          phone: '0300-0000001',
        ),
      );
      expect(replayed.createdAt, stamped);
    });
  });

  group('Barcode uniqueness — pure helper (D166)', () {
    test('finds a conflict, ignores own id and empty barcodes', () {
      const medicines = [
        Medicine(
          id: 'med-1',
          name: 'Panadol Extra',
          brand: 'GSK',
          categoryId: 'cat-analgesic',
          strength: '500mg',
          packSize: '20 tablets',
          price: 120,
          barcode: '8901000000001',
        ),
        Medicine(
          id: 'med-2',
          name: 'Brufen',
          brand: 'Abbott',
          categoryId: 'cat-analgesic',
          strength: '400mg',
          packSize: '20 tablets',
          price: 150,
          barcode: '8901000000002',
        ),
      ];
      final conflict = findBarcodeConflict(
        medicines,
        barcode: '8901000000001',
        excludeId: 'med-2',
      );
      expect(conflict, isNotNull);
      expect(conflict!.id, 'med-1');
      expect(
        barcodeConflictMessage('8901000000001', conflict.name),
        contains('already used by "Panadol Extra"'),
      );
      // The medicine's own barcode is not a conflict.
      expect(
        findBarcodeConflict(
          medicines,
          barcode: '8901000000001',
          excludeId: 'med-1',
        ),
        isNull,
      );
      // Empty / absent barcodes never conflict.
      expect(
        findBarcodeConflict(
          medicines,
          barcode: '',
          excludeId: 'med-2',
        ),
        isNull,
      );
      expect(
        findBarcodeConflict(
          medicines,
          barcode: null,
          excludeId: 'med-2',
        ),
        isNull,
      );
      // Surrounding whitespace cannot smuggle a duplicate past.
      expect(
        findBarcodeConflict(
          medicines,
          barcode: '  8901000000001  ',
          excludeId: 'med-2',
        )!
            .id,
        'med-1',
      );
      expect(
        findBarcodeConflict(
          medicines,
          barcode: '8901000000099',
          excludeId: 'med-2',
        ),
        isNull,
      );
    });

    test('seeded catalogue: no duplicate barcodes (data note)', () {
      // Reported, not silently fixed: the seed generator mints
      // `8901000000001…14` for the core rows and `8902000000000+i`
      // for the generated rows, so no two medicines share a code.
      final seen = <String, String>{};
      final duplicates = <String>[];
      for (final medicine in demoMedicines) {
        final code = medicine.barcode?.trim() ?? '';
        if (code.isEmpty) continue;
        if (seen.containsKey(code)) {
          duplicates.add(code);
        } else {
          seen[code] = medicine.id;
        }
      }
      expect(demoMedicines.length, 180);
      expect(seen.length, 180);
      expect(duplicates, isEmpty);
    });
  });

  group('Barcode uniqueness — mock medicine repo (D166)', () {
    late Medicine first;
    late Medicine second;

    setUp(() {
      first = demoMedicines[0];
      second = demoMedicines[1];
    });

    test('a barcode used by a DIFFERENT medicine is rejected', () async {
      final repo = MockMedicineRepository();
      expect(
        () => repo.updateMedicine(
          second.copyWith(barcode: first.barcode),
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message?.toString() ?? '',
            'message',
            contains('already used by "${first.name}"'),
          ),
        ),
      );
      // Nothing was written.
      expect((await repo.getById(second.id))!.barcode, second.barcode);
    });

    test('keeping the medicine’s own barcode on edit is fine',
        () async {
      final repo = MockMedicineRepository();
      final original = first;
      try {
        final saved = await repo.updateMedicine(
          first.copyWith(
            barcode: first.barcode,
            name: '${first.name} Plus',
          ),
        );
        expect(saved.barcode, first.barcode);
        expect(saved.name, '${first.name} Plus');
      } finally {
        await repo.upsertMedicine(original);
      }
      expect((await repo.getById(first.id))!.name, original.name);
    });

    test('an empty barcode is fine (not all medicines have one)',
        () async {
      final repo = MockMedicineRepository();
      final original = first;
      try {
        final saved = await repo.updateMedicine(
          first.copyWith(clearBarcode: true),
        );
        expect(saved.barcode, isNull);
      } finally {
        await repo.upsertMedicine(original);
      }
      expect((await repo.getById(first.id))!.barcode, original.barcode);
    });

    test('upsert never re-checks (restore replay, D150)', () async {
      // A restore replays data that was valid when exported; the
      // uniqueness check lives on updateMedicine only.
      final repo = MockMedicineRepository();
      final original = first;
      try {
        final saved = await repo.upsertMedicine(
          first.copyWith(barcode: second.barcode),
        );
        expect(saved.barcode, second.barcode);
      } finally {
        await repo.upsertMedicine(original);
      }
    });
  });

  group('Barcode uniqueness — Firestore medicine repo (D166)', () {
    test('duplicate rejected; own and empty barcodes pass', () async {
      final repo = FirestoreMedicineRepository(
        transport: _MemoryTransport(),
        organizationId: _org,
      );
      const first = Medicine(
        id: 'med-a',
        name: 'Panadol Extra',
        brand: 'GSK',
        categoryId: 'cat-analgesic',
        strength: '500mg',
        packSize: '20 tablets',
        price: 120,
        barcode: '8901000000001',
      );
      const second = Medicine(
        id: 'med-b',
        name: 'Brufen',
        brand: 'Abbott',
        categoryId: 'cat-analgesic',
        strength: '400mg',
        packSize: '20 tablets',
        price: 150,
        barcode: '8901000000002',
      );
      await repo.upsertMedicine(first);
      await repo.upsertMedicine(second);
      expect(
        () => repo.updateMedicine(
          second.copyWith(barcode: '8901000000001'),
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message?.toString() ?? '',
            'message',
            contains('already used by "Panadol Extra"'),
          ),
        ),
      );
      expect((await repo.getById('med-b'))!.barcode, '8901000000002');
      final own = await repo.updateMedicine(
        second.copyWith(barcode: '8901000000002', name: 'Brufen Plus'),
      );
      expect(own.barcode, '8901000000002');
      final cleared = await repo.updateMedicine(
        second.copyWith(clearBarcode: true),
      );
      expect(cleared.barcode, isNull);
    });
  });

  group('Barcode uniqueness — edit form surfaces the rejection (D166)',
      () {
    testWidgets('duplicate barcode shows the error and stays open', (
      tester,
    ) async {
      final repo = MockMedicineRepository();
      final first = demoMedicines[0];
      final second = demoMedicines[1];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            medicineRepositoryProvider.overrideWithValue(repo),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) => TextButton(
                  onPressed: () => showEditMedicineDialog(
                    context,
                    ref,
                    medicine: second,
                  ),
                  child: const Text('Edit medicine'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit medicine'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('medicine-barcode-field')),
        first.barcode!,
      );
      await tester.tap(find.byKey(const ValueKey('medicine-edit-save')));
      await tester.pumpAndSettle();
      expect(find.textContaining('already used by'), findsOneWidget);
      // The dialog stayed open and nothing was written.
      expect(find.byKey(const ValueKey('medicine-edit-save')), findsOneWidget);
      expect((await repo.getById(second.id))!.barcode, second.barcode);
    });
  });

  group('POS tax is live-watched (D167)', () {
    testWidgets('a Settings change re-rates the open sale', (
      tester,
    ) async {
      final (container, router) = await _pumpRouterAppAsRole(
        tester,
        'cashier',
      );
      router.go('/billing');
      await tester.pumpAndSettle();
      expect(find.text('Billing & POS'), findsWidgets);
      // The sale starts at the Settings default: 0% — no Tax row.
      final dropdown = find.byKey(const ValueKey('pos-tax-dropdown'));
      expect(
        tester.widget<DropdownButton<int>>(dropdown).value,
        0,
      );
      expect(find.textContaining('Tax ('), findsNothing);
      // Put one line in the cart so the Tax row can show.
      await tester.ensureVisible(find.text('Add').first);
      await tester.tap(find.text('Add').first);
      await tester.pumpAndSettle();
      expect(find.text('Cart (1)'), findsOneWidget);
      // Change the rate in Settings while the sale is open.
      expect(
        container.read(orgSettingsProvider.notifier).setTaxRate(10),
        isTrue,
      );
      await tester.pumpAndSettle();
      expect(tester.widget<DropdownButton<int>>(dropdown).value, 10);
      expect(find.text('Tax (10%)'), findsOneWidget);
      // A rate outside the usual dropdown set still renders
      // (dynamic item) instead of crashing the dropdown.
      expect(
        container.read(orgSettingsProvider.notifier).setTaxRate(7),
        isTrue,
      );
      await tester.pumpAndSettle();
      expect(tester.widget<DropdownButton<int>>(dropdown).value, 7);
      expect(find.text('Tax (7%)'), findsOneWidget);
    });

    testWidgets('a cashier-picked rate wins over later Settings changes',
        (tester) async {
      final (container, router) = await _pumpRouterAppAsRole(
        tester,
        'cashier',
      );
      router.go('/billing');
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Add').first);
      await tester.tap(find.text('Add').first);
      await tester.pumpAndSettle();
      final dropdown = find.byKey(const ValueKey('pos-tax-dropdown'));
      await tester.ensureVisible(dropdown);
      await tester.pumpAndSettle();
      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text('5%').last);
      await tester.pumpAndSettle();
      expect(tester.widget<DropdownButton<int>>(dropdown).value, 5);
      expect(find.text('Tax (5%)'), findsOneWidget);
      // Settings now says 16% — the explicit per-sale pick stands.
      expect(
        container.read(orgSettingsProvider.notifier).setTaxRate(16),
        isTrue,
      );
      await tester.pumpAndSettle();
      expect(tester.widget<DropdownButton<int>>(dropdown).value, 5);
      expect(find.text('Tax (5%)'), findsOneWidget);
      expect(find.text('Tax (16%)'), findsNothing);
    });
  });

  group('Branch code — validation (D168)', () {
    test('isValidBranchCode: 2–8 uppercase letters/digits', () {
      expect(isValidBranchCode('DHA'), isTrue);
      expect(isValidBranchCode('AB12'), isTrue);
      expect(isValidBranchCode('AB12CD34'), isTrue);
      expect(isValidBranchCode('dha'), isFalse);
      expect(isValidBranchCode('A'), isFalse);
      expect(isValidBranchCode('ABCDEFGHI'), isFalse);
      expect(isValidBranchCode('D-H'), isFalse);
      expect(isValidBranchCode(''), isFalse);
      expect(isValidBranchCode('DHA '), isFalse);
    });

    test('validateBranchForm: blank ok, valid ok, invalid rejected',
        () {
      expect(validateBranchForm(name: 'Model Town'), isEmpty);
      expect(validateBranchForm(name: 'Model Town', code: ''), isEmpty);
      expect(
        validateBranchForm(name: 'Model Town', code: 'dha'),
        isEmpty,
      );
      expect(
        validateBranchForm(name: 'Model Town', code: '  AB12  '),
        isEmpty,
      );
      expect(
        validateBranchForm(name: 'Model Town', code: 'A'),
        anyElement(
          contains('Branch code must be 2–8 uppercase letters or digits'),
        ),
      );
      expect(
        validateBranchForm(name: 'Model Town', code: 'ABCDEFGHI'),
        isNotEmpty,
      );
      expect(
        validateBranchForm(name: 'Model Town', code: 'D-H'),
        isNotEmpty,
      );
      expect(
        validateBranchForm(name: 'Model Town', code: 'D H A'),
        isNotEmpty,
      );
    });
  });

  group('Branch code field — add/edit form (D168)', () {
    Finder nameField() => find.ancestor(
          of: find.text('Branch name'),
          matching: find.byType(TextFormField),
        );

    testWidgets('blank code saves with the derived default (“”)', (
      tester,
    ) async {
      Branch? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDialog<Branch>(
                  context: context,
                  builder: (_) => BranchFormDialog(
                    onSaved: (branch) => saved = branch,
                  ),
                ),
                child: const Text('Open form'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open form'));
      await tester.pumpAndSettle();
      await tester.enterText(nameField(), 'Model Town');
      await tester.tap(find.text('Add branch').last);
      await tester.pumpAndSettle();
      expect(saved, isNotNull);
      expect(saved!.id, 'branch-model-town');
      // Blank stays '' on the form-built branch — the repository
      // derives the default from the id (D164).
      expect(saved!.code, '');
      expect(saved!.effectiveCode, 'TOW');
    });

    testWidgets('a typed code is normalized to uppercase', (tester) async {
      Branch? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDialog<Branch>(
                  context: context,
                  builder: (_) => BranchFormDialog(
                    onSaved: (branch) => saved = branch,
                  ),
                ),
                child: const Text('Open form'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open form'));
      await tester.pumpAndSettle();
      await tester.enterText(nameField(), 'Lahore Branch');
      await tester.enterText(
        find.byKey(const ValueKey('branch-code-field')),
        'lhr',
      );
      await tester.tap(find.text('Add branch').last);
      await tester.pumpAndSettle();
      expect(saved, isNotNull);
      expect(saved!.code, 'LHR');
      expect(saved!.effectiveCode, 'LHR');
    });

    testWidgets('an invalid code shows the error and never saves',
        (tester) async {
      var savedCount = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDialog<Branch>(
                  context: context,
                  builder: (_) => BranchFormDialog(
                    onSaved: (_) => savedCount++,
                  ),
                ),
                child: const Text('Open form'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open form'));
      await tester.pumpAndSettle();
      await tester.enterText(nameField(), 'Model Town');
      await tester.enterText(
        find.byKey(const ValueKey('branch-code-field')),
        '!',
      );
      await tester.tap(find.text('Add branch').last);
      await tester.pumpAndSettle();
      expect(savedCount, 0);
      expect(
        find.textContaining(
          'Branch code must be 2–8 uppercase letters or digits',
        ),
        findsOneWidget,
      );
      // The dialog stayed open for a correction (title + button).
      expect(find.text('Add branch'), findsNWidgets(2));
    });

    testWidgets('editing prefills the stored code and keeps it', (
      tester,
    ) async {
      Branch? saved;
      const existing = Branch(
        id: 'branch-isb',
        name: 'Islamabad Branch',
        address: 'Islamabad',
        phone: '0300-6',
        code: 'ISB',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDialog<Branch>(
                  context: context,
                  builder: (_) => BranchFormDialog(
                    existing: existing,
                    onSaved: (branch) => saved = branch,
                  ),
                ),
                child: const Text('Open form'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open form'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<PharmaTextField>(
              find.byKey(const ValueKey('branch-code-field')),
            )
            .controller!
            .text,
        'ISB',
      );
      await tester.tap(find.text('Save changes'));
      await tester.pumpAndSettle();
      expect(saved, isNotNull);
      expect(saved!.code, 'ISB');
    });
  });
}

AppUser _userFor(String roleKey) {
  return AppUser(
    uid: 'test-$roleKey',
    email: '$roleKey@test.pharmadesk',
    displayName: 'Test $roleKey',
    orgId: _org,
    branchIds: const [_dha, _glb],
    roleKey: roleKey,
  );
}

class _FixedAuthNotifier extends AuthNotifier {
  _FixedAuthNotifier(this.user);

  final AppUser user;

  @override
  AppUser? build() => user;
}

Future<(ProviderContainer, GoRouter)> _pumpRouterAppAsRole(
  WidgetTester tester,
  String roleKey,
) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1920, 1080);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final container = ProviderContainer(
    overrides: [
      authProvider.overrideWith(() => _FixedAuthNotifier(_userFor(roleKey))),
    ],
  );
  addTearDown(container.dispose);
  final router = createAppRouter(
    isSignedIn: () => container.read(authProvider) != null,
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: AppTheme.light(BrandConfig.defaults),
        darkTheme: AppTheme.dark(BrandConfig.defaults),
        themeMode: ThemeMode.light,
        routerConfig: router,
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 1500));
  await tester.pumpAndSettle();
  return (container, router);
}

/// Minimal in-memory Firestore transport (same shape as the Week 6
/// Day 3 one): only the document operations the medicine repo uses.
class _MemoryTransport implements FirestoreTransport {
  final Map<String, Map<String, dynamic>> _docs = {};
  var _sequence = 0;

  @override
  Future<Map<String, dynamic>?> getDocument(String path) async =>
      _docs[path] == null
          ? null
          : Map<String, dynamic>.from(_docs[path]!);

  @override
  Future<List<FirestoreDocument>> queryCollection(
    String collectionPath, {
    Map<String, Object?> whereEquals = const {},
    String? orderBy,
    bool descending = false,
    int? limit,
    String? startAfterId,
  }) async {
    final prefix = '$collectionPath/';
    final docs = [
      for (final entry in _docs.entries)
        if (entry.key.startsWith(prefix) &&
            !entry.key.substring(prefix.length).contains('/'))
          FirestoreDocument(
            id: entry.key.substring(prefix.length),
            data: Map<String, dynamic>.from(entry.value),
          ),
    ];
    for (final filter in whereEquals.entries) {
      docs.retainWhere((doc) => doc.data[filter.key] == filter.value);
    }
    if (orderBy != null) {
      docs.sort(
        (a, b) => (a.data[orderBy]?.toString() ?? '').compareTo(
          b.data[orderBy]?.toString() ?? '',
        ),
      );
    } else {
      docs.sort((a, b) => a.id.compareTo(b.id));
    }
    if (descending) return docs.reversed.toList();
    var page = docs;
    if (startAfterId != null) {
      final index = page.indexWhere((doc) => doc.id == startAfterId);
      if (index != -1) page = page.sublist(index + 1);
    }
    if (limit != null && page.length > limit) {
      page = page.sublist(0, limit);
    }
    return page;
  }

  @override
  Future<void> setDocument(
    String path,
    Map<String, dynamic> data, {
    bool merge = false,
  }) async {
    _docs[path] = Map<String, dynamic>.from(data);
  }

  @override
  String newDocumentId(String collectionPath) {
    _sequence++;
    return 'auto-$_sequence';
  }

  @override
  Future<void> updateDocument(String path, Map<String, dynamic> data) =>
      throw UnimplementedError();

  @override
  Future<String> addDocument(
    String collectionPath,
    Map<String, dynamic> data,
  ) =>
      throw UnimplementedError();

  @override
  Future<void> runBatchedWrites(List<WriteOperation> operations) =>
      throw UnimplementedError();

  @override
  Future<T> runTransaction<T>(
    Future<T> Function(FirestoreTransaction tx) update,
  ) =>
      throw UnimplementedError();
}
