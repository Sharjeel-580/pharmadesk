import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/services/branch_context.dart';
import '../../core/widgets/design_system.dart';
import '../../features/authentication/auth_state.dart';
import 'branch_directory.dart';
import 'branch_form_dialog.dart';

/// Branch Management — detail (Week 4 Day 4 — SRS D-28, FR-HO-01/02/08).
///
/// Route `/branches/:id` (capability-gated on `branches`, SRS §5.1).
/// Address, contact, manager, status, delivery areas, plus the
/// franchise settings section (type, franchise fee / royalty rates —
/// "Not set" when never configured, D130). Edit and activate /
/// deactivate are write-gated; a read-only user sees the detail with
/// no action buttons.
class BranchDetailScreen extends ConsumerWidget {
  const BranchDetailScreen({super.key, required this.branchId});

  final String branchId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final branch = ref.watch(branchDirectoryProvider).where(
      (b) => b.id == branchId,
    ).firstOrNull;
    final user = ref.watch(authProvider);
    final activeBranchId = ref.watch(activeBranchProvider).id;
    final canWrite = canWriteBranches(user, activeBranchId);
    final theme = Theme.of(context);
    if (branch == null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionHeader(
              title: 'Branch not found',
              subtitle: 'There is no branch with id "$branchId".',
              actionLabel: 'Back to Branches',
              actionIcon: Icons.store_outlined,
              onAction: () => context.go('/branches'),
            ),
            const SizedBox(height: 16),
            const PharmaEmptyState(
              icon: Icons.store_outlined,
              title: 'Unknown branch',
              message: 'This branch may have been removed, or the link '
                  'is wrong. Go back to the branch list.',
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(24),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionHeader(
              title: branch.name,
              subtitle:
                  '${branch.isFranchise ? 'Franchise' : 'Own branch'} • '
                  '${branch.active ? 'Active' : 'Deactivated'}',
              actionLabel: 'Back to Branches',
              actionIcon: Icons.store_outlined,
              onAction: () => context.go('/branches'),
            ),
            const SizedBox(height: 16),
            PharmaCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Branch detail',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _DetailRow(label: 'Address', value: branch.address),
                  _DetailRow(label: 'Phone', value: branch.phone),
                  _DetailRow(
                    label: 'Manager',
                    value: branch.managerId ?? 'Not assigned',
                  ),
                  _DetailRow(
                    label: 'Status',
                    value: branch.active ? 'Active' : 'Deactivated',
                  ),
                  _DetailRow(
                    label: 'Delivery areas',
                    value: branch.deliveryAreas.isEmpty
                        ? 'None listed'
                        : branch.deliveryAreas.join(', '),
                  ),
                  _DetailRow(label: 'Branch id', value: branch.id),
                ],
              ),
            ),
            const SizedBox(height: 16),
            PharmaCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Franchise settings',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Franchise commission / royalty tracking is a '
                    'Phase 2 (P3, FR-HO-07) feature: V1 runs the 8 own '
                    'branches only. These fields record whatever rates '
                    'are configured for a franchise branch — nothing '
                    'here is a made-up default.',
                  ),
                  const SizedBox(height: 12),
                  _DetailRow(
                    label: 'Branch type',
                    value: branch.isFranchise ? 'Franchise' : 'Own branch',
                  ),
                  _DetailRow(
                    label: 'Franchise fee rate',
                    value: branchRateLabel(branch.franchiseFeeRateBps),
                  ),
                  _DetailRow(
                    label: 'Royalty rate',
                    value: branchRateLabel(branch.royaltyRateBps),
                  ),
                ],
              ),
            ),
            if (canWrite) ...[
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  PharmaButton(
                    label: 'Edit branch',
                    icon: Icons.edit_outlined,
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (_) => BranchFormDialog(
                        existing: branch,
                        onSaved: (updated) {
                          final errors = ref
                              .read(branchDirectoryProvider.notifier)
                              .updateBranch(branch.id, updated);
                          if (errors.isNotEmpty && context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(errors.join(' '))),
                            );
                          }
                        },
                      ),
                    ),
                  ),
                  PharmaButton(
                    label: branch.active ? 'Deactivate' : 'Activate',
                    icon: branch.active
                        ? Icons.block_outlined
                        : Icons.check_circle_outlined,
                    variant: PharmaButtonVariant.danger,
                    onPressed: () async {
                      final confirmed = await showDialog<bool>(
                        context: context,
                        builder: (dialogContext) => AlertDialog(
                          title: Text(
                            branch.active
                                ? 'Deactivate ${branch.name}?'
                                : 'Activate ${branch.name}?',
                          ),
                          content: Text(
                            branch.active
                                ? 'A deactivated branch cannot transact, '
                                    'but its history is preserved '
                                    '(FR-HO-08).'
                                : 'The branch can transact again.',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () =>
                                  Navigator.of(dialogContext).pop(false),
                              child: const Text('Cancel'),
                            ),
                            PharmaButton(
                              label: branch.active
                                  ? 'Deactivate'
                                  : 'Activate',
                              variant: PharmaButtonVariant.danger,
                              onPressed: () =>
                                  Navigator.of(dialogContext).pop(true),
                            ),
                          ],
                        ),
                      );
                      if (confirmed != true || !context.mounted) return;
                      final errors = ref
                          .read(branchDirectoryProvider.notifier)
                          .setActive(branch.id, !branch.active);
                      if (errors.isNotEmpty && context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(errors.join(' '))),
                        );
                      }
                    },
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
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
            width: 160,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}
