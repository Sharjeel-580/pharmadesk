# Day 15 — Week 3 Day 3 progress: pre-aggregated report counters + pagination + sync-status UI

**Date:** 25 Nov 2026. **Status:** DONE.
**Decisions:** D105–D109 in `docs/technical-decisions.md`.

## What was built

### 1. Reports on pre-aggregated counters (D105/D106)

The daily counters rollup Function (Job 3, `firebase/functions-design.md`)
writes one document per branch per day —
`branches/{branchId}/counters/daily-{yyyy-MM-dd}` — and the reports
screen now reads those instead of scanning the whole sales / orders
collections:

- **Model + pure aggregation** (`lib/core/data/report_counters.dart`):
  `DailyCounter` (`branchId`, calendar `date`, `salesTotalMinor`,
  `salesCount`, `ordersCount`, `cogsMinor`, `grossProfitMinor`) and
  `computeDailyCounters` — the same computation the rollup performs,
  reusing the D81/D93 cost rule (batch `costMinor`, fallback medicine
  `purchasePriceMinor`, else 0; refunds reduce revenue, COGS not
  clawed back). One counter per day even for zero days — a missing day
  means "not rolled up yet", a zero day means "rolled up, nothing
  sold".
- **Repository** (`ReportCounterRepository`): the mock computes from
  the same mock repos the live reports read, so mock counters are
  derived from the seeded demo data — never invented, never a second
  seed. The Firestore implementation reads the rollup docs (one exact
  document read per day, at most 31 for a 30-day window, no collection
  scan) and is read-only by design — a client that could write its own
  counters could fake the reports. Mappers (`dailyCounterToFirestore` /
  `dailyCounterFromFirestore`, legacy docs without the D105 cost fields
  still parse), schema contract
  (`branches/{branchId}/counters/daily-{date}`; the `value` map gains
  `cogsMinor` / `grossProfitMinor` beyond the Job 3 spec — the spec
  text is updated to match), rules draft (client writes to `daily-*`
  denied), bundle + provider wiring (D101 pattern).
- **Counters-first, never mixed (D106):**
  `advancedReportDataProvider` uses counters for the weekly trend,
  branch-comparison sales/profit and P&L revenue/COGS only when they
  cover EVERY day of the window for EVERY branch in scope; anything
  short falls back to the live computation for the whole window.
  Stock value, outstanding, expiry loss, slow movers and expenses
  always stay live. The screen says which path it took
  ("Pre-aggregated daily counters • N day(s) covered" vs "Live
  computed — no daily counters yet for this window"). `ProfitLoss` /
  `BranchAnalyticsRow` gain `copyWith` helpers that re-derive gross /
  net from overridden revenue/COGS.
- **Bug found by the tests:** `weeklyTrendFromCounters` first chunked
  the flat per-branch counter list by 7 — an org-wide scope (2
  counters/day) produced 9 weekly buckets instead of 5. Fixed by
  grouping counters by calendar day first, then chunking days into
  7-day buckets; single-branch input is unchanged.

### 2. Pagination (D107)

One page size (**10**, `reportPageSize`) and shared helpers:
`paginateList` for in-memory lists (1-based, clamped, empty list is
one empty page) and `paginate` cursor pages mirroring the transport's
`startAfterId` — the mock counter repo pages this way so its page
boundaries match the Firestore repo's exactly. `PagedList` /
`PagedListControls` widget: Previous/Next + "Page x of y", buttons
disabled at the boundaries.

Applied to the reports screen's daily sales, low stock, expiry
(expired + expiring combined, expired first), weekly trend, branch
comparison, slow movers and expenses lists — replacing the old
`take(20)` / `take(10)` truncations — and to sales history. Best
sellers stays unpaged (capped at 10 by the computation itself).
Firestore counter pages use the transport's paged fetch and skip the
sequential-number docs (`invoices`, `orders`, …) sharing the
collection, fetching on until the page is full.

### 3. Sync-status UI (D108/D109)

- `SyncQueue.lastSyncedAt` — set only when `processNext` actually
  syncs an operation, never on enqueue or a failed send — exposed as
  `ProductionDataLayer.lastSyncAt`.
- `SyncStatusChip` (reusable, compact): pending count + last-sync
  time, live from the layer. "All synced" when the queue is empty,
  "N pending sync" when operations wait, "Never synced" when nothing
  ever synced (no invented time — in the demo the queue is only
  enqueued, never drained, until the Firebase project exists), "Sync
  status unavailable" when the store throws (the provider resolves
  the failure instead of crashing the screen). Tap to refresh; the
  POS / orders / purchases notifiers invalidate `syncStatusProvider`
  after a layer write.
- **Placement survey (D109):** chip on POS (sale commit enqueues),
  orders (order creation enqueues), purchases list (receiving
  enqueues one batched-write payload, D103) and inventory. Inventory
  receive/adjust write to the inventory repo directly today — no sync
  op yet — so the chip there reads "All synced" until a queued write
  from another screen exists; routing inventory writes through the
  layer is a Day 4 follow-up. Returns restock (`layer.adjustStock`)
  enqueues nothing, so no chip on the returns screens; sales history,
  dashboard and reports only read.

## Verification

- `flutter analyze` — **No issues found!**
- New tests **39/39** (`test/week3_day03_test.dart`): DailyCounter
  model + mapper round-trip (incl. legacy rollup docs),
  `computeDailyCounters` agrees EXACTLY with the live computation on
  seeded data (30-day DHA + 7-day Gulberg totals, per-day, P&L
  revenue/COGS, weekly trend), mock + Firestore counter repos
  (range omits missing days, paged reads chain to all 30 / 25 days
  with no duplicates, sequential docs skipped), pagination helpers +
  `PagedList` widget (boundaries, disabled buttons, short lists),
  `copyWith` invariants, queue last-sync tracking, sync-status labels
  + chip states (empty / pending / synced / store unavailable),
  provider counters-first vs live fallback (identical figures both
  ways), factory wiring, reports screen (counters caption + daily
  sales paging to page 2 of 3), POS chip, sales-history empty state.
- Full suite **513/513** (191 Week 1 + 203 Week 2 + 51 Week 3 Day 1 +
  29 Day 2 + 39 Day 3).
- `flutter build web --release` — **Pass** (46,379,962 bytes).
  Prescription PNGs verified bundled (D61 check: both files on disk
  at exact sizes + 8 "prescription" mentions in `AssetManifest.bin`).

## Earlier-test update (D87/D97 pattern — deliberate, disclosed)

- None. No earlier test was touched and no earlier expectation
  changed. (The reports-screen truncations replaced by pagination
  are covered by the new Day 3 widget test, not by editing an old
  one.)

## Follow-ups for Day 4

- Route inventory receive / adjust through the production data layer
  so they enqueue sync payloads like receiving does (D109) — the
  inventory chip will then show a live count for stock work too.
  Returns restock (`layer.adjustStock`) needs the same treatment if
  returns should surface in the sync status.
- Live verification of the Firestore counter repo against a real
  project/emulator is still open (no Firebase project yet — Dazy-only
  blocker, unchanged), as is the rollup Function itself (Job 3 is
  design-only until the Firebase-wiring chunk).
- The salary edit flow (repository `saveSalaryRecord` is ready;
  screen + `canManageSalary` gating still to build) is still open
  from Day 2.
