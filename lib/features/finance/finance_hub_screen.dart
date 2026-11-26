import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/data/auth_repository.dart';
import '../../core/data/permission_service.dart';
import '../../core/services/branch_context.dart';
import '../../core/widgets/design_system.dart';
import '../authentication/auth_state.dart';

/// Finance hub (Week 4 Day 3, D124 — SRS D-24 / D-25 / D-26).
///
/// The landing screen for the Finance module: three cards, one per
/// finance screen. The hub itself is NOT capability-gated (D124 —
/// the module flag is the only gate): each card checks the SRS §5.1
/// capability for its screen in the active branch, and a card the
/// user may not use shows why instead of navigating. The screens
/// themselves are route-gated too (`routeCapability`), so a direct
/// deep link is stopped the same way.
class FinanceHubScreen extends ConsumerWidget {
  const FinanceHubScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authProvider);
    final branchId = ref.watch(activeBranchProvider).id;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionHeader(
            title: 'Finance',
            subtitle:
                'Cashbook, payables & receivables, P&L and branch statements.',
          ),
          const SizedBox(height: 16),
          _FinanceCard(
            icon: Icons.book_outlined,
            title: 'Cashbook',
            subtitle:
                'Income and expense entries by category, with a daily closing for each branch day.',
            capability: 'financeEntry',
            route: '/finance/cashbook',
            user: user,
            branchId: branchId,
          ),
          const SizedBox(height: 12),
          _FinanceCard(
            icon: Icons.account_balance_outlined,
            title: 'Payables & Receivables',
            subtitle:
                'Supplier payables and customer receivables aged Current / 31–60 / 61–90 / 90+ days.',
            capability: 'financeReports',
            route: '/finance/aging',
            user: user,
            branchId: branchId,
          ),
          const SizedBox(height: 12),
          _FinanceCard(
            icon: Icons.request_quote_outlined,
            title: 'P&L & Statements',
            subtitle:
                'Profit & loss and per-branch statements — the same figures the Reports hub shows.',
            capability: 'financeReports',
            route: '/finance/statements',
            user: user,
            branchId: branchId,
          ),
          const SizedBox(height: 16),
          const Text(
            'The P&L figures on the Statements screen come from the same '
            'computation the Reports hub shows for the same window and '
            'branch (D128) — if they ever disagree, that is a bug.',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _FinanceCard extends StatelessWidget {
  const _FinanceCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.capability,
    required this.route,
    required this.user,
    required this.branchId,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String capability;
  final String route;
  final AppUser? user;
  final String branchId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final allowed =
        permissionService.canInBranch(user, capability, branchId);
    return PharmaCard(
      onTap: allowed ? () => context.go(route) : null,
      child: ListTile(
        leading: Icon(icon, color: theme.colorScheme.primary),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(subtitle),
            if (!allowed) ...[
              const SizedBox(height: 4),
              Text(
                'No access for your role in this branch (SRS §5.1).',
                style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ],
        ),
        trailing: Icon(
          allowed ? Icons.chevron_right : Icons.lock_outlined,
          color: allowed ? null : theme.colorScheme.error,
        ),
      ),
    );
  }
}
