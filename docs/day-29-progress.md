# Day 29 Progress — Week 6 Day 2: Payment idempotency, D115 dialog-held key (D162)

**Date:** 26 Nov 2026. **Status:** done.

## What changed

The Week 5 Day 23 follow-up: the production data layer minted a fresh
idempotency key per `recordPayment` call, so a UI double-tap on a
payment dialog could still create two payments. The layer already
accepted an optional key — the finance notifiers just never passed
one. This day applies the D115 dialog-held-key pattern to the
cashbook + supplier-payment dialogs together.

### 1. Dialogs — one key per dialog lifetime
- `_CashbookEntryDialog` (`lib/features/finance/cashbook_screen.dart`):
  `late final _idempotencyKey = newIdempotencyKey('finance-entry-<branchId>')`,
  passed to `recordIncome` / `recordExpense` on every submit. One key
  serves both sides of the dialog — the layer keeps separate
  registries for income and expense keys, so the shared key can never
  dedupe an income against an expense.
- `_ExpenseDialog` (`lib/features/reports/reports_screen.dart`): same
  pattern, `finance-expense-<branchId>`, passed to `recordExpense`.
  (Second cashbook-payment dialog — the expense entry from Reports.)
- `_LedgerEntryDialog` (`lib/features/suppliers/supplier_detail_screen.dart`):
  `supplier-payment-<supplierId>`, passed to `recordPayment` only on
  its payment branch. The purchase / purchase-return / adjustment
  branches write ledger-only entries through a different notifier and
  are out of scope.

A fresh dialog instance mints a fresh key, so two separate dialogs
are two payments. The notifier never mints or holds a key of its own.

### 2. Notifiers — accept + forward the key
`lib/features/finance/finance_provider.dart`:
- `ExpensesNotifier.recordExpense`, `FinancialTransactionsNotifier.recordIncome`,
  `SupplierPaymentsNotifier.recordPayment` each gain an optional
  `String? idempotencyKey`, forwarded to the layer call. Omitted, the
  layer mints a fresh key per call (pre-D162 behaviour, unchanged).
- **Supplier shortcut (the one place forwarding alone was not
  enough):** `SupplierPaymentsNotifier` re-validates against the LIVE
  outstanding before calling the layer, and the first submit already
  reduced that outstanding — so a same-key double-submit of a full
  MedServe settlement (Rs 48,250) would have failed validation
  ("cannot exceed the outstanding payable") instead of returning the
  original. The notifier remembers completed dialog-held keys for the
  session (`_completedPaymentsByKey`, the D65 auto-PO pattern) and,
  after the permission check and before any live-state validation,
  returns the already-created payment on a repeat. Expense/income
  need no such map: their validation is static, so the layer registry
  dedupes them directly. The shortcut is session-scoped; the layer
  registry remains the durable dedupe for direct layer callers.

### 3. Drive-by fix — income category dropdown overflow (pre-existing)
The cashbook entry dialog's category dropdown overflowed by 87px at
390px in income mode: the long first income category ('Owner
contribution') in a `DropdownButtonFormField` without `isExpanded`
(the exact trap D153 fixed in the medicine form). Reproduced on the
pre-change code via `git stash` + probe test — not caused by this
day. Fixed with `isExpanded: true` on that one dropdown; probe
re-run clean. The Reports expense dialog needs no such fix (all
expense categories are short).

### 4. Untouched
- The layer's idempotency registry semantics and the D149/D161
  deactivation guard behaviour — a refused write on a deactivated
  branch is still refused; a duplicate retry still returns the
  original (pinned by test, both paths).
- `PurchasesNotifier.recordSupplierPayment` (ledger-only quick
  payment, no payment record — same exclusion as D147/D161).
- POS sale, adjustments, closings, corrections, reconciliations —
  no dialog-held key added; out of scope for this day.

## Files changed
- `lib/features/finance/finance_provider.dart` — optional `idempotencyKey`
  on the three notifier methods + forward to the layer; supplier
  completed-key shortcut map.
- `lib/features/finance/cashbook_screen.dart` — dialog-held key in
  `_CashbookEntryDialog` (both submit branches) + `isExpanded: true`
  on the category dropdown.
- `lib/features/reports/reports_screen.dart` — dialog-held key in
  `_ExpenseDialog`.
- `lib/features/suppliers/supplier_detail_screen.dart` — dialog-held
  key in `_LedgerEntryDialog` (payment branch only).
- `test/week6_day02_test.dart` — new, 15 tests.
- `docs/day-29-progress.md` — this file.
- `docs/week-6-tracker.md` — Day 29 section updated.
- `docs/technical-decisions.md` — D162.

## Decisions
- **D162** (see `docs/technical-decisions.md`): D115 dialog-held key
  for the three payment dialogs; notifier forwards the key; supplier
  notifier remembers completed keys (D65 pattern) because its live
  outstanding validation would otherwise reject the retry; guard
  ordering unchanged; `isExpanded` drive-by fix for the income
  dropdown.

## Verification (measured, this run)
- `flutter analyze` — **No issues found!**
- Day 29 tests alone (`test/week6_day02_test.dart`) — **15/15 passed**
  - Cashbook double-submit: expense same key twice → same id, 1
    expense, 1 mirror transaction, 1 sync payload; income same key
    twice → same id, 1 transaction, 1 sync payload; two different
    keys → 2 expenses.
  - Supplier double-submit: partial Rs 10,000 same key twice → same
    id, 1 payment, outstanding Rs 48,250 → Rs 38,250, aging total ==
    ledger sum == Rs 38,250, 1 ledger payment entry (−Rs 10,000), 1
    supplierPayment transaction, 1 sync payload; full Rs 48,250
    settlement same key twice → same id, 1 payment, outstanding 0,
    aging 0 (the validation-trap case); two different keys → 2
    payments, outstanding reduced by both.
  - Guard: expense + supplier payment with a held key on a
    deactivated branch → `deactivated` + `FR-HO-08` error, nothing
    written; duplicate retry after deactivation returns the original
    for both paths (expense via layer registry, supplier payment via
    the notifier shortcut), still 1 payment, outstanding still 0.
  - Regression (no key): expense twice → 2 expenses, income twice →
    2 transactions, supplier payment twice → 2 payments (outstanding
    reduced by both) — the pre-D162 behaviour, documented in the
    test file header.
  - UI: cashbook dialog opened twice at 390px → 1 expense + 1 income
    entry; supplier payment dialog opened twice at 800px → 2
    payments, outstanding Rs 33,250, aging agrees.
- Full cumulative suite (Weeks 1–6) — **905/905 passed** (890 + 15).
- Fresh `flutter build web --release` — pass (46,728,010 bytes);
  prescription PNGs bundled (114,613 + 110,613 bytes, 8 manifest
  mentions, both sample paths present).
- Two test-author notes: the seeded MedServe ledger already holds
  one payment entry (`sled-3`, −Rs 11,750), so payment-entry
  assertions compare against a before-count / filter by amount,
  never assume zero; the supplier detail screen itself has
  pre-existing 390px overflows (see follow-ups), so its widget test
  runs at 800px.

## Follow-ups found (not built — other days / Dazy-only)
- **Supplier detail screen overflows at 390px (pre-existing, not
  caused by this day):** the payable-aging badges in `_AgingChips`
  overflow by 63px in the test font, and the Export-statement row
  overflows by 0.2px (`supplier_detail_screen.dart:229`). The screen
  was never in a 390px sweep (D142/D160 covered other screens). Its
  widget test therefore runs at 800px. Fix belongs to the Day 32
  QA-depth day (390px sweep re-run), not this idempotency day.
- **Notifier shortcut is session-scoped:** a supplier-payment retry
  with a dialog-held key returns the original only within the same
  notifier instance; a fresh app session has no dialog to retry
  from, and direct layer callers are covered by the layer registry.
  No action needed.
- Day 30 (ActiveBranchNotifier directory branches) is still open.
