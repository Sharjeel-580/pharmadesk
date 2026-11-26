# Day 26 Progress — Feature completion, part 2 (Week 5 Day 4)

**Date:** 26 Nov 2026. **Scope:** quarantine return/disposal approval
(FR-INV-07, D140 follow-up); POS wiring for the org Settings config
(D134/D136 follow-up); closing corrections (FR-FIN-06) + cash
reconciliation (Week 4 Day 3 follow-ups). Decisions D154, D155, D156,
D157 in `docs/technical-decisions.md`.

## What changed

### 1. Quarantine return / disposal approval (D154 — FR-INV-07, closes the D140 follow-up)
- `lib/models/inventory_item.dart` — `BatchStatus.disposed` + parser
  case + `isDisposed` / `isReturned` getters. Return → status `returned`
  + quantity 0 (leaves stock); dispose → status `disposed`, quantity kept
  as the destroyed count (like expired) — excluded from saleable stock by
  the existing D68 `isBatchSellable` guard, no guard change needed.
- `lib/models/quarantine_outcome_request.dart` (new) —
  `QuarantineOutcome {returnToSupplier, dispose}`,
  `QuarantineOutcomeStatus {pending, approved, rejected}`,
  `QuarantineOutcomeRequest` (id `qo-N`, batch/medicine/branch, outcome,
  reason, `quantityAtRequest`, requester, decided-by/at/note; `toMap` /
  `fromMap` / `copyWith`).
- `lib/features/inventory/quarantine_outcome_logic.dart` (new) —
  `validateQuarantineOutcomeRequest` (reason required);
  `canApproveQuarantineOutcome` (approver ≠ requester AND
  `canWrite(stockAdjustApprove, branchId)`, D141 separation of duties,
  §5.2.4); `canViewQuarantineOutcomeQueue` (`stockAdjustReq`).
- `lib/features/inventory/quarantine_outcome_queue.dart` (new) —
  session-only notifier (D141 posture), `requestOutcome` / `approveOutcome`
  (layer call with idempotency key `quarantine-outcome-<requestId>`,
  invalidates inventory + sync chip) / `rejectOutcome` (batch stays
  quarantined).
- `lib/core/data/production_data_layer.dart` —
  `applyQuarantineOutcome` (dedupe registry first, then the FR-HO-08
  `_requireBranchActive` guard, requires status `quarantined`; return uses
  `upsertInventoryItem` with qty 0, dispose uses `updateBatchStatus`;
  engine reload; audit `batch.returned` / `batch.disposed` with reason +
  qty + approver; one sync payload via `_enqueueBatchStatusSync`, which
  gains an optional `quantity` param, included only when non-null).
- `lib/features/inventory/stock_operation_dialogs.dart` —
  `showQuarantineOutcomeDialog` (outcome text differs return vs dispose,
  reason required, keys `quarantine-outcome-reason-field` /
  `quarantine-outcome-confirm`).
- `lib/features/inventory/quarantine_outcome_screen.dart` (new) —
  `QuarantineOutcomeScreen`, route `/inventory/quarantine-outcomes`,
  status filter chips, `PagedList` at 10, pending first, approve/reject
  with optional note dialog, `SyncStatusChip`.
- Actions where the quarantine buttons already live, no new capability —
  the existing `stockReceive` write gate (D140): inventory rows get Return
  (`inv-return-<id>`) + Dispose (`inv-dispose-<id>`) IconButtons on
  quarantined rows, and the medicine detail screen gets Return/Dispose
  `PharmaButton`s next to Restore; batch badges now show `Disposed`
  (danger) / `Returned` (info) first.
- Routing/nav: `app_router.dart` adds the route with `FeatureGate`;
  `permission_service.dart` maps it to `stockAdjustReq`; `app_shell.dart`
  adds the sidebar sub-item (gated on `canViewQuarantineOutcomeQueue`)
  and the More-sheet entry (gated on the existing
  `canViewAdjustmentRecords`).

### 2. POS wiring for org Settings config (D155 — D134/D136 follow-up)
- `lib/features/billing/billing_logic.dart` — `posPaymentMethods(OrgSettings)`
  returns `[cash, card, credit]` in that order, filtered by the enabled
  set; bankTransfer / JazzCash / Easypaisa are recorded-only methods with
  no POS settlement flow and never appear. `cappedLineDiscountMinor` /
  `cappedBillDiscountMinor` (`null` cap = unchanged, never above
  gross/subtotal). `validateSale` gains optional `maxLineDiscountPercent` /
  `maxBillDiscountPercent` (integer cross-multiplication check; the error
  names the configured maximum). `receiptText` gains `receiptFooter = ''`
  and `receiptPaperWidthMm = 80` (32-dash separator at 80mm, 24 at 58mm;
  footer appended before the DEMO line when non-empty).
- `lib/features/billing/billing_provider.dart` — `completeSale` passes the
  cap params through to `validateSale`.
- `lib/features/billing/pos_screen.dart` — split-payment legs only for
  offered methods; line/bill discounts clamp through the cap helpers; the
  effective method is the selected one if still offered, else the first
  offered; empty offered set → checkout error and Complete Sale disabled;
  the payment `SegmentedButton` is built dynamically from the offered
  methods (key `pos-payment-methods`). Every default keeps today's
  behaviour — no rate or limit invented.
- `lib/features/billing/receipt_screen.dart` — watches
  `orgSettingsProvider`, passes footer + width to `receiptText`; the
  preview card is centred in a `ConstrainedBox` (320px at 80mm, 240px at
  58mm) with the footer text and a `Receipt paper: Nmm` caption. The DEMO
  badge is wrapped in `FittedBox(scaleDown)` — the narrower card made it
  overflow by 48px in the day_06 receipt tests (regression fix, same
  commit).
- Known boundary, unchanged: the POS tax rate is still read once in
  `initState` (D136) — a settings change while the POS is open does not
  update the tax rate live; payment methods ARE live-watched in `build`.

### 3. Closing corrections (D156 — FR-FIN-06)
- `lib/models/closing_correction.dart` (new) — `ClosingCorrection`
  (append-only reversing entry: `originalClosingId`, corrected income /
  expense / closing-balance, reason, corrected-by/at, note; `toMap` /
  `fromMap` use `correctedIncome` / `correctedExpense` /
  `correctedClosingBalance`).
- `lib/features/finance/finance_logic.dart` —
  `validateClosingCorrection` (original must exist, totals ≥ 0, reason
  required); `adjustedClosingTotals` (original totals when uncorrected;
  latest correction wins by `correctedAt`, ties by list order;
  corrections for other closings ignored).
- Repos: `ClosingCorrectionRepository` + `CashReconciliationRepository`
  interfaces and mocks (`cc-N` / `cr-N`, append-only) in
  `repositories.dart`; Firestore impls in `firestore_repositories.dart`
  (D101 pattern), mappers in `firestore_mappers.dart` (stamp +
  `validateOrThrow`), collection consts + contract docs in
  `firestore_schema.dart` (`closingCorrections`, `cashReconciliations`),
  wired into `RepositoryBundle` in `repository_factory.dart`.
- `lib/core/data/production_data_layer.dart` —
  `recordClosingCorrection` (audit `closing.corrected`, one sync payload,
  entityType `closingCorrection`) with the `_committedCorrectionKeys`
  idempotency registry.
- `lib/features/finance/finance_provider.dart` —
  `ClosingCorrectionsNotifier` / `closingCorrectionsProvider`:
  `correctClosing` gated on `financeEntry`, derives
  `correctedClosingBalanceMinor = opening + income − expense` (the caller
  never supplies a balance), refresh + sync-chip invalidate.
- `lib/features/finance/cashbook_screen.dart` — closings rows show the
  original totals, a stale flag, and (when corrected) the adjusted figures
  + reason, with a "Correct closing" / "Correct again" button (key
  `correct-closing-<id>`) when the user may write; `_CorrectClosingDialog`
  prefills from `adjustedClosingTotals` (fields `correct-income-field` /
  `correct-expense-field` / `correct-reason-field`, confirm
  `correct-closing-confirm`).

### 4. Cash reconciliation (D157)
- `lib/models/cash_reconciliation.dart` (new) — `CashReconciliation`
  (branch, date, `expectedMinor`, `countedMinor`, `differenceMinor`,
  note, counted-by/at; `toMap` / `fromMap` use `expected` / `counted` /
  `difference`; getters `isExact` / `isOver` / `isShort`).
- `lib/features/finance/finance_logic.dart` — `expectedDrawerMinor` =
  opening + cash sales (`Sale.cashMinor` — every sale carries legs per
  D137, so single-method cash counts in full, split counts the cash leg
  only) + cashbook income − cashbook expenses, date-filtered. Documented
  limitation: card/credit sales are excluded by design; cash supplier
  payments and sale-return cash refunds are NOT in the figure (supplier
  payments are not cashbook entries; no cash refund is modelled yet) —
  they show up as a difference to investigate, not a silently adjusted
  expectation. `cashReconciliationDifference` (counted − expected);
  `validateCashReconciliation` (counted ≥ 0, date not future).
- `lib/core/data/production_data_layer.dart` —
  `recordCashReconciliation` (audit `cash.reconciled`, entityType
  `cashReconciliation`) with the `_committedReconciliationKeys` registry.
- `lib/features/finance/finance_provider.dart` —
  `CashReconciliationsNotifier` / `cashReconciliationsProvider`:
  `reconcileDay` gated on `financeEntry`, reads sales/expenses/
  transactions/closings fresh from the repos and computes the expected
  drawer via `expectedDrawerMinor` (reads `saleRepositoryProvider`
  directly — no `billing_provider` import, avoids a cycle).
- `lib/features/finance/cashbook_screen.dart` — reconciliation section
  after the closings: expected-drawer row, the "card/credit never touch
  the drawer" explanation, counted field (`recon-counted-field`), note
  field (`recon-note-field`), Record button (`recon-record`, gated on
  `mayWrite`) with an "exact match" / "Rs X over" / "Rs X short" snackbar,
  and `_ReconciliationRow` entries (date, expected/counted, difference).
  The button label is "Record count", not "Record drawer count": the
  full-width button inside the card is 310px at 390px width and the longer
  label overflowed it by 41px (test font renders labels wide).

## Regression fixes found while verifying (same commit)
- Receipt DEMO badge `FittedBox` (D155, above) — the 320px preview card
  broke 4 day_06 receipt tests.
- `test/week3_day05_test.dart` sidebar test: the sidebar `ListView`
  builds lazily, and the new Quarantine Outcomes row pushed "Salary"
  below the 1080px fold. The sidebar `ListView` gained the key
  `app-sidebar-list`; the test now scrolls to each item with the file's
  own `scrollListToTitle` helper before asserting.
- `test/week4_day03_test.dart` cashbook test: the unscoped
  `find.byType(TextFormField).first` now resolves to the new drawer-count
  field behind the dialog (it precedes the dialog's fields in tree
  order), so the "5000" went into the screen, not the dialog. The finder
  is now scoped to the `AlertDialog` descendant.
- Test-author lessons (both hit in this day's widget tests): snackbar
  assertions are timing-sensitive — `ScaffoldMessenger` queues snackbars
  and `pumpAndSettle` does not advance the 4s timer, so a snackbar behind
  another one never surfaces during the test. Day 26 widget tests assert
  persistent state instead (queue status, reconciliation row). And
  off-screen fields need `ensureVisible` before `enterText`, or the text
  never lands.

## Verification
- `flutter analyze`: **No issues found!**
- Day tests `test/week5_day04_test.dart`: **40/40** — D154 approval
  rules (5), D154 layer (3), D154 queue notifier (3), D154 widgets at
  390px/1024px (2), D155 pure functions (7), D155 provider + widgets
  (4), D156 pure logic (2), D156 layer + notifier (5), D157 pure logic
  (3), D157 layer + notifier (5), D156+D157 cashbook widgets at 390px
  (1).
- Full suite `flutter test`: **822/822** (baseline 782 + 40 new).
- `flutter build web --release`: **pass** — `build/web` 46,717,515 bytes;
  prescription PNGs still bundled in
  `build/web/assets/assets/images/prescriptions/`
  (`sample-prescription-1.png` 114,613 bytes,
  `sample-prescription-2.png` 110,613 bytes, same sizes as Days 23–25).
- 390px: 0 RenderFlex overflows in the Day 4 widget tests (drained
  exceptions); the two overflows found during verification (receipt DEMO
  badge 48px, "Record drawer count" 41px) are fixed in this commit.

## Follow-ups (not in this day)
- Quarantine outcome queue is session-only (D141 posture); Firestore
  persistence (`branches/{branchId}/quarantineOutcomes`, D146 pattern)
  is a follow-up — the outcome itself IS persisted on the batch row.
- Finance writes (`recordExpense` / `recordIncome` /
  `recordSupplierPayment` / closings, and now corrections/reconciliations)
  are still not FR-HO-08-guarded (D149 boundary, carried from Day 24).
- Expected drawer deliberately excludes cash supplier payments and
  sale-return cash refunds (documented in `finance_logic.dart`).
- POS tax rate is read once in `initState` (D136) — a settings change
  while the POS is open does not update the tax rate live; payment
  methods are live-watched.
- Day 27: FR-HO-07 franchise commission/royalty + Phase 8 QA depth.
