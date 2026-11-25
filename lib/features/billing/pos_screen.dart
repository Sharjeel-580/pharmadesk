import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/services/branch_context.dart';
import '../../core/utils/money.dart';
import '../../core/widgets/design_system.dart';
import '../../models/inventory_item.dart';
import '../../models/medicine.dart';
import '../../models/sale.dart';
import '../authentication/auth_state.dart';
import '../inventory/inventory_logic.dart';
import '../inventory/inventory_provider.dart';
import '../medicines/medicine_logic.dart';
import 'billing_logic.dart';
import 'billing_provider.dart';
import '../customers/customers_provider.dart';

/// POS / billing screen (Day 6, SRS §8 + FR-POS-01–04, FR-POS-09).
///
/// Route `/billing`.
///
/// - Search medicines by name, brand or barcode (sample barcodes from
///   the catalogue) and add them to the cart. Each pick row shows the
///   FEFO batch + sellable stock from the Day 5 shared guard
///   ([canSellMedicine] / [fefoBatchFor]) — a medicine whose batches
///   are all expired can never be added (D30).
/// - Cart with quantity steppers (capped at sellable stock), per-line
///   discount, bill discount, tax, payment method (cash / card /
///   credit-khata), change calculation for cash.
/// - Completing a sale saves it, decrements stock FEFO, updates the
///   dashboards immediately and opens the receipt. A credit sale needs
///   a customer and updates their khata outstanding.
///
/// All money is int minor units (paisa); rupee fields convert at the
/// boundary.
class PosScreen extends ConsumerStatefulWidget {
  const PosScreen({super.key});

  @override
  ConsumerState<PosScreen> createState() => _PosScreenState();
}

class _PosScreenState extends ConsumerState<PosScreen> {
  final _billDiscountController = TextEditingController();
  final _cashReceivedController = TextEditingController();

  String _query = '';
  List<CartLine> _lines = [];
  String? _customerId;
  SalePaymentMethod _paymentMethod = SalePaymentMethod.cash;
  int _taxRatePercent = 0;
  List<String> _errors = [];
  bool _completing = false;

  @override
  void dispose() {
    _billDiscountController.dispose();
    _cashReceivedController.dispose();
    super.dispose();
  }

  int get _billDiscountMinor {
    final rupees = int.tryParse(_billDiscountController.text.trim());
    if (rupees == null) return 0;
    return rupees * 100;
  }

  int get _cashReceivedMinor {
    final rupees = int.tryParse(_cashReceivedController.text.trim());
    if (rupees == null) return 0;
    return rupees * 100;
  }

  int get _subtotalMinor => cartSubtotalMinor(_lines);
  int get _taxMinor => computeTaxMinor(
    taxableMinor: _subtotalMinor - _billDiscountMinor,
    taxRatePercent: _taxRatePercent,
  );
  int get _totalMinor => billTotalMinor(
    subtotalMinor: _subtotalMinor,
    billDiscountMinor: _billDiscountMinor,
    taxMinor: _taxMinor,
  );

  void _addMedicine(Medicine medicine) {
    final index = _lines.indexWhere((l) => l.medicineId == medicine.id);
    setState(() {
      if (index == -1) {
        _lines = [
          ..._lines,
          CartLine(
            medicineId: medicine.id,
            medicineName: medicine.name,
            unitPriceMinor: medicine.priceMinor,
          ),
        ];
      } else {
        final line = _lines[index];
        _lines = List.of(_lines)
          ..[index] = line.copyWith(quantity: line.quantity + 1);
      }
    });
  }

  void _changeQuantity(String medicineId, int delta) {
    final index = _lines.indexWhere((l) => l.medicineId == medicineId);
    if (index == -1) return;
    final line = _lines[index];
    final nextQty = line.quantity + delta;
    setState(() {
      if (nextQty < 1) {
        _lines = List.of(_lines)..removeAt(index);
      } else {
        _lines = List.of(_lines)
          ..[index] = line.copyWith(quantity: nextQty);
      }
    });
  }

  void _setLineDiscount(String medicineId, int discountMinor) {
    final index = _lines.indexWhere((l) => l.medicineId == medicineId);
    if (index == -1) return;
    final line = _lines[index];
    setState(() {
      _lines = List.of(_lines)
        ..[index] = line.copyWith(lineDiscountMinor: discountMinor);
    });
  }

  void _removeLine(String medicineId) {
    setState(() {
      _lines = _lines.where((l) => l.medicineId != medicineId).toList();
    });
  }

  Future<void> _completeSale() async {
    final errors = <String>[];
    final billDiscountText = _billDiscountController.text.trim();
    if (billDiscountText.isNotEmpty &&
        int.tryParse(billDiscountText) == null) {
      errors.add('Bill discount must be a whole number of rupees.');
    }
    if (_paymentMethod == SalePaymentMethod.cash) {
      final cashText = _cashReceivedController.text.trim();
      if (cashText.isNotEmpty && int.tryParse(cashText) == null) {
        errors.add('Cash received must be a whole number of rupees.');
      }
    }
    if (errors.isNotEmpty) {
      setState(() => _errors = errors);
      return;
    }
    setState(() {
      _errors = [];
      _completing = true;
    });
    final branch = ref.read(activeBranchProvider);
    final user = ref.read(authProvider);
    final result = await ref.read(salesProvider.notifier).completeSale(
      branchId: branch.id,
      customerId: _customerId,
      cashierName: user?.name ?? 'Counter Staff',
      lines: _lines,
      billDiscountMinor: _billDiscountMinor,
      taxRatePercent: _taxRatePercent,
      paymentMethod: _paymentMethod,
      cashReceivedMinor: _cashReceivedMinor,
    );
    if (!mounted) return;
    setState(() => _completing = false);
    final sale = result.sale;
    if (sale == null) {
      setState(() => _errors = [result.error ?? 'Sale could not complete.']);
      return;
    }
    context.go('/billing/receipt/${sale.id}');
  }

  @override
  Widget build(BuildContext context) {
    final branch = ref.watch(activeBranchProvider);
    final user = ref.watch(authProvider);
    final medicines = ref.watch(medicinesProvider).asData?.value ?? [];
    final inventory = ref.watch(branchInventoryProvider(branch.id));
    final customers = ref.watch(customersProvider).asData?.value ?? [];
    final inventoryByMedicine = groupBatchesByMedicine(inventory);
    final sellableByMedicine = {
      for (final entry in inventoryByMedicine.entries)
        entry.key: sellableStockFor(entry.value),
    };
    final matching = filterMedicines(medicines, query: _query);
    final customerValue =
        _customerId != null &&
            customers.any((c) => c.id == _customerId)
        ? _customerId
        : null;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            title: 'Billing & POS',
            subtitle:
                '${branch.name} • Cashier: ${user?.name ?? 'Counter Staff'}',
            actionLabel: 'Sales history',
            actionIcon: Icons.history_outlined,
            onAction: () => context.go('/billing/history'),
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
                const SectionHeader(
                  title: 'Add medicines',
                  subtitle: 'Search by name, brand or barcode',
                ),
                const SizedBox(height: 12),
                PharmaSearchField(
                  hintText: 'Search medicines or scan a barcode…',
                  onChanged: (value) => setState(() => _query = value),
                ),
                const SizedBox(height: 8),
                if (matching.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('No medicines match this search.'),
                  )
                else
                  for (final medicine in matching.take(8))
                    _MedicinePickRow(
                      medicine: medicine,
                      batches:
                          inventoryByMedicine[medicine.id] ?? const [],
                      onAdd: () => _addMedicine(medicine),
                    ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          PharmaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SectionHeader(
                  title: 'Cart (${_lines.length})',
                  subtitle: _lines.isEmpty
                      ? 'No items yet — add at least one medicine.'
                      : 'Quantities are capped at sellable stock',
                ),
                const SizedBox(height: 8),
                if (_lines.isNotEmpty)
                  for (final line in _lines)
                    _CartLineRow(
                      line: line,
                      sellableStock:
                          sellableByMedicine[line.medicineId] ?? 0,
                      onDecrease: () =>
                          _changeQuantity(line.medicineId, -1),
                      onIncrease: () =>
                          _changeQuantity(line.medicineId, 1),
                      onDiscountChanged: (discountMinor) =>
                          _setLineDiscount(line.medicineId, discountMinor),
                      onRemove: () => _removeLine(line.medicineId),
                    ),
                const Divider(),
                _TotalRow(label: 'Subtotal', valueMinor: _subtotalMinor),
                if (cartLineDiscountsMinor(_lines) > 0)
                  _TotalRow(
                    label: 'Line discounts',
                    valueMinor: -cartLineDiscountsMinor(_lines),
                  ),
                if (_billDiscountMinor > 0)
                  _TotalRow(
                    label: 'Bill discount',
                    valueMinor: -_billDiscountMinor,
                  ),
                if (_taxMinor > 0)
                  _TotalRow(
                    label: 'Tax ($_taxRatePercent%)',
                    valueMinor: _taxMinor,
                  ),
                _TotalRow(label: 'Total', valueMinor: _totalMinor, bold: true),
                if (_paymentMethod == SalePaymentMethod.cash &&
                    _totalMinor > 0) ...[
                  const SizedBox(height: 4),
                  _TotalRow(
                    label: 'Change due',
                    valueMinor: changeDueMinor(
                      totalMinor: _totalMinor,
                      cashReceivedMinor: _cashReceivedMinor,
                    ),
                  ),
                  if (cashShortfallMinor(
                        totalMinor: _totalMinor,
                        cashReceivedMinor: _cashReceivedMinor,
                      ) >
                      0)
                    _TotalRow(
                      label: 'Still to receive',
                      valueMinor: cashShortfallMinor(
                        totalMinor: _totalMinor,
                        cashReceivedMinor: _cashReceivedMinor,
                      ),
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
                  title: 'Customer & payment',
                  subtitle: 'Walk-in, or a saved customer for khata sales',
                ),
                const SizedBox(height: 12),
                const Text(
                  'Customer',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                DropdownButton<String?>(
                  key: const ValueKey('pos-customer-dropdown'),
                  value: customerValue,
                  isExpanded: true,
                  hint: const Text('Walk-in customer'),
                  items: [
                    const DropdownMenuItem<String?>(
                      child: Text('Walk-in customer'),
                    ),
                    for (final customer in customers)
                      DropdownMenuItem<String?>(
                        value: customer.id,
                        child: Text(
                          '${customer.name} • ${customer.phone}',
                        ),
                      ),
                  ],
                  onChanged: (value) =>
                      setState(() => _customerId = value),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Payment method',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                SegmentedButton<SalePaymentMethod>(
                  segments: const [
                    ButtonSegment(
                      value: SalePaymentMethod.cash,
                      label: Text('Cash'),
                      icon: Icon(Icons.money_outlined),
                    ),
                    ButtonSegment(
                      value: SalePaymentMethod.card,
                      label: Text('Card'),
                      icon: Icon(Icons.credit_card_outlined),
                    ),
                    ButtonSegment(
                      value: SalePaymentMethod.credit,
                      label: Text('Credit (khata)'),
                      icon: Icon(Icons.book_outlined),
                    ),
                  ],
                  selected: {_paymentMethod},
                  onSelectionChanged: (selection) => setState(
                    () => _paymentMethod = selection.first,
                  ),
                ),
                if (_paymentMethod == SalePaymentMethod.credit) ...[
                  const SizedBox(height: 8),
                  Text(
                    _customerId == null
                        ? 'Credit sales need a customer — pick one above. The sale total is added to their khata.'
                        : 'The sale total will be added to this customer\'s khata outstanding.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: PharmaTextField(
                        controller: _billDiscountController,
                        label: 'Bill discount (Rs)',
                        hintText: '0',
                        keyboardType: TextInputType.number,
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Tax rate',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 4),
                          DropdownButton<int>(
                            key: const ValueKey('pos-tax-dropdown'),
                            value: _taxRatePercent,
                            isExpanded: true,
                            items: const [
                              DropdownMenuItem(value: 0, child: Text('No tax')),
                              DropdownMenuItem(value: 5, child: Text('5%')),
                              DropdownMenuItem(value: 10, child: Text('10%')),
                              DropdownMenuItem(value: 16, child: Text('16%')),
                              DropdownMenuItem(value: 18, child: Text('18%')),
                            ],
                            onChanged: (value) => setState(
                              () => _taxRatePercent = value ?? 0,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (_paymentMethod == SalePaymentMethod.cash) ...[
                  const SizedBox(height: 12),
                  PharmaTextField(
                    controller: _cashReceivedController,
                    label: 'Cash received (Rs)',
                    hintText: 'Amount handed over by the customer',
                    keyboardType: TextInputType.number,
                    onChanged: (_) => setState(() {}),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 24),
          PharmaButton(
            label: _completing ? 'Completing sale…' : 'Complete Sale',
            icon: Icons.point_of_sale_outlined,
            loading: _completing,
            expand: true,
            onPressed: _completing || _lines.isEmpty ? null : _completeSale,
          ),
        ],
      ),
    );
  }
}

class _MedicinePickRow extends StatelessWidget {
  const _MedicinePickRow({
    required this.medicine,
    required this.batches,
    required this.onAdd,
  });

  final Medicine medicine;

  /// All batch rows for this medicine at the active branch (Day 5).
  final List<InventoryItem> batches;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // THE GUARD (D30): the shared rule from inventory_logic — an
    // expired batch can never be sold. A medicine is addable only when
    // at least one batch is sellable; the FEFO batch (earliest expiry
    // first) is the one shown and picked.
    final sellable = canSellMedicine(batches);
    final fefo = fefoBatchFor(batches);
    final sellableQty = sellableStockFor(batches);
    final expiredOnly = batches.isNotEmpty && !sellable;
    final batchLabel = fefo == null
        ? expiredOnly
              ? 'All batches expired — never sellable'
              : batches.isEmpty
              ? 'No batch info'
              : 'Out of stock'
        : 'Batch ${fefo.batchNo ?? '—'} • ${fefo.expiryDate == null ? 'no expiry date' : 'expires ${fefo.expiryDate!.day}/${fefo.expiryDate!.month}/${fefo.expiryDate!.year}'} • FEFO';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${medicine.name} ${medicine.strength}',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  '${medicine.brand} • ${medicine.packSize} • ${formatPkr(medicine.priceMinor)}',
                  style: theme.textTheme.bodySmall,
                ),
                Text(
                  sellable
                      ? '$batchLabel • $sellableQty in stock'
                      : batchLabel,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: expiredOnly ? StatusKind.danger.color : null,
                    fontWeight: expiredOnly ? FontWeight.w700 : null,
                  ),
                ),
              ],
            ),
          ),
          PharmaButton(
            key: ValueKey('pos-add-${medicine.id}'),
            label: expiredOnly
                ? 'Expired'
                : sellable
                ? 'Add'
                : 'No stock',
            size: PharmaButtonSize.small,
            onPressed: sellable ? onAdd : null,
          ),
        ],
      ),
    );
  }
}

class _CartLineRow extends StatelessWidget {
  const _CartLineRow({
    required this.line,
    required this.sellableStock,
    required this.onDecrease,
    required this.onIncrease,
    required this.onDiscountChanged,
    required this.onRemove,
  });

  final CartLine line;
  final int sellableStock;
  final VoidCallback onDecrease;
  final VoidCallback onIncrease;
  final ValueChanged<int> onDiscountChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final atMax = line.quantity >= sellableStock;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  line.medicineName,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  '${formatPkr(line.unitPriceMinor)} each • ${formatPkr(line.lineTotalMinor)}',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 4),
                _LineDiscountField(
                  key: ValueKey('line-discount-${line.medicineId}'),
                  initialDiscountMinor: line.lineDiscountMinor,
                  onChanged: onDiscountChanged,
                ),
              ],
            ),
          ),
          IconButton(
            key: ValueKey('pos-qty-minus-${line.medicineId}'),
            tooltip: 'Decrease quantity',
            icon: const Icon(Icons.remove_circle_outline),
            onPressed: onDecrease,
          ),
          Text(
            '${line.quantity}',
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          IconButton(
            key: ValueKey('pos-qty-plus-${line.medicineId}'),
            tooltip: 'Increase quantity',
            icon: const Icon(Icons.add_circle_outline),
            onPressed: atMax ? null : onIncrease,
          ),
          IconButton(
            key: ValueKey('pos-remove-${line.medicineId}'),
            tooltip: 'Remove item',
            icon: const Icon(Icons.delete_outline),
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}

/// Per-line discount field (whole rupees). Keeps its own controller so
/// typing does not lose focus when the cart rebuilds on every keystroke.
class _LineDiscountField extends StatefulWidget {
  const _LineDiscountField({
    super.key,
    required this.initialDiscountMinor,
    required this.onChanged,
  });

  final int initialDiscountMinor;
  final ValueChanged<int> onChanged;

  @override
  State<_LineDiscountField> createState() => _LineDiscountFieldState();
}

class _LineDiscountFieldState extends State<_LineDiscountField> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: widget.initialDiscountMinor == 0
          ? ''
          : '${widget.initialDiscountMinor ~/ 100}',
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 140,
      child: TextField(
        controller: _controller,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(
          labelText: 'Line discount (Rs)',
          hintText: '0',
          isDense: true,
        ),
        onChanged: (value) {
          final rupees = int.tryParse(value.trim()) ?? 0;
          widget.onChanged(rupees * 100);
        },
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
