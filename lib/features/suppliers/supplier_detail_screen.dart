import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/utils/money.dart';
import '../../core/widgets/design_system.dart';
import '../../models/purchase_order.dart';
import '../../models/supplier.dart';
import '../../models/supplier_ledger.dart';
import '../purchases/purchases_provider.dart';
import 'supplier_logic.dart';
import 'suppliers_provider.dart';

/// Supplier detail (Day 7, SRS FR-PUR-05).
///
/// Route `/suppliers/:id`.
///
/// Contact details (editable), computed payable, purchase-order
/// history (tap opens the PO), and the append-only payables ledger
/// with Record payment / Add purchase / Adjustment actions. The
/// outstanding balance is always the ledger sum — never a stored
/// field (D37 pattern).
class SupplierDetailScreen extends ConsumerWidget {
  const SupplierDetailScreen({super.key, required this.supplierId});

  final String supplierId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final supplier = ref.watch(supplierByIdProvider(supplierId));
    if (supplier == null) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: PharmaEmptyState(
          icon: Icons.local_shipping_outlined,
          title: 'Supplier not found',
          message: 'There is no supplier with id "$supplierId" in this demo.',
          actionLabel: 'Back to Suppliers',
          onAction: () => context.go('/suppliers'),
        ),
      );
    }
    final outstanding = ref.watch(supplierOutstandingProvider(supplierId));
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            title: supplier.name,
            subtitle: 'Supplier • ${supplier.contactPerson}',
            actionLabel: 'All Suppliers',
            actionIcon: Icons.local_shipping_outlined,
            onAction: () => context.go('/suppliers'),
          ),
          const SizedBox(height: 16),
          PharmaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      radius: 26,
                      backgroundColor: theme.colorScheme.primary
                          .withValues(alpha: 0.12),
                      child: Text(
                        supplier.name.isEmpty
                            ? '?'
                            : supplier.name[0].toUpperCase(),
                        style: TextStyle(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w700,
                          fontSize: 20,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            supplier.name,
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            supplier.contactPerson,
                            style: theme.textTheme.bodyMedium,
                          ),
                        ],
                      ),
                    ),
                    StatusBadge(
                      label: outstanding > 0 ? 'Payable' : 'Settled',
                      kind: outstanding > 0
                          ? StatusKind.danger
                          : StatusKind.success,
                      icon: outstanding > 0
                          ? Icons.payments_outlined
                          : Icons.check_circle_outline,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _DetailRow(label: 'Phone', value: supplier.phone),
                if (supplier.email != null)
                  _DetailRow(label: 'Email', value: supplier.email!),
                if (supplier.address != null)
                  _DetailRow(label: 'Address', value: supplier.address!),
                if (supplier.taxNumber != null)
                  _DetailRow(label: 'Tax number', value: supplier.taxNumber!),
                if (supplier.paymentTerms != null)
                  _DetailRow(
                    label: 'Payment terms',
                    value: supplier.paymentTerms!,
                  ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: StatCard(
                        label: 'Outstanding payable',
                        value: formatPkr(outstanding),
                        icon: Icons.payments_outlined,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    PharmaButton(
                      label: 'Edit contact',
                      variant: PharmaButtonVariant.secondary,
                      size: PharmaButtonSize.small,
                      icon: Icons.edit_outlined,
                      onPressed: () =>
                          _showEditDialog(context, ref, supplier),
                    ),
                    PharmaButton(
                      label: 'Record payment',
                      size: PharmaButtonSize.small,
                      icon: Icons.payments_outlined,
                      onPressed: outstanding <= 0
                          ? null
                          : () => _showLedgerDialog(
                              context,
                              ref,
                              supplier,
                              SupplierLedgerEntryKind.payment,
                            ),
                    ),
                    PharmaButton(
                      label: 'New purchase order',
                      variant: PharmaButtonVariant.secondary,
                      size: PharmaButtonSize.small,
                      icon: Icons.shopping_cart_outlined,
                      onPressed: () => context.go(
                        '/purchases/new?supplier=${supplier.id}',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Outstanding is always computed from the ledger below — '
                  'never stored (same append-only pattern as the customer '
                  'khata).',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          const SectionHeader(title: 'Purchase history'),
          const SizedBox(height: 12),
          _PurchaseHistory(supplierId: supplier.id),
          const SizedBox(height: 24),
          SectionHeader(
            title: 'Payables ledger',
            actionLabel: 'Add purchase',
            actionIcon: Icons.add_outlined,
            onAction: () => _showLedgerDialog(
              context,
              ref,
              supplier,
              SupplierLedgerEntryKind.purchase,
            ),
          ),
          const SizedBox(height: 12),
          _LedgerList(supplierId: supplier.id),
        ],
      ),
    );
  }

  Future<void> _showEditDialog(
    BuildContext context,
    WidgetRef ref,
    Supplier supplier,
  ) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => _EditSupplierDialog(supplier: supplier),
    );
    if (saved == true && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Supplier contact updated.')),
      );
    }
  }

  Future<void> _showLedgerDialog(
    BuildContext context,
    WidgetRef ref,
    Supplier supplier,
    SupplierLedgerEntryKind kind,
  ) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => _LedgerEntryDialog(
        supplierId: supplier.id,
        kind: kind,
      ),
    );
    if (saved == true && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ledger entry recorded.')),
      );
    }
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(value, style: Theme.of(context).textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }
}

class _PurchaseHistory extends ConsumerWidget {
  const _PurchaseHistory({required this.supplierId});

  final String supplierId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final orders = ref.watch(purchaseOrdersBySupplierProvider(supplierId));
    if (orders.isEmpty) {
      return const PharmaCard(
        child: Text('No purchase orders for this supplier yet.'),
      );
    }
    return PharmaCard(
      child: Column(
        children: [
          for (var i = 0; i < orders.length; i++) ...[
            if (i > 0) const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.shopping_cart_outlined),
              title: Text(orders[i].poNumber),
              subtitle: Text(
                '${purchaseOrderStatusLabel(orders[i].status)} • '
                '${orders[i].items.length} item(s)',
              ),
              trailing: Text(
                formatPkr(orders[i].totalMinor),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              onTap: () => context.go('/purchases/${orders[i].id}'),
            ),
          ],
        ],
      ),
    );
  }
}

class _LedgerList extends ConsumerWidget {
  const _LedgerList({required this.supplierId});

  final String supplierId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entriesAsync = ref.watch(supplierLedgerProvider(supplierId));
    return entriesAsync.when(
      loading: () => const SkeletonList(count: 3),
      error: (error, _) => PharmaEmptyState(
        icon: Icons.error_outline,
        title: 'Ledger could not load',
        message: 'The demo data failed to load. Try again.',
        actionLabel: 'Retry',
        onAction: () => ref.invalidate(supplierLedgerProvider(supplierId)),
      ),
      data: (entries) {
        if (entries.isEmpty) {
          return const PharmaCard(
            child: Text('No ledger entries yet — no purchases or payments.'),
          );
        }
        final sorted = entries.toList()
          ..sort((a, b) {
            final aTime = a.createdAt;
            final bTime = b.createdAt;
            if (aTime == null && bTime == null) return 0;
            if (aTime == null) return 1;
            if (bTime == null) return -1;
            return bTime.compareTo(aTime);
          });
        return PharmaCard(
          child: Column(
            children: [
              for (var i = 0; i < sorted.length; i++) ...[
                if (i > 0) const Divider(height: 1),
                ListTile(
                  leading: Icon(
                    sorted[i].amountMinor >= 0
                        ? Icons.add_circle_outline
                        : Icons.remove_circle_outline,
                    color: sorted[i].amountMinor >= 0
                        ? Theme.of(context).colorScheme.error
                        : Theme.of(context).colorScheme.primary,
                  ),
                  title: Text(
                    supplierLedgerEntryKindLabel(sorted[i].kind),
                  ),
                  subtitle: Text(sorted[i].reason),
                  trailing: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        formatPkr(sorted[i].amountMinor),
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        'Balance ${formatPkr(sorted[i].balanceAfterMinor)}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _EditSupplierDialog extends ConsumerStatefulWidget {
  const _EditSupplierDialog({required this.supplier});

  final Supplier supplier;

  @override
  ConsumerState<_EditSupplierDialog> createState() =>
      _EditSupplierDialogState();
}

class _EditSupplierDialogState extends ConsumerState<_EditSupplierDialog> {
  late final _contact = TextEditingController(
    text: widget.supplier.contactPerson,
  );
  late final _phone = TextEditingController(text: widget.supplier.phone);
  late final _email = TextEditingController(text: widget.supplier.email ?? '');
  late final _address = TextEditingController(
    text: widget.supplier.address ?? '',
  );
  late final _paymentTerms = TextEditingController(
    text: widget.supplier.paymentTerms ?? '',
  );
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _contact.dispose();
    _phone.dispose();
    _email.dispose();
    _address.dispose();
    _paymentTerms.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final errors = validateNewSupplier(
      name: widget.supplier.name,
      contactPerson: _contact.text,
      phone: _phone.text,
    );
    if (errors.isNotEmpty) {
      setState(() => _error = errors.first);
      return;
    }
    setState(() => _saving = true);
    final ok = await ref
        .read(suppliersProvider.notifier)
        .updateSupplier(
          widget.supplier.copyWith(
            contactPerson: _contact.text.trim(),
            phone: _phone.text.trim(),
            email: _email.text.trim().isEmpty ? null : _email.text.trim(),
            clearEmail: _email.text.trim().isEmpty,
            address: _address.text.trim().isEmpty
                ? null
                : _address.text.trim(),
            clearAddress: _address.text.trim().isEmpty,
            paymentTerms: _paymentTerms.text.trim().isEmpty
                ? null
                : _paymentTerms.text.trim(),
            clearPaymentTerms: _paymentTerms.text.trim().isEmpty,
          ),
        );
    if (!mounted) return;
    setState(() => _saving = false);
    if (!ok) {
      setState(() => _error = 'Supplier could not be updated.');
      return;
    }
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Edit ${widget.supplier.name}'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_error != null) ...[
              PharmaErrorBox(errors: [_error!]),
              const SizedBox(height: 12),
            ],
            PharmaTextField(controller: _contact, label: 'Contact person'),
            const SizedBox(height: 12),
            PharmaTextField(
              controller: _phone,
              label: 'Phone',
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
          label: 'Save',
          size: PharmaButtonSize.small,
          loading: _saving,
          onPressed: _save,
        ),
      ],
    );
  }
}

class _LedgerEntryDialog extends ConsumerStatefulWidget {
  const _LedgerEntryDialog({required this.supplierId, required this.kind});

  final String supplierId;
  final SupplierLedgerEntryKind kind;

  @override
  ConsumerState<_LedgerEntryDialog> createState() =>
      _LedgerEntryDialogState();
}

class _LedgerEntryDialogState extends ConsumerState<_LedgerEntryDialog> {
  final _amount = TextEditingController();
  final _reason = TextEditingController();
  bool _isIncrease = true;
  String? _error;
  bool _saving = false;

  String get _title => switch (widget.kind) {
    SupplierLedgerEntryKind.payment => 'Record payment',
    SupplierLedgerEntryKind.purchase => 'Add purchase',
    SupplierLedgerEntryKind.purchaseReturn => 'Record purchase return',
    SupplierLedgerEntryKind.adjustment => 'Record adjustment',
  };

  @override
  void dispose() {
    _amount.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final rupees = double.tryParse(_amount.text.trim()) ?? -1;
    final amountMinor = (rupees * 100).round();
    final entries =
        ref.read(supplierLedgerProvider(widget.supplierId)).asData?.value ??
        const <SupplierLedgerEntry>[];
    final errors = validateSupplierLedgerEntry(
      kind: widget.kind,
      amountMinor: amountMinor,
      reason: _reason.text,
      outstandingMinor: supplierOutstandingMinor(entries),
    );
    if (errors.isNotEmpty) {
      setState(() => _error = errors.first);
      return;
    }
    setState(() => _saving = true);
    final result = await ref
        .read(supplierLedgerProvider(widget.supplierId).notifier)
        .recordEntry(
          kind: widget.kind,
          amountMinor: amountMinor,
          reason: _reason.text,
          isIncrease: _isIncrease,
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
      title: Text(_title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_error != null) ...[
              PharmaErrorBox(errors: [_error!]),
              const SizedBox(height: 12),
            ],
            PharmaTextField(
              controller: _amount,
              label: 'Amount (Rs)',
              hintText: 'e.g. 5000',
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              autofocus: true,
            ),
            const SizedBox(height: 12),
            PharmaTextField(
              controller: _reason,
              label: 'Reason',
              hintText: 'e.g. Payment made — bank transfer',
            ),
            if (widget.kind == SupplierLedgerEntryKind.adjustment) ...[
              const SizedBox(height: 12),
              SwitchListTile(
                title: const Text('Increases what is owed'),
                subtitle: const Text(
                  'Off = reduces what is owed (correction down).',
                ),
                value: _isIncrease,
                onChanged: (value) => setState(() => _isIncrease = value),
                contentPadding: EdgeInsets.zero,
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
          onPressed: () => Navigator.of(context).pop(false),
        ),
        PharmaButton(
          label: 'Record',
          size: PharmaButtonSize.small,
          loading: _saving,
          onPressed: _save,
        ),
      ],
    );
  }
}
