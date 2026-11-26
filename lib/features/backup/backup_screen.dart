import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/data/auth_repository.dart';
import '../../core/data/backup_export.dart';
import '../../core/data/permission_service.dart';
import '../../core/data/production_data_layer.dart';
import '../../core/services/branch_context.dart';
import '../../core/widgets/design_system.dart';
import '../../features/authentication/auth_state.dart';
import 'backup_logic.dart';
import 'backup_provider.dart';

/// Backup & Restore (Week 4 Day 4, D133 — SRS D-35, FR-SYS-07, §2.6).
///
/// Route `/backup` (capability-gated on `sysSettings`, SRS §5.1:
/// Super Admin / Owner / HO Admin only).
///
/// - **Status:** a live preview of what a backup would contain
///   (section counts + total docs, computed from a fresh export of
///   the layer — not a stored figure), plus the last manual backup
///   this session (time, size, sections).
/// - **Manual backup:** triggers the existing exporter
///   (`DataExporter` via the layer — on web it downloads the JSON
///   file) and records the status. The screen never re-implements
///   export.
/// - **Restore (admin only):** paste a backup JSON document, it is
///   validated first (`DataImporter.validateBackup`), then an
///   explicit confirmation step states that it replaces the current
///   restored data, and only then is it imported (overwrite policy)
///   into the layer's restore sink, with the import report shown.
///   The restore target is the in-memory restore sink — the live
///   demo repositories have no upsert-by-id, so a restore does NOT
///   overwrite live repo data yet (documented limitation, D133);
///   the confirmation copy says exactly what it replaces.
///
/// There is no scheduled backup to report yet: the Cloud Function
/// export (SRS §2.6) needs the Firebase project, so the screen says
/// "not configured" instead of inventing a schedule.
class BackupScreen extends ConsumerStatefulWidget {
  const BackupScreen({super.key});

  @override
  ConsumerState<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends ConsumerState<BackupScreen> {
  final _restoreController = TextEditingController();
  bool _backingUp = false;
  String? _restoreMessage;
  List<String> _restoreErrors = [];

  @override
  void dispose() {
    _restoreController.dispose();
    super.dispose();
  }

  Future<void> _runBackup() async {
    setState(() => _backingUp = true);
    try {
      final layer = ref.read(productionDataLayerProvider);
      final doc = await layer.exportBackup();
      final json = const JsonEncoder.withIndent('  ').convert(doc);
      await layer.downloadBackup();
      if (!mounted) return;
      ref
          .read(backupStatusProvider.notifier)
          .recordBackup(
            at: DateTime.now(),
            sizeBytes: utf8.encode(json).length,
            totalDocs: backupTotalDocs(doc),
            sections: backupSectionCounts(doc),
          );
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Backup created — on web it downloads as a JSON file.'),
        ),
      );
    } finally {
      if (mounted) setState(() => _backingUp = false);
    }
  }

  void _attemptRestore() {
    final text = _restoreController.text.trim();
    if (text.isEmpty) {
      setState(() {
        _restoreErrors = const ['Paste a backup JSON document first.'];
        _restoreMessage = null;
      });
      return;
    }
    Map<String, dynamic> json;
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) {
        setState(() {
          _restoreErrors = const ['The pasted text is not a JSON object.'];
          _restoreMessage = null;
        });
        return;
      }
      json = decoded;
    } catch (_) {
      setState(() {
        _restoreErrors = const ['The pasted text is not valid JSON.'];
        _restoreMessage = null;
      });
      return;
    }
    final errors = DataImporter.validateBackup(json);
    if (errors.isNotEmpty) {
      setState(() {
        _restoreErrors = errors;
        _restoreMessage = null;
      });
      return;
    }
    _confirmRestore(json);
  }

  Future<void> _confirmRestore(Map<String, dynamic> json) async {
    final totalDocs = backupTotalDocs(json);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Restore this backup?'),
        content: Text(
          'This will replace the current restored data with the '
          'contents of this backup ($totalDocs documents, overwrite '
          'policy — a document with the same id is replaced, never '
          'duplicated). The backup was exported at '
          '${json['exportedAt'] ?? 'an unknown time'} for organization '
          '${json['organizationId'] ?? 'unknown'}. '
          'This does NOT overwrite the live demo data: the restore '
          'target is the local restore store (the live repositories '
          'have no upsert-by-id yet).',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          PharmaButton(
            label: 'Restore backup',
            variant: PharmaButtonVariant.danger,
            onPressed: () => Navigator.of(dialogContext).pop(true),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final layer = ref.read(productionDataLayerProvider);
    final report = layer.importBackup(json, policy: ImportPolicy.overwrite);
    ref
        .read(backupStatusProvider.notifier)
        .recordRestore(
          applied: report.totalApplied,
          skipped: report.skipped,
        );
    setState(() {
      _restoreErrors = const [];
      _restoreMessage =
          'Restore complete: ${report.created} created, '
          '${report.overwritten} overwritten, ${report.skipped} '
          'skipped. ${report.errors.isEmpty ? '' : 'Errors: ${report.errors.join(' ')}'}';
    });
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authProvider);
    final status = ref.watch(backupStatusProvider);
    final canRestore = _canRestore(user);
    final previewAsync = ref.watch(_backupPreviewProvider);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionHeader(
              title: 'Backup & Restore',
              subtitle:
                  'Backup status, manual backup, restore — admin only '
                  '(SRS D-35, FR-SYS-07)',
              actionLabel: _backingUp ? 'Backing up…' : 'Create backup',
              actionIcon: Icons.backup_outlined,
              onAction: _backingUp ? null : _runBackup,
            ),
            const SizedBox(height: 16),
            PharmaCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Backup status',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Scheduled backups (weekly full + daily incremental '
                    'to Cloud Storage, SRS §2.6) are not configured: '
                    'they run as a Cloud Function and there is no '
                    'Firebase project yet. Manual backup below is the '
                    'working path.',
                  ),
                  const SizedBox(height: 12),
                  if (status.hasBackup) ...[
                    _StatusRow(
                      label: 'Last backup',
                      value:
                          '${_timeLabel(status.lastBackupAt)} • '
                          '${formatBackupSize(status.lastBackupSizeBytes ?? 0)} • '
                          '${status.lastBackupTotalDocs} documents',
                    ),
                    _StatusRow(
                      label: 'Sections backed up',
                      value: status.lastBackupSections.entries
                          .map((e) => '${e.key} (${e.value})')
                          .join(', '),
                    ),
                  ] else
                    const Text('No backup created yet in this session.'),
                  const SizedBox(height: 8),
                  previewAsync.when(
                    loading: () => const Text('Reading current data…'),
                    error: (error, _) =>
                        Text('Could not read current data: $error'),
                    data: (preview) => Text(
                      'Current data that a backup would contain: '
                      '${preview.$2} documents — '
                      '${preview.$1.entries.map((e) => '${e.key} (${e.value})').join(', ')}.',
                    ),
                  ),
                  if (status.hasRestore) ...[
                    const SizedBox(height: 8),
                    _StatusRow(
                      label: 'Last restore',
                      value:
                          '${_timeLabel(status.lastRestoreAt)} • '
                          '${status.lastRestoreApplied} documents applied, '
                          '${status.lastRestoreSkipped} skipped',
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),
            PharmaCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'What is included',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Medicines, suppliers + supplier ledger, riders, '
                    'orders, sales, inventory, prescriptions, purchase '
                    'orders, customers + khata ledger, audit log, '
                    'pending sync queue. Money stays in integer paisa; '
                    'dates are ISO strings. Prescription photo bytes '
                    'are NOT in the JSON backup — they live in Cloud '
                    'Storage (SRS §3.4); only their metadata is '
                    'exported.',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            PharmaCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Restore from backup',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Admin only. Paste a PharmaDesk backup JSON '
                    'document (format "pharmadesk-backup", version 1). '
                    'It is validated before anything is written, then '
                    'you confirm explicitly.',
                  ),
                  const SizedBox(height: 12),
                  if (!canRestore) ...[
                    const Text(
                      'Your role cannot restore backups (SRS §5.1 '
                      '"System settings / backup": Owner, HO Admin and '
                      'Super Admin only).',
                    ),
                  ] else ...[
                    if (_restoreErrors.isNotEmpty) ...[
                      PharmaErrorBox(errors: _restoreErrors),
                      const SizedBox(height: 12),
                    ],
                    if (_restoreMessage != null) ...[
                      Text(_restoreMessage!),
                      const SizedBox(height: 12),
                    ],
                    PharmaTextField(
                      controller: _restoreController,
                      label: 'Backup JSON',
                      hintText: 'Paste the backup JSON document here…',
                      maxLines: 8,
                    ),
                    const SizedBox(height: 12),
                    PharmaButton(
                      key: const ValueKey('restore-validate-button'),
                      label: 'Validate & restore',
                      icon: Icons.restore_outlined,
                      variant: PharmaButtonVariant.danger,
                      onPressed: _attemptRestore,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  bool _canRestore(AppUser? user) {
    // Restore is a write under `sysSettings` — the Auditor and all
    // branch roles are `none` on it (SRS §5.1); only Super Admin /
    // Owner / HO Admin hold it.
    return permissionService.canWrite(
      user,
      'sysSettings',
      ref.read(activeBranchProvider).id,
    );
  }

  String _timeLabel(DateTime? at) {
    if (at == null) return 'never';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(at.year, at.month, at.day);
    final hh = at.hour.toString().padLeft(2, '0');
    final mm = at.minute.toString().padLeft(2, '0');
    if (day == today) return 'today $hh:$mm';
    return '${at.day}/${at.month}/${at.year} $hh:$mm';
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 160,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}

/// Live preview of what a backup would contain right now: section
/// counts + total docs, from a fresh export of the layer.
final _backupPreviewProvider =
    FutureProvider<(Map<String, int>, int)>((ref) async {
      final layer = ref.read(productionDataLayerProvider);
      final doc = await layer.exportBackup();
      final sections = backupSectionCounts(doc);
      return (sections, backupTotalDocs(doc));
    });
