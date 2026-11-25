import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/utils/money.dart';
import '../../core/widgets/design_system.dart';
import '../../models/order.dart';
import '../../models/prescription.dart';
import '../dashboard/dashboard_data.dart';
import 'order_logic.dart';
import 'orders_provider.dart';

/// Order detail (Day 4): everything about one order, all real data
/// from the mock repository — customer, source, items + prices, totals,
/// discount, delivery vs pickup, rider, notes, linked prescription and
/// the status timeline — plus the status actions (advance / cancel /
/// edit) with their guards.
class OrderDetailScreen extends ConsumerWidget {
  const OrderDetailScreen({super.key, required this.orderId});

  final String orderId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final order = ref.watch(orderByIdProvider(orderId));

    if (order == null) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: PharmaEmptyState(
          icon: Icons.receipt_long_outlined,
          title: 'Order not found',
          message: 'There is no order with id "$orderId" in this demo.',
          actionLabel: 'Back to Orders',
          onAction: () => context.go('/orders'),
        ),
      );
    }

    final customers = ref.watch(orderCustomersProvider).asData?.value ?? [];
    final customer = order.customerId == 'walk-in'
        ? null
        : customers.where((c) => c.id == order.customerId).firstOrNull;
    final riders = ref.watch(orderRidersProvider).asData?.value ?? [];
    final rider = riders.where((r) => r.id == order.riderId).firstOrNull;
    final prescriptions = ref
            .watch(orderPrescriptionsProvider(order.branchId))
            .asData
            ?.value ??
        [];
    final prescription = prescriptions
        .where((rx) => rx.id == order.prescriptionId)
        .firstOrNull;
    final timeline = orderTimeline(order);
    final isCancelled = canonicalStatus(order.status) == OrderStatus.cancelled;
    final isDelivered = canonicalStatus(order.status) == OrderStatus.delivered;
    final next = nextOrderStatus(order.status);
    final blockedReason = next == null
        ? null
        : advanceBlockedReason(
            order: order,
            next: next,
            linkedPrescriptionStatus: prescription?.status,
            linkedPrescriptionValidUntil: prescription?.validUntil,
          );

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            title: order.id,
            subtitle:
                'Placed ${_formatDateTime(order.createdAt)} • ${orderSourceLabel(order.source)} order',
            actionLabel: 'All Orders',
            actionIcon: Icons.receipt_long_outlined,
            onAction: () => context.go('/orders'),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              StatusBadge(
                label: orderStatusLabel(order.status),
                kind: orderStatusKind(order.status),
              ),
              const SizedBox(width: 8),
              StatusBadge(
                label: fulfillmentLabel(order.fulfillment),
                kind: StatusKind.neutral,
                icon: order.fulfillment == FulfillmentType.delivery
                    ? Icons.delivery_dining_outlined
                    : Icons.store_outlined,
              ),
              const SizedBox(width: 8),
              StatusBadge(
                label: 'Cash on delivery',
                kind: StatusKind.neutral,
                icon: Icons.payments_outlined,
              ),
            ],
          ),
          if (isCancelled) ...[
            const SizedBox(height: 16),
            _NoticeBanner(
              icon: Icons.cancel_outlined,
              title: 'This order was cancelled',
              message:
                  'Cancelled orders are read-only history — they cannot be edited, advanced or cancelled again.',
              kind: StatusKind.danger,
            ),
          ],
          if (isDelivered) ...[
            const SizedBox(height: 16),
            const _NoticeBanner(
              icon: Icons.check_circle_outline,
              title: 'Delivered — read-only',
              message:
                  'This order is complete. Delivered orders cannot be edited or cancelled.',
              kind: StatusKind.success,
            ),
          ],
          if (prescription?.status == PrescriptionStatus.pending) ...[
            const SizedBox(height: 16),
            const _NoticeBanner(
              icon: Icons.description_outlined,
              title: 'Prescription pending review',
              message:
                  'The linked prescription is still awaiting pharmacist review. This order cannot be dispatched until it is cleared.',
              kind: StatusKind.warning,
            ),
          ],
          const SizedBox(height: 16),
          PharmaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SectionHeader(title: 'Customer'),
                const SizedBox(height: 8),
                _DetailRow(
                  label: 'Name',
                  value: order.customerId == 'walk-in'
                      ? 'Walk-in customer'
                      : (customer?.name ?? order.customerId),
                ),
                if (customer != null) ...[
                  _DetailRow(label: 'Phone', value: customer.phone),
                  _DetailRow(
                    label: 'Address',
                    value: order.deliveryAddress,
                  ),
                ] else
                  _DetailRow(
                    label: 'Address',
                    value: order.deliveryAddress,
                  ),
                _DetailRow(
                  label: 'Source',
                  value: orderSourceLabel(order.source),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          PharmaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SectionHeader(title: 'Items'),
                const SizedBox(height: 8),
                for (final item in order.items) ...[
                  _ItemRow(item: item),
                  const Divider(height: 1),
                ],
                const SizedBox(height: 12),
                _MoneyRow(
                  label: 'Subtotal',
                  valueMinor: order.subtotalMinor,
                ),
                if (order.discountMinor > 0)
                  _MoneyRow(
                    label: 'Discount',
                    valueMinor: -order.discountMinor,
                  ),
                const Divider(),
                _MoneyRow(
                  label: 'Total',
                  valueMinor: order.totalMinor,
                  bold: true,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          PharmaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SectionHeader(title: 'Delivery'),
                const SizedBox(height: 8),
                _DetailRow(
                  label: 'Type',
                  value: fulfillmentLabel(order.fulfillment),
                ),
                if (order.fulfillment == FulfillmentType.delivery)
                  _DetailRow(
                    label: 'Rider',
                    value: rider == null
                        ? 'No rider assigned yet'
                        : '${rider.name} • ${rider.phone}',
                  ),
                if (rider?.vehicle != null)
                  _DetailRow(label: 'Vehicle', value: rider!.vehicle!),
                if (order.orderNotes != null &&
                    order.orderNotes!.isNotEmpty)
                  _DetailRow(label: 'Notes', value: order.orderNotes!),
              ],
            ),
          ),
          const SizedBox(height: 16),
          PharmaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SectionHeader(
                  title: 'Prescription',
                  subtitle: 'Attached by staff when the order was taken',
                ),
                const SizedBox(height: 8),
                if (prescription == null)
                  const Text(
                    'No prescription attached to this order.',
                  )
                else
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              prescription.id,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(fontWeight: FontWeight.w600),
                            ),
                          ),
                          StatusBadge(
                            label: _prescriptionLabel(prescription.status),
                            kind: _prescriptionKind(prescription.status),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Photo on file: bundled SAMPLE image (demo asset) — '
                        'never a real patient photo or a network URL.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      if (prescription.reviewNotes != null)
                        Text(
                          'Review note: ${prescription.reviewNotes}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      const SizedBox(height: 8),
                      TextButton.icon(
                        onPressed: () => context.go(
                          '/prescriptions/${prescription.id}',
                        ),
                        icon: const Icon(Icons.description_outlined, size: 18),
                        label: const Text('Open prescription review'),
                      ),
                    ],
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          PharmaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SectionHeader(
                  title: 'Status timeline',
                  subtitle: 'Timestamps shown only where the data has them',
                ),
                const SizedBox(height: 12),
                for (var i = 0; i < timeline.length; i++)
                  _TimelineRow(
                    step: timeline[i],
                    isLast: i == timeline.length - 1,
                  ),
                if (isCancelled)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'Cancelled ${_formatDateTime(order.updatedAt)}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: StatusKind.danger.color,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (next != null)
                PharmaButton(
                  label: advanceLabel(order.status),
                  icon: Icons.arrow_forward,
                  onPressed: blockedReason != null
                      ? () => _showBlocked(context, blockedReason)
                      : () => _advance(context, ref, order, prescription),
                ),
              if (canCancel(order.status))
                PharmaButton(
                  label: 'Cancel Order',
                  icon: Icons.cancel_outlined,
                  variant: PharmaButtonVariant.danger,
                  onPressed: () => _cancel(context, ref, order),
                ),
              if (canEdit(order.status))
                PharmaButton(
                  label: 'Edit Order',
                  icon: Icons.edit_outlined,
                  variant: PharmaButtonVariant.secondary,
                  onPressed: () => context.go('/orders/${order.id}/edit'),
                ),
            ],
          ),
          if (!canEdit(order.status)) ...[
            const SizedBox(height: 12),
            Text(
              isDelivered
                  ? 'Delivered orders cannot be edited.'
                  : 'Cancelled orders cannot be edited.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _advance(
    BuildContext context,
    WidgetRef ref,
    Order order,
    Prescription? prescription,
  ) async {
    final ok = await ref
        .read(orderQueueProvider.notifier)
        .advanceOrder(order, linkedPrescriptionStatus: prescription?.status);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'Order ${order.id} marked ${orderStatusLabel(nextOrderStatus(order.status)!)}.'
              : 'Order could not be advanced.',
        ),
      ),
    );
  }

  Future<void> _cancel(
    BuildContext context,
    WidgetRef ref,
    Order order,
  ) async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Cancel order ${order.id}?',
      message:
          'The order will be marked Cancelled and excluded from sales. This cannot be undone.',
      confirmLabel: 'Cancel Order',
      danger: true,
    );
    if (confirmed != true || !context.mounted) return;
    final ok = await ref
        .read(orderQueueProvider.notifier)
        .cancelOrder(order);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'Order ${order.id} cancelled.'
              : 'Order could not be cancelled.',
        ),
      ),
    );
  }

  void _showBlocked(BuildContext context, String reason) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(reason)));
  }
}

String _formatDateTime(DateTime? value) {
  if (value == null) return '—';
  return '${value.day}/${value.month}/${value.year} '
      '${value.hour.toString().padLeft(2, '0')}:'
      '${value.minute.toString().padLeft(2, '0')}';
}

String _prescriptionLabel(PrescriptionStatus status) => switch (status) {
  PrescriptionStatus.pending => 'Pending review',
  PrescriptionStatus.approved => 'Approved',
  PrescriptionStatus.rejected => 'Rejected',
  PrescriptionStatus.needsClearerPhoto => 'Needs clearer photo',
};

StatusKind _prescriptionKind(PrescriptionStatus status) => switch (status) {
  PrescriptionStatus.approved => StatusKind.success,
  PrescriptionStatus.rejected => StatusKind.danger,
  PrescriptionStatus.pending => StatusKind.warning,
  PrescriptionStatus.needsClearerPhoto => StatusKind.warning,
};

class _NoticeBanner extends StatelessWidget {
  const _NoticeBanner({
    required this.icon,
    required this.title,
    required this.message,
    required this.kind,
  });

  final IconData icon;
  final String title;
  final String message;
  final StatusKind kind;

  @override
  Widget build(BuildContext context) {
    final color = kind.color;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: color,
                  ),
                ),
                Text(message, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({required this.item});

  final OrderItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.medicineName,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  '${item.quantity} × ${formatPkr(rupeesToMinorUnits(item.unitPrice))}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          Text(
            formatPkr(item.lineTotalMinor),
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _MoneyRow extends StatelessWidget {
  const _MoneyRow({
    required this.label,
    required this.valueMinor,
    this.bold = false,
  });

  final String label;
  final int valueMinor;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyMedium?.copyWith(
      fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text(label, style: style)),
          Text(formatPkr(valueMinor), style: style),
        ],
      ),
    );
  }
}

class _TimelineRow extends StatelessWidget {
  const _TimelineRow({required this.step, required this.isLast});

  final OrderTimelineStep step;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = switch (step.state) {
      OrderTimelineState.done => StatusKind.success.color,
      OrderTimelineState.current => theme.colorScheme.primary,
      OrderTimelineState.upcoming => theme.disabledColor,
    };
    final icon = switch (step.state) {
      OrderTimelineState.done => Icons.check_circle,
      OrderTimelineState.current => Icons.radio_button_checked,
      OrderTimelineState.upcoming => Icons.radio_button_unchecked,
    };
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            children: [
              Icon(icon, color: color, size: 22),
              if (!isLast)
                Expanded(
                  child: Container(width: 2, color: color.withValues(alpha: 0.3)),
                ),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    orderStatusLabel(step.status),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: step.state == OrderTimelineState.upcoming
                          ? FontWeight.w400
                          : FontWeight.w700,
                      color: step.state == OrderTimelineState.upcoming
                          ? theme.textTheme.bodySmall?.color
                          : null,
                    ),
                  ),
                  Text(
                    step.timestamp == null
                        ? step.state == OrderTimelineState.upcoming
                              ? 'Not reached yet'
                              : 'Reached'
                        : _formatDateTime(step.timestamp),
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
