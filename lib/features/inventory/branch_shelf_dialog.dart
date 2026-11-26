import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/widgets/design_system.dart';
import '../../models/branch_inventory_location.dart';
import '../../models/medicine.dart';
import 'inventory_provider.dart';

/// Per-branch rack / shelf dialog (Week 5 Day 3, D152 — SRS §3.3).
///
/// Sets the override for one medicine at one branch: where THIS
/// branch keeps it, when that differs from the master default shelf.
/// Both fields empty clears the override — the branch falls back to
/// the master location.
///
/// Saves through [InventoryNotifier.saveBranchLocation] (which
/// refreshes the locations provider, so the detail and inventory
/// screens show the new shelf at once). Returns the saved override,
/// or `null` on cancel.
Future<BranchInventoryLocation?> showEditBranchShelfDialog(
  BuildContext context,
  WidgetRef ref, {
  required String branchId,
  required String branchName,
  required Medicine medicine,
  required BranchInventoryLocation? currentOverride,
}) {
  return showDialog<BranchInventoryLocation>(
    context: context,
    builder: (dialogContext) => _EditBranchShelfDialog(
      branchId: branchId,
      branchName: branchName,
      medicine: medicine,
      currentOverride: currentOverride,
    ),
  );
}

class _EditBranchShelfDialog extends ConsumerStatefulWidget {
  const _EditBranchShelfDialog({
    required this.branchId,
    required this.branchName,
    required this.medicine,
    required this.currentOverride,
  });

  final String branchId;
  final String branchName;
  final Medicine medicine;
  final BranchInventoryLocation? currentOverride;

  @override
  ConsumerState<_EditBranchShelfDialog> createState() =>
      _EditBranchShelfDialogState();
}

class _EditBranchShelfDialogState
    extends ConsumerState<_EditBranchShelfDialog> {
  late final TextEditingController _rackController;
  late final TextEditingController _shelfController;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _rackController = TextEditingController(
      text: widget.currentOverride?.rack ?? '',
    );
    _shelfController = TextEditingController(
      text: widget.currentOverride?.shelf ?? '',
    );
  }

  @override
  void dispose() {
    _rackController.dispose();
    _shelfController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final rack = _rackController.text.trim();
    final shelf = _shelfController.text.trim();
    setState(() {
      _error = null;
      _saving = true;
    });
    try {
      final saved = await ref
          .read(inventoryProvider.notifier)
          .saveBranchLocation(
            BranchInventoryLocation(
              branchId: widget.branchId,
              medicineId: widget.medicine.id,
              rack: rack.isEmpty ? null : rack,
              shelf: shelf.isEmpty ? null : shelf,
            ),
          );
      if (!mounted) return;
      Navigator.of(context).pop(saved);
    } on ArgumentError catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = error.message?.toString() ?? 'Could not save the shelf.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final defaultLocation = widget.medicine.location;
    return AlertDialog(
      title: const Text('Branch shelf'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${widget.medicine.name} ${widget.medicine.strength} • ${widget.branchName}',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              defaultLocation == null
                  ? 'No default shelf is set for this medicine. Leave both empty to clear this branch’s shelf.'
                  : 'Default shelf: $defaultLocation. Leave both empty to go back to the default.',
            ),
            const SizedBox(height: 12),
            PharmaTextField(
              key: const ValueKey('branch-rack-field'),
              controller: _rackController,
              label: 'Rack',
              hintText: 'e.g. Rack B',
            ),
            const SizedBox(height: 12),
            PharmaTextField(
              key: const ValueKey('branch-shelf-field'),
              controller: _shelfController,
              label: 'Shelf',
              hintText: 'e.g. Shelf 1',
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
          key: const ValueKey('branch-shelf-save'),
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Saving…' : 'Save shelf'),
        ),
      ],
    );
  }
}
