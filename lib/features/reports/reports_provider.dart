import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/repositories.dart';
import 'reports_logic.dart';

/// Day 7 reports state.
///
/// The report set for a (branch, window) pair, computed from the
/// repositories on demand. The family argument is `(branchId, days)`:
/// `branchId == null` means all branches; `days` is 1, 7 or 30.
/// Invalidating re-runs the computation (retry button, or after a
/// sale / receive that changes the figures).
final reportDataProvider =
    FutureProvider.family<ReportData, (String?, int)>((ref, args) async {
      final (branchId, days) = args;
      final orders = await ref.read(orderRepositoryProvider).getOrders();
      final sales = await ref.read(saleRepositoryProvider).getSales();
      final inventory = await ref
          .read(inventoryRepositoryProvider)
          .getInventory();
      final medicines = await ref
          .read(medicineRepositoryProvider)
          .getMedicines();
      return computeReports(
        orders: orders,
        sales: sales,
        inventory: inventory,
        medicinesById: {for (final m in medicines) m.id: m},
        branchId: branchId,
        now: DateTime.now(),
        days: days,
      );
    });
