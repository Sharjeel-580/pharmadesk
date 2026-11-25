import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Windows desktop platform init (Week 3 Day 4, D110).
///
/// The desktop entry point ([main_desktop.dart]) calls this BEFORE
/// the app widget is built, so the sync store opens a real SQLite
/// file on Windows instead of falling back to memory:
///
/// - `sqfliteFfiInit()` loads the bundled sqlite3 library.
/// - Setting the global [databaseFactory] to [databaseFactoryFfi]
///   makes every `sqflite` call in the app (the sync store's
///   `openDatabase` / `getDatabasesPath`) run on the FFI backend.
///   `sqflite` on Windows has no platform implementation of its
///   own — without this, opening the database throws and
///   [SqfliteSyncStore] falls back to its in-memory map (see
///   `sync_store_io.dart`).
///
/// Windows-only on purpose: Android/iOS keep the platform
/// implementation (setting the FFI factory there would change a
/// working path), and the web never reaches this file — the web
/// entry point does not import it, so the web build never sees
/// `dart:io` or `sqflite` (D61-adjacent rule in
/// `sync_store_web.dart`). On any non-Windows host this is a no-op
/// that returns immediately.
Future<void> initDesktopPlatform() async {
  if (!Platform.isWindows) return;
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
}
