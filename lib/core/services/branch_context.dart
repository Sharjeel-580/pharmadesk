import 'package:flutter_riverpod/flutter_riverpod.dart';

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
  ),
  Branch(
    id: 'branch-demo-gulberg',
    name: 'Demo Branch — Gulberg',
    address: 'Gulberg III, Lahore',
    phone: '0300-2222222',
    deliveryAreas: ['Gulberg I–V'],
  ),
];

/// Holds the branch the user is currently working in.
class ActiveBranchNotifier extends Notifier<Branch> {
  @override
  Branch build() => demoBranches.first;

  /// Switches the active branch. Unknown ids are ignored.
  void switchTo(String branchId) {
    for (final branch in demoBranches) {
      if (branch.id == branchId) {
        state = branch;
        return;
      }
    }
  }
}

final activeBranchProvider =
    NotifierProvider<ActiveBranchNotifier, Branch>(
      ActiveBranchNotifier.new,
    );
