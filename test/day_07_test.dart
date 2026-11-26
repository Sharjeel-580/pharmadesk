// PharmaDesk Day 7 tests — suppliers + purchases + prescriptions +
// reports + notifications + settings (branding, roles, features) + QA.
//
// Covers: supplier ledger math (computed outstanding, never stored),
// PO flow (create → approve → receive updates inventory + supplier
// ledger; guards), prescription review transitions + order unblock,
// report computations + CSV export + real PDF bytes, notification
// generation + read state, branding change re-rendering the shell,
// feature toggles hiding modules, and a full route walk (no dead
// screens, no placeholders left).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:pharmadesk/core/routing/app_router.dart';
import 'package:pharmadesk/core/services/demo_seed_data.dart';
import 'package:pharmadesk/core/services/repositories.dart';
import 'package:pharmadesk/core/theme/app_theme.dart';
import 'package:pharmadesk/core/theme/white_label.dart';
import 'package:pharmadesk/features/notifications/notifications_logic.dart';
import 'package:pharmadesk/features/notifications/notifications_provider.dart';
import 'package:pharmadesk/features/orders/order_logic.dart';
import 'package:pharmadesk/features/prescriptions/prescriptions_logic.dart';
import 'package:pharmadesk/features/prescriptions/prescriptions_provider.dart';
import 'package:pharmadesk/features/purchases/purchases_logic.dart';
import 'package:pharmadesk/features/purchases/purchases_provider.dart';
import 'package:pharmadesk/features/reports/reports_logic.dart';
import 'package:pharmadesk/features/reports/reports_provider.dart';
import 'package:pharmadesk/features/settings/feature_config.dart';
import 'package:pharmadesk/features/settings/roles_permissions.dart';
import 'package:pharmadesk/features/suppliers/supplier_logic.dart';
import 'package:pharmadesk/models/order.dart';
import 'package:pharmadesk/models/prescription.dart';
import 'package:pharmadesk/models/purchase_order.dart';
import 'package:pharmadesk/models/supplier.dart';
import 'package:pharmadesk/models/supplier_ledger.dart';

PurchaseOrderItem _poItem({
  String medicineId = 'med-panadol-extra',
  String medicineName = 'Panadol Extra',
  int quantityOrdered = 10,
  int quantityReceived = 0,
  int unitCostMinor = 10000,
}) => PurchaseOrderItem(
  medicineId: medicineId,
  medicineName: medicineName,
  quantityOrdered: quantityOrdered,
  quantityReceived: quantityReceived,
  unitCostMinor: unitCostMinor,
);

/// Pumps the ungated router app with a fresh container the test owns,
/// so the test can read providers directly. Returns both.
Future<(ProviderContainer, GoRouter)> pumpRouterApp(
  WidgetTester tester, {
  Size size = const Size(800, 600),
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final container = ProviderContainer();
  addTearDown(container.dispose);
  final router = createAppRouter();
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

void main() {
  group('Supplier ledger (computed outstanding)', () {
    test('seeded opening balances are the ledger sums', () async {
      final repo = MockSupplierRepository();
      Future<int> outstanding(String id) async {
        final entries = await repo.getLedgerEntries(id);
        return supplierOutstandingMinor(entries);
      }

      expect(await outstanding('sup-sami'), 12500000);
      expect(await outstanding('sup-medserve'), 4825000);
      expect(await outstanding('sup-hassan-traders'), 0);
      expect(await outstanding('sup-careline'), 2100000);
    });

    test('outstanding is the sum, never a stored field', () {
      const entries = [
        SupplierLedgerEntry(
          id: 'x1',
          supplierId: 'sup-1',
          kind: SupplierLedgerEntryKind.purchase,
          amountMinor: 500000,
          reason: 'Goods received',
          balanceAfterMinor: 500000,
        ),
        SupplierLedgerEntry(
          id: 'x2',
          supplierId: 'sup-1',
          kind: SupplierLedgerEntryKind.payment,
          amountMinor: -200000,
          reason: 'Payment made',
          balanceAfterMinor: 300000,
        ),
      ];
      expect(supplierOutstandingMinor(entries), 300000);
      expect(supplierOutstandingMinor(const []), 0);
    });

    test('search by name, contact and phone digits', () {
      expect(
        searchSuppliers(demoSuppliers, query: 'sami').length,
        1,
      );
      expect(
        searchSuppliers(demoSuppliers, query: 'Nadia').length,
        1,
      );
      expect(
        searchSuppliers(demoSuppliers, query: '03007778899').length,
        1,
      );
      expect(searchSuppliers(demoSuppliers).length, 4);
    });

    test('validation rejects missing fields and duplicate phones', () {
      expect(
        validateNewSupplier(name: '', contactPerson: 'A', phone: '03001234567'),
        isNotEmpty,
      );
      expect(
        validateNewSupplier(
          name: 'New Supplier',
          contactPerson: 'A',
          phone: '0300-7778899',
          existingPhones: ['03007778899'],
        ),
        contains('A supplier with this phone number already exists.'),
      );
      expect(
        validateNewSupplier(
          name: 'New Supplier',
          contactPerson: 'A',
          phone: '0300-9998888',
        ),
        isEmpty,
      );
    });

    test('payment above outstanding is rejected; reason required', () {
      expect(
        validateSupplierLedgerEntry(
          kind: SupplierLedgerEntryKind.payment,
          amountMinor: 600000,
          reason: 'Paid',
          outstandingMinor: 500000,
        ),
        isNotEmpty,
      );
      expect(
        validateSupplierLedgerEntry(
          kind: SupplierLedgerEntryKind.payment,
          amountMinor: 500000,
          reason: '',
          outstandingMinor: 500000,
        ),
        isNotEmpty,
      );
      expect(
        validateSupplierLedgerEntry(
          kind: SupplierLedgerEntryKind.payment,
          amountMinor: 500000,
          reason: 'Paid',
          outstandingMinor: 500000,
        ),
        isEmpty,
      );
    });

    test('signed amounts: purchase adds, payment/return subtract', () {
      expect(
        signedSupplierLedgerAmount(
          kind: SupplierLedgerEntryKind.purchase,
          amountMinor: 1000,
        ),
        1000,
      );
      expect(
        signedSupplierLedgerAmount(
          kind: SupplierLedgerEntryKind.payment,
          amountMinor: 1000,
        ),
        -1000,
      );
      expect(
        signedSupplierLedgerAmount(
          kind: SupplierLedgerEntryKind.purchaseReturn,
          amountMinor: 1000,
        ),
        -1000,
      );
      expect(
        signedSupplierLedgerAmount(
          kind: SupplierLedgerEntryKind.adjustment,
          amountMinor: 1000,
          isIncrease: false,
        ),
        -1000,
      );
    });

    test('repository: create rejects duplicate phone; ledger snapshots balanceAfter',
        () async {
      final repo = MockSupplierRepository();
      await expectLater(
        repo.createSupplier(
          const Supplier(
            id: '',
            name: 'Copy',
            contactPerson: 'X',
            phone: '0300-7778899',
          ),
        ),
        throwsArgumentError,
      );
      final entry = await repo.addLedgerEntry(
        const SupplierLedgerEntry(
          id: '',
          supplierId: 'sup-careline',
          kind: SupplierLedgerEntryKind.payment,
          amountMinor: -100000,
          reason: 'Partial payment',
          balanceAfterMinor: 0,
        ),
      );
      expect(entry.balanceAfterMinor, 2000000);
    });
  });

  group('Purchase orders', () {
    test('guards: approve draft only, receive approved only, cancel before receiving',
        () {
      const draft = PurchaseOrder(
        id: 'po-1',
        poNumber: 'PO-1',
        supplierId: 'sup-sami',
        branchId: 'branch-dha-main',
        status: PurchaseOrderStatus.draft,
        items: [],
      );
      expect(canApprovePo(PurchaseOrderStatus.draft), true);
      expect(canApprovePo(PurchaseOrderStatus.approved), false);
      expect(canCancelPo(draft), true);
      final approved = draft.copyWith(
        status: PurchaseOrderStatus.approved,
        items: [_poItem()],
      );
      expect(canReceivePo(approved), true);
      expect(canCancelPo(approved), true);
      final received = approved.copyWith(
        status: PurchaseOrderStatus.received,
        items: [_poItem(quantityReceived: 10)],
      );
      expect(canReceivePo(received), false);
      expect(canCancelPo(received), false);
      expect(canApprovePo(PurchaseOrderStatus.cancelled), false);
    });

    test('totals, receiving maths and status after receiving', () {
      final items = [_poItem(quantityOrdered: 10, unitCostMinor: 10000)];
      expect(poTotalMinor(items), 100000);
      expect(poReceivedTotalMinor(items), 0);
      final lines = [
        ReceivingLine(
          item: items.first,
          quantityReceivedNow: 4,
          batchNo: 'B-1',
          mfgDate: DateTime(2026, 1, 1),
          expiryDate: DateTime(2027, 1, 1),
        ),
      ];
      final updated = applyReceiving(items, lines);
      expect(updated.first.quantityReceived, 4);
      expect(poReceivedTotalMinor(updated), 40000);
      expect(
        statusAfterReceiving(
          const PurchaseOrder(
            id: 'po-1',
            poNumber: 'PO-1',
            supplierId: 'sup-sami',
            branchId: 'branch-dha-main',
            status: PurchaseOrderStatus.approved,
            items: [],
          ).copyWith(items: updated),
        ),
        PurchaseOrderStatus.partiallyReceived,
      );
      final full = applyReceiving(updated, [
        ReceivingLine(
          item: updated.first,
          quantityReceivedNow: 6,
          batchNo: 'B-2',
          mfgDate: DateTime(2026, 1, 1),
          expiryDate: DateTime(2027, 1, 1),
        ),
      ]);
      expect(full.first.isFullyReceived, true);
    });

    test('validation: form needs supplier + lines; receiving needs batch + dates + qty cap',
        () {
      expect(
        validatePurchaseOrderForm(supplierId: null, items: []),
        hasLength(2),
      );
      expect(
        validatePurchaseOrderForm(
          supplierId: 'sup-sami',
          items: [_poItem()],
        ),
        isEmpty,
      );
      final over = [
        ReceivingLine(
          item: _poItem(quantityOrdered: 5),
          quantityReceivedNow: 6,
          batchNo: 'B-1',
          mfgDate: DateTime(2026, 1, 1),
          expiryDate: DateTime(2027, 1, 1),
        ),
      ];
      expect(validateReceiving(over), isNotEmpty);
      final noBatch = [
        ReceivingLine(
          item: _poItem(),
          quantityReceivedNow: 2,
          batchNo: '',
          mfgDate: DateTime(2026, 1, 1),
          expiryDate: DateTime(2027, 1, 1),
        ),
      ];
      expect(validateReceiving(noBatch), isNotEmpty);
      final badDates = [
        ReceivingLine(
          item: _poItem(),
          quantityReceivedNow: 2,
          batchNo: 'B-1',
          mfgDate: DateTime(2027, 1, 1),
          expiryDate: DateTime(2026, 1, 1),
        ),
      ];
      expect(validateReceiving(badDates), isNotEmpty);
      expect(validateReceiving([]), isNotEmpty);
    });

    test('seed POs: 6 across branches, every status present', () async {
      final repo = MockPurchaseOrderRepository();
      final all = await repo.getPurchaseOrders();
      expect(all.length, 6);
      final dha = await repo.getPurchaseOrders(branchId: 'branch-dha-main');
      expect(dha.length, 4);
      final statuses = all.map((po) => po.status).toSet();
      expect(
        statuses,
        containsAll([
          PurchaseOrderStatus.draft,
          PurchaseOrderStatus.approved,
          PurchaseOrderStatus.partiallyReceived,
          PurchaseOrderStatus.received,
          PurchaseOrderStatus.cancelled,
        ]),
      );
    });

    test('full PO flow: create → approve → receive updates inventory + supplier ledger',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final inventoryRepo = container.read(inventoryRepositoryProvider);
      final supplierRepo = container.read(supplierRepositoryProvider);
      final beforeQty = (await inventoryRepo.getInventory(
        branchId: 'branch-dha-main',
      ))
          .where((i) => i.medicineId == 'med-panadol-extra')
          .fold(0, (sum, i) => sum + i.quantity);
      final beforeOutstanding = (await supplierRepo.getLedgerEntries(
        'sup-sami',
      )).fold(0, (sum, e) => sum + e.amountMinor);

      final notifier = container.read(purchaseOrdersProvider.notifier);
      final created = await notifier.createOrder(
        branchId: 'branch-dha-main',
        supplierId: 'sup-sami',
        items: [_poItem(quantityOrdered: 10, unitCostMinor: 10000)],
        notes: 'Test PO',
      );
      expect(created.error, isNull);
      final po = created.order!;
      expect(po.status, PurchaseOrderStatus.draft);
      expect(po.poNumber, startsWith('PO-DHA-'));

      expect(await notifier.approveOrder(po), true);
      final approved = container.read(purchaseOrderByIdProvider(po.id))!;
      expect(approved.status, PurchaseOrderStatus.approved);
      expect(await notifier.approveOrder(approved), false);

      final received = await notifier.receiveOrder(approved, [
        ReceivingLine(
          item: approved.items.first,
          quantityReceivedNow: 10,
          batchNo: 'B-TEST-1',
          mfgDate: DateTime.now().subtract(const Duration(days: 30)),
          expiryDate: DateTime.now().add(const Duration(days: 365)),
        ),
      ]);
      expect(received.error, isNull);
      expect(received.order!.status, PurchaseOrderStatus.received);

      final afterQty = (await inventoryRepo.getInventory(
        branchId: 'branch-dha-main',
      ))
          .where((i) => i.medicineId == 'med-panadol-extra')
          .fold(0, (sum, i) => sum + i.quantity);
      expect(afterQty, beforeQty + 10);
      final batches = await inventoryRepo.getInventory(
        branchId: 'branch-dha-main',
      );
      expect(
        batches.any(
          (i) =>
              i.batchNo == 'B-TEST-1' &&
              i.medicineId == 'med-panadol-extra',
        ),
        true,
      );
      final afterOutstanding = (await supplierRepo.getLedgerEntries(
        'sup-sami',
      )).fold(0, (sum, e) => sum + e.amountMinor);
      expect(afterOutstanding, beforeOutstanding + 100000);
    });

    test('partial receiving then completing; draft cannot receive; cancel works',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(purchaseOrdersProvider.notifier);
      final created = await notifier.createOrder(
        branchId: 'branch-demo-gulberg',
        supplierId: 'sup-medserve',
        items: [_poItem(quantityOrdered: 10, unitCostMinor: 10000)],
      );
      final po = created.order!;
      final draftReceive = await notifier.receiveOrder(po, [
        ReceivingLine(
          item: po.items.first,
          quantityReceivedNow: 5,
          batchNo: 'B-1',
          mfgDate: DateTime(2026, 1, 1),
          expiryDate: DateTime(2027, 1, 1),
        ),
      ]);
      expect(draftReceive.order, isNull);
      expect(await notifier.approveOrder(po), true);
      var current = container.read(purchaseOrderByIdProvider(po.id))!;
      final partial = await notifier.receiveOrder(current, [
        ReceivingLine(
          item: current.items.first,
          quantityReceivedNow: 4,
          batchNo: 'B-2',
          mfgDate: DateTime(2026, 1, 1),
          expiryDate: DateTime(2027, 1, 1),
        ),
      ]);
      expect(partial.error, isNull);
      expect(partial.order!.status, PurchaseOrderStatus.partiallyReceived);
      current = container.read(purchaseOrderByIdProvider(po.id))!;
      final full = await notifier.receiveOrder(current, [
        ReceivingLine(
          item: current.items.first,
          quantityReceivedNow: 6,
          batchNo: 'B-3',
          mfgDate: DateTime(2026, 1, 1),
          expiryDate: DateTime(2027, 1, 1),
        ),
      ]);
      expect(full.order!.status, PurchaseOrderStatus.received);

      final draft2 = (await notifier.createOrder(
        branchId: 'branch-demo-gulberg',
        supplierId: 'sup-medserve',
        items: [_poItem()],
      )).order!;
      expect(await notifier.cancelOrder(draft2), true);
      expect(
        container
            .read(purchaseOrderByIdProvider(draft2.id))!
            .status,
        PurchaseOrderStatus.cancelled,
      );
    });
  });

  group('Prescription review', () {
    test('seed: 20 prescriptions, first of each branch pending', () {
      final all = generateDemoPrescriptions();
      expect(all.length, 20);
      expect(
        all.firstWhere((rx) => rx.id == 'rx-dha-1').status,
        PrescriptionStatus.pending,
      );
      expect(
        all.firstWhere((rx) => rx.id == 'rx-glb-11').status,
        PrescriptionStatus.pending,
      );
      expect(
        all.every(
          (rx) => rx.imageUrl.startsWith(
            'assets/images/prescriptions/sample-prescription-',
          ),
        ),
        true,
      );
    });

    test('review validation: reject needs a note; re-review rejected', () {
      expect(
        validateReview(
          current: PrescriptionStatus.pending,
          target: PrescriptionStatus.rejected,
          note: '',
        ),
        isNotEmpty,
      );
      expect(
        validateReview(
          current: PrescriptionStatus.pending,
          target: PrescriptionStatus.rejected,
          note: 'Expired prescription',
        ),
        isEmpty,
      );
      expect(
        validateReview(
          current: PrescriptionStatus.approved,
          target: PrescriptionStatus.rejected,
          note: 'x',
        ),
        isNotEmpty,
      );
    });

    test('approve unblocks the dispatch guard; pending blocks it', () {
      const order = Order(
        id: 'ord-test',
        customerId: 'cust-1',
        branchId: 'branch-dha-main',
        items: [],
        deliveryAddress: 'Test address',
        totalAmount: 0,
        prescriptionId: 'rx-dha-1',
        status: OrderStatus.ready,
      );
      expect(
        advanceBlockedReason(
          order: order,
          next: OrderStatus.dispatched,
          linkedPrescriptionStatus: PrescriptionStatus.pending,
        ),
        isNotNull,
      );
      expect(
        advanceBlockedReason(
          order: order,
          next: OrderStatus.dispatched,
          linkedPrescriptionStatus: PrescriptionStatus.approved,
        ),
        isNull,
      );
    });

    test('provider: approve + reject flows and new prescription', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(prescriptionsProvider.notifier);
      final approved = await notifier.review(
        id: 'rx-dha-1',
        target: PrescriptionStatus.approved,
        reviewedBy: 'Dr. Sana Malik',
      );
      expect(approved.error, isNull);
      expect(approved.prescription!.status, PrescriptionStatus.approved);
      expect(approved.prescription!.reviewedBy, 'Dr. Sana Malik');
      expect(approved.prescription!.reviewedAt, isNotNull);

      final noNote = await notifier.review(
        id: 'rx-glb-11',
        target: PrescriptionStatus.rejected,
        reviewedBy: 'Dr. Sana Malik',
        note: '',
      );
      expect(noNote.prescription, isNull);
      expect(noNote.error, isNotNull);
      final rejected = await notifier.review(
        id: 'rx-glb-11',
        target: PrescriptionStatus.rejected,
        reviewedBy: 'Dr. Sana Malik',
        note: 'Prescription is expired.',
      );
      expect(rejected.error, isNull);
      expect(rejected.prescription!.status, PrescriptionStatus.rejected);

      final created = await notifier.create(
        customerId: 'cust-1',
        medicinesText: 'Panadol Extra 500mg — 1 tablet as needed',
        branchId: 'branch-dha-main',
      );
      expect(created.error, isNull);
      expect(created.prescription!.status, PrescriptionStatus.pending);
      expect(created.prescription!.id, startsWith('rx-dha-'));
      final bad = await notifier.create(
        customerId: '',
        medicinesText: '',
        branchId: 'branch-dha-main',
      );
      expect(bad.prescription, isNull);
    });
  });

  group('Reports', () {
    test('computeReports: 30-day window, totals, valuation, expiry', () {
      final data = computeReports(
        orders: generateDemoOrders(),
        sales: const [],
        inventory: generateDemoInventory(),
        medicinesById: {for (final m in demoMedicines) m.id: m},
        now: DateTime.now(),
        days: 30,
      );
      expect(data.dailySales.length, 30);
      expect(data.totalSalesMinor, greaterThan(0));
      expect(data.totalOrders, greaterThan(0));
      expect(data.bestSellers, isNotEmpty);
      expect(data.lowStock, isNotEmpty);
      expect(data.expired, isNotEmpty);
      expect(data.stockValuationMinor, greaterThan(0));
      expect(data.totalStockUnits, greaterThan(0));
    });

    test('report provider: branch scoping changes the figures', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final all = await container
          .read(reportDataProvider((null, 30)).future);
      final dha = await container
          .read(reportDataProvider(('branch-dha-main', 30)).future);
      final glb = await container
          .read(reportDataProvider(('branch-demo-gulberg', 30)).future);
      expect(dha.totalSalesMinor, greaterThan(glb.totalSalesMinor));
      expect(all.totalSalesMinor,
          dha.totalSalesMinor + glb.totalSalesMinor);
    });

    test('CSV export: headers, escaping, daily rows', () {
      final data = computeReports(
        orders: generateDemoOrders(),
        sales: const [],
        inventory: generateDemoInventory(),
        now: DateTime.now(),
        days: 7,
      );
      final csv = dailySalesCsv(data.dailySales);
      expect(csv.startsWith('Date,Orders,Sales (Rs)\n'), true);
      expect(csv.split('\n').length, greaterThan(7));
      expect(bestSellersCsv(data.bestSellers).startsWith(
        'Medicine,Quantity sold,Revenue (Rs)\n',
      ), true);
      expect(
        lowStockCsv(data.lowStock).startsWith(
          'Medicine,Batch,Quantity on hand,Low-stock threshold\n',
        ),
        true,
      );
      expect(csvEscape('a,b'), '"a,b"');
      expect(csvEscape('plain'), 'plain');
    });

    test('PDF export: real bytes starting with %PDF', () async {
      final data = computeReports(
        orders: generateDemoOrders(),
        sales: const [],
        inventory: generateDemoInventory(),
        now: DateTime.now(),
        days: 7,
      );
      final bytes = await buildSalesReportPdf(
        data: data,
        branchName: 'Demo Branch — DHA',
        days: 7,
      );
      expect(bytes.lengthInBytes, greaterThan(1000));
      expect(bytes[0], 0x25); // %
      expect(bytes[1], 0x50); // P
      expect(bytes[2], 0x44); // D
      expect(bytes[3], 0x46); // F
    });
  });

  group('Notifications', () {
    test('buildNotifications covers every alert kind with routes', () {
      final notifications = buildNotifications(
        orders: generateDemoOrders(),
        inventory: generateDemoInventory(),
        prescriptions: generateDemoPrescriptions(),
        purchaseOrders: generateDemoPurchaseOrders(),
        branchId: 'branch-dha-main',
        now: DateTime.now(),
      );
      final kinds = notifications.map((n) => n.kind).toSet();
      expect(kinds, contains(NotificationKind.lowStock));
      expect(kinds, contains(NotificationKind.nearExpiry));
      expect(kinds, contains(NotificationKind.expired));
      expect(kinds, contains(NotificationKind.pendingPrescription));
      expect(kinds, contains(NotificationKind.purchaseApproval));
      expect(kinds, contains(NotificationKind.newOrder));
      for (final n in notifications) {
        expect(n.route, startsWith('/'));
      }
      final rxAlert = notifications.firstWhere(
        (n) => n.kind == NotificationKind.pendingPrescription,
      );
      expect(rxAlert.route, startsWith('/prescriptions/rx-'));
    });

    test('provider: unread count drops to zero after mark-all-read',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final unreadBefore = await container.read(
        unreadNotificationsProvider.future,
      );
      expect(unreadBefore, greaterThan(0));
      final list = await container.read(notificationsProvider.future);
      container
          .read(notificationReadProvider.notifier)
          .markAllRead(list.map((n) => n.id));
      final unreadAfter = await container.read(
        unreadNotificationsProvider.future,
      );
      expect(unreadAfter, 0);
    });
  });

  group('Branding + feature config (providers)', () {
    test('brand apply + reset; Fazal Din preset', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(brandConfigProvider.notifier);
      notifier.applyFazalDin();
      expect(
        container.read(brandConfigProvider).appName,
        "Fazal Din's Pharma Plus",
      );
      notifier.reset();
      expect(container.read(brandConfigProvider).appName, 'PharmaDesk');
    });

    test('feature toggles: disable, enable-all, route mapping', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(featureConfigProvider.notifier);
      expect(container.read(featureConfigProvider).contains('reports'), true);
      notifier.setEnabled('reports', false);
      expect(container.read(featureConfigProvider).contains('reports'), false);
      expect(featureModuleForRoute('/reports')?.key, 'reports');
      expect(featureModuleForRoute('/reports/anything')?.key, 'reports');
      expect(featureModuleForRoute('/dashboard'), isNull);
      expect(featureModuleForRoute('/settings'), isNull);
      notifier.enableAll();
      // Week 4 Day 3 (D124): the Finance module joins the toggleable
      // modules — 12, not 11.
      expect(container.read(featureConfigProvider).length, 12);
    });

    test('roles matrix: 10 roles, 24 capabilities, pharmacist reviews', () {
      expect(demoRoles.length, 10);
      expect(roleCapabilities.length, 24);
      final pharmacist = permissionsForRole('Pharmacist');
      expect(pharmacist.length, 24);
      final rxIndex = roleCapabilities.indexWhere(
        (c) => c.key == 'rxReview',
      );
      expect(pharmacist[rxIndex], RolePermission.own);
      final auditor = permissionsForRole('Auditor');
      expect(
        auditor.every(
          (p) => p == RolePermission.readOnly || p == RolePermission.none,
        ),
        true,
      );
    });
  });

  group('Widget flows', () {
    testWidgets('supplier detail: record payment reduces outstanding',
        (WidgetTester tester) async {
      final (container, router) = await pumpRouterApp(
        tester,
        size: const Size(800, 1600),
      );
      expect(container, isNotNull);
      router.go('/suppliers');
      await tester.pumpAndSettle();
      expect(find.text('Sami Pharmaceuticals'), findsOneWidget);
      await tester.tap(find.text('Sami Pharmaceuticals'));
      await tester.pumpAndSettle();
      expect(find.text('Rs 125,000.00'), findsWidgets);
      await tester.tap(find.text('Record payment'));
      await tester.pumpAndSettle();
      final dialogFields = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );
      // Amount + reason + reference (the Day 5 payment flow adds a
      // reference field for the payment record).
      expect(dialogFields, findsNWidgets(3));
      await tester.enterText(dialogFields.at(0), '5000');
      await tester.enterText(dialogFields.at(1), 'Test payment');
      await tester.tap(find.text('Record'));
      await tester.pumpAndSettle();
      expect(find.text('Rs 120,000.00'), findsWidgets);
    });

    testWidgets('PO detail: receive goods moves an approved PO to Received',
        (WidgetTester tester) async {
      final (_, router) = await pumpRouterApp(
        tester,
        size: const Size(800, 1600),
      );
      router.go('/purchases/po-dha-1001');
      await tester.pumpAndSettle();
      expect(find.text('PO-DHA-1001'), findsWidgets);
      await tester.tap(find.text('Receive goods'));
      await tester.pumpAndSettle();
      final dialogFields = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );
      expect(dialogFields, findsNWidgets(4));
      await tester.enterText(dialogFields.at(1), 'B-TEST-9');
      await tester.enterText(dialogFields.at(3), 'B-TEST-10');
      // Manufacture + expiry dates for both lines (by index — the
      // first match is always line 1, so tap each line explicitly).
      final mfgButtons = find.textContaining('Mfg:');
      final expiryButtons = find.textContaining('Expiry:');
      expect(mfgButtons, findsNWidgets(2));
      expect(expiryButtons, findsNWidgets(2));
      for (var i = 0; i < 2; i++) {
        await tester.tap(mfgButtons.at(i));
        await tester.pumpAndSettle();
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
        await tester.tap(expiryButtons.at(i));
        await tester.pumpAndSettle();
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
      }
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Receive goods'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Received'), findsWidgets);
    });

    testWidgets('prescription detail: approve unblocks the linked order',
        (WidgetTester tester) async {
      final (_, router) = await pumpRouterApp(
        tester,
        size: const Size(800, 1600),
      );
      router.go('/prescriptions/rx-dha-1');
      await tester.pumpAndSettle();
      expect(find.text('rx-dha-1'), findsWidgets);
      expect(find.textContaining('cannot be dispatched'), findsOneWidget);
      await tester.tap(find.text('Approve'));
      await tester.pumpAndSettle();
      expect(find.text('Approved'), findsWidgets);
      expect(find.textContaining('is no longer held'), findsOneWidget);
    });

    testWidgets('notifications: mark all read clears the unread badge',
        (WidgetTester tester) async {
      final (_, router) = await pumpRouterApp(tester);
      router.go('/notifications');
      await tester.pumpAndSettle();
      expect(find.textContaining('unread'), findsOneWidget);
      await tester.tap(find.text('Mark all read'));
      await tester.pumpAndSettle();
      expect(find.text('All notifications read'), findsOneWidget);
    });

    testWidgets('branding: Fazal Din preset rebrands the shell',
        (WidgetTester tester) async {
      final (_, router) = await pumpRouterApp(
        tester,
        size: const Size(1280, 800),
      );
      router.go('/settings');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Branding'));
      await tester.pumpAndSettle();
      await tester.tap(find.text("Use Fazal Din's Pharma Plus"));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Apply branding'));
      await tester.pumpAndSettle();
      expect(find.text("Fazal Din's Pharma Plus"), findsWidgets);
    });

    testWidgets('feature toggle: disabling Reports hides it + shows disabled state',
        (WidgetTester tester) async {
      final (_, router) = await pumpRouterApp(
        tester,
        size: const Size(1280, 1600),
      );
      router.go('/settings');
      await tester.pumpAndSettle();
      // Week 4 Day 4 (D134): the Settings TabBar grew to six tabs,
      // so at 1280px it scrolls — bring the last tab into view
      // before tapping it (D24 pattern).
      await tester.ensureVisible(find.text('Features'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Features'));
      await tester.pumpAndSettle();
      final tile = find.ancestor(
        of: find.text('Reports'),
        matching: find.byType(SwitchListTile),
      );
      expect(tile, findsOneWidget);
      await tester.ensureVisible(tile);
      await tester.pumpAndSettle();
      await tester.tap(tile);
      await tester.pumpAndSettle();
      router.go('/reports');
      await tester.pumpAndSettle();
      expect(find.text('Reports is disabled'), findsOneWidget);
      // Re-enable from the disabled screen's action.
      await tester.tap(find.text('Open Feature Settings'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Features'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Features'));
      await tester.pumpAndSettle();
      final reenableTile = find.ancestor(
        of: find.text('Reports'),
        matching: find.byType(SwitchListTile),
      );
      await tester.ensureVisible(reenableTile);
      await tester.pumpAndSettle();
      await tester.tap(reenableTile);
      await tester.pumpAndSettle();
      router.go('/reports');
      await tester.pumpAndSettle();
      expect(find.text('Daily sales'), findsOneWidget);
    });

    testWidgets('full route walk: all 16 modules load, no placeholders left',
        (WidgetTester tester) async {
      final (_, router) = await pumpRouterApp(
        tester,
        size: const Size(1280, 800),
      );
      const routes = [
        '/dashboard',
        '/orders',
        '/medicines',
        '/inventory',
        '/billing',
        '/customers',
        '/suppliers',
        '/purchases',
        '/prescriptions',
        '/staff',
        '/staff/salary',
        '/reports',
        '/finance',
        '/finance/cashbook',
        '/finance/aging',
        '/finance/statements',
        '/branches',
        '/branches/branch-dha-main',
        '/audit-log',
        '/backup',
        '/notifications',
        '/settings',
        '/profile',
      ];
      for (final route in routes) {
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
      }
    });
  });
}
