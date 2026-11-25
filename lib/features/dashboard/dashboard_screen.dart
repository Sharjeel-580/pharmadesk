import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/services/branch_context.dart';
import '../../core/services/repositories.dart';
import '../../core/utils/money.dart';
import '../../core/widgets/design_system.dart';
import '../../models/branch.dart';
import '../../models/inventory_item.dart';
import '../../models/medicine.dart';
import '../../models/order.dart';
import '../authentication/auth_state.dart';
import 'dashboard_data.dart';
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
              message:
                  'The demo data failed to load. Try again — the data is local, so this should not happen.',
              actionLabel: 'Retry',
              onAction: () =>
                  ref.invalidate(dashboardKpisProvider(scope)),
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
final dashboardKpisProvider =
    FutureProvider.autoDispose.family<DashboardKpis, String>(
      (ref, scope) async {
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
      },
    );

/// Per-branch KPIs for the owner branch-performance card.
final branchPerformanceProvider =
    FutureProvider.autoDispose<List<(Branch, DashboardKpis)>>((ref) async {
      final orders = await ref.read(orderRepositoryProvider).getOrders();
      final inventory = await ref
          .read(inventoryRepositoryProvider)
          .getInventory();
      final sales = await ref.read(saleRepositoryProvider).getSales();
      final prescriptions = await ref
          .read(prescriptionRepositoryProvider)
          .getPrescriptions();
      return [
        for (final branch in demoBranches)
          (
            branch,
            computeDashboardKpis(
              orders: orders,
              inventory: inventory,
              // Branch performance only shows sales/orders per branch;
              // prescriptions are not displayed here, so the unscoped
              // list is fine (pending counts are not shown).
              prescriptions: prescriptions,
              sales: sales,
              branchId: branch.id,
              now: DateTime.now(),
            ),
          ),
      ];
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
final dashboardAlertsProvider =
    FutureProvider.autoDispose.family<List<AlertItem>, String>(
      (ref, scope) async {
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
      },
    );

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
            detail:
                'Batch ${item.batchNo ?? '—'} expires in $daysLeft day(s)',
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
          detail:
              '${item.quantity} left (alert at ${item.lowStockThreshold})',
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
  final change = ((todayMinor - yesterdayMinor) / yesterdayMinor * 100)
      .round();
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
            Text(
              formatPkr(rupeesToMinorUnits(order.totalAmount)),
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 12),
            StatusBadge(
              label: orderStatusLabel(order.status),
              kind: orderStatusKind(order.status),
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

class _OwnerDashboard extends StatelessWidget {
  const _OwnerDashboard({required this.kpis});

  final DashboardKpis kpis;

  @override
  Widget build(BuildContext context) {
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
              deltaPositive:
                  kpis.todaySalesMinor >= kpis.yesterdaySalesMinor,
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
          ],
        ),
        const SizedBox(height: 16),
        PharmaCard(child: SalesChart(series: kpis.salesSeries)),
        const SizedBox(height: 16),
        const _BranchPerformanceCard(),
        const SizedBox(height: 16),
        _TopSellersCard(kpis: kpis),
        const SizedBox(height: 16),
        _RecentOrdersCard(kpis: kpis),
        const SizedBox(height: 16),
        const _AlertsSection(scope: 'all'),
      ],
    );
  }
}

/// Per-branch performance for the owner: today's sales + orders per
/// branch, computed from the same seed data. Tapping a branch switches
/// the active branch and opens its orders — the branch switcher in the
/// top bar follows immediately.
class _BranchPerformanceCard extends ConsumerWidget {
  const _BranchPerformanceCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final performanceAsync = ref.watch(branchPerformanceProvider);
    return PharmaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionHeader(
            title: 'Branch performance',
            subtitle: 'Today, per branch',
          ),
          const SizedBox(height: 8),
          performanceAsync.when(
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: ShimmerBox(width: double.infinity, height: 48),
            ),
            error: (error, _) =>
                const Text('Branch figures could not load.'),
            data: (rows) => Column(
              children: [
                for (final (branch, kpis) in rows)
                  _BranchPerformanceRow(branch: branch, kpis: kpis),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BranchPerformanceRow extends ConsumerWidget {
  const _BranchPerformanceRow({required this.branch, required this.kpis});

  final Branch branch;
  final DashboardKpis kpis;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: () {
        ref.read(activeBranchProvider.notifier).switchTo(branch.id);
        context.go('/orders');
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Icon(
              Icons.store_outlined,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    branch.name,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    '${kpis.todayOrders} orders today',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            Text(
              formatPkr(kpis.todaySalesMinor),
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.chevron_right),
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
  final DemoUser? user;

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
              deltaPositive:
                  kpis.todaySalesMinor >= kpis.yesterdaySalesMinor,
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
        _QuickActionsCard(role: user?.role),
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
    const newOrder = (
      'New Order',
      Icons.add_shopping_cart_outlined,
      '/orders',
    );
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
