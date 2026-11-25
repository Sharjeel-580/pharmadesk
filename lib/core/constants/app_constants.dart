/// App-wide constants for PharmaDesk.
///
/// Firestore collection names live here so screens, repositories and the
/// future Firebase data layer all spell them the same way.
abstract final class AppConstants {
  static const String appName = 'PharmaDesk';
  static const String appVersion = '1.0.0+1';

  /// Free-tier policy (Dazy, 23 Nov 2026): the backend stays on Firebase
  /// Spark permanently — no Blaze pay-as-you-go. Design queries, caching
  /// and writes to stay inside free quotas (see docs/technical-decisions.md).
  static const String backendPlan = 'firebase-spark-free';

  // --- Firestore collections (roadmap / SRS data model) ---
  static const String organizations = 'organizations';
  static const String branches = 'branches';
  static const String users = 'users';
  static const String roles = 'roles';
  static const String medicines = 'medicines';
  static const String batches = 'batches';
  static const String inventory = 'inventory';
  static const String orders = 'orders';
  static const String orderItems = 'order_items';
  static const String customers = 'customers';
  static const String customerLedger = 'customer_ledger';
  static const String suppliers = 'suppliers';
  static const String purchases = 'purchases';
  static const String prescriptions = 'prescriptions';
  static const String notifications = 'notifications';
  static const String settings = 'settings';
  static const String auditLogs = 'audit_logs';
}
