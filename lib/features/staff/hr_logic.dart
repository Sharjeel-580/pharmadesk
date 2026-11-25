import '../../core/data/auth_repository.dart';
import '../../core/data/permission_service.dart';
import '../../models/attendance.dart';
import '../../models/shift.dart';
import '../../models/staff.dart';
import '../customers/customer_logic.dart' show normalizePhoneDigits;

/// Week 2 Day 5 staff & HR logic — pure functions over plain lists.
///
/// Permissions come from the SRS §5.1 matrix via the Day 3
/// permission service (D70): staff CRUD / role assignment is the
/// `users` capability, attendance + shifts is `hrAttendance`.
/// Nobody assumes a role from a job title — the matrix governs.
/// The 10 SRS role keys live in `auth_repository.dart`
/// ([srsRoleKeys]) — the same list the claims mapping uses.

/// Maps an SRS role key onto the legacy [StaffRole] vocabulary
/// (D19) the [Staff] model still carries: pharmacist → pharmacist,
/// owner → owner, everything else → counter. The SRS [roleKey] is
/// what the permission service enforces; this mapping only keeps
/// the legacy field plausible.
StaffRole staffRoleForRoleKey(String? roleKey) => switch (roleKey) {
  'pharmacist' => StaffRole.pharmacist,
  'owner' => StaffRole.owner,
  _ => StaffRole.counter,
};

/// True when [user] may manage staff (create / edit / role-assign /
/// deactivate) in [branchId] — the `users` capability: Super Admin
/// allowed, Owner allowed, HO Admin allowed, Branch Mgr own,
/// Auditor read-only, everyone else none.
bool canManageStaff(AppUser? user, String branchId) =>
    permissionService.canWrite(user, 'users', branchId);

/// True when [user] may record attendance / manage shifts in
/// [branchId] — the `hrAttendance` capability: Owner allowed, HO
/// Admin allowed, Branch Mgr own, Auditor read-only, everyone else
/// none.
bool canManageHr(AppUser? user, String branchId) =>
    permissionService.canWrite(user, 'hrAttendance', branchId);

/// Validates a staff record before saving. Returns the list of
/// problems (empty = valid). [existingPhones] are the directory's
/// phones (excluding the record being edited — the caller passes
/// the others); a duplicate number (digits compared) is rejected.
/// [roleKey] must be one of the 10 SRS role keys when given.
List<String> validateStaff({
  required String name,
  required String phone,
  required String jobTitle,
  String? roleKey,
  String? email,
  List<String> existingPhones = const [],
}) {
  final errors = <String>[];
  if (name.trim().isEmpty) {
    errors.add('Staff name is required.');
  }
  if (jobTitle.trim().isEmpty) {
    errors.add('Job title is required.');
  }
  final digits = normalizePhoneDigits(phone);
  if (digits.isEmpty) {
    errors.add('Phone number is required.');
  } else if (digits.length < 10) {
    errors.add('Phone number looks too short (need at least 10 digits).');
  }
  if (digits.isNotEmpty &&
      existingPhones.any(
        (existing) => normalizePhoneDigits(existing) == digits,
      )) {
    errors.add('A staff member with this phone number already exists.');
  }
  if (email != null && email.trim().isNotEmpty && !email.contains('@')) {
    errors.add('Email address does not look valid.');
  }
  if (roleKey != null && !srsRoleKeys.contains(roleKey)) {
    errors.add('Unknown role "$roleKey". Pick one of the 10 SRS roles.');
  }
  return errors;
}

/// Searches the staff directory by name, job title, phone or role
/// label. An empty query returns the whole directory.
List<Staff> searchStaff(List<Staff> staff, {String query = ''}) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return staff.toList();
  final queryDigits = normalizePhoneDigits(query);
  return staff.where((member) {
    if (member.name.toLowerCase().contains(needle)) return true;
    if (member.jobTitle.toLowerCase().contains(needle)) return true;
    if (roleDisplayName(
      member.effectiveRoleKey,
    ).toLowerCase().contains(needle)) {
      return true;
    }
    if (queryDigits.isEmpty) return false;
    return normalizePhoneDigits(member.phone).contains(queryDigits);
  }).toList();
}

/// Validates a shift before saving. Times are `HH:MM`; the end
/// must be after the start on the same day (overnight shifts are
/// out of scope — D89). At least one employee must be assigned.
List<String> validateShift({
  required String name,
  required String startTime,
  required String endTime,
  List<String> employeeIds = const [],
}) {
  final errors = <String>[];
  if (name.trim().isEmpty) {
    errors.add('Shift name is required.');
  }
  final start = shiftTimeToMinutes(startTime);
  final end = shiftTimeToMinutes(endTime);
  if (start == null) {
    errors.add('Start time must look like HH:MM (e.g. 09:00).');
  }
  if (end == null) {
    errors.add('End time must look like HH:MM (e.g. 17:00).');
  }
  if (start != null && end != null && end <= start) {
    errors.add(
      'End time must be after the start time on the same day — '
      'overnight shifts are not supported yet.',
    );
  }
  if (employeeIds.isEmpty) {
    errors.add('Assign at least one staff member to the shift.');
  }
  return errors;
}

/// Grace period after a shift's start before a check-in counts as
/// late: 15 minutes (D89 — a documented demo rule, not an SRS
/// figure; the SRS gives no grace period).
const attendanceLateGraceMinutes = 15;

/// Derives the attendance status from a check-in / check-out pair
/// against the shift the employee is on.
///
/// - No check-in: `absent` (used only when a manager marks the day;
///   check-in itself never produces it).
/// - Checked in after shift start + grace: `late`, kept at
///   check-out.
/// - Worked under 4 hours: `halfDay` (unless already late — late
///   wins, it is the more useful signal).
/// - Otherwise `present`.
/// A null [shiftStartMinutes] (no shift assigned) means on-time:
/// any check-in counts as present.
AttendanceStatus attendanceStatusFor({
  required DateTime? checkIn,
  required DateTime? checkOut,
  int? shiftStartMinutes,
}) {
  if (checkIn == null) return AttendanceStatus.absent;
  var status = AttendanceStatus.present;
  if (shiftStartMinutes != null) {
    final checkInMinutes = checkIn.hour * 60 + checkIn.minute;
    if (checkInMinutes >
        shiftStartMinutes + attendanceLateGraceMinutes) {
      status = AttendanceStatus.late;
    }
  }
  if (status == AttendanceStatus.present && checkOut != null) {
    final worked = checkOut.difference(checkIn);
    if (worked < const Duration(hours: 4)) {
      status = AttendanceStatus.halfDay;
    }
  }
  return status;
}

/// Validates a check-in. Returns the list of problems (empty =
/// valid): one check-in per employee per day, and the employee must
/// be active.
List<String> validateCheckIn({
  required Staff employee,
  required List<Attendance> todaysRecords,
  required DateTime now,
}) {
  final errors = <String>[];
  if (!employee.active) {
    errors.add('${employee.name} is inactive and cannot check in.');
  }
  final day = DateTime(now.year, now.month, now.day);
  final existing = todaysRecords.where(
    (record) =>
        record.employeeId == employee.id &&
        record.date.year == day.year &&
        record.date.month == day.month &&
        record.date.day == day.day,
  );
  if (existing.any((record) => record.checkIn != null)) {
    errors.add('${employee.name} has already checked in today.');
  }
  return errors;
}

/// Validates a check-out: there must be an open (checked-in, not
/// yet checked-out) record for the employee today, and the
/// check-out time must be after check-in.
List<String> validateCheckOut({
  required Attendance? openRecord,
  required DateTime now,
}) {
  final errors = <String>[];
  if (openRecord == null) {
    errors.add('No check-in found for today — check in first.');
    return errors;
  }
  if (openRecord.checkIn != null && !now.isAfter(openRecord.checkIn!)) {
    errors.add('Check-out must be after check-in.');
  }
  return errors;
}

/// One row of the "today's attendance" view: the employee, their
/// shift (if any), and today's record (if any).
class TodayAttendanceRow {
  const TodayAttendanceRow({
    required this.employee,
    this.shift,
    this.record,
  });

  final Staff employee;
  final Shift? shift;
  final Attendance? record;

  /// Display status for the row: the record's status when one
  /// exists, else "Not checked in".
  String get displayStatus => record == null
      ? 'Not checked in'
      : attendanceStatusLabel(record!.status);
}

/// Builds today's attendance view for [branchId]: one row per
/// active staff member at the branch (head office sees all
/// branches when [branchId] is null), each with their shift and
/// today's record.
List<TodayAttendanceRow> todaysAttendance({
  required List<Staff> staff,
  required List<Attendance> records,
  required List<Shift> shifts,
  required DateTime now,
  String? branchId,
}) {
  final day = DateTime(now.year, now.month, now.day);
  final scopedStaff = staff
      .where(
        (member) =>
            member.active &&
            (branchId == null || member.branchId == branchId),
      )
      .toList();
  final todaysRecords = records.where(
    (record) =>
        record.date.year == day.year &&
        record.date.month == day.month &&
        record.date.day == day.day,
  );
  Shift? shiftFor(String employeeId) {
    for (final shift in shifts) {
      if (shift.employeeIds.contains(employeeId)) return shift;
    }
    return null;
  }

  return scopedStaff.map((member) {
    final record = todaysRecords
        .where((r) => r.employeeId == member.id)
        .firstOrNull;
    return TodayAttendanceRow(
      employee: member,
      shift: shiftFor(member.id),
      record: record,
    );
  }).toList();
}

/// Counts per status across today's rows, for the attendance
/// screen's summary chips.
Map<String, int> todayAttendanceCounts(List<TodayAttendanceRow> rows) {
  final counts = <String, int>{
    'Present': 0,
    'Late': 0,
    'Half day': 0,
    'Not checked in': 0,
  };
  for (final row in rows) {
    final key = row.displayStatus;
    counts[key] = (counts[key] ?? 0) + 1;
  }
  return counts;
}
