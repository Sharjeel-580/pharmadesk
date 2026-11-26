# Day 24 — Week 5 Day 2 Progress (26 Nov 2026)

**Scope:** data-layer completion, part 2 — the three remaining Week 4
follow-ups: a real branch repository (D131), FR-HO-08 deactivation
enforcement on transactions (D-28), and restore into the live repos via
upsert-by-id (D133). All three are wiring moves: no new capability, no
screen redesign — the directory becomes durable, a deactivated branch
stops transacting, and a validated restore finally replaces live data
instead of landing in a sink only.

## What shipped

### 1. Firestore branch repository — D131 closed (D148)

- **Repository (`BranchRepository`, D73/D101/D118/D146 pattern):**
  `getBranches` / `getById` / `createBranch` / `updateBranch` /
  `saveBranch` — one upsert for add + edit + activate/deactivate
  (a re-save overwrites the same doc, never a duplicate, D65).
  Mock seeded from `demoBranches` (a mutable copy per instance);
  Firestore impl over the transport under the root collection
  `branches/{id}` (branches are org-wide, not branch-scoped). Joins
  the `RepositoryBundle` + provider like the Day 3 repos. The
  directory still owns validation (`validateBranchForm`), the
  last-active-branch protection and the `branch-<slug>` id minting
  (the form dialog builds the id; an empty id gets a minted one —
  `branch-<slug>` in the mock, a Firestore auto-id in the Firestore
  impl).
- **Mapper (`branchToFirestore` / `branchFromFirestore`):** writes
  `active` AND `status` (`active` / `closed`) and both rate names
  (`franchiseFeeRateBps` / `franchiseFeeRate`, `royaltyRateBps` /
  `royaltyRate`); the read side accepts either (`active` wins,
  `status: closed` reads inactive, §3 rate names read back). §3 lists
  a `code` the model has none of — the mapper writes no `code`, never
  an invented one (the repository helper derives `branchCode` from
  the doc when present, else from the branch id), and therefore does
  NOT `validateOrThrow` against the §3 `branches` list (which marks
  `code` required). Same lossy-mapping posture as the staff mapper
  (D99). `Branch.copyWith` gains an `id` parameter (every other
  model's `copyWith` already has one) so the notifier can pin the id
  on update.
- **Layer (`loadBranches` / `getBranch` / `saveBranch`, D146
  pattern):** the notifier reads through the layer; a save upserts
  the branch doc + enqueues one update sync payload. The repo is an
  optional constructor param with a fresh-mock default, so older
  direct constructions keep working untouched; the app provider
  passes the bundle's repo.
- **Notifier re-read:** `BranchDirectoryNotifier.build` starts
  `refresh()` and the mutating methods await that load first (D146
  pattern). `refresh()` merges persisted ∪ in-memory (persisted
  wins; an in-memory-only branch is kept). Persisting happens BEFORE
  the state updates. `addBranch` / `updateBranch` / `setActive` are
  `async` now (the two branch screens and the four Week 4 Day 4
  directory tests were updated to await them — the only intentional
  old-test changes this day besides the D150 round-trip updates).
  List (paged at 10, D107), detail view, last-active protection and
  deactivation-as-a-flag are unchanged.
- **Rules (`firebase/firestore.rules`):** the existing
  `/branches/{branchId}` block now also requires `hasCommonFields()`
  and a new `validBranchDoc()` — type in `own` / `franchise`,
  `active` a bool, rates when present ints in 0–10000 bps. No rule
  weakened; branch isolation intact (read still needs branch access
  or a head-office role).

### 2. FR-HO-08 deactivation enforcement — D149

- **Guard (`_requireBranchActive`, in the production data layer):**
  every transaction write path calls it before its first write —
  `commitSale`, `createOrder`, `receiveGoods` (purchases),
  `receiveStock`, `adjustStock`, `recordStockCount`,
  quarantine/un-quarantine (`_setBatchStatus`), `createTransfer`
  (both ends), `dispatchTransfer` (source), `receiveTransfer`
  (destination). A deactivated branch throws
  `ArgumentError('Branch "<name>" is deactivated and cannot transact
  (FR-HO-08) …')` — the same type the other layer guards throw (D68
  sellable-stock, D140 quarantine transitions), so the notifiers'
  existing `on ArgumentError` handlers surface it instead of
  crashing. Nothing is written, no stock or money moves, and the sync
  queue sees nothing.
- **Ordering:** the guard sits AFTER the idempotency-duplicate early
  return, so a retried key still returns its original result instead
  of an error for a branch deactivated since the commit (a retry is
  not a new transaction). Batch-keyed paths (`adjustStock` /
  `recordStockCount` / quarantine) read the branch off the batch row
  they already load — no extra lookup.
- **Boundary — unknown branch ids are NOT refused:** the directory is
  the source of truth for deactivation, and an id it never saw cannot
  be known-deactivated. That keeps older direct constructions (tests
  and flows that transact under ids outside the directory) working
  exactly as before. Filing an adjustment *request* is also
  unguarded — a request moves no stock; the approval apply goes
  through `adjustStock`, which is guarded. Finance writes
  (`recordExpense` / `recordIncome` / `recordSupplierPayment` /
  closings) are NOT guarded yet — they are money writes, not sales /
  purchases / stock movements; that is a follow-up, not smuggled in
  here.

### 3. Restore upserts by id into the live repos — D133 closed (D150)

- **Upsert methods (one per exported repo section):**
  `upsertMedicine` / `upsertOrder` / `upsertInventoryItem` /
  `upsertCustomer` + `upsertLedgerEntry` (khata) / `upsertSale` /
  `upsertSupplier` + `upsertLedgerEntry` (payables) /
  `upsertPrescription` / `upsertPurchaseOrder` / `upsertRider` —
  existing id → replaced in place, new id → inserted as given, empty
  id → minted like the repo's create. No uniqueness re-checks (a
  restore replays data that was valid when exported); ledger upserts
  keep `balanceAfterMinor` exactly as given (a restore replays
  history, it does not recompute it); sale / order / PO upserts keep
  the given invoice / PO number and status (unlike creates, which
  re-number / reset to Draft); inventory upsert writes the batch row
  only (the per-(branch, medicine) on-hand counter is rollup state
  and is not part of a backup). Firestore impls mirror the repo's own
  create/update (doc id = model id, items subcollections rewritten by
  index with trailing stale docs deleted, `createdAt` preserved on
  rewrite); branch-scoped upserts fall back to the first branch when
  the record carries no branch (customers are org-wide in the demo
  model).
- **Layer (`importBackup`, now `async`):** validation still runs
  BEFORE any write (a bad backup aborts with nothing written). Each
  repo section is then upserted by id through its repository;
  `auditLogs` / `syncQueue` are local state, not repo data, so they
  land in the restore sink only — as does every section, so
  `restoredData` stays the full record of the last restore. Unknown
  sections also land in the sink. A doc that fails to parse or upsert
  is recorded in `ImportReport.errors` and skipped; the rest still
  import. The report counts are measured against the LIVE repos
  (`created` = id absent from the live repo, `overwritten` /
  `skipped` = id present, by policy) — so importing an export of the
  live data itself creates nothing under skip policy and replaces
  everything under overwrite policy, without duplicating a document.
  The sink itself is NOT policy-gated: it records every validated doc
  of the restore, applied or skipped.
- **Exporter:** the `branches` section joins the export (2 docs) —
  the backup now covers every repository, and a restore reactivates a
  branch the live directory deactivated. `DataImporter` itself is
  unchanged (still imports into a sink with the same policy; its unit
  tests still pin that behaviour).
- **Screen:** the backup screen awaits the import and its
  confirmation copy now says the restore replaces the *live* data;
  the admin-only gate, explicit confirmation and post-restore report
  are unchanged.

## Verification

- `flutter analyze` — **No issues found!**
- Day 2 tests (`test/week5_day02_test.dart`) — **31/31 passed**
  (branch repo mock 6, Firestore mapper + repo 4, directory notifier
  4 incl. the D107 paging widget test, FR-HO-08 enforcement 9,
  restore upsert-by-id 8)
- Cumulative full suite — **758/758 passed** (727 baseline + 31 new)
- Fresh `flutter build web --release` — **✓ Built build/web**
  (46,661,326 bytes)
- Prescription PNGs — both in
  `build/web/assets/assets/images/prescriptions/` at **114,613 +
  110,613 bytes**.

## Files changed

- New: `test/week5_day02_test.dart`, `docs/day-24-progress.md`
- Modified: `lib/core/data/firestore_mappers.dart` (branch mapper
  pair), `lib/core/services/repositories.dart` (branch repo interface
  + mock + provider; upsert methods on 9 interfaces + 2 ledger
  upserts and all mocks), `lib/core/data/firestore_repositories.dart`
  (Firestore branch repo + Firestore upserts),
  `lib/core/data/repository_factory.dart` (bundle `branches` field),
  `lib/core/data/production_data_layer.dart` (`branchRepo` param,
  `_requireBranchActive` + guards in 10 methods, `loadBranches` /
  `getBranch` / `saveBranch`, async live-restore `importBackup`,
  exporter passes `branches`), `lib/core/data/backup_export.dart`
  (`branches` section), `lib/models/branch.dart` (`copyWith` gains
  `id`), `lib/features/branches/branch_directory.dart` (async
  persist-through-layer notifier), `lib/features/branches/branch_list_screen.dart`
  + `branch_detail_screen.dart` (await), `lib/features/backup/backup_screen.dart`
  (await + new confirmation copy), `firebase/firestore.rules`
  (`validBranchDoc()` + strengthened branch rule),
  `test/week2_day01_test.dart`, `test/week4_day04_test.dart`
  (round-trip tests rewritten to the D150 semantics; directory tests
  await the async notifier; confirmation-dialog text updated),
  `test/day_05_test.dart`, `test/day_06_test.dart`,
  `test/week2_day02_test.dart`, `test/week3_day05_test.dart` (fake
  inventory repos gain `upsertInventoryItem`),
  `docs/technical-decisions.md` (D148, D149, D150),
  `docs/week-5-tracker.md` (Day 24)

## Follow-ups (Week 5)

- **`ActiveBranchNotifier.switchTo` still reads only `demoBranches`**
  — a branch added via the directory cannot become the active
  branch. Wiring it to the directory would create a provider cycle;
  needs a deliberate design decision.
- **Finance writes are NOT FR-HO-08-guarded** (`recordExpense` /
  `recordIncome` / `recordSupplierPayment` / closings) — documented
  D149 boundary. `recordSupplierPayment`'s branch scoping is an open
  question alongside it.
- **Restore does not delete:** a record deleted from live data after
  export is NOT removed by re-import (upsert only); counters are not
  restored (rollup state, not in backups); the sale payments
  subcollection is not restored (not in the backup); the Firestore
  sale doc id is the exported id, which for mock exports differs from
  the idempotency key (cross-backend restore edge).
- **Model gaps found while wiring:** `Supplier` has no `createdAt`;
  `Order` has no `orderNumber` / `idempotencyKey` field (the repo
  mints the number); the `Branch` mapper cannot validate against the
  §3 `branches` list (`code` required, model has none).
- Carried from Day 23: notifier-held idempotency keys for payments
  (double-tap still creates two payments); per-branch rack/shelf
  override (D138), full medicine master edit form (D138), quarantine
  return/disposal approval (D140), POS wiring for the Settings config
  (D134/D136), franchise commission/royalty tracking.
