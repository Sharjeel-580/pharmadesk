import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/services/branch_context.dart';
import '../../core/widgets/design_system.dart';
import '../../core/widgets/pagination_controls.dart';
import '../../features/inventory/transfer_logic.dart';
import '../../models/rider.dart';
import 'rider_logic.dart';
import 'rider_provider.dart';

/// Rider list (SRS D-21, Week 4 Day 2).
///
/// Route `/riders`.
///
/// Every delivery rider: name, phone, vehicle, home branch,
/// availability (Available / On delivery / Inactive) and the live
/// order when one is assigned. Rows are paged at 10 (D107). Tapping
/// a rider opens the detail screen with his assigned orders and the
/// assign action.
///
/// **Demo data:** the seeded riders are fictional sample riders —
/// the screen labels them as demo/sample wherever it shows them.
/// Riders are a separate model from Staff (D119): the SRS and the
/// seed already have one, with vehicle + live-order fields Staff
/// does not carry.
class RiderListScreen extends ConsumerStatefulWidget {
  const RiderListScreen({super.key});

  @override
  ConsumerState<RiderListScreen> createState() => _RiderListScreenState();
}

class _RiderListScreenState extends ConsumerState<RiderListScreen> {
  String? _branchFilter;
  RiderAvailability? _availabilityFilter;

  @override
  Widget build(BuildContext context) {
    final ridersAsync = ref.watch(riderProvider);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            title: 'Riders & Delivery',
            subtitle:
                'Delivery riders — availability, live orders, assignment',
            actionLabel: 'Back to Orders',
            actionIcon: Icons.receipt_long_outlined,
            onAction: () => context.go('/orders'),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              DropdownButton<String?>(
                key: const ValueKey('rider-branch-filter'),
                value: _branchFilter,
                hint: const Text('All branches'),
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('All branches'),
                  ),
                  for (final branch in demoBranches)
                    DropdownMenuItem<String?>(
                      value: branch.id,
                      child: Text(branch.name),
                    ),
                ],
                onChanged: (selected) =>
                    setState(() => _branchFilter = selected),
              ),
              for (final availability in [
                null,
                ...RiderAvailability.values,
              ])
                ChoiceChip(
                  label: Text(
                    availability == null
                        ? 'All riders'
                        : availability.label,
                  ),
                  selected: _availabilityFilter == availability,
                  onSelected: (_) => setState(
                    () => _availabilityFilter = availability,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          ridersAsync.when(
            loading: () =>
                const Center(child: CircularProgressIndicator()),
            error: (error, _) => PharmaEmptyState(
              icon: Icons.error_outline,
              title: 'Could not load riders',
              message: error.toString(),
              actionLabel: 'Retry',
              onAction: () => ref.invalidate(riderProvider),
            ),
            data: (riders) {
              final filtered = riders.where((rider) {
                if (_branchFilter != null &&
                    rider.branchId != _branchFilter) {
                  return false;
                }
                if (_availabilityFilter != null &&
                    riderAvailability(rider) != _availabilityFilter) {
                  return false;
                }
                return true;
              }).toList();
              if (filtered.isEmpty) {
                return const PharmaEmptyState(
                  icon: Icons.delivery_dining_outlined,
                  title: 'No riders match',
                  message: 'No riders match this filter.',
                );
              }
              return PagedList<Rider>(
                items: filtered,
                pageSize: 10,
                emptyMessage: 'No riders match this filter.',
                itemBuilder: (context, rider) {
                  final availability = riderAvailability(rider);
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: PharmaCard(
                      child: InkWell(
                        onTap: () => context.go('/riders/${rider.id}'),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          rider.name,
                                          style: Theme.of(context)
                                              .textTheme
                                              .titleMedium
                                              ?.copyWith(
                                                fontWeight: FontWeight.w700,
                                              ),
                                        ),
                                      ),
                                      const Padding(
                                        padding: EdgeInsets.only(right: 8),
                                        child: StatusBadge(
                                          label: 'Demo',
                                          kind: StatusKind.neutral,
                                        ),
                                      ),
                                      StatusBadge(
                                        label: availability.label,
                                        kind: availability.kind,
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '${rider.phone}'
                                    '${rider.vehicle != null ? ' • ${rider.vehicle!}' : ''}',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodyMedium,
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    rider.branchId == null
                                        ? 'Branch not set'
                                        : branchDisplayName(rider.branchId!)
                                        +
                                            (rider.currentOrderId == null
                                                ? ''
                                                : ' • On order ${rider.currentOrderId!}'),
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  ),
                                ],
                              ),
                            ),
                            const Icon(Icons.chevron_right),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              );
            },
          ),
          const SizedBox(height: 16),
          Text(
            'Sample riders are labelled Demo — fictional sample data. '
            'Assign a rider from an order or from a rider’s detail '
            'screen; both use the same assignment write path.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
