import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/branch_context.dart';
import '../../core/widgets/design_system.dart';
import '../../core/widgets/pagination_controls.dart';
import '../../core/widgets/sync_status_widget.dart';
import '../../models/stock_adjustment_request.dart';
import '../authentication/auth_state.dart';
import 'inventory_logic.dart';
import 'stock_adjustment_logic.dart';
import 'stock_adjustment_queue.dart';

/// Adjustment approval queue (Week 4 Day 5, D141 — SRS D-14 /
/// FR-INV-08, §5.2.4).
///
/// Route `/inventory/adjustments`, gated on `stockAdjustReq`.
///
/// Lists the active branch's requests — pending first — with the
/// requester and reason on every row. An approver (a role the §5.1
/// matrix allows to approve, other than the requester) approves or
/// rejects a pending request. Approval applies the adjustment
/// through the layer (ledger + audit + sync, exactly like the old
/// direct adjust); rejection records the decision and applies
/// nothing. The queue is session-only (D131): requests filed this
/// session only — persistence is a follow-up, recorded in D141.
class AdjustmentQueueScreen extends ConsumerStatefulWidget {
  const AdjustmentQueueScreen({super.key});

  @override
  ConsumerState<AdjustmentQueueScreen> createState() =>
      _AdjustmentQueueScreenState();
}

class _AdjustmentQueueScreenState
    extends ConsumerState<AdjustmentQueueScreen> {
  StockAdjustmentStatus? _statusFilter;

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authProvider);
    final branch = ref.watch(activeBranchProvider);
    final requests = ref.watch(stockAdjustmentQueueProvider);
    final branchRequests = requests
        .where((request) => request.branchId == branch.id)
        .toList();
    final visible = _statusFilter == null
        ? branchRequests
        : branchRequests
            .where((request) => request.status == _statusFilter)
            .toList();
    // Pending first, then newest first within each status.
    visible.sort((a, b) {
      if (a.isPending != b.isPending) return a.isPending ? -1 : 1;
      return b.requestedAt.compareTo(a.requestedAt);
    });
    final pendingCount = branchRequests
        .where((request) => request.isPending)
        .length;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            title: 'Adjustment Approvals',
            subtitle:
                'Requests for ${branch.name} — $pendingCount pending. '
                'Approval applies the adjustment (ledger + audit + sync).',
          ),
          const SizedBox(height: 8),
          const SyncStatusChip(),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (label, status) in <(String, StockAdjustmentStatus?)>[
                ('All', null),
                ('Pending', StockAdjustmentStatus.pending),
                ('Approved', StockAdjustmentStatus.approved),
                ('Rejected', StockAdjustmentStatus.rejected),
              ])
                ChoiceChip(
                  key: ValueKey('adjustment-filter-$label'),
                  label: Text(label),
                  selected: _statusFilter == status,
                  onSelected: (_) =>
                      setState(() => _statusFilter = status),
                ),
            ],
          ),
          const SizedBox(height: 16),
          PagedList<StockAdjustmentRequest>(
            items: visible,
            pageSize: 10,
            emptyMessage:
                'No adjustment requests yet — use Adjust on any batch to file one.',
            itemBuilder: (context, request) => _RequestRow(
              request: request,
              canDecide: canApproveAdjustment(
                approver: user,
                request: request,
              ),
              onApprove: () => _approve(context, ref, request),
              onReject: () => _reject(context, ref, request),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _approve(
    BuildContext context,
    WidgetRef ref,
    StockAdjustmentRequest request,
  ) async {
    final approved = await ref
        .read(stockAdjustmentQueueProvider.notifier)
        .approveAdjustment(requestId: request.id);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          approved == null
              ? 'Approval failed — the stock may have changed since the request. Try again or reject it.'
              : 'Adjustment approved — ${request.medicineName} batch ${request.batchNo} '
                    '${approved.deltaQty > 0 ? '+' : ''}${approved.deltaQty} units.',
        ),
      ),
    );
  }

  Future<void> _reject(
    BuildContext context,
    WidgetRef ref,
    StockAdjustmentRequest request,
  ) async {
    final controller = TextEditingController();
    final note = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Reject adjustment'),
          content: PharmaTextField(
            key: const ValueKey('adjustment-reject-note'),
            controller: controller,
            label: 'Note (optional)',
            hintText: 'e.g. quantity does not match the count',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const ValueKey('adjustment-reject-confirm'),
              onPressed: () =>
                  Navigator.of(dialogContext).pop(controller.text.trim()),
              child: const Text('Reject'),
            ),
          ],
        );
      },
    );
    controller.dispose();
    if (note == null) return;
    final rejected = ref
        .read(stockAdjustmentQueueProvider.notifier)
        .rejectAdjustment(requestId: request.id, note: note);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          rejected == null
              ? 'Rejection failed — the request may already be decided.'
              : 'Adjustment rejected.',
        ),
      ),
    );
  }
}

class _RequestRow extends StatelessWidget {
  const _RequestRow({
    required this.request,
    required this.canDecide,
    required this.onApprove,
    required this.onReject,
  });

  final StockAdjustmentRequest request;
  final bool canDecide;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = request.status;
    return PharmaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${request.medicineName} • Batch ${request.batchNo}',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              StatusBadge(
                label: switch (status) {
                  StockAdjustmentStatus.pending => 'Pending',
                  StockAdjustmentStatus.approved => 'Approved',
                  StockAdjustmentStatus.rejected => 'Rejected',
                },
                kind: switch (status) {
                  StockAdjustmentStatus.pending => StatusKind.warning,
                  StockAdjustmentStatus.approved => StatusKind.success,
                  StockAdjustmentStatus.rejected => StatusKind.danger,
                },
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${request.deltaQty > 0 ? '+' : ''}${request.deltaQty} units — ${request.reason}',
            style: theme.textTheme.bodyMedium,
          ),
          Text(
            'Requested by ${request.requesterName} • '
            '${formatShortDate(request.requestedAt)}',
            style: theme.textTheme.bodySmall,
          ),
          if (request.decidedByName != null)
            Text(
              'Decided by ${request.decidedByName} • '
              '${request.decidedAt == null ? '' : formatShortDate(request.decidedAt!)}'
              '${request.decisionNote == null ? '' : ' — ${request.decisionNote}'}',
              style: theme.textTheme.bodySmall,
            ),
          if (request.isPending && canDecide) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                PharmaButton(
                  key: ValueKey('adjustment-approve-${request.id}'),
                  label: 'Approve',
                  icon: Icons.check_outlined,
                  size: PharmaButtonSize.small,
                  onPressed: onApprove,
                ),
                PharmaButton(
                  key: ValueKey('adjustment-reject-${request.id}'),
                  label: 'Reject',
                  icon: Icons.close_outlined,
                  variant: PharmaButtonVariant.secondary,
                  size: PharmaButtonSize.small,
                  onPressed: onReject,
                ),
              ],
            ),
          ],
          if (request.isPending && !canDecide)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Waiting for an approver (not the requester).',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
