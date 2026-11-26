# Day 42 — Week 8 Day 5 Progress (26 Nov 2026)

**Scope:** brief §5 — final QA sweep (D180). Finance agreement,
final pass (cashbook vs P&L vs supplier ledger vs daily closings,
over the guarded writes D161/D162 + idempotent payments D162 +
re-keyed restore D173 + counter advance D175); offline-queue +
role-gate coverage for every flow added in Week 8; 390px sweep +
47-route walk re-run on the final tree with the corrected
`FlutterError.onError` trap; cumulative suite green + fresh web
build + prescription PNGs bundled; Week 8 fix-list close-out.

**Result: done. One real finance defect found and fixed the same
day (the correction chain — §1).** `flutter analyze` clean, Day 42
tests **10/10 passed**, full cumulative suite **1201/1201
passed** (see Verification), fresh web build pass (`main.dart.js`
**4,684,129** bytes), prescription PNGs bundled (114,613 + 110,613
bytes). The tree changed since Day 39 only by docs + test files,
and the re-run confirms it: **0 distinct overflows** over all 47
routes at 390px (corrected trap), all 47 routes resolve at desktop.

## 1. Finance agreement, final pass (D180) — 5 tests, 1 defect found + fixed

All figures in integer paisa. The pass re-verifies the guarded
writes with NEW angles this pass (the third pass, D173, covered
expense/income/supplier-payment/correction/reconciliation replays
and the re-keyed sale restore; this pass adds the correction
chain, the split-payment cash leg, the counter-advance order, and
one full day with all four views agreeing).

### Defect found by the new tests and fixed the same day — the correction chain

**The disagreement:** `previousClosingBalance` (used by
`closeDay`, `reconcileDay`, and the cashbook screen's close totals
+ expected drawer) read the ORIGINAL closing balance of the latest
closing before the day — even when that closing had been corrected.
The cashbook screen itself shows the CORRECTED figures for that
closing (`adjustedClosingTotals`, D156). So after a correction the
books disagreed with themselves: the corrected closing said
Rs 200.00, but the next day's opening, close totals and expected
drawer all opened from Rs 150.00.

**The evidence (test, before the fix):** close yesterday with
income Rs 250.00 / expense Rs 100.00 → closing Rs 150.00; correct
it to income Rs 300.00 → adjusted closing Rs 200.00, original
untouched at Rs 150.00; close today with no new entries → opening
**Rs 150.00** (expected Rs 200.00). The test failed with
`Expected: <20000> / Actual: <15000>`.

**Why it is a defect, not a design choice:** D156 defines the
corrected figures as "the totals a closing STANDS at" — and the
opening balance is defined (finance_logic doc) as "the previous
closing's closing balance". The balance a closing stands at IS its
corrected balance; opening from the original contradicts both
definitions. The correction is an audit record (the original is
never rewritten), but the chain must follow the re-stated day.

**The fix (3 files, no behaviour change when no correction exists):**
- `lib/features/finance/finance_logic.dart` —
  `previousClosingBalance` gains an optional `corrections`
  parameter (default `const []`): the latest closing before the
  day now contributes
  `adjustedClosingTotals(original: latest, corrections:
  corrections).closingBalanceMinor`. With no corrections the
  adjusted balance equals the original, so every existing caller
  and test is unaffected.
- `lib/features/finance/finance_provider.dart` — `closeDay` and
  `reconcileDay` read the corrections fresh from
  `closingCorrectionRepositoryProvider` (the repo, not the
  notifier state, so a correction recorded just before the close
  counts) and pass them through.
- `lib/features/finance/cashbook_screen.dart` — the close-totals
  and expected-drawer openings pass the `corrections` already in
  scope in `build`.

**Boundary, stated plainly:** a closing made BEFORE a correction
keeps its snapshot (closings are never rewritten); only closes and
reconciliations computed AFTER the correction follow the corrected
chain. The test pins the after-case; the before-case is the
snapshot semantics, unchanged.

**After the fix:** the same test passes — today opens at Rs 200.00,
closes at Rs 200.00, and the reconciliation for today expects
Rs 200.00 with difference 0.

### The five agreement tests (all pass)

| # | Test | Figures (integer paisa) |
|---|---|---|
| 1 | Correction chain (above) | Yesterday income 25000 / expense 10000 → closing 15000; corrected income 30000 → adjusted closing 20000; today opening 20000, closing 20000; reconciliation expected 20000, diff 0 |
| 2 | Split-payment drawer | Split sale Rs 10,000 (cash leg 600000, card leg 400000) + income 125000 − expense 250000 → expected drawer **475000**, diff 0; recount at 475100 → diff +100, expected unchanged. P&L takes the FULL sale (+1000000 revenue) while the drawer takes only the cash leg — the two views differ by exactly the card leg (400000). A Rs 10,000 supplier payment moves NEITHER the expected drawer NOR the P&L (D157 documented scope — a supplier payment is recorded against the payable, not the drawer) |
| 3 | Counter-advance order (D175) | Restored `ORD-DHA-1492`, Rs 500.00 → P&L revenue **+50000**, net **+50000**, daily counter **+50000**; P&L and counter agree exactly; re-restore moves nothing; next mint is `ORD-DHA-1493` |
| 4 | One day, four views | Cash sale 1000000 + expense 750000 + income 125000 + supplier payment 1000000 → cashbook income +125000 / expense +750000 (the sale and the payment are NOT cashbook entries); P&L revenue +1000000, other income +125000, expenses +750000, net +375000, and `otherIncome == cashbook income`, `expenses == cashbook expense`, `net == gross + otherIncome − expenses`; aging 4825000 → **3825000** (aging total == ledger sum == stored running balance, last entry −1000000); closing income 125000 / expense 750000 / opening 0 / closing **−625000**; reconciliation expected **375000**, diff 0 |
| 5 | Refused close/reconciliation | On a deactivated branch, `recordDailyClosing` and `recordCashReconciliation` both throw `ArgumentError`; cashbook sums, P&L and both repos exactly unchanged (both repos empty) |

### Test-side correction made while building (no app defect)

**The counter-advance test's first version carried an inconsistent
order:** `sampleOrder` (2 × Rs 100 items, Rs 5 discount) with
`totalAmount` overridden to 500.0 — and measured a 19500 revenue
delta instead of 50000. The order's `totalMinor` is DERIVED
(`subtotalMinor − discountMinor` = 19500); the Firestore mapper
stores that derived `grandTotal` (int paisa, SRS §3) and reads back
`totalAmount = grandTotal / 100`. The app always builds orders
with `totalAmount == items − discount` (`buildNewOrder` /
`buildEditedOrder`), and seeded orders are consistent too, so a
real restore round-trips consistently — only the hand-built
fixture was inconsistent. The test now builds a consistent order
(5 × Rs 100, discount 0, totalAmount 500.0) and asserts the
restored `totalAmount` is 500.0 as well as the number.

## 2. Offline-queue + role-gate coverage for every Week 8 flow

Days 38–41 added **no new flow with a queue or gate surface**
except the acceptance-test paths. Per-flow verdicts:

| Week 8 flow | Queue surface | Role-gate surface | Verdict |
|---|---|---|---|
| Day 38 criterion 1 — Owner + Cashier login | None (local demo sign-in, no sync op) | None (role is read from the demo account) | **No surface** — nothing to cover |
| Day 38 criterion 2 — full sale (scan → pay → receipt) | **Yes** — a completed sale enqueues exactly one sync op | None new (POS permission is the existing `billing` gate) | **Covered** — pinned in `test/week8_day01_test.dart` §9 test 2 (`a completed sale enqueues exactly one sync op`), re-run by the cumulative suite; not duplicated here |
| Day 38 criterion 3 — FEFO + expired-blocked | None (pure computation over the inventory repo) | None | **No surface** |
| Day 38 criterion 4 — branch switching | None (switching is viewing — the D143 pattern: the directory switch enqueues nothing) | None (role-independent viewing) | **No surface** — Week 6 pin cited, not re-tested |
| Day 38 criterion 5 — daily report + export | None (local computation + file export) | None | **No surface** |
| Day 38 criterion 6 — WhatsApp order, full status flow | **Yes** — order creation enqueues one sync op (D108) | None new | **Covered — NEW test this day:** `Day 38 criterion-6 flow enqueues exactly one sync op, drains once, and a same-key retry enqueues nothing` (create → queue +1 → `processSyncQueue` drains 1 → queue back to baseline → same-key retry returns the original, queue unchanged). Day 38's walk test never asserted the queue, so this is new coverage, not a duplicate |
| Day 38 criterion 7 — no dead buttons | None (navigation + wired actions) | None | **No surface** |
| Day 39 walk fixes (badge Wrap, dropdown `isExpanded`, scroll restructure, salary `FittedBox`) | None (pure layout) | None | **No surface** — layout changes only, 12 fixes, each with its Day 39 regression test |
| Day 39 walk check — prescription Approve | None | **Yes** — pharmacist-only `rxReview` (D70) | **Covered — re-pinned this day on the final tree:** Owner taps Approve → no snackbar, Approve stays; pharmacist taps Approve → snackbar `…approved — linked orders can now be dispatched`, Approve gone (2 widget tests) |
| Day 40 fake-transport copies | None (no app behaviour changed; 12 copies left, 0 upgraded — D178) | None | **No surface** |
| Day 41 handover docs | None (docs only, no code) | None | **No surface** |

No coverage was invented: where a flow has no queue/gate surface
the reason is stated above.

## 3. 390px sweep + 47-route walk re-run (D180)

**Trap (stated, D170/D174 standard):** `FlutterError.onError`
installed before pumping, counting DISTINCT `RenderFlex overflowed`
messages; forwarded to the previous handler. The D160
`takeException` drain is NOT the measurement.

- **Desktop (1920×1080):** all **47 routes resolve with their
  markers**, no "Page not found", no "coming Week 1" placeholder.
- **390px sweep:** **0 distinct overflows** over all 47 routes
  (corrected trap). The tree changed since Day 39 only by docs +
  test files, so 0 was expected — verified, not assumed.
- The re-run tests live in `test/week8_day05_test.dart` (route list
  + trap copied from `test/week8_day02_test.dart`, private there).

## 4. Week 8 fix-list close-out (Day 38 §3, final status of every item)

| # | Item (Day 38 §3) | FINAL status |
|---|---|---|
| 1 | Excel export (§9 Reports; SRS §4.7 + FR-REP-05) | **Documented gap** — coordinator decision (Day 39 §6): NO new dependency in Week 8; CSV export works and opens in Excel with the same data. Native `.xlsx` stays a documented post-handover gap |
| 2 | Bulk catalogue import, FR-INV-14 (§9 Inventory + Data) | **Documented gap** — feature build (Excel/CSV import + validation report); no build scope on a walk day or on the Day 42 QA sweep. The import path real client data would take; stays a post-handover gap |
| 3 | POS keyboard shortcuts, desktop (§9 POS; SRS §4.3) | **Documented gap** — feature build; no build scope in Week 8 |
| 4 | Purchase returns (§9 Core modules D) | **Documented gap** — feature build (record a return against a PO/supplier with ledger + stock effect; only the `SupplierLedgerEntryKind.purchaseReturn` label exists today). The `/billing/returns` screen itself resolves and renders (Day 39 walk) |
| 5 | Employee-performance report (§9 Core modules G) | **Documented gap** — feature build (per-employee sales over a window; branch comparison exists, per-employee does not) |
| 6 | Firestore seed script (§8.3 item 4) | **Documented gap, BLOCKED-DAZY** — needs a real Firebase project to seed into (no project exists; project + billing creation is Dazy-only). The in-app mock seed (`lib/core/services/demo_seed_data.dart`) already exists |
| 7 | Thermal printer integration (§9 POS) | **BLOCKED-CLIENT** — needs the client's printer model first (Appendix A Q6); network/USB printers are honest stubs that report "not configured" (`receipt_printer.dart`); manual-entry fallback stays |
| 8 | Login activity + performance (§9 Core modules E) | **Documented gap** — feature build (surface `lastLoginAt` + per-staff activity; schema field only today) |
| 9 | Handover docs without an owner yet — admin manual + backup/restore guide | **CLOSED in Week 8 (Day 41, D179)** — folded into the deployment guide §8 as a concise admin section instead of a separate doc (brand settings, 10×24 role matrix per-role table, 12 toggleable modules, backup export + restore steps with D169/D173/D174/D175 semantics) |

Nothing is left unrecorded. Not on the fix list, unchanged since
Day 38: demo + production Firebase projects, custom claims,
App Check, FCM, scheduled exports — **BLOCKED-DAZY**; real
org/branch/staff/data setup, optional-module selection (O-1–O-11),
support terms, scope freeze (§8.4 criterion 8) —
**BLOCKED-CLIENT**; Super Admin franchise-view gate — **STILL OPEN,
awaiting Dazy's decision** (no decision recorded anywhere in
docs/; nothing guessed or built).

## 5. Verification

- `flutter analyze`: **clean** — "No issues found!".
- Day tests: `test/week8_day05_test.dart` **10/10 passed** (finance
  agreement 5, offline/role 3, sweep/walk re-run 2).
- Full cumulative suite (Weeks 1–8): **1201/1201 passed**
  (1191 baseline + 10 new, 12:35; log at
  `~/workspace/fazal-din-pharma-week8-day42-full-suite.log`).
  Note: the first suite run was killed at ~60s by a service restart
  (SIGTERM, same failure mode as Day 39's first run); the re-run on
  the same tree completed green.
- Fresh `flutter build web --release`: **pass** — `main.dart.js`
  **4,684,129 bytes**.
- Prescription PNGs bundled: **confirmed** — 114,613 + 110,613 bytes
  in `build/web/assets/assets/images/prescriptions/`.

## 6. Files changed

- **Code (3 files, §1 fix):** `lib/features/finance/finance_logic.dart`
  (`previousClosingBalance` + optional `corrections`),
  `lib/features/finance/finance_provider.dart` (`closeDay` +
  `reconcileDay` read corrections fresh from the repo),
  `lib/features/finance/cashbook_screen.dart` (close-totals +
  expected-drawer openings pass the in-scope corrections).
- **Tests:** `test/week8_day05_test.dart` (new, 10 tests).
- **Docs:** `docs/day-42-progress.md` (this file),
  `docs/week-8-tracker.md` (Day 42 section + Follow-ups),
  `docs/technical-decisions.md` (D180).
- **Untouched:** `presentation-video/`; no new routes, no new
  capabilities, no matrix changes; no dependency added (pubspec
  untouched); no Firebase project created; nothing pushed to GitHub.

## 7. Follow-ups (Week 8 — final)

- **Super Admin franchise-view gate — STILL OPEN, awaiting Dazy's
  decision** (brief §4): no decision recorded anywhere in docs/;
  do not guess. Noted in the deployment guide §8.2.
- **Live-Firestore E2E (all of it)** — BLOCKED on a live Firebase
  project (Dazy-only step): rules, custom claims, App Check, FCM,
  scheduled exports, sync sender, seed script — verification here
  is the fake-transport suite + file checks, stated plainly.
- **§8.4 criterion 8 (client feedback + scope freeze)** —
  BLOCKED-CLIENT; needs the Phase 5 client walkthrough.
- **Week 8 fix list** — closed out in §4 above: 1 item closed in
  Week 8 (admin manual + backup/restore guide, Day 41), 1
  BLOCKED-CLIENT (thermal printer), 1 BLOCKED-DAZY (seed script),
  6 documented post-handover gaps (Excel export, bulk import
  FR-INV-14, POS keyboard shortcuts, purchase returns,
  employee-performance report, login activity + performance).
- **Known scope, pinned not fixed (D157):** a cash supplier payment
  is recorded against the payable, not the drawer — the expected
  drawer and the P&L both exclude it by design; a real cash payment
  to a supplier shows up as a drawer difference to investigate.
  Pinned by the Day 42 split-drawer test.
- **Week 8 is complete.** The coordinator's parent does the final
  full testing and delivers the FINAL report to Dazy; the
  coordinator's job ends here.
