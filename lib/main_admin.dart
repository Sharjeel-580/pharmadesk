import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/admin_app.dart';

/// Admin web panel entry point.
///
/// Run:   `flutter run -d chrome -t lib/main_admin.dart`
/// Build: `flutter build web -t lib/main_admin.dart`
///
/// Separate entry point (not a flavor): the admin panel is a different
/// app for different users (owner/staff) sharing the same models,
/// services and Firebase backend as the staff phone app.
/// Firebase init goes here too once the Firebase project exists.
void main() {
  runApp(const ProviderScope(child: AdminApp()));
}
