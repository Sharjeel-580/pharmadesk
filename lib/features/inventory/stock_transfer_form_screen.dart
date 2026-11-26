import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/data/sync_queue.dart';
import '../../core/services/branch_context.dart';
import '../../core/widgets/design_system.dart';
import '../../models/medicine.dart';
import '../../models/stock_transfer.dart';
import 'transfer_logic.dart';
import 'transfer_provider.dart';

/// New stock transfer form (SRS D-16, Week 4 Day 2).
///
/// Route `/inventory/transfers/new`.
///
/// Picks the source branch (defaults to the active branch) and the
/// destination branch, then medicines + quantities from the source
/// branch's stock. Each medicine row shows the source branch's
/// sellable on-hand (expired / quarantined batches excluded — the
/// same Day 5 guard dispatch uses), so the requester can see what
/// can actually leave. A request moves no stock — availability is
/// enforced at dispatch, so requesting more than is on hand is
/// allowed here and fails clearly at dispatch instead.
///
/// The submit holds one idempotency key across retries (D115
/// pattern): a retry after a failed submit returns the original
/// transfer instead of creating a second one.
class StockTransferFormScreen extends ConsumerStatefulWidget {
  const StockTransferFormScreen({super.key});

  @override
  ConsumerState<StockTransferFormScreen> createState() =>
      _StockTransferFormScreenState();
}

class _StockTransferFormScreenState
    extends ConsumerState<StockTransferFormScreen> {
  late String _fromBranchId;
  late String _toBranchId;
  final _noteController = TextEditingController();
  final _quantities = <String, TextEditingController>{};
  final _selected = <String>{};
  String? _error;
  bool _saving = false;
  late final String _submitKey;

  @override
  void initState() {
    super.initState();
    _fromBranchId = ref.read(activeBranchProvider).id;
    _toBranchId = demoBranches
        .firstWhere((branch) => branch.id != _fromBranchId)
        .id;
    _submitKey = newIdempotencyKey('transfer-create');
  }

  @override
  void dispose() {
    _noteController.dispose();
    for (final controller in _quantities.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final medicinesAsync = ref.watch(transferMedicinesProvider);
    final sellable = ref.watch(
      transferSellableStockProvider(_fromBranchId),
    );
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            title: 'New Transfer',
            subtitle: 'Request stock from one branch for another',
            actionLabel: 'Back to Transfers',
            actionIcon: Icons.swap_horiz_outlined,
            onAction: () => context.go('/inventory/transfers'),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  key: const ValueKey('transfer-from-branch'),
                  // Week 8 Day 2 (D177): isExpanded, the D153/D162
                  // trap — the branch name plus the field chrome
                  // overflowed at 390px without it.
                  isExpanded: true,
                  initialValue: _fromBranchId,
                  decoration: const InputDecoration(
                    labelText: 'From (source branch)',
                  ),
                  items: [
                    for (final branch in demoBranches)
                      DropdownMenuItem<String>(
                        value: branch.id,
                        child: Text(branch.name),
                      ),
                  ],
                  onChanged: (selected) {
                    if (selected == null) return;
                    setState(() {
                      _fromBranchId = selected;
                      if (_toBranchId == selected) {
                        _toBranchId = demoBranches
                            .firstWhere(
                              (branch) => branch.id != selected,
                            )
                            .id;
                      }
                    });
                  },
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: DropdownButtonFormField<String>(
                  key: const ValueKey('transfer-to-branch'),
                  // Week 8 Day 2 (D177): isExpanded, the D153/D162
                  // trap — see the From field above.
                  isExpanded: true,
                  initialValue: _toBranchId,
                  decoration: const InputDecoration(
                    labelText: 'To (destination branch)',
                  ),
                  items: [
                    for (final branch in demoBranches)
                      DropdownMenuItem<String>(
                        value: branch.id,
                        child: Text(branch.name),
                      ),
                  ],
                  onChanged: (selected) {
                    if (selected == null) return;
                    setState(() => _toBranchId = selected);
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          PharmaTextField(
            controller: _noteController,
            label: 'Note (optional)',
            hintText: 'Why does the destination branch need this stock?',
            maxLines: 2,
          ),
          const SizedBox(height: 16),
          Text(
            'Medicines — sellable stock at ${branchDisplayName(_fromBranchId)}',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          medicinesAsync.when(
            loading: () =>
                const Center(child: CircularProgressIndicator()),
            error: (error, _) => Text(
              'Could not load medicines: $error',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
            data: (medicines) {
              final withStock = medicines
                  .where((m) => (sellable[m.id] ?? 0) > 0)
                  .toList();
              if (withStock.isEmpty) {
                return const PharmaEmptyState(
                  icon: Icons.inventory_2_outlined,
                  title: 'No sellable stock at this branch',
                  message:
                      'The source branch has no sellable stock to transfer. '
                      'Pick the other branch as the source, or receive '
                      'stock first.',
                );
              }
              return Column(
                children: [
                  for (final medicine in withStock)
                    _MedicineRow(
                      medicine: medicine,
                      sellable: sellable[medicine.id] ?? 0,
                      selected: _selected.contains(medicine.id),
                      quantityController:
                          _quantities.putIfAbsent(
                            medicine.id,
                            () => TextEditingController(text: '1'),
                          ),
                      onToggle: (selected) {
                        setState(() {
                          if (selected) {
                            _selected.add(medicine.id);
                          } else {
                            _selected.remove(medicine.id);
                          }
                        });
                      },
                    ),
                ],
              );
            },
          ),
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(
              _error!,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
          const SizedBox(height: 24),
          PharmaButton(
            label: 'Request Transfer',
            icon: Icons.swap_horiz_outlined,
            loading: _saving,
            onPressed: _saving ? null : _submit,
          ),
        ],
      ),
    );
  }

  Future<void> _submit() async {
    final medicines =
        ref.read(transferMedicinesProvider).asData?.value ?? const [];
    final byId = {for (final m in medicines) m.id: m};
    final items = <TransferItem>[];
    for (final medicineId in _selected) {
      final medicine = byId[medicineId];
      if (medicine == null) continue;
      final quantity =
          int.tryParse(_quantities[medicineId]?.text.trim() ?? '') ?? 0;
      items.add(
        TransferItem(
          medicineId: medicine.id,
          medicineName: medicine.name,
          quantity: quantity,
        ),
      );
    }
    final problem = validateTransferRequest(
      fromBranchId: _fromBranchId,
      toBranchId: _toBranchId,
      items: items,
    );
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final transfer = await ref
          .read(transferProvider.notifier)
          .createTransfer(
            fromBranchId: _fromBranchId,
            toBranchId: _toBranchId,
            items: items,
            note: _noteController.text,
            idempotencyKey: _submitKey,
          );
      if (mounted) context.go('/inventory/transfers/${transfer.id}');
    } on ArgumentError catch (error) {
      setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

class _MedicineRow extends StatelessWidget {
  const _MedicineRow({
    required this.medicine,
    required this.sellable,
    required this.selected,
    required this.quantityController,
    required this.onToggle,
  });

  final Medicine medicine;
  final int sellable;
  final bool selected;
  final TextEditingController quantityController;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PharmaCard(
      child: Row(
        children: [
          Checkbox(
            value: selected,
            onChanged: (value) => onToggle(value ?? false),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  medicine.name,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  '${medicine.strength} • Sellable: $sellable unit(s)',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          if (selected)
            SizedBox(
              width: 90,
              child: PharmaTextField(
                controller: quantityController,
                label: 'Qty',
                keyboardType: TextInputType.number,
              ),
            ),
        ],
      ),
    );
  }
}
