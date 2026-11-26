import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/shell/app_shell.dart';
import '../../features/authentication/forgot_password_screen.dart';
import '../../features/authentication/login_screen.dart';
import '../../features/authentication/profile_screen.dart';
import '../../features/authentication/splash_screen.dart';
import '../../features/audit/audit_log_screen.dart';
import '../../features/backup/backup_screen.dart';
import '../../features/billing/pos_screen.dart';
import '../../features/billing/receipt_screen.dart';
import '../../features/billing/return_form_screen.dart';
import '../../features/billing/returns_list_screen.dart';
import '../../features/billing/sales_history_screen.dart';
import '../../features/branches/branch_detail_screen.dart';
import '../../features/branches/branch_list_screen.dart';
import '../../features/customers/customer_detail_screen.dart';
import '../../features/customers/customer_list_screen.dart';
import '../../features/dashboard/dashboard_screen.dart';
import '../../features/finance/aging_screen.dart';
import '../../features/finance/cashbook_screen.dart';
import '../../features/finance/finance_hub_screen.dart';
import '../../features/finance/statements_screen.dart';
import '../../features/inventory/inventory_screen.dart';
import '../../features/inventory/adjustment_queue_screen.dart';
import '../../features/inventory/stock_transfer_detail_screen.dart';
import '../../features/inventory/stock_transfer_form_screen.dart';
import '../../features/inventory/stock_transfer_list_screen.dart';
import '../../features/medicines/medicine_detail_screen.dart';
import '../../features/medicines/medicine_list_screen.dart';
import '../../features/notifications/notifications_screen.dart';
import '../../features/orders/order_detail_screen.dart';
import '../../features/orders/order_form_screen.dart';
import '../../features/orders/order_list_screen.dart';
import '../../features/prescriptions/prescription_detail_screen.dart';
import '../../features/prescriptions/prescription_list_screen.dart';
import '../../features/purchases/auto_purchase_list_screen.dart';
import '../../features/purchases/purchase_detail_screen.dart';
import '../../features/purchases/purchase_form_screen.dart';
import '../../features/purchases/purchase_list_screen.dart';
import '../../features/reports/reports_screen.dart';
import '../../features/riders/rider_detail_screen.dart';
import '../../features/riders/rider_list_screen.dart';
import '../../features/settings/feature_gate.dart';
import '../../features/settings/settings_screen.dart';
import '../../features/staff/attendance_screen.dart';
import '../../features/staff/salary_screen.dart';
import '../../features/staff/shifts_screen.dart';
import '../../features/staff/staff_list_screen.dart';
import '../../features/suppliers/supplier_detail_screen.dart';
import '../../features/suppliers/supplier_list_screen.dart';
import '../widgets/design_system.dart';

/// One Week 1 module: its route, icon, description and the day it lands.
class AppModule {
  const AppModule({
    required this.title,
    required this.route,
    required this.icon,
    required this.description,
    required this.day,
  });

  final String title;
  final String route;
  final IconData icon;
  final String description;
  final String day;
}

/// Week 1 module map (master prompt §4). Day 2 wires every module into
/// the real app shell; screens stay placeholders until their day (Days 3–7).
const appModules = <AppModule>[
  AppModule(
    title: 'Authentication',
    route: '/authentication',
    icon: Icons.lock_outline,
    description: 'Login, forgot password and demo login flow.',
    day: 'Week 1 — Day 3',
  ),
  AppModule(
    title: 'Dashboard',
    route: '/dashboard',
    icon: Icons.dashboard_outlined,
    description: "Today's sales, profit, orders, low stock and expiry alerts.",
    day: 'Week 1 — Day 3',
  ),
  AppModule(
    title: 'Orders',
    route: '/orders',
    icon: Icons.receipt_long_outlined,
    description: 'Order queue, create/edit orders, status updates, history.',
    day: 'Week 1 — Day 4',
  ),
  AppModule(
    title: 'Medicines',
    route: '/medicines',
    icon: Icons.medication_outlined,
    description: 'Medicine catalogue — search, categories, prices, barcodes.',
    day: 'Week 1 — Day 5',
  ),
  AppModule(
    title: 'Inventory',
    route: '/inventory',
    icon: Icons.inventory_2_outlined,
    description: 'Stock, batches, expiry (30/60/90 days), stock movements.',
    day: 'Week 1 — Day 5',
  ),
  AppModule(
    title: 'Billing & POS',
    route: '/billing',
    icon: Icons.point_of_sale_outlined,
    description: 'Fast pharmacy POS — cart, discount, tax, receipt, payment.',
    day: 'Week 1 — Day 6',
  ),
  AppModule(
    title: 'Customers',
    route: '/customers',
    icon: Icons.people_outline,
    description: 'Customer directory, purchase history, credit ledger.',
    day: 'Week 1 — Day 6',
  ),
  AppModule(
    title: 'Suppliers',
    route: '/suppliers',
    icon: Icons.local_shipping_outlined,
    description: 'Supplier profiles, contacts, purchase history, balances.',
    day: 'Week 1 — Day 7',
  ),
  AppModule(
    title: 'Purchases',
    route: '/purchases',
    icon: Icons.shopping_cart_outlined,
    description: 'Purchase orders, goods receiving, returns, payments.',
    day: 'Week 1 — Day 7',
  ),
  AppModule(
    title: 'Prescriptions',
    route: '/prescriptions',
    icon: Icons.description_outlined,
    description: 'Prescription review — pharmacist check before dispatch.',
    day: 'Week 1 — Day 7',
  ),
  AppModule(
    title: 'Reports',
    route: '/reports',
    icon: Icons.bar_chart_outlined,
    description: 'Sales, profit, stock valuation and expiry reports.',
    day: 'Week 1 — Day 7',
  ),
  AppModule(
    title: 'Finance',
    route: '/finance',
    icon: Icons.account_balance_outlined,
    description:
        'Cashbook, payables/receivables aging, P&L and branch statements.',
    day: 'Week 4 — Day 3',
  ),
  AppModule(
    title: 'Staff & HR',
    route: '/staff',
    icon: Icons.badge_outlined,
    description:
        'Staff directory, roles, attendance, shifts and salary.',
    day: 'Week 2 — Day 5',
  ),
  AppModule(
    title: 'Notifications',
    route: '/notifications',
    icon: Icons.notifications_outlined,
    description: 'Low-stock, expiry and order alerts for staff and owners.',
    day: 'Week 1 — Day 7',
  ),
  AppModule(
    title: 'Settings',
    route: '/settings',
    icon: Icons.settings_outlined,
    description: 'Organization branding, roles, permissions, features.',
    day: 'Week 1 — Day 7',
  ),
  AppModule(
    title: 'Profile',
    route: '/profile',
    icon: Icons.person_outline,
    description: 'Signed-in staff profile, branch and role details.',
    day: 'Week 1 — Day 3',
  ),
];

/// Routes that sit outside the app shell (no sidebar / top bar).
const _authRoutes = {'/splash', '/login', '/forgot-password'};

/// A [ChangeNotifier] the app entries bump when auth state changes, so
/// the router's redirect re-runs (login → dashboard, logout → login).
/// A tiny subclass is needed because [ChangeNotifier.notifyListeners]
/// is protected and the app entries live outside the notifier.
class AuthRefreshNotifier extends ChangeNotifier {
  void refresh() => notifyListeners();
}

/// Builds a fresh router with the Day 2 shell and the Day 3 auth flow.
///
/// - `/splash` → `/login` (or `/dashboard` when a demo session exists).
/// - Auth pages live outside the [ShellRoute]; every module route lives
///   inside it, rendering [AppShell] around it.
/// - [isSignedIn] gates the shell routes: signed-out users are sent to
///   `/login`, signed-in users are kept out of the auth pages. When it
///   is omitted the router is ungated (tests that pump the router
///   without an auth session, and the admin/desktop entries until they
///   wire auth) — the dashboard then falls back to the branch view.
/// - [refreshListenable] re-runs the redirect when auth state changes
///   (sign-in / sign-out), so login and logout navigate without the
///   screens calling `go` themselves (they also do, for immediacy).
/// - `/` redirects to `/dashboard`; `/authentication` redirects to
///   `/login` (the sign-in screen *is* the authentication module).
///   Unknown routes show a "page not found" screen with a working way
///   back — never a dead end.
///
/// Each app entry point owns its router instance (created once in the
/// app widget's `initState`) — a single shared global router cannot be
/// reused across separate `MaterialApp.router` widgets.
GoRouter createAppRouter({
  Listenable? refreshListenable,
  bool Function()? isSignedIn,
}) {
  final signedIn = isSignedIn ?? () => true;
  return GoRouter(
    initialLocation: '/splash',
    refreshListenable: refreshListenable,
    redirect: (context, state) {
      final location = state.uri.path;
      final onAuthPage = _authRoutes.contains(location);
      if (!signedIn() && !onAuthPage) return '/login';
      if (signedIn() && onAuthPage) return '/dashboard';
      return null;
    },
    routes: [
      GoRoute(
        path: '/splash',
        builder: (context, state) => const SplashScreen(),
      ),
      GoRoute(
        path: '/login',
        builder: (context, state) => const LoginScreen(),
      ),
      GoRoute(
        path: '/forgot-password',
        builder: (context, state) => const ForgotPasswordScreen(),
      ),
      GoRoute(
        path: '/',
        redirect: (context, state) => '/dashboard',
      ),
      ShellRoute(
        builder: (context, state, child) => AppShell(
          currentLocation: state.uri.path,
          child: child,
        ),
        routes: [
          GoRoute(
            path: '/dashboard',
            builder: (context, state) => FeatureGate(
              route: state.uri.path,
              child: const DashboardScreen(),
            ),
          ),
          GoRoute(
            path: '/profile',
            builder: (context, state) => FeatureGate(
              route: state.uri.path,
              child: const ProfileScreen(),
            ),
          ),
          GoRoute(
            path: '/orders',
            builder: (context, state) => FeatureGate(
              route: state.uri.path,
              child: const OrderListScreen(),
            ),
          ),
          GoRoute(
            path: '/orders/new',
            builder: (context, state) => FeatureGate(
              route: state.uri.path,
              child: const OrderFormScreen(),
            ),
          ),
          GoRoute(
            path: '/orders/:id/edit',
            builder: (context, state) => FeatureGate(
              route: state.uri.path,
              child: OrderFormScreen(
                orderId: state.pathParameters['id'],
              ),
            ),
          ),
          GoRoute(
            path: '/orders/:id',
            builder: (context, state) => FeatureGate(
              route: state.uri.path,
              child: OrderDetailScreen(
                orderId: state.pathParameters['id'] ?? '',
              ),
            ),
          ),
          GoRoute(
            path: '/medicines',
            builder: (context, state) => FeatureGate(
              route: state.uri.path,
              child: const MedicineListScreen(),
            ),
          ),
          GoRoute(
            path: '/medicines/:id',
            builder: (context, state) => FeatureGate(
              route: state.uri.path,
              child: MedicineDetailScreen(
                medicineId: state.pathParameters['id'] ?? '',
              ),
            ),
          ),
          GoRoute(
            path: '/inventory',
            builder: (context, state) => FeatureGate(
              route: state.uri.path,
              child: const InventoryScreen(),
            ),
          ),
          // Stock transfers (Week 4 Day 2, D118 — SRS D-16): a
          // sub-screen of the Inventory module (same feature
          // toggle), capability-gated on `stockTransfer` at the
          // route (see `routeCapability`).
          GoRoute(
            path: '/inventory/transfers',
            builder: (context, state) => FeatureGate(
              route: state.uri.path,
              child: const StockTransferListScreen(),
            ),
          ),
          GoRoute(
            path: '/inventory/transfers/new',
            builder: (context, state) => FeatureGate(
              route: state.uri.path,
              child: const StockTransferFormScreen(),
            ),
          ),
          GoRoute(
            path: '/inventory/transfers/:id',
            builder: (context, state) => FeatureGate(
              route: state.uri.path,
              child: StockTransferDetailScreen(
                transferId: state.pathParameters['id'] ?? '',
              ),
            ),
          ),
          // Adjustment approval queue (Week 4 Day 5, D141 — SRS
          // D-14): a sub-screen of the Inventory module, gated on
          // `stockAdjustReq` at the route (see `routeCapability`).
          GoRoute(
            path: '/inventory/adjustments',
            builder: (context, state) => FeatureGate(
              route: state.uri.path,
              child: const AdjustmentQueueScreen(),
            ),
          ),
          // Riders & delivery (Week 4 Day 2, D119/D121 — SRS D-21):
          // a sub-screen of the Orders module for navigation (same
          // feature toggle via the shell entries); no separate
          // §5.1 capability governs rider viewing, so the route is
          // not capability-gated — assignment itself is guarded by
          // the order's editability + the rider's availability.
          GoRoute(
            path: '/riders',
            builder: (context, state) => FeatureGate(
              route: state.uri.path,
              child: const RiderListScreen(),
            ),
          ),
          GoRoute(
            path: '/riders/:id',
            builder: (context, state) => FeatureGate(
              route: state.uri.path,
              child: RiderDetailScreen(
                riderId: state.pathParameters['id'] ?? '',
              ),
            ),
          ),
          GoRoute(
            path: '/billing',
            builder: (context, state) => FeatureGate(
              route: state.uri.path,
              child: const PosScreen(),
            ),
          ),
          GoRoute(
            path: '/billing/history',
            builder: (context, state) => FeatureGate(
              route: state.uri.path,
              child: const SalesHistoryScreen(),
            ),
          ),
          GoRoute(
            path: '/billing/returns',
            builder: (context, state) => FeatureGate(
              route: state.uri.path,
              child: const ReturnsListScreen(),
            ),
          ),
          GoRoute(
            path: '/billing/returns/new',
            builder: (context, state) => FeatureGate(
              route: state.uri.path,
              child: ReturnFormScreen(
                saleId: state.uri.queryParameters['sale'],
              ),
            ),
          ),
          GoRoute(
            path: '/billing/receipt/:id',
            builder: (context, state) => FeatureGate(
              route: state.uri.path,
              child: ReceiptScreen(
                saleId: state.pathParameters['id'] ?? '',
              ),
            ),
          ),
          GoRoute(
            path: '/customers',
            builder: (context, state) => FeatureGate(
              route: state.uri.path,
              child: const CustomerListScreen(),
            ),
          ),
          GoRoute(
            path: '/customers/:id',
            builder: (context, state) => FeatureGate(
              route: state.uri.path,
              child: CustomerDetailScreen(
                customerId: state.pathParameters['id'] ?? '',
              ),
            ),
          ),
          GoRoute(
            path: '/suppliers',
            builder: (context, state) => FeatureGate(
              route: state.uri.path,
              child: const SupplierListScreen(),
            ),
          ),
          GoRoute(
            path: '/suppliers/:id',
            builder: (context, state) => FeatureGate(
              route: state.uri.path,
              child: SupplierDetailScreen(
                supplierId: state.pathParameters['id'] ?? '',
              ),
            ),
          ),
          GoRoute(
            path: '/purchases',
            builder: (context, state) => FeatureGate(
              route: state.uri.path,
              child: const PurchaseListScreen(),
            ),
          ),
          GoRoute(
            path: '/purchases/new',
            builder: (context, state) => FeatureGate(
              route: state.uri.path,
              child: PurchaseFormScreen(
                preselectedSupplierId:
                    state.uri.queryParameters['supplier'],
              ),
            ),
          ),
          GoRoute(
            path: '/purchases/auto',
            builder: (context, state) => FeatureGate(
              route: state.uri.path,
              child: const AutoPurchaseListScreen(),
            ),
          ),
          GoRoute(
            path: '/purchases/:id',
            builder: (context, state) => FeatureGate(
              route: state.uri.path,
              child: PurchaseDetailScreen(
                purchaseOrderId: state.pathParameters['id'] ?? '',
              ),
            ),
          ),
          GoRoute(
            path: '/prescriptions',
            builder: (context, state) => FeatureGate(
              route: state.uri.path,
              child: const PrescriptionListScreen(),
            ),
          ),
          GoRoute(
            path: '/prescriptions/:id',
            builder: (context, state) => FeatureGate(
              route: state.uri.path,
              child: PrescriptionDetailScreen(
                prescriptionId: state.pathParameters['id'] ?? '',
              ),
            ),
          ),
          GoRoute(
            path: '/reports',
            builder: (context, state) => FeatureGate(
              route: state.uri.path,
              child: const ReportsScreen(),
            ),
          ),
          // Finance hub (Week 4 Day 3, D124 — SRS D-24 / D-25 /
          // D-26): the hub itself is gated on the feature flag only
          // (each card checks its §5.1 capability in the active
          // branch); the three screens are capability-gated at the
          // route (see `routeCapability`).
          GoRoute(
            path: '/finance',
            builder: (context, state) => FeatureGate(
              route: state.uri.path,
              child: const FinanceHubScreen(),
            ),
          ),
          GoRoute(
            path: '/finance/cashbook',
            builder: (context, state) => FeatureGate(
              route: state.uri.path,
              child: const CashbookScreen(),
            ),
          ),
          GoRoute(
            path: '/finance/aging',
            builder: (context, state) => FeatureGate(
              route: state.uri.path,
              child: const AgingScreen(),
            ),
          ),
          GoRoute(
            path: '/finance/statements',
            builder: (context, state) => FeatureGate(
              route: state.uri.path,
              child: const StatementsScreen(),
            ),
          ),
          GoRoute(
            path: '/staff',
            builder: (context, state) => FeatureGate(
              route: state.uri.path,
              child: const StaffListScreen(),
            ),
          ),
          GoRoute(
            path: '/staff/attendance',
            builder: (context, state) => FeatureGate(
              route: state.uri.path,
              child: const AttendanceScreen(),
            ),
          ),
          GoRoute(
            path: '/staff/shifts',
            builder: (context, state) => FeatureGate(
              route: state.uri.path,
              child: const ShiftsScreen(),
            ),
          ),
          GoRoute(
            path: '/staff/salary',
            builder: (context, state) => FeatureGate(
              route: state.uri.path,
              child: const SalaryScreen(),
            ),
          ),
          GoRoute(
            path: '/notifications',
            builder: (context, state) => FeatureGate(
              route: state.uri.path,
              child: const NotificationsScreen(),
            ),
          ),
          GoRoute(
            path: '/settings',
            builder: (context, state) => FeatureGate(
              route: state.uri.path,
              child: const SettingsScreen(),
            ),
          ),
          // System hub (Week 4 Day 4, D135 — SRS D-28 / D-33 /
          // D-35): sub-screens of Settings for navigation (sidebar
          // + More sheet), capability-gated at the route on their
          // own §5.1 rows (see `routeCapability` + the FeatureGate
          // non-module branch).
          GoRoute(
            path: '/branches',
            builder: (context, state) => FeatureGate(
              route: state.uri.path,
              child: const BranchListScreen(),
            ),
          ),
          GoRoute(
            path: '/branches/:id',
            builder: (context, state) => FeatureGate(
              route: state.uri.path,
              child: BranchDetailScreen(
                branchId: state.pathParameters['id'] ?? '',
              ),
            ),
          ),
          GoRoute(
            path: '/audit-log',
            builder: (context, state) => FeatureGate(
              route: state.uri.path,
              child: const AuditLogScreen(),
            ),
          ),
          GoRoute(
            path: '/backup',
            builder: (context, state) => FeatureGate(
              route: state.uri.path,
              child: const BackupScreen(),
            ),
          ),
          GoRoute(
            path: '/authentication',
            redirect: (context, state) => '/login',
          ),
        ],
      ),
    ],
    errorBuilder: (context, state) => _RouteNotFoundScreen(
      attemptedPath: state.uri.path,
    ),
  );
}

class _RouteNotFoundScreen extends StatelessWidget {
  const _RouteNotFoundScreen({required this.attemptedPath});

  final String attemptedPath;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.search_off_outlined,
                size: 56,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Text(
                'Page not found',
                style: theme.textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              Text(
                'There is no screen at "$attemptedPath".',
                style: theme.textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              PharmaButton(
                label: 'Go to Dashboard',
                icon: Icons.dashboard_outlined,
                onPressed: () => context.go('/dashboard'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
