import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/services/branch_context.dart';
import '../../core/utils/money.dart';
import '../../core/widgets/design_system.dart';
import '../authentication/auth_state.dart';
import '../branches/branch_directory.dart';
import 'franchise_logic.dart';
import 'franchise_provider.dart';

/// Franchise commission / royalty (Week 5 Day 5, D158/D159 —
/// SRS D-28 / FR-HO-07, P3, Phase 2 prep).
///
/// Route `/finance/franchise`, head-office only (see
/// [canViewFranchiseRoyalties] — Super Admin / Owner / HO Admin;
/// everyone else sees the no-permission state). Read-only: the
/// per-branch royalty / franchise-fee due for the window, with the
/// configured rates shown and "Not set" where a rate was never
/// configured. Rates are set in Branch Management → branch detail
/// → Franchise settings — this screen never edits terms, and there
/// is no onboarding flow here (Phase 2 business scope, not V1).
///
/// Honest about the demo: V1 runs the 8 own branches only, so the
/// demo rows show real period sales with both rates "Not set" and
/// Rs 0.00 due. No franchise agreement is invented to make the
/// screen look busier.
class FranchiseScreen extends ConsumerStatefulWidget {
  const FranchiseScreen({super.key});

  @override
  ConsumerState<FranchiseScreen> createState() => _FranchiseScreenState();
}

class _FranchiseScreenState extends ConsumerState<FranchiseScreen> {
  var _days = 30;

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authProvider);
    final branchId = ref.watch(activeBranchProvider).id;
    if (user != null && !canViewFranchiseRoyalties(user, branchId)) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionHeader(
              title: 'Franchise Royalties',
              subtitle:
                  'Royalty and franchise-fee commission due per branch — head office only.',
              actionLabel: 'Back to Dashboard',
              actionIcon: Icons.dashboard_outlined,
              onAction: () => context.go('/dashboard'),
            ),
            const SizedBox(height: 16),
            PharmaEmptyState(
              icon: Icons.lock_outline,
              title: 'No permission for Franchise Royalties',
              message:
                  'Your role (${user.roleLabel}) does not have the '
                  '"branches" permission for this branch (SRS §5.1). '
                  'Franchise royalty figures are head-office only — '
                  'ask an owner or HO admin if you need them.',
              actionLabel: 'Back to Dashboard',
              onAction: () => context.go('/dashboard'),
            ),
          ],
        ),
      );
    }
    final reportAsync = ref.watch(franchiseRoyaltiesProvider(_days));
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionHeader(
            title: 'Franchise Royalties',
            subtitle:
                'Royalty and franchise-fee commission due per branch — head office only.',
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment<int>(value: 7, label: Text('7 days')),
                  ButtonSegment<int>(value: 30, label: Text('30 days')),
                  ButtonSegment<int>(value: 90, label: Text('90 days')),
                ],
                selected: {_days},
                onSelectionChanged: (selected) {
                  setState(() => _days = selected.single);
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
          reportAsync.when(
            loading: () => const SkeletonList(count: 3),
            error: (error, _) => PharmaEmptyState(
              icon: Icons.error_outline,
              title: 'Royalties could not load',
              message: 'The franchise royalty figures failed to load.',
              actionLabel: 'Retry',
              onAction: () =>
                  ref.invalidate(franchiseRoyaltiesProvider(_days)),
            ),
            data: (report) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                PharmaCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Last ${report.days} days '
                        '(${_dateText(report.start)} – '
                        '${_dateText(report.end)})',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 12),
                      _SummaryRow(
                        label: 'Total branch sales',
                        value: formatPkr(report.totalSalesMinor),
                      ),
                      _SummaryRow(
                        label: 'Total royalty due',
                        value: formatPkr(report.totalRoyaltyDueMinor),
                      ),
                      _SummaryRow(
                        label: 'Total franchise fees due',
                        value: formatPkr(report.totalFranchiseFeeDueMinor),
                      ),
                      const Divider(height: 16),
                      _SummaryRow(
                        label: 'Total commission due',
                        value: formatPkr(report.totalDueMinor),
                        bold: true,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${report.configuredBranchCount} of '
                        '${report.rows.length} branch(es) have a '
                        'royalty or franchise-fee rate configured.',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                const SectionHeader(
                  title: 'Per-branch royalty',
                  subtitle:
                      'Sales are the same revenue the P&L shows for the same branch and window (POS sales + orders − returns).',
                ),
                const SizedBox(height: 12),
                for (final row in report.rows) ...[
                  _BranchRoyaltyCard(row: row),
                  const SizedBox(height: 12),
                ],
                const Text(
                  'Rates are set in Branch Management → branch detail → '
                  'Franchise settings. This view never edits terms, and '
                  'a rate that was never configured shows as "Not set" — '
                  'never as 0%. Demo data only: V1 runs the own branches, '
                  'so their rows show real sales with no rates configured '
                  'and Rs 0.00 due.',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String _dateText(DateTime date) =>
    '${date.day}/${date.month}/${date.year}';

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({
    required this.label,
    required this.value,
    this.bold = false,
  });

  final String label;
  final String value;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text(label, style: style)),
          Text(value, style: style),
        ],
      ),
    );
  }
}

class _BranchRoyaltyCard extends StatelessWidget {
  const _BranchRoyaltyCard({required this.row});

  final FranchiseRoyaltyRow row;

  @override
  Widget build(BuildContext context) {
    final branch = row.branch;
    return PharmaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  branch.name,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              Text(
                '${branch.isFranchise ? 'Franchise' : 'Own branch'}'
                '${branch.active ? '' : ' • Deactivated'}',
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _SummaryRow(
            label: 'Sales in period',
            value: formatPkr(row.salesMinor),
          ),
          _SummaryRow(
            label: 'Royalty rate',
            value: branchRateLabel(branch.royaltyRateBps),
          ),
          _SummaryRow(
            label: 'Royalty due',
            value: franchiseDueLabel(row.royaltyDueMinor),
          ),
          _SummaryRow(
            label: 'Franchise fee rate',
            value: branchRateLabel(branch.franchiseFeeRateBps),
          ),
          _SummaryRow(
            label: 'Franchise fee due',
            value: franchiseDueLabel(row.franchiseFeeDueMinor),
          ),
          const Divider(height: 16),
          _SummaryRow(
            label: 'Total due',
            value: formatPkr(row.totalDueMinor),
            bold: true,
          ),
        ],
      ),
    );
  }
}
