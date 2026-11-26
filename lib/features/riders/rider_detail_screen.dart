import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/widgets/design_system.dart';
import '../../core/widgets/pagination_controls.dart';
import '../../features/inventory/transfer_logic.dart';
import '../../models/order.dart';
import '../dashboard/dashboard_data.dart';
import '../orders/order_logic.dart';
import 'rider_logic.dart';
import 'rider_provider.dart';

/// Rider detail (SRS D-21, Week 4 Day 2).
///
/// Route `/riders/:id`.
///
/// The rider's contact + vehicle + branch + availability, his
/// current delivery (when one is live), his assigned-order history
/// (newest first, paged at 10 — D107), and — for an available rider
/// with a home branch — the delivery orders in his branch that
/// still need a rider, each with an Assign button. Assignment goes
/// through the same layer write path as the Order Detail button
/// (D121): the order's `riderId` and the rider's `currentOrderId`
/// are written together, so the two can never disagree. A failed
/// assignment (rider taken, order no longer editable) shows the
/// layer's reason instead of failing silently.
class RiderDetailScreen extends ConsumerStatefulWidget {
  const RiderDetailScreen({super.key, required this.riderId});

  final String riderId;

  @override
  ConsumerState<RiderDetailScreen> createState() =>
      _RiderDetailScreenState();
}

class _RiderDetailScreenState extends ConsumerState<RiderDetailScreen> {
  bool _working = false;
  String? _error;

  @override
  Widget build(BuildContext context) {
    final rider = ref.watch(riderByIdProvider(widget.riderId));
    if (rider == null) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionHeader(
              title: 'Rider not found',
              subtitle: 'There is no rider with this id.',
              actionLabel: 'Back to Riders',
              actionIcon: Icons.delivery_dining_outlined,
              onAction: () => context.go('/riders'),
            ),
          ],
        ),
      );
    }
    final availability = riderAvailability(rider);
    final history = ref.watch(riderOrdersProvider(rider.id));
    final unassigned = rider.branchId == null
        ? const <Order>[]
        : ref.watch(unassignedDeliveryOrdersProvider(rider.branchId!));
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            title: rider.name,
            subtitle: rider.phone,
            actionLabel: 'Back to Riders',
            actionIcon: Icons.delivery_dining_outlined,
            onAction: () => context.go('/riders'),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              StatusBadge(
                label: availability.label,
                kind: availability.kind,
              ),
              const SizedBox(width: 8),
              const StatusBadge(
                label: 'Demo — sample rider',
                kind: StatusKind.neutral,
              ),
            ],
          ),
          const SizedBox(height: 16),
          PharmaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _DetailRow(
                  label: 'Vehicle',
                  value: rider.vehicle ?? '—',
                ),
                _DetailRow(
                  label: 'Branch',
                  value: rider.branchId == null
                      ? 'Not set'
                      : branchDisplayName(rider.branchId!),
                ),
                _DetailRow(
                  label: 'Current delivery',
                  value: rider.currentOrderId ?? 'None — available',
                ),
              ],
            ),
          ),
          if (rider.currentOrderId != null) ...[
            const SizedBox(height: 16),
            PharmaButton(
              label: 'Open current delivery',
              icon: Icons.receipt_long_outlined,
              variant: PharmaButtonVariant.secondary,
              onPressed: () =>
                  context.go('/orders/${rider.currentOrderId!}'),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(
              _error!,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
          const SizedBox(height: 16),
          PharmaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SectionHeader(
                  title: 'Assigned orders',
                  subtitle: 'Delivery history, newest first',
                ),
                const SizedBox(height: 8),
                if (history.isEmpty)
                  const Text('No orders assigned to this rider yet.')
                else
                  PagedList<Order>(
                    items: history,
                    pageSize: 10,
                    emptyMessage: 'No orders assigned to this rider yet.',
                    itemBuilder: (context, order) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: InkWell(
                        onTap: () => context.go('/orders/${order.id}'),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Order ${order.id}',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            StatusBadge(
                              label: orderStatusLabel(order.status),
                              kind: _orderStatusKind(order.status),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (availability == RiderAvailability.available &&
              rider.branchId != null) ...[
            const SizedBox(height: 16),
            PharmaCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SectionHeader(
                    title: 'Assign an order',
                    subtitle:
                        'Delivery orders in this rider’s branch with no rider yet',
                  ),
                  const SizedBox(height: 8),
                  if (unassigned.isEmpty)
                    const Text(
                      'No delivery orders in this branch need a rider right now.',
                    )
                  else
                    for (final order in unassigned)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Order ${order.id} • ${order.deliveryAddress}',
                                style: theme.textTheme.bodyMedium,
                              ),
                            ),
                            PharmaButton(
                              label: 'Assign',
                              icon: Icons.delivery_dining_outlined,
                              loading: _working,
                              onPressed: _working
                                  ? null
                                  : () => _assign(order.id),
                            ),
                          ],
                        ),
                      ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _assign(String orderId) async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await ref
          .read(riderProvider.notifier)
          .assignRiderToOrder(orderId: orderId, riderId: widget.riderId);
    } on ArgumentError catch (error) {
      setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }
}

StatusKind _orderStatusKind(OrderStatus status) {
  final canonical = canonicalStatus(status);
  return switch (canonical) {
    OrderStatus.delivered => StatusKind.success,
    OrderStatus.cancelled => StatusKind.danger,
    OrderStatus.dispatched => StatusKind.info,
    _ => StatusKind.warning,
  };
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 140,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Text(value, style: theme.textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }
}
