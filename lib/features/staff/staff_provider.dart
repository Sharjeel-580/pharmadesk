import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/data/auth_repository.dart';
import '../../core/services/branch_context.dart';
import '../../core/services/repositories.dart';
import '../../models/attendance.dart';
import '../../models/shift.dart';
import '../../models/staff.dart';
import '../authentication/auth_state.dart';
import 'hr_logic.dart';

/// Week 2 Day 5 staff & HR state.
///
/// [StaffDirectoryNotifier] owns the in-memory staff list; every
/// create / edit / role assignment / deactivate writes through to
/// the repository and refreshes. [AttendanceNotifier] owns the
/// attendance records (check-in / check-out / mark absent or on
/// leave). [ShiftsNotifier] owns the shifts. All writes are gated
/// on the SRS §5.1 matrix via `hr_logic.dart` (`users` for staff
/// management, `hrAttendance` for attendance + shifts) — a user
/// without the capability gets an error string, not a silent
/// no-op.

class StaffDirectoryNotifier extends AsyncNotifier<List<Staff>> {
  @override
  Future<List<Staff>> build() async {
    final repo = ref.read(staffRepositoryProvider);
    return repo.getStaff();
  }

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(
      () => ref.read(staffRepositoryProvider).getStaff(),
    );
  }

  AppUser? get _user => ref.read(authProvider);

  /// Adds a staff member after validation. Returns the saved
  /// member, or `null` member + an error message when validation,
  /// the permission check or the repository rejects it.
  Future<({Staff? staff, String? error})> addStaff({
    required String name,
    required String email,
    required String phone,
    required String jobTitle,
    required String branchId,
    String? roleKey,
    StaffRole role = StaffRole.counter,
  }) async {
    if (!canManageStaff(_user, branchId)) {
      return (staff: null, error: 'You do not have permission to add staff in this branch (SRS §5.1: users).');
    }
    final existing = state.asData?.value ?? const <Staff>[];
    final errors = validateStaff(
      name: name,
      phone: phone,
      jobTitle: jobTitle,
      roleKey: roleKey,
      email: email,
      existingPhones: existing.map((s) => s.phone).toList(),
    );
    if (errors.isNotEmpty) {
      return (staff: null, error: errors.first);
    }
    try {
      final created = await ref.read(staffRepositoryProvider).createStaff(
        Staff(
          id: '',
          name: name.trim(),
          email: email.trim(),
          role: role,
          roleKey: roleKey,
          jobTitle: jobTitle.trim(),
          phone: phone.trim(),
          branchId: branchId,
        ),
      );
      await refresh();
      return (staff: created, error: null);
    } on ArgumentError catch (error) {
      return (staff: null, error: error.message?.toString());
    }
  }

  /// Saves an edited staff member (details, branch, SRS role,
  /// active flag). Returns `false` when the member is not in the
  /// directory or the caller may not manage staff in the member's
  /// branch; the error text explains which.
  Future<({bool ok, String? error})> updateStaff(Staff staff) async {
    if (!canManageStaff(_user, staff.branchId)) {
      return (ok: false, error: 'You do not have permission to manage staff in this branch (SRS §5.1: users).');
    }
    final existing = state.asData?.value ?? const <Staff>[];
    if (!existing.any((s) => s.id == staff.id)) {
      return (ok: false, error: 'Staff member not found.');
    }
    final errors = validateStaff(
      name: staff.name,
      phone: staff.phone,
      jobTitle: staff.jobTitle,
      roleKey: staff.roleKey,
      email: staff.email,
      existingPhones: existing
          .where((s) => s.id != staff.id)
          .map((s) => s.phone)
          .toList(),
    );
    if (errors.isNotEmpty) {
      return (ok: false, error: errors.first);
    }
    try {
      await ref.read(staffRepositoryProvider).updateStaff(staff);
      await refresh();
      return (ok: true, error: null);
    } on ArgumentError catch (error) {
      return (ok: false, error: error.message?.toString());
    }
  }
}

final staffProvider =
    AsyncNotifierProvider<StaffDirectoryNotifier, List<Staff>>(
      StaffDirectoryNotifier.new,
    );

/// One staff member by id, from the directory (refreshes when it
/// does).
final staffByIdProvider = Provider.family<Staff?, String>((ref, id) {
  final staff = ref.watch(staffProvider).asData?.value ?? const [];
  for (final member in staff) {
    if (member.id == id) return member;
  }
  return null;
});

/// Staff at the active branch (the directory's default scope).
/// Head-office users switch to "All branches" on the screen.
final branchStaffProvider = Provider<List<Staff>>((ref) {
  final branch = ref.watch(activeBranchProvider);
  final staff = ref.watch(staffProvider).asData?.value ?? const [];
  return staff.where((member) => member.branchId == branch.id).toList();
});

class AttendanceNotifier extends AsyncNotifier<List<Attendance>> {
  @override
  Future<List<Attendance>> build() async {
    final repo = ref.read(attendanceRepositoryProvider);
    return repo.getAttendances();
  }

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(
      () => ref.read(attendanceRepositoryProvider).getAttendances(),
    );
  }

  AppUser? get _user => ref.read(authProvider);

  Future<Shift?> _shiftFor(String employeeId, String branchId) async {
    final shifts = await ref
        .read(shiftRepositoryProvider)
        .getShifts(branchId: branchId);
    for (final shift in shifts) {
      if (shift.employeeIds.contains(employeeId)) return shift;
    }
    return null;
  }

  /// Checks a staff member in for today. Returns the saved record,
  /// or `null` + an error message (already checked in, inactive,
  /// or no HR permission in the branch).
  Future<({Attendance? record, String? error})> checkIn({
    required Staff employee,
    DateTime? at,
  }) async {
    final now = at ?? DateTime.now();
    if (!canManageHr(_user, employee.branchId)) {
      return (record: null, error: 'You do not have permission to record attendance in this branch (SRS §5.1: HR attendance).');
    }
    final records = state.asData?.value ?? const <Attendance>[];
    final errors = validateCheckIn(
      employee: employee,
      todaysRecords: records,
      now: now,
    );
    if (errors.isNotEmpty) {
      return (record: null, error: errors.first);
    }
    final shift = await _shiftFor(employee.id, employee.branchId);
    final day = DateTime(now.year, now.month, now.day);
    final saved = await ref
        .read(attendanceRepositoryProvider)
        .upsertAttendance(
          Attendance(
            id: '',
            employeeId: employee.id,
            branchId: employee.branchId,
            date: day,
            checkIn: now,
            status: attendanceStatusFor(
              checkIn: now,
              checkOut: null,
              shiftStartMinutes: shift?.startMinutes,
            ),
          ),
        );
    await refresh();
    return (record: saved, error: null);
  }

  /// Checks a staff member out for today: closes the open record
  /// and derives the final status (present / late / half day).
  /// Returns the saved record, or `null` + an error message (no
  /// check-in today, or no HR permission in the branch).
  Future<({Attendance? record, String? error})> checkOut({
    required Staff employee,
    DateTime? at,
  }) async {
    final now = at ?? DateTime.now();
    if (!canManageHr(_user, employee.branchId)) {
      return (record: null, error: 'You do not have permission to record attendance in this branch (SRS §5.1: HR attendance).');
    }
    final records = state.asData?.value ?? const <Attendance>[];
    final day = DateTime(now.year, now.month, now.day);
    final open = records
        .where(
          (record) =>
              record.employeeId == employee.id &&
              record.date.year == day.year &&
              record.date.month == day.month &&
              record.date.day == day.day &&
              record.isOpen,
        )
        .firstOrNull;
    final errors = validateCheckOut(openRecord: open, now: now);
    if (errors.isNotEmpty) {
      return (record: null, error: errors.first);
    }
    final shift = await _shiftFor(employee.id, employee.branchId);
    final saved = await ref
        .read(attendanceRepositoryProvider)
        .upsertAttendance(
          open!.copyWith(
            checkOut: now,
            status: attendanceStatusFor(
              checkIn: open.checkIn,
              checkOut: now,
              shiftStartMinutes: shift?.startMinutes,
            ),
          ),
        );
    await refresh();
    return (record: saved, error: null);
  }

  /// Marks a day absent / on leave for a staff member (manager
  /// action — no check-in exists for that day). Returns the saved
  /// record, or `null` + an error message.
  Future<({Attendance? record, String? error})> markDay({
    required Staff employee,
    required AttendanceStatus status,
    required DateTime date,
    String note = '',
  }) async {
    if (status != AttendanceStatus.absent &&
        status != AttendanceStatus.onLeave) {
      return (record: null, error: 'Only Absent or On leave can be marked directly — Present / Late come from check-in.');
    }
    if (!canManageHr(_user, employee.branchId)) {
      return (record: null, error: 'You do not have permission to record attendance in this branch (SRS §5.1: HR attendance).');
    }
    final records = state.asData?.value ?? const <Attendance>[];
    final day = DateTime(date.year, date.month, date.day);
    final existing = records
        .where(
          (record) =>
              record.employeeId == employee.id &&
              record.date.year == day.year &&
              record.date.month == day.month &&
              record.date.day == day.day,
        )
        .firstOrNull;
    if (existing != null && existing.checkIn != null) {
      return (record: null, error: '${employee.name} already checked in on that day.');
    }
    final saved = await ref
        .read(attendanceRepositoryProvider)
        .upsertAttendance(
          (existing ??
                  Attendance(
                    id: '',
                    employeeId: employee.id,
                    branchId: employee.branchId,
                    date: day,
                  ))
              .copyWith(status: status, note: note.trim()),
        );
    await refresh();
    return (record: saved, error: null);
  }
}

final attendanceProvider =
    AsyncNotifierProvider<AttendanceNotifier, List<Attendance>>(
      AttendanceNotifier.new,
    );

/// Today's attendance rows for the active branch (one row per
/// active staff member, with shift + today's record).
final todayAttendanceProvider = Provider<List<TodayAttendanceRow>>((ref) {
  final branch = ref.watch(activeBranchProvider);
  final staff = ref.watch(staffProvider).asData?.value ?? const [];
  final records = ref.watch(attendanceProvider).asData?.value ?? const [];
  final shifts = ref.watch(shiftsProvider).asData?.value ?? const [];
  return todaysAttendance(
    staff: staff,
    records: records,
    shifts: shifts,
    now: DateTime.now(),
    branchId: branch.id,
  );
});

class ShiftsNotifier extends AsyncNotifier<List<Shift>> {
  @override
  Future<List<Shift>> build() async {
    final repo = ref.read(shiftRepositoryProvider);
    return repo.getShifts();
  }

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(
      () => ref.read(shiftRepositoryProvider).getShifts(),
    );
  }

  AppUser? get _user => ref.read(authProvider);

  /// Creates a shift after validation. Returns the saved shift, or
  /// `null` + an error message.
  Future<({Shift? shift, String? error})> createShift({
    required String name,
    required String startTime,
    required String endTime,
    required String branchId,
    List<String> employeeIds = const [],
  }) async {
    if (!canManageHr(_user, branchId)) {
      return (shift: null, error: 'You do not have permission to manage shifts in this branch (SRS §5.1: HR attendance).');
    }
    final errors = validateShift(
      name: name,
      startTime: startTime,
      endTime: endTime,
      employeeIds: employeeIds,
    );
    if (errors.isNotEmpty) {
      return (shift: null, error: errors.first);
    }
    final created = await ref.read(shiftRepositoryProvider).createShift(
      Shift(
        id: '',
        branchId: branchId,
        name: name.trim(),
        startTime: startTime.trim(),
        endTime: endTime.trim(),
        employeeIds: employeeIds,
      ),
    );
    await refresh();
    return (shift: created, error: null);
  }

  /// Saves an edited shift (name, times, assigned employees).
  /// Returns `false` + an error when the shift is missing, the
  /// validation fails, or the caller may not manage HR in the
  /// shift's branch.
  Future<({bool ok, String? error})> updateShift(Shift shift) async {
    if (!canManageHr(_user, shift.branchId)) {
      return (ok: false, error: 'You do not have permission to manage shifts in this branch (SRS §5.1: HR attendance).');
    }
    final existing = state.asData?.value ?? const <Shift>[];
    if (!existing.any((s) => s.id == shift.id)) {
      return (ok: false, error: 'Shift not found.');
    }
    final errors = validateShift(
      name: shift.name,
      startTime: shift.startTime,
      endTime: shift.endTime,
      employeeIds: shift.employeeIds,
    );
    if (errors.isNotEmpty) {
      return (ok: false, error: errors.first);
    }
    await ref.read(shiftRepositoryProvider).updateShift(shift);
    await refresh();
    return (ok: true, error: null);
  }
}

final shiftsProvider =
    AsyncNotifierProvider<ShiftsNotifier, List<Shift>>(ShiftsNotifier.new);

/// Shifts at the active branch.
final branchShiftsProvider = Provider<List<Shift>>((ref) {
  final branch = ref.watch(activeBranchProvider);
  final shifts = ref.watch(shiftsProvider).asData?.value ?? const [];
  return shifts.where((shift) => shift.branchId == branch.id).toList();
});
