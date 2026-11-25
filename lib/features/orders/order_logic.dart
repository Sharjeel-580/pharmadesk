import '../../core/utils/money.dart';
import '../../models/customer.dart';
import '../../models/order.dart';
import '../../models/prescription.dart';
import '../dashboard/dashboard_data.dart';

/// Day 4 order logic — pure functions, no widgets, no providers, so
/// they are unit-testable without pumping anything.
///
/// Status flow (D25): New → Confirmed → Processing → Ready →
/// Dispatched → Delivered, plus Cancelled. The Day 0 legacy values
/// (`placed`, `preparing`, `outForDelivery`) map onto the same flow —
/// see [canonicalStatus] — so seeded orders and new orders advance
/// through one identical sequence.

/// The canonical Week 1 flow, in order (Cancelled is a side exit).
const orderFlow = <OrderStatus>[
  OrderStatus.newOrder,
  OrderStatus.confirmed,
  OrderStatus.processing,
  OrderStatus.ready,
  OrderStatus.dispatched,
  OrderStatus.delivered,
];

/// Maps any stored status onto its canonical Week 1 step. Legacy
/// values keep their stored name (D10) but behave identically.
OrderStatus canonicalStatus(OrderStatus status) => switch (status) {
  OrderStatus.placed => OrderStatus.newOrder,
  OrderStatus.preparing => OrderStatus.processing,
  OrderStatus.outForDelivery => OrderStatus.dispatched,
  _ => status,
};

/// The next step in the flow, or `null` when the order is terminal
/// (Delivered or Cancelled) and cannot advance.
OrderStatus? nextOrderStatus(OrderStatus status) {
  final canonical = canonicalStatus(status);
  if (canonical == OrderStatus.delivered ||
      canonical == OrderStatus.cancelled) {
    return null;
  }
  final index = orderFlow.indexOf(canonical);
  if (index == -1 || index + 1 >= orderFlow.length) return null;
  return orderFlow[index + 1];
}

/// True when the order can move one step forward.
bool canAdvance(OrderStatus status) => nextOrderStatus(status) != null;

/// True when the order can be cancelled: any live order up to (but not
/// including) Delivered. Delivered and already-Cancelled orders cannot.
bool canCancel(OrderStatus status) {
  final canonical = canonicalStatus(status);
  return canonical != OrderStatus.delivered &&
      canonical != OrderStatus.cancelled;
}

/// True when the order can still be edited: everything until Delivered.
/// Cancelled orders are read-only too — a cancelled order is history.
bool canEdit(OrderStatus status) {
  final canonical = canonicalStatus(status);
  return canonical != OrderStatus.delivered &&
      canonical != OrderStatus.cancelled;
}

/// Label for the advance button, e.g. "Mark Confirmed".
String advanceLabel(OrderStatus status) {
  final next = nextOrderStatus(status);
  if (next == null) return '';
  return 'Mark ${orderStatusLabel(next)}';
}

/// Why an advance to [next] is blocked, or `null` when it is allowed.
///
/// Prescription guard (Day 0 model rule, SRS §8): an order with a
/// linked prescription that is still `pending` review must never be
/// dispatched — the pharmacist has to clear it first (Day 7 review).
/// Week 2 Day 5 (D90): an APPROVED prescription whose validity has
/// expired blocks dispatch too — the medicine was cleared against
/// a prescription that is no longer valid. Pass
/// [linkedPrescriptionValidUntil] (null = no expiry recorded, so
/// the validity rule does not apply) and [now] for the check; both
/// default to "no expiry / now".
String? advanceBlockedReason({
  required Order order,
  required OrderStatus next,
  PrescriptionStatus? linkedPrescriptionStatus,
  DateTime? linkedPrescriptionValidUntil,
  DateTime? now,
}) {
  if (canonicalStatus(next) == OrderStatus.dispatched) {
    if (linkedPrescriptionStatus == PrescriptionStatus.pending) {
      return 'Prescription ${order.prescriptionId ?? ''} is still pending '
          'pharmacist review — the order cannot be dispatched yet.';
    }
    if (linkedPrescriptionStatus == PrescriptionStatus.approved &&
        linkedPrescriptionValidUntil != null) {
      final reference = now ?? DateTime.now();
      final refDay = DateTime(
        reference.year,
        reference.month,
        reference.day,
      );
      final lastDay = DateTime(
        linkedPrescriptionValidUntil.year,
        linkedPrescriptionValidUntil.month,
        linkedPrescriptionValidUntil.day,
      );
      if (lastDay.isBefore(refDay)) {
        return 'Prescription ${order.prescriptionId ?? ''} was approved '
            'but its validity expired on '
            '${lastDay.day}/${lastDay.month}/${lastDay.year} — ask the '
            'patient for a new prescription before dispatch.';
      }
    }
  }
  return null;
}

/// One step of the status timeline shown on the order detail screen.
class OrderTimelineStep {
  const OrderTimelineStep({
    required this.status,
    required this.state,
    this.timestamp,
  });

  final OrderStatus status;
  final OrderTimelineState state;

  /// Only the steps the data actually timestamps carry one: New is
  /// stamped with `createdAt`, the current step with `updatedAt`.
  /// Completed steps in between carry no invented timestamp.
  final DateTime? timestamp;
}

enum OrderTimelineState { done, current, upcoming }

/// Builds the 6-step timeline for an order. Cancelled orders show the
/// flow up to their (cancelled) state with a separate cancelled note —
/// the caller renders the cancelled banner, not a timeline step.
List<OrderTimelineStep> orderTimeline(Order order) {
  final canonical = canonicalStatus(order.status);
  final currentIndex = orderFlow.indexOf(canonical);
  return [
    for (var i = 0; i < orderFlow.length; i++)
      OrderTimelineStep(
        status: orderFlow[i],
        state: order.status == OrderStatus.cancelled
            ? OrderTimelineState.upcoming
            : i < currentIndex
            ? OrderTimelineState.done
            : i == currentIndex
            ? OrderTimelineState.current
            : OrderTimelineState.upcoming,
        timestamp: i == 0
            ? order.createdAt
            : i == currentIndex && currentIndex > 0
            ? order.updatedAt
            : null,
      ),
  ];
}

/// Human label for an order source.
String orderSourceLabel(OrderSource source) => switch (source) {
  OrderSource.phone => 'Phone',
  OrderSource.whatsapp => 'WhatsApp',
  OrderSource.walkIn => 'Walk-in',
};

/// Human label for a fulfilment type.
String fulfillmentLabel(FulfillmentType type) => switch (type) {
  FulfillmentType.delivery => 'Delivery',
  FulfillmentType.pickup => 'Pickup',
};

/// Subtotal in int minor units (paisa) for a list of lines.
int orderSubtotalMinor(List<OrderItem> items) =>
    items.fold(0, (sum, item) => sum + item.lineTotalMinor);

/// Total payable in int minor units: subtotal minus discount, never
/// below zero. All money stays `int` — no doubles anywhere (D6).
int orderTotalMinor({
  required List<OrderItem> items,
  int discountMinor = 0,
}) => totalAfterDiscountAndTax(
  subtotalMinorUnits: orderSubtotalMinor(items),
  discountMinor: discountMinor,
);

/// Filters the queue: branch scope, then status, then free text.
/// [statusFilter] matches by canonical status, so a "Processing"
/// filter catches both `processing` and legacy `preparing` orders.
/// The query matches order id, customer name and customer phone
/// (case-insensitive, partial).
List<Order> filterOrders({
  required List<Order> orders,
  required String branchId,
  OrderStatus? statusFilter,
  String query = '',
  Map<String, Customer> customersById = const {},
}) {
  final needle = query.trim().toLowerCase();
  final scoped = orders.where((order) => order.branchId == branchId);
  return scoped.where((order) {
    if (statusFilter != null &&
        canonicalStatus(order.status) != canonicalStatus(statusFilter)) {
      return false;
    }
    if (needle.isEmpty) return true;
    final customer = customersById[order.customerId];
    final haystacks = [
      order.id.toLowerCase(),
      customer?.name.toLowerCase() ?? '',
      customer?.phone.toLowerCase() ?? '',
      customer?.phone.replaceAll('-', '').toLowerCase() ?? '',
    ];
    return haystacks.any((haystack) => haystack.contains(needle));
  }).toList()..sort((a, b) {
    // Newest first; orders without a timestamp go last.
    final aTime = a.createdAt;
    final bTime = b.createdAt;
    if (aTime == null && bTime == null) return 0;
    if (aTime == null) return 1;
    if (bTime == null) return -1;
    return bTime.compareTo(aTime);
  });
}

/// Counts per canonical status, for the queue's filter chips.
Map<OrderStatus, int> orderStatusCounts(List<Order> orders) {
  final counts = <OrderStatus, int>{};
  for (final order in orders) {
    final canonical = canonicalStatus(order.status);
    counts[canonical] = (counts[canonical] ?? 0) + 1;
  }
  return counts;
}

/// Validates a create/edit order form. Returns the list of problems
/// (empty = valid). The form must fix every problem before saving.
List<String> validateOrderForm({
  String? customerId,
  bool isWalkIn = false,
  required List<OrderItem> items,
  int discountMinor = 0,
  required FulfillmentType fulfillment,
  String deliveryAddress = '',
}) {
  final errors = <String>[];
  if (!isWalkIn && (customerId == null || customerId.isEmpty)) {
    errors.add('Select a customer or choose Walk-in.');
  }
  if (items.isEmpty) {
    errors.add('Add at least one medicine to the order.');
  }
  for (final item in items) {
    if (item.quantity < 1) {
      errors.add('${item.medicineName}: quantity must be at least 1.');
    }
  }
  if (discountMinor < 0) {
    errors.add('Discount cannot be negative.');
  }
  if (discountMinor > orderSubtotalMinor(items)) {
    errors.add('Discount cannot be more than the subtotal.');
  }
  if (fulfillment == FulfillmentType.delivery &&
      deliveryAddress.trim().isEmpty) {
    errors.add('Delivery needs a delivery address.');
  }
  return errors;
}
