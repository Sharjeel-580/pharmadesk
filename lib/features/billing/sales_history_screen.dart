import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/services/branch_context.dart';
import '../../core/utils/money.dart';
import '../../core/widgets/design_system.dart';
import '../../models/sale.dart';
import '../customers/customers_provider.dart';
import 'billing_provider.dart';

/// Sales history (Day 6): every completed POS sale for the active
/// branch, newest first. Route `/billing/history`. Tapping a sale
/// opens its receipt.
class SalesHistoryScreen extends ConsumerWidget {
  const SalesHistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final branch = ref.watch(activeBranchProvider);
    final sales = ref.watch(branchSalesProvider(branch.id));
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            title: 'Sales history',
            subtitle:
                '${branch.name} • ${sales.length} sale(s) in this session',
            actionLabel: 'New Sale',
            actionIcon: Icons.point_of_sale_outlined,
            onAction: () => context.go('/billing'),
          ),
          const SizedBox(height: 16),
          if (sales.isEmpty)
            const PharmaEmptyState(
              icon: Icons.receipt_long_outlined,
              title: 'No sales yet',
              message:
                  'Complete a sale at the POS and it will appear here with its receipt.',
            )
          else
            PharmaCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < sales.length; i++) ...[
                    _SaleRow(sale: sales[i]),
                    if (i < sales.length - 1)
                      Divider(
                        height: 1,
                        color: Theme.of(
                          context,
                        ).dividerColor.withValues(alpha: 0.4),
                      ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _SaleRow extends ConsumerWidget {
  const _SaleRow({required this.sale});

  final Sale sale;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final customer = sale.customerId == null
        ? null
        : ref.watch(customerByIdProvider(sale.customerId!));
    final created = sale.createdAt;
    final timeLabel = created == null
        ? ''
        : '${created.hour.toString().padLeft(2, '0')}:${created.minute.toString().padLeft(2, '0')} • ${created.day}/${created.month}';
    final itemCount = sale.items.fold(0, (sum, item) => sum + item.quantity);
    return InkWell(
      onTap: () => context.go('/billing/receipt/${sale.id}'),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    sale.invoiceNumber,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    '${customer?.name ?? 'Walk-in'} • $itemCount item(s) • $timeLabel',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            Text(
              formatPkr(sale.totalMinor),
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 12),
            StatusBadge(
              label: salePaymentMethodLabel(sale.paymentMethod),
              kind: sale.isCredit
                  ? StatusKind.warning
                  : StatusKind.success,
            ),
          ],
        ),
      ),
    );
  }
}
