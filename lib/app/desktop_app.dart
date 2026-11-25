import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/routing/app_router.dart';
import '../core/theme/app_theme.dart';
import '../core/theme/theme_mode_provider.dart';
import '../core/theme/white_label.dart';
import '../features/authentication/auth_state.dart';

/// Windows desktop shell — the counter-staff frontend (Phase 3).
///
/// Run with: `flutter run -d windows -t lib/main_desktop.dart`
/// Build with: `flutter build windows -t lib/main_desktop.dart`
///
/// Uses the same Day 2 app shell (desktop layout: sidebar + top bar).
/// Phase 3 screens: counter billing/POS, print receipts, live order
/// queue, prescription review at the counter. Until Phase 3 this shell
/// shares the same models and services as the staff phone app and admin
/// web.
///
/// NOTE: firebase_messaging has no Windows implementation — push
/// notifications on desktop are out of scope; the desktop app reads order
/// updates live from Firestore instead. See docs/technical-decisions.md.
class DesktopApp extends ConsumerStatefulWidget {
  const DesktopApp({super.key});

  @override
  ConsumerState<DesktopApp> createState() => _DesktopAppState();
}

class _DesktopAppState extends ConsumerState<DesktopApp> {
  late final GoRouter _router;

  /// Notifies the router when auth state changes so its redirect
  /// re-runs (login → dashboard, logout → login).
  final _authRefresh = AuthRefreshNotifier();

  @override
  void initState() {
    super.initState();
    _router = createAppRouter(
      refreshListenable: _authRefresh,
      isSignedIn: () => ref.read(authProvider) != null,
    );
  }

  @override
  void dispose() {
    _authRefresh.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(authProvider, (_, _) => _authRefresh.refresh());
    final brand = ref.watch(brandConfigProvider);
    return MaterialApp.router(
      title: '${brand.appName} — Counter',
      theme: AppTheme.light(brand),
      darkTheme: AppTheme.dark(brand),
      themeMode: ref.watch(themeModeProvider),
      routerConfig: _router,
      debugShowCheckedModeBanner: false,
    );
  }
}
