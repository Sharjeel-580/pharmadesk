import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/data/permission_service.dart';
import '../../core/services/branch_context.dart';
import '../../core/widgets/design_system.dart';
import '../../features/authentication/auth_state.dart';
import '../../models/prescription.dart';
import '../customers/customers_provider.dart';
import '../orders/orders_provider.dart';
import 'prescriptions_logic.dart';
import 'prescriptions_provider.dart';

/// Prescription detail + pharmacist review (Day 7, SRS FR-ORD-04).
///
/// Route `/prescriptions/:id`.
///
/// Shows the bundled SAMPLE photo, the patient, the medicines text,
/// the review history, and — while Pending — the Approve / Reject /
/// Needs clearer photo actions. Approving unblocks any order the
/// dispatch guard was holding (the order detail re-reads the status
/// live); the detail says so explicitly when a linked order exists.
class PrescriptionDetailScreen extends ConsumerWidget {
  const PrescriptionDetailScreen({super.key, required this.prescriptionId});

  final String prescriptionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rx = ref.watch(prescriptionByIdProvider(prescriptionId));
    if (rx == null) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: PharmaEmptyState(
          icon: Icons.description_outlined,
          title: 'Prescription not found',
          message:
              'There is no prescription with id "$prescriptionId" in this demo.',
          actionLabel: 'Back to Prescriptions',
          onAction: () => context.go('/prescriptions'),
        ),
      );
    }
    final customer = ref.watch(customerByIdProvider(rx.customerId));
    final theme = Theme.of(context);
    final linkedOrder = rx.orderId == null
        ? null
        : ref.watch(orderByIdProvider(rx.orderId!));
    // Orders link to prescriptions from the order side too: find an
    // order whose prescriptionId is this record.
    final orders = ref.watch(orderQueueProvider).asData?.value ?? const [];
    final linkedFromOrder = orders
        .where((order) => order.prescriptionId == rx.id)
        .firstOrNull;
    final effectiveLinkedOrder = linkedOrder ?? linkedFromOrder;
    final reviewer = ref.watch(authProvider)?.name ?? 'Pharmacist';
    // Review is a pharmacist-only action (SRS §5.1 `rxReview`):
    // only a pharmacist in this prescription's branch may approve /
    // reject. Anyone else sees the buttons disabled with the reason.
    // A signed-out viewer (deep link, tests) is not blocked here —
    // the router's auth redirect is the signed-out guard and the
    // Firestore rules remain the authority (D70).
    final reviewerUser = ref.watch(authProvider);
    final reviewBranchId = rx.branchId ?? ref.watch(activeBranchProvider).id;
    final mayReview = permissionService.canWrite(
      reviewerUser,
      'rxReview',
      reviewBranchId,
    );
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            title: rx.id,
            subtitle:
                'Patient: ${customer?.name ?? rx.customerId}'
                '${customer != null ? ' • ${customer.phone}' : ''}',
            actionLabel: 'All Prescriptions',
            actionIcon: Icons.description_outlined,
            onAction: () => context.go('/prescriptions'),
          ),
          const SizedBox(height: 16),
          // Badges wrap: status + received + validity can exceed a
          // phone-width row (Day 5 overflow fix — the validity badge
          // is the third chip in this row).
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              StatusBadge(
                label: prescriptionStatusLabel(rx.status),
                kind: prescriptionStatusKind(rx.status),
              ),
              if (rx.createdAt != null)
                StatusBadge(
                  label:
                      'Received ${rx.createdAt!.day}/${rx.createdAt!.month}/${rx.createdAt!.year}',
                  kind: StatusKind.neutral,
                  icon: Icons.calendar_today_outlined,
                ),
              if (rx.validUntil != null)
                StatusBadge(
                  label: isPrescriptionExpired(rx, DateTime.now())
                      ? 'Expired ${rx.validUntil!.day}/${rx.validUntil!.month}/${rx.validUntil!.year}'
                      : 'Valid until ${rx.validUntil!.day}/${rx.validUntil!.month}/${rx.validUntil!.year}',
                  kind: isPrescriptionExpired(rx, DateTime.now())
                      ? StatusKind.danger
                      : StatusKind.success,
                  icon: Icons.event_outlined,
                ),
            ],
          ),
          if (rx.resubmissionCount > 0) ...[
            const SizedBox(height: 8),
            Text(
              'Re-submitted ${rx.resubmissionCount} time(s) for review.',
              style: theme.textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 16),
          PharmaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.asset(
                    rx.imageUrl,
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stackTrace) => Container(
                      height: 200,
                      alignment: Alignment.center,
                      color: theme.colorScheme.primary.withValues(alpha: 0.08),
                      child: const Text(
                        'Sample prescription image could not load.',
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'SAMPLE image bundled with the demo — not a real '
                  'patient prescription. In production the photo is a '
                  'private on-device file, never a public URL.',
                  style: theme.textTheme.bodySmall,
                ),
                if (rx.medicinesText != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    'Medicines on the prescription',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(rx.medicinesText!),
                ],
                if (rx.reviewedBy != null) ...[
                  const SizedBox(height: 16),
                  const Divider(height: 1),
                  const SizedBox(height: 8),
                  Text(
                    'Reviewed by ${rx.reviewedBy}'
                    '${rx.reviewedAt != null ? ' • ${rx.reviewedAt!.day}/${rx.reviewedAt!.month}/${rx.reviewedAt!.year}' : ''}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (rx.reviewNotes != null) ...[
                    const SizedBox(height: 4),
                    Text('Note: ${rx.reviewNotes}'),
                  ],
                ],
                if (effectiveLinkedOrder != null) ...[
                  const SizedBox(height: 16),
                  const Divider(height: 1),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Icon(Icons.receipt_long_outlined),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          rx.status == PrescriptionStatus.pending
                              ? 'Linked order ${effectiveLinkedOrder.id} cannot be dispatched until this prescription is approved.'
                              : !canUnblockOrder(rx, DateTime.now())
                                  ? 'Linked order ${effectiveLinkedOrder.id} cannot be dispatched — this prescription was approved but its validity has expired. Ask the patient for a new prescription, or re-submit this one with a new validity date.'
                                  : 'Linked order ${effectiveLinkedOrder.id} is no longer held by this prescription.',
                        ),
                      ),
                      TextButton(
                        onPressed: () =>
                            context.go('/orders/${effectiveLinkedOrder.id}'),
                        child: const Text('View order'),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          if (canReview(rx.status)) ...[
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                PharmaButton(
                  label: 'Approve',
                  icon: Icons.check_circle_outline,
                  onPressed: mayReview
                      ? () => _review(
                          context,
                          ref,
                          rx,
                          PrescriptionStatus.approved,
                          reviewer,
                        )
                      : null,
                ),
                PharmaButton(
                  label: 'Reject',
                  variant: PharmaButtonVariant.danger,
                  icon: Icons.cancel_outlined,
                  onPressed: mayReview
                      ? () => _reviewWithNote(
                          context,
                          ref,
                          rx,
                          PrescriptionStatus.rejected,
                          reviewer,
                        )
                      : null,
                ),
                PharmaButton(
                  label: 'Needs clearer photo',
                  variant: PharmaButtonVariant.secondary,
                  icon: Icons.photo_camera_outlined,
                  onPressed: mayReview
                      ? () => _reviewWithNote(
                          context,
                          ref,
                          rx,
                          PrescriptionStatus.needsClearerPhoto,
                          reviewer,
                        )
                      : null,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              mayReview
                  ? 'Approving unblocks dispatch for any order linked to this '
                        'prescription (Day 4 dispatch guard).'
                  : 'Only a pharmacist in this branch can review '
                        'prescriptions (SRS §5.1). You are signed in as '
                        '${reviewerUser?.roleLabel ?? 'staff'}.',
              style: theme.textTheme.bodySmall,
            ),
          ],
          if (canResubmit(rx.status)) ...[
            const SizedBox(height: 16),
            PharmaButton(
              label: 'Re-submit for review',
              icon: Icons.restart_alt_outlined,
              onPressed: canResubmitFor(reviewerUser, reviewBranchId)
                  ? () => _resubmit(context, ref, rx)
                  : null,
            ),
            const SizedBox(height: 8),
            Text(
              canResubmitFor(reviewerUser, reviewBranchId)
                  ? 'Sends the prescription back to Pending with a new '
                        'validity date — the pharmacist reviews it again. '
                        'The previous review is cleared and the '
                        're-submission is counted.'
                  : 'Only branch staff who handle prescriptions (counter / '
                        'pharmacist / manager / owner) can re-submit '
                        '(SRS §5.1). You are signed in as '
                        '${reviewerUser?.roleLabel ?? 'staff'}.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _resubmit(
    BuildContext context,
    WidgetRef ref,
    Prescription rx,
  ) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final suggested = rx.validUntil != null &&
            !rx.validUntil!.isBefore(today)
        ? rx.validUntil!
        : today.add(const Duration(days: defaultPrescriptionValidityDays));
    final validUntil = await showDatePicker(
      context: context,
      initialDate: suggested,
      firstDate: today,
      lastDate: today.add(const Duration(days: 365)),
      helpText: 'New validity date',
    );
    if (validUntil == null || !context.mounted) return;
    final result = await ref
        .read(prescriptionsProvider.notifier)
        .resubmit(id: rx.id, validUntil: validUntil);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.error ??
              'Prescription ${rx.id} re-submitted — back to Pending '
                  'for pharmacist review.',
        ),
      ),
    );
  }

  Future<void> _review(
    BuildContext context,
    WidgetRef ref,
    Prescription rx,
    PrescriptionStatus target,
    String reviewer,
  ) async {
    final result = await ref
        .read(prescriptionsProvider.notifier)
        .review(id: rx.id, target: target, reviewedBy: reviewer);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.error ??
              'Prescription ${rx.id} approved — linked orders can now be dispatched.',
        ),
      ),
    );
  }

  Future<void> _reviewWithNote(
    BuildContext context,
    WidgetRef ref,
    Prescription rx,
    PrescriptionStatus target,
    String reviewer,
  ) async {
    final note = await showDialog<String>(
      context: context,
      builder: (dialogContext) => _ReviewNoteDialog(target: target),
    );
    if (note == null || !context.mounted) return;
    final result = await ref
        .read(prescriptionsProvider.notifier)
        .review(id: rx.id, target: target, reviewedBy: reviewer, note: note);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.error ??
              'Prescription ${rx.id} marked as '
                  '${prescriptionStatusLabel(target).toLowerCase()}.',
        ),
      ),
    );
  }
}

class _ReviewNoteDialog extends StatefulWidget {
  const _ReviewNoteDialog({required this.target});

  final PrescriptionStatus target;

  @override
  State<_ReviewNoteDialog> createState() => _ReviewNoteDialogState();
}

class _ReviewNoteDialogState extends State<_ReviewNoteDialog> {
  final _note = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.target == PrescriptionStatus.rejected
        ? 'Reject prescription'
        : 'Ask for a clearer photo';
    return AlertDialog(
      title: Text(label),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_error != null) ...[
            PharmaErrorBox(errors: [_error!]),
            const SizedBox(height: 12),
          ],
          PharmaTextField(
            controller: _note,
            label: 'Note (required)',
            hintText: widget.target == PrescriptionStatus.rejected
                ? 'e.g. Prescription is expired / not legible'
                : 'e.g. Photo is blurry — please retake',
            maxLines: 3,
            autofocus: true,
          ),
        ],
      ),
      actions: [
        PharmaButton(
          label: 'Cancel',
          variant: PharmaButtonVariant.text,
          size: PharmaButtonSize.small,
          onPressed: () => Navigator.of(context).pop(),
        ),
        PharmaButton(
          label: 'Save review',
          size: PharmaButtonSize.small,
          onPressed: () {
            if (_note.text.trim().isEmpty) {
              setState(() => _error = 'Add a note explaining this decision.');
              return;
            }
            Navigator.of(context).pop(_note.text.trim());
          },
        ),
      ],
    );
  }
}
