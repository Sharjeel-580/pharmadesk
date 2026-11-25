import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/utils/money.dart';
import '../../core/widgets/design_system.dart';
import '../../models/supplier.dart';
import 'supplier_logic.dart';
import 'suppliers_provider.dart';

/// Supplier directory (Day 7, SRS §8 + FR-PUR-05).
///
/// Route `/suppliers`.
///
/// Search by name / contact person / phone, list from the seeded
/// suppliers with their computed payable (ledger sum, never a stored
/// field), add a new supplier (validated), tap a row for the detail
/// (contact + balance + purchase history + ledger).
class SupplierListScreen extends ConsumerStatefulWidget {
  const SupplierListScreen({super.key});

  @override
  ConsumerState<SupplierListScreen> createState() =>
      _SupplierListScreenState();
}

class _SupplierListScreenState extends ConsumerState<SupplierListScreen> {
  String _query = '';

  Future<void> _showAddSupplierDialog() async {
    final created = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => const _AddSupplierDialog(),
    );
    if (created == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Supplier added.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final suppliersAsync = ref.watch(suppliersProvider);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            title: 'Suppliers',
            subtitle: 'Profiles, contacts, purchase history, balances',
            actionLabel: 'Add supplier',
            actionIcon: Icons.person_add_outlined,
            onAction: _showAddSupplierDialog,
          ),
          const SizedBox(height: 16),
          PharmaSearchField(
            hintText: 'Search by name, contact or phone…',
            onChanged: (value) => setState(() => _query = value),
          ),
          const SizedBox(height: 16),
          suppliersAsync.when(
            loading: () => const SkeletonList(count: 4),
            error: (error, _) => PharmaEmptyState(
              icon: Icons.error_outline,
              title: 'Suppliers could not load',
              message: 'The demo data failed to load. Try again.',
              actionLabel: 'Retry',
              onAction: () => ref.invalidate(suppliersProvider),
            ),
            data: (suppliers) {
              final matching = searchSuppliers(
                suppliers,
                query: _query,
              );
              if (matching.isEmpty) {
                return PharmaEmptyState(
                  icon: Icons.local_shipping_outlined,
                  title: _query.isEmpty
                      ? 'No suppliers yet'
                      : 'No suppliers match "$_query"',
                  message: _query.isEmpty
                      ? 'Add your first supplier to start ordering stock.'
                      : 'Try a different name or phone number.',
                  actionLabel: 'Add supplier',
                  onAction: _showAddSupplierDialog,
                );
              }
              return PharmaCard(
                child: Column(
                  children: [
                    for (var i = 0; i < matching.length; i++) ...[
                      if (i > 0) const Divider(height: 1),
                      _SupplierRow(supplier: matching[i]),
                    ],
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _SupplierRow extends ConsumerWidget {
  const _SupplierRow({required this.supplier});

  final Supplier supplier;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final outstanding = ref.watch(supplierOutstandingProvider(supplier.id));
    final theme = Theme.of(context);
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.12),
        child: Text(
          supplier.name.isEmpty ? '?' : supplier.name[0].toUpperCase(),
          style: TextStyle(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      title: Text(supplier.name),
      subtitle: Text(
        '${supplier.contactPerson} • ${supplier.phone}',
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            formatPkr(outstanding),
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: outstanding > 0
                  ? theme.colorScheme.error
                  : theme.colorScheme.primary,
            ),
          ),
          Text(
            outstanding > 0 ? 'Payable' : 'Settled',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
      onTap: () => context.go('/suppliers/${supplier.id}'),
    );
  }
}

class _AddSupplierDialog extends ConsumerStatefulWidget {
  const _AddSupplierDialog();

  @override
  ConsumerState<_AddSupplierDialog> createState() =>
      _AddSupplierDialogState();
}

class _AddSupplierDialogState extends ConsumerState<_AddSupplierDialog> {
  final _name = TextEditingController();
  final _contact = TextEditingController();
  final _phone = TextEditingController();
  final _email = TextEditingController();
  final _address = TextEditingController();
  final _paymentTerms = TextEditingController();
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _contact.dispose();
    _phone.dispose();
    _email.dispose();
    _address.dispose();
    _paymentTerms.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final result = await ref
        .read(suppliersProvider.notifier)
        .addSupplier(
          name: _name.text,
          contactPerson: _contact.text,
          phone: _phone.text,
          email: _email.text,
          address: _address.text,
          paymentTerms: _paymentTerms.text,
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
    return AlertDialog(
      title: const Text('Add supplier'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_error != null) ...[
              PharmaErrorBox(errors: [_error!]),
              const SizedBox(height: 12),
            ],
            PharmaTextField(
              controller: _name,
              label: 'Supplier name',
              hintText: 'e.g. Sami Pharmaceuticals',
              autofocus: true,
            ),
            const SizedBox(height: 12),
            PharmaTextField(
              controller: _contact,
              label: 'Contact person',
              hintText: 'e.g. Sami Ullah',
            ),
            const SizedBox(height: 12),
            PharmaTextField(
              controller: _phone,
              label: 'Phone',
              hintText: 'e.g. 0300-1234567',
              keyboardType: TextInputType.phone,
            ),
            const SizedBox(height: 12),
            PharmaTextField(
              controller: _email,
              label: 'Email (optional)',
              keyboardType: TextInputType.emailAddress,
            ),
            const SizedBox(height: 12),
            PharmaTextField(
              controller: _address,
              label: 'Address (optional)',
              maxLines: 2,
            ),
            const SizedBox(height: 12),
            PharmaTextField(
              controller: _paymentTerms,
              label: 'Payment terms (optional)',
              hintText: 'e.g. Net 30 days',
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
          label: 'Add supplier',
          size: PharmaButtonSize.small,
          loading: _saving,
          onPressed: _save,
        ),
      ],
    );
  }
}
