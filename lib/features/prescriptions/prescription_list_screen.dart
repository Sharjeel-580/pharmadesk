import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/services/branch_context.dart';
import '../../core/widgets/design_system.dart';
import '../../models/customer.dart';
import '../../models/prescription.dart';
import '../customers/customers_provider.dart';
import 'prescriptions_logic.dart';
import 'prescriptions_provider.dart';

/// Prescription review queue (Day 7, SRS FR-ORD-04, D-08/M-08).
///
/// Route `/prescriptions`.
///
/// Branch-scoped list of the 20 seeded prescriptions with status
/// filter chips + search, tap a row for the detail (sample photo +
/// review actions). The "New prescription" form creates a Pending
/// record (patient + medicines text + notes).
class PrescriptionListScreen extends ConsumerStatefulWidget {
  const PrescriptionListScreen({super.key});

  @override
  ConsumerState<PrescriptionListScreen> createState() =>
      _PrescriptionListScreenState();
}

class _PrescriptionListScreenState
    extends ConsumerState<PrescriptionListScreen> {
  String _query = '';
  PrescriptionStatus? _statusFilter;

  Future<void> _showNewPrescriptionDialog() async {
    final created = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => const _NewPrescriptionDialog(),
    );
    if (created == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Prescription created — pending pharmacist review.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final prescriptionsAsync = ref.watch(prescriptionsProvider);
    final branchPrescriptions = ref.watch(branchPrescriptionsProvider);
    final customers =
        ref.watch(customersProvider).asData?.value ?? const <Customer>[];
    final customersById = {for (final c in customers) c.id: c};
    final counts = prescriptionStatusCounts(branchPrescriptions);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            title: 'Prescriptions',
            subtitle:
                'Pharmacist review — orders cannot dispatch until the '
                'linked prescription is approved',
            actionLabel: 'New prescription',
            actionIcon: Icons.add_outlined,
            onAction: _showNewPrescriptionDialog,
          ),
          const SizedBox(height: 16),
          PharmaSearchField(
            hintText: 'Search by prescription, patient or medicine…',
            onChanged: (value) => setState(() => _query = value),
          ),
          const SizedBox(height: 12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _FilterChip(
                  label: 'All (${branchPrescriptions.length})',
                  selected: _statusFilter == null,
                  onSelected: () => setState(() => _statusFilter = null),
                ),
                for (final status in PrescriptionStatus.values)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: _FilterChip(
                      label:
                          '${prescriptionStatusLabel(status)} (${counts[status] ?? 0})',
                      selected: _statusFilter == status,
                      onSelected: () =>
                          setState(() => _statusFilter = status),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          prescriptionsAsync.when(
            loading: () => const SkeletonList(count: 4),
            error: (error, _) => PharmaEmptyState(
              icon: Icons.error_outline,
              title: 'Prescriptions could not load',
              message: 'The demo data failed to load. Try again.',
              actionLabel: 'Retry',
              onAction: () => ref.invalidate(prescriptionsProvider),
            ),
            data: (_) {
              final matching = filterPrescriptions(
                prescriptions: branchPrescriptions,
                statusFilter: _statusFilter,
                query: _query,
                customersById: customersById,
              );
              if (matching.isEmpty) {
                return PharmaEmptyState(
                  icon: Icons.description_outlined,
                  title: _query.isEmpty && _statusFilter == null
                      ? 'No prescriptions yet'
                      : 'No prescriptions match',
                  message: _query.isEmpty && _statusFilter == null
                      ? 'New prescriptions appear here for pharmacist review.'
                      : 'Try a different search or filter.',
                  actionLabel: 'New prescription',
                  onAction: _showNewPrescriptionDialog,
                );
              }
              return PharmaCard(
                child: Column(
                  children: [
                    for (var i = 0; i < matching.length; i++) ...[
                      if (i > 0) const Divider(height: 1),
                      _PrescriptionRow(
                        prescription: matching[i],
                        customer: customersById[matching[i].customerId],
                      ),
                    ],
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 12),
          Text(
            'Photos in this demo are bundled SAMPLE images, clearly '
            'marked — never real patient photos and never network URLs '
            '(no Cloud Storage on the free tier).',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onSelected(),
    );
  }
}

class _PrescriptionRow extends StatelessWidget {
  const _PrescriptionRow({required this.prescription, this.customer});

  final Prescription prescription;
  final Customer? customer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.asset(
          prescription.imageUrl,
          width: 48,
          height: 64,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) => Container(
            width: 48,
            height: 64,
            color: theme.colorScheme.primary.withValues(alpha: 0.1),
            child: const Icon(Icons.description_outlined),
          ),
        ),
      ),
      title: Text(prescription.id),
      subtitle: Text(
        '${customer?.name ?? prescription.customerId}'
        '${prescription.medicinesText != null ? ' • ${prescription.medicinesText}' : ''}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: StatusBadge(
        label: prescriptionStatusLabel(prescription.status),
        kind: prescriptionStatusKind(prescription.status),
      ),
      onTap: () => context.go('/prescriptions/${prescription.id}'),
    );
  }
}

class _NewPrescriptionDialog extends ConsumerStatefulWidget {
  const _NewPrescriptionDialog();

  @override
  ConsumerState<_NewPrescriptionDialog> createState() =>
      _NewPrescriptionDialogState();
}

class _NewPrescriptionDialogState
    extends ConsumerState<_NewPrescriptionDialog> {
  String? _customerId;
  final _medicines = TextEditingController();
  final _notes = TextEditingController();
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _medicines.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final errors = validateNewPrescription(
      customerId: _customerId,
      medicinesText: _medicines.text,
    );
    if (errors.isNotEmpty) {
      setState(() => _error = errors.first);
      return;
    }
    setState(() {
      _error = null;
      _saving = true;
    });
    final branchId = ref.read(activeBranchProvider).id;
    final result = await ref
        .read(prescriptionsProvider.notifier)
        .create(
          customerId: _customerId!,
          medicinesText: _medicines.text,
          notes: _notes.text,
          branchId: branchId,
        );
    if (!mounted) return;
    setState(() => _saving = false);
    if (result.error != null) {
      setState(() => _error = result.error);
      return;
    }
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final customersAsync = ref.watch(customersProvider);
    return AlertDialog(
      title: const Text('New prescription'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error != null) ...[
              PharmaErrorBox(errors: [_error!]),
              const SizedBox(height: 12),
            ],
            customersAsync.when(
              loading: () => const SkeletonList(count: 1),
              error: (error, _) =>
                  const Text('Customers could not load.'),
              data: (customers) {
                return DropdownButtonFormField<String?>(
                  initialValue: _customerId,
                  hint: const Text('Select the patient'),
                  items: [
                    for (final customer in customers)
                      DropdownMenuItem<String?>(
                        value: customer.id,
                        child: Text(
                          '${customer.name} — ${customer.phone}',
                        ),
                      ),
                  ],
                  onChanged: (selected) =>
                      setState(() => _customerId = selected),
                );
              },
            ),
            const SizedBox(height: 12),
            PharmaTextField(
              controller: _medicines,
              label: 'Medicines written on the prescription',
              hintText: 'e.g. Augmentin 625mg — 1 tablet twice daily (5 days)',
              maxLines: 3,
            ),
            const SizedBox(height: 12),
            PharmaTextField(
              controller: _notes,
              label: 'Notes (optional)',
              maxLines: 2,
            ),
            const SizedBox(height: 12),
            const Text(
              'Photo: this demo attaches the bundled SAMPLE image. In '
              'production the photo is captured on-device and stored '
              'privately on the device — never uploaded to a public URL.',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
      actions: [
        PharmaButton(
          label: 'Cancel',
          variant: PharmaButtonVariant.text,
          size: PharmaButtonSize.small,
          onPressed: () => Navigator.of(context).pop(false),
        ),
        PharmaButton(
          label: 'Create',
          size: PharmaButtonSize.small,
          loading: _saving,
          onPressed: _save,
        ),
      ],
    );
  }
}
