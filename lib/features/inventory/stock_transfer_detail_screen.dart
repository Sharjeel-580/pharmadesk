import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/data/sync_queue.dart';
import '../../core/services/branch_context.dart';
import '../../core/widgets/design_system.dart';
import '../../core/widgets/sync_status_widget.dart';
import '../../models/stock_transfer.dart';
import '../authentication/auth_state.dart';
import 'transfer_logic.dart';
import 'transfer_provider.dart';

/// Stock transfer detail (SRS D-16, Week 4 Day 2).
///
/// Route `/inventory/transfers/:id`.
///
/// The transfer's lines, its FEFO dispatch allocations (once
/// dispatched), the actor trail (requested / approved / dispatched /
/// received by), and the lifecycle actions for its current status —
/// each rendered only when the signed-in role may do it
/// (`stockTransfer` write, SRS §5.1) and only in the status that
/// allows it. A failed dispatch (a line exceeds sellable source
/// stock) shows the layer's reason instead of failing silently;
/// dispatch and receive hold one idempotency key each across
/// retries (D115 pattern), so a retry after a failed submit moves
/// no stock twice.
class StockTransferDetailScreen extends ConsumerStatefulWidget {
  const StockTransferDetailScreen({super.key, required this.transferId});

  final String transferId;

  @override
  ConsumerState<StockTransferDetailScreen> createState() =>
      _StockTransferDetailScreenState();
}

class _StockTransferDetailScreenState
    extends ConsumerState<StockTransferDetailScreen> {
  late final String _dispatchKey;
  late final String _receiveKey;
  bool _working = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _dispatchKey = newIdempotencyKey('transfer-dispatch');
    _receiveKey = newIdempotencyKey('transfer-receive');
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authProvider);
    final branchId = ref.watch(activeBranchProvider).id;
    final transfer = ref.watch(transferByIdProvider(widget.transferId));
    if (transfer == null) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionHeader(
              title: 'Transfer not found',
              subtitle: 'There is no transfer with this id.',
              actionLabel: 'Back to Transfers',
              actionIcon: Icons.swap_horiz_outlined,
              onAction: () => context.go('/inventory/transfers'),
            ),
          ],
        ),
      );
    }
    final canDecide = canDecideTransfer(user, branchId);
    // Sample transfers are read-only (D118): they are fictional
    // records for viewing the lifecycle — dispatching or receiving
    // one would move real stock under a sample record's name. The
    // full lifecycle runs on transfers the user creates.
    final canAct = canDecide && !transfer.isDemo;
    final isRequester =
        user != null && transfer.requestedBy == user.uid;
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            title: transfer.transferNumber,
            subtitle:
                '${branchDisplayName(transfer.fromBranchId)} → '
                '${branchDisplayName(transfer.toBranchId)}',
            actionLabel: 'Back to Transfers',
            actionIcon: Icons.swap_horiz_outlined,
            onAction: () => context.go('/inventory/transfers'),
          ),
          const SizedBox(height: 8),
          const SyncStatusChip(),
          const SizedBox(height: 16),
          // Week 8 Day 2 (D177): a Wrap, not a Row — the status
          // badge plus the 'Demo — sample record' badge are wider
          // than the 390px line in the test font; on desktop they
          // still sit on one line.
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              StatusBadge(
                label: transfer.status.label,
                kind: transferStatusKind(transfer.status),
              ),
              if (transfer.isDemo)
                const StatusBadge(
                  label: 'Demo — sample record',
                  kind: StatusKind.neutral,
                ),
            ],
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
          const SizedBox(height: 16),
          PharmaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SectionHeader(
                  title: 'Requested lines',
                  subtitle: 'Medicines and quantities to move',
                ),
                const SizedBox(height: 8),
                for (final item in transfer.items)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            item.medicineName,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Text(
                          '${item.quantity} unit(s)',
                          style: theme.textTheme.bodyMedium,
                        ),
                      ],
                    ),
                  ),
                const Divider(),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Total',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Text(
                      '${transfer.totalQuantity} unit(s)',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                if (transfer.note != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Note: ${transfer.note!}',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),
          if (transfer.dispatchAllocations.isNotEmpty) ...[
            const SizedBox(height: 16),
            PharmaCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SectionHeader(
                    title: 'Dispatched from',
                    subtitle:
                        'FEFO batches the stock left the source branch in',
                  ),
                  const SizedBox(height: 8),
                  for (final allocation in transfer.dispatchAllocations)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Batch ${allocation.batchNo.isEmpty ? allocation.batchId : allocation.batchNo}',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          Text(
                            '${allocation.quantity} unit(s)',
                            style: theme.textTheme.bodyMedium,
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 16),
          PharmaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SectionHeader(
                  title: 'Trail',
                  subtitle: 'Who did what, in order',
                ),
                const SizedBox(height: 8),
                _TrailRow(
                  label: 'Requested by',
                  value: transfer.requestedBy ?? '—',
                ),
                _TrailRow(
                  label: 'Approved by',
                  value: transfer.approvedBy ?? '—',
                ),
                _TrailRow(
                  label: 'Dispatched by',
                  value: transfer.dispatchedBy ?? '—',
                ),
                _TrailRow(
                  label: 'Received by',
                  value: transfer.receivedBy ?? '—',
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (transfer.status == StockTransferStatus.requested &&
                  canAct) ...[
                PharmaButton(
                  label: 'Approve',
                  icon: Icons.check_outlined,
                  loading: _working,
                  onPressed: _working
                      ? null
                      : () => _run(
                          () => ref
                              .read(transferProvider.notifier)
                              .approveTransfer(transfer),
                        ),
                ),
                PharmaButton(
                  label: 'Reject',
                  icon: Icons.close_outlined,
                  variant: PharmaButtonVariant.danger,
                  loading: _working,
                  onPressed: _working
                      ? null
                      : () => _run(
                          () => ref
                              .read(transferProvider.notifier)
                              .rejectTransfer(transfer),
                        ),
                ),
                if (isRequester)
                  Text(
                    'You requested this transfer — approval separation '
                    '(SRS §5.2) means someone else must approve it.',
                    style: theme.textTheme.bodySmall,
                  ),
              ],
              if (transfer.status == StockTransferStatus.approved &&
                  canAct)
                PharmaButton(
                  label: 'Dispatch — move stock out',
                  icon: Icons.local_shipping_outlined,
                  loading: _working,
                  onPressed: _working
                      ? null
                      : () => _move(
                          () => ref
                              .read(transferProvider.notifier)
                              .dispatchTransfer(
                                transfer,
                                idempotencyKey: _dispatchKey,
                              ),
                          'Dispatch failed — the source branch may not '
                          'have enough sellable stock for every line.',
                        ),
                ),
              if (transfer.status == StockTransferStatus.dispatched &&
                  canAct)
                PharmaButton(
                  label: 'Receive at destination',
                  icon: Icons.inventory_2_outlined,
                  loading: _working,
                  onPressed: _working
                      ? null
                      : () => _move(
                          () => ref
                              .read(transferProvider.notifier)
                              .receiveTransfer(
                                transfer,
                                idempotencyKey: _receiveKey,
                              ),
                          'Receive failed — please try again.',
                        ),
                ),
              if ((transfer.status == StockTransferStatus.requested ||
                      transfer.status == StockTransferStatus.approved) &&
                  canAct)
                PharmaButton(
                  label: 'Cancel Transfer',
                  icon: Icons.cancel_outlined,
                  variant: PharmaButtonVariant.secondary,
                  loading: _working,
                  onPressed: _working
                      ? null
                      : () => _run(
                          () => ref
                              .read(transferProvider.notifier)
                              .cancelTransfer(transfer),
                        ),
                ),
              if (!canAct && !transfer.isDemo)
                Text(
                  'Your role (${user?.roleLabel ?? 'unknown'}) cannot '
                  'change transfers (SRS §5.1 stock transfer) — the '
                  'Owner, HO Admin, Regional Manager, Branch Manager '
                  'and Inventory Manager can.',
                  style: theme.textTheme.bodySmall,
                ),
            ],
          ),
          if (transfer.isDemo) ...[
            const SizedBox(height: 16),
            Text(
              'Demo — sample record: this transfer moved no real '
              'stock. Dispatching or receiving a sample record here '
              'would move real stock, so sample records stay '
              'read-only in the demo.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _run(Future<StockTransfer> Function() call) async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await call();
    } on ArgumentError catch (error) {
      setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _move(
    Future<StockTransfer?> Function() call,
    String failureMessage,
  ) async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final updated = await call();
      if (updated == null && mounted) {
        setState(() => _error = failureMessage);
      }
    } on ArgumentError catch (error) {
      setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }
}

class _TrailRow extends StatelessWidget {
  const _TrailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 140,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Text(value, style: theme.textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }
}
