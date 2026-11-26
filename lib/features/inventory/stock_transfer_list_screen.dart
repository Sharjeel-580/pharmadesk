import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/services/branch_context.dart';
import '../../core/widgets/design_system.dart';
import '../../core/widgets/pagination_controls.dart';
import '../../core/widgets/sync_status_widget.dart';
import '../../models/stock_transfer.dart';
import '../authentication/auth_state.dart';
import 'transfer_logic.dart';
import 'transfer_provider.dart';

/// Stock transfer list (SRS D-16, Week 4 Day 2).
///
/// Route `/inventory/transfers`.
///
/// All transfers between the two demo branches, with a status filter
/// and a branch filter (a branch filter shows transfers where the
/// branch is the source OR the destination — a transfer belongs to
/// both ends). Rows are paged at 10 (D107). The "New Transfer"
/// button renders only for roles that may request one
/// (`stockTransfer` write — SRS §5.1).
///
/// **Demo data:** the seeded transfers are fictional sample records
/// (`isDemo: true`) — the screen labels them as demo/sample wherever
/// it shows them, and says plainly that they moved no real stock
/// (D118). Only transfers created through the app move stock.
class StockTransferListScreen extends ConsumerStatefulWidget {
  const StockTransferListScreen({super.key});

  @override
  ConsumerState<StockTransferListScreen> createState() =>
      _StockTransferListScreenState();
}

class _StockTransferListScreenState
    extends ConsumerState<StockTransferListScreen> {
  StockTransferStatus? _statusFilter;
  String? _branchFilter;

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authProvider);
    final branchId = ref.watch(activeBranchProvider).id;
    final transfersAsync = ref.watch(transferProvider);
    final canRequest = canRequestTransfer(user, branchId);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            title: 'Stock Transfers',
            subtitle:
                'Move stock between branches — request, approve, dispatch, receive',
            actionLabel: canRequest ? 'New Transfer' : null,
            actionIcon: canRequest ? Icons.swap_horiz_outlined : null,
            onAction: canRequest
                ? () => context.go('/inventory/transfers/new')
                : null,
          ),
          const SizedBox(height: 8),
          const SyncStatusChip(),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              // Week 8 Day 2 (D177): capped at 280px with isExpanded
              // (the D153/D162 trap) — the branch names are wider
              // than the 390px line in the test font. The cap keeps
              // the desktop filters side by side, instead of forcing
              // every dropdown full-width the way bare isExpanded
              // does on /reports.
              SizedBox(
                width: 280,
                child: DropdownButton<String?>(
                  key: const ValueKey('transfer-branch-filter'),
                  isExpanded: true,
                  value: _branchFilter,
                  hint: const Text('All branches'),
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('All branches'),
                    ),
                    for (final branch in demoBranches)
                      DropdownMenuItem<String?>(
                        value: branch.id,
                        child: Text(branch.name),
                      ),
                  ],
                  onChanged: (selected) =>
                      setState(() => _branchFilter = selected),
                ),
              ),
              for (final status in [
                null,
                ...StockTransferStatus.values,
              ])
                ChoiceChip(
                  label: Text(
                    status == null ? 'All statuses' : status.label,
                  ),
                  selected: _statusFilter == status,
                  onSelected: (_) =>
                      setState(() => _statusFilter = status),
                ),
            ],
          ),
          const SizedBox(height: 16),
          transfersAsync.when(
            loading: () =>
                const Center(child: CircularProgressIndicator()),
            error: (error, _) => PharmaEmptyState(
              icon: Icons.error_outline,
              title: 'Could not load transfers',
              message: error.toString(),
              actionLabel: 'Retry',
              onAction: () => ref.invalidate(transferProvider),
            ),
            data: (transfers) {
              final filtered = transfers.where((transfer) {
                if (_statusFilter != null &&
                    transfer.status != _statusFilter) {
                  return false;
                }
                if (_branchFilter != null &&
                    transfer.fromBranchId != _branchFilter &&
                    transfer.toBranchId != _branchFilter) {
                  return false;
                }
                return true;
              }).toList();
              if (filtered.isEmpty) {
                return PharmaEmptyState(
                  icon: Icons.swap_horiz_outlined,
                  title: 'No transfers yet',
                  message: _statusFilter == null && _branchFilter == null
                      ? 'No stock has been moved between branches yet. '
                          'Request the first transfer to rebalance stock.'
                      : 'No transfers match this filter.',
                  actionLabel: canRequest ? 'New Transfer' : null,
                  onAction: canRequest
                      ? () => context.go('/inventory/transfers/new')
                      : null,
                );
              }
              return PagedList<StockTransfer>(
                items: filtered,
                pageSize: 10,
                emptyMessage: 'No transfers match this filter.',
                itemBuilder: (context, transfer) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: PharmaCard(
                    child: InkWell(
                      onTap: () => context.go(
                        '/inventory/transfers/${transfer.id}',
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        transfer.transferNumber,
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleMedium
                                            ?.copyWith(
                                              fontWeight: FontWeight.w700,
                                            ),
                                      ),
                                    ),
                                    if (transfer.isDemo)
                                      const Padding(
                                        padding: EdgeInsets.only(
                                          right: 8,
                                        ),
                                        child: StatusBadge(
                                          label: 'Demo',
                                          kind: StatusKind.neutral,
                                        ),
                                      ),
                                    StatusBadge(
                                      label: transfer.status.label,
                                      kind: transferStatusKind(
                                        transfer.status,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '${branchDisplayName(transfer.fromBranchId)} '
                                  '→ ${branchDisplayName(transfer.toBranchId)}',
                                  style: Theme.of(
                                    context,
                                  ).textTheme.bodyMedium,
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '${transfer.items.length} line(s) • '
                                  '${transfer.totalQuantity} unit(s)'
                                  '${transfer.note != null ? ' • ${transfer.note!}' : ''}',
                                  style: Theme.of(
                                    context,
                                  ).textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                          const Icon(Icons.chevron_right),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 16),
          Text(
            'Sample transfers are labelled Demo — fictional sample '
            'records that moved no real stock. Transfers you create '
            'here move real stock at dispatch and receive.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
