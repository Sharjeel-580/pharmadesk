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
