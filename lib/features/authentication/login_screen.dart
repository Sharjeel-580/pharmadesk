import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/white_label.dart';
import '../../core/widgets/design_system.dart';
import 'auth_state.dart';

/// Sign-in screen: email/password form against the mock auth, plus
/// one-tap demo login cards for the five demo accounts (SRS §8.1).
///
/// The demo password (`demo1234`) is shown on screen — this is a demo
/// build with fictional data, and the client needs the credentials in
/// front of them (they are also in `docs/demo-guide.md`).
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscurePassword = true;
  String? _error;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  String? _validateEmail(String? value) {
    final email = (value ?? '').trim();
    if (email.isEmpty) return 'Email is required.';
    if (!email.contains('@') || !email.contains('.')) {
      return 'Enter a valid email address.';
    }
    return null;
  }

  String? _validatePassword(String? value) {
    if ((value ?? '').isEmpty) return 'Password is required.';
    if (value!.length < 6) {
      return 'Password must be at least 6 characters.';
    }
    return null;
  }

  Future<void> _signIn() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final error = await ref
        .read(authProvider.notifier)
        .signIn(_emailController.text, _passwordController.text);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    if (mounted) context.go('/dashboard');
  }

  Future<void> _signInAsDemo(DemoRole role) async {
    await ref.read(authProvider.notifier).signInAsDemo(role);
    if (mounted) context.go('/dashboard');
  }

  @override
  Widget build(BuildContext context) {
    final brand = ref.watch(brandConfigProvider);
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Brand header (white-label).
                Center(
                  child: Container(
                    width: 64,
                    height: 64,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: brand.primaryColor,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Text(
                      brand.appName.isEmpty
                          ? 'P'
                          : brand.appName[0].toUpperCase(),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 32,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  brand.appName,
                  style: theme.textTheme.headlineSmall?.copyWith(
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
                const SizedBox(height: 12),
                const Center(child: DemoModeBadge()),
                const SizedBox(height: 24),
                Text(
                  'Welcome back',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Sign in with your staff email, or tap a demo account below.',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),
                Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      PharmaTextField(
                        controller: _emailController,
                        label: 'Email',
                        hintText: 'owner@demo.pharmadesk',
                        prefixIcon: Icons.email_outlined,
                        keyboardType: TextInputType.emailAddress,
                        validator: _validateEmail,
                      ),
                      const SizedBox(height: 12),
                      PharmaTextField(
                        controller: _passwordController,
                        label: 'Password',
                        hintText: 'Your password',
                        prefixIcon: Icons.lock_outline,
                        obscureText: _obscurePassword,
                        suffixIcon: IconButton(
                          tooltip: _obscurePassword
                              ? 'Show password'
                              : 'Hide password',
                          icon: Icon(
                            _obscurePassword
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                          ),
                          onPressed: () => setState(
                            () => _obscurePassword = !_obscurePassword,
                          ),
                        ),
                        validator: _validatePassword,
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.error.withValues(
                              alpha: 0.08,
                            ),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: theme.colorScheme.error.withValues(
                                alpha: 0.35,
                              ),
                            ),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                Icons.error_outline,
                                size: 18,
                                color: theme.colorScheme.error,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _error!,
                                  style: TextStyle(
                                    color: theme.colorScheme.error,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 16),
                      PharmaButton(
                        label: 'Sign in',
                        icon: Icons.login_outlined,
                        expand: true,
                        onPressed: _signIn,
                      ),
                      const SizedBox(height: 4),
                      Align(
                        alignment: Alignment.centerRight,
                        child: PharmaButton(
                          label: 'Forgot password?',
                          variant: PharmaButtonVariant.text,
                          onPressed: () => context.go('/forgot-password'),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Expanded(child: Divider()),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text(
                        'Demo accounts — one tap to sign in',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    const Expanded(child: Divider()),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  'Demo password for every account: $demoPassword',
                  style: theme.textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                for (final account in demoAccounts)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _DemoAccountCard(
                      account: account,
                      onTap: () => _signInAsDemo(account.role),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One demo account, shown as a tappable card: role, person, email.
class _DemoAccountCard extends StatelessWidget {
  const _DemoAccountCard({required this.account, required this.onTap});

  final DemoAccount account;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final role = account.role;
    return PharmaCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(role.icon, color: theme.colorScheme.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  role.label,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  '${account.user.name} • ${account.email}',
                  style: theme.textTheme.bodySmall,
                ),
                Text(
                  role.description,
                  style: theme.textTheme.bodySmall,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right),
        ],
      ),
    );
  }
}
