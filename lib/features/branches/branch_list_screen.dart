import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/services/branch_context.dart';
import '../../core/widgets/design_system.dart';
import '../../core/widgets/pagination_controls.dart';
import '../../features/authentication/auth_state.dart';
import 'branch_directory.dart';
import 'branch_form_dialog.dart';

/// Branch Management — list (Week 4 Day 4 — SRS D-28, FR-HO-01/02).
///
/// Route `/branches` (capability-gated on `branches`, SRS §5.1).
/// Lists the demo branches plus any added this session (D131),
/// paged at 10 (D107). Tapping a row opens the detail screen
/// (`/branches/:id`). Adding is write-gated (`branches` write —
/// the Auditor sees the list but no Add button).
class BranchListScreen extends ConsumerWidget {
  const BranchListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final branches = ref.watch(branchDirectoryProvider);
    final user = ref.watch(authProvider);
    final branchId = ref.watch(activeBranchProvider).id;
    final canWrite = canWriteBranches(user, branchId);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            title: 'Branch Management',
            subtitle:
                'Own branches and franchises — list, detail, franchise '
                'settings, commission / royalty (SRS D-28)',
            actionLabel: canWrite ? 'Add branch' : null,
            actionIcon: Icons.add_outlined,
            onAction: canWrite
                ? () => showDialog<void>(
                      context: context,
                      builder: (dialogContext) => BranchFormDialog(
                        onSaved: (branch) {
                          // The dialog pops itself before calling
                          // onSaved, so the snackbar uses the screen
                          // context, not the (unmounted) dialog one.
                          final errors = ref
                              .read(branchDirectoryProvider.notifier)
                              .addBranch(branch);
                          if (errors.isNotEmpty && context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(errors.join(' '))),
                            );
                          }
                        },
                      ),
                    )
                : null,
          ),
          const SizedBox(height: 16),
          if (!canWrite)
            const PharmaCard(
              child: Text(
                'You can view branches (read-only). Adding, editing '
                'and deactivating branches needs the "Manage branches" '
                'permission (SRS §5.1).',
              ),
            ),
          if (!canWrite) const SizedBox(height: 16),
          Expanded(
            child: SingleChildScrollView(
              child: PagedList(
                items: branches,
                emptyMessage:
                    'No branches yet. Add the first branch to get started.',
                itemBuilder: (context, branch) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: PharmaCard(
                      child: InkWell(
                        onTap: () => context.go('/branches/${branch.id}'),
                        child: Row(
                          children: [
                            CircleAvatar(
                              backgroundColor: theme.colorScheme.primary
                                  .withValues(alpha: 0.12),
                              child: Icon(
                                branch.isFranchise
                                    ? Icons.store_outlined
                                    : Icons.local_pharmacy_outlined,
                                color: theme.colorScheme.primary,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          branch.name,
                                          style: theme.textTheme.titleMedium
                                              ?.copyWith(
                                                fontWeight: FontWeight.w700,
                                              ),
                                        ),
                                      ),
                                      if (branch.isFranchise)
                                        _BranchChip(label: 'Franchise')
                                      else
                                        _BranchChip(label: 'Own branch'),
                                      const SizedBox(width: 8),
                                      _BranchChip(
                                        label: branch.active
                                            ? 'Active'
                                            : 'Deactivated',
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '${branch.address} • ${branch.phone}',
                                    style: theme.textTheme.bodyMedium,
                                  ),
                                  if (branch.deliveryAreas.isNotEmpty)
                                    Text(
                                      'Delivers to: '
                                      '${branch.deliveryAreas.join(', ')}',
                                      style: theme.textTheme.bodySmall,
                                    ),
                                ],
                              ),
                            ),
                            const Icon(Icons.chevron_right),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BranchChip extends StatelessWidget {
  const _BranchChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(label, style: theme.textTheme.bodySmall),
    );
  }
}
