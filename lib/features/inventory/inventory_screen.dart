import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/data/permission_service.dart';
import '../../core/services/branch_context.dart';
import '../../core/utils/money.dart';
import '../../core/widgets/design_system.dart';
import '../../core/widgets/sync_status_widget.dart';
import '../../models/inventory_item.dart';
import '../../models/medicine.dart';
import '../authentication/auth_state.dart';
import 'inventory_logic.dart';
import 'inventory_provider.dart';
import 'stock_operation_dialogs.dart';

/// Inventory screen (Day 5), route `/inventory`, branch-scoped to the
/// active branch.
///
/// - Stock tab: summary counts, expiry-bucket filters (Expired / ≤30 /
///   31–60 / 61–90 / Fresh) with counts, search, medicines with their
///   batches in FEFO order, low-stock and expired flags, receive /
///   adjust / count actions.
/// - Alerts tab: expired batches, batches expiring within 30 days and
///   low-stock rows — tapping any alert opens the medicine detail.
/// Every stock operation updates the displayed stock immediately and
/// (via the notifier) the dashboard figures.
class InventoryScreen extends ConsumerStatefulWidget {
  const InventoryScreen({super.key});

  @override
  ConsumerState<InventoryScreen> createState() => _InventoryScreenState();
}

class _InventoryScreenState extends ConsumerState<InventoryScreen> {
  bool _showAlerts = false;
  ExpiryBucket? _bucketFilter;
  String _query = '';

  void _openReceive(BuildContext context, WidgetRef ref, String branchId,
      {Medicine? medicine}) async {
    final created = await showReceiveStockDialog(
      context,
      ref,
      branchId: branchId,
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
  }

  @override
  Widget build(BuildContext context) {
    final branch = ref.watch(activeBranchProvider);
    final medicines = ref.watch(medicinesProvider).asData?.value ?? [];
    final byId = {for (final m in medicines) m.id: m};
    final branchInventory = ref.watch(branchInventoryProvider(branch.id));
    final grouped = groupBatchesByMedicine(branchInventory);
    final bucketCounts = expiryBucketCounts(branchInventory);
    final lowStockRows =
        branchInventory.where((item) => item.isLowStock).toList();
    final expiredRows = branchInventory
        .where(
          (item) =>
              expiryBucketFor(item.expiryDate) == ExpiryBucket.expired,
        )
        .toList();
    final nearExpiryRows = branchInventory
        .where(
          (item) =>
              expiryBucketFor(item.expiryDate) == ExpiryBucket.within30,
        )
        .toList();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            title: 'Inventory',
            subtitle:
                '${branch.name} • ${grouped.length} medicines • ${branchInventory.length} batches',
            actionLabel: 'Receive stock',
            actionIcon: Icons.add_box_outlined,
            onAction: () => _openReceive(context, ref, branch.id),
          ),
          const SizedBox(height: 12),
          // Sync status (Week 3 Day 3, D108; Day 4, D111; Day 5,
          // D114): stock receive / adjust / count now write through
          // the production data layer and enqueue one sync payload
          // each, so this chip shows a live pending count for stock
          // work.
          const Align(
            alignment: Alignment.centerLeft,
            child: SyncStatusChip(),
          ),
          const SizedBox(height: 16),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(
                value: false,
                label: Text('Stock'),
                icon: Icon(Icons.inventory_2_outlined),
              ),
              ButtonSegment(
                value: true,
                label: Text('Alerts'),
                icon: Icon(Icons.warning_amber_outlined),
              ),
            ],
            selected: {_showAlerts},
            onSelectionChanged: (selection) =>
                setState(() => _showAlerts = selection.first),
          ),
          const SizedBox(height: 16),
          if (_showAlerts)
            _AlertsTab(
              byId: byId,
              expiredRows: expiredRows,
              nearExpiryRows: nearExpiryRows,
              lowStockRows: lowStockRows,
            )
          else
            _StockTab(
              byId: byId,
              grouped: grouped,
              bucketCounts: bucketCounts,
              bucketFilter: _bucketFilter,
              query: _query,
              branchId: branch.id,
              onBucketSelected: (bucket) => setState(
                () => _bucketFilter = _bucketFilter == bucket ? null : bucket,
              ),
              onClearBucket: () => setState(() => _bucketFilter = null),
              onQueryChanged: (value) => setState(() => _query = value),
              onReceive: (medicine) =>
                  _openReceive(context, ref, branch.id, medicine: medicine),
            ),
        ],
      ),
    );
  }
}

/// Stock tab: bucket filter chips with counts, search, and one group
/// per medicine with its batches in FEFO order.
class _StockTab extends StatelessWidget {
  const _StockTab({
    required this.byId,
    required this.grouped,
    required this.bucketCounts,
    required this.bucketFilter,
    required this.query,
    required this.branchId,
    required this.onBucketSelected,
    required this.onClearBucket,
    required this.onQueryChanged,
    required this.onReceive,
  });

  final Map<String, Medicine> byId;
  final Map<String, List<InventoryItem>> grouped;
  final Map<ExpiryBucket, int> bucketCounts;
  final ExpiryBucket? bucketFilter;
  final String query;
  final String branchId;
  final ValueChanged<ExpiryBucket> onBucketSelected;
  final VoidCallback onClearBucket;
  final ValueChanged<String> onQueryChanged;
  final ValueChanged<Medicine> onReceive;

  List<String> _visibleMedicineIds() {
    final needle = query.trim().toLowerCase();
    return grouped.keys.where((medicineId) {
      final medicine = byId[medicineId];
      if (medicine == null) return false;
      if (needle.isNotEmpty) {
        final matches =
            medicine.name.toLowerCase().contains(needle) ||
            medicine.brand.toLowerCase().contains(needle) ||
            (medicine.barcode?.toLowerCase().contains(needle) ?? false);
        if (!matches) return false;
      }
      if (bucketFilter != null) {
        final batches = grouped[medicineId]!;
        final hasBucket = batches.any(
          (batch) =>
              expiryBucketFor(batch.expiryDate) == bucketFilter,
        );
        if (!hasBucket) return false;
      }
      return true;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visibleMedicineIds();
    final lowStockCount = grouped.values
        .where((batches) => isMedicineLowStock(batches))
        .length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _SummaryChip(
              label: '${grouped.length} medicines',
              icon: Icons.medication_outlined,
              kind: StatusKind.info,
            ),
            _SummaryChip(
              label: '$lowStockCount low stock',
              icon: Icons.inventory_2_outlined,
              kind: lowStockCount > 0
                  ? StatusKind.warning
                  : StatusKind.success,
            ),
            _SummaryChip(
              label:
                  '${bucketCounts[ExpiryBucket.within30] ?? 0} expiring ≤ 30 days',
              icon: Icons.event_outlined,
              kind: StatusKind.warning,
            ),
            _SummaryChip(
              label: '${bucketCounts[ExpiryBucket.expired] ?? 0} expired',
              icon: Icons.dangerous_outlined,
              kind: StatusKind.danger,
            ),
          ],
        ),
        const SizedBox(height: 12),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              PharmaChip(
                label: 'All batches',
                selected: bucketFilter == null,
                onSelected: (_) => onClearBucket(),
              ),
              for (final bucket in ExpiryBucket.values)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: PharmaChip(
                    label:
                        '${expiryBucketLabel(bucket)} (${bucketCounts[bucket] ?? 0})',
                    selected: bucketFilter == bucket,
                    onSelected: (_) => onBucketSelected(bucket),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        PharmaSearchField(
          hintText: 'Search medicines…',
          onChanged: onQueryChanged,
        ),
        const SizedBox(height: 12),
        if (visible.isEmpty)
          const PharmaEmptyState(
            icon: Icons.search_off_outlined,
            title: 'Nothing in this view',
            message:
                'No batches match the selected bucket or search — try a different filter.',
          )
        else
          for (final medicineId in visible)
            _MedicineStockGroup(
              medicine: byId[medicineId]!,
              batches: grouped[medicineId]!,
              bucketFilter: bucketFilter,
              onReceive: () => onReceive(byId[medicineId]!),
            ),
      ],
    );
  }
}

class _SummaryChip extends StatelessWidget {
  const _SummaryChip({
    required this.label,
    required this.icon,
    required this.kind,
  });

  final String label;
  final IconData icon;
  final StatusKind kind;

  @override
  Widget build(BuildContext context) {
    final color = kind.color;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 13,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// One medicine's batches at this branch, FEFO order, with low-stock
/// and expired flags and a receive action. When a bucket filter is on,
/// only batches in that bucket are shown.
class _MedicineStockGroup extends StatelessWidget {
  const _MedicineStockGroup({
    required this.medicine,
    required this.batches,
    required this.bucketFilter,
    required this.onReceive,
  });

  final Medicine medicine;
  final List<InventoryItem> batches;
  final ExpiryBucket? bucketFilter;
  final VoidCallback onReceive;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shown = bucketFilter == null
        ? batches
        : batches
              .where(
                (batch) =>
                    expiryBucketFor(batch.expiryDate) == bucketFilter,
              )
              .toList();
    final sellable = sellableStockFor(batches);
    final total = totalStockFor(batches);
    final lowStock = isMedicineLowStock(batches);
    final hasExpired = batches.any(
      (batch) => expiryBucketFor(batch.expiryDate) == ExpiryBucket.expired,
    );
    return PharmaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => context.go('/medicines/${medicine.id}'),
            // Week 4 Day 5 (D142): the old header Row — name column
            // + sellable/total + badges + chevron on one line —
            // overflowed 24–56px at 390px. Name + chevron stay on
            // the first line; figures + badges move to a second line
            // where the badges wrap instead of overflowing.
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${medicine.name} ${medicine.strength}',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            '${medicine.brand} • ${medicine.packSize} • ${formatPkr(medicine.priceMinor)}',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    const Icon(Icons.chevron_right),
                  ],
                ),
                const SizedBox(height: 6),
                // Figures on their own line, badges on the next:
                // the old Row left the badges a ~82px run, and a
                // badge wider than its Wrap run overflows (40px).
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$sellable sellable / $total total',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (hasExpired || lowStock) ...[
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: [
                          if (hasExpired)
                            const StatusBadge(
                              label: 'Has expired',
                              kind: StatusKind.danger,
                            ),
                          if (lowStock)
                            const StatusBadge(
                              label: 'Low stock',
                              kind: StatusKind.warning,
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          const Divider(),
          for (final batch in shown)
            _InventoryBatchRow(
              batch: batch,
              medicineName: medicine.name,
            ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: PharmaButton(
              label: 'Receive stock',
              icon: Icons.add_box_outlined,
              variant: PharmaButtonVariant.secondary,
              size: PharmaButtonSize.small,
              onPressed: onReceive,
            ),
          ),
        ],
      ),
    );
  }
}

/// One batch row inside a medicine group: batch, mfg/expiry, qty, cost,
/// FEFO position and status, with adjust / count actions.
class _InventoryBatchRow extends ConsumerWidget {
  const _InventoryBatchRow({
    required this.batch,
    required this.medicineName,
  });

  final InventoryItem batch;
  final String medicineName;

  Future<void> _toggleQuarantine(
    BuildContext context,
    WidgetRef ref, {
    required bool quarantine,
  }) async {
    final updated = await showQuarantineBatchDialog(
      context,
      ref,
      batch: batch,
      medicineName: medicineName,
      quarantine: quarantine,
    );
    if (updated != null && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            quarantine
                ? 'Batch ${updated.batchNo} quarantined — out of saleable stock.'
                : 'Batch ${updated.batchNo} restored to saleable stock.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final bucket = expiryBucketFor(batch.expiryDate);
    final sellable = isBatchSellable(batch);
    final daysLeft = daysToExpiry(batch.expiryDate);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      // Week 4 Day 5 (D142): the old one-line Row — text + badge +
      // two icon buttons — overflowed 24–56px at 390px (the badge
      // alone is ~170px in the test font). Text + badge stay on the
      // first line; the actions move to a second, right-aligned row.
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Batch ${batch.batchNo ?? '—'} • ${batch.quantity} units',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      'Mfg ${batch.mfgDate == null ? '—' : formatShortDate(batch.mfgDate!)}'
                      ' • Exp ${batch.expiryDate == null ? '—' : formatShortDate(batch.expiryDate!)}'
                      '${daysLeft == null ? '' : bucket == ExpiryBucket.expired ? ' • expired ${-daysLeft}d ago' : ' • $daysLeft day(s) left'}'
                      ' • cost ${formatPkr(batch.costMinor)}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: bucket == ExpiryBucket.expired
                            ? StatusKind.danger.color
                            : null,
                        fontWeight: bucket == ExpiryBucket.expired
                            ? FontWeight.w700
                            : null,
                      ),
                    ),
                  ],
                ),
              ),
              StatusBadge(
                label: batch.isQuarantined
                    ? 'Quarantined'
                    : sellable
                    ? expiryBucketLabel(bucket)
                    : bucket == ExpiryBucket.expired
                    ? 'Expired'
                    : 'Out of stock',
                kind: batch.isQuarantined
                    ? StatusKind.warning
                    : sellable
                    ? expiryBucketKind(bucket)
                    : StatusKind.danger,
              ),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (permissionService.canWrite(
                ref.watch(authProvider),
                'stockReceive',
                batch.branchId,
              )) ...[
                if (batch.status == BatchStatus.available)
                  IconButton(
                    key: ValueKey('inv-quarantine-${batch.id}'),
                    tooltip: 'Quarantine batch',
                    icon: const Icon(Icons.block_outlined),
                    onPressed: () => _toggleQuarantine(
                      context,
                      ref,
                      quarantine: true,
                    ),
                  )
                else if (batch.isQuarantined)
                  IconButton(
                    key: ValueKey('inv-unquarantine-${batch.id}'),
                    tooltip: 'Restore batch',
                    icon: const Icon(Icons.undo_outlined),
                    onPressed: () => _toggleQuarantine(
                      context,
                      ref,
                      quarantine: false,
                    ),
                  ),
              ],
              IconButton(
                key: ValueKey('inv-adjust-${batch.id}'),
                tooltip: 'Adjust stock',
                icon: const Icon(Icons.tune_outlined),
                onPressed: () async {
                  final request = await showAdjustStockDialog(
                    context,
                    ref,
                    batch: batch,
                    medicineName: medicineName,
                  );
                  if (request != null && context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          'Adjustment requested — pending approval on the Adjustment Approvals screen.',
                        ),
                      ),
                    );
                  }
                },
              ),
              IconButton(
                key: ValueKey('inv-count-${batch.id}'),
                tooltip: 'Stock count',
                icon: const Icon(Icons.fact_check_outlined),
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

/// Alerts tab: expired batches first, then expiring within 30 days,
/// then low stock. Tapping a row opens the medicine detail.
class _AlertsTab extends StatelessWidget {
  const _AlertsTab({
    required this.byId,
    required this.expiredRows,
    required this.nearExpiryRows,
    required this.lowStockRows,
  });

  final Map<String, Medicine> byId;
  final List<InventoryItem> expiredRows;
  final List<InventoryItem> nearExpiryRows;
  final List<InventoryItem> lowStockRows;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget section(
      String title,
      String subtitle,
      List<InventoryItem> rows,
      StatusKind kind,
      IconData icon,
    ) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(title: title, subtitle: subtitle),
          const SizedBox(height: 8),
          if (rows.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'Nothing here — all clear.',
                style: theme.textTheme.bodySmall,
              ),
            )
          else
            for (final row in rows)
              _AlertRow(
                item: row,
                medicine: byId[row.medicineId],
                kind: kind,
                icon: icon,
              ),
          const SizedBox(height: 16),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        section(
          'Expired batches',
          '${expiredRows.length} batch(es) — never sellable, write off or return',
          expiredRows,
          StatusKind.danger,
          Icons.dangerous_outlined,
        ),
        section(
          'Expiring within 30 days',
          '${nearExpiryRows.length} batch(es) — sell first (FEFO) or return',
          nearExpiryRows,
          StatusKind.warning,
          Icons.event_outlined,
        ),
        section(
          'Low stock',
          '${lowStockRows.length} batch(es) at or below the alert level',
          lowStockRows,
          StatusKind.warning,
          Icons.inventory_2_outlined,
        ),
      ],
    );
  }
}

class _AlertRow extends StatelessWidget {
  const _AlertRow({
    required this.item,
    required this.medicine,
    required this.kind,
    required this.icon,
  });

  final InventoryItem item;
  final Medicine? medicine;
  final StatusKind kind;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final daysLeft = daysToExpiry(item.expiryDate);
    final detail = kind == StatusKind.danger &&
            expiryBucketFor(item.expiryDate) == ExpiryBucket.expired
        ? 'Batch ${item.batchNo ?? '—'} expired ${daysLeft == null ? '' : '${-daysLeft} day(s) ago'} • ${item.quantity} units'
        : daysLeft != null && daysLeft <= 30
        ? 'Batch ${item.batchNo ?? '—'} expires in $daysLeft day(s) • ${item.quantity} units'
        : 'Batch ${item.batchNo ?? '—'} • ${item.quantity} left (alert at ${item.lowStockThreshold})';
    return PharmaCard(
      child: InkWell(
        key: ValueKey('alert-${item.id}'),
        onTap: medicine == null
            ? null
            : () => context.go('/medicines/${medicine!.id}'),
        child: Row(
          children: [
            Icon(icon, size: 20, color: kind.color),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    medicine?.name ?? item.medicineId,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(detail, style: theme.textTheme.bodySmall),
                ],
              ),
            ),
            const Icon(Icons.chevron_right),
          ],
        ),
      ),
    );
  }
}
