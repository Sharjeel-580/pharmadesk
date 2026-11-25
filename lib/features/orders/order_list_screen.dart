import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/services/branch_context.dart';
import '../../core/utils/money.dart';
import '../../core/widgets/design_system.dart';
import '../../core/widgets/sync_status_widget.dart';
import '../../models/customer.dart';
import '../../models/order.dart';
import '../dashboard/dashboard_data.dart';
import 'order_logic.dart';
import 'orders_provider.dart';

/// Order queue (Day 4): the branch-scoped list of orders.
///
/// - Scoped to the active branch (Day 2 switcher); switching branches
///   re-scopes the list immediately.
/// - Filter chips per status (with counts) + search by order number,
///   customer name or phone. Newest first.
/// - Row tap opens the order detail screen (`/orders/:id`).
class OrderListScreen extends ConsumerStatefulWidget {
  const OrderListScreen({super.key});

  @override
  ConsumerState<OrderListScreen> createState() => _OrderListScreenState();
}

class _OrderListScreenState extends ConsumerState<OrderListScreen> {
  final _searchController = TextEditingController();
  String _query = '';
  OrderStatus? _statusFilter;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final branch = ref.watch(activeBranchProvider);
    final queueAsync = ref.watch(orderQueueProvider);
    final customersAsync = ref.watch(orderCustomersProvider);
    final customersById = <String, Customer>{
      for (final c in customersAsync.asData?.value ?? const <Customer>[])
        c.id: c,
    };

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            title: 'Orders',
            subtitle: '${branch.name} • newest first',
            actionLabel: 'New Order',
            actionIcon: Icons.add_shopping_cart_outlined,
            onAction: () => context.go('/orders/new'),
          ),
          const SizedBox(height: 12),
          // Sync status (Week 3 Day 3, D108/D109): order creation
          // enqueues one sync op through the production data layer.
          const Align(
            alignment: Alignment.centerLeft,
            child: SyncStatusChip(),
          ),
          const SizedBox(height: 16),
          PharmaSearchField(
            controller: _searchController,
            hintText: 'Search order no., customer or phone…',
            onChanged: (value) => setState(() => _query = value),
          ),
          const SizedBox(height: 12),
          queueAsync.when(
            loading: () => const Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SkeletonCard(),
                SizedBox(height: 12),
                SkeletonList(count: 4),
              ],
            ),
            error: (error, _) => PharmaEmptyState(
              icon: Icons.error_outline,
              title: 'Orders could not load',
              message: 'The demo data failed to load. Try again.',
              actionLabel: 'Retry',
              onAction: () => ref.invalidate(orderQueueProvider),
            ),
            data: (orders) {
              final scoped = orders
                  .where((order) => order.branchId == branch.id)
                  .toList();
              final counts = orderStatusCounts(scoped);
              final filtered = filterOrders(
                orders: orders,
                branchId: branch.id,
                statusFilter: _statusFilter,
                query: _query,
                customersById: customersById,
              );
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _StatusFilterRow(
                    counts: counts,
                    total: scoped.length,
                    selected: _statusFilter,
                    onSelected: (status) =>
                        setState(() => _statusFilter = status),
                  ),
                  const SizedBox(height: 12),
                  if (filtered.isEmpty)
                    PharmaEmptyState(
                      icon: Icons.receipt_long_outlined,
                      title: _query.isNotEmpty || _statusFilter != null
                          ? 'No orders match'
                          : 'No orders in this branch yet',
                      message: _query.isNotEmpty || _statusFilter != null
                          ? 'Try a different search or status filter.'
                          : 'Create the first order for ${branch.name}.',
                      actionLabel: 'New Order',
                      onAction: () => context.go('/orders/new'),
                    )
                  else
                    PharmaCard(
                      padding: EdgeInsets.zero,
                      child: Column(
                        children: [
                          for (var i = 0; i < filtered.length; i++) ...[
                            _OrderRow(
                              order: filtered[i],
                              customer: customersById[filtered[i].customerId],
                              onTap: () =>
                                  context.go('/orders/${filtered[i].id}'),
                            ),
                            if (i < filtered.length - 1)
                              const Divider(height: 1),
                          ],
                        ],
                      ),
                    ),
                  const SizedBox(height: 8),
                  Text(
                    '${filtered.length} order(s)',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

/// Status filter chips: All + one per canonical status, with counts.
class _StatusFilterRow extends StatelessWidget {
  const _StatusFilterRow({
    required this.counts,
    required this.total,
    required this.selected,
    required this.onSelected,
  });

  final Map<OrderStatus, int> counts;
  final int total;
  final OrderStatus? selected;
  final ValueChanged<OrderStatus?> onSelected;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        PharmaChip(
          label: 'All ($total)',
          selected: selected == null,
          onSelected: (_) => onSelected(null),
        ),
        for (final status in orderFlow)
          PharmaChip(
            label:
                '${orderStatusLabel(status)} (${counts[status] ?? 0})',
            selected: selected != null &&
                canonicalStatus(selected!) == status,
            onSelected: (_) => onSelected(status),
          ),
        PharmaChip(
          label: 'Cancelled (${counts[OrderStatus.cancelled] ?? 0})',
          selected: selected != null &&
              canonicalStatus(selected!) == OrderStatus.cancelled,
          onSelected: (_) => onSelected(OrderStatus.cancelled),
        ),
      ],
    );
  }
}

class _OrderRow extends StatelessWidget {
  const _OrderRow({
    required this.order,
    required this.customer,
    required this.onTap,
  });

  final Order order;
  final Customer? customer;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final created = order.createdAt;
    final timeLabel = created == null
        ? ''
        : '${created.day}/${created.month}/${created.year} • '
              '${created.hour.toString().padLeft(2, '0')}:'
              '${created.minute.toString().padLeft(2, '0')}';
    final customerLabel = order.customerId == 'walk-in'
        ? 'Walk-in customer'
        : (customer?.name ?? 'Customer ${order.customerId}');
    final sourceIcon = switch (order.source) {
      OrderSource.phone => Icons.phone_outlined,
      OrderSource.whatsapp => Icons.chat_outlined,
      OrderSource.walkIn => Icons.person_outline,
    };
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(sourceIcon, color: theme.colorScheme.primary, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    order.id,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$customerLabel • ${fulfillmentLabel(order.fulfillment)}',
                    style: theme.textTheme.bodySmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (timeLabel.isNotEmpty)
                    Text(timeLabel, style: theme.textTheme.bodySmall),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  formatPkr(rupeesToMinorUnits(order.totalAmount)),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                StatusBadge(
                  label: orderStatusLabel(order.status),
                  kind: orderStatusKind(order.status),
                ),
              ],
            ),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right, size: 20),
          ],
        ),
      ),
    );
  }
}
