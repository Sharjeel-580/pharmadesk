# Day 28 Progress — Week 6 Day 1: FR-HO-08 guard on finance writes (D161)

**Date:** 26 Nov 2026. **Status:** done.

## What changed

The D149 deactivation guard (Week 5 Day 2) covered the ten stock/sale
write paths but explicitly left finance writes out ("money writes, not
sales / purchases / stock movements — a follow-up"). This day closes
that boundary: all six finance writes in the production data layer are
now guarded with the **same** guard, in the **same** position, raising
the **same** error.

### 1. Layer — `lib/core/data/production_data_layer.dart`
- `recordExpense`, `recordIncome`, `recordSupplierPayment`,
  `recordDailyClosing`, `recordClosingCorrection`,
  `recordCashReconciliation` each call `_requireBranchActive(...)`
  after the idempotency-duplicate early return and before the first
  write. A deactivated branch throws
  `ArgumentError('Branch "<name>" is deactivated and cannot transact
  (FR-HO-08) — reactivate it in Branch Management first.')`.
  Nothing is written, no money moves, no audit entry, no sync payload.
- For `recordSupplierPayment` the guard also sits before the
  amount/allocation validation (a refusal on a deactivated branch is
  the guard's error, not a shape error's).
- The `_requireBranchActive` doc comment now lists the finance writes
  (D161). The guard function itself is untouched, so the ten D149
  stock/sale paths behave exactly as before.
- Unknown branch ids are still NOT refused (D149 posture): the
  directory is the source of truth, an unseen id cannot be
  known-deactivated.

### 2. Notifiers — `lib/features/finance/finance_provider.dart`
- **Found gap:** D149's entry said "the notifiers' existing
  `on ArgumentError` handlers surface it" — true for the stock/sale
  notifiers, but the six finance notifiers had NO such handler: they
  return `(record, error)` tuples and called the layer bare, so a
  layer refusal would have escaped as an uncaught exception and never
  reached the UI. All six methods now wrap the layer call in
  `try { … } on ArgumentError catch (error) { return (…, error:
  error.message?.toString()); }` (the `suppliers_provider.dart`
  pattern): `recordExpense`, `recordIncome`, `recordPayment`,
  `closeDay`, `correctClosing`, `reconcileDay`. Permission and
  validation checks still run first and return their own errors.

### 3. UI — no screen changes needed
- Every caller already renders `result.error`: the cashbook entry
  dialog, close-day and correction dialogs via `PharmaErrorBox`
  (dialog stays open); the reconciliation section via snackbar; the
  supplier-payment dialog via error box; the reports-screen expense
  dialog via error box. Verified by inspection + two widget tests
  (see below).

## Files changed
- `lib/core/data/production_data_layer.dart` — 6 guard calls + doc comment.
- `lib/features/finance/finance_provider.dart` — 6 try/catch wraps.
- `test/week6_day01_test.dart` — new, 18 tests.
- `docs/day-28-progress.md` — this file.
- `docs/week-6-tracker.md` — Day 28 section updated.
- `docs/technical-decisions.md` — D161.

## Decisions
- **D161** (see `docs/technical-decisions.md`): same guard / position /
  error as D149; duplicate retry still returns the original; unknown
  ids not refused; notifier ArgumentError → error string; no new UI
  code because all callers already render `result.error`.
- **Not in scope (untouched):** the ten D149 stock/sale paths;
  `PurchasesNotifier.recordSupplierPayment` (ledger-only quick
  payment, no payment record — same exclusion as D147); D115
  dialog-held-key idempotency (Day 29); everything else in the Week 6
  brief.

## Verification (measured, this run)
- `flutter analyze` — **No issues found!**
- Day 28 tests alone (`test/week6_day01_test.dart`) — **18/18 passed**
  - Layer: 6 refusals (one per write, with repo/audit counts
    unchanged) + expense duplicate retry + supplier-payment duplicate
    retry (full Rs 48,250 settlement, still 1 payment, outstanding
    still 0) + unknown branch id not refused + reactivate writes again
    = 10 tests.
  - Notifiers: all 6 methods return the deactivation error string
    (containing `deactivated` + `FR-HO-08`) with nothing written = 6 tests.
  - UI (390px): cashbook entry dialog shows the refusal and stays
    open; reconciliation snackbar shows the refusal = 2 tests.
- Full cumulative suite (Weeks 1–6) — **890/890 passed** (872 + 18).
- Fresh `flutter build web --release` — pass; prescription PNGs
  bundled (114,613 + 110,613 bytes).
- Two test-author notes: the mock expense repo is seeded (5 DHA
  expenses), so "writes nothing" assertions compare against a
  before-count, never 0; the mock supplier-payment repo starts empty,
  the mock reconciliation repo starts empty.

## Follow-ups found (not built — other days / Dazy-only)
- None new. Day 29 (D115 dialog-held-key idempotency) is still open
  and separate: a UI double-tap on a finance dialog can still mint
  two keys — this day's guard does not change that.
