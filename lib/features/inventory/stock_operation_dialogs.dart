import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/data/sync_queue.dart';
import '../../core/utils/money.dart';
import '../../core/widgets/design_system.dart';
import '../../models/inventory_item.dart';
import '../../models/medicine.dart';
import '../../models/quarantine_outcome_request.dart';
import '../../models/stock_adjustment_request.dart';
import 'inventory_logic.dart';
import 'inventory_provider.dart';
import 'quarantine_outcome_logic.dart';
import 'quarantine_outcome_queue.dart';
import 'stock_adjustment_logic.dart';
import 'stock_adjustment_queue.dart';

/// Stock-operation dialogs (Day 5), shared by the inventory screen and
/// the medicine detail screen.
///
/// - Receive: adds a batch (medicine, batch no., mfg/expiry, qty, cost).
/// - Adjust: files an adjustment *request* with a required reason —
///   it no longer applies directly (Week 4 Day 5, D141 — the request
///   is approved on `/inventory/adjustments`).
/// - Count: records a physical count and reports the variance.
///
/// Every dialog validates before saving and returns its result so the
/// caller can confirm with a snackbar; nothing here writes to a
/// repository directly — all writes go through [InventoryNotifier]
/// (or, for adjustments, the approval queue).

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
    builder: (dialogContext) =>
        _ReceiveStockDialog(branchId: branchId, preselectedMedicine: medicine),
  );
}

/// Opens the adjust-stock dialog for one batch (Week 4 Day 5, D141
/// — SRS D-14 / FR-INV-08).
///
/// The dialog no longer applies the adjustment directly: it files a
/// [StockAdjustmentRequest] with a required reason, and an approver
/// decides it on the queue screen (`/inventory/adjustments`).
/// Returns the filed request, or `null` on cancel / invalid request.
/// The old direct-apply path stays available programmatically
/// ([InventoryNotifier.adjustStock]) for approvals and system-driven
/// restocks (returns) — it is no longer reachable from this dialog.
Future<StockAdjustmentRequest?> showAdjustStockDialog(
  BuildContext context,
  WidgetRef ref, {
  required InventoryItem batch,
  required String medicineName,
}) {
  return showDialog<StockAdjustmentRequest>(
    context: context,
    builder: (dialogContext) =>
        _AdjustStockDialog(batch: batch, medicineName: medicineName),
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
    builder: (dialogContext) =>
        _StockCountDialog(batch: batch, medicineName: medicineName),
  );
}

class _ReceiveStockDialog extends ConsumerStatefulWidget {
  const _ReceiveStockDialog({required this.branchId, this.preselectedMedicine});

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
  late final String _idempotencyKey = newIdempotencyKey(
    'stock-receive-${widget.branchId}',
  );

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
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
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
                onChanged: (value) => setState(() => _medicineId = value),
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
              Text(_error!, style: TextStyle(color: StatusKind.danger.color)),
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
    // Validation is the shared request validator (D141) — the
    // dialog only files the request; the layer re-validates at
    // approval time.
    final error = validateAdjustmentRequest(
      deltaQty: qty == null ? 0 : (_increase ? qty : -qty),
      reason: reason,
      onHandQty: widget.batch.quantity,
    );
    if (qty == null || qty <= 0) {
      setState(() => _error = 'Quantity must be a whole number above zero.');
      return;
    }
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    setState(() {
      _error = null;
      _saving = true;
    });
    final request = await ref
        .read(stockAdjustmentQueueProvider.notifier)
        .requestAdjustment(
          batchId: widget.batch.id,
          batchNo: widget.batch.batchNo ?? '—',
          medicineId: widget.batch.medicineId,
          medicineName: widget.medicineName,
          branchId: widget.batch.branchId,
          deltaQty: _increase ? qty : -qty,
          reason: reason,
          onHandQty: widget.batch.quantity,
        );
    if (!mounted) return;
    if (request == null) {
      setState(() {
        _saving = false;
        _error = 'Request failed — please try again.';
      });
      return;
    }
    Navigator.of(context).pop(request);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Request adjustment'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${widget.medicineName} • Batch ${widget.batch.batchNo ?? '—'}',
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            Text(
              'On hand: ${widget.batch.quantity} units',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            const Text(
              'This files a request — an approver reviews it on the Adjustment Approvals screen before it applies.',
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
              key: const ValueKey('adjust-qty-field'),
              controller: _qtyController,
              label: 'Quantity',
              hintText: 'e.g. 5',
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 12),
            PharmaTextField(
              key: const ValueKey('adjust-reason-field'),
              controller: _reasonController,
              label: 'Reason (required)',
              hintText: 'e.g. damaged in transit',
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: StatusKind.danger.color)),
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
          label: 'Submit request',
          size: PharmaButtonSize.small,
          loading: _saving,
          onPressed: _saving ? null : _save,
        ),
      ],
    );
  }
}

class _StockCountDialog extends ConsumerStatefulWidget {
  const _StockCountDialog({required this.batch, required this.medicineName});

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
  late final String _idempotencyKey = newIdempotencyKey(
    'stock-count-${widget.batch.id}',
  );

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
    final variance = counted == null ? null : counted - widget.batch.quantity;
    return AlertDialog(
      title: const Text('Stock count'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${widget.medicineName} • Batch ${widget.batch.batchNo ?? '—'}',
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
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
              Text(_error!, style: TextStyle(color: StatusKind.danger.color)),
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
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                border: Border.all(color: Theme.of(context).dividerColor),
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

/// Opens the quarantine / un-quarantine dialog (Week 4 Day 5, D140 —
/// SRS D-11 / FR-INV-07).
///
/// Quarantine parks a batch out of the FEFO saleable pool — it is
/// NOT a write-off (the quantity stays), and the batch can be
/// restored with the same dialog (`quarantine: false`). A reason is
/// required: it goes on the audit entry. Returns the updated batch,
/// or `null` on cancel / failed transition.
Future<InventoryItem?> showQuarantineBatchDialog(
  BuildContext context,
  WidgetRef ref, {
  required InventoryItem batch,
  required String medicineName,
  required bool quarantine,
}) {
  return showDialog<InventoryItem>(
    context: context,
    builder: (dialogContext) => _QuarantineBatchDialog(
      batch: batch,
      medicineName: medicineName,
      quarantine: quarantine,
    ),
  );
}

class _QuarantineBatchDialog extends ConsumerStatefulWidget {
  const _QuarantineBatchDialog({
    required this.batch,
    required this.medicineName,
    required this.quarantine,
  });

  final InventoryItem batch;
  final String medicineName;
  final bool quarantine;

  @override
  ConsumerState<_QuarantineBatchDialog> createState() =>
      _QuarantineBatchDialogState();
}

class _QuarantineBatchDialogState
    extends ConsumerState<_QuarantineBatchDialog> {
  late final TextEditingController _reasonController;
  String? _error;
  bool _saving = false;

  /// Dialog-held idempotency key (D115 pattern): minted once, reused
  /// on retry, so a double-tap cannot quarantine twice.
  late final String _idempotencyKey = newIdempotencyKey(
    'batch-status-${widget.batch.id}-${widget.quarantine ? 'quarantine' : 'restore'}',
  );

  @override
  void initState() {
    super.initState();
    _reasonController = TextEditingController();
  }

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final reason = _reasonController.text.trim();
    if (reason.isEmpty) {
      setState(() => _error = 'A reason is required for the audit trail.');
      return;
    }
    setState(() {
      _error = null;
      _saving = true;
    });
    final notifier = ref.read(inventoryProvider.notifier);
    final updated = widget.quarantine
        ? await notifier.quarantineBatch(
            batchId: widget.batch.id,
            reason: reason,
            idempotencyKey: _idempotencyKey,
          )
        : await notifier.unquarantineBatch(
            batchId: widget.batch.id,
            reason: reason,
            idempotencyKey: _idempotencyKey,
          );
    if (!mounted) return;
    if (updated == null) {
      setState(() {
        _saving = false;
        _error = widget.quarantine
            ? 'Could not quarantine — the batch may already be quarantined or expired.'
            : 'Could not restore — the batch is not quarantined.';
      });
      return;
    }
    Navigator.of(context).pop(updated);
  }

  @override
  Widget build(BuildContext context) {
    final quarantine = widget.quarantine;
    return AlertDialog(
      title: Text(quarantine ? 'Quarantine batch' : 'Restore batch'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${widget.medicineName} • Batch ${widget.batch.batchNo ?? '—'}',
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            Text(
              'On hand: ${widget.batch.quantity} units',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Text(
              quarantine
                  ? 'The batch leaves the saleable pool (FEFO) until it is restored. '
                        'It is not written off — the quantity stays ${widget.batch.quantity} units.'
                  : 'The batch returns to the saleable pool (FEFO) and can be sold again.',
            ),
            const SizedBox(height: 12),
            PharmaTextField(
              key: const ValueKey('quarantine-reason-field'),
              controller: _reasonController,
              label: 'Reason (required)',
              hintText: quarantine
                  ? 'e.g. suspected damage, recall notice'
                  : 'e.g. checked — safe to sell',
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.error,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('quarantine-confirm'),
          onPressed: _saving ? null : _save,
          child: Text(
            _saving
                ? 'Saving…'
                : quarantine
                ? 'Quarantine batch'
                : 'Restore batch',
          ),
        ),
      ],
    );
  }
}

/// Opens the quarantine return / disposal dialog (Week 5 Day 4,
/// D154 — SRS D-11 / FR-INV-07).
///
/// Filing a request does NOT move the batch: the batch stays
/// quarantined until an approver (other than the requester, §5.2.4)
/// approves it on the Quarantine Outcomes screen. A reason is
/// required: it goes on the audit entry when the outcome is
/// applied. Returns the filed request, or `null` on cancel / a
/// failed filing.
Future<QuarantineOutcomeRequest?> showQuarantineOutcomeDialog(
  BuildContext context,
  WidgetRef ref, {
  required InventoryItem batch,
  required String medicineName,
  required QuarantineOutcome outcome,
}) {
  return showDialog<QuarantineOutcomeRequest>(
    context: context,
    builder: (dialogContext) => _QuarantineOutcomeDialog(
      batch: batch,
      medicineName: medicineName,
      outcome: outcome,
    ),
  );
}

class _QuarantineOutcomeDialog extends ConsumerStatefulWidget {
  const _QuarantineOutcomeDialog({
    required this.batch,
    required this.medicineName,
    required this.outcome,
  });

  final InventoryItem batch;
  final String medicineName;
  final QuarantineOutcome outcome;

  @override
  ConsumerState<_QuarantineOutcomeDialog> createState() =>
      _QuarantineOutcomeDialogState();
}

class _QuarantineOutcomeDialogState
    extends ConsumerState<_QuarantineOutcomeDialog> {
  late final TextEditingController _reasonController;
  String? _error;

  @override
  void initState() {
    super.initState();
    _reasonController = TextEditingController();
  }

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  void _save() {
    final reason = _reasonController.text.trim();
    final error = validateQuarantineOutcomeRequest(reason: reason);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    final request = ref
        .read(quarantineOutcomeQueueProvider.notifier)
        .requestOutcome(
          batch: widget.batch,
          medicineName: widget.medicineName,
          outcome: widget.outcome,
          reason: reason,
        );
    if (request == null) {
      setState(() => _error = 'Could not file the request — please try again.');
      return;
    }
    Navigator.of(context).pop(request);
  }

  @override
  Widget build(BuildContext context) {
    final outcome = widget.outcome;
    final isReturn = outcome == QuarantineOutcome.returnToSupplier;
    return AlertDialog(
      title: Text(isReturn ? 'Return batch to supplier' : 'Dispose batch'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${widget.medicineName} • Batch ${widget.batch.batchNo ?? '—'}',
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            Text(
              'On hand: ${widget.batch.quantity} units (quarantined)',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Text(
              isReturn
                  ? 'The batch goes back to the supplier. On approval it leaves stock — its quantity becomes 0 — and it can never be sold again. Nothing moves until an approver (not you) approves it.'
                  : 'The batch is destroyed. On approval it stays unsellable with its quantity kept as the destroyed count. Nothing moves until an approver (not you) approves it.',
            ),
            const SizedBox(height: 12),
            PharmaTextField(
              key: const ValueKey('quarantine-outcome-reason-field'),
              controller: _reasonController,
              label: 'Reason (required)',
              hintText: isReturn
                  ? 'e.g. supplier agreed to take the damaged batch back'
                  : 'e.g. damaged beyond use, destroyed per policy',
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.error,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('quarantine-outcome-confirm'),
          onPressed: _save,
          child: Text(isReturn ? 'Request return' : 'Request disposal'),
        ),
      ],
    );
  }
}
