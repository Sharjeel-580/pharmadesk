import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/utils/money.dart';
import '../../core/widgets/design_system.dart';
import '../../models/customer_ledger.dart';
import '../../models/order.dart';
import '../../models/sale.dart';
import '../billing/billing_provider.dart';
import '../dashboard/dashboard_data.dart';
import '../finance/finance_logic.dart';
import '../finance/finance_provider.dart';
import '../orders/orders_provider.dart';
import 'customers_provider.dart';

/// Customer detail (Day 6, SRS §8 + FR-POS-09).
///
/// Route `/customers/:id`.
///
/// - Contact info + credit limit + outstanding khata balance.
/// - Purchase history: the customer's orders (from the order queue)
///   and POS sales, newest first.
/// - Credit ledger (khata): every entry with its balance after, and
///   actions to record a payment, add credit (udhaar) or post an
///   adjustment — all validated, all in int paisa. The outstanding is
///   computed from the entries, never stored.
class CustomerDetailScreen extends ConsumerWidget {
  const CustomerDetailScreen({super.key, required this.customerId});

  final String customerId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final customer = ref.watch(customerByIdProvider(customerId));
    if (customer == null) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: PharmaEmptyState(
          icon: Icons.people_outline,
          title: 'Customer not found',
          message: 'There is no customer with id "$customerId" in this demo.',
          actionLabel: 'Back to Customers',
          onAction: () => context.go('/customers'),
        ),
      );
    }
    final outstanding = ref.watch(outstandingProvider(customerId));
    final aging = ref.watch(customerAgingProvider(customerId));
    final ledgerAsync = ref.watch(ledgerProvider(customerId));
    final orders = ref
        .watch(orderQueueProvider)
        .asData
        ?.value
        .where((order) => order.customerId == customerId)
        .toList();
    final sales = ref
        .watch(salesProvider)
        .asData
        ?.value
        .where((sale) => sale.customerId == customerId)
        .toList();
    final purchases = <_PurchaseRow>[];
    for (final order in orders ?? const <Order>[]) {
      purchases.add(
        _PurchaseRow(
          date: order.createdAt,
          label: 'Order ${order.id}',
          detail:
              '${order.items.fold(0, (sum, item) => sum + item.quantity)} item(s) • ${orderStatusLabel(order.status)}',
          amountMinor: order.totalMinor,
          isOrder: true,
          route: '/orders/${order.id}',
        ),
      );
    }
    for (final sale in sales ?? const <Sale>[]) {
      purchases.add(
        _PurchaseRow(
          date: sale.createdAt,
          label: 'POS sale ${sale.invoiceNumber}',
          detail:
              '${sale.items.fold(0, (sum, item) => sum + item.quantity)} item(s) • ${salePaymentMethodLabel(sale.paymentMethod)}',
          amountMinor: sale.totalMinor,
          isOrder: false,
          route: '/billing/receipt/${sale.id}',
        ),
      );
    }
    purchases.sort(
      (a, b) => (b.date ?? DateTime(0)).compareTo(a.date ?? DateTime(0)),
    );
    final address = customer.addresses.firstOrNull;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            title: customer.name,
            subtitle: '${customer.phone} • Customer since '
                '${customer.createdAt == null ? 'demo data' : '${customer.createdAt!.day}/${customer.createdAt!.month}/${customer.createdAt!.year}'}',
            actionLabel: 'All Customers',
            actionIcon: Icons.people_outline,
            onAction: () => context.go('/customers'),
          ),
          const SizedBox(height: 16),
          PharmaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SectionHeader(
                  title: 'Contact & credit',
                  subtitle: 'Khata balance is computed from the ledger',
                ),
                const SizedBox(height: 8),
                _InfoRow(label: 'Phone', value: customer.phone),
                if (address != null)
                  _InfoRow(
                    label: 'Address',
                    value: '${address.address}, ${address.city}',
                  ),
                _InfoRow(
                  label: 'Credit limit',
                  value: customer.creditLimitMinor == 0
                      ? 'No limit set'
                      : formatPkr(customer.creditLimitMinor),
                ),
                _InfoRow(
                  label: 'Outstanding (khata)',
                  value: formatPkr(outstanding),
                  bold: true,
                  danger: outstanding > 0,
                ),
                if (outstanding > 0) ...[
                  const SizedBox(height: 12),
                  Text(
                    'Khata aging',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final bucket in AgingBucket.values)
                        StatusBadge(
                          label:
                              '${agingBucketLabel(bucket)}: ${formatPkr(aging.bucket(bucket))}',
                          kind:
                              bucket == AgingBucket.days90plus &&
                                  aging.bucket(bucket) > 0
                              ? StatusKind.danger
                              : bucket == AgingBucket.current
                                  ? StatusKind.success
                                  : StatusKind.warning,
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Payments settle the oldest credit first, so each '
                    'bucket shows what is still owed from credit of '
                    'that age.',
                    style: TextStyle(fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
          PharmaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SectionHeader(
                  title: 'Purchase history',
                  subtitle: 'Orders and POS sales, newest first',
                ),
                const SizedBox(height: 8),
                if (purchases.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('No purchases yet for this customer.'),
                  )
                else
                  for (final purchase in purchases)
                    _PurchaseRowWidget(purchase: purchase),
              ],
            ),
          ),
          const SizedBox(height: 16),
          PharmaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SectionHeader(
                  title: 'Khata — credit ledger',
                  subtitle: outstanding > 0
                      ? 'Outstanding ${formatPkr(outstanding)}'
                      : 'Settled — nothing outstanding',
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    PharmaButton(
                      label: 'Record payment',
                      icon: Icons.payments_outlined,
                      size: PharmaButtonSize.small,
                      onPressed: outstanding <= 0
                          ? null
                          : () => _showLedgerDialog(
                              context,
                              ref,
                              customerId,
                              LedgerEntryKind.payment,
                            ),
                    ),
                    PharmaButton(
                      label: 'Add credit (udhaar)',
                      icon: Icons.book_outlined,
                      variant: PharmaButtonVariant.secondary,
                      size: PharmaButtonSize.small,
                      onPressed: () => _showLedgerDialog(
                        context,
                        ref,
                        customerId,
                        LedgerEntryKind.credit,
                      ),
                    ),
                    PharmaButton(
                      label: 'Adjustment',
                      icon: Icons.tune_outlined,
                      variant: PharmaButtonVariant.secondary,
                      size: PharmaButtonSize.small,
                      onPressed: () => _showLedgerDialog(
                        context,
                        ref,
                        customerId,
                        LedgerEntryKind.adjustment,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                ledgerAsync.when(
                  loading: () => const SkeletonList(count: 3),
                  error: (error, _) => const Text(
                    'The ledger could not load.',
                  ),
                  data: (entries) {
                    if (entries.isEmpty) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: Text(
                          'No khata entries yet — credit sales and manual entries will appear here.',
                        ),
                      );
                    }
                    final sorted = entries.toList()
                      ..sort(
                        (a, b) => (b.createdAt ?? DateTime(0)).compareTo(
                          a.createdAt ?? DateTime(0),
                        ),
                      );
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var i = 0; i < sorted.length; i++) ...[
                          _LedgerRow(entry: sorted[i]),
                          if (i < sorted.length - 1)
                            Divider(
                              height: 1,
                              color: Theme.of(
                                context,
                              ).dividerColor.withValues(alpha: 0.4),
                            ),
                        ],
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showLedgerDialog(
    BuildContext context,
    WidgetRef ref,
    String customerId,
    LedgerEntryKind kind,
  ) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) =>
          _LedgerEntryDialog(customerId: customerId, kind: kind),
    );
    if (saved == true && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            kind == LedgerEntryKind.payment
                ? 'Payment recorded against the khata.'
                : kind == LedgerEntryKind.credit
                ? 'Credit added to the khata.'
                : 'Adjustment recorded.',
          ),
        ),
      );
    }
  }
}

class _PurchaseRow {
  const _PurchaseRow({
    required this.date,
    required this.label,
    required this.detail,
    required this.amountMinor,
    required this.isOrder,
    required this.route,
  });

  final DateTime? date;
  final String label;
  final String detail;
  final int amountMinor;
  final bool isOrder;
  final String route;
}

class _PurchaseRowWidget extends StatelessWidget {
  const _PurchaseRowWidget({required this.purchase});

  final _PurchaseRow purchase;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final date = purchase.date;
    final dateLabel = date == null
        ? ''
        : '${date.day}/${date.month}/${date.year} • ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    return InkWell(
      onTap: () => context.go(purchase.route),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Icon(
              purchase.isOrder
                  ? Icons.receipt_long_outlined
                  : Icons.point_of_sale_outlined,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    purchase.label,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    '${purchase.detail} • $dateLabel',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            Text(
              formatPkr(purchase.amountMinor),
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LedgerRow extends StatelessWidget {
  const _LedgerRow({required this.entry});

  final LedgerEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final date = entry.createdAt;
    final dateLabel = date == null
        ? ''
        : '${date.day}/${date.month}/${date.year}';
    final isOwingMore = entry.amountMinor > 0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  ledgerEntryKindLabel(entry.kind),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  '${entry.reason} • $dateLabel',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${isOwingMore ? '+' : ''}${formatPkr(entry.amountMinor)}',
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: isOwingMore
                      ? StatusKind.danger.color
                      : StatusKind.success.color,
                ),
              ),
              Text(
                'Balance ${formatPkr(entry.balanceAfterMinor)}',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.label,
    required this.value,
    this.bold = false,
    this.danger = false,
  });

  final String label;
  final String value;
  final bool bold;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyMedium?.copyWith(
      fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
      color: danger ? StatusKind.danger.color : null,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text(label, style: style)),
          Text(value, style: style),
        ],
      ),
    );
  }
}

/// Dialog for one khata entry: payment, credit (udhaar) or adjustment.
/// Amount is typed in whole rupees and converted to int paisa at the
/// boundary; adjustments also pick increase/decrease. Validation
/// errors show inside the dialog.
class _LedgerEntryDialog extends ConsumerStatefulWidget {
  const _LedgerEntryDialog({required this.customerId, required this.kind});

  final String customerId;
  final LedgerEntryKind kind;

  @override
  ConsumerState<_LedgerEntryDialog> createState() =>
      _LedgerEntryDialogState();
}

class _LedgerEntryDialogState extends ConsumerState<_LedgerEntryDialog> {
  final _amountController = TextEditingController();
  final _reasonController = TextEditingController();
  bool _isIncrease = true;
  List<String> _errors = [];
  bool _saving = false;

  @override
  void dispose() {
    _amountController.dispose();
    _reasonController.dispose();
    super.dispose();
  }

  String get _title => switch (widget.kind) {
    LedgerEntryKind.payment => 'Record payment',
    LedgerEntryKind.credit => 'Add credit (udhaar)',
    LedgerEntryKind.adjustment => 'Khata adjustment',
    LedgerEntryKind.creditSale => 'Credit sale',
  };

  Future<void> _save() async {
    final amountText = _amountController.text.trim();
    final amountRupees = int.tryParse(amountText);
    if (amountRupees == null) {
      setState(
        () => _errors = ['Amount must be a whole number of rupees.'],
      );
      return;
    }
    setState(() {
      _errors = [];
      _saving = true;
    });
    final result = await ref
        .read(ledgerProvider(widget.customerId).notifier)
        .recordEntry(
          kind: widget.kind,
          amountMinor: amountRupees * 100,
          reason: _reasonController.text,
          isIncrease: _isIncrease,
        );
    if (!mounted) return;
    if (result.entry == null) {
      setState(() {
        _errors = [result.error ?? 'Could not record this entry.'];
        _saving = false;
      });
      return;
    }
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final outstanding = ref.watch(outstandingProvider(widget.customerId));
    return AlertDialog(
      title: Text(_title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_errors.isNotEmpty) ...[
              PharmaErrorBox(errors: _errors),
              const SizedBox(height: 12),
            ],
            Text(
              'Outstanding: ${formatPkr(outstanding)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            PharmaTextField(
              controller: _amountController,
              label: 'Amount (Rs)',
              hintText: 'Whole rupees',
              keyboardType: TextInputType.number,
              autofocus: true,
            ),
            if (widget.kind == LedgerEntryKind.adjustment) ...[
              const SizedBox(height: 12),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(
                    value: true,
                    label: Text('Increase owed'),
                    icon: Icon(Icons.add_outlined),
                  ),
                  ButtonSegment(
                    value: false,
                    label: Text('Decrease owed'),
                    icon: Icon(Icons.remove_outlined),
                  ),
                ],
                selected: {_isIncrease},
                onSelectionChanged: (selection) =>
                    setState(() => _isIncrease = selection.first),
              ),
            ],
            const SizedBox(height: 12),
            PharmaTextField(
              controller: _reasonController,
              label: widget.kind == LedgerEntryKind.payment
                  ? 'Note (optional)'
                  : 'Reason',
              hintText: widget.kind == LedgerEntryKind.payment
                  ? 'e.g. Cash received'
                  : 'e.g. Medicines taken on credit',
              maxLines: 2,
            ),
          ],
        ),
      ),
      actions: [
        PharmaButton(
          label: 'Cancel',
          variant: PharmaButtonVariant.text,
          size: PharmaButtonSize.small,
          onPressed: () => Navigator.of(context).pop(false),
        ),
        PharmaButton(
          label: 'Save',
          size: PharmaButtonSize.small,
          loading: _saving,
          onPressed: _saving ? null : _save,
        ),
      ],
    );
  }
}
