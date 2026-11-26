import 'dart:convert';

/// Backup & Restore logic (Week 4 Day 4, D133 — SRS D-35, FR-SYS-07,
/// §2.6).
///
/// Pure helpers over the backup document the existing exporter
/// produces (`DataExporter.exportAll`): section counts, totals and
/// size. The screen triggers the exporter — it never re-implements
/// export — and restores through `DataImporter` into the layer's
/// restore sink.

/// Section → document count for a backup document, in the
/// exporter's section order.
Map<String, int> backupSectionCounts(Map<String, dynamic> backup) {
  final sections = backup['sections'];
  if (sections is! Map) return const {};
  return {
    for (final entry in sections.entries)
      entry.key.toString(): entry.value is List
          ? (entry.value as List).length
          : 0,
  };
}

/// Total documents across all sections of a backup document.
int backupTotalDocs(Map<String, dynamic> backup) {
  return backupSectionCounts(backup).values.fold(0, (a, b) => a + b);
}

/// The sections a backup covers, as human-readable names, in the
/// exporter's order.
List<String> backupSectionNames(Map<String, dynamic> backup) {
  return backupSectionCounts(backup).keys.toList();
}

/// Byte size of a backup document when serialised (the size the
/// status card shows).
int backupJsonSizeBytes(Map<String, dynamic> backup) {
  return utf8.encode(const JsonEncoder.withIndent('  ').convert(backup)).length;
}

/// Human-readable byte size (e.g. `12.4 KB`).
String formatBackupSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
