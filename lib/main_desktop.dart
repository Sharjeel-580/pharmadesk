import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/desktop_app.dart';

/// Windows desktop (counter staff) entry point.
///
/// Run:   `flutter run -d windows -t lib/main_desktop.dart`
/// Build: `flutter build windows -t lib/main_desktop.dart`
///
/// Separate entry point (not a flavor): the counter app is a different
/// app for different users (counter staff) sharing the same models,
/// services and Firebase backend. Phase 3 target — foundation shell only
/// until then.
/// NOTE: firebase_messaging has no Windows implementation; the desktop
/// app reads live order updates from Firestore instead of push.
void main() {
  runApp(const ProviderScope(child: DesktopApp()));
}
