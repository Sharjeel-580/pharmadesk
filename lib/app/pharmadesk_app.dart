import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/routing/app_router.dart';
import '../core/theme/app_theme.dart';
import '../core/theme/theme_mode_provider.dart';
import '../core/theme/white_label.dart';
import '../features/authentication/auth_state.dart';

/// PharmaDesk root widget — staff phone app (default entry point).
///
/// Wraps the app in Riverpod, applies the active brand's theme
/// (white-label) and the user's light/dark choice, and routes with
/// GoRouter through the Day 2 app shell (sidebar on desktop, bottom
/// navigation on phone).
///
/// Firebase is NOT initialised here yet: no Firebase project exists.
/// Once Dazy creates the dedicated project and the platform config files
/// are added, add `WidgetsFlutterBinding.ensureInitialized()` +
/// `Firebase.initializeApp()` in main.dart before `runApp`.
class PharmaDeskApp extends ConsumerStatefulWidget {
  const PharmaDeskApp({super.key});

  @override
  ConsumerState<PharmaDeskApp> createState() => _PharmaDeskAppState();
}

class _PharmaDeskAppState extends ConsumerState<PharmaDeskApp> {
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
    final themeMode = ref.watch(themeModeProvider);
    return MaterialApp.router(
      title: brand.appName,
      theme: AppTheme.light(brand),
      darkTheme: AppTheme.dark(brand),
      themeMode: themeMode,
      routerConfig: _router,
      debugShowCheckedModeBanner: false,
    );
  }
}
