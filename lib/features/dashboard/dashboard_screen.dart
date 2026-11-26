import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/data/auth_repository.dart';
import '../../core/data/permission_service.dart';
import '../../core/services/branch_context.dart';
import '../../core/services/repositories.dart';
import '../../core/utils/money.dart';
import '../../core/widgets/design_system.dart';
import '../../models/customer_ledger.dart';
import '../../models/inventory_item.dart';
import '../../models/medicine.dart';
import '../../models/order.dart';
import '../../models/prescription.dart';
import '../authentication/auth_state.dart';
import '../notifications/notifications_logic.dart';
import '../settings/roles_permissions.dart';
import 'dashboard_data.dart';
import 'owner_dashboard_data.dart';
import 'widgets/sales_chart.dart';

/// Dashboard screen (Day 3): owner dashboard and branch dashboards,
/// all figures computed from mock repository data (see
/// [computeDashboardKpis] — nothing is hardcoded).
///
/// - Owner: all branches — today's sales/orders, 30-day revenue,
///   low-stock + near-expiry counts, 30-day sales chart, per-branch
///   performance, top sellers, recent orders, alerts.
/// - Branch roles (Branch Manager, Pharmacist, Cashier, Inventory
///   Manager): the active branch only — today's branch orders/sales,
///   pending prescriptions, low-stock alerts, role-ordered quick
///   actions, chart, top sellers, recent orders, alerts.
/// - No user signed in (router without auth gating): falls back to the
///   branch dashboard for the active branch.
///
/// Every card and action navigates to a working destination (module
/// screens are placeholders until their day — navigation always lands).
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authProvider);
    final activeBranch = ref.watch(activeBranchProvider);
    final isOwner = user?.seesAllBranches ?? false;

    final title = isOwner ? 'Owner dashboard' : 'Branch dashboard';
    final subtitle = isOwner
        ? 'All branches — figures computed from demo data'
        : '${activeBranch.name} • ${user?.roleLabel ?? 'Staff'}';

    // 'all' = every branch (owner); otherwise the active branch id.
    final scope = isOwner ? 'all' : activeBranch.id;
    final kpisAsync = ref.watch(dashboardKpisProvider(scope));

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(title: title, subtitle: subtitle),
          const SizedBox(height: 16),
          kpisAsync.when(
            loading: () => const _DashboardLoading(),
            error: (error, _) => PharmaEmptyState(
              icon: Icons.error_outline,
              title: 'Dashboard could not load',
              message: 'The demo data failed to load. Try again — the data is local, so this should not happen.',
              actionLabel: 'Retry',
              onAction: () => ref.invalidate(dashboardKpisProvider(scope)),
            ),
            data: (kpis) => isOwner
                ? _OwnerDashboard(kpis: kpis)
                : _BranchDashboard(kpis: kpis, user: user),
          ),
        ],
      ),
    );
  }
}

/// Dashboard KPIs for a scope: `'all'` (owner, every branch) or a
/// branch id. Invalidating re-runs the load (retry button).
final dashboardKpisProvider = FutureProvider.autoDispose
    .family<DashboardKpis, String>((ref, scope) async {
      final orders = await ref.read(orderRepositoryProvider).getOrders();
      final inventory = await ref
          .read(inventoryRepositoryProvider)
          .getInventory();
      // Day 6: completed POS sales count toward the same figures, so
      // a cash sale rung through the POS shows on the dashboard
      // immediately (computeDashboardKpis `sales` parameter).
      final sales = await ref.read(saleRepositoryProvider).getSales();
      // Prescriptions are fetched already branch-scoped (the Day 0
      // model has no branchId; the mock scopes by seed id prefix) —
      // computeDashboardKpis counts whatever list it is given.
      final prescriptions = await ref
          .read(prescriptionRepositoryProvider)
          .getPrescriptions(branchId: scope == 'all' ? null : scope);
      return computeDashboardKpis(
        orders: orders,
        inventory: inventory,
        prescriptions: prescriptions,
        sales: sales,
        branchId: scope == 'all' ? null : scope,
        now: DateTime.now(),
      );
    });

/// Owner live KPIs for a scope: `'all'` (owner, every branch) or a
/// branch id. Gross profit (today, POS sales only), outstanding khata,
/// open POs, low stock, near-expiry and pending prescriptions — all
/// computed from the production data layer (see
/// `owner_dashboard_data.dart`).
final ownerLiveKpisProvider = FutureProvider.autoDispose
    .family<OwnerLiveKpis, String>((ref, scope) async {
      final branchId = scope == 'all' ? null : scope;
      final inventory = await ref
          .read(inventoryRepositoryProvider)
          .getInventory(branchId: branchId);
      final sales = await ref
          .read(saleRepositoryProvider)
          .getSales(branchId: branchId);
      final medicines = await ref
          .read(medicineRepositoryProvider)
          .getMedicines();
      final returns = await ref
          .read(saleReturnRepositoryProvider)
          .getReturns(branchId: branchId);
      final prescriptions = await ref
          .read(prescriptionRepositoryProvider)
          .getPrescriptions(branchId: branchId);
      final purchaseOrders = await ref
          .read(purchaseOrderRepositoryProvider)
          .getPurchaseOrders(branchId: branchId);
      final customers = await ref.read(customerRepositoryProvider).getCustomers();
      final ledgerEntries = <LedgerEntry>[];
      for (final customer in customers) {
        ledgerEntries.addAll(
          await ref
              .read(customerRepositoryProvider)
              .getLedgerEntries(customer.id),
        );
      }
      // Outstanding: all branches count every entry; a branch scope
      // counts only entries linked to that branch's credit sales
      // (D79 — manual entries have no branch).
      final allSales = branchId == null
          ? sales
          : await ref.read(saleRepositoryProvider).getSales();
      final saleBranchById = {
        for (final sale in allSales) sale.id: sale.branchId,
      };
      final outstanding = branchId == null
          ? computeOutstandingKhataMinor(ledgerEntries)
          : ledgerEntries
                .where(
                  (entry) =>
                      entry.referenceId != null &&
                      saleBranchById[entry.referenceId] == branchId,
                )
                .fold(0, (sum, entry) => sum + entry.amountMinor);
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      var lowStock = 0;
      var nearExpiry = 0;
      for (final item in inventory) {
        if (item.isLowStock) lowStock++;
        final expiry = item.expiryDate;
        if (expiry == null) continue;
        final expiryDay = DateTime(expiry.year, expiry.month, expiry.day);
        if (!expiryDay.isBefore(today) &&
            !expiryDay.isAfter(today.add(const Duration(days: 30)))) {
          nearExpiry++;
        }
      }
      return OwnerLiveKpis(
        grossProfitMinor: computeGrossProfitMinor(
          sales: sales,
          inventory: inventory,
          medicines: medicines,
          returns: returns,
          now: now,
        ),
        outstandingKhataMinor: outstanding,
        openPurchaseOrders: countOpenPurchaseOrders(purchaseOrders),
        lowStockCount: lowStock,
        nearExpiryCount: nearExpiry,
        pendingPrescriptions: prescriptions
            .where((rx) => rx.status == PrescriptionStatus.pending)
            .length,
      );
    });

/// Branch comparison for the signed-in user (Week 2 Day 4).
///
/// The branches shown are enforced by the permission service +
/// branch context: `allBranches` `allowed` / `readOnly` (Owner, HO
/// Admin, Accountant, Auditor — and a signed-out user, per D70)
/// sees every demo branch; an `own` role (Branch Manager, Cashier,
/// Pharmacist, …) sees only the branches in their `branchIds`
/// claim. The owner dashboard renders this provider; branch users
/// never see another branch's row.
final branchComparisonProvider =
    FutureProvider.autoDispose<List<BranchComparisonRow>>((ref) async {
      final user = ref.watch(authProvider);
      final permission = permissionService.permissionFor(user, 'allBranches');
      final seesAll =
          permission == RolePermission.allowed ||
          permission == RolePermission.readOnly;
      final branches = seesAll
          ? demoBranches
          : demoBranches
                .where(
                  (branch) =>
                      (user?.branchIds ?? []).contains(branch.id),
                )
                .toList();
      final visibleBranches = branches.isEmpty
          ? [ref.watch(activeBranchProvider)]
          : branches;
      final orders = await ref.read(orderRepositoryProvider).getOrders();
      final inventory = await ref
          .read(inventoryRepositoryProvider)
          .getInventory();
      final sales = await ref.read(saleRepositoryProvider).getSales();
      final prescriptions = await ref
          .read(prescriptionRepositoryProvider)
          .getPrescriptions();
      final purchaseOrders = await ref
          .read(purchaseOrderRepositoryProvider)
          .getPurchaseOrders();
      final customers = await ref.read(customerRepositoryProvider).getCustomers();
      final ledgerEntries = <LedgerEntry>[];
      for (final customer in customers) {
        ledgerEntries.addAll(
          await ref
              .read(customerRepositoryProvider)
              .getLedgerEntries(customer.id),
        );
      }
      return computeBranchComparison(
        branches: visibleBranches,
        orders: orders,
        sales: sales,
        inventory: inventory,
        prescriptions: prescriptions,
        purchaseOrders: purchaseOrders,
        ledgerEntries: ledgerEntries,
        now: DateTime.now(),
      );
    });

/// Alerts feed for a scope, from the notifications module
/// (`buildNotifications` — the same derived alerts the Notifications
/// screen shows). `'all'` = every branch (owner); otherwise the
/// branch id.
final dashboardAlertsFeedProvider = FutureProvider.autoDispose
    .family<List<AppNotification>, String>((ref, scope) async {
      final orders = await ref.read(orderRepositoryProvider).getOrders();
      final inventory = await ref
          .read(inventoryRepositoryProvider)
          .getInventory();
      final prescriptions = await ref
          .read(prescriptionRepositoryProvider)
          .getPrescriptions();
      final purchaseOrders = await ref
          .read(purchaseOrderRepositoryProvider)
          .getPurchaseOrders();
      return buildNotifications(
        orders: orders,
        inventory: inventory,
        prescriptions: prescriptions,
        purchaseOrders: purchaseOrders,
        branchId: scope == 'all' ? null : scope,
        now: DateTime.now(),
      );
    });

/// One alert row: low stock, near-expiry or expired batch.
class AlertItem {
  const AlertItem({
    required this.icon,
    required this.title,
    required this.detail,
    required this.kind,
    this.medicineId,
  });

  final IconData icon;
  final String title;
  final String detail;
  final StatusKind kind;

  /// Medicine this alert is about — tapping the alert opens its detail
  /// (Day 5); null falls back to the inventory screen.
  final String? medicineId;
}

/// Stock alerts for a scope: `'all'` (owner) or a branch id.
final dashboardAlertsProvider = FutureProvider.autoDispose
    .family<List<AlertItem>, String>((ref, scope) async {
      final inventory = await ref
          .read(inventoryRepositoryProvider)
          .getInventory();
      final medicines = await ref
          .read(medicineRepositoryProvider)
          .getMedicines();
      return buildAlerts(
        inventory,
        medicines,
        scope == 'all' ? null : scope,
        DateTime.now(),
      );
    });

/// Builds the alert list from inventory rows: expired batches first,
/// then soonest expiry, then low stock. Capped at 8, most severe first.
List<AlertItem> buildAlerts(
  List<InventoryItem> inventory,
  List<Medicine> medicines,
  String? branchId,
  DateTime now,
) {
  final today = DateTime(now.year, now.month, now.day);
  final byId = {for (final m in medicines) m.id: m};
  final alerts = <AlertItem>[];
  final scoped = branchId == null
      ? inventory
      : inventory.where((item) => item.branchId == branchId);
  for (final item in scoped) {
    final name = byId[item.medicineId]?.name ?? item.medicineId;
    final expiry = item.expiryDate;
    if (expiry != null) {
      final expiryDay = DateTime(expiry.year, expiry.month, expiry.day);
      final daysLeft = expiryDay.difference(today).inDays;
      if (daysLeft < 0) {
        alerts.add(
          AlertItem(
            icon: Icons.dangerous_outlined,
            title: '$name — expired',
            detail:
                'Batch ${item.batchNo ?? '—'} expired ${-daysLeft} day(s) ago',
            kind: StatusKind.danger,
            medicineId: item.medicineId,
          ),
        );
        continue;
      }
      if (daysLeft <= 30) {
        alerts.add(
          AlertItem(
            icon: Icons.event_outlined,
            title: '$name — expiring soon',
            detail: 'Batch ${item.batchNo ?? '—'} expires in $daysLeft day(s)',
            kind: StatusKind.warning,
            medicineId: item.medicineId,
          ),
        );
      }
    }
    if (item.isLowStock) {
      alerts.add(
        AlertItem(
          icon: Icons.inventory_2_outlined,
          title: '$name — low stock',
          detail: '${item.quantity} left (alert at ${item.lowStockThreshold})',
          kind: StatusKind.warning,
          medicineId: item.medicineId,
        ),
      );
    }
  }
  alerts.sort(
    (a, b) => (a.kind == StatusKind.danger ? 0 : 1).compareTo(
      b.kind == StatusKind.danger ? 0 : 1,
    ),
  );
  return alerts.take(8).toList();
}

class _DashboardLoading extends StatelessWidget {
  const _DashboardLoading();

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SkeletonCard(),
        SizedBox(height: 12),
        SkeletonCard(),
        SizedBox(height: 12),
        SkeletonList(count: 3),
      ],
    );
  }
}

// --- Shared pieces ------------------------------------------------------

/// Responsive KPI grid: 5 across on wide screens, 3 on medium, 2 on
/// narrow. Each card navigates to its module when tapped.
class _KpiGrid extends StatelessWidget {
  const _KpiGrid({required this.cards});

  final List<Widget> cards;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth > 1100
            ? 5
            : constraints.maxWidth > 700
            ? 3
            : 2;
        return GridView.count(
          crossAxisCount: columns,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          // Fixed cell height: StatCard content (label row + big value +
          // optional delta, plus card padding) needs ~150px; an aspect
          // ratio made wide-screen cells too short and overflowed.
          mainAxisExtent: 200,
          children: cards,
        );
      },
    );
  }
}

String _deltaLabel(int todayMinor, int yesterdayMinor) {
  if (yesterdayMinor == 0) return 'No sales yesterday';
  final change = ((todayMinor - yesterdayMinor) / yesterdayMinor * 100).round();
  final sign = change >= 0 ? '+' : '';
  return '$sign$change% vs yesterday';
}

class _TopSellersCard extends StatelessWidget {
  const _TopSellersCard({required this.kpis});

  final DashboardKpis kpis;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PharmaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            title: 'Top-selling medicines',
            subtitle: 'By revenue, last 30 days',
            actionLabel: 'Medicines',
            actionIcon: Icons.medication_outlined,
            onAction: () => context.go('/medicines'),
          ),
          const SizedBox(height: 8),
          if (kpis.topSellers.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text('No sales in the last 30 days.'),
            )
          else
            for (var i = 0; i < kpis.topSellers.length; i++) ...[
              _TopSellerRow(rank: i + 1, seller: kpis.topSellers[i]),
              if (i < kpis.topSellers.length - 1)
                Divider(
                  height: 1,
                  color: theme.dividerColor.withValues(alpha: 0.4),
                ),
            ],
        ],
      ),
    );
  }
}

class _TopSellerRow extends StatelessWidget {
  const _TopSellerRow({required this.rank, required this.seller});

  final int rank;
  final TopSeller seller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: () => context.go('/medicines'),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            SizedBox(
              width: 24,
              child: Text(
                '$rank',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    seller.medicineName,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    '${seller.quantitySold} sold',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            Text(
              formatPkr(seller.revenueMinor),
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RecentOrdersCard extends StatelessWidget {
  const _RecentOrdersCard({required this.kpis});

  final DashboardKpis kpis;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PharmaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            title: 'Recent orders',
            subtitle: 'Latest across the selected scope',
            actionLabel: 'Orders',
            actionIcon: Icons.receipt_long_outlined,
            onAction: () => context.go('/orders'),
          ),
          const SizedBox(height: 8),
          if (kpis.recentOrders.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text('No orders yet.'),
            )
          else
            for (var i = 0; i < kpis.recentOrders.length; i++) ...[
              _RecentOrderRow(order: kpis.recentOrders[i]),
              if (i < kpis.recentOrders.length - 1)
                Divider(
                  height: 1,
                  color: theme.dividerColor.withValues(alpha: 0.4),
                ),
            ],
        ],
      ),
    );
  }
}

class _RecentOrderRow extends StatelessWidget {
  const _RecentOrderRow({required this.order});

  final Order order;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final created = order.createdAt;
    final timeLabel = created == null
        ? ''
        : '${created.hour.toString().padLeft(2, '0')}:${created.minute.toString().padLeft(2, '0')} • ${created.day}/${created.month}';
    return InkWell(
      onTap: () => context.go('/orders/${order.id}'),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    order.id,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(timeLabel, style: theme.textTheme.bodySmall),
                ],
              ),
            ),
            // Week 4 Day 5 (D142): price + badge sat side by side
            // and overflowed by 11px at 390px — the badge ("Out for
            // Delivery") is long. Price above, badge below: the
            // column is only as wide as the badge, and the id
            // column keeps the rest.
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  formatPkr(rupeesToMinorUnits(order.totalAmount)),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                StatusBadge(
                  label: orderStatusLabel(order.status),
                  kind: orderStatusKind(order.status),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _AlertsCard extends StatelessWidget {
  const _AlertsCard({required this.alerts});

  final List<AlertItem> alerts;

  @override
  Widget build(BuildContext context) {
    return PharmaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            title: 'Alerts',
            subtitle: alerts.isEmpty
                ? 'Nothing needs attention'
                : '${alerts.length} item(s) need attention',
            actionLabel: 'Inventory',
            actionIcon: Icons.inventory_2_outlined,
            onAction: () => context.go('/inventory'),
          ),
          const SizedBox(height: 8),
          if (alerts.isEmpty)
            const PharmaEmptyState(
              icon: Icons.check_circle_outline,
              title: 'All clear',
              message: 'No low-stock or expiry alerts right now.',
            )
          else
            for (final alert in alerts)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: InkWell(
                  onTap: () => context.go(
                    alert.medicineId == null
                        ? '/inventory'
                        : '/medicines/${alert.medicineId}',
                  ),
                  child: Row(
                    children: [
                      Icon(alert.icon, size: 20, color: alert.kind.color),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              alert.title,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(fontWeight: FontWeight.w600),
                            ),
                            Text(
                              alert.detail,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      StatusBadge(
                        label: alert.kind == StatusKind.danger
                            ? 'Expired'
                            : 'Attention',
                        kind: alert.kind,
                      ),
                    ],
                  ),
                ),
              ),
        ],
      ),
    );
  }
}

/// Alerts section: watches [dashboardAlertsProvider] for the scope and
/// renders the card (or a skeleton while loading).
class _AlertsSection extends ConsumerWidget {
  const _AlertsSection({required this.scope});

  final String scope;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final alertsAsync = ref.watch(dashboardAlertsProvider(scope));
    return alertsAsync.when(
      loading: () => const PharmaCard(
        child: ShimmerBox(width: double.infinity, height: 120),
      ),
      error: (error, _) => const PharmaEmptyState(
        icon: Icons.error_outline,
        title: 'Alerts could not load',
        message: 'The demo inventory data failed to load.',
      ),
      data: (alerts) => _AlertsCard(alerts: alerts),
    );
  }
}

// --- Owner dashboard ----------------------------------------------------

class _OwnerDashboard extends ConsumerWidget {
  const _OwnerDashboard({required this.kpis});

  final DashboardKpis kpis;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final liveKpisAsync = ref.watch(ownerLiveKpisProvider('all'));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _KpiGrid(
          cards: [
            StatCard(
              label: "Today's sales",
              moneyMinorUnits: kpis.todaySalesMinor,
              icon: Icons.attach_money,
              deltaLabel: _deltaLabel(
                kpis.todaySalesMinor,
                kpis.yesterdaySalesMinor,
              ),
              deltaPositive: kpis.todaySalesMinor >= kpis.yesterdaySalesMinor,
              onTap: () => context.go('/reports'),
            ),
            StatCard(
              label: "Today's orders",
              value: '${kpis.todayOrders}',
              icon: Icons.receipt_long_outlined,
              onTap: () => context.go('/orders'),
            ),
            StatCard(
              label: 'Revenue — 30 days',
              moneyMinorUnits: kpis.revenue30dMinor,
              icon: Icons.trending_up,
              deltaLabel: '${kpis.orders30d} orders in 30 days',
              onTap: () => context.go('/reports'),
            ),
            StatCard(
              label: 'Low stock',
              value: '${kpis.lowStockCount}',
              icon: Icons.inventory_2_outlined,
              onTap: () => context.go('/inventory'),
            ),
            StatCard(
              label: 'Near expiry',
              value: '${kpis.nearExpiryCount}',
              icon: Icons.event_outlined,
              deltaLabel: kpis.expiredCount > 0
                  ? '${kpis.expiredCount} already expired'
                  : 'None expired',
              deltaPositive: kpis.expiredCount == 0,
              onTap: () => context.go('/inventory'),
            ),
            // Week 2 Day 4 live KPIs — fed by the production data
            // layer (ownerLiveKpisProvider), not the Day 3 set.
            ...liveKpisAsync.when(
              loading: () => const <Widget>[
                SkeletonCard(),
                SkeletonCard(),
                SkeletonCard(),
              ],
              error: (error, _) => const <Widget>[],
              data: (live) => [
                StatCard(
                  label: 'Gross profit — today',
                  moneyMinorUnits: live.grossProfitMinor,
                  icon: Icons.account_balance_wallet_outlined,
                  deltaLabel: 'POS sales only, after batch cost',
                  onTap: () => context.go('/reports'),
                ),
                StatCard(
                  label: 'Outstanding khata',
                  moneyMinorUnits: live.outstandingKhataMinor,
                  icon: Icons.book_outlined,
                  deltaLabel: 'Across all customers',
                  onTap: () => context.go('/customers'),
                ),
                StatCard(
                  label: 'Open purchase orders',
                  value: '${live.openPurchaseOrders}',
                  icon: Icons.shopping_cart_outlined,
                  deltaLabel: 'Draft / approved / partially received',
                  onTap: () => context.go('/purchases'),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 16),
        PharmaCard(child: SalesChart(series: kpis.salesSeries)),
        const SizedBox(height: 16),
        const _BranchComparisonCard(),
        const SizedBox(height: 16),
        _TopSellersCard(kpis: kpis),
        const SizedBox(height: 16),
        _RecentOrdersCard(kpis: kpis),
        const SizedBox(height: 16),
        const _AlertsFeedSection(scope: 'all'),
        const SizedBox(height: 16),
        const _AlertsSection(scope: 'all'),
      ],
    );
  }
}

/// Branch comparison for the owner: every visible branch side by
/// side — today's sales, stock value, outstanding khata and alerts.
/// Tapping a branch switches the active branch and opens its orders
/// — the branch switcher in the top bar follows immediately.
///
/// On narrow screens each branch is a card (no cluttered table); on
/// wide screens the same rows read as a comparison table.
class _BranchComparisonCard extends ConsumerWidget {
  const _BranchComparisonCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final comparisonAsync = ref.watch(branchComparisonProvider);
    return PharmaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionHeader(
            title: 'Branch comparison',
            subtitle: 'Today, per branch — sales, stock value, khata, alerts',
          ),
          const SizedBox(height: 8),
          comparisonAsync.when(
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: ShimmerBox(width: double.infinity, height: 48),
            ),
            error: (error, _) => const Text('Branch figures could not load.'),
            data: (rows) => Column(
              children: [
                for (final row in rows)
                  _BranchComparisonRow(row: row),
                if (rows.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'Outstanding is charged to a branch only for khata entries linked to its own credit sales — manual entries count in the org-wide total on the Outstanding khata card above.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BranchComparisonRow extends ConsumerWidget {
  const _BranchComparisonRow({required this.row});

  final BranchComparisonRow row;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: () {
        ref.read(activeBranchProvider.notifier).switchTo(row.branchId);
        context.go('/orders');
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.store_outlined, color: theme.colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    row.branchName,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  formatPkr(row.todaySalesMinor),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 8),
                const Icon(Icons.chevron_right),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 16,
              runSpacing: 4,
              children: [
                _ComparisonStat(
                  label: 'Orders today',
                  value: '${row.todayOrders}',
                ),
                _ComparisonStat(
                  label: 'Stock value',
                  value: formatPkr(row.stockValueMinor),
                ),
                _ComparisonStat(
                  label: 'Outstanding',
                  value: formatPkr(row.outstandingMinor),
                ),
                _ComparisonStat(
                  label: 'Alerts',
                  value:
                      '${row.alertCount} (${row.lowStockCount} low stock, ${row.nearExpiryCount} near expiry, ${row.expiredCount} expired)',
                ),
                _ComparisonStat(
                  label: 'Pending Rx',
                  value: '${row.pendingPrescriptions}',
                ),
                _ComparisonStat(
                  label: 'Open POs',
                  value: '${row.openPurchaseOrders}',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ComparisonStat extends StatelessWidget {
  const _ComparisonStat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '$label: ',
            style: theme.textTheme.bodySmall,
          ),
          TextSpan(
            text: value,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// Alerts feed from the notifications module: the same derived alerts
/// the Notifications screen shows (low stock, expiry, pending
/// prescriptions, POs awaiting approval, today's new orders).
/// Tapping an alert opens its destination.
class _AlertsFeedSection extends ConsumerWidget {
  const _AlertsFeedSection({required this.scope});

  final String scope;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feedAsync = ref.watch(dashboardAlertsFeedProvider(scope));
    return PharmaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            title: 'Alerts feed',
            subtitle: 'From notifications — newest first',
            actionLabel: 'All notifications',
            actionIcon: Icons.notifications_outlined,
            onAction: () => context.go('/notifications'),
          ),
          const SizedBox(height: 8),
          feedAsync.when(
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: ShimmerBox(width: double.infinity, height: 48),
            ),
            error: (error, _) => const Text('Alerts could not load.'),
            data: (notifications) {
              if (notifications.isEmpty) {
                return const PharmaEmptyState(
                  icon: Icons.check_circle_outline,
                  title: 'All clear',
                  message: 'No alerts from the notifications feed right now.',
                );
              }
              return Column(
                children: [
                  for (final notification in notifications.take(6))
                    _AlertsFeedRow(notification: notification),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _AlertsFeedRow extends StatelessWidget {
  const _AlertsFeedRow({required this.notification});

  final AppNotification notification;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final icon = switch (notification.kind) {
      NotificationKind.lowStock => Icons.inventory_2_outlined,
      NotificationKind.nearExpiry => Icons.event_outlined,
      NotificationKind.expired => Icons.dangerous_outlined,
      NotificationKind.pendingPrescription => Icons.description_outlined,
      NotificationKind.newOrder => Icons.receipt_long_outlined,
      NotificationKind.purchaseApproval => Icons.shopping_cart_outlined,
    };
    return InkWell(
      onTap: () => context.go(notification.route),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Icon(icon, size: 20, color: theme.colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    notification.title,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    notification.body,
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, size: 20),
          ],
        ),
      ),
    );
  }
}

// --- Branch dashboard ---------------------------------------------------

class _BranchDashboard extends StatelessWidget {
  const _BranchDashboard({required this.kpis, required this.user});

  final DashboardKpis kpis;
  final AppUser? user;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _KpiGrid(
          cards: [
            StatCard(
              label: "Today's branch sales",
              moneyMinorUnits: kpis.todaySalesMinor,
              icon: Icons.attach_money,
              deltaLabel: _deltaLabel(
                kpis.todaySalesMinor,
                kpis.yesterdaySalesMinor,
              ),
              deltaPositive: kpis.todaySalesMinor >= kpis.yesterdaySalesMinor,
              onTap: () => context.go('/billing'),
            ),
            StatCard(
              label: "Today's orders",
              value: '${kpis.todayOrders}',
              icon: Icons.receipt_long_outlined,
              onTap: () => context.go('/orders'),
            ),
            StatCard(
              label: 'Pending prescriptions',
              value: '${kpis.pendingPrescriptions}',
              icon: Icons.description_outlined,
              onTap: () => context.go('/prescriptions'),
            ),
            StatCard(
              label: 'Low stock',
              value: '${kpis.lowStockCount}',
              icon: Icons.inventory_2_outlined,
              onTap: () => context.go('/inventory'),
            ),
            StatCard(
              label: 'Near expiry',
              value: '${kpis.nearExpiryCount}',
              icon: Icons.event_outlined,
              deltaLabel: kpis.expiredCount > 0
                  ? '${kpis.expiredCount} already expired'
                  : 'None expired',
              deltaPositive: kpis.expiredCount == 0,
              onTap: () => context.go('/inventory'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _QuickActionsCard(role: user?.demoRole),
        const SizedBox(height: 16),
        PharmaCard(child: SalesChart(series: kpis.salesSeries)),
        const SizedBox(height: 16),
        _TopSellersCard(kpis: kpis),
        const SizedBox(height: 16),
        _RecentOrdersCard(kpis: kpis),
        const SizedBox(height: 16),
        const _BranchAlertsSection(),
      ],
    );
  }
}

/// Quick actions, ordered for the signed-in role: cashiers see New Sale
/// first, pharmacists see Prescriptions first, inventory managers see
/// Stock Check first. Every action navigates to its module.
class _QuickActionsCard extends StatelessWidget {
  const _QuickActionsCard({required this.role});

  final DemoRole? role;

  List<(String, IconData, String)> get _actions {
    const newSale = ('New Sale', Icons.point_of_sale_outlined, '/billing');
    const newOrder = ('New Order', Icons.add_shopping_cart_outlined, '/orders');
    const stockCheck = (
      'Stock Check',
      Icons.inventory_2_outlined,
      '/inventory',
    );
    const prescriptions = (
      'Prescriptions',
      Icons.description_outlined,
      '/prescriptions',
    );
    const customers = ('Customers', Icons.people_outline, '/customers');
    const reports = ('Reports', Icons.bar_chart_outlined, '/reports');
    return switch (role) {
      DemoRole.cashier => [
        newSale,
        newOrder,
        customers,
        stockCheck,
        prescriptions,
        reports,
      ],
      DemoRole.pharmacist => [
        prescriptions,
        newSale,
        newOrder,
        stockCheck,
        customers,
        reports,
      ],
      DemoRole.inventoryManager => [
        stockCheck,
        newSale,
        newOrder,
        prescriptions,
        reports,
        customers,
      ],
      _ => [newOrder, newSale, stockCheck, prescriptions, customers, reports],
    };
  }

  @override
  Widget build(BuildContext context) {
    return PharmaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionHeader(
            title: 'Quick actions',
            subtitle: 'Common tasks for this branch',
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (label, icon, route) in _actions)
                PharmaButton(
                  label: label,
                  icon: icon,
                  variant: PharmaButtonVariant.secondary,
                  size: PharmaButtonSize.small,
                  onPressed: () => context.go(route),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Branch alerts section: watches the alerts provider for the active
/// branch (the scope follows the branch switcher).
class _BranchAlertsSection extends ConsumerWidget {
  const _BranchAlertsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final branch = ref.watch(activeBranchProvider);
    return _AlertsSection(scope: branch.id);
  }
}
