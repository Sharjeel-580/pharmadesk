import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/services/branch_context.dart';
import '../../core/utils/money.dart';
import '../../core/widgets/design_system.dart';
import '../../models/purchase_order.dart';
import '../suppliers/suppliers_provider.dart';
import 'purchases_logic.dart';
import 'purchases_provider.dart';

/// Purchase order list (Day 7, SRS FR-PUR-01).
///
/// Route `/purchases`.
///
/// Branch-scoped list with status filter chips + search (PO number /
/// supplier name), tap a row for the detail (approve / receive /
/// cancel), New purchase order opens the create form.
class PurchaseListScreen extends ConsumerStatefulWidget {
  const PurchaseListScreen({super.key});

  @override
  ConsumerState<PurchaseListScreen> createState() =>
      _PurchaseListScreenState();
}

class _PurchaseListScreenState extends ConsumerState<PurchaseListScreen> {
  String _query = '';
  PurchaseOrderStatus? _statusFilter;

  @override
  Widget build(BuildContext context) {
    final ordersAsync = ref.watch(purchaseOrdersProvider);
    final suppliers = ref.watch(suppliersProvider).asData?.value ?? const [];
    final supplierNames = {
      for (final s in suppliers) s.id: s.name,
    };
    // Active branch scoping lives in the list builder (same pattern
    // as the Day 4 order queue): the notifier holds all branches.
    final branchId = ref.watch(activeBranchProvider).id;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            title: 'Purchases',
            subtitle: 'Purchase orders, goods receiving, supplier payments',
            actionLabel: 'New purchase order',
            actionIcon: Icons.add_outlined,
            onAction: () => context.go('/purchases/new'),
          ),
          const SizedBox(height: 16),
          PharmaSearchField(
            hintText: 'Search by PO number or supplier…',
            onChanged: (value) => setState(() => _query = value),
          ),
          const SizedBox(height: 12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _FilterChip(
                  label: 'All',
                  selected: _statusFilter == null,
                  onSelected: () =>
                      setState(() => _statusFilter = null),
                ),
                for (final status in PurchaseOrderStatus.values)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: _FilterChip(
                      label: purchaseOrderStatusLabel(status),
                      selected: _statusFilter == status,
                      onSelected: () =>
                          setState(() => _statusFilter = status),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              PharmaButton(
                key: const ValueKey('open-auto-purchase-list'),
                label: 'Auto Purchase List',
                variant: PharmaButtonVariant.secondary,
                size: PharmaButtonSize.small,
                icon: Icons.auto_awesome_outlined,
                onPressed: () => context.go('/purchases/auto'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          ordersAsync.when(
            loading: () => const SkeletonList(count: 4),
            error: (error, _) => PharmaEmptyState(
              icon: Icons.error_outline,
              title: 'Purchase orders could not load',
              message: 'The demo data failed to load. Try again.',
              actionLabel: 'Retry',
              onAction: () => ref.invalidate(purchaseOrdersProvider),
            ),
            data: (orders) {
              final matching = filterPurchaseOrders(
                orders: orders,
                branchId: branchId,
                statusFilter: _statusFilter,
                query: _query,
                supplierNamesById: supplierNames,
              );
              if (matching.isEmpty) {
                return PharmaEmptyState(
                  icon: Icons.shopping_cart_outlined,
                  title: _query.isEmpty && _statusFilter == null
                      ? 'No purchase orders yet'
                      : 'No purchase orders match',
                  message: _query.isEmpty && _statusFilter == null
                      ? 'Create your first purchase order to restock.'
                      : 'Try a different search or filter.',
                  actionLabel: 'New purchase order',
                  onAction: () => context.go('/purchases/new'),
                );
              }
              return PharmaCard(
                child: Column(
                  children: [
                    for (var i = 0; i < matching.length; i++) ...[
                      if (i > 0) const Divider(height: 1),
                      _PurchaseOrderRow(
                        order: matching[i],
                        supplierName:
                            supplierNames[matching[i].supplierId] ??
                            matching[i].supplierId,
                      ),
                    ],
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onSelected(),
    );
  }
}

class _PurchaseOrderRow extends StatelessWidget {
  const _PurchaseOrderRow({required this.order, required this.supplierName});

  final PurchaseOrder order;
  final String supplierName;

  @override
  Widget build(BuildContext context) {
    final kind = switch (order.status) {
      PurchaseOrderStatus.draft => StatusKind.neutral,
      PurchaseOrderStatus.approved => StatusKind.info,
      PurchaseOrderStatus.partiallyReceived => StatusKind.warning,
      PurchaseOrderStatus.received => StatusKind.success,
      PurchaseOrderStatus.cancelled => StatusKind.danger,
    };
    return ListTile(
      leading: const Icon(Icons.shopping_cart_outlined),
      title: Text(order.poNumber),
      subtitle: Text(
        '$supplierName • ${order.items.length} item(s) • '
        '${order.items.fold(0, (sum, item) => sum + item.quantityReceived)}'
        '/${order.items.fold(0, (sum, item) => sum + item.quantityOrdered)} received',
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            formatPkr(order.totalMinor),
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 2),
          StatusBadge(
            label: purchaseOrderStatusLabel(order.status),
            kind: kind,
          ),
        ],
      ),
      onTap: () => context.go('/purchases/${order.id}'),
    );
  }
}
