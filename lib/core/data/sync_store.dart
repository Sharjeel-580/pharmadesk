/// Sync store factory — platform-conditional.
///
/// On mobile (Android/iOS) the queue is persisted in SQLite via
/// sqflite, so pending operations survive a restart. On the web the
/// queue is in-memory only (resets on restart) until Firestore exists.
///
/// Same conditional-import pattern as `lib/core/utils/file_download.dart`.
library;

export 'sync_store_io.dart' if (dart.library.html) 'sync_store_web.dart';
