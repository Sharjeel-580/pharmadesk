// Week 4 Day 5 tests — last partials + Phase 8 QA depth (D137–D146).
//
// - D-04 split payment (FR-POS-05): a sale may settle across methods;
//   the split sums to the total, the receipt + history show it.
// - D-10 medicine location + per-medicine stock history (FR-INV-10/12).
// - D-11 quarantine action (FR-INV-07): quarantined batches are never
//   sellable (guard is D68 — pinned here, not re-implemented).
// - D-14 adjustment approval queue (FR-INV-08, SRS §5.2.4): request
//   with reason → approve/reject by an allowed approver who is not
//   the requester → apply on approval through the layer.
// - 390px sweep (Day 1 findings): /orders 12px, /billing 133px,
//   /inventory batch rows 24–56px — all fixed, with regression tests.
// - Offline-queue behaviour: enqueue while "offline", flush on
//   reconnect, no double-send (idempotency), chip pending → synced.
// - Role gates (SRS §5.1): every role × the Week 4 screens +
//   the existing gated screens.
// - D129 (if it fits): layer sync payload for cashbook writes +
//   SyncStatusChip on the cashbook screen.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:pharmadesk/core/data/auth_repository.dart';
import 'package:pharmadesk/core/data/production_data_layer.dart';
import 'package:pharmadesk/core/data/audit_log.dart';
import 'package:pharmadesk/core/data/firestore_mappers.dart';
import 'package:pharmadesk/core/data/firestore_schema.dart';
import 'package:pharmadesk/core/data/inventory_engine.dart';
import 'package:pharmadesk/core/data/permission_service.dart';
import 'package:pharmadesk/core/data/sync_queue.dart';
import 'package:pharmadesk/core/widgets/sync_status_widget.dart';
import 'package:pharmadesk/core/services/repositories.dart';
import 'package:pharmadesk/core/routing/app_router.dart';
import 'package:pharmadesk/core/theme/app_theme.dart';
import 'package:pharmadesk/core/theme/white_label.dart';
import 'package:pharmadesk/features/authentication/auth_state.dart';
import 'package:pharmadesk/features/billing/billing_logic.dart';
import 'package:pharmadesk/features/billing/billing_provider.dart';
import 'package:pharmadesk/features/finance/finance_provider.dart';
import 'package:pharmadesk/features/inventory/inventory_logic.dart';
import 'package:pharmadesk/features/inventory/inventory_provider.dart';
import 'package:pharmadesk/features/inventory/stock_adjustment_logic.dart';
import 'package:pharmadesk/features/inventory/stock_adjustment_queue.dart';
import 'package:pharmadesk/models/customer_ledger.dart';
import 'package:pharmadesk/models/daily_closing.dart';
import 'package:pharmadesk/models/inventory_item.dart';
import 'package:pharmadesk/models/medicine.dart';
import 'package:pharmadesk/models/sale.dart';
import 'package:pharmadesk/models/stock_adjustment_request.dart';

const _dha = 'branch-dha-main';
const _org = demoOrganizationId;
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

/// Production layer over fresh mocks (same helper shape as the
/// Week 4 Day 2/4 layer tests). The [audit] writer is exposed so
/// tests can read the audit trail the layer writes.
ProductionDataLayer _layer({InMemoryAuditLogWriter? audit}) {
  final writer = audit ?? InMemoryAuditLogWriter();
  final queue = SyncQueue(InMemorySyncStore());
  final engine = InventoryEngine(organizationId: _org, audit: writer);
  return ProductionDataLayer(
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
    stockTransferRepo: MockStockTransferRepository(),
    audit: writer,
    syncQueue: queue,
    engine: engine,
  );
}

/// Pumps the router app with a fresh container the test owns (same
/// harness as the Week 4 Day 4 widget tests).
Future<(ProviderContainer, GoRouter)> pumpRouterApp(
  WidgetTester tester, {
  Size size = const Size(1920, 1080),
  ProductionDataLayer? layerOverride,
  AppUser? user,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final container = ProviderContainer(
    overrides: [
      if (layerOverride != null)
        productionDataLayerProvider.overrideWithValue(layerOverride),
      if (user != null) authProvider.overrideWith(() => _FixedAuthNotifier(user)),
    ],
  );
  addTearDown(container.dispose);
  final router = createAppRouter(
    isSignedIn: user == null ? null : () => container.read(authProvider) != null,
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

/// Pumps the router app signed in as [roleKey] (see [_userFor]).
Future<(ProviderContainer, GoRouter)> pumpRouterAppAsRole(
  WidgetTester tester,
  String roleKey, {
  List<String> branchIds = const [_dha],
  Size size = const Size(1920, 1080),
}) async {
  return pumpRouterApp(
    tester,
    size: size,
    user: _userFor(roleKey, branchIds: branchIds),
  );
}

/// An auth notifier whose user can be swapped mid-test — the
/// approval queue needs two different users in one container (the
/// requester, then a different approver).
class _MutableAuthNotifier extends AuthNotifier {
  _MutableAuthNotifier(this._user);

  AppUser? _user;

  set user(AppUser? value) {
    _user = value;
    state = value;
  }

  @override
  AppUser? build() => _user;
}

/// Pumps the router app with a swappable auth notifier. Returns the
/// container, the router and the auth notifier (swap its `user` to
/// sign in as someone else).
Future<(ProviderContainer, GoRouter, _MutableAuthNotifier)>
pumpRouterAppWithMutableAuth(
  WidgetTester tester,
  AppUser initialUser, {
  Size size = const Size(1920, 1080),
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final auth = _MutableAuthNotifier(initialUser);
  final container = ProviderContainer(
    overrides: [authProvider.overrideWith(() => auth)],
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
  return (container, router, auth);
}

/// Drains any exceptions the binding recorded during pumping (e.g.
/// RenderFlex overflows from the screen body at 390px) and returns
/// their full texts.
///
/// NOTE: when a pump records many exceptions the binding hands back
/// ONE aggregated error ("Multiple exceptions (N) were detected…")
/// whose first line names the aggregate, not the overflows — so the
/// full text is returned and callers search the whole string, not
/// just the first line.
List<String> drainExceptions(WidgetTester tester) {
  final messages = <String>[];
  Object? error;
  while ((error = tester.takeException()) != null) {
    messages.add(error.toString());
  }
  return messages;
}

/// Counts "RenderFlex overflowed" occurrences across drained
/// exception texts (one aggregate can hold many).
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

void main() {
  group('Split payment — D-04 / FR-POS-05 (D137)', () {
    const cash = SalePaymentMethod.cash;
    const card = SalePaymentMethod.card;
    const credit = SalePaymentMethod.credit;

    CartLine line({int quantity = 1}) => CartLine(
      medicineId: 'med-panadol-extra',
      medicineName: 'Panadol Extra',
      unitPriceMinor: 12000,
      quantity: quantity,
    );

    group('validateSplitPayments', () {
      test('legs summing to the total pass', () {
        expect(
          validateSplitPayments(
            totalMinor: 12000,
            splits: const [
              SalePayment(method: cash, amountMinor: 8000),
              SalePayment(method: card, amountMinor: 4000),
            ],
          ),
          isEmpty,
        );
      });

      test('short and over splits fail', () {
        expect(
          validateSplitPayments(
            totalMinor: 12000,
            splits: const [
              SalePayment(method: cash, amountMinor: 8000),
            ],
          ),
          isNotEmpty,
        );
        expect(
          validateSplitPayments(
            totalMinor: 12000,
            splits: const [
              SalePayment(method: cash, amountMinor: 8000),
              SalePayment(method: card, amountMinor: 5000),
            ],
          ),
          isNotEmpty,
        );
      });

      test('zero leg, duplicate method and empty split fail', () {
        expect(
          validateSplitPayments(
            totalMinor: 12000,
            splits: const [
              SalePayment(method: cash, amountMinor: 0),
              SalePayment(method: card, amountMinor: 12000),
            ],
          ),
          isNotEmpty,
        );
        expect(
          validateSplitPayments(
            totalMinor: 12000,
            splits: const [
              SalePayment(method: cash, amountMinor: 6000),
              SalePayment(method: cash, amountMinor: 6000),
            ],
          ),
          isNotEmpty,
        );
        expect(
          validateSplitPayments(totalMinor: 12000, splits: const []),
          isNotEmpty,
        );
      });
    });

    group('validateSale with a split', () {
      test('valid cash+card split passes; short split fails', () {
        final ok = validateSale(
          lines: [line()],
          paymentMethod: cash,
          cashReceivedMinor: 8000,
          splitPayments: const [
            SalePayment(method: cash, amountMinor: 8000),
            SalePayment(method: card, amountMinor: 4000),
          ],
        );
        expect(ok, isEmpty);
        final short = validateSale(
          lines: [line()],
          paymentMethod: cash,
          cashReceivedMinor: 8000,
          splitPayments: const [
            SalePayment(method: cash, amountMinor: 8000),
          ],
        );
        expect(short, isNotEmpty);
      });

      test('credit leg needs a customer and headroom for the leg only',
          () {
        // No customer for the credit leg.
        expect(
          validateSale(
            lines: [line()],
            paymentMethod: cash,
            cashReceivedMinor: 8000,
            splitPayments: const [
              SalePayment(method: cash, amountMinor: 8000),
              SalePayment(method: credit, amountMinor: 4000),
            ],
          ),
          isNotEmpty,
        );
        // cust-3: outstanding Rs 12,000, limit Rs 15,000 — a Rs 40
        // credit leg fits even though the full total would not
        // matter; a Rs 4,000 leg (over the Rs 3,000 headroom) fails.
        final overLeg = validateSale(
          lines: [line(quantity: 34)],
          paymentMethod: cash,
          cashReceivedMinor: 8000,
          customerId: 'cust-3',
          outstandingMinor: 1200000,
          creditLimitMinor: 1500000,
          splitPayments: const [
            SalePayment(method: cash, amountMinor: 8000),
            SalePayment(method: credit, amountMinor: 400000),
          ],
        );
        expect(overLeg, isNotEmpty);
        final fitsLeg = validateSale(
          lines: [line(quantity: 34)],
          paymentMethod: cash,
          cashReceivedMinor: 108000,
          customerId: 'cust-3',
          outstandingMinor: 1200000,
          creditLimitMinor: 1500000,
          splitPayments: const [
            SalePayment(method: cash, amountMinor: 108000),
            SalePayment(method: credit, amountMinor: 300000),
          ],
        );
        expect(fitsLeg, isEmpty);
      });
    });

    group('buildSale + Sale model', () {
      test('split sale stores legs, primary is the largest leg', () {
        final sale = buildSale(
          branchId: _dha,
          cashierName: 'Usman Tariq',
          items: [
            SaleItem(
              medicineId: 'med-panadol-extra',
              medicineName: 'Panadol Extra',
              quantity: 1,
              unitPriceMinor: 12000,
            ),
          ],
          billDiscountMinor: 0,
          taxRatePercent: 0,
          paymentMethod: cash,
          cashReceivedMinor: 8000,
          splitPayments: const [
            SalePayment(method: cash, amountMinor: 8000),
            SalePayment(method: card, amountMinor: 4000),
          ],
        );
        expect(sale.isSplit, true);
        expect(sale.totalMinor, 12000);
        expect(sale.splitTotalMinor, 12000);
        expect(sale.paymentMethod, cash);
        expect(sale.cashMinor, 8000);
        expect(sale.creditMinor, 0);
        expect(sale.changeMinor, 0); // split cash is exact
        expect(sale.payments.length, 2);
      });

      test('single-method sale keeps one leg; cash change unchanged', () {
        final sale = buildSale(
          branchId: _dha,
          cashierName: 'Usman Tariq',
          items: [
            SaleItem(
              medicineId: 'med-panadol-extra',
              medicineName: 'Panadol Extra',
              quantity: 1,
              unitPriceMinor: 12000,
            ),
          ],
          billDiscountMinor: 0,
          taxRatePercent: 0,
          paymentMethod: cash,
          cashReceivedMinor: 20000,
        );
        expect(sale.isSplit, false);
        expect(sale.payments.length, 1);
        expect(sale.payments.first.amountMinor, 12000);
        expect(sale.changeMinor, 8000);
      });

      test('toMap/fromMap round-trips legs; legacy map derives one leg',
          () {
        final sale = buildSale(
          branchId: _dha,
          cashierName: 'Usman Tariq',
          items: [
            SaleItem(
              medicineId: 'med-panadol-extra',
              medicineName: 'Panadol Extra',
              quantity: 1,
              unitPriceMinor: 12000,
            ),
          ],
          billDiscountMinor: 0,
          taxRatePercent: 0,
          paymentMethod: cash,
          cashReceivedMinor: 8000,
          splitPayments: const [
            SalePayment(method: cash, amountMinor: 8000),
            SalePayment(method: credit, amountMinor: 4000),
          ],
        );
        final restored = Sale.fromMap('sale-1', sale.toMap());
        expect(restored.isSplit, true);
        expect(restored.creditMinor, 4000);
        expect(restored.cashMinor, 8000);
        // Legacy doc: no `payments` list at all.
        final legacy = Map<String, dynamic>.from(sale.toMap())
          ..remove('payments');
        final legacySale = Sale.fromMap('sale-1', legacy);
        expect(legacySale.isSplit, false);
        expect(legacySale.payments.first.amountMinor, 12000);
      });

      test('receipt text shows the split legs', () {
        final sale = buildSale(
          branchId: _dha,
          cashierName: 'Usman Tariq',
          items: [
            SaleItem(
              medicineId: 'med-panadol-extra',
              medicineName: 'Panadol Extra',
              quantity: 1,
              unitPriceMinor: 12000,
            ),
          ],
          billDiscountMinor: 0,
          taxRatePercent: 0,
          paymentMethod: cash,
          cashReceivedMinor: 8000,
          splitPayments: const [
            SalePayment(method: cash, amountMinor: 8000),
            SalePayment(method: card, amountMinor: 4000),
          ],
        );
        final text = receiptText(
          sale: sale.copyWith(invoiceNumber: 'INV-DHA-1001'),
          branchName: 'DHA Main',
          branchAddress: 'DHA Lahore',
          brandHeader: 'PharmaDesk',
        );
        expect(text, contains('Split: Cash + Card'));
        expect(text, contains('Cash: Rs 80.00'));
        expect(text, contains('Card: Rs 40.00'));
      });
    });

    test('receipt text shows cash rows for a hand-built cash sale', () {
      // Regression (Day 5): a Sale built by the constructor carries
      // no `payments` leg, so gating the cash rows on `cashMinor`
      // hid them. The rows describe the cash handed over
      // (`cashReceivedMinor`), so they render for any cash sale.
      final sale = Sale(
        id: 'sale-handbuilt',
        invoiceNumber: 'INV-DHA-1001',
        branchId: _dha,
        cashierName: 'Usman Tariq',
        items: [
          SaleItem(
            medicineId: 'med-panadol-extra',
            medicineName: 'Panadol Extra',
            quantity: 1,
            unitPriceMinor: 12000,
          ),
        ],
        subtotalMinor: 12000,
        totalMinor: 12000,
        paymentMethod: SalePaymentMethod.cash,
        cashReceivedMinor: 20000,
        changeMinor: 8000,
        idempotencyKey: 'sale-handbuilt-1',
        createdAt: DateTime(2026, 11, 24, 10, 30),
      );
      final text = receiptText(
        sale: sale,
        branchName: 'Demo Branch — DHA',
        branchAddress: 'DHA Phase 2, Lahore',
        brandHeader: 'PharmaDesk',
        customerName: 'Ahmed Raza',
      );
      expect(text, contains('Cash received: Rs 200.00'));
      expect(text, contains('Change: Rs 80.00'));
    });

    group('Sale completion (notifier) with a split', () {
      test('cash+card split completes, decrements FEFO, stores legs',
          () async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final notifier = container.read(salesProvider.notifier);
        final result = await notifier.completeSale(
          branchId: _dha,
          cashierName: 'Usman Tariq',
          lines: [line()],
          paymentMethod: cash,
          cashReceivedMinor: 8000,
          splitPayments: const [
            SalePayment(method: cash, amountMinor: 8000),
            SalePayment(method: card, amountMinor: 4000),
          ],
        );
        expect(result.error, isNull);
        final sale = result.sale!;
        expect(sale.isSplit, true);
        expect(sale.paymentMethod, cash);
        expect(sale.totalMinor, 12000);
        final saved = container.read(salesProvider).asData!.value;
        expect(saved.length, 1);
        expect(saved.first.creditMinor, 0);
      });

      test('cash+credit split charges the khata only the credit leg',
          () async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final notifier = container.read(salesProvider.notifier);
        final result = await notifier.completeSale(
          branchId: _dha,
          customerId: 'cust-1',
          cashierName: 'Usman Tariq',
          lines: [line()],
          paymentMethod: cash,
          cashReceivedMinor: 8000,
          splitPayments: const [
            SalePayment(method: cash, amountMinor: 8000),
            SalePayment(method: credit, amountMinor: 4000),
          ],
        );
        expect(result.error, isNull);
        final entries = await container
            .read(customerRepositoryProvider)
            .getLedgerEntries('cust-1');
        final latest = entries.last;
        expect(latest.kind, LedgerEntryKind.creditSale);
        expect(latest.amountMinor, 4000);
        expect(latest.balanceAfterMinor, 554000);
      });

      test('split short of the total completes nothing', () async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final inventoryRepo = container.read(inventoryRepositoryProvider);
        final before = await inventoryRepo.getInventory(branchId: _dha);
        final notifier = container.read(salesProvider.notifier);
        final result = await notifier.completeSale(
          branchId: _dha,
          cashierName: 'Usman Tariq',
          lines: [line()],
          paymentMethod: cash,
          cashReceivedMinor: 8000,
          splitPayments: const [
            SalePayment(method: cash, amountMinor: 8000),
          ],
        );
        expect(result.sale, isNull);
        expect(result.error, contains('must add up to the total'));
        final after = await inventoryRepo.getInventory(branchId: _dha);
        expect(
          after.map((r) => r.quantity).toList(),
          before.map((r) => r.quantity).toList(),
        );
      });
    });
  });

  group('Medicine location + stock history — D-10 (D138/D139)', () {
    test('Medicine fromMap/toMap round-trips location; copyWith clears',
        () {
      const medicine = Medicine(
        id: 'med-test',
        name: 'Test',
        brand: 'Brand',
        categoryId: 'cat-1',
        strength: '500mg',
        packSize: '20 tablets',
        price: 120,
        location: 'Rack A • Shelf 2',
      );
      final restored = Medicine.fromMap(medicine.id, medicine.toMap());
      expect(restored.location, 'Rack A • Shelf 2');
      expect(medicine.copyWith(location: 'Rack B').location, 'Rack B');
      expect(
        medicine.copyWith(clearLocation: true).location,
        isNull,
      );
      final noLocation = Medicine.fromMap(
        'med-test',
        Map<String, dynamic>.from(medicine.toMap())..remove('location'),
      );
      expect(noLocation.location, isNull);
    });

    test('Firestore mappers round-trip location', () {
      const medicine = Medicine(
        id: 'med-test',
        name: 'Test',
        brand: 'Brand',
        categoryId: 'cat-1',
        strength: '500mg',
        packSize: '20 tablets',
        price: 120,
        location: 'Rack A • Shelf 2',
      );
      final doc = medicineToFirestore(medicine, orgId: _org);
      expect(doc['location'], 'Rack A • Shelf 2');
      final restored = medicineFromFirestore('med-test', doc);
      expect(restored.location, 'Rack A • Shelf 2');
    });

    test('mock updateMedicine saves location; unknown id throws',
        () async {
      final repo = MockMedicineRepository();
      final original = await repo.getById('med-panadol-extra');
      expect(original, isNotNull);
      expect(original!.location, isNull);
      final saved = await repo.updateMedicine(
        original.copyWith(location: 'Rack A • Shelf 2'),
      );
      expect(saved.location, 'Rack A • Shelf 2');
      expect((await repo.getById('med-panadol-extra'))!.location,
          'Rack A • Shelf 2');
      // Restore so later tests see the seed state.
      await repo.updateMedicine(original.copyWith(clearLocation: true));
      expect((await repo.getById('med-panadol-extra'))!.location, isNull);
      expect(
        () => repo.updateMedicine(
          const Medicine(
            id: 'med-nope',
            name: 'Nope',
            brand: 'Brand',
            categoryId: 'cat-1',
            strength: '500mg',
            packSize: '20 tablets',
            price: 120,
          ),
        ),
        throwsArgumentError,
      );
    });

    testWidgets('detail screen edits location end to end (Owner)',
        (tester) async {
      final (container, router) = await pumpRouterAppAsRole(
        tester,
        'Owner',
        size: _phoneSize,
      );
      router.go('/medicines/med-panadol-extra');
      await tester.pump(const Duration(milliseconds: 1500));
      await tester.pumpAndSettle();
      expect(find.text('Not set'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('medicine-edit-location')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('medicine-location-field')),
        'Rack A • Shelf 2',
      );
      await tester.tap(find.byKey(const ValueKey('medicine-location-save')));
      await tester.pumpAndSettle();
      expect(find.text('Rack A • Shelf 2'), findsOneWidget);
      // Restore the seed state for later tests.
      final repo = container.read(medicineRepositoryProvider);
      final medicine = await repo.getById('med-panadol-extra');
      await repo.updateMedicine(
        medicine!.copyWith(clearLocation: true),
      );
      container.invalidate(medicinesProvider);
    });

    testWidgets('edit button hidden for Cashier (medicineCrud none)',
        (tester) async {
      final (_, router) = await pumpRouterAppAsRole(
        tester,
        'cashier',
        size: _phoneSize,
      );
      router.go('/medicines/med-panadol-extra');
      await tester.pump(const Duration(milliseconds: 1500));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('medicine-edit-location')),
        findsNothing,
      );
    });

    testWidgets('stock history shows session ledger movements',
        (tester) async {
      final (container, router) = await pumpRouterAppAsRole(
        tester,
        'Owner',
        size: _phoneSize,
      );
      router.go('/medicines/med-panadol-extra');
      await tester.pump(const Duration(milliseconds: 1500));
      await tester.pumpAndSettle();
      expect(find.text('Stock history'), findsOneWidget);
      expect(
        find.textContaining('No stock movements yet this session'),
        findsOneWidget,
      );
      // Book a movement through the app's own layer, then refresh.
      final layer = container.read(productionDataLayerProvider);
      final inventory = await container
          .read(inventoryRepositoryProvider)
          .getInventory(branchId: _dha);
      final batch = inventory.firstWhere(
        (item) => item.medicineId == 'med-panadol-extra',
      );
      await layer.adjustStock(
        batchId: batch.id,
        deltaQty: 2,
        reason: 'Found on shelf',
      );
      container.invalidate(inventoryProvider);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(find.textContaining('Adjustment'), findsOneWidget);
      expect(find.textContaining('+2 unit(s)'), findsOneWidget);
      expect(find.textContaining('Found on shelf'), findsOneWidget);
    });
  });

  group('Batch quarantine — D-11 (D140)', () {
    InventoryItem batchFor({
      String id = 'inv-test-1',
      BatchStatus status = BatchStatus.available,
      int quantity = 10,
      DateTime? expiryDate,
    }) {
      return InventoryItem(
        id: id,
        medicineId: 'med-panadol-extra',
        branchId: _dha,
        quantity: quantity,
        lowStockThreshold: 5,
        batchNo: 'B-TEST-1',
        expiryDate: expiryDate ?? DateTime.now().add(const Duration(days: 90)),
        mfgDate: DateTime.now().subtract(const Duration(days: 30)),
        costMinor: 8000,
        status: status,
      );
    }

    test('guard: quarantined batch is never sellable (D68 pinned)', () {
      final quarantined = batchFor(status: BatchStatus.quarantined);
      final available = batchFor(id: 'inv-test-2');
      expect(isBatchSellable(quarantined), isFalse);
      expect(canSellMedicine([quarantined]), isFalse);
      expect(canSellMedicine([quarantined, available]), isTrue);
      expect(fefoBatchFor([quarantined, available])?.id, 'inv-test-2');
      expect(fefoBatchFor([quarantined]), isNull);
      expect(sellableStockFor([quarantined, available]), 10);
      expect(sellableStockFor([quarantined]), 0);
      // Total stock still counts the quarantined units — quarantine
      // parks them, it does not write them off.
      expect(totalStockFor([quarantined, available]), 20);
    });

    test('layer quarantine: status, audit, sync, idempotent retry',
        () async {
      final audit = InMemoryAuditLogWriter();
      final layer = _layer(audit: audit);
      final batch = (await layer.inventoryRepo.getInventory(
        branchId: _dha,
      )).firstWhere(
        (item) => item.medicineId == 'med-panadol-extra',
      );
      final quarantined = await layer.quarantineBatch(
        batchId: batch.id,
        reason: 'Suspected damage',
        idempotencyKey: 'quarantine-test-1',
      );
      expect(quarantined.status, BatchStatus.quarantined);
      expect(quarantined.quantity, batch.quantity);
      // The engine guard sees it at once.
      expect(
        isBatchSellable(
          (await layer.inventoryRepo.getInventory(branchId: _dha))
              .firstWhere((item) => item.id == batch.id),
        ),
        isFalse,
      );
      final entries = await audit.entries(
        entityType: 'batch',
        entityId: batch.id,
        action: 'batch.quarantined',
      );
      expect(entries, hasLength(1));
      expect(entries.first.summary, contains('Suspected damage'));
      expect(entries.first.before, 'available');
      expect(entries.first.after, 'quarantined');
      expect(await layer.syncQueue.pendingCount(), 1);
      // A retry with the same key returns the original batch and
      // enqueues nothing more (no second transition, no second op).
      final retry = await layer.quarantineBatch(
        batchId: batch.id,
        reason: 'Suspected damage',
        idempotencyKey: 'quarantine-test-1',
      );
      expect(retry.id, quarantined.id);
      expect(await layer.syncQueue.pendingCount(), 1);
      // A second quarantine with a NEW key is a transition error,
      // not a second quarantine.
      expect(
        () => layer.quarantineBatch(
          batchId: batch.id,
          reason: 'Again',
          idempotencyKey: 'quarantine-test-2',
        ),
        throwsArgumentError,
      );
      expect(await layer.syncQueue.pendingCount(), 1);
    });

    test('layer unquarantine restores saleable stock', () async {
      final audit = InMemoryAuditLogWriter();
      final layer = _layer(audit: audit);
      final batch = (await layer.inventoryRepo.getInventory(
        branchId: _dha,
      )).firstWhere(
        (item) => item.medicineId == 'med-panadol-extra',
      );
      await layer.quarantineBatch(
        batchId: batch.id,
        reason: 'Suspected damage',
        idempotencyKey: 'quarantine-test-3',
      );
      expect(
        (await layer.inventoryRepo.getInventory(branchId: _dha))
            .firstWhere((item) => item.id == batch.id)
            .status,
        BatchStatus.quarantined,
      );
      final restored = await layer.unquarantineBatch(
        batchId: batch.id,
        reason: 'Checked — safe to sell',
        idempotencyKey: 'unquarantine-test-3',
      );
      expect(restored.status, BatchStatus.available);
      expect(
        isBatchSellable(
          (await layer.inventoryRepo.getInventory(branchId: _dha))
              .firstWhere((item) => item.id == batch.id),
        ),
        isTrue,
      );
      final entries = await audit.entries(
        entityType: 'batch',
        entityId: batch.id,
        action: 'batch.unquarantined',
      );
      expect(entries, hasLength(1));
      // Restoring a batch that was never quarantined throws.
      expect(
        () => layer.unquarantineBatch(
          batchId: batch.id,
          reason: 'Again',
          idempotencyKey: 'unquarantine-test-4',
        ),
        throwsArgumentError,
      );
      // Unknown batch throws.
      expect(
        () => layer.quarantineBatch(
          batchId: 'inv-nope',
          reason: 'x',
          idempotencyKey: 'quarantine-test-5',
        ),
        throwsArgumentError,
      );
    });

    testWidgets('inventory screen quarantines + restores a batch',
        (tester) async {
      final (container, router) = await pumpRouterAppAsRole(
        tester,
        'Owner',
        size: const Size(1024, 768),
      );
      router.go('/inventory');
      await tester.pump(const Duration(milliseconds: 1500));
      await tester.pumpAndSettle();
      final inventory = await container
          .read(inventoryRepositoryProvider)
          .getInventory(branchId: _dha);
      final batch = inventory.firstWhere(
        (item) => item.medicineId == 'med-panadol-extra',
      );
      final quarantineKey = ValueKey('inv-quarantine-${batch.id}');
      await tester.ensureVisible(find.byKey(quarantineKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(quarantineKey));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('quarantine-reason-field')),
        'Suspected damage',
      );
      await tester.tap(find.byKey(const ValueKey('quarantine-confirm')));
      await tester.pumpAndSettle();
      expect(find.text('Quarantined'), findsWidgets);
      expect(
        find.textContaining('quarantined — out of saleable stock'),
        findsOneWidget,
      );
      // Restore it, leaving the seed state intact for later tests.
      final restoreKey = ValueKey('inv-unquarantine-${batch.id}');
      await tester.ensureVisible(find.byKey(restoreKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(restoreKey));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('quarantine-reason-field')),
        'Checked — safe to sell',
      );
      await tester.tap(find.byKey(const ValueKey('quarantine-confirm')));
      await tester.pumpAndSettle();
      expect(find.text('Quarantined'), findsNothing);
    });

    testWidgets('quarantine button hidden for Cashier',
        (tester) async {
      final (container, router) = await pumpRouterAppAsRole(
        tester,
        'Cashier',
        size: const Size(1024, 768),
      );
      router.go('/inventory');
      await tester.pump(const Duration(milliseconds: 1500));
      await tester.pumpAndSettle();
      final inventory = await container
          .read(inventoryRepositoryProvider)
          .getInventory(branchId: _dha);
      final batch = inventory.firstWhere(
        (item) => item.medicineId == 'med-panadol-extra',
      );
      await tester.ensureVisible(
        find.byKey(ValueKey('inv-adjust-${batch.id}')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(ValueKey('inv-quarantine-${batch.id}')),
        findsNothing,
      );
      expect(
        find.byKey(ValueKey('inv-unquarantine-${batch.id}')),
        findsNothing,
      );
    });
  });

  group('Adjustment approval queue — D-14 (D141)', () {
    StockAdjustmentRequest makeRequest({
      String requesterId = 'test-owner',
      String requesterName = 'Test Owner',
    }) {
      return StockAdjustmentRequest(
        id: 'adj-1',
        batchId: 'inv-test-1',
        batchNo: 'B-TEST-1',
        medicineId: 'med-panadol-extra',
        medicineName: 'Panadol Extra',
        branchId: _dha,
        deltaQty: -2,
        reason: 'Damaged in transit',
        requesterId: requesterId,
        requesterName: requesterName,
        requestedAt: DateTime.now(),
      );
    }

    test('validateAdjustmentRequest: zero, no reason, over-decrease', () {
      expect(
        validateAdjustmentRequest(deltaQty: 0, reason: 'x', onHandQty: 10),
        isNotNull,
      );
      expect(
        validateAdjustmentRequest(deltaQty: 2, reason: '  ', onHandQty: 10),
        isNotNull,
      );
      expect(
        validateAdjustmentRequest(
          deltaQty: -11,
          reason: 'Damaged',
          onHandQty: 10,
        ),
        contains('only 10 on hand'),
      );
      expect(
        validateAdjustmentRequest(
          deltaQty: -10,
          reason: 'Damaged',
          onHandQty: 10,
        ),
        isNull,
      );
      expect(
        validateAdjustmentRequest(deltaQty: 3, reason: 'Found', onHandQty: 1),
        isNull,
      );
    });

    test('canApproveAdjustment: approver, requester, wrong role', () {
      final request = makeRequest();
      // A different Owner may approve.
      expect(
        canApproveAdjustment(
          approver: _userFor('owner', uid: 'test-owner-2'),
          request: request,
        ),
        isTrue,
      );
      // The requester themself may not (§5.2.4).
      expect(
        canApproveAdjustment(
          approver: _userFor('owner'),
          request: request,
        ),
        isFalse,
      );
      // Inventory Manager may request but never approve.
      expect(
        canApproveAdjustment(
          approver: _userFor('inventory_manager'),
          request: request,
        ),
        isFalse,
      );
      // Branch Manager may approve in their own branch only.
      expect(
        canApproveAdjustment(
          approver: _userFor('branch_manager', branchIds: [_dha]),
          request: request,
        ),
        isTrue,
      );
      expect(
        canApproveAdjustment(
          approver: _userFor(
            'branch_manager',
            branchIds: ['branch-demo-gulberg'],
          ),
          request: request,
        ),
        isFalse,
      );
      // Cashier and Pharmacist may neither request nor approve.
      expect(
        canApproveAdjustment(
          approver: _userFor('cashier'),
          request: request,
        ),
        isFalse,
      );
      expect(
        canApproveAdjustment(approver: null, request: request),
        isFalse,
      );
    });

    test('queue: request → approve applies stock via the layer',
        () async {
      final auth = _MutableAuthNotifier(_userFor('owner'));
      final container = ProviderContainer(
        overrides: [authProvider.overrideWith(() => auth)],
      );
      addTearDown(container.dispose);
      final layer = container.read(productionDataLayerProvider);
      final inventory = await container
          .read(inventoryRepositoryProvider)
          .getInventory(branchId: _dha);
      final batch = inventory.firstWhere(
        (item) => item.medicineId == 'med-panadol-extra',
      );
      final beforeQty = batch.quantity;
      final notifier = container.read(
        stockAdjustmentQueueProvider.notifier,
      );
      final request = notifier.requestAdjustment(
        batchId: batch.id,
        batchNo: batch.batchNo ?? '—',
        medicineId: batch.medicineId,
        medicineName: 'Panadol Extra',
        branchId: _dha,
        deltaQty: -2,
        reason: 'Damaged in transit',
        onHandQty: beforeQty,
      );
      expect(request, isNotNull);
      expect(request!.status, StockAdjustmentStatus.pending);
      // Stock is untouched while the request is pending.
      expect(
        (await container
                .read(inventoryRepositoryProvider)
                .getInventory(branchId: _dha))
            .firstWhere((item) => item.id == batch.id)
            .quantity,
        beforeQty,
      );
      // The requester cannot approve their own request.
      expect(
        await notifier.approveAdjustment(requestId: request.id),
        isNull,
      );
      // A different Owner approves: the layer applies it.
      auth.user = _userFor('owner', uid: 'test-owner-2');
      final approved = await notifier.approveAdjustment(
        requestId: request.id,
      );
      expect(approved, isNotNull);
      expect(approved!.status, StockAdjustmentStatus.approved);
      expect(approved.movementId, isNotNull);
      expect(
        (await container
                .read(inventoryRepositoryProvider)
                .getInventory(branchId: _dha))
            .firstWhere((item) => item.id == batch.id)
            .quantity,
        beforeQty - 2,
      );
      expect(await layer.syncQueue.pendingCount(), 1);
      // Approving twice is a no-op (already decided).
      expect(
        await notifier.approveAdjustment(requestId: request.id),
        isNull,
      );
    });

    test('queue: reject records the decision and applies nothing',
        () async {
      final auth = _MutableAuthNotifier(_userFor('owner'));
      final container = ProviderContainer(
        overrides: [authProvider.overrideWith(() => auth)],
      );
      addTearDown(container.dispose);
      final inventory = await container
          .read(inventoryRepositoryProvider)
          .getInventory(branchId: _dha);
      final batch = inventory.firstWhere(
        (item) => item.medicineId == 'med-panadol-extra',
      );
      final beforeQty = batch.quantity;
      final notifier = container.read(
        stockAdjustmentQueueProvider.notifier,
      );
      final request = notifier.requestAdjustment(
        batchId: batch.id,
        batchNo: batch.batchNo ?? '—',
        medicineId: batch.medicineId,
        medicineName: 'Panadol Extra',
        branchId: _dha,
        deltaQty: 3,
        reason: 'Found on shelf',
        onHandQty: beforeQty,
      );
      expect(request, isNotNull);
      // The requester cannot reject their own request either.
      expect(
        notifier.rejectAdjustment(
          requestId: request!.id,
          note: 'No',
        ),
        isNull,
      );
      auth.user = _userFor('owner', uid: 'test-owner-2');
      final rejected = notifier.rejectAdjustment(
        requestId: request.id,
        note: 'Count does not match',
      );
      expect(rejected, isNotNull);
      expect(rejected!.status, StockAdjustmentStatus.rejected);
      expect(rejected.decisionNote, 'Count does not match');
      expect(
        (await container
                .read(inventoryRepositoryProvider)
                .getInventory(branchId: _dha))
            .firstWhere((item) => item.id == batch.id)
            .quantity,
        beforeQty,
      );
    });

    testWidgets('queue screen: request via dialog, approve as another user',
        (tester) async {
      final (container, router, auth) = await pumpRouterAppWithMutableAuth(
        tester,
        _userFor('owner'),
        size: const Size(1024, 768),
      );
      final inventory = await container
          .read(inventoryRepositoryProvider)
          .getInventory(branchId: _dha);
      final batch = inventory.firstWhere(
        (item) => item.medicineId == 'med-panadol-extra',
      );
      final beforeQty = batch.quantity;
      router.go('/inventory');
      await tester.pump(const Duration(milliseconds: 1500));
      await tester.pumpAndSettle();
      final adjustKey = ValueKey('inv-adjust-${batch.id}');
      await tester.ensureVisible(find.byKey(adjustKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(adjustKey));
      await tester.pumpAndSettle();
      expect(find.text('Request adjustment'), findsOneWidget);
      await tester.tap(find.text('Decrease'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('adjust-qty-field')),
        '2',
      );
      await tester.enterText(
        find.byKey(const ValueKey('adjust-reason-field')),
        'Damaged in transit',
      );
      await tester.tap(find.text('Submit request'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Adjustment requested — pending approval'),
        findsOneWidget,
      );
      // Let the first SnackBar dismiss: the approve SnackBar
      // queues behind it and would otherwise never become visible
      // under fake time.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      router.go('/inventory/adjustments');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      // The sidebar sub-item duplicates the screen header, so
      // there are two matching texts on desktop widths.
      expect(find.text('Adjustment Approvals'), findsWidgets);
      expect(find.text('Pending'), findsWidgets);
      expect(
        find.textContaining('Damaged in transit'),
        findsOneWidget,
      );
      // The requester sees no Approve button — only the waiting note.
      expect(find.textContaining('Waiting for an approver'), findsOneWidget);
      expect(find.text('Approve'), findsNothing);
      // A different Owner approves.
      auth.user = _userFor('owner', uid: 'test-owner-2');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      final approveKey = ValueKey(
        'adjustment-approve-${container.read(stockAdjustmentQueueProvider).first.id}',
      );
      await tester.ensureVisible(find.byKey(approveKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(approveKey));
      await tester.pumpAndSettle();
      expect(find.textContaining('Adjustment approved'), findsOneWidget);
      expect(find.text('Approved'), findsWidgets);
      expect(
        (await container
                .read(inventoryRepositoryProvider)
                .getInventory(branchId: _dha))
            .firstWhere((item) => item.id == batch.id)
            .quantity,
        beforeQty - 2,
      );
    });

    testWidgets('queue screen gated for Cashier, open for Inventory Mgr',
        (tester) async {
      final (_, router) = await pumpRouterAppAsRole(
        tester,
        'Cashier',
        size: const Size(1024, 768),
      );
      router.go('/inventory/adjustments');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(find.text('Adjustment Approvals'), findsNothing);
      final (_, router2) = await pumpRouterAppAsRole(
        tester,
        'inventory_manager',
        size: const Size(1024, 768),
      );
      router2.go('/inventory/adjustments');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(find.text('Adjustment Approvals'), findsWidgets);
    });
  });

  group('Offline queue behaviour — Phase 8 (D143)', () {
    Future<SyncOperation> enqueueOp(
      SyncQueue queue,
      String key, {
      String entityType = 'sale',
    }) {
      return queue.enqueue(
        idempotencyKey: key,
        entityType: entityType,
        entityId: 'ent-$key',
        branchId: _dha,
        organizationId: _org,
        kind: SyncOperationKind.create,
        payload: {'path': 'sales/ent-$key'},
      );
    }

    test('enqueue while offline → held → flush on reconnect, no loss',
        () async {
      var now = DateTime(2026, 11, 26, 12, 0, 0);
      final queue = SyncQueue(
        InMemorySyncStore(),
        nowProvider: () => now,
      );
      await enqueueOp(queue, 'sale-offline-1');
      await enqueueOp(queue, 'adjust-offline-1', entityType: 'stockTransaction');
      expect((await queue.pendingOperations()).length, 2);
      expect(queue.lastSyncedAt, isNull);

      // Offline: the sender reports "not synced". `processAll`
      // stops at the first failure (by design — one attempt per op
      // per call while sends succeed, stop on failure), so the
      // first op is backing off and the second is still due — but
      // NEITHER is lost: the store still holds both.
      final offline = await queue.processAll((_) async => false);
      expect(offline, 0);
      expect((await queue.store.all()).length, 2);
      expect((await queue.pendingOperations()).length, 1);
      expect(queue.lastSyncedAt, isNull);

      // Past the back-off both are due again; a throwing sender
      // behaves the same way — still nothing lost.
      now = now.add(const Duration(seconds: 10));
      expect((await queue.pendingOperations()).length, 2);
      final throwing = await queue.processAll(
        (_) async => throw Exception('No connection'),
      );
      expect(throwing, 0);
      expect((await queue.store.all()).length, 2);

      // Reconnect after the back-off: both flush, each sent once.
      now = now.add(const Duration(seconds: 10));
      final sent = <String>[];
      final flushed = await queue.processAll((op) async {
        sent.add(op.idempotencyKey);
        return true;
      });
      expect(flushed, 2);
      expect(sent, ['sale-offline-1', 'adjust-offline-1']);
      expect((await queue.pendingOperations()).length, 0);
      expect(await queue.pendingCount(), 0);
      expect(queue.lastSyncedAt, now);

      // A second flush sends nothing — no double-send on retry.
      final again = await queue.processAll((op) async {
        sent.add(op.idempotencyKey);
        return true;
      });
      expect(again, 0);
      expect(sent, hasLength(2));
    });

    test('same idempotency key enqueued twice stores one operation',
        () async {
      final queue = SyncQueue(InMemorySyncStore());
      final first = await enqueueOp(queue, 'sale-dedupe-1');
      final second = await enqueueOp(queue, 'sale-dedupe-1');
      expect(second.idempotencyKey, first.idempotencyKey);
      expect((await queue.store.all()).length, 1);
      expect((await queue.pendingOperations()).length, 1);
    });

    test('layer writes while offline are held, then flushed', () async {
      final layer = _layer();
      final batch = (await layer.inventoryRepo.getInventory(
        branchId: _dha,
      )).firstWhere(
        (item) => item.medicineId == 'med-panadol-extra',
      );
      // The layer enqueues the sync payload at write time — no
      // transport is involved, so the write "works offline".
      await layer.adjustStock(
        batchId: batch.id,
        deltaQty: 2,
        reason: 'Found on shelf',
      );
      expect(await layer.syncQueue.pendingCount(), 1);
      expect(layer.lastSyncAt, isNull);
      final sent = <String>[];
      final flushed = await layer.syncQueue.processAll((op) async {
        sent.add(op.idempotencyKey);
        return true;
      });
      expect(flushed, 1);
      expect(sent, hasLength(1));
      expect(await layer.syncQueue.pendingCount(), 0);
      expect(layer.lastSyncAt, isNotNull);
    });

    testWidgets('sync chip reflects pending → synced', (tester) async {
      final layer = _layer();
      await enqueueOp(layer.syncQueue, 'sale-chip-1');
      final (container, router) = await pumpRouterApp(
        tester,
        size: _phoneSize,
        layerOverride: layer,
        user: _userFor('owner'),
      );
      router.go('/orders');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(find.textContaining('1 pending sync'), findsOneWidget);
      // Reconnect: flush the queue, refresh the chip.
      await layer.syncQueue.processAll((_) async => true);
      container.invalidate(syncStatusProvider);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      // The chip renders the combined label ("All synced • Last
      // sync HH:MM"), so this is a substring match.
      expect(find.textContaining('All synced'), findsOneWidget);
    });
  });

  group('Role gates — SRS §5.1 matrix (D144)', () {
    // Route → a header text that only the rendered screen shows.
    // The expected outcome comes from the matrix itself
    // (`routeCapability` + `canInBranch`): the test pins the
    // WIRING — that each route's gate follows the matrix — not a
    // second copy of the matrix. `/riders` has no capability
    // mapping, so every role reaches it (D121).
    const routes = <(String, String)>[
      ('/inventory/transfers', 'Stock Transfers'),
      ('/riders', 'Riders & Delivery'),
      ('/finance/cashbook', 'Cashbook'),
      ('/finance/aging', 'Payables & Receivables'),
      ('/finance/statements', 'P&L & Statements'),
      ('/branches', 'Branch Management'),
      ('/audit-log', 'Audit Log'),
      ('/backup', 'Backup & Restore'),
      ('/inventory/adjustments', 'Adjustment Approvals'),
      ('/billing', 'Billing & POS'),
      ('/medicines', 'Medicines'),
      ('/staff/salary', 'Salary'),
      ('/purchases', 'Purchases'),
      ('/reports', 'Reports'),
      ('/customers', 'Customers'),
      ('/suppliers', 'Suppliers'),
    ];

    for (final roleKey in srsRoleKeys) {
      testWidgets('role $roleKey reaches exactly its matrix routes',
          (tester) async {
        final user = _userFor(roleKey);
        final (_, router) = await pumpRouterAppAsRole(
          tester,
          roleKey,
          size: const Size(1280, 800),
        );
        for (final (route, marker) in routes) {
          final capability = routeCapability(route);
          final allowed = capability == null ||
              permissionService.canInBranch(user, capability, _dha);
          router.go(route);
          await tester.pump(const Duration(milliseconds: 400));
          await tester.pumpAndSettle();
          if (allowed) {
            expect(
              find.textContaining('No permission for'),
              findsNothing,
              reason: '$roleKey should reach $route',
            );
            expect(
              find.text(marker),
              findsWidgets,
              reason: '$roleKey should see $marker on $route',
            );
          } else {
            expect(
              find.textContaining('No permission for'),
              findsWidgets,
              reason: '$roleKey should be gated from $route',
            );
          }
        }
      });
    }

    test('matrix spot checks: Cashier, Auditor, Inventory Mgr', () {
      // Hard-coded pins for the roles most likely to regress —
      // the loop above already covers all ten, these name the
      // decisions a reader cares about.
      final cashier = _userFor('cashier');
      expect(
        permissionService.canInBranch(cashier, 'sysSettings', _dha),
        isFalse,
      );
      expect(
        permissionService.canInBranch(cashier, 'stockAdjustReq', _dha),
        isFalse,
      );
      expect(
        permissionService.canInBranch(cashier, 'posSell', _dha),
        isTrue,
      );
      final auditor = _userFor('auditor');
      // Read-only still views (the gate is a view gate).
      expect(
        permissionService.canInBranch(auditor, 'auditLog', _dha),
        isTrue,
      );
      expect(
        permissionService.canWrite(auditor, 'auditLog', _dha),
        isFalse,
      );
      final inventoryMgr = _userFor('inventory_manager');
      expect(
        permissionService.canInBranch(
          inventoryMgr,
          'stockAdjustReq',
          _dha,
        ),
        isTrue,
      );
      expect(
        permissionService.canWrite(
          inventoryMgr,
          'stockAdjustApprove',
          _dha,
        ),
        isFalse,
      );
      // …but not in a branch outside their own.
      expect(
        permissionService.canInBranch(
          inventoryMgr,
          'stockAdjustReq',
          'branch-demo-gulberg',
        ),
        isFalse,
      );
    });
  });

  group('Cashbook layer writes — D129 closed (D145)', () {
    test('recordExpense: expense + mirror + one sync op, idempotent',
        () async {
      final layer = _layer();
      final created = await layer.recordExpense(
        branchId: _dha,
        category: 'Utilities',
        amountMinor: 500000,
        description: 'Electricity bill',
        expenseDate: DateTime(2026, 11, 26),
        createdBy: 'test-owner',
        idempotencyKey: 'finance-expense-test-1',
      );
      expect(created.id, isNotEmpty);
      expect(created.amountMinor, 500000);
      final expenses = await layer.expenseRepo.getExpenses(branchId: _dha);
      expect(
        expenses.where((e) => e.id == created.id),
        hasLength(1),
      );
      final mirrors = await layer.financialTransactionRepo.getTransactions(
        branchId: _dha,
      );
      final mirror = mirrors.where(
        (t) => t.referenceType == 'expense' && t.referenceId == created.id,
      );
      expect(mirror, hasLength(1));
      expect(mirror.first.amountMinor, -500000);
      expect(await layer.syncQueue.pendingCount(), 1);
      // Retry with the same key: same expense, nothing more written.
      final retry = await layer.recordExpense(
        branchId: _dha,
        category: 'Utilities',
        amountMinor: 500000,
        description: 'Electricity bill',
        expenseDate: DateTime(2026, 11, 26),
        createdBy: 'test-owner',
        idempotencyKey: 'finance-expense-test-1',
      );
      expect(retry.id, created.id);
      expect(
        (await layer.expenseRepo.getExpenses(branchId: _dha))
            .where((e) => e.description == 'Electricity bill')
            .length,
        1,
      );
      expect(await layer.syncQueue.pendingCount(), 1);
    });

    test('recordIncome: one transaction + one sync op, idempotent',
        () async {
      final layer = _layer();
      final created = await layer.recordIncome(
        branchId: _dha,
        category: 'Other income',
        amountMinor: 250000,
        date: DateTime(2026, 11, 26),
        createdBy: 'test-owner',
        idempotencyKey: 'finance-income-test-1',
      );
      expect(created.amountMinor, 250000);
      expect(created.type.name, 'income');
      expect(await layer.syncQueue.pendingCount(), 1);
      final retry = await layer.recordIncome(
        branchId: _dha,
        category: 'Other income',
        amountMinor: 250000,
        date: DateTime(2026, 11, 26),
        createdBy: 'test-owner',
        idempotencyKey: 'finance-income-test-1',
      );
      expect(retry.id, created.id);
      expect(await layer.syncQueue.pendingCount(), 1);
    });

    test('recordDailyClosing: one closing + one sync op, idempotent',
        () async {
      final layer = _layer();
      final closing = DailyClosing(
        id: '',
        branchId: _dha,
        date: DateTime(2026, 11, 26),
        totalIncomeMinor: 1000000,
        totalExpenseMinor: 400000,
        openingBalanceMinor: 200000,
        closingBalanceMinor: 800000,
        closedBy: 'test-owner',
        closedAt: DateTime(2026, 11, 26, 20, 0),
        note: 'Day close',
      );
      final created = await layer.recordDailyClosing(
        closing: closing,
        idempotencyKey: 'finance-closing-test-1',
      );
      expect(created.id, isNotEmpty);
      expect(created.closingBalanceMinor, 800000);
      expect(await layer.syncQueue.pendingCount(), 1);
      final retry = await layer.recordDailyClosing(
        closing: closing,
        idempotencyKey: 'finance-closing-test-1',
      );
      expect(retry.id, created.id);
      expect(await layer.syncQueue.pendingCount(), 1);
    });

    test('expenses notifier routes through the layer (sync enqueued)',
        () async {
      final container = ProviderContainer(
        overrides: [
          authProvider.overrideWith(
            () => _FixedAuthNotifier(_userFor('owner')),
          ),
        ],
      );
      addTearDown(container.dispose);
      final layer = container.read(productionDataLayerProvider);
      final result = await container
          .read(expensesProvider.notifier)
          .recordExpense(
            branchId: _dha,
            category: 'Utilities',
            amountMinor: 150000,
            description: 'Water bill',
            expenseDate: DateTime(2026, 11, 26),
          );
      expect(result.error, isNull);
      expect(result.expense, isNotNull);
      expect(await layer.syncQueue.pendingCount(), 1);
      final expenses = await container.read(expensesProvider.future);
      expect(
        expenses.any((e) => e.id == result.expense!.id),
        isTrue,
      );
    });

    testWidgets('cashbook screen shows the sync chip', (tester) async {
      final layer = _layer();
      await layer.recordExpense(
        branchId: _dha,
        category: 'Utilities',
        amountMinor: 500000,
        description: 'Electricity bill',
        expenseDate: DateTime(2026, 11, 26),
        createdBy: 'test-owner',
        idempotencyKey: 'finance-expense-chip-1',
      );
      final (_, router) = await pumpRouterApp(
        tester,
        size: _phoneSize,
        layerOverride: layer,
        user: _userFor('owner'),
      );
      router.go('/finance/cashbook');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(find.text('Cashbook'), findsOneWidget);
      expect(find.textContaining('1 pending sync'), findsOneWidget);
    });
  });

  group('390px sweep — Day 1 findings fixed (D142)', () {
    // The detail route is swept too: its badge Row overflowed by
    // 162px at 390px until this day (D142).
    for (final route in [
      '/dashboard',
      '/orders',
      '/billing',
      '/inventory',
      '/medicines/med-panadol-extra',
    ]) {
      testWidgets('$route body fits at 390px — no RenderFlex overflow',
          (WidgetTester tester) async {
        final (_, router) = await pumpRouterAppAsRole(
          tester,
          'Owner',
          size: _phoneSize,
        );
        // The pump lands on /dashboard: drain its exceptions first
        // so each route's findings are its own.
        drainExceptions(tester);
        router.go(route);
        await tester.pump(const Duration(milliseconds: 1500));
        await tester.pumpAndSettle();
        final findings = drainExceptions(tester);
        final overflowCount = countOverflows(findings);
        expect(
          overflowCount,
          0,
          reason: '$route still overflows at 390px '
              '($overflowCount RenderFlex overflow(s)): '
              '${findings.join('\n').split('\n').where((m) => m.contains('overflowed by')).take(5).join('; ')}',
        );
      });
    }
  });
}
