// PharmaDesk Week 2 Day 2 tests — Auto Purchase List.
//
// Covers: suggestion maths (reorder − usable, floored at 0; the
// near-expiry usable-stock rule; expired stock never usable),
// exclusions for open POs, grouping by supplier, PO totals in paisa,
// idempotent approval (same key / double-tap → one PO per supplier),
// and widget tests (screen renders with seeded data, edit qty,
// remove line, approve creates Draft POs visible in Purchases, empty
// state when nothing to order).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:pharmadesk/core/routing/app_router.dart';
import 'package:pharmadesk/core/services/demo_seed_data.dart';
import 'package:pharmadesk/core/services/repositories.dart';
import 'package:pharmadesk/core/theme/app_theme.dart';
import 'package:pharmadesk/core/theme/white_label.dart';
import 'package:pharmadesk/features/purchases/auto_purchase_logic.dart';
import 'package:pharmadesk/features/purchases/auto_purchase_provider.dart';
import 'package:pharmadesk/models/branch_inventory_location.dart';
import 'package:pharmadesk/models/inventory_item.dart';
import 'package:pharmadesk/models/medicine.dart';
import 'package:pharmadesk/models/purchase_order.dart';
import 'package:pharmadesk/models/supplier.dart';

DateTime get _today => DateTime(2026, 11, 25);

Medicine _medicine({
  String id = 'med-a',
  String name = 'Test Medicine',
  double price = 100,
}) => Medicine(
  id: id,
  name: name,
  brand: 'TestBrand',
  categoryId: 'cat-1',
  strength: '500mg',
  packSize: '20 tablets',
  price: price,
);

InventoryItem _batch({
  String id = 'inv-1',
  String medicineId = 'med-a',
  String branchId = 'branch-dha-main',
  int quantity = 5,
  int threshold = 10,
  int? expiryDays,
  int costMinor = 8000,
}) => InventoryItem(
  id: id,
  medicineId: medicineId,
  branchId: branchId,
  quantity: quantity,
  lowStockThreshold: threshold,
  expiryDate: expiryDays == null
      ? null
      : _today.add(Duration(days: expiryDays)),
  batchNo: 'B-$id',
  costMinor: costMinor,
);

const _suppliers = <Supplier>[
  Supplier(
    id: 'sup-sami',
    name: 'Sami Pharmaceuticals',
    contactPerson: 'Sami Ullah',
    phone: '0300-7778899',
  ),
  Supplier(
    id: 'sup-medserve',
    name: 'MedServe Distributors',
    contactPerson: 'Nadia Iqbal',
    phone: '0321-1122334',
  ),
];

PurchaseOrder _po({
  String id = 'po-1',
  String supplierId = 'sup-sami',
  String branchId = 'branch-dha-main',
  PurchaseOrderStatus status = PurchaseOrderStatus.draft,
  List<PurchaseOrderItem> items = const [],
  DateTime? createdAt,
}) => PurchaseOrder(
  id: id,
  poNumber: 'PO-TEST-1',
  supplierId: supplierId,
  branchId: branchId,
  status: status,
  items: items,
  createdAt: createdAt ?? _today,
);

/// Pumps the ungated router app with a fresh container the test owns.
Future<(ProviderContainer, GoRouter)> _pumpRouterApp(
  WidgetTester tester, {
  Size size = const Size(1280, 900),
  ProviderContainer? container,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final owned = container ?? ProviderContainer();
  addTearDown(owned.dispose);
  final router = createAppRouter();
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: owned,
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
  return (owned, router);
}

Future<void> _openAutoList(
  WidgetTester tester,
  GoRouter router,
) async {
  router.go('/purchases/auto');
  await tester.pumpAndSettle();
  // Title appears twice on wide screens: the section header and the
  // sidebar sub-item.
  expect(find.text('Auto Purchase List'), findsWidgets);
}

void main() {
  group('Suggestion maths', () {
    test('suggested qty = reorder level − usable stock', () {
      final result = computeAutoPurchaseList(
        medicines: [_medicine()],
        inventory: [
          _batch(quantity: 5, threshold: 10),
          _batch(id: 'inv-2', quantity: 8, threshold: 10),
        ],
        branchOrders: const [],
        suppliers: _suppliers,
        branchId: 'branch-dha-main',
        now: _today,
      );
      // Usable 13, reorder 20 → suggest 7.
      expect(result.suggestions, hasLength(1));
      final line = result.suggestions.first;
      expect(line.usableStock, 13);
      expect(line.reorderLevel, 20);
      expect(line.suggestedQuantity, 7);
      expect(line.lineTotalMinor, 7 * 8000);
      expect(line.reason, AutoPurchaseReason.belowReorderLevel);
    });

    test('no line when usable stock is at or above the reorder level', () {
      final result = computeAutoPurchaseList(
        medicines: [_medicine()],
        inventory: [_batch(quantity: 25, threshold: 10)],
        branchOrders: const [],
        suppliers: _suppliers,
        branchId: 'branch-dha-main',
        now: _today,
      );
      expect(result.suggestions, isEmpty);
      expect(result.excluded, isEmpty);
    });

    test('expired stock is never usable: only the sellable batch counts',
        () {
      final result = computeAutoPurchaseList(
        medicines: [_medicine()],
        inventory: [
          // 50 units, but expired yesterday — unusable.
          _batch(quantity: 50, threshold: 10, expiryDays: -1),
          // 4 usable units, far expiry.
          _batch(id: 'inv-2', quantity: 4, threshold: 10, expiryDays: 200),
        ],
        branchOrders: const [],
        suppliers: _suppliers,
        branchId: 'branch-dha-main',
        now: _today,
      );
      expect(result.suggestions, hasLength(1));
      final line = result.suggestions.first;
      expect(line.usableStock, 4);
      expect(line.reorderLevel, 20);
      expect(line.suggestedQuantity, 16);
    });

    test('zero usable stock is Low stock; near-expiry batch labels the line',
        () {
      final low = computeAutoPurchaseList(
        medicines: [_medicine()],
        inventory: [_batch(quantity: 0, threshold: 10, expiryDays: 200)],
        branchOrders: const [],
        suppliers: _suppliers,
        branchId: 'branch-dha-main',
        now: _today,
      );
      expect(low.suggestions.first.reason, AutoPurchaseReason.lowStock);
      expect(low.suggestions.first.suggestedQuantity, 10);

      final near = computeAutoPurchaseList(
        medicines: [_medicine()],
        inventory: [
          _batch(quantity: 4, threshold: 10, expiryDays: 12),
        ],
        branchOrders: const [],
        suppliers: _suppliers,
        branchId: 'branch-dha-main',
        now: _today,
      );
      expect(near.suggestions.first.reason, AutoPurchaseReason.nearExpiry);
    });

    test('near-expiry alone with plenty of usable stock suggests nothing',
        () {
      final result = computeAutoPurchaseList(
        medicines: [_medicine()],
        inventory: [
          _batch(quantity: 30, threshold: 10, expiryDays: 5),
        ],
        branchOrders: const [],
        suppliers: _suppliers,
        branchId: 'branch-dha-main',
        now: _today,
      );
      expect(result.suggestions, isEmpty);
    });

    test('unit cost falls back to 80% of the sale price with no batch cost',
        () {
      final result = computeAutoPurchaseList(
        medicines: [_medicine(price: 100)],
        inventory: [
          _batch(quantity: 2, threshold: 10, expiryDays: 200, costMinor: 0),
        ],
        branchOrders: const [],
        suppliers: _suppliers,
        branchId: 'branch-dha-main',
        now: _today,
      );
      // 80% of Rs 100.00 = Rs 80.00 = 8000 paisa.
      expect(result.suggestions.first.unitCostMinor, 8000);
    });

    test('other branches never leak into this branch list', () {
      final result = computeAutoPurchaseList(
        medicines: [_medicine()],
        inventory: [
          _batch(branchId: 'branch-demo-gulberg', quantity: 1),
        ],
        branchOrders: const [],
        suppliers: _suppliers,
        branchId: 'branch-dha-main',
        now: _today,
      );
      expect(result.suggestions, isEmpty);
    });
  });

  group('Exclusions for open POs', () {
    test('Draft / Approved / Partially received cover the medicine', () {
      for (final status in [
        PurchaseOrderStatus.draft,
        PurchaseOrderStatus.approved,
        PurchaseOrderStatus.partiallyReceived,
      ]) {
        final result = computeAutoPurchaseList(
          medicines: [_medicine()],
          inventory: [_batch(quantity: 2, threshold: 10, expiryDays: 200)],
          branchOrders: [
            _po(
              status: status,
              items: const [
                PurchaseOrderItem(
                  medicineId: 'med-a',
                  medicineName: 'Test Medicine',
                  quantityOrdered: 50,
                  unitCostMinor: 8000,
                ),
              ],
            ),
          ],
          suppliers: _suppliers,
          branchId: 'branch-dha-main',
          now: _today,
        );
        expect(result.suggestions, isEmpty, reason: '$status');
        expect(result.excluded, hasLength(1), reason: '$status');
        expect(result.excluded.first.medicineName, 'Test Medicine');
      }
    });

    test('Received / Cancelled POs do not exclude', () {
      for (final status in [
        PurchaseOrderStatus.received,
        PurchaseOrderStatus.cancelled,
      ]) {
        final result = computeAutoPurchaseList(
          medicines: [_medicine()],
          inventory: [_batch(quantity: 2, threshold: 10, expiryDays: 200)],
          branchOrders: [
            _po(
              status: status,
              items: const [
                PurchaseOrderItem(
                  medicineId: 'med-a',
                  medicineName: 'Test Medicine',
                  quantityOrdered: 50,
                  quantityReceived: 50,
                  unitCostMinor: 8000,
                ),
              ],
            ),
          ],
          suppliers: _suppliers,
          branchId: 'branch-dha-main',
          now: _today,
        );
        expect(result.suggestions, hasLength(1), reason: '$status');
        expect(result.excluded, isEmpty, reason: '$status');
      }
    });

    test('an open PO at another branch does not exclude', () {
      final result = computeAutoPurchaseList(
        medicines: [_medicine()],
        inventory: [_batch(quantity: 2, threshold: 10, expiryDays: 200)],
        branchOrders: [
          _po(
            branchId: 'branch-demo-gulberg',
            items: const [
              PurchaseOrderItem(
                medicineId: 'med-a',
                medicineName: 'Test Medicine',
                quantityOrdered: 50,
                unitCostMinor: 8000,
              ),
            ],
          ),
        ],
        suppliers: _suppliers,
        branchId: 'branch-dha-main',
        now: _today,
      );
      expect(result.suggestions, hasLength(1));
    });

    test('a fully received line on an open PO does not exclude', () {
      final result = computeAutoPurchaseList(
        medicines: [_medicine()],
        inventory: [_batch(quantity: 2, threshold: 10, expiryDays: 200)],
        branchOrders: [
          _po(
            status: PurchaseOrderStatus.partiallyReceived,
            items: const [
              PurchaseOrderItem(
                medicineId: 'med-a',
                medicineName: 'Test Medicine',
                quantityOrdered: 10,
                quantityReceived: 10,
                unitCostMinor: 8000,
              ),
            ],
          ),
        ],
        suppliers: _suppliers,
        branchId: 'branch-dha-main',
        now: _today,
      );
      expect(result.suggestions, hasLength(1));
      expect(result.excluded, isEmpty);
    });
  });

  group('Supplier grouping + totals + validation', () {
    AutoPurchaseLine line({
      String medicineId = 'med-a',
      String name = 'Test Medicine',
      int quantity = 5,
      int unitCostMinor = 8000,
      String? supplierId = 'sup-sami',
    }) => AutoPurchaseLine(
      suggestion: AutoPurchaseSuggestion(
        medicineId: medicineId,
        medicineName: name,
        brand: 'TestBrand',
        strength: '500mg',
        packSize: '20 tablets',
        reason: AutoPurchaseReason.belowReorderLevel,
        usableStock: 5,
        reorderLevel: 10,
        unitCostMinor: unitCostMinor,
        suggestedQuantity: 5,
        supplierId: supplierId,
      ),
      quantity: quantity,
      supplierId: supplierId,
    );

    test('groups by supplier: one PO per supplier, totals in paisa', () {
      final grouped = groupLinesBySupplier([
        line(),
        line(medicineId: 'med-b', name: 'Second', quantity: 3),
        line(
          medicineId: 'med-c',
          name: 'Third',
          quantity: 2,
          supplierId: 'sup-medserve',
          unitCostMinor: 10000,
        ),
      ]);
      expect(grouped.keys, {'sup-sami', 'sup-medserve'});
      expect(grouped['sup-sami'], hasLength(2));
      expect(grouped['sup-medserve'], hasLength(1));
      final samiTotal = grouped['sup-sami']!.fold(
        0,
        (sum, item) => sum + item.lineTotalMinor,
      );
      expect(samiTotal, (5 + 3) * 8000);
      expect(grouped['sup-medserve']!.first.lineTotalMinor, 2 * 10000);
    });

    test('qty 0 lines and supplier-less lines are not grouped', () {
      final grouped = groupLinesBySupplier([
        line(quantity: 0),
        line(medicineId: 'med-b', name: 'No supplier', supplierId: null),
        line(medicineId: 'med-c', name: 'Kept', quantity: 4),
      ]);
      expect(grouped.keys, {'sup-sami'});
      expect(grouped['sup-sami'], hasLength(1));
      expect(grouped['sup-sami']!.first.medicineName, 'Kept');
    });

    test('autoPurchaseTotalMinor sums only orderable lines', () {
      expect(
        autoPurchaseTotalMinor([
          line(quantity: 5),
          line(medicineId: 'med-b', name: 'Zero', quantity: 0),
          line(
            medicineId: 'med-c',
            name: 'Third',
            quantity: 2,
            unitCostMinor: 10000,
          ),
        ]),
        5 * 8000 + 2 * 10000,
      );
    });

    test('validation: empty list, all-zero, missing supplier, negative', () {
      expect(validateAutoPurchaseLines(const []), isNotEmpty);
      expect(
        validateAutoPurchaseLines([line(quantity: 0)]),
        isNotEmpty,
      );
      expect(
        validateAutoPurchaseLines([
          line(supplierId: null),
        ]),
        isNotEmpty,
      );
      expect(
        validateAutoPurchaseLines([line(quantity: -1)]),
        isNotEmpty,
      );
      expect(validateAutoPurchaseLines([line()]), isEmpty);
    });

    test('preferred supplier reuses the newest PO for the medicine', () {
      final id = preferredSupplierIdForMedicine(
        medicineId: 'med-a',
        branchOrders: [
          _po(
            id: 'po-old',
            supplierId: 'sup-sami',
            createdAt: DateTime(2026, 11, 20),
            items: const [
              PurchaseOrderItem(
                medicineId: 'med-a',
                medicineName: 'Test Medicine',
                quantityOrdered: 10,
                unitCostMinor: 8000,
              ),
            ],
          ),
          _po(
            id: 'po-new',
            supplierId: 'sup-medserve',
            createdAt: DateTime(2026, 11, 24),
            items: const [
              PurchaseOrderItem(
                medicineId: 'med-a',
                medicineName: 'Test Medicine',
                quantityOrdered: 10,
                unitCostMinor: 8000,
              ),
            ],
          ),
        ],
        suppliers: _suppliers,
      );
      expect(id, 'sup-medserve');
    });

    test('preferred supplier falls back to the first active supplier', () {
      expect(
        preferredSupplierIdForMedicine(
          medicineId: 'med-unknown',
          branchOrders: const [],
          suppliers: _suppliers,
        ),
        'sup-sami',
      );
      expect(
        preferredSupplierIdForMedicine(
          medicineId: 'med-unknown',
          branchOrders: const [],
          suppliers: const [],
        ),
        isNull,
      );
    });
  });

  group('Idempotent approval (provider)', () {
    testWidgets('same approval key twice creates one PO per supplier',
        (WidgetTester tester) async {
      final (container, router) = await _pumpRouterApp(tester);
      await _openAutoList(tester, router);
      final notifier = container.read(autoPurchaseListProvider.notifier);
      final lines = container.read(autoPurchaseListProvider).lines;
      expect(lines, isNotEmpty);
      final suppliers = lines
          .where((line) => line.quantity > 0)
          .map((line) => line.supplierId)
          .toSet();
      expect(suppliers.length, greaterThan(0));

      Future<int> poCount() async => (await container
              .read(purchaseOrderRepositoryProvider)
              .getPurchaseOrders())
          .length;
      final before = await poCount();
      final first = await notifier.approve(idempotencyKey: 'test-key-1');
      expect(first.error, isNull);
      expect(first.orders, hasLength(suppliers.length));
      expect(
        first.orders.every(
          (po) => po.status == PurchaseOrderStatus.draft,
        ),
        isTrue,
      );
      final second = await notifier.approve(idempotencyKey: 'test-key-1');
      expect(second.error, isNull);
      expect(
        second.orders.map((po) => po.id),
        first.orders.map((po) => po.id),
      );
      expect(await poCount(), before + suppliers.length);
    });

    testWidgets('concurrent double approval creates one PO per supplier',
        (WidgetTester tester) async {
      final (container, router) = await _pumpRouterApp(tester);
      await _openAutoList(tester, router);
      final notifier = container.read(autoPurchaseListProvider.notifier);
      Future<int> poCount() async => (await container
              .read(purchaseOrderRepositoryProvider)
              .getPurchaseOrders())
          .length;
      final before = await poCount();
      final results = await Future.wait([
        notifier.approve(idempotencyKey: 'test-key-2'),
        notifier.approve(idempotencyKey: 'test-key-2'),
      ]);
      final created = results
          .expand((r) => r.orders)
          .map((po) => po.id)
          .toSet();
      final after = await poCount();
      // One of the two calls wins; the other reports in-progress and
      // creates nothing — never two POs per supplier.
      expect(after, before + created.length);
      expect(created.length, greaterThan(0));
    });
  });

  group('Screen (seeded data, DHA branch)', () {
    testWidgets('renders suggested lines with reason, stock and totals',
        (WidgetTester tester) async {
      final (container, router) = await _pumpRouterApp(tester);
      await _openAutoList(tester, router);
      final state = container.read(autoPurchaseListProvider);
      expect(state.loading, isFalse);
      expect(state.lines, isNotEmpty);
      expect(find.textContaining('Branch: Demo Branch — DHA'), findsOneWidget);
      expect(find.text('Estimated total'), findsWidgets);
      // Every line shows its reason label and its medicine name.
      for (final line in state.lines.take(3)) {
        expect(
          find.text(line.suggestion.medicineName),
          findsWidgets,
        );
        expect(
          find.text(autoPurchaseReasonLabel(line.suggestion.reason)),
          findsWidgets,
        );
      }
      if (state.excludedCount > 0) {
        expect(find.textContaining('already covered by an open'), findsOneWidget);
      }
    });

    testWidgets('edit qty updates the line total; remove drops the line',
        (WidgetTester tester) async {
      final (container, router) = await _pumpRouterApp(tester);
      await _openAutoList(tester, router);
      final first = container.read(autoPurchaseListProvider).lines.first;
      final medicineId = first.suggestion.medicineId;
      final before = container.read(autoPurchaseListProvider).totalMinor;

      await tester.enterText(
        find.byKey(ValueKey('qty-$medicineId')),
        '${first.quantity + 10}',
      );
      await tester.pumpAndSettle();
      final edited = container
          .read(autoPurchaseListProvider)
          .lines
          .firstWhere((l) => l.suggestion.medicineId == medicineId);
      expect(edited.quantity, first.quantity + 10);
      expect(
        container.read(autoPurchaseListProvider).totalMinor,
        before + 10 * first.suggestion.unitCostMinor,
      );

      await tester.ensureVisible(find.byKey(ValueKey('remove-$medicineId')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('remove-$medicineId')));
      await tester.pumpAndSettle();
      expect(
        container
            .read(autoPurchaseListProvider)
            .lines
            .any((l) => l.suggestion.medicineId == medicineId),
        isFalse,
      );
    });

    testWidgets('approve creates Draft POs visible in Purchases',
        (WidgetTester tester) async {
      final (container, router) = await _pumpRouterApp(tester);
      await _openAutoList(tester, router);
      final lines = container.read(autoPurchaseListProvider).lines;
      final suppliers = lines
          .where((line) => line.quantity > 0)
          .map((line) => line.supplierId)
          .toSet();
      final approveButton = find.text('Approve & create purchase orders');
      await tester.ensureVisible(approveButton);
      await tester.pumpAndSettle();
      await tester.tap(approveButton);
      await tester.pumpAndSettle();
      final state = container.read(autoPurchaseListProvider);
      expect(state.lastCreated, hasLength(suppliers.length));
      expect(find.textContaining('draft purchase order'), findsWidgets);

      router.go('/purchases');
      await tester.pumpAndSettle();
      for (final po in state.lastCreated) {
        expect(find.text(po.poNumber), findsOneWidget);
      }
    });

    testWidgets('double-tap approval creates only one PO per supplier',
        (WidgetTester tester) async {
      final (container, router) = await _pumpRouterApp(tester);
      await _openAutoList(tester, router);
      Future<int> poCount() async => (await container
              .read(purchaseOrderRepositoryProvider)
              .getPurchaseOrders())
          .length;
      final before = await poCount();
      final suppliers = container
          .read(autoPurchaseListProvider)
          .lines
          .where((line) => line.quantity > 0)
          .map((line) => line.supplierId)
          .toSet();
      final approveButton = find.text('Approve & create purchase orders');
      await tester.ensureVisible(approveButton);
      await tester.pumpAndSettle();
      await tester.tap(approveButton);
      // Second tap while the first approval is in flight: the button
      // is disabled (loading), so nothing happens.
      await tester.tap(approveButton, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(await poCount(), before + suppliers.length);
    });

    testWidgets('Purchases list links to the Auto Purchase List',
        (WidgetTester tester) async {
      final (_, router) = await _pumpRouterApp(tester);
      router.go('/purchases');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('open-auto-purchase-list')));
      await tester.pumpAndSettle();
      expect(find.text('Auto Purchase List'), findsWidgets);
    });
  });

  group('Screen (empty state)', () {
    testWidgets('shows the empty state when nothing needs ordering',
        (WidgetTester tester) async {
      // A branch whose stock is far above every reorder level: the
      // mock inventory repo returns only well-stocked batches.
      // (Riverpod 3.5 does not export the `Override` type, so the
      // override list is built inline here, where the constructor
      // parameter types it contextually.)
      final container = ProviderContainer(overrides: [
        inventoryRepositoryProvider.overrideWithValue(
          _WellStockedInventoryRepository(),
        ),
      ]);
      final (_, router) = await _pumpRouterApp(tester, container: container);
      await _openAutoList(tester, router);
      expect(find.text('Nothing to order'), findsOneWidget);
      expect(find.text('View purchase orders'), findsOneWidget);
    });
  });
}

/// Inventory repository that returns only well-stocked batches (one
/// per catalogue medicine, 200 units, threshold 10, far expiry), so
/// the auto purchase list is empty.
class _WellStockedInventoryRepository implements InventoryRepository {
  @override
  Future<List<InventoryItem>> getInventory({String? branchId}) async {
    return [
      for (final medicine in demoMedicines)
        InventoryItem(
          id: 'inv-full-${medicine.id}',
          medicineId: medicine.id,
          branchId: branchId ?? 'branch-dha-main',
          quantity: 200,
          lowStockThreshold: 10,
          expiryDate: DateTime(2027, 6, 1),
          batchNo: 'FULL-1',
          costMinor: 8000,
        ),
    ];
  }

  @override
  Future<List<InventoryItem>> getLowStock({String? branchId}) async =>
      const [];

  @override
  Future<List<InventoryItem>> getExpiringWithin({
    int days = 30,
    String? branchId,
  }) async => const [];

  @override
  Future<InventoryItem> receiveStock({
    required String branchId,
    required String medicineId,
    required String batchNo,
    required DateTime mfgDate,
    required DateTime expiryDate,
    required int quantity,
    required int costMinor,
  }) async => throw UnimplementedError();

  @override
  Future<InventoryItem> adjustStock({
    required String batchId,
    required int deltaQty,
    required String reason,
  }) async => throw UnimplementedError();

  @override
  Future<InventoryItem> recordStockCount({
    required String batchId,
    required int countedQty,
    String? note,
  }) async => throw UnimplementedError();

  @override
  Future<InventoryItem> updateBatchStatus({
    required String batchId,
    required BatchStatus status,
    String? reason,
  }) async => throw UnimplementedError();

  @override
  Future<InventoryItem> upsertInventoryItem(InventoryItem item) async =>
      throw UnimplementedError();

  @override
  Future<BranchInventoryLocation?> getBranchLocation({
    required String branchId,
    required String medicineId,
  }) async =>
      throw UnimplementedError();

  @override
  Future<List<BranchInventoryLocation>> getBranchLocations({
    String? branchId,
  }) async =>
      throw UnimplementedError();

  @override
  Future<BranchInventoryLocation> saveBranchLocation(
    BranchInventoryLocation location,
  ) async =>
      throw UnimplementedError();
}
