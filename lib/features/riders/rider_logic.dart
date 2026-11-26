import '../../core/widgets/badges.dart';
import '../../models/order.dart';
import '../../models/rider.dart';

/// Rider logic (Week 4 Day 2, D119/D121) — pure functions, no
/// widgets, no providers, so they are unit-testable without pumping
/// anything.

/// Availability of a rider, from the rider row alone: a rider is
/// "On delivery" when he has a live order, "Available" when active
/// with no live order, "Inactive" otherwise. The live order is the
/// single source of truth — the layer sets `currentOrderId` when it
/// assigns and clears it when it unassigns, so this can never
/// disagree with the order queue.
enum RiderAvailability { available, onDelivery, inactive }

RiderAvailability riderAvailability(Rider rider) {
  if (!rider.active) return RiderAvailability.inactive;
  if (rider.currentOrderId != null) {
    return RiderAvailability.onDelivery;
  }
  return RiderAvailability.available;
}

extension RiderAvailabilityLabel on RiderAvailability {
  String get label => switch (this) {
    RiderAvailability.available => 'Available',
    RiderAvailability.onDelivery => 'On delivery',
    RiderAvailability.inactive => 'Inactive',
  };

  StatusKind get kind => switch (this) {
    RiderAvailability.available => StatusKind.success,
    RiderAvailability.onDelivery => StatusKind.info,
    RiderAvailability.inactive => StatusKind.neutral,
  };
}

/// True when [rider] may take [order]: active, in the order's
/// branch (when the rider has a home branch), and not already out
/// on another order. The layer re-checks all three — this is the
/// UI's gate so an impossible assignment never reaches it.
bool canAssignRiderToOrder(Rider rider, Order order) {
  if (!rider.active) return false;
  if (order.fulfillment != FulfillmentType.delivery) return false;
  if (order.status == OrderStatus.delivered ||
      order.status == OrderStatus.cancelled) {
    return false;
  }
  if (rider.branchId != null && rider.branchId != order.branchId) {
    return false;
  }
  if (rider.currentOrderId != null &&
      rider.currentOrderId != order.id) {
    return false;
  }
  return true;
}
