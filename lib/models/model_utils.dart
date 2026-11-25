import 'package:cloud_firestore/cloud_firestore.dart';

/// Shared helpers for model <-> Firestore map conversion.
///
/// Firestore stores dates as [Timestamp]; JSON/backups may carry ISO strings
/// or epoch millis. [parseDate] accepts all of them so models stay robust
/// no matter where the map came from.
DateTime? parseDate(dynamic value) {
  if (value == null) return null;
  if (value is DateTime) return value;
  if (value is Timestamp) return value.toDate();
  if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
  if (value is String) return DateTime.tryParse(value);
  return null;
}

/// Serialises a [DateTime] for Firestore. Null stays null.
dynamic dateToMap(DateTime? value) =>
    value == null ? null : Timestamp.fromDate(value);
