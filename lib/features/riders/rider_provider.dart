import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/data/production_data_layer.dart';
import '../../core/services/repositories.dart';
import '../../core/widgets/sync_status_widget.dart';
import '../../models/order.dart';
import '../../models/rider.dart';
import '../authentication/auth_state.dart';
import '../orders/orders_provider.dart';

/// Rider state (Week 4 Day 2, D119/D121).
///
/// [RiderNotifier] owns the in-memory rider list for the session:
/// it loads from the (mock) repository once, and assignment writes
/// go through the production data layer ([assignRiderToOrder]) and
/// then refresh the list, so a rider's "On delivery" state updates
/// immediately. Week 2 swaps the repository for Firestore behind
/// the same interface; the screens do not change.
class RiderNotifier extends AsyncNotifier<List<Rider>> {
  @override
  Future<List<Rider>> build() async {
    final repo = ref.read(riderRepositoryProvider);
    return repo.getRiders();
  }

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(
      () => ref.read(riderRepositoryProvider).getRiders(),
    );
  }

  /// Assigns (or unassigns, with [riderId] null) a rider to an
  /// order through the production data layer — the ONE assignment
  /// write path (D121). Returns the updated order.
  Future<Order> assignRiderToOrder({
    required String orderId,
    required String? riderId,
  }) async {
    final user = ref.read(authProvider);
    final updated = await ref
        .read(productionDataLayerProvider)
        .assignRider(
          orderId: orderId,
          riderId: riderId,
          actorId: user?.uid ?? demoActorId,
          actorName: user?.displayName ?? demoActorName,
        );
    await refresh();
    ref.invalidate(orderQueueProvider);
    ref.invalidate(orderRidersProvider);
    ref.invalidate(syncStatusProvider);
    return updated;
  }
}

final riderProvider = AsyncNotifierProvider<RiderNotifier, List<Rider>>(
  RiderNotifier.new,
);

/// One rider by id, from the list (refreshes when the list does).
final riderByIdProvider = Provider.family<Rider?, String>((ref, id) {
  final riders = ref.watch(riderProvider).asData?.value ?? const [];
  for (final rider in riders) {
    if (rider.id == id) return rider;
  }
  return null;
});

/// Orders assigned to one rider, newest first — the rider's
/// delivery history on the detail screen.
final riderOrdersProvider = Provider.family<List<Order>, String>((
  ref,
  riderId,
) {
  final orders = ref.watch(orderQueueProvider).asData?.value ?? const [];
  final assigned = orders
      .where((order) => order.riderId == riderId)
      .toList();
  assigned.sort((a, b) {
    final aTime = a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    final bTime = b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    return bTime.compareTo(aTime);
  });
  return assigned;
});

/// Delivery orders in [branchId] that still need a rider: delivery
/// fulfilment, no rider yet, still editable (not Delivered /
/// Cancelled) — the "assign this rider" list on the rider detail
/// screen.
final unassignedDeliveryOrdersProvider =
    Provider.family<List<Order>, String>((ref, branchId) {
      final orders =
          ref.watch(orderQueueProvider).asData?.value ?? const [];
      return orders
          .where(
            (order) =>
                order.branchId == branchId &&
                order.fulfillment == FulfillmentType.delivery &&
                order.riderId == null &&
                order.status != OrderStatus.delivered &&
                order.status != OrderStatus.cancelled,
          )
          .toList();
    });
