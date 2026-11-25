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
import 'medicine_logic.dart';

/// Medicine catalogue (Day 5), route `/medicines`.
///
/// Search by name / brand / barcode, filter by category, sort by name,
/// price (int paisa) or sellable stock on the active branch. Every row
/// shows the sellable stock for the active branch and opens the
/// medicine detail on tap. All data comes from the mock repositories.
class MedicineListScreen extends ConsumerStatefulWidget {
  const MedicineListScreen({super.key});

  @override
  ConsumerState<MedicineListScreen> createState() =>
      _MedicineListScreenState();
}

class _MedicineListScreenState extends ConsumerState<MedicineListScreen> {
  String _query = '';
  String _categoryId = 'all';
  MedicineSort _sort = MedicineSort.nameAsc;

  @override
  Widget build(BuildContext context) {
    final branch = ref.watch(activeBranchProvider);
    final medicinesAsync = ref.watch(medicinesProvider);
    final branchInventory = ref.watch(branchInventoryProvider(branch.id));
    final batchesByMedicine = groupBatchesByMedicine(branchInventory);
    final sellableByMedicine = <String, int>{
      for (final entry in batchesByMedicine.entries)
        entry.key: sellableStockFor(entry.value),
    };

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          medicinesAsync.when(
            loading: () => const _CatalogueLoading(),
            error: (error, _) => PharmaEmptyState(
              icon: Icons.error_outline,
              title: 'Catalogue could not load',
              message: 'The demo catalogue failed to load. Try again.',
              actionLabel: 'Retry',
              onAction: () => ref.invalidate(medicinesProvider),
            ),
            data: (medicines) {
              final filtered = sortMedicines(
                filterMedicines(
                  medicines,
                  query: _query,
                  categoryId: _categoryId,
                ),
                _sort,
                sellableStockByMedicine: sellableByMedicine,
              );
              return _CatalogueBody(
                medicines: medicines,
                filtered: filtered,
                branchName: branch.name,
                sellableByMedicine: sellableByMedicine,
                batchesByMedicine: batchesByMedicine,
                query: _query,
                categoryId: _categoryId,
                sort: _sort,
                onQueryChanged: (value) =>
                    setState(() => _query = value),
                onCategorySelected: (value) =>
                    setState(() => _categoryId = value),
                onSortChanged: (value) => setState(
                  () => _sort = value ?? MedicineSort.nameAsc,
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _CatalogueLoading extends StatelessWidget {
  const _CatalogueLoading();

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SkeletonCard(),
        SizedBox(height: 12),
        SkeletonList(count: 5),
      ],
    );
  }
}

class _CatalogueBody extends StatelessWidget {
  const _CatalogueBody({
    required this.medicines,
    required this.filtered,
    required this.branchName,
    required this.sellableByMedicine,
    required this.batchesByMedicine,
    required this.query,
    required this.categoryId,
    required this.sort,
    required this.onQueryChanged,
    required this.onCategorySelected,
    required this.onSortChanged,
  });

  final List<Medicine> medicines;
  final List<Medicine> filtered;
  final String branchName;
  final Map<String, int> sellableByMedicine;
  final Map<String, List<InventoryItem>> batchesByMedicine;
  final String query;
  final String categoryId;
  final MedicineSort sort;
  final ValueChanged<String> onQueryChanged;
  final ValueChanged<String> onCategorySelected;
  final ValueChanged<MedicineSort?> onSortChanged;

  @override
  Widget build(BuildContext context) {
    final categoryCounts = <String, int>{};
    for (final medicine in medicines) {
      categoryCounts[medicine.categoryId] =
          (categoryCounts[medicine.categoryId] ?? 0) + 1;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(
          title: 'Medicines',
          subtitle:
              '${medicines.length} medicines • $branchName • search by name, brand or barcode',
        ),
        const SizedBox(height: 16),
        PharmaSearchField(
          hintText: 'Search medicines…',
          onChanged: onQueryChanged,
        ),
        const SizedBox(height: 12),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              PharmaChip(
                label: 'All (${medicines.length})',
                selected: categoryId == 'all',
                onSelected: (_) => onCategorySelected('all'),
              ),
              for (final entry in medicineCategoryLabels.entries)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: PharmaChip(
                    label:
                        '${entry.value} (${categoryCounts[entry.key] ?? 0})',
                    selected: categoryId == entry.key,
                    onSelected: (_) => onCategorySelected(entry.key),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: Text(
                '${filtered.length} result(s)',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            DropdownButton<MedicineSort>(
              key: const ValueKey('catalogue-sort-dropdown'),
              value: sort,
              items: [
                for (final value in MedicineSort.values)
                  DropdownMenuItem<MedicineSort>(
                    value: value,
                    child: Text(medicineSortLabel(value)),
                  ),
              ],
              onChanged: onSortChanged,
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (filtered.isEmpty)
          PharmaEmptyState(
            icon: Icons.search_off_outlined,
            title: 'No medicines found',
            message: query.isEmpty && categoryId == 'all'
                ? 'The catalogue is empty in this demo.'
                : 'Nothing matches this search or category — try a different name, brand or barcode.',
          )
        else
          for (final medicine in filtered)
            _MedicineRow(
              medicine: medicine,
              sellableStock: sellableByMedicine[medicine.id] ?? 0,
              totalStock: totalStockFor(
                batchesByMedicine[medicine.id] ?? const [],
              ),
              isLowStock: isMedicineLowStock(
                batchesByMedicine[medicine.id] ?? const [],
              ),
            ),
      ],
    );
  }
}

class _MedicineRow extends StatelessWidget {
  const _MedicineRow({
    required this.medicine,
    required this.sellableStock,
    required this.totalStock,
    required this.isLowStock,
  });

  final Medicine medicine;
  final int sellableStock;
  final int totalStock;
  final bool isLowStock;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final outOfStock = sellableStock == 0;
    final expiredOnly = outOfStock && totalStock > 0;
    return PharmaCard(
      child: InkWell(
        onTap: () => context.go('/medicines/${medicine.id}'),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
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
                      '${medicine.brand} • ${medicine.packSize} • ${medicineCategoryLabel(medicine)}',
                      style: theme.textTheme.bodySmall,
                    ),
                    Text(
                      'Barcode ${medicine.barcode ?? '—'}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    formatPkr(medicine.priceMinor),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  if (expiredOnly)
                    const StatusBadge(
                      label: 'Expired stock',
                      kind: StatusKind.danger,
                    )
                  else if (outOfStock)
                    const StatusBadge(
                      label: 'Out of stock',
                      kind: StatusKind.danger,
                    )
                  else if (isLowStock)
                    StatusBadge(
                      label: 'Low stock • $sellableStock',
                      kind: StatusKind.warning,
                    )
                  else
                    StatusBadge(
                      label: '$sellableStock in stock',
                      kind: StatusKind.success,
                    ),
                  if (medicine.requiresPrescription) ...[
                    const SizedBox(height: 4),
                    const StatusBadge(
                      label: 'Rx only',
                      kind: StatusKind.info,
                    ),
                  ],
                ],
              ),
              const SizedBox(width: 4),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}
