# Day 36 — Week 7 Day 4 Progress (26 Nov 2026)

**Scope:** brief §5 — Phase 8 QA depth, fourth pass (D174).
Fresh full 390px sweep + 47-route walk with the CORRECTED
`FlutterError.onError` trap (D170 standard); D170 overflow fixes
re-verified in place; offline-queue + role-gate coverage for every
Week 7 flow (D171 persisted quarantine queue, D172 fake-transport
transaction/batch paths as exercised by the repos, D173 re-keyed
restore); finance agreement THIRD pass over the guarded finance
writes + idempotent payments, extended to the re-keyed restore.

**Every sweep figure below was measured with the corrected trap**
(`_OverflowTrap` in `test/week7_day04_test.dart` — a
`FlutterError.onError` trap counting DISTINCT overflow messages).
No figure in this doc was measured with the D160
`takeException` drain; the drain is kept in the day file only for
the harness-proof test, which re-pins the difference (D160 drain
0, trap 2, for two simultaneous overflows).

## What shipped

### 1. Defect found by the new tests, fixed the same day — D174

**Restore re-numbered orders cross-backend**
(`lib/core/data/firestore_repositories.dart`,
`FirestoreOrderRepository.upsertOrder`): for a genuinely new doc
the repo always minted a fresh order number from the target's
per-branch counter, ignoring the number the restore replay
carried. A mock order numbered `ORD-DHA-1492` restored into a
fresh Firestore layer came back as `ORD-DHA-1001`. The mock repo
never had this defect — its number is derived from the doc id, so
a mock→mock restore preserves the number — which made the
cross-backend restore asymmetric, against the stated D165 intent
("a restore never re-numbers"). Order numbers are business
identity (printed on receipts, referenced by staff); a restore
that renumbers them silently breaks that link.

**Fix:** for a new doc, `upsertOrder` now keeps the incoming
order's non-empty `orderNumber` and mints from the counter only
when the incoming order carries none (a genuinely new order,
e.g. Day 34's `sampleOrder()` with no number). An existing doc
keeps its stored number, as before. `upsertOrder`'s only caller
in `lib/` is the restore (`_restoreDoc`), so the change is
restore-scoped in practice — exactly like the D173 mock
`upsertSale` change. The `OrderRepository.upsertOrder` interface
doc (`lib/core/services/repositories.dart`) now states the
preserved-number behaviour. No existing test needed updating:
Day 34's upsert tests use number-less orders (still minted),
Day 35's order tests asserted id/key only (unchanged).

**Follow-up (recorded, not smuggled in):** preserving a number
does not advance the target's counter — a target whose counter
sits at 1001 that restores an order numbered 1492 will mint
1002…1491 for new orders and could eventually mint 1492 for a
different order. Advancing the counter past a preserved number
needs a sequence-parsing rule for `ORD-<branch>-<seq>` shapes
(and a decision for numbers from other branches / shapes) —
left as a follow-up; it cannot collide in practice yet, because
no live Firestore exists and the mock derives numbers from ids.

### 2. The sweep found NO new overflows — and the D170 fixes hold

- **D170 fixes re-verified in place (trap, 0 distinct overflows
  each):** supplier detail for both suppliers (the 63px aging
  badge + 0.2px Export row), `/reports` branch filter dropdown
  opened and picked (the 21px `isExpanded` case), supplier
  payment dialog with the method dropdown opened (the 5.9px
  case), `/branches` list rows (the 4.4px Wrap case), sales
  history paged list (the 120px `PagedListControls` Wrap case).
  The fix sites are still in the code (`isExpanded: true` in
  `reports_screen.dart` / `supplier_detail_screen.dart`,
  `Wrap` in `branch_list_screen.dart` /
  `pagination_controls.dart`, `Flexible` in `badges.dart` /
  `buttons.dart`).
- **Week 7 screens swept (trap, 0 distinct overflows each):**
  quarantine outcomes queue populated (pending request, filter
  chips All/Pending/Approved exercised), queue with a decided
  request carrying a long decision note, the Return-batch dialog
  on a quarantined batch (opened, reason entered, request filed),
  the Dispose-batch dialog with an empty reason (validation error
  inline, dialog stays open, nothing filed), the backup screen
  with the D169 restore text, the restore confirm dialog.
- **Full D160 list re-run with the corrected trap (0 distinct
  overflows each):** branch shelf dialog, POS with cash disabled,
  cashbook with closing + correction + reconciliation including
  the Correct dialog, franchise view with configured rates,
  aging, statements.
- **47-route walk re-run:** Week 7 added no routes, so the walk
  is the same 47 shell routes as Day 27 / Day 32, count asserted
  (`hasLength(47)`), no placeholders, no 404s.

### 3. Finance agreement, third pass (D161/D162/D173)

Re-run with new keys and amounts — guarded expense Rs 7,500 +
income Rs 1,250 move the windowed cashbook sums and the P&L's
other income/expenses by exactly their amounts, with exactly
one mirror transaction per expense; idempotent replays move
nothing. A guarded supplier payment of Rs 15,000 moves the
aging from Rs 48,250 to Rs 33,250 (aging total == ledger sum ==
stored running balance) and moves no P&L field; its replay
returns the original with no new ledger entry. A guarded closing
correction and a guarded reconciliation each move neither the
cashbook nor the P&L, and each replay records nothing twice. A
refused write on a deactivated branch leaves cashbook sums, P&L
and aging exactly unchanged. A guarded daily closing (via the
notifier) agrees with an independent recomputation of
`computeDailyClosing` (income Rs 250, expense Rs 100).

**New this pass — re-keyed restore agreement (D173):** a mock
export restored into a fresh mock layer moves the P&L revenue
and the derived daily counter by exactly the restored sale
(Rs 10,000.00), once — the sale lands under its key, not the
mock id — and a re-restore under overwrite counts it as
overwritten (created 0) and moves no figure a second time.

### 4. Offline queue + role gates for the Week 7 flows

- **Persisted quarantine queue (D171):** filing at the layer
  enqueues exactly 1 payload, flushes once, and a same-id re-file
  dedupes (no second doc, no second payload). Through the
  notifier, an approve queues apply + decision on top of the
  quarantine + file payloads already queued (4 total — the
  quarantine itself enqueues one batch-status payload first),
  flushes once, and a double-approve adds nothing (one
  `batch.disposed` audit entry, batch disposed). A reject queues
  the decision on top (3 total), flushes once, and the batch
  stays quarantined. A refused approve on a deactivated branch
  enqueues nothing new (request stays pending, batch stays
  quarantined); reactivation lets the same approval through
  exactly once (4 payloads, one audit entry).
- **Restore (D173):** a restore enqueues NO sync payload — it
  writes direct to the repos (a fresh layer's seeded docs are
  overwritten, not created, so `created + overwritten > 0` with
  `pendingCount()` still 0).
- **Fake-transport transaction/batch paths as exercised by the
  repos (D172):** `createOrder` through the Firestore repo over
  the fake transport returns `ORD-DHA-1001` + key == id, the
  stored doc and the items subcollection (1 item) agree, and the
  read-back matches; a restore replay via `upsertOrder` returns
  the same number/key, consumes no counter (next create is
  `ORD-DHA-1002`), and writes the item once. An order-only
  backup restored into the Firestore layer lands via the batch
  path (doc + items) and re-imports count once (created 1, then
  overwritten 1, still 1 order) — and now preserves the backup's
  order number (§1). A repo-level pin: `upsertOrder` for a new
  order WITH a number keeps it (`ORD-DHA-1492`) and consumes no
  counter (next create still `ORD-DHA-1001`); with an empty
  number it still mints (`ORD-DHA-1002`).
- **Role gates:** all 10 roles × `/inventory/quarantine-outcomes`
  — the route gate follows `stockAdjustReq` from the matrix
  (Owner / HO Admin / Branch Mgr / Inventory Mgr pass; the other
  six see "No permission for Inventory", the Inventory module
  title). Approve is refused for the requester themself (§5.2.4
  separation of duties — no apply, no decision persist, no new
  payload) and for a Cashier (no `stockAdjustApprove`); the Owner
  approves. Backup gate spot-check holds: Owner passes,
  Pharmacist sees "No permission for Backup & Restore".

## What broke while building (and the fix) — all test-side, no app defect

- **First run: 15 failures, all in the new day file.** The
  app code was never at fault except §1 (found by the tests).
  (a) The quarantine-batch step enqueues a batch-status payload
  before filing, so notifier-path pending counts are one higher
  than the file/apply/decision payloads alone (2 after filing,
  4 after approve, 3 after reject) — counts corrected, and the
  test names now say so. (b) The quarantine route's
  no-permission screen carries the Inventory module title ("No
  permission for Inventory"), not the route title — the
  `FeatureGate` uses `module.title` for module routes. (c) The
  reports dropdown is `DropdownButton<String?>` and the supplier
  payment method dropdown is
  `DropdownButtonFormField<SupplierPaymentMethod>`, not the
  `<String>` types first assumed — finders corrected. (d) A
  fresh-layer restore overwrites the seeded docs, so `created`
  is 0 — the assertion is now `created + overwritten > 0`.
  (e) The mock order counter starts past its seeded orders
  (`ORD-DHA-1492`, not 1001) and the export carries all 492
  seeded orders — the order-only backup is now filtered to the
  created order's doc and compared against its own number.
  (f) The order-number mismatch that remained after (e) was the
  §1 defect, fixed in `lib/`.
- **One analyze pass** flagged an unused import, an unused
  helper and a wrong schema path helper (`orderItemsPath` does
  not exist — the items path is `nestedCollection(…,
  orders, id, orderItems)`); all fixed, analyze clean.
- **The first full-suite run died with a service restart**
  (same shape as Day 33's stall — the run produced only a
  truncated log and the service restarted mid-run); the re-run
  completed green in ~11 min. No test failure was observed
  before the restart.

## Verification

- `flutter analyze`: **clean** — "No issues found!"
- Day 36 tests alone (`test/week7_day04_test.dart`): **50/50
  passed** — harness proof (1), route walk (2), D170 fixes
  (6), Week 7 screens sweep (6), D160 re-run (6), finance
  agreement third pass (7), offline queue Week 7 flows (8),
  role gates Week 7 flows (14).
- Full cumulative suite (Weeks 1–7): **1111/1111 passed**
  (baseline 1061 + 50 new).
- Fresh `flutter build web --release`: **pass**
  (46,743,464 bytes), run sequentially after the full suite.
- Prescription PNGs bundled (114,613 + 110,613 bytes in
  `build/web/assets/assets/images/prescriptions/`, 8 manifest
  mentions, both sample paths present).

## Files changed

- New: `test/week7_day04_test.dart`, `docs/day-36-progress.md`
- Modified: `lib/core/data/firestore_repositories.dart`
  (`upsertOrder` preserves a carried order number on a new doc,
  D174 §1), `lib/core/services/repositories.dart`
  (`upsertOrder` interface doc updated for the preserved-number
  behaviour), `docs/technical-decisions.md` (D174),
  `docs/week-7-tracker.md` (Day 36 section)

## Follow-ups (Week 7)

- **Restore counter advance (D174, new):** preserving a backup
  order number does not advance the target's per-branch counter
  — a target at 1001 restoring an order numbered 1492 could
  eventually mint 1492 for a different order. Advancing the
  counter past a preserved number needs a sequence-parsing rule
  for `ORD-<branch>-<seq>` shapes (and a decision for numbers
  from other branches / shapes). Cannot collide in practice yet
  (no live Firestore; the mock derives numbers from ids).
- **Super Admin franchise-view gate — STILL OPEN, awaiting
  Dazy's decision** (brief §4): no decision recorded anywhere
  in docs/; do not guess.
- **Live-Firestore E2E for the restore re-key + number
  preservation (D173/D174):** blocked on a live Firebase
  project (Dazy-only step) — no project exists, none was
  created; verification here is the fake-transport suite.
