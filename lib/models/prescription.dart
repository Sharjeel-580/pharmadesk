import 'model_utils.dart';

/// Pharmacist review outcome for an uploaded prescription.
///
/// Prescription-only medicines are never dispatched while the linked
/// prescription is still `pending` — the order flow enforces this.
enum PrescriptionStatus {
  pending,
  approved,
  rejected,
  needsClearerPhoto,
}

PrescriptionStatus prescriptionStatusFromString(String? value) {
  switch (value) {
    case 'approved':
      return PrescriptionStatus.approved;
    case 'rejected':
      return PrescriptionStatus.rejected;
    case 'needsClearerPhoto':
      return PrescriptionStatus.needsClearerPhoto;
    case 'pending':
    default:
      return PrescriptionStatus.pending;
  }
}

/// An uploaded prescription photo.
///
/// Firestore collection: `prescriptions`.
/// Day 7 (D45): in the demo the record points at a bundled sample
/// asset (`assets/images/prescriptions/sample-prescription-*.png`,
/// clearly marked SAMPLE) — never a network URL.
/// Production (Blaze, D62): the photo is captured on-device and
/// uploaded to Cloud Storage at
/// `organizations/{orgId}/branches/{branchId}/prescriptions/{id}.jpg`
/// (see `lib/core/data/firestore_schema.dart` storage paths and
/// `firebase/storage.rules`); the Firestore doc carries the metadata
/// (`photoStoragePath`, `photoContentType`, `photoUploadedAt`,
/// `photoUploadedBy`) and `localPhotoPath` is only the on-device cache
/// copy. `imageUrl` below is the demo-era field (sample asset path);
/// the Firebase-wiring chunk migrates it to the Storage metadata
/// fields when the upload flow lands.
class Prescription {
  final String id;
  final String customerId;
  final String? orderId;
  final String imageUrl;
  final PrescriptionStatus status;
  final String? reviewedBy;
  final DateTime? reviewedAt;
  final String? reviewNotes;

  /// Medicines written on the prescription, as entered by staff for a
  /// manually created record (free text — the photo itself is the
  /// source of truth for seeded records).
  final String? medicinesText;
  final DateTime? createdAt;

  const Prescription({
    required this.id,
    required this.customerId,
    this.orderId,
    required this.imageUrl,
    this.status = PrescriptionStatus.pending,
    this.reviewedBy,
    this.reviewedAt,
    this.reviewNotes,
    this.medicinesText,
    this.createdAt,
  });

  Prescription copyWith({
    String? id,
    String? customerId,
    String? orderId,
    bool clearOrderId = false,
    String? imageUrl,
    PrescriptionStatus? status,
    String? reviewedBy,
    bool clearReviewedBy = false,
    DateTime? reviewedAt,
    bool clearReviewedAt = false,
    String? reviewNotes,
    bool clearReviewNotes = false,
    String? medicinesText,
    bool clearMedicinesText = false,
    DateTime? createdAt,
  }) {
    return Prescription(
      id: id ?? this.id,
      customerId: customerId ?? this.customerId,
      orderId: clearOrderId ? null : (orderId ?? this.orderId),
      imageUrl: imageUrl ?? this.imageUrl,
      status: status ?? this.status,
      reviewedBy: clearReviewedBy ? null : (reviewedBy ?? this.reviewedBy),
      reviewedAt: clearReviewedAt ? null : (reviewedAt ?? this.reviewedAt),
      reviewNotes: clearReviewNotes
          ? null
          : (reviewNotes ?? this.reviewNotes),
      medicinesText: clearMedicinesText
          ? null
          : (medicinesText ?? this.medicinesText),
      createdAt: createdAt ?? this.createdAt,
    );
  }

  factory Prescription.fromMap(String id, Map<String, dynamic> map) {
    return Prescription(
      id: id,
      customerId: map['customerId'] as String? ?? '',
      orderId: map['orderId'] as String?,
      imageUrl: map['imageUrl'] as String? ?? '',
      status: prescriptionStatusFromString(map['status'] as String?),
      reviewedBy: map['reviewedBy'] as String?,
      reviewedAt: parseDate(map['reviewedAt']),
      reviewNotes: map['reviewNotes'] as String?,
      medicinesText: map['medicinesText'] as String?,
      createdAt: parseDate(map['createdAt']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'customerId': customerId,
      'orderId': orderId,
      'imageUrl': imageUrl,
      'status': status.name,
      'reviewedBy': reviewedBy,
      'reviewedAt': dateToMap(reviewedAt),
      'reviewNotes': reviewNotes,
      'medicinesText': medicinesText,
      'createdAt': dateToMap(createdAt),
    };
  }
}
