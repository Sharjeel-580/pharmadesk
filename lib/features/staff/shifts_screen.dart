import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/branch_context.dart';
import '../../core/widgets/design_system.dart';
import '../../models/shift.dart';
import '../../models/staff.dart';
import '../authentication/auth_state.dart';
import 'hr_logic.dart';
import 'staff_provider.dart';

/// Shift planner (Week 2 Day 5, SRS §3.7 shifts, D-23).
///
/// Route `/staff/shifts`.
///
/// Shifts at the branch with their assigned staff; create a shift
/// (name, start/end `HH:MM`, assigned staff) or edit one. Shifts
/// end after they start on the same day — overnight shifts are out
/// of scope (D89). Managing shifts needs the `hrAttendance`
/// capability (Owner / HO Admin / own Branch Mgr).
class ShiftsScreen extends ConsumerWidget {
  const ShiftsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shiftsAsync = ref.watch(shiftsProvider);
    final shifts = ref.watch(branchShiftsProvider);
    final staff = ref.watch(staffProvider).asData?.value ?? const [];
    final user = ref.watch(authProvider);
    final branch = ref.watch(activeBranchProvider);
    final mayManage = canManageHr(user, branch.id);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            title: 'Shifts — ${branch.name}',
            subtitle: '${shifts.length} shift(s) at this branch',
            actionLabel: 'New shift',
            actionIcon: Icons.add_outlined,
            onAction: mayManage
                ? () => _showShiftDialog(context, ref, null)
                : null,
          ),
          const SizedBox(height: 8),
          if (!mayManage)
            Text(
              'You can view shifts. Creating or editing them needs the '
              '"HR: attendance, shifts" permission (SRS §5.1) — Owner, '
              'HO Admin, or your own Branch Manager.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          const SizedBox(height: 16),
          shiftsAsync.when(
            loading: () => const SkeletonList(count: 3),
            error: (error, _) => PharmaEmptyState(
              icon: Icons.error_outline,
              title: 'Shifts could not load',
              message: 'The demo data failed to load. Try again.',
              actionLabel: 'Retry',
              onAction: () => ref.invalidate(shiftsProvider),
            ),
            data: (_) {
              if (shifts.isEmpty) {
                return const PharmaCard(
                  child: Text('No shifts at this branch yet.'),
                );
              }
              return Column(
                children: [
                  for (final shift in shifts)
                    _ShiftCard(
                      shift: shift,
                      staffById: {for (final m in staff) m.id: m},
                      mayManage: mayManage,
                      onEdit: () =>
                          _showShiftDialog(context, ref, shift),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Future<void> _showShiftDialog(
    BuildContext context,
    WidgetRef ref,
    Shift? shift,
  ) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => _ShiftFormDialog(shift: shift),
    );
    if (saved == true && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            shift == null ? 'Shift created.' : 'Shift updated.',
          ),
        ),
      );
    }
  }
}

class _ShiftCard extends StatelessWidget {
  const _ShiftCard({
    required this.shift,
    required this.staffById,
    required this.mayManage,
    required this.onEdit,
  });

  final Shift shift;
  final Map<String, Staff> staffById;
  final bool mayManage;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final assigned = shift.employeeIds
        .map((id) => staffById[id]?.name ?? id)
        .toList();
    return PharmaCard(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    shift.name,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${shift.startTime} – ${shift.endTime}'
                    '${shift.duration == null ? '' : ' • ${shift.duration!.inHours}h ${shift.duration!.inMinutes % 60}m'}',
                    style: theme.textTheme.bodyMedium,
                  ),
                  Text(
                    assigned.isEmpty
                        ? 'Nobody assigned yet.'
                        : 'Assigned: ${assigned.join(', ')}',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            PharmaButton(
              label: 'Edit',
              variant: PharmaButtonVariant.secondary,
              size: PharmaButtonSize.small,
              onPressed: mayManage ? onEdit : null,
            ),
          ],
        ),
      ),
    );
  }
}

class _ShiftFormDialog extends ConsumerStatefulWidget {
  const _ShiftFormDialog({this.shift});

  final Shift? shift;

  @override
  ConsumerState<_ShiftFormDialog> createState() => _ShiftFormDialogState();
}

class _ShiftFormDialogState extends ConsumerState<_ShiftFormDialog> {
  late final _name = TextEditingController(text: widget.shift?.name ?? '');
  late final _start = TextEditingController(
    text: widget.shift?.startTime ?? '09:00',
  );
  late final _end = TextEditingController(
    text: widget.shift?.endTime ?? '17:00',
  );
  late final Set<String> _assigned = {...?widget.shift?.employeeIds};
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _start.dispose();
    _end.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final branchId =
        widget.shift?.branchId ?? ref.read(activeBranchProvider).id;
    setState(() => _saving = true);
    if (widget.shift == null) {
      final result = await ref
          .read(shiftsProvider.notifier)
          .createShift(
            name: _name.text,
            startTime: _start.text,
            endTime: _end.text,
            branchId: branchId,
            employeeIds: _assigned.toList(),
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
        .read(shiftsProvider.notifier)
        .updateShift(
          widget.shift!.copyWith(
            name: _name.text.trim(),
            startTime: _start.text.trim(),
            endTime: _end.text.trim(),
            employeeIds: _assigned.toList(),
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
    final isNew = widget.shift == null;
    final branchId =
        widget.shift?.branchId ?? ref.watch(activeBranchProvider).id;
    final staff = ref.watch(staffProvider).asData?.value ?? const [];
    final branchStaff = staff
        .where((m) => m.branchId == branchId && m.active)
        .toList();
    return AlertDialog(
      title: Text(isNew ? 'New shift' : 'Edit ${widget.shift!.name}'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error != null) ...[
              PharmaErrorBox(errors: [_error!]),
              const SizedBox(height: 12),
            ],
            PharmaTextField(controller: _name, label: 'Shift name'),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: PharmaTextField(
                    controller: _start,
                    label: 'Start (HH:MM)',
                    hintText: '09:00',
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: PharmaTextField(
                    controller: _end,
                    label: 'End (HH:MM)',
                    hintText: '17:00',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'Assign staff',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            if (branchStaff.isEmpty)
              const Text('No active staff at this branch yet.')
            else
              for (final member in branchStaff)
                CheckboxListTile(
                  title: Text(member.name),
                  subtitle: Text(member.jobTitle),
                  value: _assigned.contains(member.id),
                  onChanged: (checked) => setState(() {
                    if (checked == true) {
                      _assigned.add(member.id);
                    } else {
                      _assigned.remove(member.id);
                    }
                  }),
                  contentPadding: EdgeInsets.zero,
                ),
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
          label: isNew ? 'Create' : 'Save',
          size: PharmaButtonSize.small,
          loading: _saving,
          onPressed: _save,
        ),
      ],
    );
  }
}
