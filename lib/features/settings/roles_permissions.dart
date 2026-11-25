import 'package:flutter/material.dart';

/// Day 7 roles & permissions — the SRS §5.1 capability matrix, as
/// read-only demo data.
///
/// In production this matrix is ENFORCED by Firestore security rules +
/// custom claims (FR-SYS-02); the settings screen only displays it.
/// The demo role assignment on the settings screen is mock — it picks
/// which role's column is highlighted, it does not change what the
/// signed-in user can do.

/// One capability row of the matrix.
class RoleCapability {
  const RoleCapability({required this.key, required this.label});

  final String key;
  final String label;
}

/// What a role may do with a capability.
enum RolePermission {
  /// Fully allowed.
  allowed,

  /// Allowed within the user's own branch only.
  own,

  /// Read-only.
  readOnly,

  /// Not allowed.
  none,
}

extension RolePermissionLabel on RolePermission {
  String get label => switch (this) {
    RolePermission.allowed => '✓',
    RolePermission.own => 'Own',
    RolePermission.readOnly => 'RO',
    RolePermission.none => '—',
  };
}

/// The ten SRS §5 roles, in matrix order.
const demoRoles = <String>[
  'Super Admin',
  'Owner',
  'HO Admin',
  'Regional Mgr',
  'Branch Mgr',
  'Pharmacist',
  'Cashier',
  'Inventory Mgr',
  'Accountant',
  'Auditor',
];

/// The capability rows shown on the settings screen (SRS §5.1 core).
const roleCapabilities = <RoleCapability>[
  RoleCapability(key: 'brand', label: 'Manage organization / Brand Settings'),
  RoleCapability(key: 'modules', label: 'Enable/disable modules'),
  RoleCapability(key: 'branches', label: 'Manage branches / franchises'),
  RoleCapability(key: 'allBranches', label: 'View all branches (consolidated)'),
  RoleCapability(key: 'users', label: 'Manage users & roles'),
  RoleCapability(key: 'posSell', label: 'POS sell'),
  RoleCapability(key: 'posDiscount', label: 'POS discount (within limit)'),
  RoleCapability(key: 'posRefund', label: 'POS refund / return'),
  RoleCapability(key: 'rxReview', label: 'Prescription review & approve'),
  RoleCapability(key: 'medicineCrud', label: 'Medicine master CRUD'),
  RoleCapability(key: 'stockReceive', label: 'Stock receive / count'),
  RoleCapability(key: 'stockAdjustReq', label: 'Stock adjustment (request)'),
  RoleCapability(key: 'stockAdjustApprove', label: 'Stock adjustment (approve)'),
  RoleCapability(key: 'poManage', label: 'Purchase order create/approve'),
  RoleCapability(key: 'supplierPay', label: 'Supplier payment'),
  RoleCapability(key: 'khata', label: 'Customer credit (khata)'),
  RoleCapability(key: 'financeEntry', label: 'Finance: income/expense entry'),
  RoleCapability(key: 'financeReports', label: 'Finance: P&L, statements'),
  RoleCapability(key: 'reports', label: 'Reports (all)'),
  RoleCapability(key: 'auditLog', label: 'Audit log view'),
  RoleCapability(key: 'sysSettings', label: 'System settings / backup'),
];

/// The matrix itself: capability key → one permission per role, in
/// [demoRoles] order. Transcribed from SRS §5.1.
const rolePermissionMatrix = <String, List<RolePermission>>{
  'brand': [
    RolePermission.allowed,
    RolePermission.allowed,
    RolePermission.none,
    RolePermission.none,
    RolePermission.none,
    RolePermission.none,
    RolePermission.none,
    RolePermission.none,
    RolePermission.none,
    RolePermission.none,
  ],
  'modules': [
    RolePermission.allowed,
    RolePermission.allowed,
    RolePermission.none,
    RolePermission.none,
    RolePermission.none,
    RolePermission.none,
    RolePermission.none,
    RolePermission.none,
    RolePermission.none,
    RolePermission.none,
  ],
  'branches': [
    RolePermission.allowed,
    RolePermission.allowed,
    RolePermission.allowed,
    RolePermission.none,
    RolePermission.none,
    RolePermission.none,
    RolePermission.none,
    RolePermission.none,
    RolePermission.none,
    RolePermission.readOnly,
  ],
  'allBranches': [
    RolePermission.allowed,
    RolePermission.allowed,
    RolePermission.allowed,
    RolePermission.own,
    RolePermission.own,
    RolePermission.own,
    RolePermission.own,
    RolePermission.own,
    RolePermission.allowed,
    RolePermission.readOnly,
  ],
  'users': [
    RolePermission.allowed,
    RolePermission.allowed,
    RolePermission.allowed,
    RolePermission.none,
    RolePermission.own,
    RolePermission.none,
    RolePermission.none,
    RolePermission.none,
    RolePermission.none,
    RolePermission.readOnly,
  ],
  'posSell': [
    RolePermission.none,
    RolePermission.allowed,
    RolePermission.allowed,
    RolePermission.none,
    RolePermission.own,
    RolePermission.own,
    RolePermission.own,
    RolePermission.none,
    RolePermission.none,
    RolePermission.none,
  ],
  'posDiscount': [
    RolePermission.none,
    RolePermission.allowed,
    RolePermission.allowed,
    RolePermission.none,
    RolePermission.own,
    RolePermission.own,
    RolePermission.own,
    RolePermission.none,
    RolePermission.none,
    RolePermission.none,
  ],
  'posRefund': [
    RolePermission.none,
    RolePermission.allowed,
    RolePermission.allowed,
    RolePermission.none,
    RolePermission.own,
    RolePermission.none,
    RolePermission.own,
    RolePermission.none,
    RolePermission.none,
    RolePermission.none,
  ],
  'rxReview': [
    RolePermission.none,
    RolePermission.none,
    RolePermission.none,
    RolePermission.none,
    RolePermission.none,
    RolePermission.own,
    RolePermission.none,
    RolePermission.none,
    RolePermission.none,
    RolePermission.none,
  ],
  'medicineCrud': [
    RolePermission.none,
    RolePermission.allowed,
    RolePermission.allowed,
    RolePermission.none,
    RolePermission.own,
    RolePermission.own,
    RolePermission.none,
    RolePermission.own,
    RolePermission.none,
    RolePermission.readOnly,
  ],
  'stockReceive': [
    RolePermission.none,
    RolePermission.allowed,
    RolePermission.allowed,
    RolePermission.none,
    RolePermission.own,
    RolePermission.none,
    RolePermission.none,
    RolePermission.own,
    RolePermission.none,
    RolePermission.readOnly,
  ],
  'stockAdjustReq': [
    RolePermission.none,
    RolePermission.allowed,
    RolePermission.allowed,
    RolePermission.none,
    RolePermission.own,
    RolePermission.none,
    RolePermission.none,
    RolePermission.own,
    RolePermission.none,
    RolePermission.none,
  ],
  'stockAdjustApprove': [
    RolePermission.none,
    RolePermission.allowed,
    RolePermission.allowed,
    RolePermission.none,
    RolePermission.own,
    RolePermission.none,
    RolePermission.none,
    RolePermission.none,
    RolePermission.none,
    RolePermission.none,
  ],
  'poManage': [
    RolePermission.none,
    RolePermission.allowed,
    RolePermission.allowed,
    RolePermission.none,
    RolePermission.own,
    RolePermission.none,
    RolePermission.none,
    RolePermission.own,
    RolePermission.allowed,
    RolePermission.readOnly,
  ],
  'supplierPay': [
    RolePermission.none,
    RolePermission.allowed,
    RolePermission.allowed,
    RolePermission.none,
    RolePermission.none,
    RolePermission.none,
    RolePermission.none,
    RolePermission.none,
    RolePermission.allowed,
    RolePermission.readOnly,
  ],
  'khata': [
    RolePermission.none,
    RolePermission.allowed,
    RolePermission.allowed,
    RolePermission.none,
    RolePermission.own,
    RolePermission.none,
    RolePermission.own,
    RolePermission.none,
    RolePermission.allowed,
    RolePermission.readOnly,
  ],
  'financeEntry': [
    RolePermission.none,
    RolePermission.allowed,
    RolePermission.allowed,
    RolePermission.none,
    RolePermission.own,
    RolePermission.none,
    RolePermission.own,
    RolePermission.none,
    RolePermission.allowed,
    RolePermission.readOnly,
  ],
  'financeReports': [
    RolePermission.none,
    RolePermission.allowed,
    RolePermission.allowed,
    RolePermission.own,
    RolePermission.own,
    RolePermission.none,
    RolePermission.none,
    RolePermission.none,
    RolePermission.allowed,
    RolePermission.readOnly,
  ],
  'reports': [
    RolePermission.allowed,
    RolePermission.allowed,
    RolePermission.allowed,
    RolePermission.own,
    RolePermission.own,
    RolePermission.own,
    RolePermission.own,
    RolePermission.own,
    RolePermission.allowed,
    RolePermission.readOnly,
  ],
  'auditLog': [
    RolePermission.allowed,
    RolePermission.allowed,
    RolePermission.allowed,
    RolePermission.none,
    RolePermission.own,
    RolePermission.none,
    RolePermission.none,
    RolePermission.none,
    RolePermission.none,
    RolePermission.readOnly,
  ],
  'sysSettings': [
    RolePermission.allowed,
    RolePermission.allowed,
    RolePermission.allowed,
    RolePermission.none,
    RolePermission.none,
    RolePermission.none,
    RolePermission.none,
    RolePermission.none,
    RolePermission.none,
    RolePermission.none,
  ],
};

/// Permissions of one role across every capability, in
/// [roleCapabilities] order.
List<RolePermission> permissionsForRole(String role) {
  final index = demoRoles.indexOf(role);
  if (index == -1) return List.filled(roleCapabilities.length, RolePermission.none);
  return [
    for (final capability in roleCapabilities)
      rolePermissionMatrix[capability.key]?[index] ?? RolePermission.none,
  ];
}

/// Icon for a feature module (settings feature-config list).
IconData featureModuleIcon(String key) => switch (key) {
  'dashboard' => Icons.dashboard_outlined,
  'orders' => Icons.receipt_long_outlined,
  'medicines' => Icons.medication_outlined,
  'inventory' => Icons.inventory_2_outlined,
  'billing' => Icons.point_of_sale_outlined,
  'customers' => Icons.people_outline,
  'suppliers' => Icons.local_shipping_outlined,
  'purchases' => Icons.shopping_cart_outlined,
  'prescriptions' => Icons.description_outlined,
  'reports' => Icons.bar_chart_outlined,
  'notifications' => Icons.notifications_outlined,
  _ => Icons.extension_outlined,
};
