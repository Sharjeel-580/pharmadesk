// Week 8 Day 1 tests — SRS acceptance checklist, formal pass (D176).
//
// Verifies the eight §8.4 demo acceptance criteria on the final tree,
// one by one, plus §9 production-scope evidence where a test can carry
// it (branch comparison, offline sync enqueue, rules-draft status).
// Criterion 8 (client feedback recorded; scope freeze signed) has NO
// test — it needs the client (Phase 5), so it is BLOCKED-CLIENT in
// `docs/day-38-progress.md`, never claimed here.
//
// Evidence style: every PASS below names the concrete check. The
// seeded figures re-pinned here (DHA today sales Rs 6,990.00 vs
// Gulberg Rs 5,210.00, 491 orders, FEFO picks, dispatch-guard links)
// were verified in Week 7 Day 5 (D175) and are re-pinned, not
// re-derived, so a later change cannot silently move the demo.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharmadesk/app/pharmadesk_app.dart';
import 'package:pharmadesk/core/data/production_data_layer.dart';
import 'package:pharmadesk/core/services/branch_context.dart';
import 'package:pharmadesk/core/services/repositories.dart';
import 'package:pharmadesk/core/utils/money.dart';
import 'package:pharmadesk/core/widgets/buttons.dart';
import 'package:pharmadesk/core/widgets/section_header.dart';
import 'package:pharmadesk/features/authentication/auth_state.dart';
import 'package:pharmadesk/features/billing/barcode_scanner.dart';
import 'package:pharmadesk/features/billing/billing_logic.dart';
import 'package:pharmadesk/features/billing/billing_provider.dart';
import 'package:pharmadesk/features/dashboard/dashboard_data.dart';
import 'package:pharmadesk/features/dashboard/owner_dashboard_data.dart';
import 'package:pharmadesk/features/inventory/inventory_logic.dart';
import 'package:pharmadesk/features/orders/order_logic.dart';
import 'package:pharmadesk/features/orders/orders_provider.dart';
import 'package:pharmadesk/features/reports/reports_logic.dart';
import 'package:pharmadesk/models/customer_ledger.dart';
import 'package:pharmadesk/models/inventory_item.dart';
import 'package:pharmadesk/models/order.dart';
import 'package:pharmadesk/models/prescription.dart';
import 'package:pharmadesk/models/sale.dart';

import 'test_helpers.dart';
import 'week7_day04_test.dart';

const _dha = 'branch-dha-main';
const _glb = 'branch-demo-gulberg';

InventoryItem _batch({
  required String id,
  required String medicineId,
  required String branchId,
  required int quantity,
  DateTime? expiry,
  String batchNo = 'B-1',
  BatchStatus status = BatchStatus.available,
}) {
  return InventoryItem(
    id: id,
    medicineId: medicineId,
    branchId: branchId,
    quantity: quantity,
    lowStockThreshold: 10,
    expiryDate: expiry,
    batchNo: batchNo,
    costMinor: 5000,
    status: status,
  );
}

/// The D170 corrected-trap shape (copied, not imported — the Day 36
/// trap is private to its file): counts DISTINCT RenderFlex overflow
/// messages as the handler sees them. Every widget figure in this
/// file states its trap.
class _D38OverflowTrap {
  _D38OverflowTrap() : _previous = FlutterError.onError {
    FlutterError.onError = (details) {
      _seen.add(details.toString());
      _previous?.call(details);
    };
  }

  final dynamic _previous;
  final _seen = <String>[];

  int get overflowCount {
    var count = 0;
    final distinct = <String>{
      for (final message in _seen)
        if (message.contains('RenderFlex overflowed')) message,
    };
    for (final message in distinct) {
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

  void dispose() {
    FlutterError.onError = _previous;
  }
}

Future<Order> _readOrder(ProviderContainer container, String id) async {
  final orders = await container.read(orderRepositoryProvider).getOrders();
  return orders.firstWhere((order) => order.id == id);
}

void main() {
  group('§8.4 criterion 1 — login as Owner and as Cashier (demo1234)', () {
    test('owner and cashier sign in with the demo credentials', () async {
      final cases = <(DemoRole, String, String?, String)>[
        (DemoRole.owner, 'Hassan Raza', null, 'owner'),
        (DemoRole.cashier, 'Usman Tariq', _glb, 'cashier'),
      ];
      for (final (role, name, branchId, roleKey) in cases) {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final error = await container
            .read(authProvider.notifier)
            .signIn(role.email, demoPassword);
        expect(error, isNull, reason: '${role.label} sign-in');
        final user = container.read(authProvider);
        expect(user, isNotNull, reason: role.label);
        expect(user!.demoRole, role);
        expect(user.roleKey, roleKey);
        expect(user.name, name);
        expect(user.branchId, branchId);
      }
    });

    testWidgets('typed owner login opens the owner dashboard', (
      tester,
    ) async {
      await pumpAppToLogin(tester, const PharmaDeskApp());
      await tester.enterText(
        find.byType(TextFormField).first,
        'owner@demo.pharmadesk',
      );
      await tester.enterText(find.byType(TextFormField).last, 'demo1234');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      expect(find.text('Owner dashboard'), findsOneWidget);
    });
  });

  group('§8.4 criterion 2 — full sale: scan → pay → receipt', () {
    test('scan → FEFO allocate → completeSale → receipt (cashier, Gulberg)',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(authProvider.notifier).signInAsDemo(
        DemoRole.cashier,
      );
      final inventory = await container
          .read(inventoryRepositoryProvider)
          .getInventory(branchId: _glb);
      final medicines = await container
          .read(medicineRepositoryProvider)
          .getMedicines();
      final batchesByMedicine = groupBatchesByMedicine(inventory);

      // Scan: the seeded Panadol Extra barcode resolves to the FEFO
      // batch (earliest-expiry sellable) for Gulberg.
      final scan = scanBarcode(
        medicines: medicines,
        batchesByMedicine: batchesByMedicine,
        code: '8901000000001',
      );
      expect(scan.outcome, BarcodeScanOutcome.found);
      expect(scan.medicine?.name, 'Panadol Extra');
      expect(scan.fefoBatch, isNotNull);
      final fefoBatch = scan.fefoBatch!;
      final stockBefore = inventory
          .firstWhere((item) => item.id == fefoBatch.id)
          .quantity;

      // Pay: cash, Rs 1,000 handed over.
      final medicine = scan.medicine!;
      final result = await container.read(salesProvider.notifier).completeSale(
        branchId: _glb,
        cashierName: 'Usman Tariq',
        lines: [
          CartLine(
            medicineId: medicine.id,
            medicineName: medicine.name,
            unitPriceMinor: medicine.priceMinor,
            quantity: 2,
          ),
        ],
        paymentMethod: SalePaymentMethod.cash,
        cashReceivedMinor: 100000,
      );
      expect(result.error, isNull, reason: result.error);
      final sale = result.sale!;
      expect(sale.invoiceNumber, isNotEmpty);
      expect(sale.branchId, _glb);
      expect(sale.totalMinor, greaterThan(0));
      expect(sale.cashierName, 'Usman Tariq');
      // The sale line carries the FEFO batch the scan picked.
      expect(sale.items.first.batchId, fefoBatch.id);
      // Stock moved on exactly that batch.
      final after = await container
          .read(inventoryRepositoryProvider)
          .getInventory(branchId: _glb);
      expect(
        after.firstWhere((item) => item.id == fefoBatch.id).quantity,
        stockBefore - 2,
      );
      // The sale is saved and listed.
      final saved = await container.read(saleRepositoryProvider).getSales();
      expect(saved.any((s) => s.id == sale.id), isTrue);

      // Receipt: the plain-text receipt carries the invoice number,
      // the branch and the total.
      final receipt = receiptText(
        sale: sale,
        branchName: 'Demo Branch — Gulberg',
        branchAddress: 'Main Boulevard, Gulberg, Lahore',
        brandHeader: 'PharmaDesk',
      );
      expect(receipt, contains(sale.invoiceNumber));
      expect(receipt, contains('Demo Branch — Gulberg'));
      expect(receipt, contains(formatPkr(sale.totalMinor)));
    });

    testWidgets('desktop POS completes a card sale and opens the receipt',
        (tester) async {
      final trap = _D38OverflowTrap();
      addTearDown(trap.dispose);
      final (container, router) = await pumpRouterAppAsRole(
        tester,
        'cashier',
        branchIds: [_glb],
        size: const Size(1440, 900),
      );
      // The harness injects the user without the sign-in flow, so
      // the active branch is still the default (DHA) — a Gulberg
      // cashier cannot use it (FeatureGate capability check). Real
      // sign-in switches to the user's home branch (auth_state.dart);
      // mirror that here.
      expect(
        container.read(activeBranchProvider.notifier).switchTo(_glb),
        isTrue,
      );
      router.go('/billing');
      await tester.pumpAndSettle();
      expect(find.text('Simulate scan'), findsOneWidget);
      // Empty cart: Complete Sale is disabled (a dead end would be a
      // button that looks live and does nothing — this one is honest).
      expect(
        tester
            .widget<PharmaButton>(
              find.widgetWithText(PharmaButton, 'Complete Sale'),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const ValueKey('pos-simulate-scan')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<PharmaButton>(
              find.widgetWithText(PharmaButton, 'Complete Sale'),
            )
            .onPressed,
        isNotNull,
      );
      // Card avoids the cash-received field: the pay step is one tap.
      await tester.ensureVisible(
        find.descendant(
          of: find.byKey(const ValueKey('pos-payment-methods')),
          matching: find.text('Card'),
        ),
      );
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('pos-payment-methods')),
          matching: find.text('Card'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.widgetWithText(PharmaButton, 'Complete Sale'),
      );
      await tester.tap(find.widgetWithText(PharmaButton, 'Complete Sale'));
      await tester.pumpAndSettle();
      // Receipt screen: invoice row + receipt title.
      expect(find.text('Invoice'), findsOneWidget);
      expect(find.textContaining('Receipt'), findsWidgets);
      final sales = await container.read(saleRepositoryProvider).getSales();
      final latest = sales.last;
      expect(
        find.text('Receipt ${latest.invoiceNumber}'),
        findsOneWidget,
      );
      expect(trap.overflowCount, 0);
    });

    testWidgets('mobile POS completes a card sale at 390px', (tester) async {
      final trap = _D38OverflowTrap();
      addTearDown(trap.dispose);
      final (container, router) = await pumpRouterAppAsRole(
        tester,
        'cashier',
        branchIds: [_glb],
        size: const Size(390, 844),
      );
      // Same sign-in mirror as the desktop POS test: the harness
      // leaves the default DHA active, which a Gulberg cashier
      // cannot use.
      expect(
        container.read(activeBranchProvider.notifier).switchTo(_glb),
        isTrue,
      );
      router.go('/billing');
      await tester.pumpAndSettle();
      expect(find.text('Simulate scan'), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const ValueKey('pos-simulate-scan')),
      );
      await tester.tap(find.byKey(const ValueKey('pos-simulate-scan')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.descendant(
          of: find.byKey(const ValueKey('pos-payment-methods')),
          matching: find.text('Card'),
        ),
      );
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('pos-payment-methods')),
          matching: find.text('Card'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.widgetWithText(PharmaButton, 'Complete Sale'),
      );
      await tester.tap(find.widgetWithText(PharmaButton, 'Complete Sale'));
      await tester.pumpAndSettle();
      expect(find.text('Invoice'), findsOneWidget);
      final sales = await container.read(saleRepositoryProvider).getSales();
      expect(
        find.text('Receipt ${sales.last.invoiceNumber}'),
        findsOneWidget,
      );
      expect(trap.overflowCount, 0);
    });
  });

  group('§8.4 criterion 3 — FEFO in action, expired batch blocked', () {
    test('seeded FEFO picks the earliest-expiry batch (Panadol Extra, DHA)',
        () async {
      final inventory = await MockInventoryRepository().getInventory();
      final now = DateTime.now();
      final dhaBatches = groupBatchesByMedicine(
        inventory.where((i) => i.branchId == _dha),
      );
      // The pick is named by batch NUMBER (Day 37 pin): the May 2027
      // batch expires first. (The row id is a mock id, not the number.)
      final panadol = dhaBatches['med-panadol-extra']!;
      expect(fefoBatchFor(panadol, now: now)?.batchNo, 'DHA-1-2-173');
      final risek = dhaBatches['med-risek-20']!;
      expect(fefoBatchFor(risek, now: now)?.batchNo, 'DHA-3-2-863');
    });

    test(
      'expired-only medicine: scan refuses, allocation throws, sale saves nothing',
      () async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        await container.read(authProvider.notifier).signInAsDemo(
          DemoRole.cashier,
        );
        final inventory = await container
            .read(inventoryRepositoryProvider)
            .getInventory(branchId: _dha);
        final medicines = await container
            .read(medicineRepositoryProvider)
            .getMedicines();
        final batchesByMedicine = groupBatchesByMedicine(inventory);
        // Levaquin (med-gen-021) is seeded at DHA with exactly one
        // batch, expired, with stock on hand — the demo guide's
        // "try adding a medicine whose only batches are expired".
        final scan = scanBarcode(
          medicines: medicines,
          batchesByMedicine: batchesByMedicine,
          code: '8902000000020',
        );
        expect(scan.outcome, BarcodeScanOutcome.notSellable);
        expect(scan.medicine?.name, 'Levaquin');
        expect(
          () => allocateFefo(
            lines: [
              CartLine(
                medicineId: 'med-gen-021',
                medicineName: 'Levaquin',
                unitPriceMinor: 10000,
                quantity: 1,
              ),
            ],
            batchesByMedicine: batchesByMedicine,
          ),
          throwsArgumentError,
        );
        final salesBefore = await container
            .read(saleRepositoryProvider)
            .getSales();
        final result = await container
            .read(salesProvider.notifier)
            .completeSale(
              branchId: _dha,
              cashierName: 'Usman Tariq',
              lines: [
                CartLine(
                  medicineId: 'med-gen-021',
                  medicineName: 'Levaquin',
                  unitPriceMinor: 10000,
                  quantity: 1,
                ),
              ],
              paymentMethod: SalePaymentMethod.cash,
              cashReceivedMinor: 10000,
            );
        expect(result.sale, isNull);
        expect(result.error, contains('only 0 unit(s) sellable'));
        final salesAfter = await container
            .read(saleRepositoryProvider)
            .getSales();
        expect(salesAfter.length, salesBefore.length);
      },
    );

    test('an expired batch is never picked even with the earliest expiry',
        () {
      final now = DateTime(2026, 11, 26);
      final batches = [
        _batch(
          id: 'b-expired-first',
          medicineId: 'med-x',
          branchId: _dha,
          quantity: 10,
          expiry: DateTime(2026, 10, 1),
          batchNo: 'EXP-1',
        ),
        _batch(
          id: 'b-valid-second',
          medicineId: 'med-x',
          branchId: _dha,
          quantity: 10,
          expiry: DateTime(2027, 3, 1),
          batchNo: 'VAL-1',
        ),
      ];
      expect(fefoBatchFor(batches, now: now)?.id, 'b-valid-second');
      expect(isBatchSellable(batches.first, now: now), isFalse);
      // Ordering is separate from the guard: `fefoBatches` lists
      // earliest-expiry first (expired included); only the pick
      // (`fefoBatchFor`) skips the expired row.
      expect(
        fefoBatches(batches).map((b) => b.id).toList(),
        ['b-expired-first', 'b-valid-second'],
      );
    });
  });

  group('§8.4 criterion 4 — branch switching changes stock/sales', () {
    test('dashboard KPIs differ on every figure, DHA busier (Day 37 pin)',
        () async {
      final orders = await MockOrderRepository().getOrders();
      final inventory = await MockInventoryRepository().getInventory();
      final sales = await MockSaleRepository().getSales();
      final rxRepo = MockPrescriptionRepository();
      Future<DashboardKpis> kpis(String branchId) async {
        final rx = await rxRepo.getPrescriptions(branchId: branchId);
        return computeDashboardKpis(
          orders: orders,
          inventory: inventory,
          prescriptions: rx,
          sales: sales,
          branchId: branchId,
          now: DateTime.now(),
        );
      }

      final dha = await kpis(_dha);
      final glb = await kpis(_glb);
      expect(dha.todaySalesMinor, 699000);
      expect(glb.todaySalesMinor, 521000);
      expect(dha.todayOrders, 7);
      expect(glb.todayOrders, 5);
      expect(dha.revenue30dMinor, 49448000);
      expect(glb.revenue30dMinor, 27198000);
      expect(dha.orders30d, 284);
      expect(glb.orders30d, 152);
      expect(dha.lowStockCount, 74);
      expect(glb.lowStockCount, 72);
      expect(dha.nearExpiryCount, 129);
      expect(glb.nearExpiryCount, 147);
      expect(dha.expiredCount, 30);
      expect(glb.expiredCount, 29);
      expect(dha.pendingPrescriptions, 2);
      expect(glb.pendingPrescriptions, 4);
    });

    test('orders and reports are branch-scoped', () async {
      final orders = await MockOrderRepository().getOrders();
      final inventory = await MockInventoryRepository().getInventory();
      final sales = await MockSaleRepository().getSales();
      final now = DateTime.now();
      expect(
        filterOrders(orders: orders, branchId: _dha),
        hasLength(319),
      );
      expect(
        filterOrders(orders: orders, branchId: _glb),
        hasLength(172),
      );
      final dha = computeReports(
        orders: orders,
        sales: sales,
        inventory: inventory,
        branchId: _dha,
        now: now,
        days: 30,
      );
      final glb = computeReports(
        orders: orders,
        sales: sales,
        inventory: inventory,
        branchId: _glb,
        now: now,
        days: 30,
      );
      expect(dha.totalSalesMinor, isNot(glb.totalSalesMinor));
      expect(dha.totalOrders, isNot(glb.totalOrders));
      expect(dha.stockValuationMinor, isNot(glb.stockValuationMinor));
      expect(
        dha.dailySales.map((d) => d.salesMinor).toList(),
        isNot(glb.dailySales.map((d) => d.salesMinor).toList()),
      );
    });
  });

  group('§8.4 criterion 5 — daily sales report and export', () {
    test('daily report for today: DHA 7 orders / Rs 6,990.00, Gulberg 5 / '
        'Rs 5,210.00', () async {
      final orders = await MockOrderRepository().getOrders();
      final inventory = await MockInventoryRepository().getInventory();
      final sales = await MockSaleRepository().getSales();
      final now = DateTime.now();
      final dha = computeReports(
        orders: orders,
        sales: sales,
        inventory: inventory,
        branchId: _dha,
        now: now,
        days: 1,
      );
      expect(dha.totalOrders, 7);
      expect(dha.totalSalesMinor, 699000);
      expect(dha.dailySales, hasLength(1));
      expect(dha.dailySales.single.orders, 7);
      expect(dha.dailySales.single.salesMinor, 699000);
      final glb = computeReports(
        orders: orders,
        sales: sales,
        inventory: inventory,
        branchId: _glb,
        now: now,
        days: 1,
      );
      expect(glb.totalOrders, 5);
      expect(glb.totalSalesMinor, 521000);
    });

    test('daily sales CSV exports the report rows', () async {
      final orders = await MockOrderRepository().getOrders();
      final inventory = await MockInventoryRepository().getInventory();
      final sales = await MockSaleRepository().getSales();
      final now = DateTime.now();
      final dha = computeReports(
        orders: orders,
        sales: sales,
        inventory: inventory,
        branchId: _dha,
        now: now,
        days: 1,
      );
      final csv = dailySalesCsv(dha.dailySales);
      expect(csv, startsWith('Date,Orders,Sales (Rs)\n'));
      final today =
          '${now.year}-${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')}';
      expect(csv, contains('$today,7,6990.00'));
      expect(
        bestSellersCsv(dha.bestSellers),
        startsWith('Medicine,Quantity sold,Revenue (Rs)\n'),
      );
    });

    test('sales report PDF is real PDF bytes', () async {
      final orders = await MockOrderRepository().getOrders();
      final inventory = await MockInventoryRepository().getInventory();
      final sales = await MockSaleRepository().getSales();
      final data = computeReports(
        orders: orders,
        sales: sales,
        inventory: inventory,
        branchId: _dha,
        now: DateTime.now(),
        days: 30,
      );
      final pdf = await buildSalesReportPdf(
        data: data,
        branchName: 'Demo Branch — DHA',
        days: 30,
      );
      expect(pdf.lengthInBytes, greaterThan(1000));
      expect(pdf.sublist(0, 4), [0x25, 0x50, 0x44, 0x46]); // %PDF
    });

    testWidgets('reports screen offers wired Export PDF and Export CSV '
        'actions', (tester) async {
      final (_, router) = await pumpRouterAppAsRole(
        tester,
        'owner',
        size: const Size(1280, 800),
      );
      router.go('/reports');
      await tester.pumpAndSettle();
      final headers = tester
          .widgetList<SectionHeader>(find.byType(SectionHeader))
          .toList();
      final pdfActions = headers
          .where((header) => header.actionLabel == 'Export PDF')
          .toList();
      expect(pdfActions, hasLength(1));
      expect(pdfActions.single.onAction, isNotNull);
      final csvActions = headers
          .where((header) => header.actionLabel == 'Export CSV')
          .toList();
      expect(csvActions, isNotEmpty);
      expect(csvActions.every((header) => header.onAction != null), isTrue);
    });
  });

  group('§8.4 criterion 6 — WhatsApp order through the full status flow',
      () {
    test('WhatsApp order walks New → Delivered with a rider assigned',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(authProvider.notifier).signInAsDemo(
        DemoRole.owner,
      );
      final queue = container.read(orderQueueProvider.notifier);
      final customers = await container
          .read(customerRepositoryProvider)
          .getCustomers();
      final medicine = await container
          .read(medicineRepositoryProvider)
          .getById('med-panadol-extra');
      expect(medicine, isNotNull);
      final created = await queue.createOrder(
        Order(
          id: '',
          customerId: customers.first.id,
          branchId: _dha,
          items: [
            OrderItem(
              medicineId: medicine!.id,
              medicineName: medicine.name,
              quantity: 2,
              unitPrice: medicine.priceMinor / 100,
            ),
          ],
          deliveryAddress: 'House 12, Street 4, DHA Lahore',
          source: OrderSource.whatsapp,
          fulfillment: FulfillmentType.delivery,
          totalAmount: 2 * medicine.priceMinor / 100,
          status: OrderStatus.newOrder,
        ),
      );
      expect(created.id, isNotEmpty);
      expect(created.orderNumber, startsWith('ORD-DHA-'));
      expect(created.source, OrderSource.whatsapp);
      expect(created.status, OrderStatus.newOrder);

      var current = created;
      for (final expected in [
        OrderStatus.confirmed,
        OrderStatus.processing,
        OrderStatus.ready,
      ]) {
        expect(await queue.advanceOrder(current), isTrue);
        current = await _readOrder(container, current.id);
        expect(current.status, expected);
      }
      // Rider assigned at Ready, before dispatch (demo guide §6).
      expect(await queue.assignRider(current, 'rider-1'), isTrue);
      current = await _readOrder(container, current.id);
      expect(current.riderId, 'rider-1');
      for (final expected in [
        OrderStatus.dispatched,
        OrderStatus.delivered,
      ]) {
        expect(await queue.advanceOrder(current), isTrue);
        current = await _readOrder(container, current.id);
        expect(current.status, expected);
      }
      // Delivered is terminal — no further advance.
      expect(await queue.advanceOrder(current), isFalse);
    });

    test('prescription-linked order is still held at dispatch (guard pin)',
        () async {
      final orders = await MockOrderRepository().getOrders();
      final linked = orders.firstWhere((o) => o.id == 'ord-dha-1312');
      expect(linked.prescriptionId, 'rx-dha-1');
      expect(
        advanceBlockedReason(
          order: linked,
          next: OrderStatus.dispatched,
          linkedPrescriptionStatus: PrescriptionStatus.pending,
        ),
        contains('still pending pharmacist review'),
      );
      expect(
        advanceBlockedReason(
          order: linked,
          next: OrderStatus.dispatched,
          linkedPrescriptionStatus: PrescriptionStatus.approved,
        ),
        isNull,
      );
    });
  });

  group('§8.4 criterion 7 — no dead buttons in the demo walkthrough', () {
    testWidgets('demo-walkthrough routes resolve, no placeholder, no 404',
        (tester) async {
      final (_, router) = await pumpRouterAppAsRole(
        tester,
        'owner',
        size: const Size(1280, 800),
      );
      const routes = <(String, String)>[
        ('/dashboard', 'Owner dashboard'),
        ('/billing', 'Simulate scan'),
        ('/billing/history', 'Sales history'),
        ('/inventory', 'Inventory'),
        ('/orders', 'Orders'),
        ('/reports', 'Export PDF'),
        ('/finance', 'Finance'),
        ('/suppliers', 'Suppliers'),
        ('/purchases', 'Purchases'),
        ('/prescriptions', 'Prescriptions'),
        ('/customers', 'Customers'),
        ('/settings', 'Settings'),
        ('/branches', 'Branch Management'),
        ('/notifications', 'Notifications'),
      ];
      for (final (route, marker) in routes) {
        router.go(route);
        await tester.pumpAndSettle();
        expect(
          find.textContaining('coming Week 1'),
          findsNothing,
          reason: 'Placeholder left on $route',
        );
        expect(
          find.text('Page not found'),
          findsNothing,
          reason: 'Missing route $route',
        );
        expect(
          find.text(marker),
          findsWidgets,
          reason: '$route should render its screen ($marker)',
        );
      }
    });

    testWidgets('order detail advance button is wired and advances',
        (tester) async {
      final (container, router) = await pumpRouterAppAsRole(
        tester,
        'owner',
        size: const Size(1280, 800),
      );
      final queue = container.read(orderQueueProvider.notifier);
      final customers = await container
          .read(customerRepositoryProvider)
          .getCustomers();
      final medicine = await container
          .read(medicineRepositoryProvider)
          .getById('med-panadol-extra');
      final created = await queue.createOrder(
        Order(
          id: '',
          customerId: customers.first.id,
          branchId: _dha,
          items: [
            OrderItem(
              medicineId: medicine!.id,
              medicineName: medicine.name,
              quantity: 1,
              unitPrice: medicine.priceMinor / 100,
            ),
          ],
          deliveryAddress: 'House 12, Street 4, DHA Lahore',
          source: OrderSource.whatsapp,
          fulfillment: FulfillmentType.delivery,
          totalAmount: medicine.priceMinor / 100,
          status: OrderStatus.newOrder,
        ),
      );
      router.go('/orders/${created.id}');
      await tester.pumpAndSettle();
      final advance = find.widgetWithText(PharmaButton, 'Mark Confirmed');
      expect(advance, findsOneWidget);
      expect(
        tester.widget<PharmaButton>(advance).onPressed,
        isNotNull,
      );
      // The action row sits below the fold — scroll it into view
      // before tapping, or the tap misses (hit-test warning).
      await tester.ensureVisible(advance);
      await tester.tap(advance);
      await tester.pumpAndSettle();
      expect(
        find.widgetWithText(PharmaButton, 'Mark Processing'),
        findsOneWidget,
      );
      final stored = await _readOrder(container, created.id);
      expect(stored.status, OrderStatus.confirmed);
    });
  });

  group('§9 production-scope evidence (test-carried rows)', () {
    test('branch comparison covers both branches, DHA busier', () async {
      final orders = await MockOrderRepository().getOrders();
      final inventory = await MockInventoryRepository().getInventory();
      final sales = await MockSaleRepository().getSales();
      final prescriptions = await MockPrescriptionRepository()
          .getPrescriptions();
      final purchaseOrders = await MockPurchaseOrderRepository()
          .getPurchaseOrders();
      final customerRepo = MockCustomerRepository();
      final customers = await customerRepo.getCustomers();
      final ledgerEntries = <LedgerEntry>[];
      for (final customer in customers) {
        ledgerEntries.addAll(
          await customerRepo.getLedgerEntries(customer.id),
        );
      }
      final rows = computeBranchComparison(
        branches: demoBranches,
        orders: orders,
        sales: sales,
        inventory: inventory,
        prescriptions: prescriptions,
        purchaseOrders: purchaseOrders,
        ledgerEntries: ledgerEntries,
        now: DateTime.now(),
      );
      expect(rows.map((row) => row.branchId).toSet(), {_dha, _glb});
      final dha = rows.firstWhere((row) => row.branchId == _dha);
      final glb = rows.firstWhere((row) => row.branchId == _glb);
      expect(dha.todaySalesMinor, 699000);
      expect(glb.todaySalesMinor, 521000);
      expect(dha.todayOrders, 7);
      expect(glb.todayOrders, 5);
    });

    test('a completed sale enqueues exactly one sync op (offline leg)',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(authProvider.notifier).signInAsDemo(
        DemoRole.cashier,
      );
      final layer = container.read(productionDataLayerProvider);
      final before = await layer.pendingSyncCount();
      final inventory = await container
          .read(inventoryRepositoryProvider)
          .getInventory(branchId: _glb);
      final stocked = inventory.firstWhere(
        (item) => item.medicineId == 'med-panadol-extra' && item.quantity > 0,
      );
      final medicine = await container
          .read(medicineRepositoryProvider)
          .getById(stocked.medicineId);
      final result = await container.read(salesProvider.notifier).completeSale(
        branchId: _glb,
        cashierName: 'Usman Tariq',
        lines: [
          CartLine(
            medicineId: stocked.medicineId,
            medicineName: medicine?.name ?? stocked.medicineId,
            unitPriceMinor: medicine?.priceMinor ?? 12000,
            quantity: 1,
          ),
        ],
        paymentMethod: SalePaymentMethod.cash,
        cashReceivedMinor: 100000,
      );
      expect(result.sale, isNotNull, reason: result.error);
      expect(await layer.pendingSyncCount(), before + 1);
    });

    test('Firestore rules are draft-only; no Firebase project is configured',
        () {
      final rules = File('firebase/firestore.rules').readAsStringSync();
      expect(rules, contains('DRAFT ONLY'));
      expect(rules, contains('Branch isolation'));
      expect(rules, contains('custom claims'));
      expect(rules, contains('NOT deployed anywhere'));
      expect(File('firebase_options.dart').existsSync(), isFalse);
      expect(File('lib/firebase_options.dart').existsSync(), isFalse);
    });
  });
}
