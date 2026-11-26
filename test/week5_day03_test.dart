// Week 5 Day 3 tests — feature completion, part 1 (D151, D152, D153).
//
// - D151: medicine master edit validation — the rules the schema +
//   seed data imply (no creation flow exists to copy from), rupee
//   text -> int paisa at the boundary, per-field errors.
// - D152: per-branch rack/shelf override — model + effective-location
//   rule, mock + Firestore repos (fake transport), mapper round-trip,
//   set -> override wins, clear -> master default, other branch
//   unaffected.
// - D153: full master edit form — Owner edits every field end to end
//   at 390px, invalid input blocks the save, read-only roles see no
//   edit UI; the branch-shelf dialog drives the detail + inventory
//   screens.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:pharmadesk/core/data/auth_repository.dart';
import 'package:pharmadesk/core/data/firestore_mappers.dart';
import 'package:pharmadesk/core/data/firestore_repositories.dart';
import 'package:pharmadesk/core/data/firestore_schema.dart';
import 'package:pharmadesk/core/data/firestore_transport.dart';
import 'package:pharmadesk/core/data/inventory_engine.dart'
    show WriteOperation, WriteOperationKind;
import 'package:pharmadesk/core/routing/app_router.dart';
import 'package:pharmadesk/core/services/repositories.dart';
import 'package:pharmadesk/core/theme/app_theme.dart';
import 'package:pharmadesk/core/theme/white_label.dart';
import 'package:pharmadesk/features/authentication/auth_state.dart';
import 'package:pharmadesk/features/inventory/inventory_logic.dart';
import 'package:pharmadesk/features/inventory/inventory_provider.dart';
import 'package:pharmadesk/features/medicines/medicine_validation.dart';
import 'package:pharmadesk/models/branch_inventory_location.dart';
import 'package:pharmadesk/models/medicine.dart';

const _dha = 'branch-dha-main';
const _glb = 'branch-demo-gulberg';
const _org = demoOrganizationId;
const _panadol = 'med-panadol-extra';
const _phoneSize = Size(390, 844);

AppUser _userFor(
  String roleKey, {
  List<String> branchIds = const [_dha],
  String? uid,
}) {
  return AppUser(
    uid: uid ?? 'test-$roleKey',
    email: '$roleKey@test.pharmadesk',
    displayName: 'Test $roleKey',
    orgId: _org,
    branchIds: branchIds,
    roleKey: roleKey,
  );
}

class _FixedAuthNotifier extends AuthNotifier {
  _FixedAuthNotifier(this.user);

  final AppUser user;

  @override
  AppUser? build() => user;
}

Future<(ProviderContainer, GoRouter)> pumpRouterAppAsRole(
  WidgetTester tester,
  String roleKey, {
  List<String> branchIds = const [_dha],
  Size size = const Size(1920, 1080),
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final user = _userFor(roleKey, branchIds: branchIds);
  final container = ProviderContainer(
    overrides: [authProvider.overrideWith(() => _FixedAuthNotifier(user))],
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

/// Drains exceptions the binding recorded during pumping (e.g.
/// RenderFlex overflows) and returns their full texts.
List<String> drainExceptions(WidgetTester tester) {
  final messages = <String>[];
  Object? error;
  while ((error = tester.takeException()) != null) {
    messages.add(error.toString());
  }
  return messages;
}

int countOverflows(List<String> drained) {
  var count = 0;
  for (final message in drained) {
    var from = 0;
    while (true) {
      final at = message.indexOf('RenderFlex overflowed', from);
      if (at == -1) break;
      count++;
      from = at + 1;
    }
  }
  return count;
}

/// In-memory fake transport (same shape as the Week 3 Day 1 fake):
/// the Firestore repositories run against this, never a real backend.
class FakeFirestoreTransport implements FirestoreTransport {
  final Map<String, Map<String, dynamic>> docs = {};

  int _autoId = 0;

  @override
  Future<Map<String, dynamic>?> getDocument(String path) async {
    final data = docs[path];
    return data == null ? null : Map<String, dynamic>.from(data);
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
    var entries = docs.entries.where((entry) {
      if (!entry.key.startsWith('$collectionPath/')) return false;
      return !entry.key.substring(collectionPath.length + 1).contains('/');
    }).toList();
    for (final filter in whereEquals.entries) {
      entries = entries
          .where((entry) => entry.value[filter.key] == filter.value)
          .toList();
    }
    int compare(FirestoreDocument a, FirestoreDocument b) {
      if (orderBy == null) return a.id.compareTo(b.id);
      final aValue = a.data[orderBy];
      final bValue = b.data[orderBy];
      if (aValue is Comparable && bValue is Comparable) {
        try {
          return aValue.compareTo(bValue);
        } on Object {
          // Mixed types: fall through to string comparison.
        }
      }
      return aValue.toString().compareTo(bValue.toString());
    }

    var page = [
      for (final entry in entries)
        FirestoreDocument(
          id: entry.key.split('/').last,
          data: Map<String, dynamic>.from(entry.value),
        ),
    ]..sort(compare);
    if (descending) page = page.reversed.toList();
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
    if (merge && docs.containsKey(path)) {
      docs[path] = {...docs[path]!, ...data};
    } else {
      docs[path] = Map<String, dynamic>.from(data);
    }
  }

  @override
  Future<void> updateDocument(String path, Map<String, dynamic> data) async {
    final existing = docs[path];
    if (existing == null) {
      throw StateError('No document at $path to update.');
    }
    docs[path] = {...existing, ...data};
  }

  @override
  Future<String> addDocument(
    String collectionPath,
    Map<String, dynamic> data,
  ) async {
    final id = newDocumentId(collectionPath);
    docs['$collectionPath/$id'] = Map<String, dynamic>.from(data);
    return id;
  }

  @override
  Future<void> runBatchedWrites(List<WriteOperation> operations) async {
    for (final operation in operations) {
      switch (operation.kind) {
        case WriteOperationKind.set:
          docs[operation.path] = Map<String, dynamic>.from(
            operation.data ?? const {},
          );
        case WriteOperationKind.update:
          final existing = docs[operation.path];
          if (existing == null) {
            throw StateError('No document at ${operation.path} to update.');
          }
          docs[operation.path] = {...existing, ...?operation.data};
        case WriteOperationKind.delete:
          docs.remove(operation.path);
      }
    }
  }

  @override
  Future<T> runTransaction<T>(
    Future<T> Function(FirestoreTransaction tx) action,
  ) async {
    return action(_FakeTransaction(docs));
  }

  @override
  String newDocumentId(String collectionPath) {
    _autoId += 1;
    return 'auto-$_autoId';
  }
}

class _FakeTransaction implements FirestoreTransaction {
  _FakeTransaction(this.docs);

  final Map<String, Map<String, dynamic>> docs;

  @override
  Future<Map<String, dynamic>?> get(String path) async {
    final data = docs[path];
    return data == null ? null : Map<String, dynamic>.from(data);
  }

  @override
  void set(String path, Map<String, dynamic> data, {bool merge = false}) {
    if (merge && docs.containsKey(path)) {
      docs[path] = {...docs[path]!, ...data};
    } else {
      docs[path] = Map<String, dynamic>.from(data);
    }
  }

  @override
  void update(String path, Map<String, dynamic> data) {
    final existing = docs[path];
    if (existing == null) {
      throw StateError('No document at $path to update.');
    }
    docs[path] = {...existing, ...data};
  }
}

Future<void> _seedBranches(FakeFirestoreTransport transport) async {
  await transport.setDocument('branches/$_dha', {
    'organizationId': _org,
    'name': 'Demo Branch — DHA',
  });
  await transport.setDocument('branches/$_glb', {
    'organizationId': _org,
    'name': 'Demo Branch — Gulberg',
  });
}

Map<String, String> _validEdit({
  String name = 'Panadol Extra',
  String salePrice = '120',
  String purchasePrice = '90',
  String mrp = '130',
  String barcode = '8901000000001',
  String categoryId = 'cat-analgesic',
}) {
  return validateMedicineEdit(
    name: name,
    salePrice: salePrice,
    purchasePrice: purchasePrice,
    mrp: mrp,
    barcode: barcode,
    categoryId: categoryId,
  );
}

void main() {
  group('D151 — medicine edit validation', () {
    test('parseRupeesToMinor converts at the boundary, rejects junk', () {
      expect(parseRupeesToMinor('120'), 12000);
      expect(parseRupeesToMinor('120.50'), 12050);
      expect(parseRupeesToMinor('120.5'), 12050);
      expect(parseRupeesToMinor('0.99'), 99);
      expect(parseRupeesToMinor(' 120 '), 12000);
      expect(parseRupeesToMinor(''), isNull);
      expect(parseRupeesToMinor('abc'), isNull);
      expect(parseRupeesToMinor('-5'), isNull);
      expect(parseRupeesToMinor('12.345'), isNull);
      expect(parseRupeesToMinor('12.'), isNull);
      expect(parseRupeesToMinor('1,200'), isNull);
    });

    test('formatMinorUnitsAsRupees round-trips the parse', () {
      expect(formatMinorUnitsAsRupees(12000), '120');
      expect(formatMinorUnitsAsRupees(12050), '120.50');
      expect(formatMinorUnitsAsRupees(99), '0.99');
      expect(
        parseRupeesToMinor(formatMinorUnitsAsRupees(185050)),
        185050,
      );
    });

    test('a valid edit passes with no errors', () {
      expect(_validEdit(), isEmpty);
    });

    test('empty name fails', () {
      expect(_validEdit(name: '  ')['name'], isNotNull);
    });

    test('sale price must be present, numeric and above zero', () {
      expect(_validEdit(salePrice: '')['salePrice'], isNotNull);
      expect(_validEdit(salePrice: 'abc')['salePrice'], isNotNull);
      expect(_validEdit(salePrice: '0')['salePrice'], isNotNull);
      expect(_validEdit(salePrice: '-10')['salePrice'], isNotNull);
      expect(_validEdit(salePrice: '12.345')['salePrice'], isNotNull);
      expect(_validEdit(salePrice: '120.50'), isEmpty);
    });

    test('purchase price must be present and numeric; zero is allowed', () {
      expect(_validEdit(purchasePrice: '')['purchasePrice'], isNotNull);
      expect(_validEdit(purchasePrice: 'abc')['purchasePrice'], isNotNull);
      expect(_validEdit(purchasePrice: '-1')['purchasePrice'], isNotNull);
      expect(_validEdit(purchasePrice: '0'), isEmpty);
    });

    test('MRP is optional but never below the sale price', () {
      expect(_validEdit(mrp: ''), isEmpty);
      expect(_validEdit(mrp: 'abc')['mrp'], isNotNull);
      expect(_validEdit(mrp: '100')['mrp'], isNotNull);
      expect(_validEdit(mrp: '120'), isEmpty);
      expect(_validEdit(mrp: '130'), isEmpty);
    });

    test('barcode is optional; when set it is 8–14 digits', () {
      expect(_validEdit(barcode: ''), isEmpty);
      expect(_validEdit(barcode: '8901000000001'), isEmpty);
      expect(_validEdit(barcode: '12345678'), isEmpty);
      expect(_validEdit(barcode: 'ABC123')['barcode'], isNotNull);
      expect(_validEdit(barcode: '1234567')['barcode'], isNotNull);
      expect(_validEdit(barcode: '123456789012345')['barcode'], isNotNull);
    });

    test('category must be a known catalogue category', () {
      expect(_validEdit(categoryId: 'cat-antibiotic'), isEmpty);
      expect(_validEdit(categoryId: 'cat-nope')['categoryId'], isNotNull);
      expect(_validEdit(categoryId: '')['categoryId'], isNotNull);
    });
  });

  group('D152 — branch rack/shelf override: model + rule', () {
    const dhaOverride = BranchInventoryLocation(
      branchId: _dha,
      medicineId: _panadol,
      rack: 'Rack B',
      shelf: 'Shelf 1',
    );

    test('displayLabel joins rack and shelf; empty override has none', () {
      expect(dhaOverride.displayLabel, 'Rack B • Shelf 1');
      expect(
        const BranchInventoryLocation(
          branchId: _dha,
          medicineId: _panadol,
          rack: 'Rack B',
        ).displayLabel,
        'Rack B',
      );
      expect(
        const BranchInventoryLocation(
          branchId: _dha,
          medicineId: _panadol,
        ).displayLabel,
        isNull,
      );
      expect(
        const BranchInventoryLocation(
          branchId: _dha,
          medicineId: _panadol,
        ).isEmpty,
        isTrue,
      );
      expect(dhaOverride.isEmpty, isFalse);
    });

    test('effectiveLocation prefers the override, falls back to master', () {
      expect(
        effectiveLocation(masterLocation: 'Rack A • Shelf 2', override: dhaOverride),
        'Rack B • Shelf 1',
      );
      expect(
        effectiveLocation(masterLocation: 'Rack A • Shelf 2'),
        'Rack A • Shelf 2',
      );
      expect(effectiveLocation(masterLocation: null), isNull);
      expect(effectiveLocation(masterLocation: '  '), isNull);
      // An empty override is no override — the master still wins.
      expect(
        effectiveLocation(
          masterLocation: 'Rack A • Shelf 2',
          override: const BranchInventoryLocation(
            branchId: _dha,
            medicineId: _panadol,
          ),
        ),
        'Rack A • Shelf 2',
      );
    });

    test('branchLocationFor matches branch + medicine only', () {
      final locations = [
        dhaOverride,
        const BranchInventoryLocation(
          branchId: _glb,
          medicineId: _panadol,
          rack: 'Rack G',
          shelf: 'Shelf 9',
        ),
        const BranchInventoryLocation(branchId: _dha, medicineId: 'med-other'),
      ];
      expect(
        branchLocationFor(locations, branchId: _dha, medicineId: _panadol),
        dhaOverride,
      );
      expect(
        branchLocationFor(
          locations,
          branchId: _glb,
          medicineId: _panadol,
        )!.rack,
        'Rack G',
      );
      expect(
        branchLocationFor(locations, branchId: _dha, medicineId: 'med-other'),
        isNull,
      );
      expect(
        branchLocationFor(locations, branchId: _dha, medicineId: 'med-nope'),
        isNull,
      );
    });

    test('mapper round-trips rack/shelf; clear writes nulls', () {
      final doc = branchInventoryLocationToFirestore(
        dhaOverride,
        orgId: _org,
      );
      expect(doc['rack'], 'Rack B');
      expect(doc['shelf'], 'Shelf 1');
      expect(doc['medicineId'], _panadol);
      final restored = branchInventoryLocationFromFirestore(
        _dha,
        _panadol,
        doc,
      );
      expect(restored, dhaOverride);
      final cleared = branchInventoryLocationToFirestore(
        const BranchInventoryLocation(branchId: _dha, medicineId: _panadol),
        orgId: _org,
      );
      expect(cleared['rack'], isNull);
      expect(cleared['shelf'], isNull);
    });
  });

  group('D152 — branch rack/shelf override: mock repository', () {
    test('set -> read back; other branch unaffected; clear -> fallback', () async {
      final repo = MockInventoryRepository();
      expect(
        await repo.getBranchLocation(branchId: _dha, medicineId: _panadol),
        isNull,
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
      expect(
        (await repo.getBranchLocation(
          branchId: _dha,
          medicineId: _panadol,
        ))!.displayLabel,
        'Rack B • Shelf 1',
      );
      // Per-branch: Gulberg still has no override.
      expect(
        await repo.getBranchLocation(branchId: _glb, medicineId: _panadol),
        isNull,
      );
      expect(await repo.getBranchLocations(branchId: _glb), isEmpty);
      expect(await repo.getBranchLocations(branchId: _dha), hasLength(1));
      // Clear: both fields empty removes the override.
      final cleared = await repo.saveBranchLocation(
        const BranchInventoryLocation(branchId: _dha, medicineId: _panadol),
      );
      expect(cleared.isEmpty, isTrue);
      expect(
        await repo.getBranchLocation(branchId: _dha, medicineId: _panadol),
        isNull,
      );
      expect(await repo.getBranchLocations(branchId: _dha), isEmpty);
    });

    test('getBranchLocations without a branch lists every override', () async {
      final repo = MockInventoryRepository();
      await repo.saveBranchLocation(
        const BranchInventoryLocation(
          branchId: _dha,
          medicineId: _panadol,
          rack: 'Rack B',
        ),
      );
      await repo.saveBranchLocation(
        const BranchInventoryLocation(
          branchId: _glb,
          medicineId: _panadol,
          rack: 'Rack G',
        ),
      );
      expect(await repo.getBranchLocations(), hasLength(2));
    });
  });

  group('D152 — branch rack/shelf override: Firestore repository', () {
    test('save/get/clear round-trips; merge-set keeps the counters', () async {
      final transport = FakeFirestoreTransport();
      await _seedBranches(transport);
      final repo = FirestoreInventoryRepository(
        transport: transport,
        organizationId: _org,
      );
      // The inventory doc already carries counters — a location
      // write must not drop them.
      await transport.setDocument(
        'branches/$_dha/inventory/$_panadol',
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
        'branches/$_dha/inventory/$_panadol',
      );
      expect(raw!['quantityOnHand'], 5);
      expect(raw['rack'], 'Rack B');
      expect(
        (await repo.getBranchLocation(
          branchId: _dha,
          medicineId: _panadol,
        ))!.displayLabel,
        'Rack B • Shelf 1',
      );
      expect(await repo.getBranchLocations(branchId: _dha), hasLength(1));
      expect(await repo.getBranchLocations(), hasLength(1));
      expect(await repo.getBranchLocations(branchId: _glb), isEmpty);
      await repo.saveBranchLocation(
        const BranchInventoryLocation(branchId: _dha, medicineId: _panadol),
      );
      expect(
        await repo.getBranchLocation(branchId: _dha, medicineId: _panadol),
        isNull,
      );
      final afterClear = await transport.getDocument(
        'branches/$_dha/inventory/$_panadol',
      );
      expect(afterClear!['quantityOnHand'], 5);
    });
  });

  group('D153 — full master edit through updateMedicine', () {
    test('save round-trips every form field; restore keeps the suite green',
        () async {
      final repo = MockMedicineRepository();
      final original = (await repo.getById(_panadol))!;
      final saved = await repo.updateMedicine(
        original.copyWith(
          name: 'Panadol Extra Plus',
          price: 150,
          purchasePriceMinor: 9000,
          mrp: 165,
          barcode: '8901000000099',
          categoryId: 'cat-antibiotic',
          location: 'Rack A • Shelf 2',
          updatedAt: DateTime.now(),
        ),
      );
      expect(saved.name, 'Panadol Extra Plus');
      expect(saved.priceMinor, 15000);
      expect(saved.purchasePriceMinor, 9000);
      expect(saved.mrp, 165);
      expect(saved.barcode, '8901000000099');
      expect(saved.categoryId, 'cat-antibiotic');
      expect(saved.location, 'Rack A • Shelf 2');
      // Untouched fields survive the whole-record replace.
      expect(saved.brand, original.brand);
      expect(saved.strength, original.strength);
      expect(saved.packSize, original.packSize);
      expect(saved.requiresPrescription, original.requiresPrescription);
      final readBack = (await repo.getById(_panadol))!;
      expect(readBack.name, 'Panadol Extra Plus');
      // Restore the seed state for later tests.
      await repo.updateMedicine(original);
      expect((await repo.getById(_panadol))!.name, original.name);
    });

    test('Medicine copyWith can clear the barcode', () {
      const medicine = Medicine(
        id: 'med-test',
        name: 'Test',
        brand: 'Brand',
        categoryId: 'cat-analgesic',
        strength: '500mg',
        packSize: '20 tablets',
        price: 120,
        barcode: '8901000000001',
      );
      expect(medicine.copyWith(clearBarcode: true).barcode, isNull);
      expect(
        medicine.copyWith(barcode: '12345678').barcode,
        '12345678',
      );
    });
  });

  group('D153 — full master edit form (widget)', () {
    testWidgets('Owner edits every field end to end at 390px',
        (tester) async {
      final (container, router) = await pumpRouterAppAsRole(
        tester,
        'Owner',
        size: _phoneSize,
      );
      final repo = container.read(medicineRepositoryProvider);
      final original = (await repo.getById(_panadol))!;
      router.go('/medicines/$_panadol');
      await tester.pump(const Duration(milliseconds: 1500));
      await tester.pumpAndSettle();
      expect(find.text('Panadol Extra 500mg'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('medicine-edit')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('medicine-name-field')),
        findsOneWidget,
      );

      Future<void> setField(String key, String value) async {
        final finder = find.byKey(ValueKey(key));
        await tester.ensureVisible(finder);
        await tester.pumpAndSettle();
        await tester.enterText(finder, value);
      }

      await setField('medicine-name-field', 'Panadol Extra Plus');
      await setField('medicine-sale-price-field', '150');
      await setField('medicine-purchase-price-field', '90.50');
      await setField('medicine-mrp-field', '165');
      await setField('medicine-barcode-field', '8901000000099');
      await setField('medicine-location-field', 'Rack A • Shelf 2');
      // Category: pick Antibiotic from the dropdown.
      await tester.ensureVisible(
        find.byKey(const ValueKey('medicine-category-field')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('medicine-category-field')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Antibiotic'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('medicine-edit-save')));
      await tester.pumpAndSettle();
      expect(find.text('Panadol Extra Plus 500mg'), findsOneWidget);
      expect(find.text('Rs 150.00'), findsOneWidget);
      expect(find.text('Rs 165.00'), findsOneWidget);
      expect(find.text('8901000000099'), findsOneWidget);
      expect(find.text('Antibiotic'), findsWidgets);
      expect(find.text('Rack A • Shelf 2'), findsOneWidget);
      expect(countOverflows(drainExceptions(tester)), 0);
      // Restore the seed state for later tests.
      await repo.updateMedicine(original);
      container.invalidate(medicinesProvider);
    });

    testWidgets('edit dialog fits at 390px with no overflow',
        (tester) async {
      final (_, router) = await pumpRouterAppAsRole(
        tester,
        'Owner',
        size: _phoneSize,
      );
      router.go('/medicines/$_panadol');
      await tester.pump(const Duration(milliseconds: 1500));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('medicine-edit')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('medicine-name-field')),
        findsOneWidget,
      );
      expect(countOverflows(drainExceptions(tester)), 0);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    });

    testWidgets('invalid sale price blocks the save and keeps the old price',
        (tester) async {
      final (container, router) = await pumpRouterAppAsRole(
        tester,
        'Owner',
        size: _phoneSize,
      );
      router.go('/medicines/$_panadol');
      await tester.pump(const Duration(milliseconds: 1500));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('medicine-edit')));
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('medicine-sale-price-field'));
      await tester.ensureVisible(field);
      await tester.pumpAndSettle();
      await tester.enterText(field, 'abc');
      await tester.tap(find.byKey(const ValueKey('medicine-edit-save')));
      await tester.pumpAndSettle();
      expect(
        find.text('Enter the sale price in rupees, e.g. 120 or 120.50.'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('medicine-name-field')),
        findsOneWidget,
      );
      final unchanged = (await container
          .read(medicineRepositoryProvider)
          .getById(_panadol))!;
      expect(unchanged.priceMinor, 12000);
    });

    testWidgets('MRP below sale and a bad barcode both report errors',
        (tester) async {
      final (_, router) = await pumpRouterAppAsRole(
        tester,
        'Owner',
        size: _phoneSize,
      );
      router.go('/medicines/$_panadol');
      await tester.pump(const Duration(milliseconds: 1500));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('medicine-edit')));
      await tester.pumpAndSettle();
      final mrpField = find.byKey(const ValueKey('medicine-mrp-field'));
      await tester.ensureVisible(mrpField);
      await tester.pumpAndSettle();
      await tester.enterText(mrpField, '100');
      await tester.tap(find.byKey(const ValueKey('medicine-edit-save')));
      await tester.pumpAndSettle();
      expect(
        find.text('MRP cannot be below the sale price.'),
        findsOneWidget,
      );
      final barcodeField = find.byKey(
        const ValueKey('medicine-barcode-field'),
      );
      await tester.ensureVisible(barcodeField);
      await tester.pumpAndSettle();
      await tester.enterText(barcodeField, 'ABC');
      await tester.enterText(mrpField, '130');
      await tester.tap(find.byKey(const ValueKey('medicine-edit-save')));
      await tester.pumpAndSettle();
      expect(
        find.text('Barcode must contain digits only.'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('medicine-name-field')),
        findsOneWidget,
      );
    });

    testWidgets('read-only role (Auditor) sees no edit UI', (tester) async {
      // Auditor is the read-only role for medicineCrud (Cashier is
      // `none` — the route itself is gated, so it proves nothing
      // about the edit buttons). The detail screen renders, but
      // neither edit button does.
      final (_, router) = await pumpRouterAppAsRole(
        tester,
        'auditor',
        size: _phoneSize,
      );
      router.go('/medicines/$_panadol');
      await tester.pump(const Duration(milliseconds: 1500));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('medicine-edit')), findsNothing);
      expect(
        find.byKey(const ValueKey('medicine-branch-shelf')),
        findsNothing,
      );
      // Read-only still works: the medicine and its location show.
      expect(find.text('Panadol Extra 500mg'), findsOneWidget);
      expect(find.text('Not set'), findsOneWidget);
    });
  });

  group('D152 — branch shelf dialog (widget)', () {
    testWidgets('set override -> detail + inventory show it; clear -> master',
        (tester) async {
      final (container, router) = await pumpRouterAppAsRole(
        tester,
        'Owner',
        size: _phoneSize,
      );
      final medicineRepo = container.read(medicineRepositoryProvider);
      final original = (await medicineRepo.getById(_panadol))!;
      // Give the medicine a master location first, so the fallback
      // after clearing is visible.
      await medicineRepo.updateMedicine(
        original.copyWith(location: 'Rack A • Shelf 2'),
      );
      container.invalidate(medicinesProvider);
      router.go('/medicines/$_panadol');
      await tester.pump(const Duration(milliseconds: 1500));
      await tester.pumpAndSettle();
      expect(find.text('Rack A • Shelf 2'), findsOneWidget);

      // Set the override for this branch.
      await tester.ensureVisible(
        find.byKey(const ValueKey('medicine-branch-shelf')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('medicine-branch-shelf')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('branch-rack-field')),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const ValueKey('branch-rack-field')),
        'Rack B',
      );
      await tester.enterText(
        find.byKey(const ValueKey('branch-shelf-field')),
        'Shelf 1',
      );
      await tester.tap(find.byKey(const ValueKey('branch-shelf-save')));
      await tester.pumpAndSettle();
      expect(find.text('Rack B • Shelf 1 (this branch)'), findsOneWidget);

      // The inventory screen prefers the override too.
      router.go('/inventory');
      await tester.pump(const Duration(milliseconds: 1500));
      await tester.pumpAndSettle();
      expect(find.text('Location: Rack B • Shelf 1'), findsWidgets);

      // Clear the override: back on the detail screen, both fields
      // empty, save — the master location returns.
      router.go('/medicines/$_panadol');
      await tester.pump(const Duration(milliseconds: 1500));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('medicine-branch-shelf')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('medicine-branch-shelf')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('branch-rack-field')),
        '',
      );
      await tester.enterText(
        find.byKey(const ValueKey('branch-shelf-field')),
        '',
      );
      await tester.tap(find.byKey(const ValueKey('branch-shelf-save')));
      await tester.pumpAndSettle();
      expect(find.text('Rack A • Shelf 2'), findsOneWidget);
      expect(find.textContaining('(this branch)'), findsNothing);
      router.go('/inventory');
      await tester.pump(const Duration(milliseconds: 1500));
      await tester.pumpAndSettle();
      expect(find.text('Location: Rack A • Shelf 2'), findsWidgets);
      expect(countOverflows(drainExceptions(tester)), 0);

      // Restore the seed state for later tests.
      await medicineRepo.updateMedicine(original);
      container.invalidate(medicinesProvider);
    });
  });
}
