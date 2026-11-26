# Day 27 Progress — Franchise foundations + Phase 8 QA depth (Week 5 Day 5)

**Date:** 26 Nov 2026. **Scope:** FR-HO-07 franchise commission/royalty
tracking — schema + head-office view only, no onboarding flow; Phase 8
QA depth — full route walk + 390px sweep re-run, offline-queue +
role-gate coverage for the new flows, second QA pass over the finance
hub numbers. Decisions D158, D159, D160 in
`docs/technical-decisions.md`.

## What changed

### 1. Franchise royalty / commission computation (D158 — FR-HO-07, P3)
- `lib/features/finance/franchise_logic.dart` (new) — pure
  computation, int paisa, never floats:
  - `branchSalesMinor` = POS sales (`Sale.totalMinor`) +
    non-cancelled order totals (`rupeesToMinorUnits`, D6) −
    sale-return refunds, branch-scoped, inclusive day window.
    Deliberately the SAME revenue base as the P&L, so a royalty
    figure can never diverge from the revenue the Statements
    screen shows for the same branch and window. Refunds above
    sales clamp the base at zero.
  - `rateDueMinor` = `salesMinor * rateBps ~/ 10000`; `null` rate
    → `null` ("Not set", D130 — never 0); explicit 0% → 0. The
    division truncates sub-paisa remainders — a due is never
    rounded up.
  - `computeFranchiseRoyalties` — one row per branch (own branches
    included: sales show, both rates "Not set", due Rs 0.00;
    deactivated branches keep their history, FR-HO-08, so their
    period sales still accrue); `franchiseWindowStart` (trailing
    7 / 30 / 90 days, P&L convention); `franchiseDueLabel`
    ("Not set" / formatted amount).
  - `canViewFranchiseRoyalties` — see D159.
- `lib/features/finance/franchise_provider.dart` (new) —
  `FranchiseRoyaltyReport` (rows + totals) and
  `franchiseRoyaltiesProvider` (`FutureProvider.family` over the
  window), reading the branch directory + the three live sales
  repos fresh. Read-only: nothing here writes a rate.
- `lib/features/finance/franchise_screen.dart` (new) —
  `FranchiseScreen`, route `/finance/franchise`: window selector
  (7 / 30 / 90, default 30), summary card (total sales, royalty
  due, franchise fees due, total commission due, configured-branch
  count), per-branch cards (sales, royalty rate + due, franchise
  fee rate + due, total due), and the honesty note — rates are set
  in Branch Management, this view never edits terms, a missing
  rate shows as "Not set", and V1 runs the own branches so the
  demo rows show real sales with no rates configured and Rs 0.00
  due. No franchise agreement is invented. Head-office-only
  viewers outside the gate see the no-permission state (D159).
- No new capability, no new collection, no new repo: the rates
  already live on `Branch` (D130) and the sales already live in
  the sales/order/return repos.

### 2. Head-office gating + navigation (D159)
- `lib/core/data/permission_service.dart` — `/finance/franchise`
  maps to the existing `branches` capability ("Manage branches /
  franchises"). `lib/core/routing/app_router.dart` adds the route
  with `FeatureGate`.
- The screen itself requires WRITE-level `branches`
  (`canViewFranchiseRoyalties`): effective reach Super Admin /
  Owner / HO Admin; the Auditor passes the route gate (read-only)
  but is stopped at the screen — royalty figures are head-office
  financials, not branch reference data. This is the one
  deliberate exception to the D144 read-only-passes pattern, and
  the role-gate test pins it from `canWrite`, not `canInBranch`.
  Super Admin passes because the matrix grants it `allowed` on
  `branches`; excluding it would need a role check outside the
  matrix (follow-up if Dazy wants literally Owner / HO Admin
  only).
- `lib/features/finance/finance_hub_screen.dart` — fourth card,
  "Franchise Royalties" (`branches` + new `_FinanceCard.requireWrite`,
  so the Auditor sees the card locked instead of tapping through
  to a no-permission screen).
- `lib/app/shell/app_shell.dart` — sidebar sub-item under Finance
  and More-sheet entry under Finance, both gated on
  `canViewFranchiseRoyalties`.
- `lib/features/settings/feature_gate.dart` — `/finance/franchise`
  title/subtitle, so a route-gated role reads "No permission for
  Franchise Royalties" instead of "This screen".

### 3. Phase 8 QA depth (D160)
- **Route walk:** the Day 5 suite walks all 47 routes in the
  router (markers where a screen has a unique title,
  no-placeholder + no-404 everywhere), including the Week 5
  routes (`/inventory/adjustments`,
  `/inventory/quarantine-outcomes`, `/finance/franchise`).
- **390px sweep:** medicine edit form, branch shelf dialog,
  populated quarantine-outcomes queue, POS with cash disabled,
  cashbook with a closing + correction + reconciliation
  (including opening the Correct dialog), franchise view with
  configured rates, aging, statements — 0 RenderFlex overflows
  in every case.
- **Offline queue (D143 pattern, new flows):** adjustment filing,
  supplier payment, branch save, quarantine outcome, closing
  correction + cash reconciliation — enqueue while "offline",
  flush exactly once on reconnect, retry with the same
  idempotency key returns the original with no new payload and
  no second money/stock move; a failed send keeps the op and it
  flushes past the back-off.
- **Role gates (D144 pattern):** all 10 roles × the two new
  routes, expectations computed from the matrix, plus spot
  checks naming the Auditor divergence.
- **Finance agreement (second pass):** cashbook income/expense
  sums agree with the P&L's other income/expenses for the same
  30-day window; a closing correction moves neither the cashbook
  nor the P&L; a supplier payment through the layer moves the
  aging by exactly the payment (aging total == ledger sum ==
  stored running balance) and moves no P&L field; seeded aging
  buckets agree with the ledger per supplier and org-wide
  (Rs 194,250.00); a mixed-age ledger ages FIFO with buckets
  summing to the total; the aging providers agree with the
  ledger per supplier; closing totals agree with the day's
  cashbook entries and the expected drawer follows the same
  entries, unchanged by a correction.

## Old-test updates (intentional, Day 2 pattern)
- `test/week4_day03_test.dart` — the finance hub now has FOUR
  cards, not three: the owner hub test is renamed ("four finance
  cards") and asserts the "Franchise Royalties" card; the
  cashier hub test now expects THREE locked cards ("No access"),
  not two — the franchise card is locked for the Cashier too
  (D159, head-office only). No behaviour was bent to fit the
  test; the card is the intended change.

## Test-author lessons (found while verifying, same commit)
- The mock expense repo is SEEDED — an unwindowed cashbook sum
  mixes in older history (Rs 236,200.00 of seeded expenses). The
  agreement test windows both sides identically (trailing 30
  days, P&L convention) and pins the delta from its own writes.
- FIFO settles the OLDEST charge first: a part payment settles
  the 120-day charge, not the 10-day one — the first draft of
  the mixed-age test had the direction backwards.
- `InMemorySyncStore.pendingCount()` reads the REAL clock, so
  due-count assertions under a fake clock must use
  `pendingOperations()` (the queue's `nowProvider` clock).
- The top-bar branch switcher also renders the active branch
  name, so branch-name assertions at desktop width are
  `findsWidgets`, never `findsOneWidget` (and an Auditor
  no-permission test must not assert the branch name is absent).
- Pumping two router apps in one test trips the binding's
  pending-timer check at teardown — the hub-card test is two
  tests (Owner / Auditor), not one double-pump test.

## Verification
- `flutter analyze`: **No issues found!**
- Day tests `test/week5_day05_test.dart`: **50/50** — D158 pure
  computation (8), D159 gating + widgets (8), route walk (2),
  390px sweep (8), offline queue new flows (6), role gates new
  routes (11), finance agreement second pass (7).
- Full suite `flutter test`: **872/872** (baseline 822 + 50 new).
- `flutter build web --release`: **pass** — `build/web`
  (46,725,756 bytes); prescription PNGs still bundled in
  `build/web/assets/assets/images/prescriptions/`
  (`sample-prescription-1.png` 114,613 bytes,
  `sample-prescription-2.png` 110,613 bytes, same sizes as Days
  23–26).
- 390px: 0 RenderFlex overflows in the Day 5 widget tests
  (drained exceptions).

## Follow-ups (not in this day)
- Franchise onboarding flow is Phase 2 business scope — not
  built here by design (schema + head-office view only).
- Super Admin passes the franchise gate because the matrix
  grants it `allowed` on `branches`; literally Owner / HO Admin
  only would need a new decision, not a code tweak.
- Finance writes are still not FR-HO-08-guarded (D149 boundary,
  carried from Day 24) — corrections/reconciliations included.
- Quarantine outcome queue is still session-only (D141 posture);
  Firestore persistence is a follow-up.
- POS tax rate is still read once in `initState` (D136).
- Week 5 QA pass (coordinator) is next.
