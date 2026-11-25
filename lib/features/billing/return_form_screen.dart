import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/data/permission_service.dart';
import '../../core/services/branch_context.dart';
import '../../core/utils/money.dart';
import '../../core/widgets/design_system.dart';
import '../../models/sale.dart';
import '../authentication/auth_state.dart';
import 'billing_provider.dart';
import 'returns_logic.dart';
import 'returns_provider.dart';

/// New return form (Week 2 Day 4, FR-POS-08).
///
/// Route `/billing/returns/new` (optional `?sale=<saleId>` to
/// preselect a sale, e.g. from the receipt screen).
///
/// 1. Pick a completed sale at the active branch.
/// 2. Pick items + quantities (capped at what is still returnable:
///    sold − already returned across earlier returns).
/// 3. Give a reason (required) and confirm.
///
/// The refund preview is live: per chunk, unit price × qty minus the
/// pro-rated line discount; bill discount and tax are not refunded
/// (see `returns_logic.dart`). Confirm is role-gated on `posRefund`
/// (permission service, D70): a user without it sees why the button
/// is disabled instead of a dead button. On confirm the stock is
/// restocked, the sale status moves, and a credit sale comes off the
/// customer khata (see `returns_provider.dart`).
class ReturnFormScreen extends ConsumerStatefulWidget {
  const ReturnFormScreen({super.key, this.saleId});

  final String? saleId;

  @override
  ConsumerState<ReturnFormScreen> createState() => _ReturnFormScreenState();
}

class _ReturnFormScreenState extends ConsumerState<ReturnFormScreen> {
  final _reasonController = TextEditingController();
  String? _selectedSaleId;
  Map<String, int> _quantities = {};
  List<String> _errors = [];
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _selectedSaleId = widget.saleId;
  }

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  void _selectSale(String? saleId) {
    setState(() {
      _selectedSaleId = saleId;
      _quantities = {};
      _errors = [];
    });
  }

  void _setQuantity(String chunkKey, int qty) {
    setState(() => _quantities = {..._quantities, chunkKey: qty});
  }

  Future<void> _confirm(Sale sale) async {
    final user = ref.read(authProvider);
    setState(() {
      _errors = [];
      _submitting = true;
    });
    final result = await ref.read(saleReturnsProvider.notifier).createReturn(
      sale: sale,
      quantities: _quantities,
      reason: _reasonController.text,
      approver: user,
    );
    if (!mounted) return;
    setState(() => _submitting = false);
    if (result.saleReturn == null) {
      setState(() => _errors = [result.error ?? 'Return could not be recorded.']);
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Return recorded — ${formatPkr(result.saleReturn!.refundedAmountMinor)} refunded on ${sale.invoiceNumber}.',
        ),
      ),
    );
    context.go('/billing/returns');
  }

  @override
  Widget build(BuildContext context) {
    final branch = ref.watch(activeBranchProvider);
    final user = ref.watch(authProvider);
    final sales = ref.watch(branchSalesProvider(branch.id));
    final canApprove = permissionService.canWrite(
      user,
      'posRefund',
      branch.id,
    );
    final selected = _selectedSaleId == null
        ? null
        : sales.where((sale) => sale.id == _selectedSaleId).firstOrNull;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            title: 'New return',
            subtitle: '${branch.name} • Return items from a completed sale',
            actionLabel: 'All returns',
            actionIcon: Icons.keyboard_return_outlined,
            onAction: () => context.go('/billing/returns'),
          ),
          if (_errors.isNotEmpty) ...[
            const SizedBox(height: 16),
            PharmaErrorBox(errors: _errors),
          ],
          const SizedBox(height: 16),
          PharmaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Sale',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                DropdownButton<String?>(
                  key: const ValueKey('return-sale-dropdown'),
                  value: selected?.id,
                  isExpanded: true,
                  hint: const Text('Pick a completed sale'),
                  items: [
                    for (final sale in sales)
                      DropdownMenuItem<String?>(
                        value: sale.id,
                        child: Text(
                          '${sale.invoiceNumber} • ${formatPkr(sale.totalMinor)} • ${saleStatusLabel(sale.status)}',
                        ),
                      ),
                  ],
                  onChanged: _selectSale,
                ),
                if (_selectedSaleId != null && selected == null)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                      'That sale is not at this branch (or no longer exists) — pick one from the list.',
                    ),
                  ),
              ],
            ),
          ),
          if (selected != null) ...[
            const SizedBox(height: 16),
            _ReturnItemsCard(
              sale: selected,
              quantities: _quantities,
              onQuantityChanged: _setQuantity,
            ),
            const SizedBox(height: 16),
            PharmaCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  PharmaTextField(
                    controller: _reasonController,
                    label: 'Reason for the return (required)',
                    hintText: 'e.g. wrong medicine dispensed',
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 12),
                  _TotalRow(
                    label: 'Refund',
                    valueMinor: computeRefundMinor(
                      sale: selected,
                      quantities: _quantities,
                    ),
                    bold: true,
                  ),
                  Text(
                    'Refund = returned line totals (bill discount and tax are not refunded). '
                    'Returned units go back to their original batch; a credit sale comes off the customer khata.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  if (!canApprove)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        'You cannot approve returns in this branch — the POS refund permission belongs to the owner, HO admin, branch manager and cashier roles. Ask one of them to approve this return.',
                        style: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(
                              color: StatusKind.danger.color,
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                    ),
                  PharmaButton(
                    key: const ValueKey('return-confirm'),
                    label: _submitting ? 'Recording return…' : 'Confirm return',
                    icon: Icons.keyboard_return_outlined,
                    loading: _submitting,
                    expand: true,
                    onPressed: !canApprove || _submitting
                        ? null
                        : () => _confirm(selected),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ReturnItemsCard extends ConsumerWidget {
  const _ReturnItemsCard({
    required this.sale,
    required this.quantities,
    required this.onQuantityChanged,
  });

  final Sale sale;
  final Map<String, int> quantities;
  final void Function(String chunkKey, int qty) onQuantityChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final existing = ref.watch(saleReturnsForSaleProvider(sale.id));
    final returnable = returnableChunkQuantities(sale, existing);
    return PharmaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            title: 'Items — ${sale.invoiceNumber}',
            subtitle: sale.status == SaleStatus.returned
                ? 'Everything on this sale has already been returned.'
                : 'Quantities are capped at what is still returnable',
          ),
          const SizedBox(height: 8),
          for (final item in sale.items)
            _ReturnItemRow(
              item: item,
              returnable:
                  returnable[returnChunkKey(item.medicineId, item.batchId)] ??
                  0,
              quantity:
                  quantities[returnChunkKey(item.medicineId, item.batchId)] ??
                  0,
              onChanged: (qty) => onQuantityChanged(
                returnChunkKey(item.medicineId, item.batchId),
                qty,
              ),
            ),
        ],
      ),
    );
  }
}

class _ReturnItemRow extends StatelessWidget {
  const _ReturnItemRow({
    required this.item,
    required this.returnable,
    required this.quantity,
    required this.onChanged,
  });

  final SaleItem item;
  final int returnable;
  final int quantity;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final refund = chunkRefundMinor(item: item, quantity: quantity);
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
                  'Sold ${item.quantity} • ${item.batchNo == null ? 'no batch' : 'Batch ${item.batchNo}'} • ${formatPkr(item.unitPriceMinor)} each',
                  style: theme.textTheme.bodySmall,
                ),
                Text(
                  returnable == 0
                      ? 'Already fully returned'
                      : '$returnable still returnable • Refund ${formatPkr(refund)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: returnable == 0 ? StatusKind.danger.color : null,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            key: ValueKey('return-qty-minus-${item.medicineId}-${item.batchId}'),
            tooltip: 'Return one fewer',
            icon: const Icon(Icons.remove_circle_outline),
            onPressed: quantity <= 0
                ? null
                : () => onChanged(quantity - 1),
          ),
          Text(
            '$quantity',
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          IconButton(
            key: ValueKey('return-qty-plus-${item.medicineId}-${item.batchId}'),
            tooltip: 'Return one more',
            icon: const Icon(Icons.add_circle_outline),
            onPressed: quantity >= returnable
                ? null
                : () => onChanged(quantity + 1),
          ),
        ],
      ),
    );
  }
}

class _TotalRow extends StatelessWidget {
  const _TotalRow({
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
