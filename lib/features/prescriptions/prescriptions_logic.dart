import '../../core/data/auth_repository.dart';
import '../../core/data/permission_service.dart';
import '../../core/widgets/badges.dart';
import '../../models/customer.dart';
import '../../models/prescription.dart';

/// Day 7 prescription review logic — pure functions over plain lists.
///
/// A prescription is Pending until a pharmacist approves or rejects
/// it (SRS FR-ORD-04, FR-POS-12). Approving unblocks any order the
/// Day 4 dispatch guard was holding: the guard reads the prescription
/// status live (`advanceBlockedReason`), so once the review lands the
/// order can be dispatched with no other change.

/// Human label for a review status.
String prescriptionStatusLabel(PrescriptionStatus status) => switch (status) {
  PrescriptionStatus.pending => 'Pending review',
  PrescriptionStatus.approved => 'Approved',
  PrescriptionStatus.rejected => 'Rejected',
  PrescriptionStatus.needsClearerPhoto => 'Needs clearer photo',
};

/// Badge kind for a review status.
StatusKind prescriptionStatusKind(PrescriptionStatus status) =>
    switch (status) {
      PrescriptionStatus.pending => StatusKind.warning,
      PrescriptionStatus.approved => StatusKind.success,
      PrescriptionStatus.rejected => StatusKind.danger,
      PrescriptionStatus.needsClearerPhoto => StatusKind.info,
    };

/// True when the prescription can still be reviewed: only Pending
/// records (an approved/rejected record is history — review it again
/// by creating a new prescription, never by rewriting the old one).
bool canReview(PrescriptionStatus status) =>
    status == PrescriptionStatus.pending;

/// Default validity for a new prescription: 30 days from issue
/// (Week 2 Day 5, D90 — a documented demo rule; the SRS names no
/// validity period, and the form lets staff change the date).
const defaultPrescriptionValidityDays = 30;

/// True when the prescription's validity has run out. The validity
/// date is a calendar day: a prescription is expired when its
/// `validUntil` day is before today. A record with no `validUntil`
/// (legacy, pre-Day 5) is treated as valid — the rule only applies
/// once a date exists.
bool isPrescriptionExpired(Prescription rx, DateTime now) {
  final validUntil = rx.validUntil;
  if (validUntil == null) return false;
  final today = DateTime(now.year, now.month, now.day);
  final lastDay = DateTime(
    validUntil.year,
    validUntil.month,
    validUntil.day,
  );
  return lastDay.isBefore(today);
}

/// True when the prescription lets its linked order be dispatched:
/// approved AND still within its validity period. An approved but
/// expired prescription blocks dispatch exactly like a pending one
/// (the Day 4 guard checks this — D90).
bool canUnblockOrder(Prescription rx, DateTime now) =>
    rx.status == PrescriptionStatus.approved &&
    !isPrescriptionExpired(rx, now);

/// True when the prescription can be re-submitted for review: only
/// Rejected and Needs-clearer-photo records. Approved and Pending
/// records have nothing to re-submit.
bool canResubmit(PrescriptionStatus status) =>
    status == PrescriptionStatus.rejected ||
    status == PrescriptionStatus.needsClearerPhoto;

/// Validates a re-submission. Returns the list of problems (empty =
/// valid). The record must be re-submittable, and the new validity
/// date must be set and not in the past — re-submitting an already
/// expired prescription without a live validity date would approve
/// a record that still cannot unblock its order.
List<String> validateResubmit({
  required PrescriptionStatus current,
  required DateTime? validUntil,
  required DateTime now,
}) {
  final errors = <String>[];
  if (!canResubmit(current)) {
    errors.add('Only a rejected prescription (or one needing a clearer photo) can be re-submitted.');
  }
  if (validUntil == null) {
    errors.add('Set a validity date for the re-submitted prescription.');
  } else {
    final today = DateTime(now.year, now.month, now.day);
    final lastDay = DateTime(
      validUntil.year,
      validUntil.month,
      validUntil.day,
    );
    if (lastDay.isBefore(today)) {
      errors.add('The validity date is already past — pick a future date.');
    }
  }
  return errors;
}

/// True when [user] may re-submit a prescription in [branchId]
/// (Week 2 Day 5, D91).
///
/// Re-submission is a staff action, not a review: the pharmacist
/// who rejected the record does not re-submit it — the branch
/// staff who hold the prescription do. The SRS matrix has no
/// "re-submit" capability, so the rule is derived from the two
/// capabilities that touch prescriptions in a branch: anyone who
/// may sell at the counter there (`posSell` write — Owner, HO
/// Admin, Branch Mgr own, Cashier own) or review there (`rxReview`
/// write — Pharmacist own) may re-submit. Inventory Manager,
/// Accountant, Regional Mgr, Super Admin and Auditor may not:
/// none of them handles prescriptions in a branch.
bool canResubmitFor(AppUser? user, String branchId) =>
    permissionService.canWrite(user, 'posSell', branchId) ||
    permissionService.canWrite(user, 'rxReview', branchId);

/// Validates a review action. Returns the list of problems (empty =
/// valid). A rejection (or a clearer-photo request) must carry a note
/// so the customer/staff knows what was wrong.
List<String> validateReview({
  required PrescriptionStatus current,
  required PrescriptionStatus target,
  String note = '',
}) {
  final errors = <String>[];
  if (!canReview(current)) {
    errors.add('This prescription has already been reviewed.');
  }
  if ((target == PrescriptionStatus.rejected ||
          target == PrescriptionStatus.needsClearerPhoto) &&
      note.trim().isEmpty) {
    errors.add('Add a note explaining why this prescription was not approved.');
  }
  if (target == PrescriptionStatus.pending) {
    errors.add('A review must approve, reject or ask for a clearer photo.');
  }
  return errors;
}

/// Validates the new-prescription form. Returns the list of problems
/// (empty = valid).
List<String> validateNewPrescription({
  String? customerId,
  String medicinesText = '',
}) {
  final errors = <String>[];
  if (customerId == null || customerId.isEmpty) {
    errors.add('Select the patient (customer) for this prescription.');
  }
  if (medicinesText.trim().isEmpty) {
    errors.add('Enter the medicines written on the prescription.');
  }
  return errors;
}

/// Filters prescriptions: status, then free text (id, customer name
/// or phone, case-insensitive, partial).
List<Prescription> filterPrescriptions({
  required List<Prescription> prescriptions,
  PrescriptionStatus? statusFilter,
  String query = '',
  Map<String, Customer> customersById = const {},
}) {
  final needle = query.trim().toLowerCase();
  return prescriptions.where((rx) {
    if (statusFilter != null && rx.status != statusFilter) return false;
    if (needle.isEmpty) return true;
    final customer = customersById[rx.customerId];
    final haystacks = [
      rx.id.toLowerCase(),
      customer?.name.toLowerCase() ?? '',
      customer?.phone.toLowerCase() ?? '',
      rx.medicinesText?.toLowerCase() ?? '',
    ];
    return haystacks.any((haystack) => haystack.contains(needle));
  }).toList()..sort((a, b) {
    final aTime = a.createdAt;
    final bTime = b.createdAt;
    if (aTime == null && bTime == null) return 0;
    if (aTime == null) return 1;
    if (bTime == null) return -1;
    return bTime.compareTo(aTime);
  });
}

/// Counts per review status, for the list's filter chips.
Map<PrescriptionStatus, int> prescriptionStatusCounts(
  List<Prescription> prescriptions,
) {
  final counts = <PrescriptionStatus, int>{};
  for (final rx in prescriptions) {
    counts[rx.status] = (counts[rx.status] ?? 0) + 1;
  }
  return counts;
}
