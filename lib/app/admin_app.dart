import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/routing/app_router.dart';
import '../core/theme/app_theme.dart';
import '../core/theme/theme_mode_provider.dart';
import '../core/theme/white_label.dart';
import '../features/authentication/auth_state.dart';

/// Admin web panel — the owner/staff frontend.
///
/// Run with: `flutter run -d chrome -t lib/main_admin.dart`
/// Build with: `flutter build web -t lib/main_admin.dart`
///
/// Uses the same Day 2 app shell as the phone app; on wide screens the
/// shell renders the desktop layout (sidebar + top bar), which is the
/// web admin layout. Shares the same models and (later) services as the
/// staff phone app.
class AdminApp extends ConsumerStatefulWidget {
  const AdminApp({super.key});

  @override
  ConsumerState<AdminApp> createState() => _AdminAppState();
}

class _AdminAppState extends ConsumerState<AdminApp> {
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
      title: '${brand.appName} — Admin',
      theme: AppTheme.light(brand),
      darkTheme: AppTheme.dark(brand),
      themeMode: ref.watch(themeModeProvider),
      routerConfig: _router,
      debugShowCheckedModeBanner: false,
    );
  }
}
