import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/desktop_app.dart';
import 'app/desktop_bootstrap.dart';

/// Windows desktop (counter staff) entry point.
///
/// Run:   `flutter run -d windows -t lib/main_desktop.dart`
/// Build: `flutter build windows -t lib/main_desktop.dart`
///   (CI job `build-windows` in `.github/workflows/build-apk.yml` —
///   this Linux sandbox cannot run a Windows build, D11/D110.)
///
/// Separate entry point (not a flavor): the counter app is a different
/// app for different users (counter staff) sharing the same models,
/// services and Firebase backend. It renders the same desktop shell
/// (sidebar + top bar) as the web admin on wide screens.
///
/// NOTE: firebase_messaging has no Windows implementation; the desktop
/// app reads live order updates from Firestore instead of push.
/// Verified Week 3 Day 4 (D110): no Dart file under `lib/` imports
/// `package:firebase_messaging` — only these doc comments mention it —
/// so nothing in the desktop entry path can hit the missing plugin.
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Windows only: wires sqflite_common_ffi so the sync queue persists
  // in SQLite instead of falling back to memory (D110). No-op on any
  // other host; the web entry point never imports this file.
  await initDesktopPlatform();
  runApp(const ProviderScope(child: DesktopApp()));
}
