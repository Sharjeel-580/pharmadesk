import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/branch_context.dart';

/// Demo authentication (SRS §8.1: demo accounts for Owner, Branch
/// Manager, Pharmacist, Cashier, Inventory Manager).
///
/// There is no backend yet (no Firebase project exists), so auth is a
/// mock: credentials are checked in-memory against [demoAccounts] and the
/// signed-in user lives only for the session. Week 2 swaps this for
/// Firebase Auth behind the same provider — screens read [authProvider]
/// and never touch the mock directly.
///
/// Passwords are demo-only, shared in `docs/demo-guide.md`, and rotated
/// per demo build (SRS §8.1). Never use these in production.
const demoPassword = 'demo1234';

/// The five demo roles (SRS §8.1). Deliberately separate from the Day 0
/// [StaffRole] enum (owner / pharmacist / counter / rider): the demo
/// roles are the client-facing roles from the SRS, and aligning the two
/// vocabularies is a Week 2 decision (see D19).
enum DemoRole { owner, branchManager, pharmacist, cashier, inventoryManager }

extension DemoRoleDetails on DemoRole {
  /// Short label shown on the demo-login card and the dashboard.
  String get label => switch (this) {
    DemoRole.owner => 'Owner',
    DemoRole.branchManager => 'Branch Manager',
    DemoRole.pharmacist => 'Pharmacist',
    DemoRole.cashier => 'Cashier',
    DemoRole.inventoryManager => 'Inventory Manager',
  };

  /// One-line description shown under the role on the login screen.
  String get description => switch (this) {
    DemoRole.owner =>
      'All branches — sales, profit, stock and staff overview.',
    DemoRole.branchManager =>
      'One branch — orders, staff and daily branch performance.',
    DemoRole.pharmacist =>
      'Prescription review and dispensing for the branch.',
    DemoRole.cashier => 'Counter billing (POS) and order taking.',
    DemoRole.inventoryManager =>
      'Stock, batches, expiry and purchase receiving.',
  };

  IconData get icon => switch (this) {
    DemoRole.owner => Icons.admin_panel_settings_outlined,
    DemoRole.branchManager => Icons.store_outlined,
    DemoRole.pharmacist => Icons.medication_outlined,
    DemoRole.cashier => Icons.point_of_sale_outlined,
    DemoRole.inventoryManager => Icons.inventory_2_outlined,
  };

  /// Demo sign-in email for this role.
  String get email => switch (this) {
    DemoRole.owner => 'owner@demo.pharmadesk',
    DemoRole.branchManager => 'manager@demo.pharmadesk',
    DemoRole.pharmacist => 'pharmacist@demo.pharmadesk',
    DemoRole.cashier => 'cashier@demo.pharmadesk',
    DemoRole.inventoryManager => 'inventory@demo.pharmadesk',
  };
}

/// A signed-in demo user: the account's display identity plus its role
/// and home branch (`null` for the owner, who sees all branches).
class DemoUser {
  const DemoUser({
    required this.id,
    required this.name,
    required this.email,
    required this.role,
    this.branchId,
  });

  final String id;
  final String name;
  final String email;
  final DemoRole role;

  /// Home branch id, or `null` for the owner (all branches).
  final String? branchId;

  /// True when this user may see every branch (owner only).
  bool get seesAllBranches => role == DemoRole.owner;

  String get roleLabel => role.label;
}

/// One demo account: the user plus its sign-in email.
class DemoAccount {
  const DemoAccount({required this.user});

  final DemoUser user;

  DemoRole get role => user.role;
  String get email => user.email;
}

/// The five demo accounts (SRS §8.1). All share [demoPassword].
/// Names are fictional — no real client data in the demo (SRS §8.2).
const demoAccounts = <DemoAccount>[
  DemoAccount(
    user: DemoUser(
      id: 'demo-owner',
      name: 'Hassan Raza',
      email: 'owner@demo.pharmadesk',
      role: DemoRole.owner,
    ),
  ),
  DemoAccount(
    user: DemoUser(
      id: 'demo-manager',
      name: 'Bilal Ahmed',
      email: 'manager@demo.pharmadesk',
      role: DemoRole.branchManager,
      branchId: 'branch-dha-main',
    ),
  ),
  DemoAccount(
    user: DemoUser(
      id: 'demo-pharmacist',
      name: 'Dr. Sana Malik',
      email: 'pharmacist@demo.pharmadesk',
      role: DemoRole.pharmacist,
      branchId: 'branch-dha-main',
    ),
  ),
  DemoAccount(
    user: DemoUser(
      id: 'demo-cashier',
      name: 'Usman Tariq',
      email: 'cashier@demo.pharmadesk',
      role: DemoRole.cashier,
      branchId: 'branch-demo-gulberg',
    ),
  ),
  DemoAccount(
    user: DemoUser(
      id: 'demo-inventory',
      name: 'Fatima Noor',
      email: 'inventory@demo.pharmadesk',
      role: DemoRole.inventoryManager,
      branchId: 'branch-demo-gulberg',
    ),
  ),
];

/// Holds the signed-in demo user (`null` = signed out) and the mock
/// auth operations: email/password sign-in, one-tap demo sign-in,
/// sign-out and the mock forgot-password flow.
///
/// Passwords live in an in-memory map seeded with [demoPassword]; a
/// successful mock reset rewrites the entry for the session only, so the
/// reset flow is genuinely usable end to end in the demo (sign in with
/// the new password afterwards). Nothing is persisted — Week 2 replaces
/// this with Firebase Auth.
class AuthNotifier extends Notifier<DemoUser?> {
  /// In-memory demo passwords, keyed by email.
  final Map<String, String> _passwords = {
    for (final account in demoAccounts) account.email: demoPassword,
  };

  /// Outstanding mock reset codes, keyed by email.
  final Map<String, String> _pendingResetCodes = {};

  @override
  DemoUser? build() => null;

  /// Signs in with email + password.
  ///
  /// Returns `null` on success, or an error message to show on the
  /// login form on failure (unknown email / wrong password).
  String? signIn(String email, String password) {
    final normalized = email.trim().toLowerCase();
    DemoAccount? account;
    for (final candidate in demoAccounts) {
      if (candidate.email == normalized) account = candidate;
    }
    if (account == null) {
      return 'No demo account found for this email.';
    }
    if (_passwords[normalized] != password) {
      return 'Incorrect password for this demo account.';
    }
    _applySignIn(account.user);
    return null;
  }

  /// One-tap demo sign-in as [role] (the demo-login cards).
  void signInAsDemo(DemoRole role) {
    final account = demoAccounts.firstWhere(
      (candidate) => candidate.role == role,
    );
    _applySignIn(account.user);
  }

  void signOut() {
    state = null;
  }

  void _applySignIn(DemoUser user) {
    state = user;
    // Branch-scoped roles start in their home branch; the owner keeps
    // whichever branch was active.
    final homeBranch = user.branchId;
    if (homeBranch != null) {
      ref.read(activeBranchProvider.notifier).switchTo(homeBranch);
    }
  }

  /// Starts the mock forgot-password flow for [email].
  ///
  /// Returns the demo reset code to display on screen, or `null` when
  /// no demo account has that email. No email is ever sent — there is
  /// no backend in the demo; the code is shown on screen instead (the
  /// forgot-password screen explains this).
  String? requestPasswordReset(String email) {
    final normalized = email.trim().toLowerCase();
    final exists = demoAccounts.any(
      (account) => account.email == normalized,
    );
    if (!exists) return null;
    final code = resetCodeFor(normalized);
    _pendingResetCodes[normalized] = code;
    return code;
  }

  /// The code a reset step shows for [email] (without starting a flow).
  /// Kept public so tests can assert the deterministic code.
  static String resetCodeFor(String email) {
    // Simple deterministic hash (String.hashCode is not stable across
    // runs, so the code is derived from the code units instead).
    var hash = 0;
    for (final unit in email.codeUnits) {
      hash = (hash * 31 + unit) % 1000000;
    }
    return ((hash % 900000) + 100000).toString();
  }

  /// Completes a mock reset: checks the code, then replaces the demo
  /// password for [email] for the rest of the session.
  ///
  /// Returns `null` on success, or an error message on failure.
  String? resetPassword({
    required String email,
    required String code,
    required String newPassword,
  }) {
    final normalized = email.trim().toLowerCase();
    if (_pendingResetCodes[normalized] != code.trim()) {
      return 'The reset code is incorrect. Check the code shown on the previous step.';
    }
    if (newPassword.length < 6) {
      return 'Password must be at least 6 characters.';
    }
    _passwords[normalized] = newPassword;
    _pendingResetCodes.remove(normalized);
    return null;
  }
}

/// The signed-in demo user, or `null` when signed out.
final authProvider = NotifierProvider<AuthNotifier, DemoUser?>(
  AuthNotifier.new,
);
