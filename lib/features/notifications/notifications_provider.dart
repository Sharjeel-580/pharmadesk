import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/branch_context.dart';
import '../../core/services/repositories.dart';
import 'notifications_logic.dart';

/// Day 7 notifications state.
///
/// The alert list is DERIVED from the live repositories (orders,
/// inventory, prescriptions, purchase orders) every time it is read,
/// so it never goes stale — only the read/unread state is kept, in
/// memory, in [NotificationReadNotifier]. Mutations that change the
/// underlying data (PO receive, prescription review, stock operations)
/// invalidate [notificationsProvider].

/// Holds the ids of notifications the user has marked as read.
class NotificationReadNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => {};

  void markRead(String id) {
    state = {...state, id};
  }

  void markUnread(String id) {
    final next = Set<String>.of(state)..remove(id);
    state = next;
  }

  void markAllRead(Iterable<String> ids) {
    state = {...state, ...ids};
  }
}

final notificationReadProvider =
    NotifierProvider<NotificationReadNotifier, Set<String>>(
      NotificationReadNotifier.new,
    );

/// The alert list for the active branch, newest first, with read
/// state applied from [notificationReadProvider].
final notificationsProvider = FutureProvider<List<AppNotification>>((
  ref,
) async {
  final branch = ref.watch(activeBranchProvider);
  final readIds = ref.watch(notificationReadProvider);
  final orders = await ref.read(orderRepositoryProvider).getOrders();
  final inventory = await ref.read(inventoryRepositoryProvider).getInventory();
  final prescriptions = await ref
      .read(prescriptionRepositoryProvider)
      .getPrescriptions();
  final purchaseOrders = await ref
      .read(purchaseOrderRepositoryProvider)
      .getPurchaseOrders();
  final built = buildNotifications(
    orders: orders,
    inventory: inventory,
    prescriptions: prescriptions,
    purchaseOrders: purchaseOrders,
    branchId: branch.id,
    now: DateTime.now(),
  );
  return [
    for (final notification in built)
      notification.copyWith(isRead: readIds.contains(notification.id)),
  ];
});

/// Unread alert count for the active branch (shell bell badge).
final unreadNotificationsProvider = FutureProvider<int>((ref) async {
  final notifications = await ref.watch(notificationsProvider.future);
  return notifications.where((n) => !n.isRead).length;
});
