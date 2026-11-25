import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/white_label.dart';
import '../../core/widgets/design_system.dart';
import 'auth_state.dart';

/// Forgot-password screen — a working mock flow.
///
/// There is no backend (no Firebase project exists), so no email is
/// ever sent. Instead the screen is honest about that and does something
/// real:
///   1. Enter a demo email → the screen shows the demo reset code
///      (deterministic per email) with a clear demo notice.
///   2. Enter that code + a new password → the mock password is replaced
///      for the rest of the session, and the new password signs in on the
///      login screen.
/// Unknown emails are rejected, wrong codes are rejected — never a dead
/// button, never a silent success.
class ForgotPasswordScreen extends ConsumerStatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  ConsumerState<ForgotPasswordScreen> createState() =>
      _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends ConsumerState<ForgotPasswordScreen> {
  final _emailFormKey = GlobalKey<FormState>();
  final _resetFormKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _codeController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();

  /// Step 1 = enter email, step 2 = enter code + new password,
  /// step 3 = done.
  int _step = 1;
  String? _resetCode;
  String? _error;

  @override
  void dispose() {
    _emailController.dispose();
    _codeController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
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

  Future<void> _requestCode() async {
    if (!(_emailFormKey.currentState?.validate() ?? false)) return;
    final code = await ref
        .read(authProvider.notifier)
        .requestPasswordReset(_emailController.text);
    if (code == null) {
      setState(
        () => _error = 'No demo account found for this email. Use one of the demo accounts from the sign-in screen.',
      );
      return;
    }
    setState(() {
      _resetCode = code;
      _error = null;
      _step = 2;
    });
  }

  Future<void> _resetPassword() async {
    if (!(_resetFormKey.currentState?.validate() ?? false)) return;
    final error = await ref
        .read(authProvider.notifier)
        .resetPassword(
          email: _emailController.text,
          code: _codeController.text,
          newPassword: _passwordController.text,
        );
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    setState(() {
      _error = null;
      _step = 3;
    });
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
                Text(
                  brand.appName,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                const Center(child: DemoModeBadge()),
                const SizedBox(height: 24),
                Text(
                  'Reset your password',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Demo mode: there is no email service in the demo, so no '
                  'reset email is sent. Your demo reset code is shown on '
                  'screen instead.',
                ),
                const SizedBox(height: 16),
                if (_step == 1) _buildEmailStep(theme),
                if (_step == 2) _buildResetStep(theme),
                if (_step == 3) _buildDoneStep(theme),
                const SizedBox(height: 16),
                PharmaButton(
                  label: 'Back to sign in',
                  variant: PharmaButtonVariant.text,
                  icon: Icons.arrow_back,
                  onPressed: () => context.go('/login'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildErrorBanner(ThemeData theme) {
    if (_error == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: theme.colorScheme.error.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: theme.colorScheme.error.withValues(alpha: 0.35),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline, size: 18, color: theme.colorScheme.error),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _error!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmailStep(ThemeData theme) {
    return Form(
      key: _emailFormKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildErrorBanner(theme),
          PharmaTextField(
            controller: _emailController,
            label: 'Email',
            hintText: 'owner@demo.pharmadesk',
            prefixIcon: Icons.email_outlined,
            keyboardType: TextInputType.emailAddress,
            validator: _validateEmail,
          ),
          const SizedBox(height: 16),
          PharmaButton(
            label: 'Send reset code',
            icon: Icons.mail_outline,
            expand: true,
            onPressed: _requestCode,
          ),
        ],
      ),
    );
  }

  Widget _buildResetStep(ThemeData theme) {
    return Form(
      key: _resetFormKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildErrorBanner(theme),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: theme.colorScheme.primary.withValues(alpha: 0.3),
              ),
            ),
            child: Column(
              children: [
                Text(
                  'Your demo reset code for ${_emailController.text.trim()}',
                  style: theme.textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  _resetCode ?? '',
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: 6,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'In production this code arrives by email. In the demo '
                  'it is shown here so the flow can be completed.',
                  style: theme.textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          PharmaTextField(
            controller: _codeController,
            label: 'Reset code',
            hintText: '6-digit code shown above',
            prefixIcon: Icons.pin_outlined,
            keyboardType: TextInputType.number,
            validator: (value) =>
                (value ?? '').trim().isEmpty ? 'Enter the reset code.' : null,
          ),
          const SizedBox(height: 12),
          PharmaTextField(
            controller: _passwordController,
            label: 'New password',
            hintText: 'At least 6 characters',
            prefixIcon: Icons.lock_outline,
            obscureText: true,
            validator: (value) => (value ?? '').length < 6
                ? 'Password must be at least 6 characters.'
                : null,
          ),
          const SizedBox(height: 12),
          PharmaTextField(
            controller: _confirmController,
            label: 'Confirm new password',
            hintText: 'Repeat the new password',
            prefixIcon: Icons.lock_outline,
            obscureText: true,
            validator: (value) => value != _passwordController.text
                ? 'Passwords do not match.'
                : null,
          ),
          const SizedBox(height: 16),
          PharmaButton(
            label: 'Reset password',
            icon: Icons.check,
            expand: true,
            onPressed: _resetPassword,
          ),
        ],
      ),
    );
  }

  Widget _buildDoneStep(ThemeData theme) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: theme.colorScheme.primary.withValues(alpha: 0.08),
            shape: BoxShape.circle,
          ),
          child: Icon(
            Icons.check_circle_outline,
            size: 40,
            color: theme.colorScheme.primary,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'Password reset',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 6),
        Text(
          'Your demo password for ${_emailController.text.trim()} has '
          'been changed for this session. Sign in with the new password.',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        PharmaButton(
          label: 'Sign in now',
          icon: Icons.login_outlined,
          expand: true,
          onPressed: () => context.go('/login'),
        ),
      ],
    );
  }
}
