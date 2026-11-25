import '../../models/inventory_item.dart';
import '../../models/order.dart';
import '../../models/prescription.dart';
import '../../models/purchase_order.dart';

/// Day 7 notifications — in-app alerts computed from mock data
/// (SRS O-7, demo scope: in-app only; no push/SMS/WhatsApp provider
/// in the demo).
///
/// Alerts are DERIVED, never stored: the list is rebuilt from the
/// live orders / inventory / prescriptions / purchase orders every
/// time it is read, so a new low-stock batch or a newly pending
/// prescription shows up without any sync step. Only the read/unread
/// state is kept (in-memory, in the notifications provider).

/// Where tapping the notification goes.
enum NotificationKind {
  lowStock,
  nearExpiry,
  expired,
  pendingPrescription,
  newOrder,
  purchaseApproval,
}

class AppNotification {
  const AppNotification({
    required this.id,
    required this.kind,
    required this.title,
    required this.body,
    required this.route,
    required this.createdAt,
    this.isRead = false,
  });

  final String id;
  final NotificationKind kind;
  final String title;
  final String body;

  /// Route the tap navigates to.
  final String route;
  final DateTime createdAt;
  final bool isRead;

  AppNotification copyWith({bool? isRead}) {
    return AppNotification(
      id: id,
      kind: kind,
      title: title,
      body: body,
      route: route,
      createdAt: createdAt,
      isRead: isRead ?? this.isRead,
    );
  }
}

/// Builds the alert list for [branchId] (`null` = all branches).
///
/// Caps: one summary notification per stock category, one per pending
/// prescription (max 5, newest first), one per PO awaiting approval,
/// one summary for today's new orders. Newest first overall.
List<AppNotification> buildNotifications({
  required List<Order> orders,
  required List<InventoryItem> inventory,
  required List<Prescription> prescriptions,
  required List<PurchaseOrder> purchaseOrders,
  String? branchId,
  required DateTime now,
}) {
  final today = DateTime(now.year, now.month, now.day);
  final scopedOrders = branchId == null
      ? orders
      : orders.where((order) => order.branchId == branchId).toList();
  final scopedInventory = branchId == null
      ? inventory
      : inventory.where((item) => item.branchId == branchId).toList();
  final scopedPrescriptions = branchId == null
      ? prescriptions
      : prescriptions.where((rx) {
          final prefix = branchId == 'branch-dha-main'
              ? 'rx-dha-'
              : 'rx-glb-';
          return rx.id.startsWith(prefix);
        }).toList();
  final scopedPos = branchId == null
      ? purchaseOrders
      : purchaseOrders.where((po) => po.branchId == branchId).toList();

  final notifications = <AppNotification>[];

  // Stock alerts (per batch row, as on the dashboard).
  var lowStock = 0;
  var nearExpiry = 0;
  var expired = 0;
  for (final item in scopedInventory) {
    if (item.isLowStock) lowStock++;
    final expiry = item.expiryDate;
    if (expiry == null) continue;
    final expiryDay = DateTime(expiry.year, expiry.month, expiry.day);
    if (expiryDay.isBefore(today)) {
      expired++;
    } else if (!expiryDay.isAfter(today.add(const Duration(days: 30)))) {
      nearExpiry++;
    }
  }
  if (lowStock > 0) {
    notifications.add(
      AppNotification(
        id: 'notif-lowstock-${branchId ?? 'all'}',
        kind: NotificationKind.lowStock,
        title: 'Low stock — $lowStock batches',
        body:
            '$lowStock batch(es) are at or below their low-stock level. '
            'Review the inventory and reorder.',
        route: '/inventory',
        createdAt: now,
      ),
    );
  }
  if (nearExpiry > 0) {
    notifications.add(
      AppNotification(
        id: 'notif-expiry-${branchId ?? 'all'}',
        kind: NotificationKind.nearExpiry,
        title: 'Near expiry — $nearExpiry batches',
        body:
            '$nearExpiry batch(es) expire within 30 days. Check the '
            'expiry radar and rotate stock (FEFO).',
        route: '/inventory',
        createdAt: now,
      ),
    );
  }
  if (expired > 0) {
    notifications.add(
      AppNotification(
        id: 'notif-expired-${branchId ?? 'all'}',
        kind: NotificationKind.expired,
        title: 'Expired stock — $expired batches',
        body:
            '$expired batch(es) have expired. Expired stock can never '
            'be sold — quarantine or return it.',
        route: '/inventory',
        createdAt: now,
      ),
    );
  }

  // Pending prescriptions (newest first, max 5).
  final pending = scopedPrescriptions
      .where((rx) => rx.status == PrescriptionStatus.pending)
      .toList()
    ..sort((a, b) {
      final aTime = a.createdAt;
      final bTime = b.createdAt;
      if (aTime == null && bTime == null) return 0;
      if (aTime == null) return 1;
      if (bTime == null) return -1;
      return bTime.compareTo(aTime);
    });
  for (final rx in pending.take(5)) {
    notifications.add(
      AppNotification(
        id: 'notif-rx-${rx.id}',
        kind: NotificationKind.pendingPrescription,
        title: 'Prescription awaiting review',
        body:
            'Prescription ${rx.id} is still pending pharmacist review. '
            'Orders linked to it cannot be dispatched yet.',
        route: '/prescriptions/${rx.id}',
        createdAt: rx.createdAt ?? now,
      ),
    );
  }

  // Purchase orders awaiting approval.
  final awaitingApproval = scopedPos
      .where((po) => po.status == PurchaseOrderStatus.draft)
      .toList();
  for (final po in awaitingApproval) {
    notifications.add(
      AppNotification(
        id: 'notif-po-${po.id}',
        kind: NotificationKind.purchaseApproval,
        title: 'Purchase order awaiting approval',
        body:
            '${po.poNumber} is still a draft. Approve it to receive '
            'stock against it.',
        route: '/purchases/${po.id}',
        createdAt: po.createdAt ?? now,
      ),
    );
  }

  // Today's new orders (summary).
  bool isToday(DateTime? value) =>
      value != null &&
      value.year == today.year &&
      value.month == today.month &&
      value.day == today.day;
  final todaysNew = scopedOrders
      .where(
        (order) =>
            isToday(order.createdAt) &&
            (order.status == OrderStatus.newOrder ||
                order.status == OrderStatus.placed),
      )
      .length;
  if (todaysNew > 0) {
    notifications.add(
      AppNotification(
        id: 'notif-orders-${branchId ?? 'all'}',
        kind: NotificationKind.newOrder,
        title: '$todaysNew new order(s) today',
        body:
            '$todaysNew order(s) arrived today and are waiting in the '
            'queue. Open the order queue to confirm them.',
        route: '/orders',
        createdAt: now,
      ),
    );
  }

  notifications.sort((a, b) => b.createdAt.compareTo(a.createdAt));
  return notifications;
}
