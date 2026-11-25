import 'sync_queue.dart';

/// Creates the platform sync store: in-memory on the web.
///
/// Web has no sqflite, so the queue lives in memory and resets when
/// the app restarts. That is the documented behaviour until Firestore
/// exists — Firestore's own offline persistence takes over then
/// (SRS §2.5). Nothing on the web path imports sqflite.
SyncStore createSyncStore() => InMemorySyncStore();
