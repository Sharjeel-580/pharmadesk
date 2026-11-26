# Day 33 — Week 7 Day 1 Progress (26 Nov 2026)

**Scope:** brief §1 — persist the quarantine outcome queue
(D154 follow-up, D141 posture carried). The queue was
session-only while the outcome itself IS persisted on the batch
row; a restart lost pending return / disposal requests. This day
persists the queue the same way the adjustment queue was
persisted in Week 5 (D146, `branches/{branchId}/...`).
A wiring move: no computation, no screen redesign, no new
capability — the queue becomes durable and the outcome stays
exactly-once.

## What shipped

### 1. Quarantine-outcome-queue persistence — D154 closed (D171)

- **Collection contract (`firestore_schema.dart`):**
  `branches/{branchId}/quarantineOutcomes/{id}` — new collection,
  not in the SRS §3 list (the SRS names the approval flow but
  gives it no collection). Doc id = request id (`qo-N`, also the
  idempotency key for the approval apply). Fields: batch /
  medicine (denormalized, as before), `outcome`
  (returnToSupplier / dispose), `reason`, `quantityAtRequest`,
  requester + `requestedAt`, `status` (pending / approved /
  rejected), decision stamps + `decisionNote`. Path builders
  `quarantineOutcomesPath` / `quarantineOutcomeDocPath`.
- **Repository (`QuarantineOutcomeRequestRepository`, D73/D118
  pattern):** `getRequests` / `getById` / `saveRequest` — one
  upsert for filing AND deciding (a re-save overwrites the same
  doc, never a duplicate, D65). Mock starts empty (requests only
  arise from filing); Firestore impl over the transport
  (`createdAt` preserved on rewrite, branch fan-out on
  null-branch reads). Joins the `RepositoryBundle` + provider
  like the adjustment queue. The model already had `toMap` /
  `fromMap` (D154) — no model change was needed — and the
  mappers round-trip through them.
- **Rules (`firebase/firestore.rules`):** new
  `quarantineOutcomes` block mirroring the stockAdjustments
  rule — read in-branch; create/update for the requester ∪
  approver roles (Owner / HO Admin / Branch Mgr / Inventory
  Mgr); `outcome` in returnToSupplier / dispose;
  `quantityAtRequest` an int; `status` in pending / approved /
  rejected; never deleted. Branch isolation intact — no rule
  weakened.
- **Layer (`fileQuarantineOutcomeRequest` /
  `loadQuarantineOutcomeRequests` /
  `updateQuarantineOutcomeRequest`, D103/D111 pattern):** filing
  persists the request + enqueues one sync payload (the request
  doc); the registry is keyed by request id, and a re-file first
  checks the store (`getById`) so a fresh layer instance (e.g.
  after an app restart) dedupes instead of writing a second doc
  or payload. Decisions persist via
  `updateQuarantineOutcomeRequest` (one update payload). The repo
  is an optional constructor param with a fresh-mock default, so
  older direct constructions keep working untouched.
- **Notifier re-read:** `build()` starts `refresh()` and the
  mutating methods await that load first, so ids are minted past
  the persisted sequence and decisions never act on a stale empty
  state. `refresh()` merges persisted ∪ in-memory (persisted
  wins, except an in-memory decided copy over a still-pending
  persisted one — the interleave where the decision persist
  failed; the next decision write repairs it). Filing persists
  BEFORE the state updates; approve/reject persist the decision
  BEFORE the state updates.
- **`requestOutcome` / `rejectOutcome` are `async` now:** the
  Return / Dispose dialog (`_save` awaits, with a `mounted`
  guard before the `pop` — the one analyze finding on the first
  pass), the queue screen (`_reject` awaits) and the three
  old-test call sites were updated to await them — the only
  intentional old-test changes this day
  (`test/week5_day04_test.dart`, `test/week5_day05_test.dart`,
  `test/week6_day05_test.dart`, `await` only, no flow change).

### 2. Outcome exactly once — the D146 gap, closed here (D171)

- The D146 adjustment queue relies on the layer registry for
  same-instance dedupe, and a restart empties that registry.
  For quarantine outcomes the batch row itself is the dedupe
  signal: `applyQuarantineOutcome` now returns the batch
  without moving stock, writing audit or enqueuing sync when
  the batch is already in the outcome's target status — placed
  BEFORE the FR-HO-08 guard, like the registry return
  (D149/D161 ordering — a retry is not a new transaction).
- A retry with a mismatched outcome (batch disposed, a return
  requested) still throws, and an outcome on a
  never-quarantined batch still throws — the replay only fires
  when the batch row already shows the requested outcome.
- The lost-decision window (outcome landed, decision persist
  failed, approver retries after a restart) replays as a
  duplicate and then persists the decision: the outcome lands
  on the batch row exactly once. Pinned by test at both levels
  (layer replay across fresh instances; notifier approve after
  an out-of-band apply + restart — one audit entry, one sync
  payload on the restarted layer, the decision payload).
- Approve now enqueues 3 payloads (file + apply + decision)
  where D154 enqueued 1 (apply only) — pinned by test, not a
  regression (the same counting change D146 made for
  adjustments).

### 3. Deactivation guard — unchanged, pinned (FR-HO-08, D149/D161)

- The approval apply goes through `applyQuarantineOutcome`,
  which is guarded: approving on a deactivated branch returns
  `null`, the request stays pending and the batch stays
  quarantined; reactivating lets the same approval through,
  exactly once (one audit entry).
- Filing a request is NOT guarded (D149 posture — a request
  moves no stock; it waits pending until the branch is active
  again). Unknown branch ids are NOT refused (D149 posture,
  unchanged).

## What broke while building (and the fix)

- **Restart test: swapped auth on an unread notifier:**
  the full-restart test creates a second container whose auth
  notifier is never read before the test swaps the user to the
  Owner — writing `state` on an uninitialized notifier throws
  ("Tried to use a notifier in an uninitialized state"). The
  test harness now reads `authProvider` once when the container
  is built, so the notifier exists before any mid-test swap.
  This is a test-harness property, not an app defect: a
  watching screen reads auth on build.
- **One analyze finding on the first pass:**
  `use_build_context_synchronously` in the dialog's `_save`
  (now async) — a `mounted` guard before the `setState` on the
  null-request path and before the `pop`. Fixed; analyze clean.
- **One analyze warning on the second pass:** an unused
  `_FixedAuthNotifier` in the new day test (only the mutable
  one is used) — removed. Analyze clean.
- **First full-suite run stalled, then the service restarted:**
  the run produced no test output for ~19 min (both the
  flutter_tools process and the frontend server idle on futex)
  and was killed; a service restart then wiped `/tmp` (the log
  file with it — the re-run logs to `~/workspace/` instead).
  No test failure was observed before the stall; the re-run is
  the verification below.

## Verification

- `flutter analyze` — **No issues found!**
- Day 1 tests (`test/week7_day01_test.dart`) — **20/20 passed**
  (schema + mapper 3, layer queue persistence 5, outcome
  exactly once 3, notifier re-read + restart 5, deactivated-branch
  refusal 4)
- Cumulative full suite — **1028/1028 passed** (1008 baseline + 20
  new; first run stalled pre-test with no output for ~19 min and
  was killed, then a service restart wiped `/tmp` — the re-run
  logged to `~/workspace/` and completed green in 14.5 min)
- Fresh `flutter build web --release` — **✓ Built build/web**
  (305.9s compile, 46,742,607 bytes)
- Prescription PNGs — both in
  `build/web/assets/assets/images/prescriptions/` at **114,613 +
  110,613 bytes**, 8 "prescription" mentions in
  `AssetManifest.bin`, both sample paths present.

## Files changed

- New: `test/week7_day01_test.dart`,
  `docs/day-33-progress.md`, `docs/week-7-tracker.md`
- Modified: `lib/core/data/firestore_schema.dart` (collection + paths +
  contract), `lib/core/data/firestore_mappers.dart` (mapper pair),
  `lib/core/services/repositories.dart` (interface + mock +
  provider), `lib/core/data/firestore_repositories.dart`
  (Firestore impl), `lib/core/data/repository_factory.dart`
  (bundle), `lib/core/data/production_data_layer.dart`
  (`file/load/updateQuarantineOutcomeRequest`, replay-safe
  `applyQuarantineOutcome`, provider wiring),
  `lib/features/inventory/quarantine_outcome_queue.dart` (persist
  + re-read), `lib/features/inventory/stock_operation_dialogs.dart`
  (await + `mounted` guard),
  `lib/features/inventory/quarantine_outcome_screen.dart` (await),
  `firebase/firestore.rules` (`quarantineOutcomes` block),
  `test/week5_day04_test.dart`, `test/week5_day05_test.dart`,
  `test/week6_day05_test.dart` (await on the
  request / reject call sites — intentional update only),
  `docs/technical-decisions.md` (D171)

## Follow-ups (Week 7)

- **Fake transport — `runTransaction` + `runBatchedWrites`**
  (brief §2): the Firestore order-repo return values are still
  verified by code inspection only (D165).
- **Cross-backend restore edge (Day 24, D169)** (brief §3):
  mock-export sale doc id ≠ idempotency key — still open.
- **Super Admin franchise-view gate — STILL OPEN, awaiting
  Dazy's decision** (brief §4): no decision recorded anywhere
  in docs/; do not guess.
