import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/data/auth_repository.dart';
import '../../core/services/repositories.dart';
import '../../models/salary_record.dart';
import 'salary_logic.dart';

/// Week 3 Day 2 salary state.
///
/// [SalaryNotifier] owns the in-memory salary-record list; it loads
/// from the (mock) repository once. The screen was display-only
/// until Week 3 Day 4 (D112), when the edit flow landed:
/// [saveRecord] writes through `saveSalaryRecord`, gated on the
/// SRS §5.1 `hrSalary` capability via [canManageSalary]. Salary
/// figures live in these records, not on the Staff model (D102).

class SalaryNotifier extends AsyncNotifier<List<SalaryRecord>> {
  @override
  Future<List<SalaryRecord>> build() async {
    final repo = ref.read(salaryRepositoryProvider);
    return repo.getSalaryRecords();
  }

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(
      () => ref.read(salaryRepositoryProvider).getSalaryRecords(),
    );
  }

  /// Saves (creates or replaces) one salary record for one employee
  /// and month. Returns the saved record, or `null` + an error
  /// message when the permission, validation or repository forbids
  /// it — the same (record, error) shape as the returns notifier.
  ///
  /// The gate is [canManageSalary] (`hrSalary` write: Owner / HO
  /// Admin / Accountant in-branch; Auditor is read-only and may
  /// not save, Branch Manager may not even see the screen). The
  /// record is validated with [validateSalaryRecord] before the
  /// repository sees it; the repository re-checks the same rules.
  Future<({SalaryRecord? record, String? error})> saveRecord({
    required SalaryRecord record,
    required AppUser? user,
  }) async {
    if (!canManageSalary(user, record.branchId)) {
      return (
        record: null,
        error:
            'Salary records need the "HR: salary records" permission '
            'in this branch — ask the owner, HO Admin or Accountant.',
      );
    }
    final errors = validateSalaryRecord(record);
    if (errors.isNotEmpty) {
      return (record: null, error: errors.first);
    }
    try {
      final saved = await ref
          .read(salaryRepositoryProvider)
          .saveSalaryRecord(record);
      await refresh();
      return (record: saved, error: null);
    } on ArgumentError catch (error) {
      return (record: null, error: error.message?.toString());
    }
  }
}

final salaryProvider =
    AsyncNotifierProvider<SalaryNotifier, List<SalaryRecord>>(
      SalaryNotifier.new,
    );
