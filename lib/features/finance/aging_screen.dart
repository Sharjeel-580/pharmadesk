import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/utils/money.dart';
import '../../core/widgets/design_system.dart';
import '../../core/widgets/pagination_controls.dart';
import '../../models/purchase_order.dart';
import '../customers/customers_provider.dart';
import '../purchases/purchases_provider.dart';
import '../suppliers/suppliers_provider.dart';
import 'finance_logic.dart';
import 'finance_provider.dart';

/// Payables / receivables aging (Week 4 Day 3, D127 — SRS D-25 /
/// FR-FIN-03).
///
/// Supplier payables and customer receivables aged with the ONE D92
/// aging computation ([computeAging] — FIFO, payments applied
/// oldest-first): Current (0–30 days) / 31–60 / 61–90 / 90+ days.
/// Per-party rows navigate to the supplier / customer detail, where
/// the statements already live. This screen adds no second aging
/// math and no second outstanding figure — the totals here are the
/// same ledger sums the detail screens show.
///
/// Unpaid purchase orders are shown separately as committed spend:
/// an approved / partially-received PO is NOT a payable until its
/// goods are received (the received value is what the ledger is
/// charged), so open POs never enter the buckets or the totals.
class AgingScreen extends ConsumerWidget {
  const AgingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final payables = ref.watch(allPayablesAgingProvider);
    final receivables = ref.watch(allReceivablesAgingProvider);
    final suppliers = ref.watch(suppliersProvider).asData?.value ?? const [];
    final customers = ref.watch(customersProvider).asData?.value ?? const [];
    final orders = ref.watch(purchaseOrdersProvider).asData?.value ?? const [];

    final payableRows = [
      for (final supplier in suppliers)
        (
          id: supplier.id,
          name: supplier.name,
          aging: payables[supplier.id] ??
              AgingSummary(
                buckets: {
                  for (final bucket in AgingBucket.values) bucket: 0,
                },
                totalMinor: 0,
              ),
        ),
    ]..sort((a, b) => b.aging.totalMinor.compareTo(a.aging.totalMinor));
    final receivableRows = [
      for (final customer in customers)
        (
          id: customer.id,
          name: customer.name,
          aging: receivables[customer.id] ??
              AgingSummary(
                buckets: {
                  for (final bucket in AgingBucket.values) bucket: 0,
                },
                totalMinor: 0,
              ),
        ),
    ]..sort((a, b) => b.aging.totalMinor.compareTo(a.aging.totalMinor));

    final openPayables = payableRows
        .where((row) => row.aging.totalMinor > 0)
        .toList();
    final settledSuppliers = payableRows.length - openPayables.length;
    final openReceivables = receivableRows
        .where((row) => row.aging.totalMinor > 0)
        .toList();
    final settledCustomers = receivableRows.length - openReceivables.length;

    // Open POs: approved or partially received, with value still to
    // receive. Drafts are not commitments; received / cancelled POs
    // have nothing outstanding.
    final openOrders = orders
        .where(
          (order) =>
              (order.status == PurchaseOrderStatus.approved ||
                  order.status == PurchaseOrderStatus.partiallyReceived) &&
              order.totalMinor - order.receivedTotalMinor > 0,
        )
        .toList();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionHeader(
            title: 'Payables & Receivables',
            subtitle:
                'Aged from the supplier and khata ledgers — oldest charge first. Tap a party to open its detail and statement.',
          ),
          const SizedBox(height: 16),
          _AgingSection(
            title: 'Supplier payables',
            emptyMessage: 'No supplier owes a balance.',
            settledCaption: settledSuppliers > 0
                ? '$settledSuppliers supplier(s) settled — zero outstanding.'
                : null,
            rows: openPayables,
            onTap: (id) => context.go('/suppliers/$id'),
          ),
          const SizedBox(height: 24),
          _AgingSection(
            title: 'Customer receivables',
            emptyMessage: 'No customer owes a balance.',
            settledCaption: settledCustomers > 0
                ? '$settledCustomers customer(s) settled — zero outstanding.'
                : null,
            rows: openReceivables,
            onTap: (id) => context.go('/customers/$id'),
          ),
          const SizedBox(height: 24),
          const SectionHeader(
            title: 'Unpaid purchase orders',
            subtitle:
                'Committed spend, not yet payable — goods not received are not owed. The received value is what the ledger charges.',
          ),
          const SizedBox(height: 12),
          if (openOrders.isEmpty)
            const Text('No open purchase orders.')
          else
            PagedList<PurchaseOrder>(
              items: openOrders,
              pageSize: 10,
              itemBuilder: (context, order) => _OpenOrderRow(order: order),
            ),
        ],
      ),
    );
  }
}

typedef _AgingRow =
    ({String id, String name, AgingSummary aging});

class _AgingSection extends StatelessWidget {
  const _AgingSection({
    required this.title,
    required this.emptyMessage,
    required this.settledCaption,
    required this.rows,
    required this.onTap,
  });

  final String title;
  final String emptyMessage;
  final String? settledCaption;
  final List<_AgingRow> rows;
  final void Function(String id) onTap;

  @override
  Widget build(BuildContext context) {
    final total = rows.fold(0, (sum, row) => sum + row.aging.totalMinor);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(title: title),
        const SizedBox(height: 12),
        PharmaCard(
          child: Column(
            children: [
              for (final bucket in AgingBucket.values)
                _BucketRow(
                  label: agingBucketLabel(bucket),
                  amountMinor: rows.fold(
                    0,
                    (sum, row) => sum + row.aging.bucket(bucket),
                  ),
                ),
              const Divider(height: 16),
              _BucketRow(
                label: 'Total outstanding',
                amountMinor: total,
                bold: true,
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (settledCaption != null) ...[
          Text(settledCaption!, style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 8),
        ],
        if (rows.isEmpty)
          Text(emptyMessage)
        else
          PagedList<_AgingRow>(
            items: rows,
            pageSize: 10,
            itemBuilder: (context, row) => PharmaCard(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                title: Text(
                  row.name,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Text(
                  AgingBucket.values
                      .map(
                        (bucket) =>
                            '${_shortBucketLabel(bucket)} ${formatPkr(row.aging.bucket(bucket))}',
                      )
                      .join(' • '),
                ),
                trailing: Text(
                  formatPkr(row.aging.totalMinor),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                onTap: () => onTap(row.id),
              ),
            ),
          ),
      ],
    );
  }
}

String _shortBucketLabel(AgingBucket bucket) => switch (bucket) {
  AgingBucket.current => 'Current',
  AgingBucket.days30 => '31–60',
  AgingBucket.days60 => '61–90',
  AgingBucket.days90plus => '90+',
};

class _BucketRow extends StatelessWidget {
  const _BucketRow({
    required this.label,
    required this.amountMinor,
    this.bold = false,
  });

  final String label;
  final int amountMinor;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text(label, style: style)),
          Text(formatPkr(amountMinor), style: style),
        ],
      ),
    );
  }
}

class _OpenOrderRow extends ConsumerWidget {
  const _OpenOrderRow({required this.order});

  final PurchaseOrder order;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final supplier = ref.watch(supplierByIdProvider(order.supplierId));
    final remaining = order.totalMinor - order.receivedTotalMinor;
    return PharmaCard(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: const Icon(Icons.shopping_cart_outlined),
        title: Text(
          '${order.poNumber} — ${supplier?.name ?? order.supplierId}',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Text(
          '${purchaseOrderStatusLabel(order.status)} • '
          'Ordered ${formatPkr(order.totalMinor)} • '
          'Received ${formatPkr(order.receivedTotalMinor)}',
        ),
        trailing: Text(
          formatPkr(remaining),
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        onTap: () => context.go('/purchases/${order.id}'),
      ),
    );
  }
}
