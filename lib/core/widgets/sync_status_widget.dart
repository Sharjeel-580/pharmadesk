import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/production_data_layer.dart';
import '../data/sync_queue.dart';

/// Sync-status UI (Week 3 Day 3, D108).
///
/// A small reusable chip that tells the truth about the offline sync
/// queue: how many operations are still pending, and when the queue
/// last synced successfully. It reads live from the production data
/// layer (`pendingSyncOperations()` / `lastSyncAt`) — the receiving
/// sync payload enqueued by Day 2 (D103) is exactly what surfaces
/// here — and it NEVER fakes a sync:
///
/// - Queue empty → "All synced".
/// - Operations pending → "N pending sync" (never "synced").
/// - Nothing has ever synced → "Never synced" (no invented time).
/// - Queue store throws → "Sync status unavailable" (not a stale
///   "All synced").
///
/// Tapping the chip refreshes it (invalidates [syncStatusProvider]);
/// the notifiers that write through the layer (POS sale, order
/// create, goods receiving, returns restock) invalidate it after a
/// successful write too, so the count moves without a tap.

/// Snapshot of the queue state for the chip.
class SyncStatus {
  const SyncStatus({
    required this.pendingCount,
    required this.pendingOperations,
    required this.lastSyncAt,
    required this.available,
  });

  /// Operations due for sync right now.
  final int pendingCount;

  /// The pending operations themselves (oldest first).
  final List<SyncOperation> pendingOperations;

  /// When an operation last synced successfully (`null` = never).
  final DateTime? lastSyncAt;

  /// False when the queue store could not be read at all.
  final bool available;

  /// True only when the store answered AND nothing is pending.
  bool get allSynced => available && pendingCount == 0;

  /// Short label for the chip, e.g. "All synced" / "3 pending sync"
  /// / "Sync status unavailable".
  String get label {
    if (!available) return 'Sync status unavailable';
    if (pendingCount == 0) return 'All synced';
    return pendingCount == 1 ? '1 pending sync' : '$pendingCount pending sync';
  }

  /// "Last sync 14:32" / "Never synced" — empty when unavailable.
  String get lastSyncLabel {
    if (!available || lastSyncAt == null) {
      return available ? 'Never synced' : '';
    }
    return 'Last sync ${formatSyncTime(lastSyncAt!)}';
  }
}

/// "14:32" today, "25/11 14:32" on another day.
String formatSyncTime(DateTime time) {
  final now = DateTime.now();
  final hh = time.hour.toString().padLeft(2, '0');
  final mm = time.minute.toString().padLeft(2, '0');
  if (time.year == now.year &&
      time.month == now.month &&
      time.day == now.day) {
    return '$hh:$mm';
  }
  return '${time.day}/${time.month} $hh:$mm';
}

/// Reads the live queue state from the production data layer. A
/// store failure resolves to `available: false` instead of throwing
/// — the chip must render "unavailable", not crash the screen.
final syncStatusProvider = FutureProvider<SyncStatus>((ref) async {
  final layer = ref.read(productionDataLayerProvider);
  try {
    final pending = await layer.pendingSyncOperations();
    return SyncStatus(
      pendingCount: pending.length,
      pendingOperations: pending,
      lastSyncAt: layer.lastSyncAt,
      available: true,
    );
  } catch (_) {
    return const SyncStatus(
      pendingCount: 0,
      pendingOperations: [],
      lastSyncAt: null,
      available: false,
    );
  }
});

/// Compact sync-status chip for offline-capable screens (POS,
/// inventory, purchases receiving, orders — D109). Sits under the
/// screen header; tapping it refreshes the status.
class SyncStatusChip extends ConsumerWidget {
  const SyncStatusChip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final statusAsync = ref.watch(syncStatusProvider);
    final theme = Theme.of(context);
    return statusAsync.when(
      loading: () => _ChipShell(
        icon: Icons.sync_outlined,
        color: theme.colorScheme.onSurfaceVariant,
        label: 'Checking sync…',
        onTap: null,
      ),
      error: (_, _) => _ChipShell(
        icon: Icons.cloud_off_outlined,
        color: theme.colorScheme.error,
        label: 'Sync status unavailable',
        onTap: () => ref.invalidate(syncStatusProvider),
      ),
      data: (status) {
        final color = !status.available
            ? theme.colorScheme.error
            : status.pendingCount > 0
            ? theme.colorScheme.tertiary
            : Colors.green.shade700;
        final icon = !status.available
            ? Icons.cloud_off_outlined
            : status.pendingCount > 0
            ? Icons.cloud_upload_outlined
            : Icons.cloud_done_outlined;
        final detail = status.lastSyncLabel;
        return _ChipShell(
          icon: icon,
          color: color,
          label: detail.isEmpty
              ? status.label
              : '${status.label} • $detail',
          onTap: () => ref.invalidate(syncStatusProvider),
        );
      },
    );
  }
}

class _ChipShell extends StatelessWidget {
  const _ChipShell({
    required this.icon,
    required this.color,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Sync status — tap to refresh',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            border: Border.all(color: color.withValues(alpha: 0.4)),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 6),
              Text(
                label,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
