import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/services/branch_context.dart';
import '../../core/utils/money.dart';
import '../../core/widgets/design_system.dart';
import '../../models/inventory_item.dart';
import '../../models/medicine.dart';
import '../inventory/inventory_logic.dart';
import '../inventory/inventory_provider.dart';
import '../inventory/stock_operation_dialogs.dart';
import 'medicine_logic.dart';

/// Medicine detail (Day 5), route `/medicines/:id`.
///
/// Info (name, brand, category, strength, pack, price in int paisa,
/// MRP, barcode, Rx flag), stock per branch, and the active branch's
/// batches in FEFO order with mfg/expiry, quantities and status —
/// expired batches clearly flagged and never sellable. Batch actions
/// (adjust / count) and receive-stock open the shared stock dialogs.
class MedicineDetailScreen extends ConsumerWidget {
  const MedicineDetailScreen({super.key, required this.medicineId});

  final String medicineId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final branch = ref.watch(activeBranchProvider);
    final medicine = ref.watch(medicineByIdProvider(medicineId));
    if (medicine == null) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: PharmaEmptyState(
          icon: Icons.medication_outlined,
          title: 'Medicine not found',
          message: 'There is no medicine with id "$medicineId" in this demo.',
          actionLabel: 'All Medicines',
          onAction: () => context.go('/medicines'),
        ),
      );
    }
    final allInventory = ref.watch(inventoryProvider).asData?.value ?? [];
    final branchBatches = allInventory
        .where(
          (item) =>
              item.medicineId == medicine.id && item.branchId == branch.id,
        )
        .toList();
    final batches = fefoBatches(branchBatches);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            title: '${medicine.name} ${medicine.strength}',
            subtitle:
                '${medicine.brand} • ${medicineCategoryLabel(medicine)} • ${branch.name}',
            actionLabel: 'All Medicines',
            actionIcon: Icons.medication_outlined,
            onAction: () => context.go('/medicines'),
          ),
          const SizedBox(height: 16),
          PharmaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _InfoRow(label: 'Name', value: medicine.name),
                _InfoRow(label: 'Brand', value: medicine.brand),
                _InfoRow(
                  label: 'Category',
                  value: medicineCategoryLabel(medicine),
                ),
                _InfoRow(label: 'Strength', value: medicine.strength),
                _InfoRow(label: 'Pack size', value: medicine.packSize),
                _InfoRow(
                  label: 'Sale price',
                  value: formatPkr(medicine.priceMinor),
                ),
                if (medicine.mrp != null)
                  _InfoRow(
                    label: 'MRP',
                    value: formatPkr(rupeesToMinorUnits(medicine.mrp!)),
                  ),
                _InfoRow(
                  label: 'Barcode',
                  value: medicine.barcode ?? '—',
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    if (medicine.requiresPrescription)
                      const StatusBadge(
                        label: 'Rx only — prescription required',
                        kind: StatusKind.info,
                      )
                    else
                      const StatusBadge(
                        label: 'Over the counter',
                        kind: StatusKind.success,
                      ),
                    const SizedBox(width: 8),
                    if (!canSellMedicine(batches))
                      const StatusBadge(
                        label: 'Not sellable here',
                        kind: StatusKind.danger,
                      )
                    else if (isMedicineLowStock(batches))
                      const StatusBadge(
                        label: 'Low stock',
                        kind: StatusKind.warning,
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _BranchStockCard(medicine: medicine, inventory: allInventory),
          const SizedBox(height: 16),
          PharmaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SectionHeader(
                  title: 'Batches — ${branch.name}',
                  subtitle:
                      'FEFO order: earliest expiry first (expired batches are never sellable)',
                  actionLabel: 'Receive stock',
                  actionIcon: Icons.add_box_outlined,
                  onAction: () async {
                    final created = await showReceiveStockDialog(
                      context,
                      ref,
                      branchId: branch.id,
                      medicine: medicine,
                    );
                    if (created != null && context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            'Received ${created.quantity} units — batch ${created.batchNo}.',
                          ),
                        ),
                      );
                    }
                  },
                ),
                const SizedBox(height: 8),
                if (batches.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Text('No batches at this branch yet.'),
                  )
                else
                  for (final batch in batches)
                    _BatchRow(
                      batch: batch,
                      medicineName: medicine.name,
                    ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

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
            width: 110,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

/// Stock of one medicine at every demo branch.
class _BranchStockCard extends StatelessWidget {
  const _BranchStockCard({required this.medicine, required this.inventory});

  final Medicine medicine;
  final List<InventoryItem> inventory;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PharmaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionHeader(
            title: 'Stock per branch',
            subtitle: 'Sellable units exclude expired batches',
          ),
          const SizedBox(height: 8),
          for (final branch in demoBranches)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      branch.name,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    '${sellableStockFor(inventory.where((item) => item.medicineId == medicine.id && item.branchId == branch.id))} sellable',
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(width: 12),
                  Text(
                    '${totalStockFor(inventory.where((item) => item.medicineId == medicine.id && item.branchId == branch.id))} total',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// One batch row: batch no., mfg/expiry, qty, cost, status — expired
/// batches are flagged red, with adjust / count actions.
class _BatchRow extends ConsumerWidget {
  const _BatchRow({required this.batch, required this.medicineName});

  final InventoryItem batch;
  final String medicineName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final bucket = expiryBucketFor(batch.expiryDate);
    final sellable = isBatchSellable(batch);
    final daysLeft = daysToExpiry(batch.expiryDate);
    final expiryText = batch.expiryDate == null
        ? 'No expiry'
        : bucket == ExpiryBucket.expired
        ? 'Expired ${daysLeft == null ? '' : '${-daysLeft} day(s) ago'} • ${formatShortDate(batch.expiryDate!)}'
        : 'Expires in $daysLeft day(s) • ${formatShortDate(batch.expiryDate!)}';
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bucket == ExpiryBucket.expired
            ? StatusKind.danger.color.withValues(alpha: 0.06)
            : null,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: bucket == ExpiryBucket.expired
              ? StatusKind.danger.color.withValues(alpha: 0.35)
              : theme.dividerColor.withValues(alpha: 0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Batch ${batch.batchNo ?? '—'}',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              StatusBadge(
                label: sellable
                    ? expiryBucketLabel(bucket)
                    : bucket == ExpiryBucket.expired
                    ? 'Expired — never sellable'
                    : 'Out of stock',
                kind: sellable
                    ? expiryBucketKind(bucket)
                    : StatusKind.danger,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Mfg ${batch.mfgDate == null ? '—' : formatShortDate(batch.mfgDate!)} • $expiryText',
            style: theme.textTheme.bodySmall,
          ),
          Text(
            '${batch.quantity} units • cost ${formatPkr(batch.costMinor)} each',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              PharmaButton(
                key: ValueKey('adjust-${batch.id}'),
                label: 'Adjust',
                icon: Icons.tune_outlined,
                variant: PharmaButtonVariant.secondary,
                size: PharmaButtonSize.small,
                onPressed: () async {
                  final updated = await showAdjustStockDialog(
                    context,
                    ref,
                    batch: batch,
                    medicineName: medicineName,
                  );
                  if (updated != null && context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          'Batch ${updated.batchNo} now has ${updated.quantity} units.',
                        ),
                      ),
                    );
                  }
                },
              ),
              const SizedBox(width: 8),
              PharmaButton(
                key: ValueKey('count-${batch.id}'),
                label: 'Count',
                icon: Icons.fact_check_outlined,
                variant: PharmaButtonVariant.secondary,
                size: PharmaButtonSize.small,
                onPressed: () async {
                  final result = await showStockCountDialog(
                    context,
                    ref,
                    batch: batch,
                    medicineName: medicineName,
                  );
                  if (result != null && context.mounted) {
                    final variance = result.variance;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          variance == 0
                              ? 'Count matches the system (${result.item.quantity} units).'
                              : 'Count saved — variance ${variance > 0 ? '+' : ''}$variance units.',
                        ),
                      ),
                    );
                  }
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}
