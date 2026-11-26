import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Backup status state (Week 4 Day 4, D133 — SRS D-35).
///
/// Session-only, like the rest of the demo state: the last manual
/// backup this session produced (when, how big, what it covered)
/// and the last restore (when, how many docs it applied). The
/// scheduled Cloud Function export (SRS §2.6 — weekly full + daily
/// incremental to Cloud Storage) does not exist yet: there is no
/// Firebase project, so there is no scheduled backup to report, and
/// the screen says so instead of inventing one.
class BackupStatus {
  const BackupStatus({
    this.lastBackupAt,
    this.lastBackupSizeBytes,
    this.lastBackupTotalDocs = 0,
    this.lastBackupSections = const {},
    this.lastRestoreAt,
    this.lastRestoreApplied = 0,
    this.lastRestoreSkipped = 0,
  });

  final DateTime? lastBackupAt;
  final int? lastBackupSizeBytes;
  final int lastBackupTotalDocs;
  final Map<String, int> lastBackupSections;

  final DateTime? lastRestoreAt;
  final int lastRestoreApplied;
  final int lastRestoreSkipped;

  bool get hasBackup => lastBackupAt != null;
  bool get hasRestore => lastRestoreAt != null;
}

class BackupStatusNotifier extends Notifier<BackupStatus> {
  @override
  BackupStatus build() => const BackupStatus();

  void recordBackup({
    required DateTime at,
    required int sizeBytes,
    required int totalDocs,
    required Map<String, int> sections,
  }) {
    state = BackupStatus(
      lastBackupAt: at,
      lastBackupSizeBytes: sizeBytes,
      lastBackupTotalDocs: totalDocs,
      lastBackupSections: Map<String, int>.of(sections),
      lastRestoreAt: state.lastRestoreAt,
      lastRestoreApplied: state.lastRestoreApplied,
      lastRestoreSkipped: state.lastRestoreSkipped,
    );
  }

  void recordRestore({required int applied, required int skipped}) {
    state = BackupStatus(
      lastBackupAt: state.lastBackupAt,
      lastBackupSizeBytes: state.lastBackupSizeBytes,
      lastBackupTotalDocs: state.lastBackupTotalDocs,
      lastBackupSections: state.lastBackupSections,
      lastRestoreAt: DateTime.now(),
      lastRestoreApplied: applied,
      lastRestoreSkipped: skipped,
    );
  }
}

final backupStatusProvider =
    NotifierProvider<BackupStatusNotifier, BackupStatus>(
      BackupStatusNotifier.new,
    );
