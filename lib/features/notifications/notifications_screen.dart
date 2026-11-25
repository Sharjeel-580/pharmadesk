import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/widgets/design_system.dart';
import 'notifications_logic.dart';
import 'notifications_provider.dart';

/// Notifications center (Day 7, SRS O-7, D-32/M-20).
///
/// Route `/notifications`.
///
/// In-app alerts computed from live mock data (low stock, near
/// expiry, expired stock, pending prescriptions, purchase orders
/// awaiting approval, today's new orders). Tap a row to open the
/// relevant screen; mark individual alerts read/unread, or mark them
/// all read. The shell bell shows the unread count.
class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notificationsAsync = ref.watch(notificationsProvider);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            title: 'Notifications',
            subtitle: 'Alerts computed from live demo data — nothing is stored',
            actionLabel: 'Mark all read',
            actionIcon: Icons.done_all_outlined,
            onAction: () {
              final notifications =
                  notificationsAsync.asData?.value ?? const [];
              ref
                  .read(notificationReadProvider.notifier)
                  .markAllRead(notifications.map((n) => n.id));
            },
          ),
          const SizedBox(height: 16),
          notificationsAsync.when(
            loading: () => const SkeletonList(count: 4),
            error: (error, _) => PharmaEmptyState(
              icon: Icons.error_outline,
              title: 'Notifications could not load',
              message: 'The demo data failed to load. Try again.',
              actionLabel: 'Retry',
              onAction: () => ref.invalidate(notificationsProvider),
            ),
            data: (notifications) {
              if (notifications.isEmpty) {
                return const PharmaEmptyState(
                  icon: Icons.notifications_none_outlined,
                  title: 'All clear',
                  message:
                      'No alerts right now — no low stock, no expiring batches, no pending prescriptions.',
                );
              }
              final unread = notifications.where((n) => !n.isRead).length;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  StatusBadge(
                    label: unread == 0
                        ? 'All notifications read'
                        : '$unread unread',
                    kind: unread == 0
                        ? StatusKind.success
                        : StatusKind.warning,
                    icon: Icons.notifications_outlined,
                  ),
                  const SizedBox(height: 12),
                  PharmaCard(
                    child: Column(
                      children: [
                        for (var i = 0; i < notifications.length; i++) ...[
                          if (i > 0) const Divider(height: 1),
                          _NotificationRow(
                            notification: notifications[i],
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 12),
          Text(
            'Demo scope: in-app alerts only. Push / SMS / WhatsApp '
            'delivery needs a provider (SRS O-7) and is a production '
            'decision — see docs/known-limitations.md.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _NotificationRow extends ConsumerWidget {
  const _NotificationRow({required this.notification});

  final AppNotification notification;

  IconData get _icon => switch (notification.kind) {
    NotificationKind.lowStock => Icons.inventory_2_outlined,
    NotificationKind.nearExpiry => Icons.schedule_outlined,
    NotificationKind.expired => Icons.dangerous_outlined,
    NotificationKind.pendingPrescription => Icons.description_outlined,
    NotificationKind.newOrder => Icons.receipt_long_outlined,
    NotificationKind.purchaseApproval => Icons.shopping_cart_outlined,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: notification.isRead
            ? theme.colorScheme.surfaceContainerHighest
            : theme.colorScheme.primary.withValues(alpha: 0.12),
        child: Icon(
          _icon,
          color: notification.isRead
              ? theme.colorScheme.onSurfaceVariant
              : theme.colorScheme.primary,
        ),
      ),
      title: Text(
        notification.title,
        style: TextStyle(
          fontWeight: notification.isRead
              ? FontWeight.w500
              : FontWeight.w700,
        ),
      ),
      subtitle: Text(notification.body),
      trailing: IconButton(
        tooltip: notification.isRead ? 'Mark unread' : 'Mark read',
        icon: Icon(
          notification.isRead
              ? Icons.mark_email_unread_outlined
              : Icons.mark_email_read_outlined,
        ),
        onPressed: () {
          final notifier = ref.read(notificationReadProvider.notifier);
          if (notification.isRead) {
            notifier.markUnread(notification.id);
          } else {
            notifier.markRead(notification.id);
          }
        },
      ),
      onTap: () => context.go(notification.route),
    );
  }
}
