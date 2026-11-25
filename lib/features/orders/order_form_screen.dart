import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/services/branch_context.dart';
import '../../core/utils/money.dart';
import '../../core/widgets/design_system.dart';
import '../../models/inventory_item.dart';
import '../../models/medicine.dart';
import '../../models/order.dart';
import '../../models/prescription.dart';
import '../dashboard/dashboard_data.dart';
import '../inventory/inventory_logic.dart';
import 'order_logic.dart';
import 'orders_provider.dart';

/// Create / edit order form (Day 4), one screen for both.
///
/// - Create (`/orders/new`): staff-entered order — pick a customer (or
///   walk-in), add medicines from the catalogue (with batch/expiry info
///   from the branch inventory), quantities, discount, delivery vs
///   pickup, rider, source, notes, optional seeded prescription.
/// - Edit (`/orders/:id/edit`): same form prefilled; editable until
///   Delivered. Delivered / Cancelled orders open read-only with a
///   clear notice and no save button.
/// - Validation runs on save (at least one item, valid quantities,
///   discount within the subtotal, delivery needs an address).
///   All money is int minor units (paisa); the discount field takes
///   whole rupees and converts at the boundary.
class OrderFormScreen extends ConsumerWidget {
  const OrderFormScreen({super.key, this.orderId});

  /// `null` → create a new order; set → edit that order.
  final String? orderId;

  bool get isEdit => orderId != null;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!isEdit) return const _OrderFormBody();
    final order = ref.watch(orderByIdProvider(orderId!));
    if (order == null) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: PharmaEmptyState(
          icon: Icons.receipt_long_outlined,
          title: 'Order not found',
          message: 'There is no order with id "$orderId" in this demo.',
          actionLabel: 'Back to Orders',
          onAction: () => context.go('/orders'),
        ),
      );
    }
    return _OrderFormBody(order: order);
  }
}

class _OrderFormBody extends ConsumerStatefulWidget {
  const _OrderFormBody({this.order});

  final Order? order;

  @override
  ConsumerState<_OrderFormBody> createState() => _OrderFormBodyState();
}

class _OrderFormBodyState extends ConsumerState<_OrderFormBody> {
  late final TextEditingController _discountController;
  late final TextEditingController _addressController;
  late final TextEditingController _notesController;
  late final TextEditingController _medicineSearchController;

  String? _customerId;
  bool _isWalkIn = false;
  List<OrderItem> _lines = [];
  OrderSource _source = OrderSource.phone;
  FulfillmentType _fulfillment = FulfillmentType.delivery;
  String? _riderId;
  String? _prescriptionId;
  String _medicineQuery = '';
  List<String> _errors = [];
  bool _saving = false;

  bool get _isEdit => widget.order != null;
  bool get _readOnly =>
      widget.order != null && !canEdit(widget.order!.status);

  @override
  void initState() {
    super.initState();
    final order = widget.order;
    _discountController = TextEditingController(
      text: order == null || order.discountMinor == 0
          ? ''
          : '${order.discountMinor ~/ 100}',
    );
    _addressController = TextEditingController(
      text: order?.deliveryAddress ?? '',
    );
    _notesController = TextEditingController(text: order?.orderNotes ?? '');
    _medicineSearchController = TextEditingController();
    if (order != null) {
      _customerId = order.customerId == 'walk-in' ? null : order.customerId;
      _isWalkIn = order.customerId == 'walk-in';
      _lines = List.of(order.items);
      _source = order.source;
      _fulfillment = order.fulfillment;
      _riderId = order.riderId;
      _prescriptionId = order.prescriptionId;
    }
  }

  @override
  void dispose() {
    _discountController.dispose();
    _addressController.dispose();
    _notesController.dispose();
    _medicineSearchController.dispose();
    super.dispose();
  }

  int get _discountMinor {
    final rupees = int.tryParse(_discountController.text.trim());
    if (rupees == null) return 0;
    return rupees * 100;
  }

  int get _subtotalMinor => orderSubtotalMinor(_lines);
  int get _totalMinor => orderTotalMinor(
    items: _lines,
    discountMinor: _discountMinor,
  );

  void _addMedicine(Medicine medicine) {
    final index = _lines.indexWhere((l) => l.medicineId == medicine.id);
    setState(() {
      if (index == -1) {
        _lines = [
          ..._lines,
          OrderItem(
            medicineId: medicine.id,
            medicineName: medicine.name,
            quantity: 1,
            unitPrice: medicine.price,
          ),
        ];
      } else {
        final line = _lines[index];
        _lines = List.of(_lines)
          ..[index] = OrderItem(
            medicineId: line.medicineId,
            medicineName: line.medicineName,
            quantity: line.quantity + 1,
            unitPrice: line.unitPrice,
          );
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
          ..[index] = OrderItem(
            medicineId: line.medicineId,
            medicineName: line.medicineName,
            quantity: nextQty,
            unitPrice: line.unitPrice,
          );
      }
    });
  }

  void _removeLine(String medicineId) {
    setState(() {
      _lines = _lines.where((l) => l.medicineId != medicineId).toList();
    });
  }

  Future<void> _save() async {
    final errors = <String>[];
    final discountText = _discountController.text.trim();
    if (discountText.isNotEmpty && int.tryParse(discountText) == null) {
      errors.add('Discount must be a whole number of rupees.');
    }
    errors.addAll(
      validateOrderForm(
        customerId: _customerId,
        isWalkIn: _isWalkIn,
        items: _lines,
        discountMinor: _discountMinor,
        fulfillment: _fulfillment,
        deliveryAddress: _addressController.text,
      ),
    );
    if (errors.isNotEmpty) {
      setState(() => _errors = errors);
      return;
    }
    setState(() {
      _errors = [];
      _saving = true;
    });
    final branch = ref.read(activeBranchProvider);
    final notifier = ref.read(orderQueueProvider.notifier);
    if (!_isEdit) {
      final saved = await notifier.createOrder(
        buildNewOrder(
          branchId: branch.id,
          customerId: _customerId,
          isWalkIn: _isWalkIn,
          items: _lines,
          discountMinor: _discountMinor,
          source: _source,
          fulfillment: _fulfillment,
          deliveryAddress: _addressController.text.trim(),
          riderId: _riderId,
          orderNotes: _notesController.text,
          prescriptionId: _prescriptionId,
        ),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Order ${saved.id} created.')));
      context.go('/orders/${saved.id}');
    } else {
      final original = widget.order!;
      final updated = buildEditedOrder(
        original: original,
        items: _lines,
        discountMinor: _discountMinor,
        riderId: _fulfillment == FulfillmentType.delivery ? _riderId : null,
        clearRiderId: _fulfillment == FulfillmentType.pickup,
        orderNotes: _notesController.text.trim().isEmpty
            ? null
            : _notesController.text.trim(),
        prescriptionId: _prescriptionId,
        clearPrescriptionId: _prescriptionId == null,
        deliveryAddress: _fulfillment == FulfillmentType.pickup
            ? 'Pickup from branch'
            : _addressController.text.trim(),
      );
      final ok = await notifier.updateOrder(updated);
      if (!mounted) return;
      setState(() => _saving = false);
      if (!ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('This order can no longer be edited.'),
          ),
        );
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Order ${original.id} updated.')),
      );
      context.go('/orders/${original.id}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final branch = ref.watch(activeBranchProvider);
    final customers = ref.watch(orderCustomersProvider).asData?.value ?? [];
    final medicines = ref.watch(orderMedicinesProvider).asData?.value ?? [];
    final riders = ref.watch(orderRidersProvider).asData?.value ?? [];
    final prescriptions =
        ref.watch(orderPrescriptionsProvider(branch.id)).asData?.value ?? [];
    final inventory =
        ref.watch(orderInventoryProvider(branch.id)).asData?.value ?? [];
    // Day 5: one medicine has 1–3 batch rows per branch — group them so
    // the pick row can show the FEFO batch and the shared sellable
    // guard (inventory_logic) instead of a single row's expiry.
    final inventoryByMedicine = groupBatchesByMedicine(inventory);
    final query = _medicineQuery.trim().toLowerCase();
    final matchingMedicines = medicines.where((medicine) {
      if (query.isEmpty) return true;
      return medicine.name.toLowerCase().contains(query) ||
          medicine.brand.toLowerCase().contains(query);
    }).toList();
    final order = widget.order;
    final title = _isEdit ? 'Edit order ${order!.id}' : 'New Order';
    final subtitle = _isEdit
        ? '${branch.name} • ${orderStatusLabel(order!.status)}'
        : '${branch.name} • staff-entered order';
    // Dropdown values must exist in the item list: while the lookup
    // providers are still loading the lists are empty, and a set value
    // with no matching item crashes DropdownButton — so fall back to
    // null (hint) until the data arrives.
    final customerValue = _isWalkIn
        ? 'walk-in'
        : customers.any((c) => c.id == _customerId)
        ? _customerId
        : null;
    final riderValue = riders.any((r) => r.id == _riderId) ? _riderId : null;
    final prescriptionValue = prescriptions.any(
      (rx) => rx.id == _prescriptionId,
    )
        ? _prescriptionId
        : null;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            title: title,
            subtitle: subtitle,
            actionLabel: 'All Orders',
            actionIcon: Icons.receipt_long_outlined,
            onAction: () => context.go('/orders'),
          ),
          if (_readOnly) ...[
            const SizedBox(height: 16),
            _ReadOnlyBanner(status: order!.status),
          ],
          if (_errors.isNotEmpty) ...[
            const SizedBox(height: 16),
            _ErrorBox(errors: _errors),
          ],
          const SizedBox(height: 16),
          PharmaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SectionHeader(
                  title: 'Customer',
                  subtitle: 'Pick a saved customer, or walk-in',
                ),
                const SizedBox(height: 12),
                const Text(
                  'Customer',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                DropdownButton<String>(
                  key: const ValueKey('customer-dropdown'),
                  value: customerValue,
                  isExpanded: true,
                  hint: const Text('Select a customer'),
                  items: [
                    const DropdownMenuItem<String>(
                      value: 'walk-in',
                      child: Text('Walk-in customer'),
                    ),
                    for (final customer in customers)
                      DropdownMenuItem<String>(
                        value: customer.id,
                        child: Text(
                          '${customer.name} • ${customer.phone}',
                        ),
                      ),
                  ],
                  onChanged: _readOnly
                      ? null
                      : (value) {
                          setState(() {
                            if (value == 'walk-in') {
                              _isWalkIn = true;
                              _customerId = null;
                            } else {
                              _isWalkIn = false;
                              _customerId = value;
                              final customer = customers
                                  .where((c) => c.id == value)
                                  .firstOrNull;
                              final address =
                                  customer?.addresses.firstOrNull?.address;
                              if (address != null &&
                                  _fulfillment ==
                                      FulfillmentType.delivery) {
                                _addressController.text = address;
                              }
                            }
                          });
                        },
                ),
                const SizedBox(height: 12),
                const Text(
                  'Source',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                SegmentedButton<OrderSource>(
                  segments: const [
                    ButtonSegment(
                      value: OrderSource.phone,
                      label: Text('Phone'),
                      icon: Icon(Icons.phone_outlined),
                    ),
                    ButtonSegment(
                      value: OrderSource.whatsapp,
                      label: Text('WhatsApp'),
                      icon: Icon(Icons.chat_outlined),
                    ),
                    ButtonSegment(
                      value: OrderSource.walkIn,
                      label: Text('Walk-in'),
                      icon: Icon(Icons.person_outline),
                    ),
                  ],
                  selected: {_source},
                  onSelectionChanged: _readOnly
                      ? null
                      : (selection) =>
                            setState(() => _source = selection.first),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          PharmaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SectionHeader(
                  title: 'Items',
                  subtitle: 'Search the catalogue and add medicines',
                ),
                const SizedBox(height: 12),
                PharmaSearchField(
                  hintText: 'Search medicines…',
                  onChanged: (value) =>
                      setState(() => _medicineQuery = value),
                ),
                const SizedBox(height: 8),
                if (matchingMedicines.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('No medicines match this search.'),
                  )
                else
                  for (final medicine in matchingMedicines.take(6))
                    _MedicinePickRow(
                      medicine: medicine,
                      batches:
                          inventoryByMedicine[medicine.id] ?? const [],
                      readOnly: _readOnly,
                      onAdd: () => _addMedicine(medicine),
                    ),
                const SizedBox(height: 12),
                const Divider(),
                if (_lines.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      'No items yet — add at least one medicine.',
                    ),
                  )
                else
                  for (final line in _lines)
                    _OrderLineRow(
                      line: line,
                      readOnly: _readOnly,
                      onDecrease: () => _changeQuantity(line.medicineId, -1),
                      onIncrease: () => _changeQuantity(line.medicineId, 1),
                      onRemove: () => _removeLine(line.medicineId),
                    ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          PharmaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SectionHeader(
                  title: 'Delivery & rider',
                  subtitle: 'Delivery to the customer, or pickup',
                ),
                const SizedBox(height: 12),
                SegmentedButton<FulfillmentType>(
                  segments: const [
                    ButtonSegment(
                      value: FulfillmentType.delivery,
                      label: Text('Delivery'),
                      icon: Icon(Icons.delivery_dining_outlined),
                    ),
                    ButtonSegment(
                      value: FulfillmentType.pickup,
                      label: Text('Pickup'),
                      icon: Icon(Icons.store_outlined),
                    ),
                  ],
                  selected: {_fulfillment},
                  onSelectionChanged: _readOnly
                      ? null
                      : (selection) => setState(
                          () => _fulfillment = selection.first,
                        ),
                ),
                const SizedBox(height: 12),
                if (_fulfillment == FulfillmentType.delivery) ...[
                  PharmaTextField(
                    controller: _addressController,
                    label: 'Delivery address',
                    hintText: 'House, street, area',
                    enabled: !_readOnly,
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Rider',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  DropdownButton<String?>(
                    key: const ValueKey('rider-dropdown'),
                    value: riderValue,
                    isExpanded: true,
                    items: [
                      const DropdownMenuItem<String?>(
                        child: Text('No rider yet'),
                      ),
                      for (final rider in riders.where((r) => r.active))
                        DropdownMenuItem<String?>(
                          value: rider.id,
                          child: Text(
                            '${rider.name} • ${rider.phone}',
                          ),
                        ),
                    ],
                    onChanged: _readOnly
                        ? null
                        : (value) => setState(() => _riderId = value),
                  ),
                ] else
                  const Text(
                    'The customer collects this order from the branch — no rider needed.',
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          PharmaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SectionHeader(
                  title: 'Prescription (optional)',
                  subtitle: 'Attach a seeded prescription — no new photo capture on Day 4',
                ),
                const SizedBox(height: 12),
                const Text(
                  'Linked prescription',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                DropdownButton<String?>(
                  key: const ValueKey('prescription-dropdown'),
                  value: prescriptionValue,
                  isExpanded: true,
                  items: [
                    const DropdownMenuItem<String?>(
                      child: Text('No prescription'),
                    ),
                    for (final rx in prescriptions)
                      DropdownMenuItem<String?>(
                        value: rx.id,
                        child: Text(
                          '${rx.id} • ${_rxLabel(rx.status)}',
                        ),
                      ),
                  ],
                  onChanged: _readOnly
                      ? null
                      : (value) => setState(() => _prescriptionId = value),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          PharmaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SectionHeader(title: 'Notes & discount'),
                const SizedBox(height: 12),
                PharmaTextField(
                  controller: _notesController,
                  label: 'Order notes',
                  hintText: 'Anything the rider or pharmacist should know',
                  maxLines: 2,
                  enabled: !_readOnly,
                ),
                const SizedBox(height: 12),
                PharmaTextField(
                  controller: _discountController,
                  label: 'Discount (Rs, whole rupees)',
                  hintText: '0',
                  keyboardType: TextInputType.number,
                  enabled: !_readOnly,
                ),
                const SizedBox(height: 12),
                const Divider(),
                _TotalRow(label: 'Subtotal', valueMinor: _subtotalMinor),
                if (_discountMinor > 0)
                  _TotalRow(
                    label: 'Discount',
                    valueMinor: -_discountMinor,
                  ),
                _TotalRow(
                  label: 'Total',
                  valueMinor: _totalMinor,
                  bold: true,
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          if (!_readOnly)
            PharmaButton(
              label: _isEdit ? 'Save Changes' : 'Save Order',
              icon: Icons.check,
              loading: _saving,
              expand: true,
              onPressed: _saving ? null : _save,
            )
          else
            PharmaButton(
              label: 'Back to Order',
              icon: Icons.arrow_back,
              variant: PharmaButtonVariant.secondary,
              expand: true,
              onPressed: () => context.go('/orders/${order!.id}'),
            ),
        ],
      ),
    );
  }
}

String _rxLabel(PrescriptionStatus status) => switch (status) {
  PrescriptionStatus.pending => 'Pending review',
  PrescriptionStatus.approved => 'Approved',
  PrescriptionStatus.rejected => 'Rejected',
  PrescriptionStatus.needsClearerPhoto => 'Needs clearer photo',
};

class _ReadOnlyBanner extends StatelessWidget {
  const _ReadOnlyBanner({required this.status});

  final OrderStatus status;

  @override
  Widget build(BuildContext context) {
    final isDelivered =
        canonicalStatus(status) == OrderStatus.delivered;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: StatusKind.warning.color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: StatusKind.warning.color.withValues(alpha: 0.35),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.lock_outline, color: StatusKind.warning.color),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              isDelivered
                  ? 'This order is Delivered and read-only — items, discount, rider and notes cannot be changed.'
                  : 'This order is Cancelled and read-only — items, discount, rider and notes cannot be changed.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox({required this.errors});

  final List<String> errors;

  @override
  Widget build(BuildContext context) {
    final color = StatusKind.danger.color;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Please fix the following:',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
          const SizedBox(height: 4),
          for (final error in errors)
            Text('• $error', style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _MedicinePickRow extends StatelessWidget {
  const _MedicinePickRow({
    required this.medicine,
    required this.batches,
    required this.readOnly,
    required this.onAdd,
  });

  final Medicine medicine;

  /// All batch rows for this medicine at the active branch (Day 5).
  final List<InventoryItem> batches;
  final bool readOnly;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // THE GUARD (D30): the shared rule from inventory_logic — an
    // expired batch can never be added to an order. A medicine is
    // addable only when at least one batch is sellable; the FEFO batch
    // (earliest expiry first) is the one shown and picked.
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
        : 'Batch ${fefo.batchNo ?? '—'} • ${fefo.expiryDate == null ? 'no expiry date' : 'expires ${_formatDate(fefo.expiryDate!)}'} • FEFO';
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
                  '${medicine.brand} • ${medicine.packSize} • ${formatPkr(rupeesToMinorUnits(medicine.price))}',
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
            key: ValueKey('add-${medicine.id}'),
            label: expiredOnly
                ? 'Expired'
                : sellable
                ? 'Add'
                : 'No stock',
            size: PharmaButtonSize.small,
            onPressed: (readOnly || !sellable) ? null : onAdd,
          ),
        ],
      ),
    );
  }
}

String _formatDate(DateTime value) =>
    '${value.day}/${value.month}/${value.year}';

class _OrderLineRow extends StatelessWidget {
  const _OrderLineRow({
    required this.line,
    required this.readOnly,
    required this.onDecrease,
    required this.onIncrease,
    required this.onRemove,
  });

  final OrderItem line;
  final bool readOnly;
  final VoidCallback onDecrease;
  final VoidCallback onIncrease;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
                  '${formatPkr(rupeesToMinorUnits(line.unitPrice))} each • ${formatPkr(line.lineTotalMinor)}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          IconButton(
            key: ValueKey('qty-minus-${line.medicineId}'),
            tooltip: 'Decrease quantity',
            icon: const Icon(Icons.remove_circle_outline),
            onPressed: readOnly ? null : onDecrease,
          ),
          Text(
            '${line.quantity}',
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          IconButton(
            key: ValueKey('qty-plus-${line.medicineId}'),
            tooltip: 'Increase quantity',
            icon: const Icon(Icons.add_circle_outline),
            onPressed: readOnly ? null : onIncrease,
          ),
          IconButton(
            key: ValueKey('remove-${line.medicineId}'),
            tooltip: 'Remove item',
            icon: const Icon(Icons.delete_outline),
            onPressed: readOnly ? null : onRemove,
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
