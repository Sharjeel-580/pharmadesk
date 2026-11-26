# Day 19 — Week 4 Day 2 Progress (26 Nov 2026)

**Scope:** the two missing operations screens from the Week 3 Day 4
audit — D-16 Stock Transfer and D-21 Riders & Delivery (Week 4
brief §2). Full lifecycle for transfers (request → approve →
dispatch → receive, plus reject/cancel) with real FEFO stock
movement, and a rider list + detail with assignment through the one
existing assignment write path.

## What shipped

### 1. Stock Transfer model + repositories (D118, D120)

- New `lib/models/stock_transfer.dart`: `StockTransfer` (id,
  transfer number, from/to branch, status, embedded `items`,
  note, requested/approved/dispatched/received-by stamps, FEFO
  `dispatchAllocations`, `isDemo`), `TransferItem`,
  `TransferAllocation`, `StockTransferStatus` (Requested →
  Approved → Dispatched → Received, plus Rejected/Cancelled).
- New `StockTransferRepository` interface + `MockStockTransferRepository`
  (mutable, seeded from `demoTransfers`; branch-scoped reads return
  transfers where the branch is the source OR the destination) +
  `FirestoreStockTransferRepository` (doc under the source branch,
  `branches/{fromBranchId}/stockTransfers/{id}`; transfer number
  from the per-branch counter, `TR-{from}-{to}-{seq}`; D65
  caller-id pattern; destination-branch reads scan the org's
  branches and filter). Both join the `RepositoryBundle` (D101
  pattern) with a `stockTransferRepositoryProvider`.
- Schema (`firestore_schema.dart`, D120): the `stockTransfers`
  contract gains `transferNumber`, `items` (embedded lines),
  `note`, `dispatchedBy` / `receivedBy`, `dispatchAllocations`
  and `isDemo` — and the status list gains `rejected`, which the
  SRS contract omitted even though approval implies it. Path
  helpers `stockTransfersPath` / `stockTransferDocPath` added.
  Mappers in `firestore_mappers.dart` round-trip the model
  (validated against the contract — pinned by test).

### 2. Transfer lifecycle through the production data layer (D118)

- `ProductionDataLayer` gains `createTransfer`,
  `approveTransfer`, `rejectTransfer`, `cancelTransfer`,
  `dispatchTransfer`, `receiveTransfer` (all single write paths,
  same pattern as `receiveGoods` / `receiveStock` / D111/D114):
  - **Create** validates (branches differ, every line a real
    medicine with a positive quantity — canonical medicine names
    from the repo) and moves no stock. The idempotency key IS the
    transfer id, so a retried create returns the original.
  - **Approve** enforces approval separation (SRS §5.2 rule 4):
    the requester cannot approve their own transfer. Demo
    accounts have distinct uids (`demo-owner`,
    `demo-branch_manager`, …), so the rule works in the demo.
  - **Dispatch** reserves FEFO batches per line from live source
    stock (a short line throws and releases every hold — nothing
    partially dispatches), then `InventoryEngine.transferOut`
    (new — mirrors `confirm` but books `transfer_out` movements)
    plus the repository decrements the same batches. The FEFO
    allocations (batch no, mfg/expiry, unit cost) are recorded on
    the transfer, so the receive never guesses which batch the
    units left in.
  - **Receive** creates one destination batch per allocation
    (same batch number, mfg/expiry, unit cost), booked by
    `InventoryEngine.transferIn` (new — mirrors `receive` but
    books `transfer_in` movements). Engine load order follows
    the D111 rule (load before the repo create, or the new batch
    counts twice).
  - **Idempotency:** separate registries per step (create /
    dispatch / receive) — a same-key retry returns the original
    and moves no stock twice (pinned by tests, incl. the
    dispatch/receive double-move counts).
  - **Sync:** every step enqueues one batched-write payload
    (transfer doc + stock transactions + inventory updates, +
    new batch docs on receive), so the Day 3 sync-status chip
    moves for transfer work.
- Capability: new `stockTransfer` row in the §5.1 matrix
  (Owner / HO Admin / Regional Mgr allowed, Branch Mgr +
  Inventory Mgr own, Auditor read-only, everyone else none) and
  `'/inventory/transfers': 'stockTransfer'` in `routeCapability`
  — the route is gated, the `/inventory` screen itself stays open
  (same posture as `/inventory` vs `stockAdjustApprove`).

### 3. Transfer screens

- `stock_transfer_list_screen.dart` (`/inventory/transfers`):
  status filter chips + branch filter (both directions),
  `PagedList` at 10 (D107), `SyncStatusChip`, Demo badges on
  seeded rows, "New Transfer" button only for
  `stockTransfer` writers.
- `stock_transfer_form_screen.dart` (`/inventory/transfers/new`):
  source/destination branch pickers (source defaults to the
  active branch), medicine picker showing the source branch's
  **sellable** on-hand per medicine (expired/quarantined excluded
  — the Day 5 guard dispatch uses), quantities, note. A request
  moves no stock; over-requesting is allowed here and fails
  clearly at dispatch. One dialog-held idempotency key across
  retries (D115 pattern).
- `stock_transfer_detail_screen.dart`
  (`/inventory/transfers/:id`): lines, FEFO dispatch
  allocations once dispatched, actor trail, and the lifecycle
  actions for the current status — each rendered only when the
  role may do it and only in the status that allows it, with
  dialog-held keys for dispatch/receive and the layer's reason
  shown on a failed move.
- Seeded demo transfers (D118, labelled demo/sample on sight):
  `TR-DHA-GLB-1001` Requested, `TR-GLB-DHA-1002` Dispatched
  (with allocations), `TR-DHA-GLB-1003` Received (with
  allocations). **Seeded transfers are read-only sample records
  (D122)** — dispatching/receiving one would move real stock
  under a sample record's name, so their action buttons are
  hidden; the full lifecycle runs on transfers the user creates.
  Their stock effects are NOT retro-applied to the generated
  demo inventory — the same posture as the seeded sales/orders,
  whose stock effects the generated inventory also never
  reflects.

### 4. Riders & Delivery (D119, D121)

- **Model decision (D119): riders stay a separate model.** The
  SRS and the seed already have one (`lib/models/rider.dart`,
  `branches/{branchId}/riders`), with vehicle + live-order
  fields Staff does not carry. Riders are NOT Staff rows with a
  rider role. Week 4 Day 2 adds only `branchId` (home branch —
  riders 1–2 DHA, 3–4 Gulberg) + `copyWith` to the model, and the
  mapper reads/writes it (extra field, D99 posture).
- **One assignment write path (D121):**
  `ProductionDataLayer.assignRider` — the Order Detail "Assign
  rider" button, the order form's rider picker (which saves
  through `updateOrder` — unchanged) and the Rider Detail
  "Assign order" action all end here. It writes the order's
  `riderId` AND both rider rows together (previous rider's
  `currentOrderId` cleared, new rider's set), plus audit + one
  sync payload — so the rider list's "On delivery" state can
  never disagree with the order queue. Guards: order must be an
  editable delivery order; rider must exist, be active, belong
  to the order's branch, and not already be out on another order.
  `RiderRepository` gains `updateRider` (mock mutable +
  Firestore implementation) because assignment is the first
  rider write.
- `rider_list_screen.dart` (`/riders`): name, phone, vehicle,
  home branch, availability (Available / On delivery / Inactive
  — derived from `active` + `currentOrderId`, the single source
  of truth), live order when assigned; branch + availability
  filters, `PagedList` at 10, Demo badges.
- `rider_detail_screen.dart` (`/riders/:id`): contact/vehicle/
  branch/availability, current delivery (with a link to the
  order), assigned-order history newest first (paged at 10), and
  — for an available rider with a home branch — the delivery
  orders in his branch with no rider yet, each with an Assign
  button.
- `OrderDetailScreen` gains an "Assign Rider" / "Change Rider"
  button (delivery orders only, while editable) opening a rider
  picker dialog (active riders in the branch; busy riders shown
  disabled) that saves via `OrderQueueNotifier.assignRider`.
- **No rider capability (D123):** the SRS §5.1 matrix has no
  rider-management row, so none was invented. Rider routes are
  NOT capability-gated; the screens follow the Orders module for
  navigation, and assignment itself is guarded by the order's
  editability + the rider's availability.

### 5. Routes + navigation

- New routes (all behind `FeatureGate`): `/inventory/transfers`,
  `/inventory/transfers/new`, `/inventory/transfers/:id`,
  `/riders`, `/riders/:id`. Transfers follow the Inventory
  module toggle + `stockTransfer` capability; riders follow the
  Orders module for navigation.
- Sidebar: "Stock Transfers" under Inventory (only for users
  who may use transfers in the active branch) and "Riders &
  Delivery" under Orders. Mobile More sheet: the same two
  entries (`_showMoreSheet` gains a `canViewTransferRecords`
  parameter).
- Route-walk coverage: the Week 3 Day 5 walk covered every
  route then; the five new routes are walked by the Day 2 tests
  (list / new / detail × transfer + list / detail × rider), so
  every route in the router is still walked by at least one test.

### 6. Older tests updated for the new reality (not regressions)

- `test/day_07_test.dart`: the roles-matrix test counts
  capabilities — 23 → **24** (`stockTransfer` added). The
  Auditor check (read-only or none everywhere) still holds.
- `test/week3_day04_test.dart`: the "seven missing desktop
  screens have no route" test — D-16 (`/inventory/transfers`)
  and D-21 (`/riders`) now resolve, so the test is now "the
  remaining missing desktop screens have no route" (D-24 /
  D-28 / D-33 / D-35). Its header comment is updated the same
  way.

## Verification

- `flutter analyze`: **clean — no issues**.
- Day tests `test/week4_day02_test.dart`: **27/27** — transfer
  lifecycle (request + validation + duplicate-key + status
  order + approval separation + FEFO dispatch + short-stock
  rollback + dispatch/receive idempotency + seeded coverage),
  rider assignment (assign + reassign + unassign + all six
  guards), gates + validation (matrix row, per-role
  view/write incl. the `own`-scope branch check, request
  validator, rider availability, mapper round-trip), Firestore
  repos on the fake transport (transfer numbering + both-direction
  reads + update; rider `updateRider`), and 7 widget tests
  (route walk, seeded demo rendering, sample read-only detail,
  Pharmacist gate, sidebar entries, form end to end, order-detail
  assign end to end).
- Full suite: **581/581** (554 + 27 new, no earlier test touched
  except the two intentional updates above).
- Fresh `flutter build web --release`: **pass** (186.7s,
  46,472,274 bytes); prescription PNGs bundled at **114,613 +
  110,613 bytes**, 8 "prescription" mentions in
  `AssetManifest.bin`, both paths present.

## Decisions

- D118 — Stock transfer lifecycle design (layer + engine +
  FEFO allocations + per-step idempotency + approval
  separation). See `docs/technical-decisions.md`.
- D119 — Riders stay a separate model (not Staff-with-rider-role).
- D120 — Schema extensions for transfers (`rejected`, embedded
  items/allocations, actor stamps, `isDemo`) + rider `branchId`.
- D121 — One rider-assignment write path (`layer.assignRider`).
- D122 — Seeded transfers are read-only sample records; their
  stock effects are not retro-applied.
- D123 — No rider capability invented (SRS has no rider row);
  rider routes follow the Orders module.

## Files changed

- New: `lib/models/stock_transfer.dart`,
  `lib/features/inventory/transfer_logic.dart`,
  `lib/features/inventory/transfer_provider.dart`,
  `lib/features/inventory/stock_transfer_list_screen.dart`,
  `lib/features/inventory/stock_transfer_form_screen.dart`,
  `lib/features/inventory/stock_transfer_detail_screen.dart`,
  `lib/features/riders/rider_logic.dart`,
  `lib/features/riders/rider_provider.dart`,
  `lib/features/riders/rider_list_screen.dart`,
  `lib/features/riders/rider_detail_screen.dart`,
  `test/week4_day02_test.dart`.
- Edited: `lib/models/rider.dart` (+`branchId`, `copyWith`),
  `lib/models/models.dart` (export), `lib/core/services/demo_seed_data.dart`
  (rider branches + `demoTransfers`), `lib/core/services/repositories.dart`
  (transfer repo + `updateRider` + provider), `lib/core/data/repository_factory.dart`
  (bundle field), `lib/core/data/firestore_schema.dart` (contract +
  paths), `lib/core/data/firestore_mappers.dart` (transfer mappers +
  rider branch), `lib/core/data/firestore_repositories.dart`
  (Firestore transfer repo + rider update), `lib/core/data/inventory_engine.dart`
  (`transferOut` / `transferIn`), `lib/core/data/production_data_layer.dart`
  (transfer lifecycle + `assignRider`), `lib/features/settings/roles_permissions.dart`
  (`stockTransfer` row), `lib/core/data/permission_service.dart`
  (route capability), `lib/core/routing/app_router.dart` (5 routes),
  `lib/app/shell/app_shell.dart` (sidebar + More sheet),
  `lib/features/orders/orders_provider.dart` (`assignRider`),
  `lib/features/orders/order_detail_screen.dart` (assign button +
  dialog), `test/day_07_test.dart` (24 capabilities),
  `test/week3_day04_test.dart` (remaining-missing test).
- No new dependencies.

## Follow-ups (not in this day)

- **Seeded-order rider/branch mismatch (pre-existing):** the
  seeded-order generator assigns riders 1–3 to out-for-delivery
  / delivered orders regardless of branch, so a DHA order can
  reference Gulberg rider-3. New assignments enforce the branch
  (D121); the seeded rows are untouched sample data. Worth a
  seed fix on a later QA pass, not smuggled into this day.
- **Rider create/edit:** there is no rider add/edit screen — the
  SRS names rider list/assignment/delivery status only, and none
  was invented. If Hadi asks for rider onboarding, that is a
  Day 5 / Week 5 addition.
- **Transfer partial dispatch:** dispatch is all-or-nothing per
  transfer (a short line fails the whole dispatch with a clear
  error). Partial dispatch / split quantities were not in the
  brief and were not invented.
- **390px body findings (Day 5 sweep, unchanged):** `/orders`
  12px, `/billing` 133px, `/inventory` batch-row overflows —
  still open for the Day 5 sweep, not touched here.
