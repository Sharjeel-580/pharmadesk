import 'package:flutter/material.dart';

/// Demo accounts (SRS §8.1: Owner, Branch Manager, Pharmacist,
/// Cashier, Inventory Manager).
///
/// Moved here from `features/authentication/auth_state.dart` on Week 2
/// Day 3 so the auth repository (`auth_repository.dart`) can sign
/// users in against them without importing the Riverpod notifier
/// (which itself depends on the repository — an import cycle).
///
/// There is no backend yet (no Firebase project exists), so the mock
/// auth repository checks credentials in-memory against
/// [demoAccounts]. Week 2 swaps the repository for Firebase Auth
/// behind the same interface — screens read [authProvider] and never
/// touch these accounts directly.
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
    DemoRole.owner => 'All branches — sales, profit, stock and staff overview.',
    DemoRole.branchManager =>
      'One branch — orders, staff and daily branch performance.',
    DemoRole.pharmacist => 'Prescription review and dispensing for the branch.',
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

  /// The SRS §5.1 role key this demo role maps to (the custom-claims
  /// `role` value, `firebase/firestore.rules`). The full 10-role
  /// vocabulary also has Super Admin, HO Admin, Regional Manager,
  /// Accountant and Auditor, which have no demo account.
  String get roleKey => switch (this) {
    DemoRole.owner => 'owner',
    DemoRole.branchManager => 'branch_manager',
    DemoRole.pharmacist => 'pharmacist',
    DemoRole.cashier => 'cashier',
    DemoRole.inventoryManager => 'inventory_manager',
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
