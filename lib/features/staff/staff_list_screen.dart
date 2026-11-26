import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/data/auth_repository.dart';
import '../../core/data/permission_service.dart';
import '../../core/services/branch_context.dart';
import '../../core/widgets/design_system.dart';
import '../../models/staff.dart';
import '../authentication/auth_state.dart';
import '../settings/roles_permissions.dart';
import 'hr_logic.dart';
import 'salary_logic.dart';
import 'staff_provider.dart';

/// Staff directory (Week 2 Day 5, SRS §3.7 employees, D-22).
///
/// Route `/staff`.
///
/// Branch-scoped directory (head office sees all branches):
/// search by name / job title / phone / role, add / edit staff
/// (name, phone, job title, email, branch, SRS role), deactivate /
/// reactivate. Role assignment uses the 10 SRS §5.1 roles and is
/// enforced through the Day 3 permission service — the `users`
/// capability (Owner / HO Admin allowed, Branch Mgr own, Auditor
/// read-only). A user without it sees the directory read-only, with
/// the reason stated on screen.
class StaffListScreen extends ConsumerStatefulWidget {
  const StaffListScreen({super.key});

  @override
  ConsumerState<StaffListScreen> createState() => _StaffListScreenState();
}

class _StaffListScreenState extends ConsumerState<StaffListScreen> {
  String _query = '';
  String? _branchId; // null = all branches (head office only)

  @override
  void initState() {
    super.initState();
    _branchId = ref.read(activeBranchProvider).id;
  }

  @override
  Widget build(BuildContext context) {
    final staffAsync = ref.watch(staffProvider);
    final user = ref.watch(authProvider);
    final canSeeAll =
        user == null ||
        permissionService.permissionFor(user, 'allBranches') ==
            RolePermission.allowed ||
        permissionService.permissionFor(user, 'allBranches') ==
            RolePermission.readOnly;
    final effectiveBranch = _branchId;
    final mayManage = effectiveBranch == null
        ? canManageStaff(user, ref.read(activeBranchProvider).id)
        : canManageStaff(user, effectiveBranch);
    final mayViewSalary = effectiveBranch == null
        ? canViewSalary(user, ref.read(activeBranchProvider).id)
        : canViewSalary(user, effectiveBranch);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            title: 'Staff & HR',
            subtitle: 'Staff directory — ${staffAsync.asData?.value.length ?? 0} staff members',
            actionLabel: 'Add staff',
            actionIcon: Icons.person_add_outlined,
            onAction: mayManage
                ? () => _showStaffDialog(context, ref, null)
                : null,
          ),
          const SizedBox(height: 16),
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
              SizedBox(
                width: 280,
                child: PharmaTextField(
                  label: 'Search staff',
                  hintText: 'Name, job title, phone or role',
                  onChanged: (value) => setState(() => _query = value),
                ),
              ),
              ActionChip(
                avatar: const Icon(Icons.calendar_today_outlined, size: 18),
                label: const Text('Attendance'),
                onPressed: () => context.go('/staff/attendance'),
              ),
              ActionChip(
                avatar: const Icon(Icons.schedule_outlined, size: 18),
                label: const Text('Shifts'),
                onPressed: () => context.go('/staff/shifts'),
              ),
              // Salary (Week 3 Day 2, D102): only for users who may
              // view salary figures in this branch (`hrSalary`).
              if (mayViewSalary)
                ActionChip(
                  avatar: const Icon(Icons.payments_outlined, size: 18),
                  label: const Text('Salary'),
                  onPressed: () => context.go('/staff/salary'),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (!mayManage)
            Text(
              'You can view the directory. Adding or editing staff needs '
              'the "Manage users & roles" permission (SRS §5.1) — Owner, '
              'HO Admin, or your own Branch Manager.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          const SizedBox(height: 16),
          staffAsync.when(
            loading: () => const SkeletonList(count: 4),
            error: (error, _) => PharmaEmptyState(
              icon: Icons.error_outline,
              title: 'Staff could not load',
              message: 'The demo data failed to load. Try again.',
              actionLabel: 'Retry',
              onAction: () => ref.invalidate(staffProvider),
            ),
            data: (staff) {
              final scoped = effectiveBranch == null
                  ? staff
                  : staff
                        .where((m) => m.branchId == effectiveBranch)
                        .toList();
              final filtered = searchStaff(scoped, query: _query);
              if (filtered.isEmpty) {
                return const PharmaCard(
                  child: Text('No staff match this search.'),
                );
              }
              return Column(
                children: [
                  for (final member in filtered)
                    _StaffCard(
                      member: member,
                      mayManage: mayManage,
                      onEdit: () =>
                          _showStaffDialog(context, ref, member),
                      onToggleActive: () => _toggleActive(member),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Future<void> _toggleActive(Staff member) async {
    final result = await ref
        .read(staffProvider.notifier)
        .updateStaff(member.copyWith(active: !member.active));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.error ??
              (member.active
                  ? '${member.name} deactivated.'
                  : '${member.name} reactivated.'),
        ),
      ),
    );
  }

  Future<void> _showStaffDialog(
    BuildContext context,
    WidgetRef ref,
    Staff? member,
  ) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => _StaffFormDialog(member: member),
    );
    if (saved == true && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            member == null
                ? 'Staff member added.'
                : 'Staff member updated.',
          ),
        ),
      );
    }
  }
}

class _StaffCard extends StatelessWidget {
  const _StaffCard({
    required this.member,
    required this.mayManage,
    required this.onEdit,
    required this.onToggleActive,
  });

  final Staff member;
  final bool mayManage;
  final VoidCallback onEdit;
  final VoidCallback onToggleActive;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final branchName = demoBranches
        .where((b) => b.id == member.branchId)
        .firstOrNull
        ?.name ?? member.branchId;
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
                member.name.isEmpty ? '?' : member.name[0].toUpperCase(),
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
                  // column is only ~77px wide (the Edit /
                  // Deactivate column takes the rest), so name +
                  // badge overflowed by 35px in the test font. The
                  // badge flows below the name when they do not fit
                  // beside it; the name wraps instead of
                  // ellipsizing. On desktop they still sit on one
                  // line.
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        member.name,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      StatusBadge(
                        label: member.active ? 'Active' : 'Inactive',
                        kind: member.active
                            ? StatusKind.success
                            : StatusKind.neutral,
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${member.jobTitle.isEmpty ? '—' : member.jobTitle} • '
                    '${roleDisplayName(member.effectiveRoleKey)}',
                    style: theme.textTheme.bodyMedium,
                  ),
                  Text(
                    '${member.phone} • $branchName',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                PharmaButton(
                  label: 'Edit',
                  variant: PharmaButtonVariant.secondary,
                  size: PharmaButtonSize.small,
                  onPressed: mayManage ? onEdit : null,
                ),
                const SizedBox(height: 4),
                TextButton(
                  onPressed: mayManage ? onToggleActive : null,
                  child: Text(
                    member.active ? 'Deactivate' : 'Reactivate',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StaffFormDialog extends ConsumerStatefulWidget {
  const _StaffFormDialog({this.member});

  final Staff? member;

  @override
  ConsumerState<_StaffFormDialog> createState() => _StaffFormDialogState();
}

class _StaffFormDialogState extends ConsumerState<_StaffFormDialog> {
  late final _name = TextEditingController(text: widget.member?.name ?? '');
  late final _email = TextEditingController(
    text: widget.member?.email ?? '',
  );
  late final _phone = TextEditingController(
    text: widget.member?.phone ?? '',
  );
  late final _jobTitle = TextEditingController(
    text: widget.member?.jobTitle ?? '',
  );
  late String _branchId =
      widget.member?.branchId ?? demoBranches.first.id;
  late String? _roleKey =
      widget.member?.roleKey ?? widget.member?.effectiveRoleKey;
  late bool _active = widget.member?.active ?? true;
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _phone.dispose();
    _jobTitle.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    if (widget.member == null) {
      final result = await ref
          .read(staffProvider.notifier)
          .addStaff(
            name: _name.text,
            email: _email.text,
            phone: _phone.text,
            jobTitle: _jobTitle.text,
            branchId: _branchId,
            roleKey: _roleKey,
            role: staffRoleForRoleKey(_roleKey),
          );
      if (!mounted) return;
      setState(() => _saving = false);
      if (result.error != null) {
        setState(() => _error = result.error);
        return;
      }
      Navigator.of(context).pop(true);
      return;
    }
    final result = await ref
        .read(staffProvider.notifier)
        .updateStaff(
          widget.member!.copyWith(
            name: _name.text.trim(),
            email: _email.text.trim(),
            phone: _phone.text.trim(),
            jobTitle: _jobTitle.text.trim(),
            branchId: _branchId,
            roleKey: _roleKey,
            role: staffRoleForRoleKey(_roleKey),
            active: _active,
          ),
        );
    if (!mounted) return;
    setState(() => _saving = false);
    if (!result.ok) {
      setState(() => _error = result.error);
      return;
    }
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.member == null;
    return AlertDialog(
      title: Text(isNew ? 'Add staff member' : 'Edit ${widget.member!.name}'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error != null) ...[
              PharmaErrorBox(errors: [_error!]),
              const SizedBox(height: 12),
            ],
            PharmaTextField(controller: _name, label: 'Full name'),
            const SizedBox(height: 12),
            PharmaTextField(
              controller: _jobTitle,
              label: 'Job title',
              hintText: 'e.g. Senior Pharmacist',
            ),
            const SizedBox(height: 12),
            PharmaTextField(
              controller: _phone,
              label: 'Phone',
              keyboardType: TextInputType.phone,
            ),
            const SizedBox(height: 12),
            PharmaTextField(
              controller: _email,
              label: 'Email (optional)',
              keyboardType: TextInputType.emailAddress,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _branchId,
              decoration: const InputDecoration(labelText: 'Branch'),
              items: [
                for (final branch in demoBranches)
                  DropdownMenuItem<String>(
                    value: branch.id,
                    child: Text(branch.name),
                  ),
              ],
              onChanged: (selected) {
                if (selected != null) setState(() => _branchId = selected);
              },
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String?>(
              initialValue: _roleKey,
              decoration: const InputDecoration(
                labelText: 'Role (SRS §5.1)',
              ),
              items: [
                for (final key in srsRoleKeys)
                  DropdownMenuItem<String?>(
                    value: key,
                    child: Text(roleDisplayName(key)),
                  ),
              ],
              onChanged: (selected) =>
                  setState(() => _roleKey = selected),
            ),
            const SizedBox(height: 4),
            const Text(
              'The role decides what this person may do — the permission '
              'matrix (Settings → Roles & Permissions) enforces it.',
              style: TextStyle(fontSize: 12),
            ),
            if (!isNew) ...[
              const SizedBox(height: 12),
              SwitchListTile(
                title: const Text('Active'),
                subtitle: const Text(
                  'Inactive staff cannot check in and leave the '
                  'attendance view.',
                ),
                value: _active,
                onChanged: (value) => setState(() => _active = value),
                contentPadding: EdgeInsets.zero,
              ),
            ],
          ],
        ),
      ),
      actions: [
        PharmaButton(
          label: 'Cancel',
          variant: PharmaButtonVariant.text,
          size: PharmaButtonSize.small,
          onPressed: () => Navigator.of(context).pop(false),
        ),
        PharmaButton(
          label: isNew ? 'Add' : 'Save',
          size: PharmaButtonSize.small,
          loading: _saving,
          onPressed: _save,
        ),
      ],
    );
  }
}
