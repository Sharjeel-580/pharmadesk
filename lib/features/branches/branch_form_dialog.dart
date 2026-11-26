import 'package:flutter/material.dart';

import '../../core/widgets/design_system.dart';
import '../../models/branch.dart';
import 'branch_directory.dart';

/// Add / edit branch form (Week 4 Day 4 — SRS D-28, FR-HO-01/02).
///
/// One dialog for both flows: [existing] is `null` when adding.
/// Rates are entered as percentages and stored as basis points; an
/// empty rate field means "not configured" (D130 — never stored as
/// 0%). Validation is [validateBranchForm]; the dialog shows its
/// errors and never calls [onSaved] with an invalid branch.
class BranchFormDialog extends StatefulWidget {
  const BranchFormDialog({super.key, this.existing, required this.onSaved});

  final Branch? existing;
  final ValueChanged<Branch> onSaved;

  @override
  State<BranchFormDialog> createState() => _BranchFormDialogState();
}

class _BranchFormDialogState extends State<BranchFormDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _addressController;
  late final TextEditingController _phoneController;
  late final TextEditingController _areasController;
  late final TextEditingController _managerController;
  late final TextEditingController _feeController;
  late final TextEditingController _royaltyController;
  late String _type;
  List<String> _errors = [];

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _nameController = TextEditingController(text: existing?.name ?? '');
    _addressController = TextEditingController(
      text: existing?.address ?? '',
    );
    _phoneController = TextEditingController(text: existing?.phone ?? '');
    _areasController = TextEditingController(
      text: (existing?.deliveryAreas ?? []).join(', '),
    );
    _managerController = TextEditingController(
      text: existing?.managerId ?? '',
    );
    _feeController = TextEditingController(
      text: _percentText(existing?.franchiseFeeRateBps),
    );
    _royaltyController = TextEditingController(
      text: _percentText(existing?.royaltyRateBps),
    );
    _type = existing?.type ?? 'own';
  }

  static String _percentText(int? rateBps) {
    if (rateBps == null) return '';
    final whole = rateBps ~/ 100;
    final frac = rateBps % 100;
    return frac == 0 ? '$whole' : '$whole.${frac.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _nameController.dispose();
    _addressController.dispose();
    _phoneController.dispose();
    _areasController.dispose();
    _managerController.dispose();
    _feeController.dispose();
    _royaltyController.dispose();
    super.dispose();
  }

  int? _rateBps(TextEditingController controller) {
    final text = controller.text.trim();
    if (text.isEmpty) return null;
    final percent = double.tryParse(text);
    if (percent == null) return -1;
    return (percent * 100).round();
  }

  void _save() {
    final feeBps = _rateBps(_feeController);
    final royaltyBps = _rateBps(_royaltyController);
    final errors = <String>[];
    if (feeBps == -1) errors.add('Franchise fee rate must be a number.');
    if (royaltyBps == -1) errors.add('Royalty rate must be a number.');
    errors.addAll(
      validateBranchForm(
        name: _nameController.text,
        franchiseFeeRateBps: feeBps == -1 ? null : feeBps,
        royaltyRateBps: royaltyBps == -1 ? null : royaltyBps,
      ),
    );
    if (errors.isNotEmpty) {
      setState(() => _errors = errors);
      return;
    }
    final existing = widget.existing;
    final areas = _areasController.text
        .split(',')
        .map((area) => area.trim())
        .where((area) => area.isNotEmpty)
        .toList();
    final managerId = _managerController.text.trim();
    final branch = Branch(
      id: existing?.id ?? _slugId(_nameController.text),
      name: _nameController.text.trim(),
      address: _addressController.text.trim(),
      phone: _phoneController.text.trim(),
      deliveryAreas: areas,
      active: existing?.active ?? true,
      createdAt: existing?.createdAt,
      type: _type,
      managerId: managerId.isEmpty ? null : managerId,
      franchiseFeeRateBps: feeBps,
      royaltyRateBps: royaltyBps,
    );
    Navigator.of(context).pop();
    widget.onSaved(branch);
  }

  static String _slugId(String name) {
    final slug = name
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return 'branch-${slug.isEmpty ? 'new' : slug}';
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;
    return AlertDialog(
      title: Text(isEdit ? 'Edit branch' : 'Add branch'),
      content: SingleChildScrollView(
        child: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_errors.isNotEmpty) ...[
                PharmaErrorBox(errors: _errors),
                const SizedBox(height: 12),
              ],
              PharmaTextField(
                controller: _nameController,
                label: 'Branch name',
                hintText: 'e.g. Demo Branch — Model Town',
              ),
              const SizedBox(height: 12),
              PharmaTextField(
                controller: _addressController,
                label: 'Address',
              ),
              const SizedBox(height: 12),
              PharmaTextField(
                controller: _phoneController,
                label: 'Phone',
                keyboardType: TextInputType.phone,
              ),
              const SizedBox(height: 12),
              PharmaTextField(
                controller: _areasController,
                label: 'Delivery areas (comma-separated)',
                hintText: 'e.g. Model Town, Garden Town',
              ),
              const SizedBox(height: 12),
              PharmaTextField(
                controller: _managerController,
                label: 'Manager id (optional)',
                hintText: 'Staff id of the branch manager',
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _type,
                decoration: const InputDecoration(labelText: 'Branch type'),
                items: const [
                  DropdownMenuItem(value: 'own', child: Text('Own branch')),
                  DropdownMenuItem(
                    value: 'franchise',
                    child: Text('Franchise'),
                  ),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => _type = value);
                },
              ),
              const SizedBox(height: 12),
              const Text(
                'Franchise settings — rates are only meaningful for '
                'franchise branches (FR-HO-07 is P3: commission / '
                'royalty tracking). Leave blank when not configured; '
                'a blank rate is shown as "Not set", never as 0%.',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 8),
              PharmaTextField(
                controller: _feeController,
                label: 'Franchise fee rate (%) — optional',
                hintText: 'e.g. 5',
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
              ),
              const SizedBox(height: 12),
              PharmaTextField(
                controller: _royaltyController,
                label: 'Royalty rate (%) — optional',
                hintText: 'e.g. 2.5',
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        PharmaButton(
          label: isEdit ? 'Save changes' : 'Add branch',
          onPressed: _save,
        ),
      ],
    );
  }
}
