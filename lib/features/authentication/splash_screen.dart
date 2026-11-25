import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/white_label.dart';
import '../../core/widgets/demo_mode_badge.dart';
import 'auth_state.dart';

/// Branded splash screen (white-label brand, DEMO MODE badge).
///
/// Shows briefly while the app starts, then routes on: to the dashboard
/// when a demo session already exists in memory, otherwise to login.
class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  /// How long the splash stays visible (short — it is a brand beat,
  /// not a loading screen; there is no backend to wait on in the demo).
  static const splashDuration = Duration(milliseconds: 1200);

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen> {
  @override
  void initState() {
    super.initState();
    Future.delayed(SplashScreen.splashDuration, () {
      if (!mounted) return;
      final signedIn = ref.read(authProvider) != null;
      context.go(signedIn ? '/dashboard' : '/login');
    });
  }

  @override
  Widget build(BuildContext context) {
    final brand = ref.watch(brandConfigProvider);
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 88,
                height: 88,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: brand.primaryColor,
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Text(
                  brand.appName.isEmpty
                      ? 'P'
                      : brand.appName[0].toUpperCase(),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 44,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                brand.appName,
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              Text(
                brand.organizationName,
                style: theme.textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              const DemoModeBadge(),
              const SizedBox(height: 32),
              const SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
              const SizedBox(height: 32),
              Text(
                '${brand.appName} v1.0.0',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
