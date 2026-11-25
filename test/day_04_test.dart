// PharmaDesk Day 4 tests — orders: status flow + guards, totals in
// int minor units, queue filtering/search/branch scoping, repository
// create/update/status persistence, create/edit validation, and the
// queue / detail / form widget flows.
//
// Widget tests pump a router (signed in, no auth user — the dashboard
// falls back to the branch view) with an overridden order repository,
// so the tests control exactly which orders exist.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:pharmadesk/core/routing/app_router.dart';
import 'package:pharmadesk/core/services/demo_seed_data.dart';
import 'package:pharmadesk/core/services/repositories.dart';
import 'package:pharmadesk/core/theme/app_theme.dart';
import 'package:pharmadesk/core/theme/white_label.dart';
import 'package:pharmadesk/core/utils/money.dart';
import 'package:pharmadesk/features/dashboard/dashboard_data.dart';
import 'package:pharmadesk/features/orders/order_logic.dart';
import 'package:pharmadesk/features/orders/orders_provider.dart';
import 'package:pharmadesk/models/order.dart';
import 'package:pharmadesk/models/prescription.dart';

Order _order({
  String id = 'ord-test-1',
  String customerId = 'cust-1',
  String branchId = 'branch-dha-main',
  OrderStatus status = OrderStatus.newOrder,
  List<OrderItem> items = const [
    OrderItem(
      medicineId: 'med-panadol-extra',
      medicineName: 'Panadol Extra',
      quantity: 2,
      unitPrice: 120,
    ),
    OrderItem(
      medicineId: 'med-risek-20',
      medicineName: 'Risek',
      quantity: 1,
      unitPrice: 640,
    ),
  ],
  int discountMinor = 0,
  String? prescriptionId,
}) {
  final subtotal = orderSubtotalMinor(items);
  final total = subtotal - discountMinor;
  return Order(
    id: id,
    customerId: customerId,
    branchId: branchId,
    items: items,
    deliveryAddress: 'Test address',
    status: status,
    discountMinor: discountMinor,
    prescriptionId: prescriptionId,
    totalAmount: minorUnitsToRupees(total < 0 ? 0 : total),
    createdAt: DateTime(2026, 11, 24, 10, 30),
  );
}

void main() {
  group('Status flow (pure)', () {
    test('legacy values map onto the Week 1 vocabulary', () {
      expect(canonicalStatus(OrderStatus.placed), OrderStatus.newOrder);
      expect(
        canonicalStatus(OrderStatus.preparing),
        OrderStatus.processing,
      );
      expect(
        canonicalStatus(OrderStatus.outForDelivery),
        OrderStatus.dispatched,
      );
      expect(canonicalStatus(OrderStatus.ready), OrderStatus.ready);
      expect(
        canonicalStatus(OrderStatus.delivered),
        OrderStatus.delivered,
      );
      expect(
        canonicalStatus(OrderStatus.cancelled),
        OrderStatus.cancelled,
      );
    });

    test('next step walks the full flow, then stops', () {
      expect(nextOrderStatus(OrderStatus.newOrder), OrderStatus.confirmed);
      expect(
        nextOrderStatus(OrderStatus.confirmed),
        OrderStatus.processing,
      );
      expect(nextOrderStatus(OrderStatus.processing), OrderStatus.ready);
      expect(nextOrderStatus(OrderStatus.ready), OrderStatus.dispatched);
      expect(
        nextOrderStatus(OrderStatus.dispatched),
        OrderStatus.delivered,
      );
      expect(nextOrderStatus(OrderStatus.delivered), isNull);
      expect(nextOrderStatus(OrderStatus.cancelled), isNull);
    });

    test('legacy values advance through the same flow', () {
      expect(nextOrderStatus(OrderStatus.placed), OrderStatus.confirmed);
      expect(nextOrderStatus(OrderStatus.preparing), OrderStatus.ready);
      expect(
        nextOrderStatus(OrderStatus.outForDelivery),
        OrderStatus.delivered,
      );
    });

    test('guards: terminal orders cannot advance, cancel or edit', () {
      for (final status in [
        OrderStatus.delivered,
        OrderStatus.cancelled,
      ]) {
        expect(canAdvance(status), isFalse);
        expect(canCancel(status), isFalse);
        expect(canEdit(status), isFalse);
      }
      for (final status in orderFlow) {
        if (status == OrderStatus.delivered) continue;
        expect(canAdvance(status), isTrue);
        expect(canCancel(status), isTrue);
        expect(canEdit(status), isTrue);
      }
      expect(canCancel(OrderStatus.cancelled), isFalse);
    });

    test('labels use the Week 1 vocabulary for old and new values', () {
      expect(orderStatusLabel(OrderStatus.placed), 'New');
      expect(orderStatusLabel(OrderStatus.newOrder), 'New');
      expect(orderStatusLabel(OrderStatus.preparing), 'Processing');
      expect(orderStatusLabel(OrderStatus.processing), 'Processing');
      expect(orderStatusLabel(OrderStatus.outForDelivery), 'Dispatched');
      expect(orderStatusLabel(OrderStatus.dispatched), 'Dispatched');
      expect(orderStatusLabel(OrderStatus.ready), 'Ready');
      expect(advanceLabel(OrderStatus.newOrder), 'Mark Confirmed');
      expect(advanceLabel(OrderStatus.ready), 'Mark Dispatched');
      expect(advanceLabel(OrderStatus.delivered), '');
    });

    test('dispatch is blocked while the linked prescription is pending',
        () {
      final order = _order(
        status: OrderStatus.ready,
        prescriptionId: 'rx-dha-1',
      );
      expect(
        advanceBlockedReason(
          order: order,
          next: OrderStatus.dispatched,
          linkedPrescriptionStatus: PrescriptionStatus.pending,
        ),
        contains('pending'),
      );
      expect(
        advanceBlockedReason(
          order: order,
          next: OrderStatus.dispatched,
          linkedPrescriptionStatus: PrescriptionStatus.approved,
        ),
        isNull,
      );
      // Earlier steps are never blocked by the prescription.
      expect(
        advanceBlockedReason(
          order: order,
          next: OrderStatus.processing,
          linkedPrescriptionStatus: PrescriptionStatus.pending,
        ),
        isNull,
      );
    });

    test('timeline marks done/current/upcoming with honest timestamps',
        () {
      final fresh = _order(status: OrderStatus.newOrder);
      final steps = orderTimeline(fresh);
      expect(steps.length, 6);
      expect(steps.first.state, OrderTimelineState.current);
      expect(steps.first.timestamp, fresh.createdAt);
      expect(steps.skip(1).every((s) => s.state == OrderTimelineState.upcoming), isTrue);
      expect(steps.skip(1).every((s) => s.timestamp == null), isTrue);

      final delivered = _order(
        status: OrderStatus.delivered,
        id: 'ord-test-delivered',
      ).copyWith(updatedAt: DateTime(2026, 11, 24, 12, 0));
      final done = orderTimeline(delivered);
      expect(
        done.every((s) => s.state != OrderTimelineState.upcoming),
        isTrue,
      );
      expect(done.last.state, OrderTimelineState.current);
      expect(done.last.timestamp, delivered.updatedAt);
    });

    test('status strings parse old and new values, unknown defaults', () {
      expect(orderStatusFromString('new'), OrderStatus.newOrder);
      expect(orderStatusFromString('newOrder'), OrderStatus.newOrder);
      expect(orderStatusFromString('processing'), OrderStatus.processing);
      expect(orderStatusFromString('ready'), OrderStatus.ready);
      expect(orderStatusFromString('dispatched'), OrderStatus.dispatched);
      expect(orderStatusFromString('placed'), OrderStatus.placed);
      expect(orderStatusFromString('preparing'), OrderStatus.preparing);
      expect(
        orderStatusFromString('outForDelivery'),
        OrderStatus.outForDelivery,
      );
      expect(orderStatusFromString('bogus'), OrderStatus.placed);
      expect(orderStatusFromString(null), OrderStatus.placed);
    });
  });

  group('Totals in int minor units (pure)', () {
    test('subtotal and total are exact int paisa, discount clamps at 0',
        () {
      final items = _order().items;
      // 2 × Rs 120 + 1 × Rs 640 = Rs 880.00 = 88,000 paisa.
      expect(orderSubtotalMinor(items), 88000);
      expect(
        orderTotalMinor(items: items, discountMinor: 5000),
        83000,
      );
      expect(
        orderTotalMinor(items: items, discountMinor: 999999),
        0,
      );
      expect(orderTotalMinor(items: items), 88000);
      expect(orderTotalMinor(items: const []), 0);
      // The model's own int getters agree with the pure functions.
      final order = _order(discountMinor: 5000);
      expect(order.subtotalMinor, 88000);
      expect(order.totalMinor, 83000);
    });

    test('line totals are int paisa, never doubles', () {
      const line = OrderItem(
        medicineId: 'med-panadol-extra',
        medicineName: 'Panadol Extra',
        quantity: 3,
        unitPrice: 120,
      );
      expect(line.lineTotalMinor, 36000);
      expect(line.lineTotalMinor, isA<int>());
    });
  });

  group('Queue filtering (pure)', () {
    final customersById = {
      for (final c in demoCustomers) c.id: c,
    };
    final orders = [
      _order(id: 'ord-dha-1', status: OrderStatus.newOrder),
      _order(
        id: 'ord-dha-2',
        customerId: 'cust-2',
        status: OrderStatus.preparing,
      ),
      _order(
        id: 'ord-glb-1',
        branchId: 'branch-demo-gulberg',
        status: OrderStatus.delivered,
      ),
      _order(
        id: 'ord-dha-3',
        customerId: 'cust-3',
        status: OrderStatus.cancelled,
      ),
    ];

    test('branch scoping keeps only the active branch', () {
      final dha = filterOrders(
        orders: orders,
        branchId: 'branch-dha-main',
        customersById: customersById,
      );
      expect(dha.map((o) => o.id), ['ord-dha-1', 'ord-dha-2', 'ord-dha-3']);
      final glb = filterOrders(
        orders: orders,
        branchId: 'branch-demo-gulberg',
        customersById: customersById,
      );
      expect(glb.map((o) => o.id), ['ord-glb-1']);
    });

    test('status filter matches by canonical status (legacy included)',
        () {
      final processing = filterOrders(
        orders: orders,
        branchId: 'branch-dha-main',
        statusFilter: OrderStatus.processing,
        customersById: customersById,
      );
      // The legacy `preparing` order is a Processing order.
      expect(processing.map((o) => o.id), ['ord-dha-2']);
      final cancelled = filterOrders(
        orders: orders,
        branchId: 'branch-dha-main',
        statusFilter: OrderStatus.cancelled,
        customersById: customersById,
      );
      expect(cancelled.map((o) => o.id), ['ord-dha-3']);
    });

    test('search matches order id, customer name and phone', () {
      final byId = filterOrders(
        orders: orders,
        branchId: 'branch-dha-main',
        query: 'ord-dha-2',
        customersById: customersById,
      );
      expect(byId.map((o) => o.id), ['ord-dha-2']);
      final byName = filterOrders(
        orders: orders,
        branchId: 'branch-dha-main',
        query: 'fatima',
        customersById: customersById,
      );
      expect(byName.map((o) => o.id), ['ord-dha-2']);
      final byPhone = filterOrders(
        orders: orders,
        branchId: 'branch-dha-main',
        query: '03004445566',
        customersById: customersById,
      );
      expect(byPhone.map((o) => o.id), ['ord-dha-2']);
      final none = filterOrders(
        orders: orders,
        branchId: 'branch-dha-main',
        query: 'zzz-no-match',
        customersById: customersById,
      );
      expect(none, isEmpty);
    });

    test('status counts are per canonical status', () {
      final counts = orderStatusCounts(orders);
      expect(counts[OrderStatus.newOrder], 1);
      expect(counts[OrderStatus.processing], 1);
      expect(counts[OrderStatus.delivered], 1);
      expect(counts[OrderStatus.cancelled], 1);
    });
  });

  group('Create/edit validation (pure)', () {
    const items = [
      OrderItem(
        medicineId: 'med-panadol-extra',
        medicineName: 'Panadol Extra',
        quantity: 1,
        unitPrice: 120,
      ),
    ];

    test('a valid walk-in delivery order passes', () {
      expect(
        validateOrderForm(
          isWalkIn: true,
          items: items,
          fulfillment: FulfillmentType.delivery,
          deliveryAddress: 'House 1, DHA',
        ),
        isEmpty,
      );
    });

    test('empty items, missing customer, bad discount, missing address',
        () {
      expect(
        validateOrderForm(
          items: const [],
          fulfillment: FulfillmentType.delivery,
          deliveryAddress: 'House 1',
        ),
        contains('Add at least one medicine to the order.'),
      );
      expect(
        validateOrderForm(
          items: items,
          fulfillment: FulfillmentType.delivery,
          deliveryAddress: 'House 1',
        ),
        contains('Select a customer or choose Walk-in.'),
      );
      expect(
        validateOrderForm(
          isWalkIn: true,
          items: items,
          discountMinor: -100,
          fulfillment: FulfillmentType.pickup,
        ),
        contains('Discount cannot be negative.'),
      );
      expect(
        validateOrderForm(
          isWalkIn: true,
          items: items,
          discountMinor: 999999,
          fulfillment: FulfillmentType.pickup,
        ),
        contains('Discount cannot be more than the subtotal.'),
      );
      expect(
        validateOrderForm(
          isWalkIn: true,
          items: items,
          fulfillment: FulfillmentType.delivery,
          deliveryAddress: '   ',
        ),
        contains('Delivery needs a delivery address.'),
      );
      // Pickup needs no address.
      expect(
        validateOrderForm(
          isWalkIn: true,
          items: items,
          fulfillment: FulfillmentType.pickup,
        ),
        isEmpty,
      );
    });

    test('a zero-quantity line is rejected', () {
      expect(
        validateOrderForm(
          isWalkIn: true,
          items: const [
            OrderItem(
              medicineId: 'med-panadol-extra',
              medicineName: 'Panadol Extra',
              quantity: 0,
              unitPrice: 120,
            ),
          ],
          fulfillment: FulfillmentType.pickup,
        ),
        contains('Panadol Extra: quantity must be at least 1.'),
      );
    });
  });

  group('Order model (Day 4 fields)', () {
    test('fromMap/toMap round-trips discount, source and fulfilment',
        () {
      final order = _order(discountMinor: 2500).copyWith(
        source: OrderSource.whatsapp,
        fulfillment: FulfillmentType.pickup,
        riderId: 'rider-1',
        orderNotes: 'Leave at gate',
        prescriptionId: 'rx-dha-1',
      );
      final restored = Order.fromMap(order.id, order.toMap());
      expect(restored.discountMinor, 2500);
      expect(restored.source, OrderSource.whatsapp);
      expect(restored.fulfillment, FulfillmentType.pickup);
      expect(restored.riderId, 'rider-1');
      expect(restored.orderNotes, 'Leave at gate');
      expect(restored.prescriptionId, 'rx-dha-1');
      expect(restored.status, OrderStatus.newOrder);
    });

    test('Day 0 maps without the new fields default sanely', () {
      final restored = Order.fromMap('ord-old', {
        'customerId': 'cust-1',
        'branchId': 'branch-dha-main',
        'items': [],
        'deliveryAddress': 'Old address',
        'status': 'placed',
        'totalAmount': 0,
      });
      expect(restored.discountMinor, 0);
      expect(restored.source, OrderSource.phone);
      expect(restored.fulfillment, FulfillmentType.delivery);
      expect(restored.status, OrderStatus.placed);
    });

    test('buildNewOrder derives the stored total from int paisa', () {
      final order = buildNewOrder(
        branchId: 'branch-dha-main',
        customerId: 'cust-1',
        items: _order().items,
        discountMinor: 8000,
        source: OrderSource.whatsapp,
        fulfillment: FulfillmentType.delivery,
        deliveryAddress: 'House 1',
        riderId: 'rider-2',
      );
      expect(order.status, OrderStatus.newOrder);
      expect(order.totalMinor, 80000);
      expect(order.totalAmount, 800);
      expect(order.riderId, 'rider-2');
    });

    test('buildNewOrder walk-in pickup clears rider and address', () {
      final order = buildNewOrder(
        branchId: 'branch-dha-main',
        isWalkIn: true,
        items: _order().items,
        source: OrderSource.walkIn,
        fulfillment: FulfillmentType.pickup,
        riderId: 'rider-2',
      );
      expect(order.customerId, 'walk-in');
      expect(order.riderId, isNull);
      expect(order.deliveryAddress, 'Pickup from branch');
    });

    test('buildEditedOrder keeps identity and recomputes the total', () {
      final original = _order(discountMinor: 0);
      final edited = buildEditedOrder(
        original: original,
        items: const [
          OrderItem(
            medicineId: 'med-panadol-extra',
            medicineName: 'Panadol Extra',
            quantity: 5,
            unitPrice: 120,
          ),
        ],
        discountMinor: 10000,
        riderId: 'rider-1',
      );
      expect(edited.id, original.id);
      expect(edited.status, original.status);
      expect(edited.branchId, original.branchId);
      expect(edited.totalMinor, 50000);
      expect(edited.riderId, 'rider-1');
    });
  });

  group('Mock order repository (Day 4)', () {
    test('create assigns an id and the order appears in the queue', () async {
      final repo = MockOrderRepository();
      final before = await repo.getOrders(branchId: 'branch-dha-main');
      final saved = await repo.createOrder(
        buildNewOrder(
          branchId: 'branch-dha-main',
          customerId: 'cust-1',
          items: _order().items,
          source: OrderSource.phone,
          fulfillment: FulfillmentType.delivery,
          deliveryAddress: 'House 1',
        ),
      );
      expect(saved.id, startsWith('ord-dha-'));
      expect(saved.id, isNotEmpty);
      final after = await repo.getOrders(branchId: 'branch-dha-main');
      expect(after.length, before.length + 1);
      expect(await repo.getById(saved.id), isNotNull);
      // The new order is in the other branch's queue too — no, it is
      // scoped: Gulberg must not see it.
      final glb = await repo.getOrders(branchId: 'branch-demo-gulberg');
      expect(glb.where((o) => o.id == saved.id), isEmpty);
    });

    test('updateStatus preserves source, discount, rider and notes',
        () async {
      final repo = MockOrderRepository();
      final saved = await repo.createOrder(
        buildNewOrder(
          branchId: 'branch-dha-main',
          customerId: 'cust-1',
          items: _order().items,
          discountMinor: 2500,
          source: OrderSource.whatsapp,
          fulfillment: FulfillmentType.delivery,
          deliveryAddress: 'House 1',
          riderId: 'rider-1',
          orderNotes: 'Ring twice',
          prescriptionId: 'rx-dha-1',
        ),
      );
      await repo.updateStatus(saved.id, OrderStatus.confirmed);
      final updated = await repo.getById(saved.id);
      expect(updated!.status, OrderStatus.confirmed);
      expect(updated.discountMinor, 2500);
      expect(updated.source, OrderSource.whatsapp);
      expect(updated.riderId, 'rider-1');
      expect(updated.orderNotes, 'Ring twice');
      expect(updated.prescriptionId, 'rx-dha-1');
      expect(updated.totalMinor, 85500);
    });

    test('updateOrder replaces items, discount and rider', () async {
      final repo = MockOrderRepository();
      final saved = await repo.createOrder(
        buildNewOrder(
          branchId: 'branch-dha-main',
          customerId: 'cust-1',
          items: _order().items,
          source: OrderSource.phone,
          fulfillment: FulfillmentType.delivery,
          deliveryAddress: 'House 1',
        ),
      );
      final edited = buildEditedOrder(
        original: saved,
        items: const [
          OrderItem(
            medicineId: 'med-zyrtec-10',
            medicineName: 'Zyrtec',
            quantity: 2,
            unitPrice: 340,
          ),
        ],
        discountMinor: 8000,
        riderId: 'rider-3',
      );
      await repo.updateOrder(edited);
      final updated = await repo.getById(saved.id);
      expect(updated!.items.length, 1);
      expect(updated.items.first.medicineName, 'Zyrtec');
      expect(updated.totalMinor, 60000);
      expect(updated.riderId, 'rider-3');
    });

    test('riders: four seeded, three active', () async {
      final repo = MockRiderRepository();
      final riders = await repo.getRiders();
      expect(riders.length, 4);
      expect(riders.where((r) => r.active).length, 3);
      expect(await repo.getById('rider-1'), isNotNull);
      expect((await repo.getById('rider-1'))!.name, 'Bilal Ahmed');
      expect(await repo.getById('nope'), isNull);
    });
  });

  group('Order queue notifier (guards)', () {
    test('advance/cancel go through the notifier and persist', () async {
      final container = ProviderContainer(
        overrides: [
          orderRepositoryProvider.overrideWithValue(MockOrderRepository()),
        ],
      );
      addTearDown(container.dispose);
      final orders = await container.read(orderQueueProvider.future);
      final live = orders.firstWhere((o) => canAdvance(o.status));
      expect(
        await container
            .read(orderQueueProvider.notifier)
            .advanceOrder(live),
        isTrue,
      );
      final advanced = await container
          .read(orderRepositoryProvider)
          .getById(live.id);
      expect(advanced!.status, nextOrderStatus(live.status));

      // Delivered orders refuse both advance and cancel.
      final delivered = orders.firstWhere(
        (o) => o.status == OrderStatus.delivered,
      );
      expect(
        await container
            .read(orderQueueProvider.notifier)
            .advanceOrder(delivered),
        isFalse,
      );
      expect(
        await container
            .read(orderQueueProvider.notifier)
            .cancelOrder(delivered),
        isFalse,
      );
      expect(
        await container
            .read(orderQueueProvider.notifier)
            .updateOrder(delivered),
        isFalse,
      );
      // A live order cancels fine.
      final toCancel = orders.firstWhere(
        (o) => canCancel(o.status) && o.id != live.id,
      );
      expect(
        await container
            .read(orderQueueProvider.notifier)
            .cancelOrder(toCancel),
        isTrue,
      );
      final cancelled = await container
          .read(orderRepositoryProvider)
          .getById(toCancel.id);
      expect(cancelled!.status, OrderStatus.cancelled);
    });
  });

  group('Orders screens (widget)', () {
    late MockOrderRepository repo;
    late GoRouter router;

    Future<void> pumpOrders(
      WidgetTester tester,
      String location,
    ) async {
      repo = MockOrderRepository();
      router = createAppRouter(isSignedIn: () => true);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            orderRepositoryProvider.overrideWithValue(repo),
          ],
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
      router.go(location);
      await tester.pumpAndSettle();
    }

    testWidgets('queue is branch-scoped and shows status badges',
        (WidgetTester tester) async {
      await pumpOrders(tester, '/orders');
      expect(find.text('Orders'), findsWidgets);
      expect(find.text('New Order'), findsOneWidget);
      expect(find.text('Demo Branch — DHA'), findsWidgets);
      // DHA queue only: no Gulberg order ids on screen.
      expect(find.textContaining('ord-glb-'), findsNothing);
      expect(find.textContaining('ord-dha-'), findsWidgets);
      // Filter chips carry counts; 'All' is selected by default.
      expect(find.textContaining('All ('), findsOneWidget);
      expect(find.textContaining('New ('), findsOneWidget);
      expect(find.textContaining('Cancelled ('), findsOneWidget);
    });

    testWidgets('status filter narrows the queue', (WidgetTester tester) async {
      await pumpOrders(tester, '/orders');
      final dha = await repo.getOrders(branchId: 'branch-dha-main');
      final cancelledCount = dha
          .where((o) => canonicalStatus(o.status) == OrderStatus.cancelled)
          .length;
      await tester.tap(find.text('Cancelled ($cancelledCount)'));
      await tester.pumpAndSettle();
      expect(find.text('$cancelledCount order(s)'), findsOneWidget);
      expect(find.textContaining('ord-dha-'), findsWidgets);
    });

    testWidgets('search by order id narrows to one row',
        (WidgetTester tester) async {
      await pumpOrders(tester, '/orders');
      await tester.enterText(
        find.byType(TextField).first,
        'ord-dha-1001',
      );
      await tester.pumpAndSettle();
      expect(find.text('1 order(s)'), findsOneWidget);
      // The id appears both in the search field and in the row.
      expect(find.text('ord-dha-1001'), findsWidgets);
    });

    testWidgets('branch switching re-scopes the queue',
        (WidgetTester tester) async {
      await pumpOrders(tester, '/orders');
      expect(find.textContaining('ord-glb-'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('branch-switcher-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Demo Branch — Gulberg').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('ord-glb-'), findsWidgets);
      expect(find.textContaining('ord-dha-'), findsNothing);
    });

    testWidgets('detail shows items, totals, timeline and actions',
        (WidgetTester tester) async {
      final orders = await MockOrderRepository().getOrders();
      final live = orders.firstWhere(
        (o) =>
            o.branchId == 'branch-dha-main' && canAdvance(o.status),
      );
      await pumpOrders(tester, '/orders/${live.id}');
      expect(find.text(live.id), findsWidgets);
      expect(find.text('Status timeline'), findsOneWidget);
      expect(find.text('Items'), findsOneWidget);
      expect(find.text('Customer'), findsOneWidget);
      expect(find.text('Delivery'), findsWidgets);
      expect(find.text('Prescription'), findsOneWidget);
      expect(find.text(advanceLabel(live.status)), findsOneWidget);
      expect(find.text('Cancel Order'), findsOneWidget);
      expect(find.text('Edit Order'), findsOneWidget);
      expect(
        find.text(formatPkr(rupeesToMinorUnits(live.totalAmount))),
        findsWidgets,
      );
    });

    testWidgets('advance moves the order and updates the badge',
        (WidgetTester tester) async {
      final orders = await MockOrderRepository().getOrders();
      final live = orders.firstWhere(
        (o) =>
            o.branchId == 'branch-dha-main' && canAdvance(o.status),
      );
      final next = nextOrderStatus(live.status)!;
      await pumpOrders(tester, '/orders/${live.id}');
      await tester.ensureVisible(find.text(advanceLabel(live.status)));
      await tester.tap(find.text(advanceLabel(live.status)));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('marked ${orderStatusLabel(next)}'),
        findsOneWidget,
      );
      final updated = await repo.getById(live.id);
      expect(updated!.status, next);
    });

    testWidgets('cancel asks first, then marks the order cancelled',
        (WidgetTester tester) async {
      final orders = await MockOrderRepository().getOrders();
      final live = orders.firstWhere(
        (o) =>
            o.branchId == 'branch-dha-main' && canCancel(o.status),
      );
      await pumpOrders(tester, '/orders/${live.id}');
      await tester.ensureVisible(find.text('Cancel Order'));
      await tester.tap(find.text('Cancel Order'));
      await tester.pumpAndSettle();
      expect(find.text('Cancel order ${live.id}?'), findsOneWidget);
      // The dialog's confirm button is the last 'Cancel Order'.
      await tester.tap(find.text('Cancel Order').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('cancelled.'), findsOneWidget);
      final updated = await repo.getById(live.id);
      expect(updated!.status, OrderStatus.cancelled);
      expect(find.text('Edit Order'), findsNothing);
    });

    testWidgets('create form validates, then saves and opens the order',
        (WidgetTester tester) async {
      await pumpOrders(tester, '/orders/new');
      final beforeIds = (await repo.getOrders(branchId: 'branch-dha-main'))
          .map((o) => o.id)
          .toSet();
      expect(find.text('New Order'), findsWidgets);
      // Save with nothing filled: validation errors appear.
      await tester.ensureVisible(find.text('Save Order'));
      await tester.tap(find.text('Save Order'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Add at least one medicine'),
        findsOneWidget,
      );
      expect(
        find.text('• Select a customer or choose Walk-in.'),
        findsOneWidget,
      );
      // Pick a customer from the dropdown.
      await tester.ensureVisible(
        find.byKey(const ValueKey('customer-dropdown')),
      );
      await tester.tap(find.byKey(const ValueKey('customer-dropdown')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ahmed Raza • 0300-1112233').last);
      await tester.pumpAndSettle();
      // Add Panadol Extra twice (quantity 2).
      await tester.ensureVisible(
        find.byKey(const ValueKey('add-med-panadol-extra')),
      );
      await tester.tap(find.byKey(const ValueKey('add-med-panadol-extra')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('add-med-panadol-extra')));
      await tester.pumpAndSettle();
      expect(find.text('2'), findsWidgets);
      // Discount Rs 20 → total Rs 220.00 (2 × Rs 120 − Rs 20).
      await tester.enterText(
        find.byType(TextFormField).last,
        '20',
      );
      await tester.ensureVisible(find.text('Save Order'));
      await tester.tap(find.text('Save Order'));
      await tester.pumpAndSettle();
      expect(find.textContaining('created.'), findsOneWidget);
      final after = await repo.getOrders(branchId: 'branch-dha-main');
      expect(after.length, beforeIds.length + 1);
      final saved = after.firstWhere((o) => !beforeIds.contains(o.id));
      expect(saved.customerId, 'cust-1');
      expect(saved.items.length, 1);
      expect(saved.items.first.quantity, 2);
      expect(saved.totalMinor, 22000);
      expect(saved.discountMinor, 2000);
      expect(saved.status, OrderStatus.newOrder);
      expect(find.text(saved.id), findsWidgets);
    });

    testWidgets('delivered order edit screen is read-only',
        (WidgetTester tester) async {
      final orders = await MockOrderRepository().getOrders();
      final delivered = orders.firstWhere(
        (o) =>
            o.branchId == 'branch-dha-main' &&
            o.status == OrderStatus.delivered,
      );
      await pumpOrders(tester, '/orders/${delivered.id}/edit');
      expect(find.text('Edit order ${delivered.id}'), findsOneWidget);
      expect(find.textContaining('read-only'), findsOneWidget);
      expect(find.text('Save Changes'), findsNothing);
      expect(find.text('Back to Order'), findsOneWidget);
      await tester.ensureVisible(find.text('Back to Order'));
      await tester.tap(find.text('Back to Order'));
      await tester.pumpAndSettle();
      expect(find.text('Status timeline'), findsOneWidget);
    });

    testWidgets('edit updates items and total on a live order',
        (WidgetTester tester) async {
      final orders = await MockOrderRepository().getOrders();
      final live = orders.firstWhere(
        (o) =>
            o.branchId == 'branch-dha-main' && canEdit(o.status),
      );
      await pumpOrders(tester, '/orders/${live.id}/edit');
      expect(find.text('Edit order ${live.id}'), findsOneWidget);
      // Increase the first line's quantity by one.
      final firstLine = live.items.first;
      await tester.ensureVisible(
        find.byKey(ValueKey('qty-plus-${firstLine.medicineId}')),
      );
      await tester.tap(
        find.byKey(ValueKey('qty-plus-${firstLine.medicineId}')),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Save Changes'));
      await tester.tap(find.text('Save Changes'));
      await tester.pumpAndSettle();
      expect(find.textContaining('updated.'), findsOneWidget);
      final updated = await repo.getById(live.id);
      expect(
        updated!.items.firstWhere((i) => i.medicineId == firstLine.medicineId).quantity,
        firstLine.quantity + 1,
      );
    });
  });
}
