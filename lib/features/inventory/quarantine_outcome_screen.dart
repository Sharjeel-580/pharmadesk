import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/branch_context.dart';
import '../../core/widgets/design_system.dart';
import '../../core/widgets/pagination_controls.dart';
import '../../core/widgets/sync_status_widget.dart';
import '../../models/quarantine_outcome_request.dart';
import '../authentication/auth_state.dart';
import 'inventory_logic.dart';
import 'quarantine_outcome_logic.dart';
import 'quarantine_outcome_queue.dart';

/// Quarantine return / disposal approval queue (Week 5 Day 4, D154
/// — SRS D-11 / FR-INV-07, §5.2.4).
///
/// Route `/inventory/quarantine-outcomes`, gated on `stockAdjustReq`
/// (like the adjustment queue).
///
/// Lists the active branch's requests — pending first — with the
/// outcome, quantity and reason on every row. An approver (a role
/// the §5.1 matrix allows to approve, other than the requester)
/// approves or rejects a pending request. Approval applies the
/// outcome through the layer (status + quantity + audit + sync):
/// a return leaves stock (quantity 0), a disposal stays unsellable.
/// Rejection records the decision and applies nothing — the batch
/// stays quarantined. The queue itself is session-only (D141
/// posture); the outcome on the batch row is persisted.
class QuarantineOutcomeScreen extends ConsumerStatefulWidget {
  const QuarantineOutcomeScreen({super.key});

  @override
  ConsumerState<QuarantineOutcomeScreen> createState() =>
      _QuarantineOutcomeScreenState();
}

class _QuarantineOutcomeScreenState
    extends ConsumerState<QuarantineOutcomeScreen> {
  QuarantineOutcomeStatus? _statusFilter;

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authProvider);
    final branch = ref.watch(activeBranchProvider);
    final requests = ref.watch(quarantineOutcomeQueueProvider);
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
            title: 'Quarantine Outcomes',
            subtitle:
                'Return / disposal requests for ${branch.name} — '
                '$pendingCount pending. Approval moves the batch '
                '(return leaves stock, disposal stays unsellable).',
          ),
          const SizedBox(height: 8),
          const SyncStatusChip(),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (label, status)
                  in <(String, QuarantineOutcomeStatus?)>[
                    ('All', null),
                    ('Pending', QuarantineOutcomeStatus.pending),
                    ('Approved', QuarantineOutcomeStatus.approved),
                    ('Rejected', QuarantineOutcomeStatus.rejected),
                  ])
                ChoiceChip(
                  key: ValueKey('quarantine-outcome-filter-$label'),
                  label: Text(label),
                  selected: _statusFilter == status,
                  onSelected: (_) => setState(() => _statusFilter = status),
                ),
            ],
          ),
          const SizedBox(height: 16),
          PagedList<QuarantineOutcomeRequest>(
            items: visible,
            pageSize: 10,
            emptyMessage: 'No return / disposal requests yet — use Return or Dispose on any quarantined batch to file one.',
            itemBuilder: (context, request) => _RequestRow(
              request: request,
              canDecide: canApproveQuarantineOutcome(
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
    QuarantineOutcomeRequest request,
  ) async {
    final approved = await ref
        .read(quarantineOutcomeQueueProvider.notifier)
        .approveOutcome(requestId: request.id);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          approved == null
              ? 'Approval failed — the batch may no longer be quarantined. Try again or reject it.'
              : '${quarantineOutcomeLabel(request.outcome)} approved — '
                    '${request.medicineName} batch ${request.batchNo} '
                    '(${request.quantityAtRequest} units).',
        ),
      ),
    );
  }

  Future<void> _reject(
    BuildContext context,
    WidgetRef ref,
    QuarantineOutcomeRequest request,
  ) async {
    final controller = TextEditingController();
    final note = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Reject outcome request'),
          content: PharmaTextField(
            key: const ValueKey('quarantine-outcome-reject-note'),
            controller: controller,
            label: 'Note (optional)',
            hintText: 'e.g. batch is safe — restore it instead',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const ValueKey('quarantine-outcome-reject-confirm'),
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
        .read(quarantineOutcomeQueueProvider.notifier)
        .rejectOutcome(requestId: request.id, note: note);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          rejected == null
              ? 'Rejection failed — the request may already be decided.'
              : 'Outcome request rejected — the batch stays quarantined.',
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

  final QuarantineOutcomeRequest request;
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
                  QuarantineOutcomeStatus.pending => 'Pending',
                  QuarantineOutcomeStatus.approved => 'Approved',
                  QuarantineOutcomeStatus.rejected => 'Rejected',
                },
                kind: switch (status) {
                  QuarantineOutcomeStatus.pending => StatusKind.warning,
                  QuarantineOutcomeStatus.approved => StatusKind.success,
                  QuarantineOutcomeStatus.rejected => StatusKind.danger,
                },
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${quarantineOutcomeLabel(request.outcome)} — '
            '${request.quantityAtRequest} units — ${request.reason}',
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
                  key: ValueKey('quarantine-outcome-approve-${request.id}'),
                  label: 'Approve',
                  icon: Icons.check_outlined,
                  size: PharmaButtonSize.small,
                  onPressed: onApprove,
                ),
                PharmaButton(
                  key: ValueKey('quarantine-outcome-reject-${request.id}'),
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
