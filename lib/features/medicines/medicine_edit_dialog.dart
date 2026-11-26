import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/repositories.dart';
import '../../core/widgets/design_system.dart';
import '../../models/medicine.dart';
import '../inventory/inventory_provider.dart';

/// Medicine location edit (Week 4 Day 5, D138 — SRS D-10 /
/// FR-INV-10).
///
/// The detail screen has no master edit form yet — this dialog edits
/// the one master field the Day 5 scope adds: the storage location
/// (shelf / bin). A full master edit (name, prices, barcode, …) is a
/// follow-up, not smuggled in here. An empty location clears the
/// field ("Not set" on the detail screen).
///
/// Saves through [MedicineRepository.updateMedicine] and refreshes
/// the catalogue provider, so the detail screen shows the new
/// location without a restart. Returns the saved medicine, or `null`
/// on cancel.
Future<Medicine?> showEditMedicineLocationDialog(
  BuildContext context,
  WidgetRef ref, {
  required Medicine medicine,
}) {
  return showDialog<Medicine>(
    context: context,
    builder: (dialogContext) => _EditLocationDialog(medicine: medicine),
  );
}

class _EditLocationDialog extends ConsumerStatefulWidget {
  const _EditLocationDialog({required this.medicine});

  final Medicine medicine;

  @override
  ConsumerState<_EditLocationDialog> createState() =>
      _EditLocationDialogState();
}

class _EditLocationDialogState extends ConsumerState<_EditLocationDialog> {
  late final TextEditingController _locationController;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _locationController = TextEditingController(
      text: widget.medicine.location ?? '',
    );
  }

  @override
  void dispose() {
    _locationController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final location = _locationController.text.trim();
    setState(() {
      _error = null;
      _saving = true;
    });
    try {
      final saved = await ref
          .read(medicineRepositoryProvider)
          .updateMedicine(
            widget.medicine.copyWith(
              location: location.isEmpty ? null : location,
              clearLocation: location.isEmpty,
              updatedAt: DateTime.now(),
            ),
          );
      ref.invalidate(medicinesProvider);
      if (!mounted) return;
      Navigator.of(context).pop(saved);
    } on ArgumentError catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = error.message?.toString() ?? 'Could not save the location.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit location'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${widget.medicine.name} ${widget.medicine.strength}',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            const Text(
              'Where is this medicine kept? Leave empty to clear it.',
            ),
            const SizedBox(height: 12),
            PharmaTextField(
              key: const ValueKey('medicine-location-field'),
              controller: _locationController,
              label: 'Location (shelf / bin)',
              hintText: 'e.g. Rack A • Shelf 2',
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
          key: const ValueKey('medicine-location-save'),
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Saving…' : 'Save location'),
        ),
      ],
    );
  }
}
