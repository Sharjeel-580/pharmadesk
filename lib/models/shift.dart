import 'model_utils.dart';

/// A work shift (SRS §3.7 `branches/{branchId}/shifts`, FR-HR).
///
/// Times are `HH:MM` 24-hour strings (e.g. `09:00`, `17:30`). A
/// shift ends after it starts on the same day — overnight shifts
/// are out of scope for this version (see D89); a shift that would
/// cross midnight is rejected by validation.
class Shift {
  final String id;
  final String branchId;
  final String name;
  final String startTime;
  final String endTime;
  final List<String> employeeIds;
  final DateTime? createdAt;

  const Shift({
    required this.id,
    required this.branchId,
    required this.name,
    required this.startTime,
    required this.endTime,
    this.employeeIds = const [],
    this.createdAt,
  });

  /// Minutes from midnight for [startTime], or null when malformed.
  int? get startMinutes => shiftTimeToMinutes(startTime);

  /// Minutes from midnight for [endTime], or null when malformed.
  int? get endMinutes => shiftTimeToMinutes(endTime);

  /// Length of the shift, or null when either time is malformed.
  Duration? get duration {
    final start = startMinutes;
    final end = endMinutes;
    if (start == null || end == null) return null;
    return Duration(minutes: end - start);
  }

  Shift copyWith({
    String? id,
    String? branchId,
    String? name,
    String? startTime,
    String? endTime,
    List<String>? employeeIds,
    DateTime? createdAt,
  }) {
    return Shift(
      id: id ?? this.id,
      branchId: branchId ?? this.branchId,
      name: name ?? this.name,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      employeeIds: employeeIds ?? this.employeeIds,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  factory Shift.fromMap(String id, Map<String, dynamic> map) {
    return Shift(
      id: id,
      branchId: map['branchId'] as String? ?? '',
      name: map['name'] as String? ?? '',
      startTime: map['startTime'] as String? ?? '',
      endTime: map['endTime'] as String? ?? '',
      employeeIds:
          (map['employeeIds'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
      createdAt: parseDate(map['createdAt']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'branchId': branchId,
      'name': name,
      'startTime': startTime,
      'endTime': endTime,
      'employeeIds': employeeIds,
      'createdAt': dateToMap(createdAt),
    };
  }
}

/// Parses an `HH:MM` 24-hour time into minutes from midnight.
/// Returns null when the text is not a valid time.
int? shiftTimeToMinutes(String value) {
  final parts = value.trim().split(':');
  if (parts.length != 2) return null;
  final hour = int.tryParse(parts[0]);
  final minute = int.tryParse(parts[1]);
  if (hour == null || minute == null) return null;
  if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
  return hour * 60 + minute;
}

/// Formats minutes from midnight as `HH:MM`.
String shiftMinutesToLabel(int minutes) {
  final hour = (minutes ~/ 60).clamp(0, 23);
  final minute = (minutes % 60).clamp(0, 59);
  return '${hour.toString().padLeft(2, '0')}:'
      '${minute.toString().padLeft(2, '0')}';
}
