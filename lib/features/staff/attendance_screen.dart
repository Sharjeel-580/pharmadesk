import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/services/branch_context.dart';
import '../../core/widgets/design_system.dart';
import '../../models/attendance.dart';
import '../../models/staff.dart';
import '../authentication/auth_state.dart';
import 'hr_logic.dart';
import 'staff_provider.dart';

/// Today's attendance (Week 2 Day 5, SRS §3.7 attendances, D-23).
///
/// Route `/staff/attendance`.
///
/// One row per active staff member at the branch: shift, check-in /
/// check-out times, status, and Check in / Check out buttons.
/// Check-in after the shift start + 15 minutes counts as Late;
/// under 4 hours worked counts as Half day (D89). A manager can
/// also mark a day Absent / On leave. Recording needs the
/// `hrAttendance` capability (Owner / HO Admin / own Branch Mgr);
/// anyone else sees the view read-only with the reason stated.
class AttendanceScreen extends ConsumerWidget {
  const AttendanceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rowsAsync = ref.watch(attendanceProvider);
    final rows = ref.watch(todayAttendanceProvider);
    final user = ref.watch(authProvider);
    final branch = ref.watch(activeBranchProvider);
    final mayManage = canManageHr(user, branch.id);
    final counts = todayAttendanceCounts(rows);
    final now = DateTime.now();
    final dateLabel = '${now.day}/${now.month}/${now.year}';
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            title: 'Attendance — $dateLabel',
            subtitle: '${branch.name} • ${rows.length} active staff',
            actionLabel: 'Staff directory',
            actionIcon: Icons.people_outline,
            onAction: () => context.go('/staff'),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              SizedBox(
                width: 180,
                child: StatCard(
                  label: 'Present',
                  value: '${counts['Present'] ?? 0}',
                  icon: Icons.check_circle_outline,
                ),
              ),
              SizedBox(
                width: 180,
                child: StatCard(
                  label: 'Late',
                  value: '${counts['Late'] ?? 0}',
                  icon: Icons.schedule_outlined,
                ),
              ),
              SizedBox(
                width: 180,
                child: StatCard(
                  label: 'Half day',
                  value: '${counts['Half day'] ?? 0}',
                  icon: Icons.timelapse_outlined,
                ),
              ),
              SizedBox(
                width: 180,
                child: StatCard(
                  label: 'Not checked in',
                  value: '${counts['Not checked in'] ?? 0}',
                  icon: Icons.person_off_outlined,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (!mayManage)
            Text(
              'You can view attendance. Recording check-in / check-out '
              'needs the "HR: attendance, shifts" permission (SRS §5.1) '
              '— Owner, HO Admin, or your own Branch Manager.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          const SizedBox(height: 16),
          rowsAsync.when(
            loading: () => const SkeletonList(count: 4),
            error: (error, _) => PharmaEmptyState(
              icon: Icons.error_outline,
              title: 'Attendance could not load',
              message: 'The demo data failed to load. Try again.',
              actionLabel: 'Retry',
              onAction: () => ref.invalidate(attendanceProvider),
            ),
            data: (_) {
              if (rows.isEmpty) {
                return const PharmaCard(
                  child: Text('No active staff at this branch yet.'),
                );
              }
              return Column(
                children: [
                  for (final row in rows)
                    _AttendanceRowCard(
                      row: row,
                      mayManage: mayManage,
                      onCheckIn: () => _checkIn(context, ref, row.employee),
                      onCheckOut: () =>
                          _checkOut(context, ref, row.employee),
                      onMark: (status) =>
                          _markDay(context, ref, row.employee, status),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Future<void> _checkIn(
    BuildContext context,
    WidgetRef ref,
    Staff employee,
  ) async {
    final result = await ref
        .read(attendanceProvider.notifier)
        .checkIn(employee: employee);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.error ?? '${employee.name} checked in.',
        ),
      ),
    );
  }

  Future<void> _checkOut(
    BuildContext context,
    WidgetRef ref,
    Staff employee,
  ) async {
    final result = await ref
        .read(attendanceProvider.notifier)
        .checkOut(employee: employee);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.error ??
              '${employee.name} checked out — '
                  '${attendanceStatusLabel(result.record!.status)}.',
        ),
      ),
    );
  }

  Future<void> _markDay(
    BuildContext context,
    WidgetRef ref,
    Staff employee,
    AttendanceStatus status,
  ) async {
    final result = await ref
        .read(attendanceProvider.notifier)
        .markDay(
          employee: employee,
          status: status,
          date: DateTime.now(),
        );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.error ??
              '${employee.name} marked ${attendanceStatusLabel(status).toLowerCase()}.',
        ),
      ),
    );
  }
}

class _AttendanceRowCard extends StatelessWidget {
  const _AttendanceRowCard({
    required this.row,
    required this.mayManage,
    required this.onCheckIn,
    required this.onCheckOut,
    required this.onMark,
  });

  final TodayAttendanceRow row;
  final bool mayManage;
  final VoidCallback onCheckIn;
  final VoidCallback onCheckOut;
  final ValueChanged<AttendanceStatus> onMark;

  String _timeText(DateTime? time) => time == null
      ? '—'
      : '${time.hour.toString().padLeft(2, '0')}:'
            '${time.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final record = row.record;
    final kind = switch (row.displayStatus) {
      'Present' => StatusKind.success,
      'Late' => StatusKind.warning,
      'Half day' => StatusKind.info,
      'Not checked in' => StatusKind.neutral,
      _ => StatusKind.neutral,
    };
    return PharmaCard(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          row.employee.name,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      StatusBadge(label: row.displayStatus, kind: kind),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${row.employee.jobTitle} • '
                    'Shift: ${row.shift == null ? 'none assigned' : '${row.shift!.name} (${row.shift!.startTime}–${row.shift!.endTime})'}',
                    style: theme.textTheme.bodyMedium,
                  ),
                  Text(
                    'In ${_timeText(record?.checkIn)} • '
                    'Out ${_timeText(record?.checkOut)}'
                    '${record?.workedDuration == null ? '' : ' • ${record!.workedDuration!.inHours}h ${record.workedDuration!.inMinutes % 60}m worked'}',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (record == null)
              PharmaButton(
                label: 'Check in',
                size: PharmaButtonSize.small,
                onPressed: mayManage ? onCheckIn : null,
              )
            else if (record.isOpen)
              PharmaButton(
                label: 'Check out',
                variant: PharmaButtonVariant.secondary,
                size: PharmaButtonSize.small,
                onPressed: mayManage ? onCheckOut : null,
              )
            else
              const Text('Done for today'),
            if (record == null) ...[
              const SizedBox(width: 8),
              PopupMenuButton<AttendanceStatus>(
                enabled: mayManage,
                tooltip: 'Mark day',
                itemBuilder: (menuContext) => [
                  const PopupMenuItem<AttendanceStatus>(
                    value: AttendanceStatus.absent,
                    child: Text('Mark absent'),
                  ),
                  const PopupMenuItem<AttendanceStatus>(
                    value: AttendanceStatus.onLeave,
                    child: Text('Mark on leave'),
                  ),
                ],
                onSelected: onMark,
                child: const Icon(Icons.more_vert_outlined),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
