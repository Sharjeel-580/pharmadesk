import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/repositories.dart';
import '../../core/utils/money.dart';
import '../../core/widgets/design_system.dart';
import '../../models/medicine.dart';
import '../inventory/inventory_provider.dart';
import 'medicine_logic.dart';
import 'medicine_validation.dart';

/// Full medicine master edit form (Week 5 Day 3, D153 — closes the
/// D138 follow-up).
///
/// Week 4 Day 5 shipped a location-only dialog; this replaces it:
/// name, sale price, purchase price, MRP, barcode, category and the
/// location, all in one form. Prices are entered in rupees and
/// converted to int paisa at the boundary (D6 — never floats);
/// validation is [validateMedicineEdit] (D151), the rules the
/// Firestore schema and the seed data already imply.
///
/// Saves through [MedicineRepository.updateMedicine] — the whole
/// medicine is replaced, so fields the form does not touch (brand,
/// strength, pack size, Rx flag, …) are carried from the existing
/// record, never reset. Refreshes the catalogue provider, so the
/// detail screen shows the new values without a restart. Returns the
/// saved medicine, or `null` on cancel.
Future<Medicine?> showEditMedicineDialog(
  BuildContext context,
  WidgetRef ref, {
  required Medicine medicine,
}) {
  return showDialog<Medicine>(
    context: context,
    builder: (dialogContext) => _EditMedicineDialog(medicine: medicine),
  );
}

class _EditMedicineDialog extends ConsumerStatefulWidget {
  const _EditMedicineDialog({required this.medicine});

  final Medicine medicine;

  @override
  ConsumerState<_EditMedicineDialog> createState() =>
      _EditMedicineDialogState();
}

class _EditMedicineDialogState extends ConsumerState<_EditMedicineDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _salePriceController;
  late final TextEditingController _purchasePriceController;
  late final TextEditingController _mrpController;
  late final TextEditingController _barcodeController;
  late final TextEditingController _locationController;
  late String _categoryId;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final medicine = widget.medicine;
    _nameController = TextEditingController(text: medicine.name);
    _salePriceController = TextEditingController(
      text: formatMinorUnitsAsRupees(medicine.priceMinor),
    );
    _purchasePriceController = TextEditingController(
      text: formatMinorUnitsAsRupees(medicine.purchasePriceMinor),
    );
    _mrpController = TextEditingController(
      text: medicine.mrp == null
          ? ''
          : formatMinorUnitsAsRupees(rupeesToMinorUnits(medicine.mrp!)),
    );
    _barcodeController = TextEditingController(text: medicine.barcode ?? '');
    _locationController = TextEditingController(
      text: medicine.location ?? '',
    );
    _categoryId = medicine.categoryId;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _salePriceController.dispose();
    _purchasePriceController.dispose();
    _mrpController.dispose();
    _barcodeController.dispose();
    _locationController.dispose();
    super.dispose();
  }

  Map<String, String> _errors() => validateMedicineEdit(
    name: _nameController.text,
    salePrice: _salePriceController.text,
    purchasePrice: _purchasePriceController.text,
    mrp: _mrpController.text,
    barcode: _barcodeController.text,
    categoryId: _categoryId,
  );

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _error = null;
      _saving = true;
    });
    try {
      final saleMinor = parseRupeesToMinor(_salePriceController.text)!;
      final purchaseMinor = parseRupeesToMinor(
        _purchasePriceController.text,
      )!;
      final mrpText = _mrpController.text.trim();
      final mrpMinor = mrpText.isEmpty
          ? null
          : parseRupeesToMinor(mrpText)!;
      final barcodeText = _barcodeController.text.trim();
      final locationText = _locationController.text.trim();
      final saved = await ref
          .read(medicineRepositoryProvider)
          .updateMedicine(
            widget.medicine.copyWith(
              name: _nameController.text.trim(),
              price: minorUnitsToRupees(saleMinor),
              purchasePriceMinor: purchaseMinor,
              mrp: mrpMinor == null
                  ? null
                  : minorUnitsToRupees(mrpMinor),
              clearMrp: mrpMinor == null,
              barcode: barcodeText.isEmpty ? null : barcodeText,
              clearBarcode: barcodeText.isEmpty,
              categoryId: _categoryId,
              location: locationText.isEmpty ? null : locationText,
              clearLocation: locationText.isEmpty,
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
        _error = error.message?.toString() ?? 'Could not save the medicine.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit medicine'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
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
                'Prices are in rupees. Leave MRP empty when there is none; leave the location empty to clear it.',
              ),
              const SizedBox(height: 12),
              PharmaTextField(
                key: const ValueKey('medicine-name-field'),
                controller: _nameController,
                label: 'Name',
                hintText: 'e.g. Panadol Extra',
                validator: (_) => _errors()['name'],
              ),
              const SizedBox(height: 12),
              PharmaTextField(
                key: const ValueKey('medicine-sale-price-field'),
                controller: _salePriceController,
                label: 'Sale price (Rs)',
                hintText: 'e.g. 120.50',
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                validator: (_) => _errors()['salePrice'],
              ),
              const SizedBox(height: 12),
              PharmaTextField(
                key: const ValueKey('medicine-purchase-price-field'),
                controller: _purchasePriceController,
                label: 'Purchase price (Rs)',
                hintText: 'e.g. 90.50',
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                validator: (_) => _errors()['purchasePrice'],
              ),
              const SizedBox(height: 12),
              PharmaTextField(
                key: const ValueKey('medicine-mrp-field'),
                controller: _mrpController,
                label: 'MRP (Rs, optional)',
                hintText: 'e.g. 130',
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                validator: (_) => _errors()['mrp'],
              ),
              const SizedBox(height: 12),
              PharmaTextField(
                key: const ValueKey('medicine-barcode-field'),
                controller: _barcodeController,
                label: 'Barcode (optional)',
                hintText: '8–14 digits',
                keyboardType: TextInputType.number,
                validator: (_) => _errors()['barcode'],
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: const ValueKey('medicine-category-field'),
                initialValue: medicineCategoryLabels.containsKey(_categoryId)
                    ? _categoryId
                    : null,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Category'),
                items: [
                  for (final entry in medicineCategoryLabels.entries)
                    DropdownMenuItem<String>(
                      value: entry.key,
                      child: Text(entry.value),
                    ),
                ],
                validator: (_) => _errors()['categoryId'],
                onChanged: (value) {
                  if (value == null) return;
                  setState(() => _categoryId = value);
                },
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
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('medicine-edit-save'),
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Saving…' : 'Save medicine'),
        ),
      ],
    );
  }
}
