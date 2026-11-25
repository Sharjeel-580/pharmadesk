import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/services/branch_context.dart';
import '../../core/utils/money.dart';
import '../../core/widgets/design_system.dart';
import '../../models/sale.dart';
import '../../models/sale_return.dart';
import 'billing_provider.dart';
import 'returns_provider.dart';

/// Returns & refunds list (Week 2 Day 4, FR-POS-08).
///
/// Route `/billing/returns`.
///
/// Every return recorded at the active branch, newest first: the
/// invoice it reverses, the reason, the refund, and whether the sale
/// ended fully or partially returned (from the sale's status). Tapping
/// "New return" opens the return form; each row also shows the
/// approver, so the approval trail is visible without opening
/// anything.
class ReturnsListScreen extends ConsumerWidget {
  const ReturnsListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final branch = ref.watch(activeBranchProvider);
    final returnsAsync = ref.watch(saleReturnsProvider);
    final returns = ref.watch(branchSaleReturnsProvider(branch.id));
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            title: 'Returns & refunds',
            subtitle: '${branch.name} • ${returns.length} return(s)',
            actionLabel: 'New return',
            actionIcon: Icons.keyboard_return_outlined,
            onAction: () => context.go('/billing/returns/new'),
          ),
          const SizedBox(height: 16),
          returnsAsync.when(
            loading: () => const Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SkeletonCard(),
                SizedBox(height: 12),
                SkeletonList(count: 3),
              ],
            ),
            error: (error, _) => PharmaEmptyState(
              icon: Icons.error_outline,
              title: 'Returns could not load',
              message: 'The return records failed to load. Try again.',
              actionLabel: 'Retry',
              onAction: () =>
                  ref.read(saleReturnsProvider.notifier).refresh(),
            ),
            data: (_) {
              if (returns.isEmpty) {
                return PharmaEmptyState(
                  icon: Icons.keyboard_return_outlined,
                  title: 'No returns yet',
                  message:
                      'No items have been returned at this branch. Record a return from a completed sale — the stock goes back to its batch and a credit sale comes off the customer khata.',
                  actionLabel: 'New return',
                  onAction: () => context.go('/billing/returns/new'),
                );
              }
              return Column(
                children: [
                  for (final saleReturn in returns)
                    _ReturnRow(saleReturn: saleReturn),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _ReturnRow extends ConsumerWidget {
  const _ReturnRow({required this.saleReturn});

  final SaleReturn saleReturn;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final sale = ref.watch(saleByIdProvider(saleReturn.saleId));
    final extent = sale == null
        ? saleReturnStatusLabel(saleReturn.status)
        : sale.status == SaleStatus.returned
        ? 'Full return'
        : 'Partial return';
    final created = saleReturn.createdAt;
    final dateLabel = created == null
        ? ''
        : '${created.day}/${created.month}/${created.year} '
              '${created.hour.toString().padLeft(2, '0')}:${created.minute.toString().padLeft(2, '0')}';
    return PharmaCard(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Icon(
              Icons.keyboard_return_outlined,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${saleReturn.invoiceNumber} • $extent',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    saleReturn.reason,
                    style: theme.textTheme.bodyMedium,
                  ),
                  Text(
                    '${saleReturn.items.length} item(s) • Approved by ${saleReturn.approvedByName} • $dateLabel',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '-${formatPkr(saleReturn.refundedAmountMinor)}',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                StatusBadge(
                  label: extent,
                  kind: sale?.status == SaleStatus.returned
                      ? StatusKind.success
                      : StatusKind.warning,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
