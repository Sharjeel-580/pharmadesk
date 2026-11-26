import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/data/auth_repository.dart';
import '../../core/data/permission_service.dart';
import '../../core/data/production_data_layer.dart';
import '../../core/services/branch_context.dart';
import '../../models/branch.dart';

/// Branch management logic (Week 4 Day 4, D130/D131 — SRS D-28,
/// FR-HO-01/02/08; persisted Week 5 Day 2, D148).
///
/// The demo branches live as the `demoBranches` const in
/// `branch_context.dart` and seed the branch repository (mock now,
/// Firestore when the bundle switches). The directory reads and
/// writes through the production data layer ([loadBranches] /
/// [saveBranch], D146 pattern): add / edit / activate / deactivate
/// persist before the state updates, so a branch survives a
/// notifier rebuild and an app restart. Switching the active branch
/// still goes through `activeBranchProvider` (the shell's branch
/// switcher), so the directory never owns two sources of "current
/// branch".

/// True when [user] may view branch management in [branchId]
/// (SRS §5.1 `branches`: Super Admin / Owner / HO Admin, Auditor
/// read-only — everyone else none).
bool canViewBranches(AppUser? user, String branchId) =>
    permissionService.canInBranch(user, 'branches', branchId);

/// True when [user] may change a branch in [branchId] (add / edit /
/// activate / deactivate — `readOnly` is false here, so the Auditor
/// sees the screens but no action buttons).
bool canWriteBranches(AppUser? user, String branchId) =>
    permissionService.canWrite(user, 'branches', branchId);

/// Validation for the add/edit branch form. Returns the problems
/// found; empty = the form is valid. A rate is valid when it is
/// absent (not configured) or 0–10000 basis points (0–100%).
List<String> validateBranchForm({
  required String name,
  int? franchiseFeeRateBps,
  int? royaltyRateBps,
}) {
  final errors = <String>[];
  if (name.trim().isEmpty) errors.add('Branch name is required.');
  for (final (label, rate) in [
    ('Franchise fee rate', franchiseFeeRateBps),
    ('Royalty rate', royaltyRateBps),
  ]) {
    if (rate != null && (rate < 0 || rate > 10000)) {
      errors.add('$label must be between 0% and 100%.');
    }
  }
  return errors;
}

/// The branch directory: the demo branches plus any added this
/// session, in display order.
class BranchDirectoryNotifier extends Notifier<List<Branch>> {
  /// The in-flight initial load, started by [build]: mutating
  /// methods await it before validating or minting, so they always
  /// see the persisted directory first (D146 pattern).
  Future<void>? _loadFuture;

  @override
  List<Branch> build() {
    _loadFuture = refresh();
    return List<Branch>.of(demoBranches);
  }

  Future<void> _ensureLoaded() => _loadFuture ?? Future.value();

  /// Re-reads the persisted branches from the layer and merges them
  /// into the state. Persisted branches win; an in-memory branch
  /// the store has not seen yet (a persist that failed mid-write)
  /// is kept, and the next write repairs the store.
  Future<void> refresh() async {
    final persisted = await ref
        .read(productionDataLayerProvider)
        .loadBranches();
    final mergedById = <String, Branch>{
      for (final branch in persisted) branch.id: branch,
    };
    for (final current in state) {
      mergedById.putIfAbsent(current.id, () => current);
    }
    state = mergedById.values.toList();
  }

  Branch? byId(String branchId) {
    for (final branch in state) {
      if (branch.id == branchId) return branch;
    }
    return null;
  }

  /// Adds a branch. Returns the problems found; empty = added.
  /// Ids are `branch-<slug>` from the name; a clash with an existing
  /// id is refused rather than overwriting. The branch is persisted
  /// through the layer BEFORE the state updates.
  Future<List<String>> addBranch(Branch branch) async {
    await _ensureLoaded();
    final errors = validateBranchForm(
      name: branch.name,
      franchiseFeeRateBps: branch.franchiseFeeRateBps,
      royaltyRateBps: branch.royaltyRateBps,
    );
    if (byId(branch.id) != null) {
      errors.add('A branch with this id already exists.');
    }
    if (errors.isNotEmpty) return errors;
    final saved = await ref
        .read(productionDataLayerProvider)
        .saveBranch(branch);
    state = [...state, saved];
    return const [];
  }

  /// Replaces the branch with [branchId] by [updated]. Returns the
  /// problems found; empty = updated. The id itself never changes.
  /// The change is persisted through the layer BEFORE the state
  /// updates.
  Future<List<String>> updateBranch(String branchId, Branch updated) async {
    await _ensureLoaded();
    final errors = validateBranchForm(
      name: updated.name,
      franchiseFeeRateBps: updated.franchiseFeeRateBps,
      royaltyRateBps: updated.royaltyRateBps,
    );
    if (byId(branchId) == null) errors.add('Branch not found.');
    if (errors.isNotEmpty) return errors;
    final saved = await ref
        .read(productionDataLayerProvider)
        .saveBranch(updated.copyWith(id: branchId));
    state = [
      for (final branch in state)
        if (branch.id == branchId) saved else branch,
    ];
    return const [];
  }

  /// Activates / deactivates a branch (SRS FR-HO-08: a deactivated
  /// branch cannot transact but its history is preserved — the flag
  /// is the record, and the production data layer enforces it on
  /// every transaction write path, D149). The last active branch
  /// cannot be deactivated: the app always needs one branch to work
  /// in. Returns the problems found.
  Future<List<String>> setActive(String branchId, bool active) async {
    await _ensureLoaded();
    final branch = byId(branchId);
    if (branch == null) return const ['Branch not found.'];
    if (!active &&
        state.where((b) => b.active).length <= 1 &&
        branch.active) {
      return const ['The last active branch cannot be deactivated.'];
    }
    return updateBranch(branchId, branch.copyWith(active: active));
  }
}

final branchDirectoryProvider =
    NotifierProvider<BranchDirectoryNotifier, List<Branch>>(
      BranchDirectoryNotifier.new,
    );

/// Display label for a franchise/royalty rate in basis points, or
/// "Not set" when the rate was never configured (D130 — a missing
/// rate is shown as missing, never as 0%).
String branchRateLabel(int? rateBps) {
  if (rateBps == null) return 'Not set';
  final whole = rateBps ~/ 100;
  final frac = rateBps % 100;
  return frac == 0 ? '$whole%' : '$whole.${frac.toString().padLeft(2, '0')}%';
}
