import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/services/branch_context.dart';
import '../../core/utils/money.dart';
import '../../core/widgets/design_system.dart';
import '../../models/supplier.dart';
import 'auto_purchase_logic.dart';
import 'auto_purchase_provider.dart';

/// Auto Purchase List (Week 2 Day 2, SRS FR-PUR-01 — Hadi asked for
/// it specifically).
///
/// Route `/purchases/auto` (under the Purchases module).
///
/// A suggested order list computed from live inventory for the active
/// branch: low stock, below reorder level, and near-expiry medicines
/// whose usable (sellable) stock is low. Staff review the list —
/// edit quantities, change the supplier per line, remove lines —
/// then approve: one Draft PO per supplier is created through the
/// normal purchases flow, so the POs appear in Purchases at once and
/// follow Draft → Approved → receiving with batch-wise receiving and
/// the supplier ledger.
///
/// Medicines already covered by an open PO are excluded by default
/// (no double-ordering) and counted in the banner above the list.
/// The list is branch-scoped — head office sees each branch's list
/// separately, and a PO never mixes branches.
class AutoPurchaseListScreen extends ConsumerStatefulWidget {
  const AutoPurchaseListScreen({super.key});

  @override
  ConsumerState<AutoPurchaseListScreen> createState() =>
      _AutoPurchaseListScreenState();
}

class _AutoPurchaseListScreenState
    extends ConsumerState<AutoPurchaseListScreen> {
  final _qtyControllers = <String, TextEditingController>{};
  final _qtySynced = <String, int>{};

  /// Client-generated approval key, minted once per approval tap and
  /// reused if that approval fails and the staff retries — so a retry
  /// can never create duplicate POs (D65). Reset on success.
  String? _approvalKey;

  @override
  void initState() {
    super.initState();
    final branch = ref.read(activeBranchProvider);
    Future.microtask(
      () => ref.read(autoPurchaseListProvider.notifier).load(branch.id),
    );
  }

  @override
  void dispose() {
    for (final controller in _qtyControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  TextEditingController _qtyControllerFor(AutoPurchaseLine line) {
    final id = line.suggestion.medicineId;
    final controller = _qtyControllers.putIfAbsent(
      id,
      () => TextEditingController(text: '${line.quantity}'),
    );
    if (_qtySynced[id] != line.quantity) {
      _qtySynced[id] = line.quantity;
      if (controller.text != '${line.quantity}') {
        controller.text = '${line.quantity}';
      }
    }
    return controller;
  }

  void _onQtyChanged(AutoPurchaseLine line, String text) {
    final medicineId = line.suggestion.medicineId;
    if (text.isEmpty) {
      _qtySynced[medicineId] = 0;
      ref.read(autoPurchaseListProvider.notifier).setQuantity(medicineId, 0);
      return;
    }
    final quantity = int.tryParse(text);
    if (quantity == null) return;
    _qtySynced[medicineId] = quantity;
    final error = ref
        .read(autoPurchaseListProvider.notifier)
        .setQuantity(medicineId, quantity);
    if (error != null && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error)));
    }
  }

  Future<void> _approve() async {
    final branch = ref.read(activeBranchProvider);
    _approvalKey ??=
        'auto-po-${branch.id}-${DateTime.now().millisecondsSinceEpoch}';
    final result = await ref
        .read(autoPurchaseListProvider.notifier)
        .approve(idempotencyKey: _approvalKey);
    if (!mounted) return;
    if (result.error != null && result.orders.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(result.error!)));
      return;
    }
    _approvalKey = null;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.orders.length == 1
              ? '${result.orders.first.poNumber} created as Draft.'
              : '${result.orders.length} draft purchase orders created.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final branch = ref.watch(activeBranchProvider);
    ref.listen(activeBranchProvider, (previous, next) {
      if (previous?.id != next.id) {
        ref.read(autoPurchaseListProvider.notifier).load(next.id);
      }
    });
    final state = ref.watch(autoPurchaseListProvider);
    final suppliers = ref.watch(autoPurchaseSuppliersProvider);
    final supplierNames = {for (final s in suppliers) s.id: s.name};
    final isWide = MediaQuery.sizeOf(context).width >= 900;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            title: 'Auto Purchase List',
            subtitle: 'Branch: ${branch.name} — suggested orders from '
                'live stock levels',
            actionLabel: 'Refresh',
            actionIcon: Icons.refresh_outlined,
            onAction: () => ref
                .read(autoPurchaseListProvider.notifier)
                .refresh(),
          ),
          const SizedBox(height: 16),
          if (state.error != null)
            _MessageBanner(
              icon: Icons.error_outline,
              message: state.error!,
              kind: StatusKind.danger,
            ),
          if (state.lastCreated.isNotEmpty) ...[
            _MessageBanner(
              icon: Icons.check_circle_outline,
              message:
                  '${state.lastCreated.length} draft purchase order(s) '
                  'created: ${state.lastCreated.map((po) => po.poNumber).join(', ')}.',
              kind: StatusKind.success,
              actionLabel: 'View purchase orders',
              onAction: () => context.go('/purchases'),
            ),
            const SizedBox(height: 12),
          ],
          if (state.excludedCount > 0) ...[
            _MessageBanner(
              icon: Icons.info_outlined,
              message:
                  '${state.excludedCount} item(s) already covered by an '
                  'open purchase order — skipped so nothing is ordered '
                  'twice (${state.excluded.map((s) => s.medicineName).join(', ')}).',
              kind: StatusKind.info,
            ),
            const SizedBox(height: 12),
          ],
          if (state.loading)
            const SkeletonList(count: 4)
          else if (state.lines.isEmpty)
            PharmaEmptyState(
              icon: Icons.shopping_basket_outlined,
              title: 'Nothing to order',
              message: 'Stock is above reorder levels at ${branch.name}, '
                  'and nothing covered by an open purchase order needs '
                  'reordering. Check back after sales or receiving.',
              actionLabel: 'View purchase orders',
              onAction: () => context.go('/purchases'),
            )
          else ...[
            PharmaCard(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Wrap(
                  spacing: 24,
                  runSpacing: 8,
                  children: [
                    _SummaryItem(
                      label: 'Lines to order',
                      value: '${state.orderableCount} of ${state.lines.length}',
                    ),
                    _SummaryItem(
                      label: 'Estimated total',
                      value: formatPkr(state.totalMinor),
                    ),
                    _SummaryItem(
                      label: 'Excluded (open PO)',
                      value: '${state.excludedCount}',
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            if (isWide)
              _WideTable(
                lines: state.lines,
                supplierNames: supplierNames,
                suppliers: suppliers,
                qtyControllerFor: _qtyControllerFor,
                onQtyChanged: _onQtyChanged,
                onSupplierChanged: (line, supplierId) {
                  final error = ref
                      .read(autoPurchaseListProvider.notifier)
                      .setSupplier(line.suggestion.medicineId, supplierId);
                  if (error != null && mounted) {
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(SnackBar(content: Text(error)));
                  }
                },
                onRemove: (line) {
                  ref
                      .read(autoPurchaseListProvider.notifier)
                      .removeLine(line.suggestion.medicineId);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'Line removed. Refresh the list to bring it back.',
                      ),
                    ),
                  );
                },
              )
            else
              for (final line in state.lines) ...[
                _LineCard(
                  line: line,
                  supplierNames: supplierNames,
                  suppliers: suppliers,
                  qtyController: _qtyControllerFor(line),
                  onQtyChanged: (text) => _onQtyChanged(line, text),
                  onSupplierChanged: (supplierId) {
                    final error = ref
                        .read(autoPurchaseListProvider.notifier)
                        .setSupplier(line.suggestion.medicineId, supplierId);
                    if (error != null && mounted) {
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(SnackBar(content: Text(error)));
                    }
                  },
                  onRemove: () {
                    ref
                        .read(autoPurchaseListProvider.notifier)
                        .removeLine(line.suggestion.medicineId);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Line removed. Refresh the list to bring it back.',
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 12),
              ],
            const SizedBox(height: 16),
            PharmaCard(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Estimated total',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        Text(
                          formatPkr(state.totalMinor),
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 16,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Approval creates one Draft purchase order per '
                      'supplier. Lines set to 0 are not ordered.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 12),
                    PharmaButton(
                      label: 'Approve & create purchase orders',
                      icon: Icons.check_outlined,
                      loading: state.isApproving,
                      onPressed: state.orderableCount == 0
                          ? null
                          : _approve,
                      expand: true,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SummaryItem extends StatelessWidget {
  const _SummaryItem({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 2),
        Text(
          value,
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
        ),
      ],
    );
  }
}

class _MessageBanner extends StatelessWidget {
  const _MessageBanner({
    required this.icon,
    required this.message,
    required this.kind,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String message;
  final StatusKind kind;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.dividerColor),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 10,
            height: 10,
            margin: const EdgeInsets.only(top: 5),
            decoration: BoxDecoration(
              color: kind.color,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Icon(icon, size: 20, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(child: Text(message)),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(width: 8),
            PharmaButton(
              label: actionLabel!,
              variant: PharmaButtonVariant.secondary,
              size: PharmaButtonSize.small,
              onPressed: onAction,
            ),
          ],
        ],
      ),
    );
  }
}

/// Wide (desktop) layout: one clean table row per suggested line.
class _WideTable extends StatelessWidget {
  const _WideTable({
    required this.lines,
    required this.supplierNames,
    required this.suppliers,
    required this.qtyControllerFor,
    required this.onQtyChanged,
    required this.onSupplierChanged,
    required this.onRemove,
  });

  final List<AutoPurchaseLine> lines;
  final Map<String, String> supplierNames;
  final List<Supplier> suppliers;
  final TextEditingController Function(AutoPurchaseLine) qtyControllerFor;
  final void Function(AutoPurchaseLine, String) onQtyChanged;
  final void Function(AutoPurchaseLine, String) onSupplierChanged;
  final void Function(AutoPurchaseLine) onRemove;

  @override
  Widget build(BuildContext context) {
    return PharmaCard(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          columns: const [
            DataColumn(label: Text('Medicine')),
            DataColumn(label: Text('Reason')),
            DataColumn(label: Text('Usable'), numeric: true),
            DataColumn(label: Text('Reorder'), numeric: true),
            DataColumn(label: Text('Unit cost'), numeric: true),
            DataColumn(label: Text('Order qty'), numeric: true),
            DataColumn(label: Text('Line total'), numeric: true),
            DataColumn(label: Text('Supplier')),
            DataColumn(label: Text('')),
          ],
          rows: [
            for (final line in lines)
              DataRow(
                key: ValueKey('auto-line-${line.suggestion.medicineId}'),
                cells: [
                  DataCell(
                    Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          line.suggestion.medicineName,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        Text(
                          '${line.suggestion.brand} • '
                          '${line.suggestion.strength} • '
                          '${line.suggestion.packSize}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  DataCell(
                    StatusBadge(
                      label: autoPurchaseReasonLabel(line.suggestion.reason),
                      kind: switch (line.suggestion.reason) {
                        AutoPurchaseReason.lowStock => StatusKind.danger,
                        AutoPurchaseReason.nearExpiry => StatusKind.warning,
                        AutoPurchaseReason.belowReorderLevel =>
                          StatusKind.info,
                      },
                    ),
                  ),
                  DataCell(Text('${line.suggestion.usableStock}')),
                  DataCell(Text('${line.suggestion.reorderLevel}')),
                  DataCell(
                    Text(formatPkr(line.suggestion.unitCostMinor)),
                  ),
                  DataCell(
                    SizedBox(
                      width: 76,
                      child: TextField(
                        key: ValueKey(
                          'qty-${line.suggestion.medicineId}',
                        ),
                        controller: qtyControllerFor(line),
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        textAlign: TextAlign.center,
                        decoration: const InputDecoration(
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 8,
                          ),
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (text) => onQtyChanged(line, text),
                      ),
                    ),
                  ),
                  DataCell(Text(formatPkr(line.lineTotalMinor))),
                  DataCell(
                    _SupplierDropdown(
                      key: ValueKey(
                        'supplier-${line.suggestion.medicineId}',
                      ),
                      line: line,
                      suppliers: suppliers,
                      onChanged: (supplierId) =>
                          onSupplierChanged(line, supplierId),
                    ),
                  ),
                  DataCell(
                    IconButton(
                      key: ValueKey(
                        'remove-${line.suggestion.medicineId}',
                      ),
                      tooltip: 'Remove line',
                      icon: const Icon(Icons.close_outlined),
                      onPressed: () => onRemove(line),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// Narrow (mobile) layout: one card per suggested line.
class _LineCard extends StatelessWidget {
  const _LineCard({
    required this.line,
    required this.supplierNames,
    required this.suppliers,
    required this.qtyController,
    required this.onQtyChanged,
    required this.onSupplierChanged,
    required this.onRemove,
  });

  final AutoPurchaseLine line;
  final Map<String, String> supplierNames;
  final List<Supplier> suppliers;
  final TextEditingController qtyController;
  final ValueChanged<String> onQtyChanged;
  final ValueChanged<String> onSupplierChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final suggestion = line.suggestion;
    return PharmaCard(
      key: ValueKey('auto-line-${suggestion.medicineId}'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        suggestion.medicineName,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        '${suggestion.brand} • ${suggestion.strength} • '
                        '${suggestion.packSize}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                StatusBadge(
                  label: autoPurchaseReasonLabel(suggestion.reason),
                  kind: switch (suggestion.reason) {
                    AutoPurchaseReason.lowStock => StatusKind.danger,
                    AutoPurchaseReason.nearExpiry => StatusKind.warning,
                    AutoPurchaseReason.belowReorderLevel => StatusKind.info,
                  },
                ),
                IconButton(
                  key: ValueKey('remove-${suggestion.medicineId}'),
                  tooltip: 'Remove line',
                  icon: const Icon(Icons.close_outlined),
                  onPressed: onRemove,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 16,
              runSpacing: 4,
              children: [
                _Fact('Usable stock', '${suggestion.usableStock}'),
                _Fact('Reorder level', '${suggestion.reorderLevel}'),
                _Fact('Unit cost', formatPkr(suggestion.unitCostMinor)),
                _Fact('Line total', formatPkr(line.lineTotalMinor)),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Text(
                  'Order qty',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 76,
                  child: TextField(
                    key: ValueKey('qty-${suggestion.medicineId}'),
                    controller: qtyController,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                    ],
                    textAlign: TextAlign.center,
                    decoration: const InputDecoration(
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 8,
                      ),
                      border: OutlineInputBorder(),
                    ),
                    onChanged: onQtyChanged,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _SupplierDropdown(
              key: ValueKey('supplier-${suggestion.medicineId}'),
              line: line,
              suppliers: suppliers,
              onChanged: onSupplierChanged,
            ),
          ],
        ),
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
      ],
    );
  }
}

/// Per-line supplier picker. The value is the line's supplier; staff
/// change it here and approval groups by the new value.
class _SupplierDropdown extends StatelessWidget {
  const _SupplierDropdown({
    super.key,
    required this.line,
    required this.suppliers,
    required this.onChanged,
  });

  final AutoPurchaseLine line;
  final List<Supplier> suppliers;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButton<String>(
      value: line.supplierId,
      hint: const Text('Pick supplier'),
      isDense: true,
      underline: const SizedBox.shrink(),
      items: [
        for (final supplier in suppliers)
          DropdownMenuItem<String>(
            value: supplier.id,
            child: Text(supplier.name),
          ),
      ],
      onChanged: (value) {
        if (value != null) onChanged(value);
      },
    );
  }
}
