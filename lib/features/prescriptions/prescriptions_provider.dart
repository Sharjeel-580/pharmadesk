import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/branch_context.dart';
import '../../core/services/repositories.dart';
import '../../models/prescription.dart';
import '../dashboard/dashboard_screen.dart';
import '../notifications/notifications_provider.dart';
import '../orders/orders_provider.dart';
import 'prescriptions_logic.dart';

/// Day 7 prescription review state.
///
/// [PrescriptionsNotifier] owns the in-memory prescription list for
/// the session: it loads from the (mock) repository once, and every
/// review / new prescription writes through to the repository and
/// refreshes, so the list, detail and dashboard pending counts share
/// one source of truth.
///
/// Approving a prescription unblocks linked orders automatically:
/// the Day 4 dispatch guard reads the prescription status live
/// (`advanceBlockedReason`), and the order detail's prescription
/// lookup is invalidated here, so the order screen re-reads the new
/// status without a restart.

class PrescriptionsNotifier extends AsyncNotifier<List<Prescription>> {
  @override
  Future<List<Prescription>> build() async {
    final repo = ref.read(prescriptionRepositoryProvider);
    return repo.getPrescriptions();
  }

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(
      () => ref.read(prescriptionRepositoryProvider).getPrescriptions(),
    );
  }

  void _invalidateDependents() {
    // The order detail reads prescriptions through the order lookup
    // provider; the dashboard counts pending prescriptions; the
    // notifications list is derived from the same data.
    ref.invalidate(orderPrescriptionsProvider);
    ref.invalidate(dashboardKpisProvider);
    ref.invalidate(dashboardAlertsProvider);
    ref.invalidate(branchComparisonProvider);
    ref.invalidate(notificationsProvider);
  }

  /// Records a pharmacist review. Returns the updated prescription,
  /// or `null` prescription + an error message when validation
  /// rejects it (already reviewed, or a rejection without a note).
  Future<({Prescription? prescription, String? error})> review({
    required String id,
    required PrescriptionStatus target,
    required String reviewedBy,
    String note = '',
  }) async {
    // The list may not have loaded yet when review is called (e.g. a
    // test calling the notifier directly): fall back to the repository
    // instead of reporting "not found" for a record that exists.
    final current =
        state.asData?.value ??
        await ref.read(prescriptionRepositoryProvider).getPrescriptions();
    final existing = current.where((rx) => rx.id == id).firstOrNull;
    if (existing == null) {
      return (prescription: null, error: 'Prescription not found.');
    }
    final errors = validateReview(
      current: existing.status,
      target: target,
      note: note,
    );
    if (errors.isNotEmpty) {
      return (prescription: null, error: errors.first);
    }
    final updated = await ref
        .read(prescriptionRepositoryProvider)
        .reviewPrescription(
          id: id,
          status: target,
          reviewedBy: reviewedBy,
          reviewNotes: note,
        );
    await refresh();
    _invalidateDependents();
    return (prescription: updated, error: null);
  }

  /// Re-submits a rejected / needs-clearer-photo prescription for
  /// review (Week 2 Day 5, D91): back to Pending with a new validity
  /// date, previous review cleared, `resubmissionCount` + 1. The
  /// caller (detail screen) checks `canResubmitFor` first; this
  /// method validates the transition and the date itself. Returns
  /// the updated prescription, or `null` + an error message.
  Future<({Prescription? prescription, String? error})> resubmit({
    required String id,
    required DateTime validUntil,
  }) async {
    final current =
        state.asData?.value ??
        await ref.read(prescriptionRepositoryProvider).getPrescriptions();
    final existing = current.where((rx) => rx.id == id).firstOrNull;
    if (existing == null) {
      return (prescription: null, error: 'Prescription not found.');
    }
    final errors = validateResubmit(
      current: existing.status,
      validUntil: validUntil,
      now: DateTime.now(),
    );
    if (errors.isNotEmpty) {
      return (prescription: null, error: errors.first);
    }
    final updated = await ref
        .read(prescriptionRepositoryProvider)
        .resubmitPrescription(id: id, validUntil: validUntil);
    await refresh();
    _invalidateDependents();
    return (prescription: updated, error: null);
  }

  /// Creates a new Pending prescription from the manual form
  /// (patient + medicines text + notes). The photo is the bundled
  /// SAMPLE asset — the form explains that a real photo is attached
  /// on-device in production. Returns the saved record, or `null`
  /// record + an error message when validation rejects it.
  Future<({Prescription? prescription, String? error})> create({
    required String customerId,
    required String medicinesText,
    String notes = '',
    required String branchId,
    DateTime? validUntil,
  }) async {
    final errors = validateNewPrescription(
      customerId: customerId,
      medicinesText: medicinesText,
    );
    if (errors.isNotEmpty) {
      return (prescription: null, error: errors.first);
    }
    final prefix = branchId == 'branch-dha-main' ? 'rx-dha-' : 'rx-glb-';
    final created = await ref
        .read(prescriptionRepositoryProvider)
        .createPrescription(
          Prescription(
            // Branch is encoded in the id prefix (see the repository):
            // the repo assigns the next sequence for that branch.
            id: prefix,
            customerId: customerId,
            branchId: branchId,
            imageUrl: 'assets/images/prescriptions/sample-prescription-1.png',
            status: PrescriptionStatus.pending,
            medicinesText: medicinesText.trim(),
            reviewNotes: notes.trim().isEmpty ? null : notes.trim(),
            validUntil:
                validUntil ??
                DateTime.now().add(
                  const Duration(days: defaultPrescriptionValidityDays),
                ),
          ),
          branchId: branchId,
        );
    await refresh();
    _invalidateDependents();
    return (prescription: created, error: null);
  }
}

final prescriptionsProvider =
    AsyncNotifierProvider<PrescriptionsNotifier, List<Prescription>>(
      PrescriptionsNotifier.new,
    );

/// One prescription by id, from the list (refreshes when it does).
final prescriptionByIdProvider = Provider.family<Prescription?, String>((
  ref,
  id,
) {
  final list = ref.watch(prescriptionsProvider).asData?.value ?? const [];
  for (final rx in list) {
    if (rx.id == id) return rx;
  }
  return null;
});

/// Prescriptions for the active branch (the list screen's scope).
final branchPrescriptionsProvider = Provider<List<Prescription>>((ref) {
  final branch = ref.watch(activeBranchProvider);
  final prefix = branch.id == 'branch-dha-main' ? 'rx-dha-' : 'rx-glb-';
  final list = ref.watch(prescriptionsProvider).asData?.value ?? const [];
  return list.where((rx) => rx.id.startsWith(prefix)).toList();
});
