import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/data/production_data_layer.dart';
import '../../core/services/repositories.dart';
import '../../core/utils/money.dart';
import '../../features/authentication/auth_state.dart';
import '../../models/customer.dart';
import '../../models/inventory_item.dart';
import '../../models/medicine.dart';
import '../../models/order.dart';
import '../../models/prescription.dart';
import '../../models/rider.dart';
import 'order_logic.dart';

/// Day 4 orders state.
///
/// [OrderQueueNotifier] owns the in-memory order list for the session:
/// it loads from the (mock) repository once, and every mutation —
/// create, edit, advance, cancel — writes through to the repository
/// and then refreshes its own state, so a saved order appears in the
/// queue immediately. Week 2 swaps the repository for Firestore
/// behind the same interface; the screens do not change.
///
/// The queue is branch-scoped in the UI (active branch), not here:
/// the notifier holds all branches so the owner dashboard's recent
/// orders and the queue share one source of truth.

class OrderQueueNotifier extends AsyncNotifier<List<Order>> {
  @override
  Future<List<Order>> build() async {
    final repo = ref.read(orderRepositoryProvider);
    return repo.getOrders();
  }

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(
      () => ref.read(orderRepositoryProvider).getOrders(),
    );
  }

  /// Moves an order one step forward in the flow. Returns `false`
  /// (and leaves the order untouched) when the guard forbids it.
  Future<bool> advanceOrder(
    Order order, {
    PrescriptionStatus? linkedPrescriptionStatus,
    DateTime? linkedPrescriptionValidUntil,
  }) async {
    final next = nextOrderStatus(order.status);
    if (next == null) return false;
    if (advanceBlockedReason(
          order: order,
          next: next,
          linkedPrescriptionStatus: linkedPrescriptionStatus,
          linkedPrescriptionValidUntil: linkedPrescriptionValidUntil,
        ) !=
        null) {
      return false;
    }
    await ref.read(orderRepositoryProvider).updateStatus(order.id, next);
    await refresh();
    return true;
  }

  /// Cancels an order after the detail screen's confirm dialog.
  /// Returns `false` when the guard forbids it (Delivered / already
  /// Cancelled).
  Future<bool> cancelOrder(Order order) async {
    if (!canCancel(order.status)) return false;
    await ref
        .read(orderRepositoryProvider)
        .updateStatus(order.id, OrderStatus.cancelled);
    await refresh();
    return true;
  }

  /// Saves a new order and returns it (with its repository-assigned
  /// id). The write goes through the production data layer (Week 2
  /// Day 1): idempotency dedupe, audit entry, sync enqueue. A retry
  /// with the same [idempotencyKey] returns the original order.
  Future<Order> createOrder(Order order, {String? idempotencyKey}) async {
    final user = ref.read(authProvider);
    final result = await ref
        .read(productionDataLayerProvider)
        .createOrder(
          order: order,
          idempotencyKey: idempotencyKey,
          actorId: user?.uid ?? demoActorId,
          actorName: user?.name ?? demoActorName,
        );
    await refresh();
    return result.order;
  }

  /// Saves an edited order (items, quantities, discount, rider,
  /// notes). Returns `false` when the guard forbids editing.
  Future<bool> updateOrder(Order order) async {
    if (!canEdit(order.status)) return false;
    await ref.read(orderRepositoryProvider).updateOrder(order);
    await refresh();
    return true;
  }
}

final orderQueueProvider =
    AsyncNotifierProvider<OrderQueueNotifier, List<Order>>(
      OrderQueueNotifier.new,
    );

/// One order by id, from the queue (refreshes when the queue does).
final orderByIdProvider = Provider.family<Order?, String>((ref, id) {
  final orders = ref.watch(orderQueueProvider).asData?.value ?? const [];
  for (final order in orders) {
    if (order.id == id) return order;
  }
  return null;
});

/// Builds a new order from the create form. All money is int minor
/// units: the discount arrives in paisa and the stored `totalAmount`
/// (double rupees, Day 0 model) is derived from the int total.
Order buildNewOrder({
  required String branchId,
  String? customerId,
  bool isWalkIn = false,
  required List<OrderItem> items,
  int discountMinor = 0,
  required OrderSource source,
  required FulfillmentType fulfillment,
  String deliveryAddress = '',
  String? riderId,
  String? orderNotes,
  String? prescriptionId,
}) {
  final totalMinor = orderTotalMinor(
    items: items,
    discountMinor: discountMinor,
  );
  return Order(
    id: '',
    customerId: isWalkIn ? 'walk-in' : (customerId ?? ''),
    branchId: branchId,
    riderId: fulfillment == FulfillmentType.delivery ? riderId : null,
    items: List.unmodifiable(items),
    deliveryAddress: fulfillment == FulfillmentType.pickup
        ? 'Pickup from branch'
        : deliveryAddress,
    status: OrderStatus.newOrder,
    orderNotes: orderNotes?.trim().isEmpty ?? true ? null : orderNotes!.trim(),
    prescriptionId: prescriptionId,
    totalAmount: minorUnitsToRupees(totalMinor),
    discountMinor: discountMinor,
    source: source,
    fulfillment: fulfillment,
  );
}

/// Rebuilds an edited order from the edit form: same items/total math
/// as a new order, but keeps the original id, branch, customer,
/// source, status and timestamps (the repository stamps `updatedAt`).
Order buildEditedOrder({
  required Order original,
  required List<OrderItem> items,
  int discountMinor = 0,
  String? riderId,
  bool clearRiderId = false,
  String? orderNotes,
  String? prescriptionId,
  bool clearPrescriptionId = false,
  String? deliveryAddress,
}) {
  final totalMinor = orderTotalMinor(
    items: items,
    discountMinor: discountMinor,
  );
  return original.copyWith(
    items: List.unmodifiable(items),
    discountMinor: discountMinor,
    riderId: riderId,
    clearRiderId: clearRiderId,
    orderNotes: orderNotes,
    clearOrderNotes: orderNotes == null,
    prescriptionId: prescriptionId,
    clearPrescriptionId: clearPrescriptionId,
    deliveryAddress: deliveryAddress,
    totalAmount: minorUnitsToRupees(totalMinor),
  );
}

/// Supporting lookups for the order screens (all mock-backed).
final orderCustomersProvider = FutureProvider<List<Customer>>((ref) async {
  return ref.read(customerRepositoryProvider).getCustomers();
});

final orderMedicinesProvider = FutureProvider<List<Medicine>>((ref) async {
  return ref.read(medicineRepositoryProvider).getMedicines();
});

final orderRidersProvider = FutureProvider<List<Rider>>((ref) async {
  return ref.read(riderRepositoryProvider).getRiders();
});

final orderPrescriptionsProvider =
    FutureProvider.family<List<Prescription>, String>((ref, branchId) async {
      return ref
          .read(prescriptionRepositoryProvider)
          .getPrescriptions(branchId: branchId);
    });

/// Per-branch inventory, so the order form can show batch/expiry info
/// next to each medicine.
final orderInventoryProvider =
    FutureProvider.family<List<InventoryItem>, String>((ref, branchId) async {
      return ref
          .read(inventoryRepositoryProvider)
          .getInventory(branchId: branchId);
    });
