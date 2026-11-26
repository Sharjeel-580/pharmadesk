import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/branches/branch_directory.dart';
import '../../models/branch.dart';

/// Active-branch context for the app shell.
///
/// Demo data only (SRS §8): two fictional branches, "Demo Branch — DHA"
/// and "Demo Branch — Gulberg". The first branch reuses the id
/// `branch-dha-main` so it lines up with the Day 1 mock repositories'
/// sample orders/inventory. No backend is involved: switching branches
/// only changes which branch the UI (and later the mock repos) treats as
/// active. Week 2 replaces this with the Firestore-backed branch list.
const demoBranches = <Branch>[
  Branch(
    id: 'branch-dha-main',
    name: 'Demo Branch — DHA',
    address: 'DHA Phase 2, Lahore',
    phone: '0300-1111111',
    deliveryAreas: ['DHA Phase 1–5'],
    code: 'DHA',
  ),
  Branch(
    id: 'branch-demo-gulberg',
    name: 'Demo Branch — Gulberg',
    address: 'Gulberg III, Lahore',
    phone: '0300-2222222',
    deliveryAreas: ['Gulberg I–V'],
    code: 'GLB',
  ),
];

/// Holds the branch the user is currently working in.
///
/// Resolution (Week 6 Day 3, D163): [switchTo] resolves the id
/// against the branch directory first — the directory seeds from
/// [demoBranches] and holds every branch added through Branch
/// Management — and falls back to [demoBranches] for containers in
/// which the directory provider is overridden without them. The
/// lookup is a one-shot [Ref.read] inside [switchTo], never a
/// [Ref.watch] in [build]: watching the directory from `build()`
/// would rebuild this notifier (and reset the active branch to the
/// first demo branch) on every directory change, and would put a
/// build-time edge between the two providers. A directory-added
/// branch therefore becomes active exactly like a demo branch, and
/// adding/editing a branch afterwards never resets the active one.
class ActiveBranchNotifier extends Notifier<Branch> {
  @override
  Branch build() => demoBranches.first;

  /// Switches the active branch. Returns `true` when [branchId]
  /// resolved to a known branch and became active, `false` when it
  /// is unknown to the directory and the demo list — in that case
  /// the active branch is left unchanged (previously the unknown
  /// id was ignored silently; the return value makes the outcome
  /// explicit without throwing, so existing callers that ignore
  /// it keep working).
  ///
  /// A deactivated branch CAN become active: FR-HO-08 guards
  /// transactions on a deactivated branch (D149/D161), not viewing
  /// it — its history stays readable, same as the franchise view
  /// (D158).
  bool switchTo(String branchId) {
    for (final branch in _knownBranches) {
      if (branch.id == branchId) {
        state = branch;
        return true;
      }
    }
    return false;
  }

  /// Branches [switchTo] can resolve, directory first (it holds the
  /// demo branches too), demo list as fallback for ids the directory
  /// has never seen.
  Iterable<Branch> get _knownBranches sync* {
    final seen = <String>{};
    for (final branch in ref.read(branchDirectoryProvider)) {
      if (seen.add(branch.id)) yield branch;
    }
    for (final branch in demoBranches) {
      if (seen.add(branch.id)) yield branch;
    }
  }
}

final activeBranchProvider =
    NotifierProvider<ActiveBranchNotifier, Branch>(
      ActiveBranchNotifier.new,
    );
