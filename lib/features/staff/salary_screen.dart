import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/data/permission_service.dart';
import '../../core/services/branch_context.dart';
import '../../core/utils/money.dart';
import '../../core/widgets/design_system.dart';
import '../authentication/auth_state.dart';
import '../settings/roles_permissions.dart';
import 'salary_edit_dialog.dart';
import 'salary_logic.dart';
import 'salary_provider.dart';
import 'staff_provider.dart';

/// Salary screen (Week 3 Day 2, D102).
///
/// Route `/staff/salary`.
///
/// Per-employee monthly salary info + monthly totals, branch-scoped.
/// Gated on the SRS §5.1 `hrSalary` capability at the route
/// ([FeatureGate] + `routeCapability`) AND in-screen, so a user
/// without it sees a clear explanation instead of figures: Owner /
/// HO Admin / Accountant may view, Auditor read-only, everyone else
/// (incl. Branch Manager) may not.
///
/// **Demo data:** the seeded records are fictional sample payroll
/// (`isDemo: true`) — the screen labels them as demo/sample
/// whenever it shows them, and says plainly that they are not real
/// payroll. No salary figure is ever invented as real data.
class SalaryScreen extends ConsumerStatefulWidget {
  const SalaryScreen({super.key});

  @override
  ConsumerState<SalaryScreen> createState() => _SalaryScreenState();
}

class _SalaryScreenState extends ConsumerState<SalaryScreen> {
  late String _month;
  String? _branchId; // null = all branches (head office only)

  @override
  void initState() {
    super.initState();
    _month = salaryMonthKey(DateTime.now());
    _branchId = ref.read(activeBranchProvider).id;
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authProvider);
    final staffAsync = ref.watch(staffProvider);
    final salaryAsync = ref.watch(salaryProvider);
    final canSeeAll =
        user == null ||
        permissionService.permissionFor(user, 'allBranches') ==
            RolePermission.allowed ||
        permissionService.permissionFor(user, 'allBranches') ==
            RolePermission.readOnly;
    final effectiveBranch = _branchId;
    final mayView = effectiveBranch == null
        ? canViewSalary(user, ref.read(activeBranchProvider).id)
        : canViewSalary(user, effectiveBranch);
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            title: 'Salary',
            subtitle:
                'Monthly payroll — ${salaryMonthLabel(_month)}',
            actionLabel: 'Back to Staff',
            actionIcon: Icons.badge_outlined,
            onAction: () => context.go('/staff'),
          ),
          const SizedBox(height: 16),
          if (!mayView) ...[
            PharmaEmptyState(
              icon: Icons.lock_outline,
              title: 'No permission for Salary',
              message:
                  'Your role (${user?.roleLabel ?? 'unknown'}) does not '
                  'have the "HR: salary records" permission (SRS §5.1). '
                  'Salary figures are visible to the Owner, HO Admin and '
                  'Accountant only — ask one of them if you need access.',
              actionLabel: 'Back to Staff',
              onAction: () => context.go('/staff'),
            ),
          ] else ...[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (canSeeAll)
                  // Week 8 Day 2 (D177): capped at 280px with
                  // isExpanded (the D153/D162 trap) — same
                  // branch-name overflow as the transfer list.
                  SizedBox(
                    width: 280,
                    child: DropdownButton<String?>(
                      isExpanded: true,
                      value: _branchId,
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
                          setState(() => _branchId = selected),
                    ),
                  ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.chevron_left),
                      tooltip: 'Previous month',
                      onPressed: () => setState(
                        () => _month = previousSalaryMonth(_month),
                      ),
                    ),
                    Text(
                      salaryMonthLabel(_month),
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.chevron_right),
                      tooltip: 'Next month',
                      // No future months: payroll is for months that
                      // have happened.
                      onPressed: _month == salaryMonthKey(DateTime.now())
                          ? null
                          : () => setState(
                                () => _month = nextSalaryMonth(_month),
                              ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),
            salaryAsync.when(
              loading: () => const SkeletonList(count: 4),
              error: (error, _) => PharmaEmptyState(
                icon: Icons.error_outline,
                title: 'Salary records could not load',
                message: 'The salary records failed to load. Try again.',
                actionLabel: 'Retry',
                onAction: () => ref.invalidate(salaryProvider),
              ),
              data: (records) {
                return staffAsync.when(
                  loading: () => const SkeletonList(count: 4),
                  error: (error, _) => PharmaEmptyState(
                    icon: Icons.error_outline,
                    title: 'Staff could not load',
                    message: 'The staff directory failed to load.',
                    actionLabel: 'Retry',
                    onAction: () => ref.invalidate(staffProvider),
                  ),
                  data: (staff) {
                    final rows = salaryRowsFor(
                      staff: staff,
                      records: records,
                      month: _month,
                      branchId: effectiveBranch,
                    );
                    final totals = monthlySalaryTotals(rows);
                    final hasDemo = rows.any((row) => row.isDemo);
                    if (rows.isEmpty) {
                      return const PharmaCard(
                        child: Text(
                          'No staff at this branch.',
                        ),
                      );
                    }
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (hasDemo)
                          PharmaCard(
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(
                                  Icons.info_outline,
                                  color: theme.colorScheme.primary,
                                ),
                                const SizedBox(width: 12),
                                const Expanded(
                                  child: Text(
                                    'Demo data — these salary figures are '
                                    'fictional sample figures for the demo, '
                                    'not real payroll. Real payroll records '
                                    'replace them when the payroll module is '
                                    'connected.',
                                  ),
                                ),
                              ],
                            ),
                          ),
                        if (hasDemo) const SizedBox(height: 16),
                        _TotalsCard(totals: totals, month: _month),
                        const SizedBox(height: 16),
                        if (totals.recordedCount == 0)
                          PharmaCard(
                            child: Text(
                              'No salary records for '
                              '${salaryMonthLabel(_month)} yet.',
                            ),
                          )
                        else ...[
                          for (final row in rows)
                            _SalaryRowCard(
                              row: row,
                              month: _month,
                              // Edit (Week 3 Day 4, D112): only users
                              // who may manage salary in this branch
                              // see the button — Auditor is read-only
                              // and Branch Manager has no `hrSalary`.
                              canEdit: canManageSalary(
                                user,
                                row.employee.branchId,
                              ),
                              onEdit: () async {
                                final saved =
                                    await showSalaryEditDialog(
                                      context,
                                      ref,
                                      employee: row.employee,
                                      month: _month,
                                      record: row.record,
                                    );
                                if (saved != null && context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        'Saved ${row.employee.name} — '
                                        'net ${formatPkr(saved.netMinor)} '
                                        'for ${salaryMonthLabel(_month)}.',
                                      ),
                                    ),
                                  );
                                }
                              },
                            ),
                          const SizedBox(height: 8),
                          Text(
                            'All amounts are monthly, in PKR. '
                            'Net = base + allowances − deductions.',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ],
                    );
                  },
                );
              },
            ),
          ],
        ],
      ),
    );
  }
}

/// Monthly totals card: net total first, then the parts.
class _TotalsCard extends StatelessWidget {
  const _TotalsCard({required this.totals, required this.month});

  final MonthlySalaryTotals totals;
  final String month;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PharmaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Monthly total — ${salaryMonthLabel(month)}',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${totals.recordedCount} of ${totals.employeeCount} staff '
            'have a record for this month.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 24,
            runSpacing: 12,
            children: [
              _TotalItem(label: 'Total net', value: totals.netMinor, bold: true),
              _TotalItem(label: 'Base', value: totals.baseMinor),
              _TotalItem(
                label: 'Allowances',
                value: totals.allowancesMinor,
              ),
              _TotalItem(
                label: 'Deductions',
                value: totals.deductionsMinor,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TotalItem extends StatelessWidget {
  const _TotalItem({
    required this.label,
    required this.value,
    this.bold = false,
  });

  final String label;
  final int value;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.textTheme.bodySmall),
        Text(
          formatPkr(value),
          style: (bold
                  ? theme.textTheme.titleLarge
                  : theme.textTheme.titleMedium)
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
      ],
    );
  }
}

/// One employee's salary row: name + job title, then the month's
/// figures (or "no record" when none exists for the month). When
/// [canEdit] is true an Edit button opens the salary edit dialog
/// (Week 3 Day 4, D112); otherwise the row is display-only.
class _SalaryRowCard extends StatelessWidget {
  const _SalaryRowCard({
    required this.row,
    required this.month,
    this.canEdit = false,
    this.onEdit,
  });

  final SalaryRow row;
  final String month;
  final bool canEdit;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final record = row.record;
    final branchName = demoBranches
        .where((b) => b.id == row.employee.branchId)
        .firstOrNull
        ?.name ?? row.employee.branchId;
    return PharmaCard(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            CircleAvatar(
              radius: 24,
              backgroundColor: theme.colorScheme.primary.withValues(
                alpha: 0.12,
              ),
              child: Text(
                row.employee.name.isEmpty
                    ? '?'
                    : row.employee.name[0].toUpperCase(),
                style: TextStyle(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w700,
                  fontSize: 18,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Week 8 Day 2 (D177): a Wrap, not a Row (the
                  // D170 branches pattern) — at 390px the name
                  // column is squeezed by the net-amount text and
                  // the edit action, so name + Demo badge
                  // overflowed in the test font. The badge flows
                  // below the name when they do not fit beside it;
                  // the name wraps instead of ellipsizing.
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        row.employee.name,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (record != null && record.isDemo)
                        const StatusBadge(
                          label: 'Demo',
                          kind: StatusKind.neutral,
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${row.employee.jobTitle.isEmpty ? '—' : row.employee.jobTitle} • $branchName',
                    style: theme.textTheme.bodyMedium,
                  ),
                  Text(
                    record == null
                        ? 'No salary record for ${salaryMonthLabel(month)}.'
                        : 'Base ${formatPkr(record.baseSalaryMinor)} • '
                            'Allowances ${formatPkr(record.allowancesMinor)} • '
                            'Deductions ${formatPkr(record.deductionsMinor)}',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // Week 8 Day 2 (D177): the net amount scales down
            // instead of overflowing — at 390px the avatar + net +
            // edit button are wider than the card in the test font
            // (up to 20px). The figure stays complete, never
            // ellipsized; on a real phone it fits at full size and
            // renders unchanged.
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 150),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: Text(
                  record == null ? '—' : formatPkr(record.netMinor),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            if (canEdit) ...[
              const SizedBox(width: 4),
              IconButton(
                icon: const Icon(Icons.edit_outlined),
                tooltip: record == null
                    ? 'Set salary for ${salaryMonthLabel(month)}'
                    : 'Edit salary for ${salaryMonthLabel(month)}',
                onPressed: onEdit,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
