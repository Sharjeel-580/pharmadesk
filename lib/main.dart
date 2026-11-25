import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/pharmadesk_app.dart';

/// Default entry point — PharmaDesk staff phone app (Android / iOS).
///
/// Firebase is NOT initialised here yet: no Firebase project exists for
/// PharmaDesk. Once Dazy creates the dedicated Firebase project and the
/// platform config files are added (google-services.json /
/// GoogleService-Info.plist / firebase_options.dart), add
/// `WidgetsFlutterBinding.ensureInitialized()` +
/// `Firebase.initializeApp()` before `runApp`.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: PharmaDeskApp()));
}
