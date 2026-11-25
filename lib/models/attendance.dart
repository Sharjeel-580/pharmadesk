import 'model_utils.dart';

/// Attendance status for one employee on one day (SRS §3.7
/// `branches/{branchId}/attendances`, FR-HR).
enum AttendanceStatus { present, late, absent, onLeave, halfDay }

AttendanceStatus attendanceStatusFromString(String? value) {
  switch (value) {
    case 'late':
      return AttendanceStatus.late;
    case 'absent':
      return AttendanceStatus.absent;
    case 'onLeave':
      return AttendanceStatus.onLeave;
    case 'halfDay':
      return AttendanceStatus.halfDay;
    case 'present':
    default:
      return AttendanceStatus.present;
  }
}

String attendanceStatusLabel(AttendanceStatus status) => switch (status) {
  AttendanceStatus.present => 'Present',
  AttendanceStatus.late => 'Late',
  AttendanceStatus.absent => 'Absent',
  AttendanceStatus.onLeave => 'On leave',
  AttendanceStatus.halfDay => 'Half day',
};

/// One employee's attendance for one day.
///
/// Firestore collection: `branches/{branchId}/attendances`.
/// `date` is the calendar day (time stripped). A record is created
/// by check-in and completed by check-out; [status] is derived at
/// check-out (present / late / half day) or set directly for
/// absent / on-leave days by a manager.
class Attendance {
  final String id;
  final String employeeId;
  final String branchId;
  final DateTime date;
  final DateTime? checkIn;
  final DateTime? checkOut;
  final AttendanceStatus status;
  final String? note;
  final DateTime? createdAt;

  const Attendance({
    required this.id,
    required this.employeeId,
    required this.branchId,
    required this.date,
    this.checkIn,
    this.checkOut,
    this.status = AttendanceStatus.present,
    this.note,
    this.createdAt,
  });

  /// True when the employee has checked in but not yet checked out.
  bool get isOpen => checkIn != null && checkOut == null;

  /// Worked time, or null while the day is still open.
  Duration? get workedDuration => checkIn == null || checkOut == null
      ? null
      : checkOut!.difference(checkIn!);

  Attendance copyWith({
    String? id,
    String? employeeId,
    String? branchId,
    DateTime? date,
    DateTime? checkIn,
    bool clearCheckIn = false,
    DateTime? checkOut,
    bool clearCheckOut = false,
    AttendanceStatus? status,
    String? note,
    bool clearNote = false,
    DateTime? createdAt,
  }) {
    return Attendance(
      id: id ?? this.id,
      employeeId: employeeId ?? this.employeeId,
      branchId: branchId ?? this.branchId,
      date: date ?? this.date,
      checkIn: clearCheckIn ? null : (checkIn ?? this.checkIn),
      checkOut: clearCheckOut ? null : (checkOut ?? this.checkOut),
      status: status ?? this.status,
      note: clearNote ? null : (note ?? this.note),
      createdAt: createdAt ?? this.createdAt,
    );
  }

  factory Attendance.fromMap(String id, Map<String, dynamic> map) {
    return Attendance(
      id: id,
      employeeId: map['employeeId'] as String? ?? '',
      branchId: map['branchId'] as String? ?? '',
      date: parseDate(map['date']) ?? DateTime.now(),
      checkIn: parseDate(map['checkIn']),
      checkOut: parseDate(map['checkOut']),
      status: attendanceStatusFromString(map['status'] as String?),
      note: map['note'] as String?,
      createdAt: parseDate(map['createdAt']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'employeeId': employeeId,
      'branchId': branchId,
      'date': dateToMap(date),
      'checkIn': dateToMap(checkIn),
      'checkOut': dateToMap(checkOut),
      'status': status.name,
      'note': note,
      'createdAt': dateToMap(createdAt),
    };
  }
}
