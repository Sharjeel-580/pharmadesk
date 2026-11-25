# Day 17 — Week 3 Day 5 Progress (26 Nov 2026)

**Scope:** Phase 8 QA start (Week 3 brief §3) — the small known
nits first (D110 citation fix, stock-count routing, the D54 UI gap),
then the Week 3 QA pass at the same bar as the Week 2 QA pass, then
closing the week in docs.

## What shipped

### 1. Doc citation fix (D110)
- D110's "Not verified here" line cited "(D11)" for the sandbox
  Windows-build block; corrected to D52 per the Day 5 brief.
  One-line doc change, no code touched.

### 2. Stock count through the production data layer (D114, closes the D111 follow-up)
- `ProductionDataLayer.recordStockCount` (new) is the single write
  path for physical stock counts, like `receiveStock` /
  `adjustStock` (D111) are for receive / adjust. The variance
  (counted − system) is booked through the engine (`adjust`,
  reason "Stock count", ledger movement + audit) and the repository
  is set to the counted quantity — the same end state as the old
  repo-direct write, now with a ledger trail and an audit entry.
- Idempotency: optional `idempotencyKey` + a registry like the
  receive/adjust registries — a same-key retry returns the original
  count and applies no correction twice. The count dialog holds one
  key across retries (D115).
- Zero variance: a count that matches the system books no movement
  and enqueues no sync payload — there is no quantity change to
  sync. The repo write still happens (it stamps `updatedAt`).
- Sync: a non-zero correction enqueues one sync payload (the stock
  transaction + inventory-doc update, via the shared
  `_enqueueAdjustSync` — the same payload shape as an adjustment),
  so the Day 3 sync-status chip moves for stock counts. With this,
  every inventory write path (POS sale, order, goods receiving,
  receive, adjust, count, returns restock) enqueues — the D109
  survey has no repo-direct writer left on an offline-capable
  screen.
- `InventoryNotifier.recordStockCount` routes through the layer
  (actor from the signed-in user, demo fallback) and invalidates
  `syncStatusProvider` after a successful write, like
  receive/adjust. The `(item, variance)` return and the
  `null`-on-rejection contract are unchanged — the dialog and the
  medicine-detail caller need no changes. The stale "Stock count
  still writes repo-direct" comments in the provider and the
  inventory screen are updated.

### 3. Dialog-held idempotency keys (D115, closes the D54 UI gap)
- The gap (D54): the layer dedupes on the key, but the stock
  dialogs minted a fresh key per submit (the layer minted one per
  call), so a retry after a failed submit would NOT dedupe — the
  same posture POS had before its dialog-held key (Week 2 Day 3).
- Fix: each of the three stock dialogs (`_ReceiveStockDialog`,
  `_AdjustStockDialog`, `_StockCountDialog`) mints one key in its
  state (`late final`, `newIdempotencyKey('stock-receive-…'` /
  `'stock-adjust-…'` / `'stock-count-…')`, the D103/D65 pattern)
  and passes it through the notifier — whose three methods gain an
  optional `idempotencyKey`, forwarded to the layer — on every
  submit. D54 is now closed for every dialog that writes through
  the layer. The returns restock path still calls
  `layer.adjustStock` without an explicit key (one shot per return,
  no retry UI) — unchanged.
- Receive dialog could not retry at all: its `_save` had no error
  handling — a layer throw left the dialog stuck on loading with
  the button disabled, so the held key would have been moot.
  `_save` now catches the failure, shows "Receive failed — please
  try again.", and re-enables the button; the retry reuses the held
  key. The adjust/count dialogs already handled a null return this
  way; only the receive dialog needed the catch. This was small
  and safe (one try/catch + three key fields + three optional
  parameters), so it was fixed rather than recorded.

### 4. Week 3 QA pass — VERDICT: GREEN
- `flutter analyze`: **No issues found!** (zero errors, warnings
  and info lints — verified by reading the output, not by the
  exit code alone).
- Week 3 alone (`test/week3_day01_test.dart` …
  `test/week3_day05_test.dart`): **154/154 passed** (51 + 29 +
  39 + 21 + 14).
- Cumulative full suite (Week 1 + Week 2 + Week 3): **548/548
  passed** (191 Week 1 + 203 Week 2 + 154 Week 3). No earlier
  test was touched or updated — the layer/notifier changes kept
  every existing contract (D87/D97 pattern not needed).
- Fresh `flutter build web --release`: **Pass** (46,399,784
  bytes, 184.3s compile).
- Prescription PNGs (D61 check): both sample PNGs in
  `build/web/assets/assets/images/prescriptions/` at their exact
  source sizes (114,613 + 110,613 bytes), 8 "prescription"
  mentions in the decoded manifest, both sample paths present.
- Route walk: the Day 7 walk (15 module routes) + the Day 4
  desktop audit (19 routes) left 11 routes unwalked; the Day 5
  walk covers all 11 (`/orders/new`, `/orders/:id`,
  `/orders/:id/edit`, `/customers/:id`, `/suppliers/:id`,
  `/purchases/new`, `/purchases/:id`, `/prescriptions/:id`,
  `/billing/returns`, `/billing/returns/new`,
  `/billing/receipt/:id`) with a per-screen marker — every route
  in the router is now walked by at least one test. No
  placeholder, no dead route, no dead button found on any Week 3
  screen (salary screen, sync-chip placements, paginated report
  sections, inventory receive/adjust/count flows).
- Sidebar + mobile More sheet: Salary and Auto Purchase List
  entries verified in both (More sheet at the established 800px
  mobile test width — see §5 for the 390px caveat).
- **Verdict: Week 3 COMPLETE + VERIFIED.** Details in
  `docs/week-3-tracker.md` (Week 3 QA pass section, same format
  as the Week 2 QA pass).

### 5. QA finding — top-bar overflow at phone widths (D116, documented, NOT fixed)
- At a 390px viewport the shared shell top bar overflows by 236px
  on the right (brand mark + app name + branch switcher up to
  180px + DEMO MODE badge + three icon buttons do not fit). Every
  shell screen is affected — it is the shared `_TopBar`, not one
  screen. It was never caught before because every mobile test
  ran at 800px wide.
- Not fixed in this day, deliberately: the fix is a responsive
  top-bar pass (hide the app-name text / shrink the
  branch-switcher cap below ~600px), not a one-line change, and
  the DEMO MODE badge must stay visible on every screen (SRS
  §8.2) — the same precedent as Day 4, which recorded layout gaps
  rather than half-fixing them. Recorded in the tracker
  follow-ups with the suggested fix direction. The mobile
  More-sheet entries are verified at 800px until then.

## Verification
- `flutter analyze`: **No issues found!** (zero errors, warnings and info lints)
- New tests: **14/14** (`test/week3_day05_test.dart`)
- Week 3 alone: **154/154** (51 + 29 + 39 + 21 + 14)
- Full suite: **548/548** (Week 1 + Week 2 + Week 3; 534 before + 14 new, no earlier test touched)
- `flutter build web --release`: **Pass** (46,399,784 bytes)
- Prescription PNGs: **verified bundled** (D61 check — both sample
  PNGs in `build/web/assets/assets/images/prescriptions/` at their
  exact source sizes, 8 "prescription" mentions in the decoded
  manifest, both sample paths present)

## Decisions
D114–D116 in `docs/technical-decisions.md`.

## Files created / changed
- Created: `test/week3_day05_test.dart`, `docs/day-17-progress.md`
- Changed: `lib/core/data/production_data_layer.dart`,
  `lib/features/inventory/inventory_provider.dart`,
  `lib/features/inventory/stock_operation_dialogs.dart`,
  `lib/features/inventory/inventory_screen.dart` (comment only),
  `docs/week-3-tracker.md`, `docs/technical-decisions.md`

## Follow-ups (not in Week 3 build)
- **First CI `build-windows` run** (on the coordinator's push):
  watch it — until it goes green there is no verified Windows
  binary. If it fails on the FFI/sqlite3 native build, the fix
  belongs in the Windows runner config, not the Dart code.
- **Live Firestore verification** — blocked on the Firebase project
  + billing (Dazy-only step). Firestore code stays behind the mock
  default until then; no live read/write has been exercised.
- **Top-bar overflow at phone widths (D116)** — responsive top-bar
  pass (hide the app-name text / shrink the branch-switcher cap
  below ~600px); DEMO MODE badge must stay visible (SRS §8.2).
- **The seven missing desktop screens** (D-16, D-21, D-24, D-25,
  D-28, D-33, D-35) and the six partials (D-04 split payment,
  D-10 location + stock history, D-11 quarantine action, D-14
  adjustment approval queue, D-26 dedicated finance screen,
  D-34 tax/payment/receipt/discount config) — all recorded in the
  tracker as follow-ups with reasons; none is half-built.
