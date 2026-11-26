# Day 20 — Week 4 Day 3 Progress (26 Nov 2026)

**Scope:** the finance hub — the three missing/partial finance
screens from the Week 3 Day 4 audit: D-24 Cashbook, D-25
Payables/Receivables aging, D-26 dedicated P&L / Statements
screen (Week 4 brief §2).

## What shipped

### 1. Cashbook — D-24 (D124–D126, D129)
- `lib/features/finance/cashbook_screen.dart` (`/finance/cashbook`):
  income/expense entries for the active branch (expenses from the
  `expenses` collection, income from `financialTransactions` of type
  `income` — unified newest-first by `cashbookEntries`, D124), a
  day picker + "Show all dates" filter, money-in / money-out / net
  summary for the filtered set, and a `PagedList` at 10 (D107).
- **Add entry** (dialog, gated on `financeEntry` write): income or
  expense, date (never future), fixed category list, whole-rupee
  amount, note for expenses. Expenses reuse
  `ExpensesNotifier.recordExpense`; income is new —
  `FinancialTransactionsNotifier.recordIncome` (D125).
- **Daily closing** (D126): "Close this day" snapshots the day's
  totals (in/out + opening carried from the previous closing) into
  a `DailyClosing` record — a record, never an edit of the entries.
  The closings history lists each closing with its totals; a
  closing whose day gained entries after the close is flagged
  "Changed since closing" (`dailyClosingIsStale`) instead of being
  rewritten (FR-FIN-06).
- **New data layer (D101 pattern):** `DailyClosing` model
  (`lib/models/daily_closing.dart`), `DailyClosingRepository`
  interface + mock + Firestore implementation,
  `branches/{branchId}/dailyClosings` schema contract (new
  collection — the SRS names daily closing but gives it no
  collection; `cashDrawers` is the physical drawer count), mappers,
  `RepositoryBundle.dailyClosings` + `dailyClosingRepositoryProvider`.
  No seeded closings — the demo starts with no day closed.

### 2. Payables / Receivables aging — D-25 (D127)
- `lib/features/finance/aging_screen.dart` (`/finance/aging`):
  supplier payables and customer receivables aged with the ONE D92
  computation (`computeAging` — FIFO, payments oldest-first;
  Current / 31–60 / 61–90 / 90+ days). Per-party rows (outstanding
  only, largest first) navigate to the supplier/customer detail,
  where the statements already live. Settled parties are counted,
  not listed.
- **Unpaid POs are a memo, not a payable:** approved /
  partially-received POs are listed separately with ordered value,
  received value and remaining commitment — goods not received are
  not owed, so open POs never enter the buckets or the totals.
- Seeded demo totals (all charges Current — 28/25/15 and 20/12/8/3
  days old): payables Rs 194,250.00 (Sami 125,000 + MedServe
  48,250 + CareLine 21,000); receivables Rs 32,000.00 (Ahmed Raza
  5,500 + Fatima Khan 2,500 + cust-3 12,000 + cust-4 12,000 —
  cust-4 is 15,000 − 5,000 + a 2,000 charge).

### 3. P&L / Statements — D-26 (D128)
- `lib/features/finance/statements_screen.dart`
  (`/finance/statements`): consolidated P&L for the selected window
  (7/30/90 days) and branch (All branches or one), the same
  counters caption as Reports, CSV export of the consolidated P&L
  (`profitLossCsv`), and one statement card per branch in scope.
- **No second P&L computation:** the screen reads
  `advancedReportDataProvider` directly, and the branch cards read
  it through `branchStatementProvider` (a thin provider returning
  that provider's `profitLoss` for the same (branch, window)). The
  agreement with the Reports hub is pinned by test (same figures
  for (all, 30d), (DHA, 30d), (all, 7d), plus equality with a direct
  live `computeProfitAndLoss`).

### 4. Finance hub + routes + navigation (D124, D130)
- `lib/features/finance/finance_hub_screen.dart` (`/finance`): three
  cards (Cashbook / Payables & Receivables / P&L & Statements).
  The hub is flag-gated only — each card checks its §5.1 capability
  in the active branch and shows "No access" when the role lacks
  it (a Cashier must reach the cashbook although `financeReports`
  is `none` for them; a Regional Manager must reach the statements
  although `financeEntry` is `none` for them).
- Route gates (`routeCapability`): `/finance/cashbook` →
  `financeEntry`, `/finance/aging` + `/finance/statements` →
  `financeReports`. No new capability was invented (both rows
  already exist in the §5.1 matrix).
- Finance is the 16th module: `AppModule` + `FeatureModuleConfig`
  (`finance`), sidebar Insights group (Reports → Finance →
  Notifications), mobile More sheet via the module list, feature
  icon in `featureModuleIcon`.

### 5. Small behaviour fix found by the work (D125)
- Both `addTransaction` implementations (mock + Firestore) used to
  overwrite `createdAt` with `now`. A caller-supplied `createdAt`
  is now kept — it is the transaction's business date, so a
  backdated income entry lands on its own day's cashbook and P&L
  window instead of today's. Supplier payments and expense mirrors
  pass `now` explicitly, so their behaviour is unchanged.

### 6. Older tests updated for the new reality (not regressions)
- `test/day_02_test.dart`: sidebar test 15 → **16 modules**,
  'Finance' after 'Reports' in the sidebar order.
- `test/day_07_test.dart`: route walk 15 → **16 modules** (+ the 4
  finance routes); feature-toggle count 11 → **12** modules.
- `test/week3_day04_test.dart`: the "remaining missing desktop
  screens" test drops `/finance` — D-24/D-25/D-26 are closed, the
  remaining missing are D-28 / D-33 / D-35.

## Verification
- `flutter analyze`: **clean — no issues**.
- Day tests `test/week4_day03_test.dart`: **34/34** — aging
  boundaries + FIFO, cashbook union + validation, closing totals /
  opening / duplicate / future / stale, recordIncome (gate +
  backdated date), closeDay (totals, opening carry, duplicate /
  future / gate), P&L agreement (3 windows/branches + live
  computation), aging aggregates (seeded ledgers), mapper +
  Firestore repo on the fake transport, and 11 widget tests (route
  walk, hub cards + cashier lock-out, seeded cashbook + aging
  totals, add-entry + close-day end to end, aging → supplier
  detail, statements rendering, sidebar entry, 5 gate tests).
- Full suite: **615/615** (581 + 34 new, no earlier test touched
  except the three intentional updates above).
- Fresh `flutter build web --release`: **pass** (183.3s,
  46,516,062 bytes); prescription PNGs bundled at **114,613 +
  110,613 bytes**, 8 "prescription" mentions in
  `AssetManifest.bin`, both paths present.

## Decisions
- D124 — Finance hub routes + gating (hub flag-only, cards check
  capabilities, screens route-gated on the existing matrix rows).
- D125 — Income categories fixed list; income = `income` financial
  transaction (no note field); caller-supplied `createdAt` kept.
- D126 — Daily closing as a snapshot record; new `dailyClosings`
  collection; opening carried from the previous closing; stale
  flag instead of rewrites; no seeded closings.
- D127 — Aging is the one D92 computation; unpaid POs are a
  committed-spend memo, never in the buckets.
- D128 — P&L reuse through `advancedReportDataProvider` /
  `branchStatementProvider`; agreement pinned by test.
- D129 — Cashbook writes stay repo-direct (no layer sync payload
  yet); no `SyncStatusChip` on the cashbook (D108 rule).
- See `docs/technical-decisions.md`.

## Files changed
- New: `lib/models/daily_closing.dart`,
  `lib/features/finance/finance_hub_screen.dart`,
  `lib/features/finance/cashbook_screen.dart`,
  `lib/features/finance/aging_screen.dart`,
  `lib/features/finance/statements_screen.dart`,
  `test/week4_day03_test.dart`.
- Edited: `lib/models/models.dart` (export),
  `lib/core/services/repositories.dart` (interface + mock +
  provider; `createdAt` fix), `lib/core/data/repository_factory.dart`
  (bundle field + wiring), `lib/core/data/firestore_schema.dart`
  (const + contract), `lib/core/data/firestore_mappers.dart`
  (mappers), `lib/core/data/firestore_repositories.dart`
  (Firestore repo; `createdAt` fix),
  `lib/features/finance/finance_logic.dart` (income categories,
  cashbook union/validation, closing computation),
  `lib/features/finance/finance_provider.dart` (`recordIncome`,
  closings notifier, cashbook entries, branch statements, aging
  aggregates), `lib/core/routing/app_router.dart` (Finance module +
  4 routes), `lib/features/settings/feature_config.dart` (finance
  module), `lib/core/data/permission_service.dart` (3 route
  capabilities), `lib/app/shell/app_shell.dart` (Insights group +
  module count comment),
  `lib/features/settings/roles_permissions.dart` (finance icon),
  `test/day_02_test.dart`, `test/day_07_test.dart`,
  `test/week3_day04_test.dart` (intentional updates),
  `docs/week-4-tracker.md`, `docs/technical-decisions.md`.
- No new dependencies.

## Follow-ups (not in this day)
- **Layer sync payload for cashbook writes (D129):** add layer
  methods for expense/income/closing writes (D103/D111 pattern:
  single write path + idempotency key + one batched-write sync
  payload), then add the `SyncStatusChip` to the cashbook screen.
  Until then the chip stays off the screen by design.
- **Income notes:** `FinancialTransaction` carries no note field,
  so income entries record category + amount only (D125). If Hadi
  wants income notes, add a `note` field to the contract.
- **Closing corrections (FR-FIN-06):** a wrong closing is never
  edited in place — the correction flow (reversing/adjusting entry
  + new closing record) is not built; the stale flag is the
  detection, not the fix.
- **Cash reconciliation (FR-FIN-02):** the closing snapshots
  totals; there is no expected-vs-actual cash count (that is the
  `cashDrawers` drawer flow, FR-POS-10) and no variance step.
- **390px body findings (Day 5 sweep, unchanged):** `/orders`
  12px, `/billing` 133px, `/inventory` batch-row overflows — still
  open for the Day 5 sweep, not touched here. (The statements
  branch dropdown needed `isExpanded` + 280px to avoid a 177px
  overflow — fixed in this day; the cashbook screen's loading-state
  list sort crash was fixed the same way, by copying to a fresh
  growable list.)
