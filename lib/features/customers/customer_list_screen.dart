import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/utils/money.dart';
import '../../core/widgets/design_system.dart';
import '../../models/customer.dart';
import 'customer_logic.dart';
import 'customers_provider.dart';

/// Customer directory (Day 6, SRS §8 + FR-POS-09).
///
/// Route `/customers`.
///
/// Search by name or phone, list from the seeded customers with their
/// khata outstanding, add a new customer (validated), tap a row for
/// the detail (purchase history + credit ledger).
class CustomerListScreen extends ConsumerStatefulWidget {
  const CustomerListScreen({super.key});

  @override
  ConsumerState<CustomerListScreen> createState() =>
      _CustomerListScreenState();
}

class _CustomerListScreenState extends ConsumerState<CustomerListScreen> {
  String _query = '';

  Future<void> _showAddCustomerDialog() async {
    final created = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => const _AddCustomerDialog(),
    );
    if (created == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Customer added.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final customersAsync = ref.watch(customersProvider);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            title: 'Customers',
            subtitle: 'Directory, purchase history and khata',
            actionLabel: 'Add customer',
            actionIcon: Icons.person_add_outlined,
            onAction: _showAddCustomerDialog,
          ),
          const SizedBox(height: 16),
          PharmaSearchField(
            hintText: 'Search by name or phone…',
            onChanged: (value) => setState(() => _query = value),
          ),
          const SizedBox(height: 16),
          customersAsync.when(
            loading: () => const SkeletonList(count: 4),
            error: (error, _) => PharmaEmptyState(
              icon: Icons.error_outline,
              title: 'Customers could not load',
              message: 'The demo data failed to load. Try again.',
              actionLabel: 'Retry',
              onAction: () => ref.invalidate(customersProvider),
            ),
            data: (customers) {
              final matching = searchCustomers(
                customers,
                query: _query,
              );
              if (matching.isEmpty) {
                return PharmaEmptyState(
                  icon: Icons.people_outline,
                  title: _query.isEmpty
                      ? 'No customers yet'
                      : 'No customers match "$_query"',
                  message: _query.isEmpty
                      ? 'Add your first customer to start a khata.'
                      : 'Try a different name or phone number.',
                  actionLabel: 'Add customer',
                  onAction: _showAddCustomerDialog,
                );
              }
              return PharmaCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '${matching.length} customer(s)',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 8),
                    for (var i = 0; i < matching.length; i++) ...[
                      _CustomerRow(customer: matching[i]),
                      if (i < matching.length - 1)
                        Divider(
                          height: 1,
                          color: Theme.of(
                            context,
                          ).dividerColor.withValues(alpha: 0.4),
                        ),
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

class _CustomerRow extends ConsumerWidget {
  const _CustomerRow({required this.customer});

  final Customer customer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final outstanding = ref.watch(outstandingProvider(customer.id));
    final address = customer.addresses.firstOrNull;
    return InkWell(
      onTap: () => context.go('/customers/${customer.id}'),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: theme.colorScheme.primary.withValues(
                alpha: 0.12,
              ),
              child: Text(
                customer.name.isEmpty
                    ? '?'
                    : customer.name[0].toUpperCase(),
                style: TextStyle(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    customer.name,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    '${customer.phone}'
                    '${address == null ? '' : ' • ${address.address}, ${address.city}'}',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  formatPkr(outstanding),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: outstanding > 0
                        ? StatusKind.danger.color
                        : null,
                  ),
                ),
                Text(
                  outstanding > 0 ? 'owes (khata)' : 'settled',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
            const SizedBox(width: 8),
            const Icon(Icons.chevron_right),
          ],
        ),
      ),
    );
  }
}

/// Add-customer dialog: its own stateful widget so validation errors
/// and the saving state live in the dialog itself. Pops `true` when a
/// customer was added, `false`/`null` otherwise.
class _AddCustomerDialog extends ConsumerStatefulWidget {
  const _AddCustomerDialog();

  @override
  ConsumerState<_AddCustomerDialog> createState() =>
      _AddCustomerDialogState();
}

class _AddCustomerDialogState extends ConsumerState<_AddCustomerDialog> {
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _addressController = TextEditingController();
  final _cityController = TextEditingController(text: 'Lahore');
  List<String> _errors = [];
  bool _saving = false;

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _addressController.dispose();
    _cityController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final customers = ref.read(customersProvider).asData?.value ?? [];
    final validation = validateNewCustomer(
      name: _nameController.text,
      phone: _phoneController.text,
      existingPhones: customers.map((c) => c.phone).toList(),
    );
    if (validation.isNotEmpty) {
      setState(() => _errors = validation);
      return;
    }
    setState(() {
      _errors = [];
      _saving = true;
    });
    final result = await ref.read(customersProvider.notifier).addCustomer(
      name: _nameController.text,
      phone: _phoneController.text,
      address: _addressController.text,
      city: _cityController.text,
    );
    if (!mounted) return;
    if (result.customer == null) {
      setState(() {
        _errors = [result.error ?? 'Could not add customer.'];
        _saving = false;
      });
      return;
    }
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add customer'),
      content: SingleChildScrollView(
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
              label: 'Full name',
              hintText: 'e.g. Ahmed Raza',
              autofocus: true,
            ),
            const SizedBox(height: 12),
            PharmaTextField(
              controller: _phoneController,
              label: 'Phone',
              hintText: 'e.g. 0300-1234567',
              keyboardType: TextInputType.phone,
            ),
            const SizedBox(height: 12),
            PharmaTextField(
              controller: _addressController,
              label: 'Address (optional)',
              hintText: 'House, street, area',
            ),
            const SizedBox(height: 12),
            PharmaTextField(
              controller: _cityController,
              label: 'City',
              hintText: 'Lahore',
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
          label: 'Add customer',
          size: PharmaButtonSize.small,
          loading: _saving,
          onPressed: _saving ? null : _save,
        ),
      ],
    );
  }
}
