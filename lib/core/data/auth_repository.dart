import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/branch_context.dart';
import 'demo_accounts.dart';
import 'firestore_schema.dart';
import 'repository_factory.dart';

/// Firebase Auth wiring (Week 2 Day 3, SRS §5.2).
///
/// The app signs in through the [AuthRepository] interface; screens
/// and notifiers never call Firebase Auth directly. Two
/// implementations exist:
///
/// - [MockAuthRepository] (default): the five demo accounts
///   (`demo_accounts.dart`, password `demo1234`), in-memory only.
///   The login screens keep working exactly as before.
/// - [FirebaseAuthRepository]: real Firebase Auth (email/password)
///   with the custom-claims design from `firebase/firestore.rules`
///   (`orgId` / `branchIds[]` / `role`). Code-ready, but it cannot
///   run until the Firebase project exists (no project, no
///   `Firebase.initializeApp()` — D13, Dazy-only).
///
/// The signed-in user is an [AppUser]: uid, email, display name, org,
/// branch list and the SRS §5.1 role key. The role key is the
/// snake_case claim value (`owner`, `branch_manager`, …) from
/// `firebase/firestore.rules` — NOT the display name from the
/// settings matrix (`roles_permissions.dart`); [roleDisplayName]
/// converts between the two.

/// Thrown by [AuthRepository] methods when sign-in / reset fails.
/// The [message] is safe to show on the login form.
class AuthException implements Exception {
  const AuthException(this.message);

  final String message;

  @override
  String toString() => 'AuthException: $message';
}

/// A signed-in user, as the app sees them.
///
/// Built either from a demo account ([AppUser.fromDemoUser]) or from
/// a Firebase user + its ID-token custom claims
/// ([appUserFromClaims]). The [demoRole] is set only when the role
/// key maps onto one of the five demo roles; SRS-only roles (HO
/// Admin, Accountant, Auditor, …) have `demoRole == null` and are
/// still fully usable — permissions consult [roleKey], never the demo
/// role (see `permission_service.dart`).
class AppUser {
  const AppUser({
    required this.uid,
    required this.email,
    required this.displayName,
    required this.orgId,
    required this.branchIds,
    required this.roleKey,
    this.demoRole,
    this.homeBranchId,
  });

  /// Firebase uid, or the demo account id (`demo-owner`, …).
  final String uid;
  final String email;

  /// Display name (Firebase `displayName`, demo account name).
  final String displayName;

  /// Organization id from the `orgId` claim.
  final String orgId;

  /// Branch ids from the `branchIds` claim (empty = no branch).
  final List<String> branchIds;

  /// SRS §5.1 role key, e.g. `owner`, `branch_manager`, `pharmacist`.
  final String roleKey;

  /// Demo role when [roleKey] maps onto one (see [demoRoleFromRoleKey]).
  final DemoRole? demoRole;

  /// Home branch for branch-scoped roles; `null` for all-branch
  /// roles (owner, HO, …), which keep whichever branch is active.
  final String? homeBranchId;

  /// Display name, for the shell / dashboard / profile screens.
  String get name => displayName;

  /// Human role label (`Owner`, `Branch Mgr`, …).
  String get roleLabel => roleDisplayName(roleKey);

  /// Home branch: `null` for all-branch users.
  String? get branchId => homeBranchId;

  /// True for the head-office roles, which read all branches of their
  /// org (same set as `isHeadOffice()` in `firebase/firestore.rules`).
  bool get seesAllBranches => const {
    'super_admin',
    'owner',
    'ho_admin',
    'accountant',
    'auditor',
  }.contains(roleKey);

  /// Builds the signed-in user for a demo account. Branch-scoped
  /// roles get their home branch; the owner gets every demo branch
  /// and no home branch (all-branch role).
  factory AppUser.fromDemoUser(
    DemoUser user, {
    String orgId = demoOrganizationId,
  }) {
    final branches = user.branchId != null
        ? [user.branchId!]
        : [for (final branch in demoBranches) branch.id];
    return AppUser(
      uid: user.id,
      email: user.email,
      displayName: user.name,
      orgId: orgId,
      branchIds: branches,
      roleKey: user.role.roleKey,
      demoRole: user.role,
      homeBranchId: user.branchId,
    );
  }
}

/// SRS §5.1 role keys (the custom-claims `role` values, exactly as in
/// `firebase/firestore.rules`), in matrix order.
const srsRoleKeys = <String>[
  'super_admin',
  'owner',
  'ho_admin',
  'regional_manager',
  'branch_manager',
  'pharmacist',
  'cashier',
  'inventory_manager',
  'accountant',
  'auditor',
];

/// Display name for a role key (`roles_permissions.dart` vocabulary).
/// Unknown keys are returned unchanged.
String roleDisplayName(String roleKey) => switch (roleKey) {
  'super_admin' => 'Super Admin',
  'owner' => 'Owner',
  'ho_admin' => 'HO Admin',
  'regional_manager' => 'Regional Mgr',
  'branch_manager' => 'Branch Mgr',
  'pharmacist' => 'Pharmacist',
  'cashier' => 'Cashier',
  'inventory_manager' => 'Inventory Mgr',
  'accountant' => 'Accountant',
  'auditor' => 'Auditor',
  _ => roleKey,
};

/// Demo role for a role key, or `null` when the key has no demo
/// account (Super Admin, HO Admin, Regional Manager, Accountant,
/// Auditor).
DemoRole? demoRoleFromRoleKey(String roleKey) => switch (roleKey) {
  'owner' => DemoRole.owner,
  'branch_manager' => DemoRole.branchManager,
  'pharmacist' => DemoRole.pharmacist,
  'cashier' => DemoRole.cashier,
  'inventory_manager' => DemoRole.inventoryManager,
  _ => null,
};

/// Builds an [AppUser] from a Firebase uid + email + the ID-token
/// custom claims (`orgId`, `branchIds`, `role`). Pure — unit-tested
/// without Firebase. Missing claims fall back to an empty role and no
/// branches (a user with no claims set yet can sign in but can do
/// nothing until `setUserClaims` runs; see
/// `firebase/functions-design.md` Job 6).
AppUser appUserFromClaims({
  required String uid,
  required String email,
  String? displayName,
  required Map<String, dynamic> claims,
  String orgIdFallback = demoOrganizationId,
}) {
  final rawBranches = claims['branchIds'];
  final branchIds = rawBranches is List
      ? rawBranches.whereType<String>().toList()
      : <String>[];
  final roleKey = claims['role'] as String? ?? '';
  // All-branch roles have no home branch; a branch-scoped role's
  // home branch is its first listed branch.
  const allBranchRoles = {
    'super_admin',
    'owner',
    'ho_admin',
    'accountant',
    'auditor',
  };
  return AppUser(
    uid: uid,
    email: email,
    displayName: displayName ?? email.split('@').first,
    orgId: claims['orgId'] as String? ?? orgIdFallback,
    branchIds: branchIds,
    roleKey: roleKey,
    demoRole: demoRoleFromRoleKey(roleKey),
    homeBranchId: allBranchRoles.contains(roleKey)
        ? null
        : (branchIds.isEmpty ? null : branchIds.first),
  );
}

/// Auth repository interface. Implementations throw [AuthException]
/// (or [UnsupportedError] for flows the backend cannot do) with a
/// user-facing message.
abstract class AuthRepository {
  /// The currently signed-in user, or `null`.
  Future<AppUser?> currentUser();

  /// Signs in with email + password. Throws [AuthException] on
  /// unknown email / wrong password.
  Future<AppUser> signInWithEmail(String email, String password);

  /// One-tap demo sign-in as [role]. Mock only — the Firebase
  /// implementation throws [UnsupportedError].
  Future<AppUser> signInAsDemo(DemoRole role);

  Future<void> signOut();

  /// Stream of auth-state changes (`null` = signed out).
  Stream<AppUser?> get authStateChanges;

  /// Starts a password reset for [email].
  ///
  /// Returns a displayable reset code only for the mock repository
  /// (shown on screen — there is no backend to send email from). The
  /// Firebase implementation sends a real reset email and returns
  /// `null`. Returns `null` when no account has that email.
  Future<String?> requestPasswordReset(String email);

  /// Completes a mock reset with the code from [requestPasswordReset].
  /// Throws [AuthException] on a wrong code or a too-short password.
  /// The Firebase implementation throws [UnsupportedError] — its reset
  /// runs through the emailed link instead.
  Future<void> resetPassword({
    required String email,
    required String code,
    required String newPassword,
  });
}

/// Mock auth repository: the five demo accounts, in-memory only.
///
/// Passwords live in a map seeded with [demoPassword]; a successful
/// mock reset rewrites the entry for the session only, so the reset
/// flow is genuinely usable end to end (sign in with the new password
/// afterwards). Nothing is persisted.
class MockAuthRepository implements AuthRepository {
  /// In-memory demo passwords, keyed by email.
  final Map<String, String> _passwords = {
    for (final account in demoAccounts) account.email: demoPassword,
  };

  /// Outstanding mock reset codes, keyed by email.
  final Map<String, String> _pendingResetCodes = {};

  AppUser? _currentUser;

  @override
  Future<AppUser?> currentUser() async => _currentUser;

  @override
  Stream<AppUser?> get authStateChanges => Stream.value(_currentUser);

  @override
  Future<AppUser> signInWithEmail(String email, String password) async {
    final normalized = email.trim().toLowerCase();
    DemoAccount? account;
    for (final candidate in demoAccounts) {
      if (candidate.email == normalized) account = candidate;
    }
    if (account == null) {
      throw const AuthException('No demo account found for this email.');
    }
    if (_passwords[normalized] != password) {
      throw const AuthException('Incorrect password for this demo account.');
    }
    _currentUser = AppUser.fromDemoUser(account.user);
    return _currentUser!;
  }

  @override
  Future<AppUser> signInAsDemo(DemoRole role) async {
    final account = demoAccounts.firstWhere(
      (candidate) => candidate.role == role,
    );
    _currentUser = AppUser.fromDemoUser(account.user);
    return _currentUser!;
  }

  @override
  Future<void> signOut() async {
    _currentUser = null;
  }

  @override
  Future<String?> requestPasswordReset(String email) async {
    final normalized = email.trim().toLowerCase();
    final exists = demoAccounts.any((account) => account.email == normalized);
    if (!exists) return null;
    final code = resetCodeFor(normalized);
    _pendingResetCodes[normalized] = code;
    return code;
  }

  /// The code a reset step shows for [email] (without starting a flow).
  /// Deterministic: derived from the email's code units, not
  /// `String.hashCode` (which is not stable across runs).
  static String resetCodeFor(String email) {
    var hash = 0;
    for (final unit in email.codeUnits) {
      hash = (hash * 31 + unit) % 1000000;
    }
    return ((hash % 900000) + 100000).toString();
  }

  @override
  Future<void> resetPassword({
    required String email,
    required String code,
    required String newPassword,
  }) async {
    final normalized = email.trim().toLowerCase();
    if (_pendingResetCodes[normalized] != code.trim()) {
      throw const AuthException(
        'The reset code is incorrect. Check the code shown on the '
        'previous step.',
      );
    }
    if (newPassword.length < 6) {
      throw const AuthException('Password must be at least 6 characters.');
    }
    _passwords[normalized] = newPassword;
    _pendingResetCodes.remove(normalized);
  }
}

/// Firebase Auth repository (code-ready — needs the Firebase project).
///
/// Sign-in reads the user's ID-token custom claims (`orgId`,
/// `branchIds[]`, `role`, set by the `setUserClaims` Function or the
/// Admin SDK) and builds the [AppUser] from them; a token refresh
/// picks up changed claims. Demo sign-in and code-based reset are not
/// available against Firebase Auth and throw [UnsupportedError].
class FirebaseAuthRepository implements AuthRepository {
  FirebaseAuthRepository({FirebaseAuth? firebaseAuth})
    : _auth = firebaseAuth ?? FirebaseAuth.instance;

  final FirebaseAuth _auth;

  @override
  Future<AppUser?> currentUser() async {
    final user = _auth.currentUser;
    if (user == null) return null;
    return _appUserFromFirebaseUser(user);
  }

  @override
  Stream<AppUser?> get authStateChanges =>
      _auth.authStateChanges().asyncMap((user) async {
        if (user == null) return null;
        return _appUserFromFirebaseUser(user);
      });

  @override
  Future<AppUser> signInWithEmail(String email, String password) async {
    try {
      final credential = await _auth.signInWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
      final user = credential.user;
      if (user == null) {
        throw const AuthException('Sign-in did not return a user.');
      }
      return await _appUserFromFirebaseUser(user);
    } on FirebaseAuthException catch (error) {
      throw AuthException(_friendlyMessage(error));
    }
  }

  @override
  Future<AppUser> signInAsDemo(DemoRole role) {
    throw UnsupportedError(
      'Demo sign-in is only available with the mock auth repository.',
    );
  }

  @override
  Future<void> signOut() => _auth.signOut();

  @override
  Future<String?> requestPasswordReset(String email) async {
    await _auth.sendPasswordResetEmail(email: email.trim());
    return null;
  }

  @override
  Future<void> resetPassword({
    required String email,
    required String code,
    required String newPassword,
  }) {
    throw UnsupportedError(
      'Firebase password reset runs through the emailed link, not a '
      'code.',
    );
  }

  Future<AppUser> _appUserFromFirebaseUser(User user) async {
    final token = await user.getIdTokenResult();
    return appUserFromClaims(
      uid: user.uid,
      email: user.email ?? '',
      displayName: user.displayName,
      claims: token.claims ?? const {},
    );
  }

  static String _friendlyMessage(FirebaseAuthException error) {
    return switch (error.code) {
      'user-not-found' => 'No account found for this email.',
      'wrong-password' => 'Incorrect password for this account.',
      'invalid-email' => 'Enter a valid email address.',
      'user-disabled' => 'This account has been disabled.',
      'too-many-requests' =>
        'Too many sign-in attempts — try again in a few minutes.',
      'network-request-failed' =>
        'No network connection — check connectivity and retry.',
      _ => 'Sign-in failed (${error.code}).',
    };
  }
}

/// The auth repository for the app: the mock until the Firebase
/// project exists. It reads the repository bundle
/// (`repository_factory.dart`), so overriding the bundle switches
/// auth to Firebase Auth along with the data repositories.
final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => ref.watch(repositoryBundleProvider).auth,
);
