import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/services/branch_context.dart';
import '../../core/utils/money.dart';
import '../../core/widgets/design_system.dart';
import '../../models/medicine.dart';
import '../../models/purchase_order.dart';
import '../orders/orders_provider.dart';
import '../suppliers/suppliers_provider.dart';
import 'purchases_logic.dart';
import 'purchases_provider.dart';

/// Create purchase order (Day 7, SRS FR-PUR-01).
///
/// Route `/purchases/new` (optional `?supplier=<id>` pre-selects the
/// supplier, e.g. from a supplier detail screen).
///
/// Pick a supplier, add medicines from the 180-medicine catalogue
/// with quantities and cost prices (int paisa), add notes, save as a
/// Draft. Approval and receiving happen on the PO detail screen.
class PurchaseFormScreen extends ConsumerStatefulWidget {
  const PurchaseFormScreen({super.key, this.preselectedSupplierId});

  final String? preselectedSupplierId;

  @override
  ConsumerState<PurchaseFormScreen> createState() =>
      _PurchaseFormScreenState();
}

class _PoLineDraft {
  _PoLineDraft({required this.medicine, int? costMinor})
    : costMinor = costMinor ?? (medicine.priceMinor * 0.8).round();

  final Medicine medicine;
  int quantity = 1;
  int costMinor;
}

class _PurchaseFormScreenState extends ConsumerState<PurchaseFormScreen> {
  String? _supplierId;
  String _medicineQuery = '';
  final _notes = TextEditingController();
  final _lines = <_PoLineDraft>[];
  List<String> _errors = [];
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _supplierId = widget.preselectedSupplierId;
  }

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  List<PurchaseOrderItem> get _items => [
    for (final line in _lines)
      PurchaseOrderItem(
        medicineId: line.medicine.id,
        medicineName: line.medicine.name,
        quantityOrdered: line.quantity,
        unitCostMinor: line.costMinor,
      ),
  ];

  Future<void> _save() async {
    final errors = validatePurchaseOrderForm(
      supplierId: _supplierId,
      items: _items,
    );
    if (errors.isNotEmpty) {
      setState(() => _errors = errors);
      return;
    }
    setState(() {
      _errors = [];
      _saving = true;
    });
    final branchId = ref.read(activeBranchProvider).id;
    final result = await ref
        .read(purchaseOrdersProvider.notifier)
        .createOrder(
          branchId: branchId,
          supplierId: _supplierId!,
          items: _items,
          notes: _notes.text,
        );
    if (!mounted) return;
    setState(() => _saving = false);
    if (result.error != null) {
      setState(() => _errors = [result.error!]);
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${result.order!.poNumber} created as Draft.')),
    );
    context.go('/purchases/${result.order!.id}');
  }

  @override
  Widget build(BuildContext context) {
    final suppliersAsync = ref.watch(suppliersProvider);
    final medicinesAsync = ref.watch(orderMedicinesProvider);
    final branch = ref.watch(activeBranchProvider);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            title: 'New purchase order',
            subtitle: 'Branch: ${branch.name}',
            actionLabel: 'All Purchases',
            actionIcon: Icons.shopping_cart_outlined,
            onAction: () => context.go('/purchases'),
          ),
          const SizedBox(height: 16),
          if (_errors.isNotEmpty) ...[
            PharmaErrorBox(errors: _errors),
            const SizedBox(height: 16),
          ],
          PharmaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Supplier',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                suppliersAsync.when(
                  loading: () => const SkeletonList(count: 1),
                  error: (error, _) => const Text(
                    'Suppliers could not load.',
                  ),
                  data: (suppliers) {
                    final value = suppliers.any((s) => s.id == _supplierId)
                        ? _supplierId
                        : null;
                    return DropdownButtonFormField<String?>(
                      // Week 8 Day 2 (D177): isExpanded, the
                      // D153/D162 trap — 'Supplier — contact person'
                      // is wider than the 390px line without it.
                      isExpanded: true,
                      initialValue: value,
                      hint: const Text('Select a supplier'),
                      items: [
                        for (final supplier in suppliers)
                          DropdownMenuItem<String?>(
                            value: supplier.id,
                            child: Text(
                              '${supplier.name} — ${supplier.contactPerson}',
                            ),
                          ),
                      ],
                      onChanged: (selected) =>
                          setState(() => _supplierId = selected),
                    );
                  },
                ),
                const SizedBox(height: 16),
                PharmaTextField(
                  controller: _notes,
                  label: 'Notes (optional)',
                  hintText: 'e.g. Monthly antibiotic restock',
                  maxLines: 2,
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          const SectionHeader(title: 'Order lines'),
          const SizedBox(height: 12),
          if (_lines.isEmpty)
            const PharmaCard(
              child: Text(
                'No lines yet — search for a medicine below and tap it '
                'to add it to this order.',
              ),
            )
          else
            PharmaCard(
              child: Column(
                children: [
                  for (var i = 0; i < _lines.length; i++) ...[
                    if (i > 0) const Divider(height: 1),
                    _PoLineRow(
                      line: _lines[i],
                      onQuantityChanged: (qty) => setState(
                        () => _lines[i].quantity = qty,
                      ),
                      onCostChanged: (costMinor) => setState(
                        () => _lines[i].costMinor = costMinor,
                      ),
                      onRemove: () => setState(() => _lines.removeAt(i)),
                    ),
                  ],
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Order total',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                        Text(
                          formatPkr(poTotalMinor(_items)),
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 24),
          const SectionHeader(title: 'Add medicines'),
          const SizedBox(height: 12),
          PharmaSearchField(
            hintText: 'Search medicines by name or brand…',
            onChanged: (value) => setState(() => _medicineQuery = value),
          ),
          const SizedBox(height: 12),
          medicinesAsync.when(
            loading: () => const SkeletonList(count: 4),
            error: (error, _) => const PharmaCard(
              child: Text('Medicines could not load.'),
            ),
            data: (medicines) {
              final needle = _medicineQuery.trim().toLowerCase();
              final matching = medicines.where((medicine) {
                if (needle.isEmpty) return true;
                return medicine.name.toLowerCase().contains(needle) ||
                    medicine.brand.toLowerCase().contains(needle);
              }).take(8).toList();
              if (matching.isEmpty) {
                return const PharmaCard(
                  child: Text('No medicines match that search.'),
                );
              }
              return PharmaCard(
                child: Column(
                  children: [
                    for (var i = 0; i < matching.length; i++) ...[
                      if (i > 0) const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.medication_outlined),
                        title: Text(
                          '${matching[i].name} ${matching[i].strength}',
                        ),
                        subtitle: Text(
                          '${matching[i].brand} • ${matching[i].packSize} • '
                          'sells at ${formatPkr(matching[i].priceMinor)}',
                        ),
                        trailing: Icon(
                          _lines.any(
                                (line) =>
                                    line.medicine.id == matching[i].id,
                              )
                              ? Icons.check_circle
                              : Icons.add_circle_outline,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        onTap: () {
                          if (_lines.any(
                            (line) => line.medicine.id == matching[i].id,
                          )) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  '${matching[i].name} is already on this order.',
                                ),
                              ),
                            );
                            return;
                          }
                          setState(
                            () => _lines.add(
                              _PoLineDraft(medicine: matching[i]),
                            ),
                          );
                        },
                      ),
                    ],
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 24),
          PharmaButton(
            label: 'Create purchase order',
            icon: Icons.shopping_cart_outlined,
            loading: _saving,
            onPressed: _save,
            expand: true,
          ),
        ],
      ),
    );
  }
}

class _PoLineRow extends StatefulWidget {
  const _PoLineRow({
    required this.line,
    required this.onQuantityChanged,
    required this.onCostChanged,
    required this.onRemove,
  });

  final _PoLineDraft line;
  final ValueChanged<int> onQuantityChanged;
  final ValueChanged<int> onCostChanged;
  final VoidCallback onRemove;

  @override
  State<_PoLineRow> createState() => _PoLineRowState();
}

class _PoLineRowState extends State<_PoLineRow> {
  late final TextEditingController _costController;

  @override
  void initState() {
    super.initState();
    _costController = TextEditingController(
      text: (widget.line.costMinor / 100).toStringAsFixed(0),
    );
  }

  @override
  void dispose() {
    _costController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final line = widget.line;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${line.medicine.name} ${line.medicine.strength}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                tooltip: 'Remove line',
                icon: const Icon(Icons.delete_outline),
                onPressed: widget.onRemove,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              IconButton(
                tooltip: 'Decrease quantity',
                icon: const Icon(Icons.remove_circle_outline),
                onPressed: line.quantity > 1
                    ? () => widget.onQuantityChanged(line.quantity - 1)
                    : null,
              ),
              Text(
                '${line.quantity}',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                ),
              ),
              IconButton(
                tooltip: 'Increase quantity',
                icon: const Icon(Icons.add_circle_outline),
                onPressed: () =>
                    widget.onQuantityChanged(line.quantity + 1),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: PharmaTextField(
                  controller: _costController,
                  label: 'Cost price (Rs / unit)',
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  onChanged: (value) {
                    final rupees = double.tryParse(value.trim());
                    if (rupees != null && rupees >= 0) {
                      widget.onCostChanged((rupees * 100).round());
                    }
                  },
                ),
              ),
              const SizedBox(width: 8),
              Text(
                formatPkr(line.costMinor * line.quantity),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
