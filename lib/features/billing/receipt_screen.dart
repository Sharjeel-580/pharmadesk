import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/services/branch_context.dart';
import '../../core/theme/white_label.dart';
import '../../core/utils/money.dart';
import '../../core/widgets/design_system.dart';
import '../../models/sale.dart';
import '../customers/customers_provider.dart';
import 'billing_logic.dart';
import 'billing_provider.dart';
import 'receipt_print.dart';

/// Receipt preview screen (Day 6, SRS §8 + FR-POS-07).
///
/// Route `/billing/receipt/:id`.
///
/// Shows the saved sale: branch, invoice number, items with the batch
/// + expiry they were picked from, discounts, tax, totals, payment
/// method, cashier, date/time — plus the DEMO watermark. Actions:
///
/// - Share: copies the plain-text receipt to the clipboard.
/// - Print: browser print dialog on web; on other targets a clear note
///   that printing is available on the web demo.
/// - New Sale: back to the POS.
/// - View customer (credit/walk-in sales with a customer): the
///   customer's detail, where the khata entry is visible.
class ReceiptScreen extends ConsumerWidget {
  const ReceiptScreen({super.key, required this.saleId});

  final String saleId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sale = ref.watch(saleByIdProvider(saleId));
    if (sale == null) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: PharmaEmptyState(
          icon: Icons.receipt_long_outlined,
          title: 'Sale not found',
          message: 'There is no sale with id "$saleId" in this demo.',
          actionLabel: 'Back to POS',
          onAction: () => context.go('/billing'),
        ),
      );
    }
    final branch = ref.watch(activeBranchProvider);
    final brand = ref.watch(brandConfigProvider);
    final customer = sale.customerId == null
        ? null
        : ref.watch(customerByIdProvider(sale.customerId!));
    final text = receiptText(
      sale: sale,
      branchName: branch.name,
      branchAddress: branch.address,
      brandHeader: brand.receiptHeader,
      customerName: customer?.name,
    );
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            title: 'Receipt ${sale.invoiceNumber}',
            subtitle: 'Sale saved — share, print or start a new sale',
            actionLabel: 'Sales history',
            actionIcon: Icons.history_outlined,
            onAction: () => context.go('/billing/history'),
          ),
          const SizedBox(height: 16),
          PharmaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Text(
                    brand.receiptHeader,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(height: 4),
                Center(
                  child: Text(
                    '${branch.name} • ${branch.address}',
                    style: Theme.of(context).textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                ),
                Center(
                  child: Text(
                    'Phone: ${branch.phone}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                const SizedBox(height: 8),
                const Divider(),
                _ReceiptRow(label: 'Invoice', value: sale.invoiceNumber),
                _ReceiptRow(
                  label: 'Date',
                  value: formatReceiptDateTime(
                    sale.createdAt ?? DateTime.now(),
                  ),
                ),
                _ReceiptRow(label: 'Cashier', value: sale.cashierName),
                if (customer != null)
                  _ReceiptRow(label: 'Customer', value: customer.name),
                const Divider(),
                for (final item in sale.items) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${item.medicineName} × ${item.quantity}',
                                style: Theme.of(context).textTheme.bodyMedium
                                    ?.copyWith(fontWeight: FontWeight.w600),
                              ),
                              Text(
                                item.batchNo == null
                                    ? '${formatPkr(item.unitPriceMinor)} each'
                                    : 'Batch ${item.batchNo}'
                                          '${item.batchExpiryDate == null ? '' : ' • exp ${item.batchExpiryDate!.day}/${item.batchExpiryDate!.month}/${item.batchExpiryDate!.year}'}'
                                          ' • ${formatPkr(item.unitPriceMinor)} each',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                              if (item.lineDiscountMinor > 0)
                                Text(
                                  'Discount: -${formatPkr(item.lineDiscountMinor)}',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                            ],
                          ),
                        ),
                        Text(
                          formatPkr(item.lineTotalMinor),
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                ],
                const Divider(),
                _ReceiptRow(
                  label: 'Subtotal',
                  value: formatPkr(sale.subtotalMinor),
                ),
                if (sale.billDiscountMinor > 0)
                  _ReceiptRow(
                    label: 'Bill discount',
                    value: '-${formatPkr(sale.billDiscountMinor)}',
                  ),
                if (sale.taxMinor > 0)
                  _ReceiptRow(label: 'Tax', value: formatPkr(sale.taxMinor)),
                _ReceiptRow(
                  label: 'Total',
                  value: formatPkr(sale.totalMinor),
                  bold: true,
                ),
                _ReceiptRow(
                  label: 'Payment',
                  value: salePaymentMethodLabel(sale.paymentMethod),
                ),
                if (sale.paymentMethod == SalePaymentMethod.cash) ...[
                  _ReceiptRow(
                    label: 'Cash received',
                    value: formatPkr(sale.cashReceivedMinor),
                  ),
                  _ReceiptRow(
                    label: 'Change',
                    value: formatPkr(sale.changeMinor),
                  ),
                ],
                if (sale.isCredit)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'On credit — added to the customer khata.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
                Center(
                  child: StatusBadge(
                    label: 'DEMO — not a real receipt',
                    kind: StatusKind.warning,
                  ),
                ),
                const SizedBox(height: 8),
                const Center(child: Text('Thank you for shopping with us!')),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              PharmaButton(
                label: 'Share',
                icon: Icons.share_outlined,
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: text));
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'Receipt text copied — share it from any app.',
                      ),
                    ),
                  );
                },
              ),
              PharmaButton(
                label: 'Print',
                icon: Icons.print_outlined,
                variant: PharmaButtonVariant.secondary,
                onPressed: () {
                  if (canPrintReceipt) {
                    printReceipt();
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Printing is available on the web demo — use Share to copy the receipt text.',
                        ),
                      ),
                    );
                  }
                },
              ),
              PharmaButton(
                label: 'New Sale',
                icon: Icons.point_of_sale_outlined,
                variant: PharmaButtonVariant.secondary,
                onPressed: () => context.go('/billing'),
              ),
              if (customer != null)
                PharmaButton(
                  label: 'View customer',
                  icon: Icons.person_outline,
                  variant: PharmaButtonVariant.text,
                  onPressed: () => context.go('/customers/${customer.id}'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ReceiptRow extends StatelessWidget {
  const _ReceiptRow({
    required this.label,
    required this.value,
    this.bold = false,
  });

  final String label;
  final String value;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyMedium?.copyWith(
      fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(child: Text(label, style: style)),
          Text(value, style: style),
        ],
      ),
    );
  }
}
