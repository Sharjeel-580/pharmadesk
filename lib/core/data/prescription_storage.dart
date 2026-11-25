import 'dart:typed_data';

import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'firestore_schema.dart';
import 'repository_factory.dart';

/// Prescription photo upload (Week 2 Day 3, Blaze — D74).
///
/// The photo bytes go to Cloud Storage; the Firestore prescription
/// doc carries only the metadata (`photoStoragePath`,
/// `photoContentType`, `photoUploadedAt`, `photoUploadedBy` —
/// `firestore_schema.dart`, `firebase/storage.rules`). The rules
/// enforce branch isolation + role checks server-side; this module
/// enforces the client-side shape before anything is uploaded:
///
/// - Images only (`image/*` content type — the rules reject anything
///   else with `isImage()`).
/// - Prescription photos ≤ 10 MB (the rules use a strict `< 10 MB`
///   check — 10,485,760 bytes is rejected, not accepted).
/// - Branch-scoped path, built by [FirestoreSchema]
///   (`organizations/{orgId}/branches/{branchId}/prescriptions/{id}.jpg`).
///
/// Two uploaders exist, behind [PrescriptionPhotoUploader]:
///
/// - [FirebasePrescriptionPhotoUploader] — real `firebase_storage`
///   upload. Code-ready; it cannot run until the Firebase project
///   exists (no project, no bucket — D13).
/// - [LocalPrescriptionPhotoUploader] (default) — on-device fallback
///   while no project exists: the bytes are held in memory and the
///   result carries a `localPhotoPath` (`prescriptions/{id}.jpg`
///   under the app's cache) instead of a Storage path, so the demo
///   keeps its current sample behaviour and no code path assumes a
///   cloud URL exists. The Firestore doc still gets the metadata
///   shape (with `photoStoragePath == null` until the real upload
///   lands).

/// Maximum prescription photo size: 10 MiB, strict (`<`, per
/// `firebase/storage.rules` `sizeWithin(10)`).
const maxPrescriptionPhotoBytes = 10 * 1024 * 1024;

/// Result of a prescription photo upload.
class PrescriptionPhotoUpload {
  const PrescriptionPhotoUpload({
    this.storagePath,
    this.localPath,
    required this.contentType,
    required this.uploadedAt,
    required this.uploadedBy,
  });

  /// Cloud Storage path (Firebase uploader only).
  final String? storagePath;

  /// On-device cache path (local uploader only).
  final String? localPath;

  final String contentType;
  final DateTime uploadedAt;

  /// Uid of the uploader.
  final String uploadedBy;

  /// True when the photo lives in Cloud Storage.
  bool get isInCloud => storagePath != null;

  /// Metadata map for the Firestore prescription doc (the
  /// `photoStoragePath` is `null` for local uploads — the doc must
  /// never carry a fake cloud path).
  Map<String, dynamic> get metadata => {
    'photoStoragePath': storagePath,
    'photoContentType': contentType,
    'photoUploadedAt': uploadedAt.toIso8601String(),
    'photoUploadedBy': uploadedBy,
    'localPhotoPath': localPath,
  };
}

/// A validated, ready-to-execute upload: storage path + metadata.
/// Pure — unit-tested without Firebase.
class PrescriptionPhotoUploadRequest {
  const PrescriptionPhotoUploadRequest({
    required this.storagePath,
    required this.contentType,
    required this.uploadedBy,
    required this.bytes,
  });

  /// `organizations/{orgId}/branches/{branchId}/prescriptions/{id}.jpg`.
  final String storagePath;
  final String contentType;
  final String uploadedBy;
  final Uint8List bytes;
}

/// Validates a photo upload and builds the request. Throws
/// [ArgumentError] on a non-image content type or an oversized file.
PrescriptionPhotoUploadRequest buildPrescriptionPhotoUpload({
  required String orgId,
  required String branchId,
  required String prescriptionId,
  required Uint8List bytes,
  required String contentType,
  required String uploadedBy,
}) {
  if (!contentType.startsWith('image/')) {
    throw ArgumentError(
      'Prescription photos must be images (got "$contentType").',
    );
  }
  if (bytes.lengthInBytes >= maxPrescriptionPhotoBytes) {
    throw ArgumentError(
      'Prescription photo is ${bytes.lengthInBytes} bytes — the limit '
      'is under 10 MB.',
    );
  }
  if (prescriptionId.isEmpty) {
    throw ArgumentError('A prescription id is required to upload a photo.');
  }
  return PrescriptionPhotoUploadRequest(
    storagePath: FirestoreSchema.storagePrescriptionPath(
      orgId,
      branchId,
      prescriptionId,
    ),
    contentType: contentType,
    uploadedBy: uploadedBy,
    bytes: bytes,
  );
}

/// Uploads prescription photos.
abstract class PrescriptionPhotoUploader {
  /// Uploads the photo bytes for [prescriptionId] and returns the
  /// upload result (Storage path for the Firebase uploader, local
  /// path for the fallback).
  Future<PrescriptionPhotoUpload> uploadPrescriptionPhoto({
    required String orgId,
    required String branchId,
    required String prescriptionId,
    required Uint8List bytes,
    required String contentType,
    required String uploadedBy,
  });
}

/// Real uploader: `firebase_storage` (Blaze). Code-ready — needs the
/// Firebase project + bucket (D13).
class FirebasePrescriptionPhotoUploader implements PrescriptionPhotoUploader {
  FirebasePrescriptionPhotoUploader({FirebaseStorage? storage})
    : _storage = storage ?? FirebaseStorage.instance;

  final FirebaseStorage _storage;

  @override
  Future<PrescriptionPhotoUpload> uploadPrescriptionPhoto({
    required String orgId,
    required String branchId,
    required String prescriptionId,
    required Uint8List bytes,
    required String contentType,
    required String uploadedBy,
  }) async {
    final request = buildPrescriptionPhotoUpload(
      orgId: orgId,
      branchId: branchId,
      prescriptionId: prescriptionId,
      bytes: bytes,
      contentType: contentType,
      uploadedBy: uploadedBy,
    );
    final ref = _storage.ref(request.storagePath);
    await ref.putData(
      request.bytes,
      SettableMetadata(contentType: request.contentType),
    );
    return PrescriptionPhotoUpload(
      storagePath: request.storagePath,
      contentType: request.contentType,
      uploadedAt: DateTime.now(),
      uploadedBy: uploadedBy,
    );
  }
}

/// On-device fallback while no Firebase project exists: the bytes are
/// kept in memory (keyed by prescription id) and the result carries
/// a local cache path. Nothing is uploaded anywhere.
class LocalPrescriptionPhotoUploader implements PrescriptionPhotoUploader {
  /// Held bytes, keyed by prescription id (test seam: lets tests
  /// prove the bytes were kept, not dropped).
  final Map<String, Uint8List> storedBytes = {};

  @override
  Future<PrescriptionPhotoUpload> uploadPrescriptionPhoto({
    required String orgId,
    required String branchId,
    required String prescriptionId,
    required Uint8List bytes,
    required String contentType,
    required String uploadedBy,
  }) async {
    // Validation is shared with the Firebase path — the same
    // content-type / size rules apply before anything is stored.
    buildPrescriptionPhotoUpload(
      orgId: orgId,
      branchId: branchId,
      prescriptionId: prescriptionId,
      bytes: bytes,
      contentType: contentType,
      uploadedBy: uploadedBy,
    );
    storedBytes[prescriptionId] = bytes;
    return PrescriptionPhotoUpload(
      localPath: 'prescriptions/$prescriptionId.jpg',
      contentType: contentType,
      uploadedAt: DateTime.now(),
      uploadedBy: uploadedBy,
    );
  }
}

/// The photo uploader for the app: the local fallback until the
/// Firebase project exists. It reads the repository bundle
/// (`repository_factory.dart`), so overriding the bundle switches
/// the uploader to Cloud Storage along with the data repositories.
final prescriptionPhotoUploaderProvider = Provider<PrescriptionPhotoUploader>(
  (ref) => ref.watch(repositoryBundleProvider).photoUploader,
);
