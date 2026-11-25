import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/data/sync_queue.dart';
import '../../core/utils/money.dart';
import '../../core/widgets/design_system.dart';
import '../../models/inventory_item.dart';
import '../../models/medicine.dart';
import 'inventory_logic.dart';
import 'inventory_provider.dart';

/// Stock-operation dialogs (Day 5), shared by the inventory screen and
/// the medicine detail screen.
///
/// - Receive: adds a batch (medicine, batch no., mfg/expiry, qty, cost).
/// - Adjust: increases/decreases one batch with a required reason.
/// - Count: records a physical count and reports the variance.
///
/// Every dialog validates before saving and returns its result so the
/// caller can confirm with a snackbar; nothing here writes to a
/// repository directly — all writes go through [InventoryNotifier].

/// Opens the receive-stock dialog. [medicine] preselects the medicine
/// (medicine detail passes it); otherwise the dialog offers the full
/// catalogue dropdown. Returns the created batch, or `null` on cancel.
Future<InventoryItem?> showReceiveStockDialog(
  BuildContext context,
  WidgetRef ref, {
  required String branchId,
  Medicine? medicine,
}) {
  return showDialog<InventoryItem>(
    context: context,
    builder: (dialogContext) => _ReceiveStockDialog(
      branchId: branchId,
      preselectedMedicine: medicine,
    ),
  );
}

/// Opens the adjust-stock dialog for one batch. Returns the updated
/// batch, or `null` on cancel / failed adjustment.
Future<InventoryItem?> showAdjustStockDialog(
  BuildContext context,
  WidgetRef ref, {
  required InventoryItem batch,
  required String medicineName,
}) {
  return showDialog<InventoryItem>(
    context: context,
    builder: (dialogContext) => _AdjustStockDialog(
      batch: batch,
      medicineName: medicineName,
    ),
  );
}

/// Opens the stock-count dialog for one batch. Returns the updated
/// batch plus the variance (counted − system), or `null` on cancel /
/// failed count.
Future<({InventoryItem item, int variance})?> showStockCountDialog(
  BuildContext context,
  WidgetRef ref, {
  required InventoryItem batch,
  required String medicineName,
}) {
  return showDialog<({InventoryItem item, int variance})>(
    context: context,
    builder: (dialogContext) => _StockCountDialog(
      batch: batch,
      medicineName: medicineName,
    ),
  );
}

class _ReceiveStockDialog extends ConsumerStatefulWidget {
  const _ReceiveStockDialog({
    required this.branchId,
    this.preselectedMedicine,
  });

  final String branchId;
  final Medicine? preselectedMedicine;

  @override
  ConsumerState<_ReceiveStockDialog> createState() =>
      _ReceiveStockDialogState();
}

class _ReceiveStockDialogState extends ConsumerState<_ReceiveStockDialog> {
  late final TextEditingController _batchNoController;
  late final TextEditingController _qtyController;
  late final TextEditingController _costController;
  String? _medicineId;
  DateTime _mfgDate = DateTime.now();
  DateTime _expiryDate = DateTime.now().add(const Duration(days: 365));
  String? _error;
  bool _saving = false;

  /// Dialog-held idempotency key (Week 3 Day 5, D115 — closes the
  /// D54 UI gap for this dialog): minted once for the dialog's
  /// lifetime and reused on a retried submit, so a retry after a
  /// failed submit dedupes in the layer instead of creating a
  /// second batch. Same pattern as the PO receiving dialog (D103).
  late final String _idempotencyKey =
      newIdempotencyKey('stock-receive-${widget.branchId}');

  @override
  void initState() {
    super.initState();
    _batchNoController = TextEditingController();
    _qtyController = TextEditingController();
    _costController = TextEditingController();
    _medicineId = widget.preselectedMedicine?.id;
  }

  @override
  void dispose() {
    _batchNoController.dispose();
    _qtyController.dispose();
    _costController.dispose();
    super.dispose();
  }

  Future<void> _pickDate({required bool isMfg}) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: isMfg ? _mfgDate : _expiryDate,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365 * 5)),
    );
    if (picked == null) return;
    setState(() {
      if (isMfg) {
        _mfgDate = picked;
      } else {
        _expiryDate = picked;
      }
    });
  }

  Future<void> _save() async {
    final qty = int.tryParse(_qtyController.text.trim());
    final costRupees = int.tryParse(_costController.text.trim());
    String? error;
    if (_medicineId == null) {
      error = 'Pick a medicine first.';
    } else if (_batchNoController.text.trim().isEmpty) {
      error = 'Batch number is required.';
    } else if (qty == null || qty <= 0) {
      error = 'Quantity must be a whole number above zero.';
    } else if (costRupees == null || costRupees < 0) {
      error = 'Cost per unit must be a whole number of rupees (0 or more).';
    } else if (!_expiryDate.isAfter(_mfgDate)) {
      error = 'Expiry date must be after the manufacture date.';
    }
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    setState(() {
      _error = null;
      _saving = true;
    });
    // A failed submit stays in the dialog with the error shown and
    // the button re-enabled, so the user CAN retry — and the retry
    // reuses [_idempotencyKey] (D115). Before this, a layer throw
    // left the dialog stuck on loading with no retry path at all.
    InventoryItem? created;
    try {
      created = await ref
          .read(inventoryProvider.notifier)
          .receiveStock(
            branchId: widget.branchId,
            medicineId: _medicineId!,
            batchNo: _batchNoController.text.trim(),
            mfgDate: _mfgDate,
            expiryDate: _expiryDate,
            quantity: qty!,
            costMinor: rupeesToMinorUnits(costRupees!),
            idempotencyKey: _idempotencyKey,
          );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Receive failed — please try again.';
      });
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop(created);
  }

  @override
  Widget build(BuildContext context) {
    final medicines =
        ref.watch(medicinesProvider).asData?.value ?? const <Medicine>[];
    final medicineValue = medicines.any((m) => m.id == _medicineId)
        ? _medicineId
        : null;
    return AlertDialog(
      title: const Text('Receive stock'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.preselectedMedicine != null)
              Text(
                '${widget.preselectedMedicine!.name} ${widget.preselectedMedicine!.strength}',
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
              )
            else
              DropdownButton<String>(
                key: const ValueKey('receive-medicine-dropdown'),
                value: medicineValue,
                isExpanded: true,
                hint: const Text('Select a medicine'),
                items: [
                  for (final medicine in medicines)
                    DropdownMenuItem<String>(
                      value: medicine.id,
                      child: Text(
                        '${medicine.name} ${medicine.strength}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (value) =>
                    setState(() => _medicineId = value),
              ),
            const SizedBox(height: 12),
            PharmaTextField(
              controller: _batchNoController,
              label: 'Batch number',
              hintText: 'e.g. DHA-42-1-318',
            ),
            const SizedBox(height: 12),
            _DateRow(
              label: 'Manufactured',
              date: _mfgDate,
              onTap: () => _pickDate(isMfg: true),
            ),
            const SizedBox(height: 8),
            _DateRow(
              label: 'Expires',
              date: _expiryDate,
              onTap: () => _pickDate(isMfg: false),
            ),
            const SizedBox(height: 12),
            PharmaTextField(
              controller: _qtyController,
              label: 'Quantity received',
              hintText: 'e.g. 50',
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 12),
            PharmaTextField(
              controller: _costController,
              label: 'Cost per unit (Rs)',
              hintText: 'e.g. 85',
              keyboardType: TextInputType.number,
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: StatusKind.danger.color),
              ),
            ],
          ],
        ),
      ),
      actions: [
        PharmaButton(
          label: 'Cancel',
          variant: PharmaButtonVariant.text,
          size: PharmaButtonSize.small,
          onPressed: () => Navigator.of(context).pop(),
        ),
        PharmaButton(
          label: 'Receive',
          size: PharmaButtonSize.small,
          loading: _saving,
          onPressed: _saving ? null : _save,
        ),
      ],
    );
  }
}

class _AdjustStockDialog extends ConsumerStatefulWidget {
  const _AdjustStockDialog({required this.batch, required this.medicineName});

  final InventoryItem batch;
  final String medicineName;

  @override
  ConsumerState<_AdjustStockDialog> createState() => _AdjustStockDialogState();
}

class _AdjustStockDialogState extends ConsumerState<_AdjustStockDialog> {
  late final TextEditingController _qtyController;
  late final TextEditingController _reasonController;
  bool _increase = true;
  String? _error;
  bool _saving = false;

  /// Dialog-held idempotency key (Week 3 Day 5, D115 — closes the
  /// D54 UI gap for this dialog): minted once, reused on retry.
  late final String _idempotencyKey =
      newIdempotencyKey('stock-adjust-${widget.batch.id}');

  @override
  void initState() {
    super.initState();
    _qtyController = TextEditingController();
    _reasonController = TextEditingController();
  }

  @override
  void dispose() {
    _qtyController.dispose();
    _reasonController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final qty = int.tryParse(_qtyController.text.trim());
    final reason = _reasonController.text.trim();
    String? error;
    if (qty == null || qty <= 0) {
      error = 'Quantity must be a whole number above zero.';
    } else if (reason.isEmpty) {
      error = 'A reason is required (e.g. damaged, found, expired).';
    } else if (!_increase && qty > widget.batch.quantity) {
      error =
          'Cannot remove $qty units — only ${widget.batch.quantity} on hand.';
    }
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    // qty is non-null here: every null/zero case sets error above.
    final amount = qty!;
    setState(() {
      _error = null;
      _saving = true;
    });
    final updated = await ref
        .read(inventoryProvider.notifier)
        .adjustStock(
          batchId: widget.batch.id,
          deltaQty: _increase ? amount : -amount,
          reason: reason,
          idempotencyKey: _idempotencyKey,
        );
    if (!mounted) return;
    if (updated == null) {
      setState(() {
        _saving = false;
        _error = 'Adjustment failed — please try again.';
      });
      return;
    }
    Navigator.of(context).pop(updated);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Adjust stock'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${widget.medicineName} • Batch ${widget.batch.batchNo ?? '—'}',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            Text(
              'On hand: ${widget.batch.quantity} units',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                  value: true,
                  label: Text('Increase'),
                  icon: Icon(Icons.add_circle_outline),
                ),
                ButtonSegment(
                  value: false,
                  label: Text('Decrease'),
                  icon: Icon(Icons.remove_circle_outline),
                ),
              ],
              selected: {_increase},
              onSelectionChanged: (selection) =>
                  setState(() => _increase = selection.first),
            ),
            const SizedBox(height: 12),
            PharmaTextField(
              controller: _qtyController,
              label: 'Quantity',
              hintText: 'e.g. 5',
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 12),
            PharmaTextField(
              controller: _reasonController,
              label: 'Reason (required)',
              hintText: 'e.g. damaged in transit',
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: StatusKind.danger.color),
              ),
            ],
          ],
        ),
      ),
      actions: [
        PharmaButton(
          label: 'Cancel',
          variant: PharmaButtonVariant.text,
          size: PharmaButtonSize.small,
          onPressed: () => Navigator.of(context).pop(),
        ),
        PharmaButton(
          label: 'Save adjustment',
          size: PharmaButtonSize.small,
          loading: _saving,
          onPressed: _saving ? null : _save,
        ),
      ],
    );
  }
}

class _StockCountDialog extends ConsumerStatefulWidget {
  const _StockCountDialog({
    required this.batch,
    required this.medicineName,
  });

  final InventoryItem batch;
  final String medicineName;

  @override
  ConsumerState<_StockCountDialog> createState() => _StockCountDialogState();
}

class _StockCountDialogState extends ConsumerState<_StockCountDialog> {
  late final TextEditingController _countedController;
  late final TextEditingController _noteController;
  String? _error;
  bool _saving = false;

  /// Dialog-held idempotency key (Week 3 Day 5, D115 — closes the
  /// D54 UI gap for this dialog): minted once, reused on retry.
  late final String _idempotencyKey =
      newIdempotencyKey('stock-count-${widget.batch.id}');

  @override
  void initState() {
    super.initState();
    _countedController = TextEditingController();
    _noteController = TextEditingController();
  }

  @override
  void dispose() {
    _countedController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  int? get _counted => int.tryParse(_countedController.text.trim());

  Future<void> _save() async {
    final counted = _counted;
    if (counted == null || counted < 0) {
      setState(
        () => _error = 'Counted quantity must be a whole number (0 or more).',
      );
      return;
    }
    setState(() {
      _error = null;
      _saving = true;
    });
    final result = await ref
        .read(inventoryProvider.notifier)
        .recordStockCount(
          batchId: widget.batch.id,
          countedQty: counted,
          note: _noteController.text.trim().isEmpty
              ? null
              : _noteController.text.trim(),
          idempotencyKey: _idempotencyKey,
        );
    if (!mounted) return;
    if (result == null) {
      setState(() {
        _saving = false;
        _error = 'Count could not be saved — please try again.';
      });
      return;
    }
    Navigator.of(context).pop(result);
  }

  @override
  Widget build(BuildContext context) {
    final counted = _counted;
    final variance = counted == null
        ? null
        : counted - widget.batch.quantity;
    return AlertDialog(
      title: const Text('Stock count'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${widget.medicineName} • Batch ${widget.batch.batchNo ?? '—'}',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            Text(
              'System quantity: ${widget.batch.quantity} units',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            PharmaTextField(
              controller: _countedController,
              label: 'Counted quantity',
              hintText: 'What you counted on the shelf',
              keyboardType: TextInputType.number,
              onChanged: (_) => setState(() {}),
            ),
            if (variance != null) ...[
              const SizedBox(height: 8),
              Text(
                variance == 0
                    ? 'Variance: 0 — matches the system.'
                    : 'Variance: ${variance > 0 ? '+' : ''}$variance units',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: variance == 0
                      ? StatusKind.success.color
                      : StatusKind.warning.color,
                ),
              ),
            ],
            const SizedBox(height: 12),
            PharmaTextField(
              controller: _noteController,
              label: 'Note (optional)',
              hintText: 'e.g. shelf recount after delivery',
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: StatusKind.danger.color),
              ),
            ],
          ],
        ),
      ),
      actions: [
        PharmaButton(
          label: 'Cancel',
          variant: PharmaButtonVariant.text,
          size: PharmaButtonSize.small,
          onPressed: () => Navigator.of(context).pop(),
        ),
        PharmaButton(
          label: 'Save count',
          size: PharmaButtonSize.small,
          loading: _saving,
          onPressed: _saving ? null : _save,
        ),
      ],
    );
  }
}

/// One date row inside the receive dialog: label + tappable date chip
/// that opens the system date picker.
class _DateRow extends StatelessWidget {
  const _DateRow({
    required this.label,
    required this.date,
    required this.onTap,
  });

  final String label;
  final DateTime date;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(width: 110, child: Text(label)),
        Expanded(
          child: InkWell(
            key: ValueKey('date-$label'),
            onTap: onTap,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
              decoration: BoxDecoration(
                border: Border.all(
                  color: Theme.of(context).dividerColor,
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Expanded(child: Text(formatShortDate(date))),
                  const Icon(Icons.calendar_today_outlined, size: 18),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
