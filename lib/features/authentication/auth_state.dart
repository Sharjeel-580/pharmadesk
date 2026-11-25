import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/data/auth_repository.dart';
import '../../core/data/demo_accounts.dart';
import '../../core/services/branch_context.dart';

export '../../core/data/demo_accounts.dart';

/// Signed-in user state (Week 2 Day 3).
///
/// The state is an [AppUser] (uid, email, display name, org, branch
/// list, SRS §5.1 role key) and every operation delegates to the
/// [AuthRepository] behind [authRepositoryProvider] — the mock
/// repository by default (the five demo accounts, password
/// `demo1234`), Firebase Auth once the project exists. Screens call
/// this notifier; they never touch the repository directly.
///
/// The demo account definitions moved to
/// `core/data/demo_accounts.dart` (re-exported here so existing
/// imports of [DemoRole] / [demoAccounts] keep working).
///
/// Passwords are demo-only, shared in `docs/demo-guide.md`. Never use
/// these in production.
class AuthNotifier extends Notifier<AppUser?> {
  AuthRepository get _repository => ref.read(authRepositoryProvider);

  @override
  AppUser? build() => null;

  /// Signs in with email + password.
  ///
  /// Returns `null` on success, or an error message to show on the
  /// login form on failure (unknown email / wrong password).
  Future<String?> signIn(String email, String password) async {
    try {
      final user = await _repository.signInWithEmail(email, password);
      _applySignIn(user);
      return null;
    } on AuthException catch (error) {
      return error.message;
    } on UnsupportedError catch (error) {
      return error.message ?? 'Sign-in is not available.';
    }
  }

  /// One-tap demo sign-in as [role] (the demo-login cards).
  Future<void> signInAsDemo(DemoRole role) async {
    final user = await _repository.signInAsDemo(role);
    _applySignIn(user);
  }

  Future<void> signOut() async {
    await _repository.signOut();
    state = null;
  }

  void _applySignIn(AppUser user) {
    state = user;
    // Branch-scoped roles start in their home branch; all-branch
    // roles (owner, HO, …) keep whichever branch was active.
    if (!user.seesAllBranches) {
      final homeBranch = user.branchId;
      if (homeBranch != null) {
        ref.read(activeBranchProvider.notifier).switchTo(homeBranch);
      }
    }
  }

  /// Starts the forgot-password flow for [email].
  ///
  /// Returns the demo reset code to display on screen, or `null`
  /// when no account has that email (mock) or when the reset runs
  /// by email (Firebase). No email is ever sent by the mock — there
  /// is no backend in the demo; the code is shown on screen instead
  /// (the forgot-password screen explains this).
  Future<String?> requestPasswordReset(String email) {
    return _repository.requestPasswordReset(email);
  }

  /// The code a reset step shows for [email] (without starting a flow).
  /// Kept public so tests can assert the deterministic code.
  static String resetCodeFor(String email) =>
      MockAuthRepository.resetCodeFor(email);

  /// Completes a mock reset: checks the code, then replaces the demo
  /// password for [email] for the rest of the session.
  ///
  /// Returns `null` on success, or an error message on failure.
  Future<String?> resetPassword({
    required String email,
    required String code,
    required String newPassword,
  }) async {
    try {
      await _repository.resetPassword(
        email: email,
        code: code,
        newPassword: newPassword,
      );
      return null;
    } on AuthException catch (error) {
      return error.message;
    } on UnsupportedError catch (error) {
      return error.message ?? 'Password reset is not available.';
    }
  }
}

/// The signed-in user, or `null` when signed out.
final authProvider = NotifierProvider<AuthNotifier, AppUser?>(AuthNotifier.new);
