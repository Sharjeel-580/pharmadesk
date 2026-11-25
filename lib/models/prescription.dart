import 'model_utils.dart';

/// Pharmacist review outcome for an uploaded prescription.
///
/// Prescription-only medicines are never dispatched while the linked
/// prescription is still `pending` — the order flow enforces this.
enum PrescriptionStatus { pending, approved, rejected, needsClearerPhoto }

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
/// copy. Week 2 Day 3 (D69) adds those fields to this model;
/// `imageUrl` stays as the demo-era field (sample asset path) and as
/// the display fallback until the upload flow replaces it.
class Prescription {
  final String id;
  final String customerId;
  final String? orderId;
  final String imageUrl;
  final PrescriptionStatus status;
  final String? reviewedBy;
  final DateTime? reviewedAt;
  final String? reviewNotes;

  /// Branch this prescription belongs to (Week 2 Day 3 — D69).
  /// Seeded / legacy records carry no branch id; repositories fall
  /// back to the id prefix (`rx-dha-…` / `rx-glb-…`, D21) until the
  /// seed is migrated. Production records always carry it: the
  /// branch-scoped Storage path and the Firestore rules both need it.
  final String? branchId;

  /// Cloud Storage path of the photo, e.g.
  /// `organizations/{orgId}/branches/{branchId}/prescriptions/{id}.jpg`
  /// (Blaze, D62). The bytes live in Storage; this doc carries only
  /// the metadata. Never a public http(s) URL — the rules reject it.
  final String? photoStoragePath;

  /// MIME type of the uploaded photo, e.g. `image/jpeg`.
  final String? photoContentType;

  /// When the photo was uploaded to Storage, and by whom (uid).
  final DateTime? photoUploadedAt;
  final String? photoUploadedBy;

  /// On-device cache copy of the photo (nullable). The Storage path
  /// above is the source of truth; this is only the offline cache.
  final String? localPhotoPath;

  /// Medicines written on the prescription, as entered by staff for a
  /// manually created record (free text — the photo itself is the
  /// source of truth for seeded records).
  final String? medicinesText;
  final DateTime? createdAt;

  /// Last day the prescription is valid (Week 2 Day 5, D90). An
  /// expired prescription can never unblock an order — the Day 4
  /// dispatch guard checks this as well as the review status — even
  /// when it was approved before it expired. Null on legacy records
  /// means "no expiry recorded": those are treated as valid (the
  /// validity rule only applies once a date exists).
  final DateTime? validUntil;

  /// How many times this prescription has been re-submitted for
  /// review after a rejection / clearer-photo request (Week 2 Day 5,
  /// D91). Each re-submission returns the record to Pending and
  /// clears the previous review; the count is the audit trail.
  final int resubmissionCount;

  const Prescription({
    required this.id,
    required this.customerId,
    this.orderId,
    required this.imageUrl,
    this.status = PrescriptionStatus.pending,
    this.reviewedBy,
    this.reviewedAt,
    this.reviewNotes,
    this.branchId,
    this.photoStoragePath,
    this.photoContentType,
    this.photoUploadedAt,
    this.photoUploadedBy,
    this.localPhotoPath,
    this.medicinesText,
    this.createdAt,
    this.validUntil,
    this.resubmissionCount = 0,
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
    String? branchId,
    bool clearBranchId = false,
    String? photoStoragePath,
    bool clearPhotoStoragePath = false,
    String? photoContentType,
    bool clearPhotoContentType = false,
    DateTime? photoUploadedAt,
    bool clearPhotoUploadedAt = false,
    String? photoUploadedBy,
    bool clearPhotoUploadedBy = false,
    String? localPhotoPath,
    bool clearLocalPhotoPath = false,
    String? medicinesText,
    bool clearMedicinesText = false,
    DateTime? createdAt,
    DateTime? validUntil,
    bool clearValidUntil = false,
    int? resubmissionCount,
  }) {
    return Prescription(
      id: id ?? this.id,
      customerId: customerId ?? this.customerId,
      orderId: clearOrderId ? null : (orderId ?? this.orderId),
      imageUrl: imageUrl ?? this.imageUrl,
      status: status ?? this.status,
      reviewedBy: clearReviewedBy ? null : (reviewedBy ?? this.reviewedBy),
      reviewedAt: clearReviewedAt ? null : (reviewedAt ?? this.reviewedAt),
      reviewNotes: clearReviewNotes ? null : (reviewNotes ?? this.reviewNotes),
      branchId: clearBranchId ? null : (branchId ?? this.branchId),
      photoStoragePath: clearPhotoStoragePath
          ? null
          : (photoStoragePath ?? this.photoStoragePath),
      photoContentType: clearPhotoContentType
          ? null
          : (photoContentType ?? this.photoContentType),
      photoUploadedAt: clearPhotoUploadedAt
          ? null
          : (photoUploadedAt ?? this.photoUploadedAt),
      photoUploadedBy: clearPhotoUploadedBy
          ? null
          : (photoUploadedBy ?? this.photoUploadedBy),
      localPhotoPath: clearLocalPhotoPath
          ? null
          : (localPhotoPath ?? this.localPhotoPath),
      medicinesText: clearMedicinesText
          ? null
          : (medicinesText ?? this.medicinesText),
      createdAt: createdAt ?? this.createdAt,
      validUntil: clearValidUntil ? null : (validUntil ?? this.validUntil),
      resubmissionCount: resubmissionCount ?? this.resubmissionCount,
    );
  }

  factory Prescription.fromMap(String id, Map<String, dynamic> map) {
    return Prescription(
      id: id,
      customerId: map['customerId'] as String? ?? '',
      orderId: map['orderId'] as String?,
      imageUrl: map['imageUrl'] as String? ?? '',
      // Firestore names the field `reviewStatus` (SRS §3); the local
      // map historically used `status` — accept both.
      status: prescriptionStatusFromString(
        map['reviewStatus'] as String? ?? map['status'] as String?,
      ),
      reviewedBy: map['reviewedBy'] as String?,
      reviewedAt: parseDate(map['reviewedAt']),
      reviewNotes: map['reviewNotes'] as String?,
      branchId: map['branchId'] as String?,
      photoStoragePath: map['photoStoragePath'] as String?,
      photoContentType: map['photoContentType'] as String?,
      photoUploadedAt: parseDate(map['photoUploadedAt']),
      photoUploadedBy: map['photoUploadedBy'] as String?,
      localPhotoPath: map['localPhotoPath'] as String?,
      medicinesText: map['medicinesText'] as String?,
      createdAt: parseDate(map['createdAt']),
      validUntil: parseDate(map['validUntil']),
      resubmissionCount: (map['resubmissionCount'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'customerId': customerId,
      'orderId': orderId,
      'imageUrl': imageUrl,
      'status': status.name,
      'reviewStatus': status.name,
      'reviewedBy': reviewedBy,
      'reviewedAt': dateToMap(reviewedAt),
      'reviewNotes': reviewNotes,
      'branchId': branchId,
      'photoStoragePath': photoStoragePath,
      'photoContentType': photoContentType,
      'photoUploadedAt': dateToMap(photoUploadedAt),
      'photoUploadedBy': photoUploadedBy,
      'localPhotoPath': localPhotoPath,
      'medicinesText': medicinesText,
      'createdAt': dateToMap(createdAt),
      'validUntil': dateToMap(validUntil),
      'resubmissionCount': resubmissionCount,
    };
  }
}
