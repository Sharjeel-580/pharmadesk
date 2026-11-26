import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/data/sync_queue.dart';
import '../../core/utils/money.dart';
import '../../core/widgets/design_system.dart';
import '../../models/purchase_order.dart';
import '../suppliers/suppliers_provider.dart';
import 'purchases_logic.dart';
import 'purchases_provider.dart';

/// Purchase order detail (Day 7, SRS FR-PUR-01/02/03).
///
/// Route `/purchases/:id`.
///
/// Supplier, status, lines with ordered/received/remaining, totals,
/// and the guarded actions: Approve (Draft only), Receive goods
/// (Approved / Partially received — batch-wise, adds stock to
/// inventory and charges the supplier ledger), Cancel (Draft /
/// Approved with nothing received).
class PurchaseDetailScreen extends ConsumerWidget {
  const PurchaseDetailScreen({super.key, required this.purchaseOrderId});

  final String purchaseOrderId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final order = ref.watch(purchaseOrderByIdProvider(purchaseOrderId));
    if (order == null) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: PharmaEmptyState(
          icon: Icons.shopping_cart_outlined,
          title: 'Purchase order not found',
          message:
              'There is no purchase order with id "$purchaseOrderId" in this demo.',
          actionLabel: 'Back to Purchases',
          onAction: () => context.go('/purchases'),
        ),
      );
    }
    final supplier = ref.watch(supplierByIdProvider(order.supplierId));
    final theme = Theme.of(context);
    final kind = switch (order.status) {
      PurchaseOrderStatus.draft => StatusKind.neutral,
      PurchaseOrderStatus.approved => StatusKind.info,
      PurchaseOrderStatus.partiallyReceived => StatusKind.warning,
      PurchaseOrderStatus.received => StatusKind.success,
      PurchaseOrderStatus.cancelled => StatusKind.danger,
    };
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            title: order.poNumber,
            subtitle:
                'Created ${_formatDate(order.createdAt)}'
                '${order.approvedBy != null ? ' • Approved by ${order.approvedBy}' : ''}',
            actionLabel: 'All Purchases',
            actionIcon: Icons.shopping_cart_outlined,
            onAction: () => context.go('/purchases'),
          ),
          const SizedBox(height: 16),
          // Week 8 Day 2 (D177): a Wrap, not a Row — the status
          // badge plus the supplier-name badge are wider than the
          // 390px line in the test font; on desktop they still sit
          // on one line.
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              StatusBadge(
                label: purchaseOrderStatusLabel(order.status),
                kind: kind,
              ),
              StatusBadge(
                label: supplier?.name ?? order.supplierId,
                kind: StatusKind.neutral,
                icon: Icons.local_shipping_outlined,
              ),
            ],
          ),
          const SizedBox(height: 16),
          PharmaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.local_shipping_outlined),
                  title: Text(supplier?.name ?? order.supplierId),
                  subtitle: supplier == null
                      ? null
                      : Text(
                          '${supplier.contactPerson} • ${supplier.phone}',
                        ),
                  trailing: supplier == null
                      ? null
                      : TextButton(
                          onPressed: () =>
                              context.go('/suppliers/${supplier.id}'),
                          child: const Text('View supplier'),
                        ),
                ),
                if (order.notes != null) ...[
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text('Notes: ${order.notes}'),
                  ),
                ],
                const Divider(height: 1),
                const SizedBox(height: 8),
                for (final item in order.items) ...[
                  _PoItemRow(item: item),
                  const SizedBox(height: 8),
                ],
                const Divider(height: 1),
                const SizedBox(height: 8),
                _TotalRow(
                  label: 'Order total',
                  value: formatPkr(order.totalMinor),
                ),
                _TotalRow(
                  label: 'Received so far',
                  value: formatPkr(order.receivedTotalMinor),
                ),
                _TotalRow(
                  label: 'Still outstanding',
                  value: formatPkr(
                    order.totalMinor - order.receivedTotalMinor,
                  ),
                  bold: true,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (canApprovePo(order.status))
                PharmaButton(
                  label: 'Approve',
                  icon: Icons.check_circle_outline,
                  onPressed: () => _approve(context, ref, order),
                ),
              if (canReceivePo(order))
                PharmaButton(
                  label: 'Receive goods',
                  icon: Icons.inventory_2_outlined,
                  onPressed: () => _showReceiveDialog(context, ref, order),
                ),
              if (canCancelPo(order))
                PharmaButton(
                  label: 'Cancel order',
                  variant: PharmaButtonVariant.danger,
                  icon: Icons.cancel_outlined,
                  onPressed: () => _cancel(context, ref, order),
                ),
            ],
          ),
          if (order.status == PurchaseOrderStatus.received) ...[
            const SizedBox(height: 16),
            PharmaCard(
              child: Row(
                children: [
                  Icon(
                    Icons.check_circle_outline,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Received in full. The stock is in inventory and '
                      'the received value is on the supplier ledger.',
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (order.status == PurchaseOrderStatus.cancelled) ...[
            const SizedBox(height: 16),
            const PharmaCard(
              child: Text(
                'This purchase order was cancelled. Cancelled orders are '
                'read-only history.',
              ),
            ),
          ],
          const SizedBox(height: 8),
          Text(
            'Receiving adds a batch per line to inventory (FR-PUR-03) — '
            'check the Inventory screen: the new batch is there '
            'immediately, with the batch number and expiry you entered.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Future<void> _approve(
    BuildContext context,
    WidgetRef ref,
    PurchaseOrder order,
  ) async {
    final ok = await ref
        .read(purchaseOrdersProvider.notifier)
        .approveOrder(order);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? '${order.poNumber} approved — goods can now be received.'
              : 'This order cannot be approved in its current state.',
        ),
      ),
    );
  }

  Future<void> _cancel(
    BuildContext context,
    WidgetRef ref,
    PurchaseOrder order,
  ) async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Cancel ${order.poNumber}?',
      message:
          'The purchase order is cancelled and becomes read-only history. '
          'Nothing is ordered from this supplier for it.',
      confirmLabel: 'Cancel order',
      danger: true,
    );
    if (confirmed != true || !context.mounted) return;
    final ok = await ref
        .read(purchaseOrdersProvider.notifier)
        .cancelOrder(order);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? '${order.poNumber} cancelled.'
              : 'This order cannot be cancelled in its current state.',
        ),
      ),
    );
  }

  Future<void> _showReceiveDialog(
    BuildContext context,
    WidgetRef ref,
    PurchaseOrder order,
  ) async {
    final received = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => _ReceiveDialog(order: order),
    );
    if (received == true && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Goods received for ${order.poNumber} — stock is in '
            'inventory and the supplier ledger is updated.',
          ),
        ),
      );
    }
  }
}

String _formatDate(DateTime? value) {
  if (value == null) return 'unknown date';
  return '${value.day}/${value.month}/${value.year}';
}

class _TotalRow extends StatelessWidget {
  const _TotalRow({required this.label, required this.value, this.bold = false});

  final String label;
  final String value;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Week 8 Day 2 (D177): the label wraps instead of
          // overflowing — a long label plus a money figure is wider
          // than the 390px line in the test font; the money value
          // itself stays complete, never ellipsized.
          Flexible(
            child: Text(
              label,
              style: TextStyle(
                fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _PoItemRow extends StatelessWidget {
  const _PoItemRow({required this.item});

  final PurchaseOrderItem item;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.medicineName,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              Text(
                '${formatPkr(item.unitCostMinor)} / unit',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        Text(
          '${item.quantityReceived}/${item.quantityOrdered} received',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: 90,
          child: Text(
            formatPkr(item.lineTotalMinor),
            textAlign: TextAlign.right,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
  }
}

/// Goods-receiving dialog (SRS FR-PUR-02): per line, how many units
/// arrived and as which batch (batch number, manufacture + expiry
/// dates). Partial receiving is allowed — the PO becomes Partially
/// received until every line is full.
class _ReceiveDialog extends ConsumerStatefulWidget {
  const _ReceiveDialog({required this.order});

  final PurchaseOrder order;

  @override
  ConsumerState<_ReceiveDialog> createState() => _ReceiveDialogState();
}

class _ReceiveDialogState extends ConsumerState<_ReceiveDialog> {
  late final List<_ReceiveLineState> _lines;
  List<String> _errors = [];
  bool _saving = false;

  /// Minted once per dialog (Week 3 Day 2, D103): the receiving
  /// idempotency key. A failed submit keeps the dialog open, so a
  /// retry reuses this key and the production layer returns the
  /// original receipt instead of receiving the stock twice (D54/D65
  /// pattern). A fresh dialog is a new delivery, so it mints a new
  /// key.
  late final String _idempotencyKey =
      newIdempotencyKey('receipt-${widget.order.branchId}');

  @override
  void initState() {
    super.initState();
    _lines = [
      for (final item in widget.order.items)
        if (item.quantityRemaining > 0) _ReceiveLineState(item: item),
    ];
  }

  @override
  void dispose() {
    for (final line in _lines) {
      line.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final lines = [
      for (final line in _lines) line.toReceivingLine(),
    ];
    final errors = validateReceiving(lines);
    if (errors.isNotEmpty) {
      setState(() => _errors = errors);
      return;
    }
    setState(() {
      _errors = [];
      _saving = true;
    });
    final result = await ref
        .read(purchaseOrdersProvider.notifier)
        .receiveOrder(
          widget.order,
          lines,
          idempotencyKey: _idempotencyKey,
        );
    if (!mounted) return;
    setState(() => _saving = false);
    if (result.error != null) {
      setState(() => _errors = [result.error!]);
      return;
    }
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Receive goods — ${widget.order.poNumber}'),
      content: SingleChildScrollView(
        child: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_errors.isNotEmpty) ...[
                PharmaErrorBox(errors: _errors),
                const SizedBox(height: 12),
              ],
              const Text(
                'Enter the batch details for the goods that arrived. '
                'Each line becomes a batch in inventory.',
              ),
              const SizedBox(height: 12),
              for (final line in _lines) ...[
                _ReceiveLineEditor(line: line),
                const Divider(height: 24),
              ],
            ],
          ),
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
          label: 'Receive goods',
          size: PharmaButtonSize.small,
          loading: _saving,
          onPressed: _save,
        ),
      ],
    );
  }
}

class _ReceiveLineState {
  _ReceiveLineState({required this.item})
    : qtyController = TextEditingController(
        text: item.quantityRemaining.toString(),
      ),
      batchController = TextEditingController();

  final PurchaseOrderItem item;
  final TextEditingController qtyController;
  final TextEditingController batchController;
  DateTime? mfgDate;
  DateTime? expiryDate;

  ReceivingLine toReceivingLine() {
    return ReceivingLine(
      item: item,
      quantityReceivedNow: int.tryParse(qtyController.text.trim()) ?? 0,
      batchNo: batchController.text,
      mfgDate: mfgDate,
      expiryDate: expiryDate,
    );
  }

  void dispose() {
    qtyController.dispose();
    batchController.dispose();
  }
}

class _ReceiveLineEditor extends StatefulWidget {
  const _ReceiveLineEditor({required this.line});

  final _ReceiveLineState line;

  @override
  State<_ReceiveLineEditor> createState() => _ReceiveLineEditorState();
}

class _ReceiveLineEditorState extends State<_ReceiveLineEditor> {
  Future<void> _pickDate({required bool isMfg}) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: isMfg
          ? now.subtract(const Duration(days: 30))
          : now.add(const Duration(days: 365)),
      firstDate: DateTime(2020),
      lastDate: DateTime(2035),
    );
    if (picked == null) return;
    setState(() {
      if (isMfg) {
        widget.line.mfgDate = picked;
      } else {
        widget.line.expiryDate = picked;
      }
    });
  }

  String _dateLabel(DateTime? date) {
    if (date == null) return 'Pick a date';
    return '${date.day}/${date.month}/${date.year}';
  }

  @override
  Widget build(BuildContext context) {
    final line = widget.line;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${line.item.medicineName} — ${line.item.quantityRemaining} outstanding',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: PharmaTextField(
                controller: line.qtyController,
                label: 'Quantity received',
                keyboardType: TextInputType.number,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: PharmaTextField(
                controller: line.batchController,
                label: 'Batch number',
                hintText: 'e.g. B-2026-114',
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.calendar_today_outlined, size: 18),
                label: Text('Mfg: ${_dateLabel(line.mfgDate)}'),
                onPressed: () => _pickDate(isMfg: true),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.calendar_today_outlined, size: 18),
                label: Text('Expiry: ${_dateLabel(line.expiryDate)}'),
                onPressed: () => _pickDate(isMfg: false),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
