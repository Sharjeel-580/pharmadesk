import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/data/audit_log.dart';
import '../../core/data/production_data_layer.dart';
import '../../core/services/branch_context.dart';
import '../../core/widgets/design_system.dart';
import '../../core/widgets/pagination_controls.dart';
import '../../features/authentication/auth_state.dart';
import 'audit_logic.dart';

/// Audit Log — filterable viewer (Week 4 Day 4, D132 — SRS D-33,
/// FR-SYS-04).
///
/// Route `/audit-log` (capability-gated on `auditLog`, SRS §5.1).
/// Reads the same in-memory store the writer writes
/// (`ProductionDataLayer.auditEntries`); the audit writer is
/// in-memory until the Firebase project exists, so the log covers
/// this session only — the screen says so instead of implying a
/// permanent record. Filters: branch, actor, action family, date
/// range (All / Today / Last 7 days / Last 30 days). Paged at 10
/// (D107). Tapping a row opens the detail dialog (what changed:
/// before → after).
class AuditLogScreen extends ConsumerStatefulWidget {
  const AuditLogScreen({super.key});

  @override
  ConsumerState<AuditLogScreen> createState() => _AuditLogScreenState();
}

class _AuditLogScreenState extends ConsumerState<AuditLogScreen> {
  String? _branchFilter;
  String? _actorFilter;
  String? _actionFilter;
  int _rangeDays = 0; // 0 = all time.

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authProvider);
    final entriesAsync = ref.watch(_auditEntriesProvider);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            title: 'Audit Log',
            subtitle:
                'Filterable log of all important actions — sales, refunds, '
                'stock adjustments, purchase changes, permission changes, '
                'financial changes, admin actions (SRS D-33, FR-SYS-04)',
            actionLabel: 'Refresh',
            actionIcon: Icons.refresh_outlined,
            onAction: () => ref.invalidate(_auditEntriesProvider),
          ),
          const SizedBox(height: 8),
          const Text(
            'The audit log is in-memory for this session (the writer '
            'has no Firebase project yet): entries cover what this '
            'session did, and reset when the app restarts. Entries '
            'are append-only — never edited or deleted.',
          ),
          const SizedBox(height: 16),
          entriesAsync.when(
            loading: () => const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: CircularProgressIndicator(),
              ),
            ),
            error: (error, _) => PharmaErrorBox(errors: ['$error']),
            data: (allEntries) {
              final visible = auditVisibleEntries(allEntries, user);
              final now = DateTime.now();
              final from = _rangeDays == 0
                  ? null
                  : DateTime(
                      now.year,
                      now.month,
                      now.day,
                    ).subtract(Duration(days: _rangeDays - 1));
              final filtered = filterAuditEntries(
                visible,
                branchId: _branchFilter,
                actorName: _actorFilter,
                actionPrefix: _actionFilter,
                from: from,
              );
              return Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Filters(
                      entries: visible,
                      branchFilter: _branchFilter,
                      actorFilter: _actorFilter,
                      actionFilter: _actionFilter,
                      rangeDays: _rangeDays,
                      onBranchChanged: (value) =>
                          setState(() => _branchFilter = value),
                      onActorChanged: (value) =>
                          setState(() => _actorFilter = value),
                      onActionChanged: (value) =>
                          setState(() => _actionFilter = value),
                      onRangeChanged: (value) =>
                          setState(() => _rangeDays = value),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '${filtered.length} '
                      '${filtered.length == 1 ? 'entry' : 'entries'}',
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: SingleChildScrollView(
                        child: PagedList<AuditLogEntry>(
                          items: filtered,
                          emptyMessage:
                              'No audit entries match these filters.',
                          itemBuilder: (context, entry) => Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: PharmaCard(
                              child: InkWell(
                                onTap: () => _showDetail(context, entry),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            entry.action,
                                            style: theme.textTheme.titleSmall
                                                ?.copyWith(
                                                  fontWeight: FontWeight.w700,
                                                ),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            entry.summary.isEmpty
                                                ? '${entry.entityType} '
                                                    '${entry.entityId}'
                                                : entry.summary,
                                            style:
                                                theme.textTheme.bodyMedium,
                                          ),
                                          Text(
                                            '${entry.actorName} • '
                                            '${_branchName(entry.branchId)} • '
                                            '${_timeLabel(entry.createdAt)}',
                                            style:
                                                theme.textTheme.bodySmall,
                                          ),
                                        ],
                                      ),
                                    ),
                                    const Icon(Icons.chevron_right),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  String _branchName(String branchId) {
    for (final branch in demoBranches) {
      if (branch.id == branchId) return branch.name;
    }
    return branchId;
  }

  String _timeLabel(DateTime? createdAt) {
    if (createdAt == null) return 'no time recorded';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(
      createdAt.year,
      createdAt.month,
      createdAt.day,
    );
    final hh = createdAt.hour.toString().padLeft(2, '0');
    final mm = createdAt.minute.toString().padLeft(2, '0');
    if (day == today) return 'today $hh:$mm';
    return '${createdAt.day}/${createdAt.month}/${createdAt.year} $hh:$mm';
  }

  void _showDetail(BuildContext context, AuditLogEntry entry) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(entry.action),
        content: SingleChildScrollView(
          child: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _DetailRow(label: 'Actor', value: entry.actorName),
                _DetailRow(label: 'User id', value: entry.userId),
                _DetailRow(label: 'Branch', value: _branchName(entry.branchId)),
                _DetailRow(label: 'Entity', value: '${entry.entityType} ${entry.entityId}'),
                _DetailRow(
                  label: 'When',
                  value: _timeLabel(entry.createdAt),
                ),
                if (entry.summary.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(entry.summary),
                ],
                if (entry.before != null || entry.after != null) ...[
                  const SizedBox(height: 12),
                  const Text(
                    'What changed',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  if (entry.before != null)
                    _DetailRow(label: 'Before', value: entry.before!),
                  if (entry.after != null)
                    _DetailRow(label: 'After', value: entry.after!),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

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
            width: 90,
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

class _Filters extends StatelessWidget {
  const _Filters({
    required this.entries,
    required this.branchFilter,
    required this.actorFilter,
    required this.actionFilter,
    required this.rangeDays,
    required this.onBranchChanged,
    required this.onActorChanged,
    required this.onActionChanged,
    required this.onRangeChanged,
  });

  final List<AuditLogEntry> entries;
  final String? branchFilter;
  final String? actorFilter;
  final String? actionFilter;
  final int rangeDays;
  final ValueChanged<String?> onBranchChanged;
  final ValueChanged<String?> onActorChanged;
  final ValueChanged<String?> onActionChanged;
  final ValueChanged<int> onRangeChanged;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 12,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        DropdownButton<String?>(
          key: const ValueKey('audit-branch-filter'),
          value: branchFilter,
          hint: const Text('All branches'),
          items: [
            const DropdownMenuItem<String?>(value: null, child: Text('All branches')),
            for (final branch in demoBranches)
              DropdownMenuItem<String?>(
                value: branch.id,
                child: Text(branch.name),
              ),
          ],
          onChanged: onBranchChanged,
        ),
        DropdownButton<String?>(
          key: const ValueKey('audit-actor-filter'),
          value: actorFilter,
          hint: const Text('All actors'),
          items: [
            const DropdownMenuItem<String?>(value: null, child: Text('All actors')),
            for (final actor in auditActors(entries))
              DropdownMenuItem<String?>(value: actor, child: Text(actor)),
          ],
          onChanged: onActorChanged,
        ),
        DropdownButton<String?>(
          key: const ValueKey('audit-action-filter'),
          value: actionFilter,
          hint: const Text('All actions'),
          items: [
            const DropdownMenuItem<String?>(value: null, child: Text('All actions')),
            for (final family in auditActionFamilies(entries))
              DropdownMenuItem<String?>(value: family, child: Text(family)),
          ],
          onChanged: onActionChanged,
        ),
        DropdownButton<int>(
          key: const ValueKey('audit-range-filter'),
          value: rangeDays,
          items: const [
            DropdownMenuItem(value: 0, child: Text('All time')),
            DropdownMenuItem(value: 1, child: Text('Today')),
            DropdownMenuItem(value: 7, child: Text('Last 7 days')),
            DropdownMenuItem(value: 30, child: Text('Last 30 days')),
          ],
          onChanged: (value) {
            if (value != null) onRangeChanged(value);
          },
        ),
      ],
    );
  }
}

/// The audit entries the layer's writer holds, newest first
/// (the screen filters + pages them; the provider is invalidated
/// by Refresh).
final _auditEntriesProvider = FutureProvider<List<AuditLogEntry>>((
  ref,
) async {
  final layer = ref.read(productionDataLayerProvider);
  final entries = await layer.auditEntries();
  final sorted = List<AuditLogEntry>.of(entries);
  sorted.sort((a, b) {
    final aAt = a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    final bAt = b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    return bAt.compareTo(aAt);
  });
  return sorted;
});
