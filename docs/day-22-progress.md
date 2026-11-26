# Day 22 — Week 4 Day 5 Progress (26 Nov 2026)

**Scope:** the last partials + Phase 8 QA depth + final QA pass — this
closes Week 4. Split payment (D-04), medicine location + stock
history (D-10), quarantine action (D-11), adjustment approval queue
(D-14), the 390px sweep (Day 1 findings), offline-queue behaviour
tests, role-gate tests, and D129 (cashbook layer writes) — everything
in the Day 5 brief fit; nothing was left half-built.

## What shipped

### 1. Split payment — D-04 (D137)

- `Sale` gains `payments: List<SalePayment>` (method + `amountMinor`,
  int paisa). Legacy `paymentMethod` is kept as the primary method
  (largest leg); `fromMap` derives one leg for legacy docs,
  `toMap` writes the `payments` list in the SRS §3.4 shape.
  Getters: `isSplit`, `splitTotalMinor`, `creditMinor` (the khata
  entry is the credit LEG only), `cashMinor`, `hasCreditLeg`.
- Validation (`billing_logic.dart`): ≥1 leg, each > 0, no duplicate
  method, sum == total; a cash leg needs cash received ≥ the leg; a
  credit leg needs a customer + headroom for the leg only.
  Split-mode cash is exact — no change on a split sale; change only
  exists on single-method cash sales. The POS shows the remaining
  amount live and hides the cash-received / change rows in split
  mode.
- Layer `_enqueueSaleSync` writes the `payments` subcollection docs
  (`payment-$i`, new `FirestoreSchema.salePaymentsPath`); the
  receipt shows one row per leg; sales history badges use
  `salePaymentSummary` and warn on a credit leg; the provider books
  the khata entry for `sale.creditMinor` only. Single-method flow
  unchanged (13 tests, incl. the hand-built-sale regression).

### 2. Medicine location + stock history — D-10 (D138, D139)

- The Medicine model had no location field — one was added
  (`location`, shelf / bin) + `copyWith`, the schema contract, and
  the Firestore mappers round-trip it. `MedicineRepository.
  updateMedicine` is new (interface + mock + Firestore; the
  Firestore write keeps the original `createdAt`).
- **Deviation recorded (D138):** SRS §3.3 puts rack/shelf on the
  per-branch `inventory` doc, not on the master medicine. The brief
  explicitly asked for a location field on the medicine, so the
  master location is the **default shelf**; a per-branch rack/shelf
  override is a follow-up. There is still no full master edit form —
  the new dialog edits location only, gated on `medicineCrud` write.
- Stock history: the detail screen reads the engine ledger for the
  medicine + branch, newest first, paged at 10, with batch numbers
  resolved from the screen's own batch list. **Session-only, stated
  on the screen** — no seeded history exists and none was invented
  (6 tests).

### 3. Quarantine action — D-11 (D140)

- Layer `quarantineBatch` / `unquarantineBatch`: only
  `available → quarantined` and back; repo flips the status
  (`InventoryRepository.updateBatchStatus`, mock + Firestore), the
  engine reloads, one audit entry (`batch.quarantined` /
  `batch.unquarantined`, before → after + reason), one batch-doc
  sync payload, same-key retry returns the original batch.
- The guard already excluded quarantined batches (D68) — nothing
  was re-implemented; the day pins it with tests
  (`sellableStockFor` / `fefoBatchFor` / `canSellMedicine` skip
  quarantined batches; total stock still counts them).
- Buttons on the inventory batch row and the detail batch row
  (dialog with a required reason, D115 key), gated on
  `stockReceive` write — no §5.1 capability governs quarantine, so
  the closest existing stock-action capability is reused; no new
  capability invented. Distinct "Quarantined" badge on both rows.
  The return / disposal approval (FR-INV-07) is a follow-up (5 tests).

### 4. Adjustment approval queue — D-14 (D141)

- **The Adjust dialog is request-only now** — the decision recorded
  in D141: every adjustment a person files goes through the queue.
  The dialog returns the filed `StockAdjustmentRequest`; the two
  callers show "Adjustment requested — pending approval".
  `InventoryNotifier.adjustStock` / `layer.adjustStock` stay as the
  apply path (approvals + system-driven restocks like returns).
- Queue (`stock_adjustment_queue.dart`, session-only, D131 pattern):
  request (non-zero qty, reason required, decrease ≤ on-hand) →
  approve (applies through `layer.adjustStock` — ledger + audit +
  sync — with the request id as the idempotency key, and records
  the ledger movement id) / reject. Requests are not persisted to
  Firestore yet — a follow-up.
- Who may decide: holds `stockAdjustApprove` in the branch AND is
  not the requester (§5.2.4). Owner / HO Admin any branch, Branch
  Mgr own branch only, Inventory Mgr never approves, Cashier /
  Pharmacist neither. Route `/inventory/adjustments` (sidebar +
  More-sheet sub-item under Inventory) is gated on
  `stockAdjustReq`; per-row buttons apply the stricter check (6 tests).

### 5. 390px sweep — Day 1 findings fixed (D142)

- Reproduced exactly before fixing: /orders 12px (sync chip),
  /billing 133px (POS action Row) + 11/12px, /inventory 24–56px
  (every batch row). Two more found while pumping the detail
  screen: the info-card badges Row overflowed 162px, and the
  batch action Row would overflow with a third button.
- Structural fixes: chip caps its row and ellipsizes; POS action
  row stacks below 480px (Complete Sale first); dashboard order
  row stacks price above badge; inventory headers put figures +
  badges on a second line and batch actions move to a second row;
  detail badges and the three batch buttons wrap. Nothing was
  shrunk to fit the test font.
- Sweep tests cover /dashboard, /orders, /billing, /inventory and
  /medicines/:id — all print **zero** RenderFlex overflows. The
  harness drains the binding's aggregated exceptions and counts
  "RenderFlex overflowed" in the full text (5 tests).

### 6. Offline-queue behaviour tests (D143)

- Enqueue while offline → held → flush on reconnect, nothing
  lost, no double-send: a fake sender (`false` / throwing) holds
  both ops in the store; past the back-off (controllable clock)
  both flush, each sent once; a second flush sends nothing.
  `processAll` stops at the first failure by design — the first
  version of the test expected otherwise and was corrected to
  match the implementation.
- Same idempotency key enqueued twice stores one operation;
  layer writes while offline are held, then flushed; the sync
  chip reflects pending → synced on /orders (4 tests).

### 7. Role-gate tests (D144)

- One test per SRS role (all 10 `srsRoleKeys`) walks 16 routes —
  transfers, riders, finance hub, branches, audit log, backup,
  adjustments, plus billing, medicines, salary, purchases,
  reports, customers, suppliers — and asserts the gate outcome
  the matrix itself computes (`routeCapability` + `canInBranch`).
  `/riders` has no capability mapping, so every role reaches it;
  read-only still views (Auditor passes the audit-log gate,
  `canWrite` stays false). Spot checks pin Cashier / Auditor /
  Inventory Mgr (11 tests).

### 8. Cashbook layer writes — D129 closed (D145)

- Layer `recordExpense` / `recordIncome` / `recordDailyClosing`
  (D103/D111 pattern): idempotency registry per method;
  `recordExpense` creates the expense AND its mirror
  `financialTransactions` entry in the same call and enqueues one
  batched-write payload (expense doc + transaction doc); income
  and closing each enqueue one payload. The finance repos are
  optional constructor params with fresh-mock defaults on the
  `goodsReceiptRepo` precedent — older direct constructions keep
  working untouched; the app provider passes the bundle's repos.
- Notifiers keep their permission + validation and now call the
  layer, then invalidate `syncStatusProvider`. The cashbook screen
  shows the `SyncStatusChip` (D108). Supplier payments are NOT
  moved — they write three records across two repos and stay
  repo-direct (a follow-up, not smuggled into D129) (5 tests).

## What broke while building (and the fix)

- **Notifier self-invalidation:** the new `quarantineBatch` /
  `unquarantineBatch` notifier methods called
  `ref.invalidate(inventoryProvider)` from inside the notifier
  itself — Riverpod throws "A provider cannot depend on itself".
  Fixed by using the existing `_invalidateDependents()` (as
  `adjustStock` already does) after `refresh()`.
- **`permissionService.can` takes 2 args, not 3:** the new
  `canViewAdjustmentQueue` helper passed a branch — fixed to
  `canInBranch`. `AppUser` has no `copyWith` — the "second Owner"
  in tests is built via the `_userFor` helper's new `uid` param.
- **Role keys are snake_case:** `_userFor('Branch Manager')`
  resolves to no matrix row (the demo role is 'Branch Mgr'), so
  the D-14 tests use the SRS keys (`branch_manager`,
  `inventory_manager`, …). Display names only worked for Owner /
  Cashier by accident of the fallback in `roleDisplayName`.
- **SnackBar queueing in tests:** the approve SnackBar queues
  behind the earlier "Adjustment requested" SnackBar, which never
  dismisses under fake time — the test now pumps 5s first.
- **Dialog default is Increase:** the widget approve test filed a
  +2 request while asserting −2 — it now taps 'Decrease' first.
- **Receipt cash-rows gate (real bug, D137):** the receipt text
  and the receipt screen gated the "Cash received / Change" rows
  on `sale.cashMinor` (derived from the `payments` legs) — but a
  Sale built by the constructor carries no legs, so the rows
  vanished for a hand-built cash sale (caught by the old day_06
  receipt test). The rows describe the cash actually handed over,
  so both now gate on `sale.cashReceivedMinor > 0`. Regression
  test added to the Day 5 suite.
- **Old day_05 adjust test updated (D141):** the Day 5 "adjust
  stock from medicine detail updates quantity" test drove the
  dialog and expected an immediate quantity change — that flow no
  longer exists. It now taps "Submit request" and expects
  "Adjustment requested — pending approval" (and asserts the
  quantity does NOT change).
- **Four old test fakes** (`day_05`, `day_06`, `week2_day02`,
  `week3_day05`) implemented `InventoryRepository` and missed the
  new `updateBatchStatus` — each gained the stub (throw /
  delegate, matching its neighbours). No other old test's
  assertions changed.

## Verification

- `flutter analyze` — **No issues found!**
- Day 5 tests (`test/week4_day05_test.dart`) — **55/55 passed**
  (split 13, D-10 6, D-11 5, D-14 6, offline 4, role gates 11,
  D129 5, sweep 5)
- Cumulative full suite — **709/709 passed** (654 + 55 new; Week 4
  alone 162 = 6 + 27 + 34 + 40 + 55)
- Fresh `flutter build web --release` — **✓ Built build/web**
  (182.5s compile, 46,614,266 bytes)
- Prescription PNGs — both in
  `build/web/assets/assets/images/prescriptions/` at **114,613 +
  110,613 bytes**, 8 "prescription" mentions in the decoded
  `AssetManifest.bin`, both sample paths present.
- No new dependencies.

## Files changed

- New: `lib/features/inventory/adjustment_queue_screen.dart`,
  `lib/features/inventory/stock_adjustment_logic.dart`,
  `lib/features/inventory/stock_adjustment_queue.dart`,
  `lib/features/medicines/medicine_edit_dialog.dart`,
  `lib/models/stock_adjustment_request.dart`,
  `test/week4_day05_test.dart`
- Modified: `lib/models/sale.dart`, `lib/models/medicine.dart`,
  `lib/core/data/firestore_schema.dart`,
  `lib/core/data/firestore_mappers.dart`,
  `lib/core/data/firestore_repositories.dart`,
  `lib/core/data/production_data_layer.dart`,
  `lib/core/data/permission_service.dart`,
  `lib/core/routing/app_router.dart`,
  `lib/core/services/repositories.dart`,
  `lib/core/widgets/sync_status_widget.dart`,
  `lib/features/billing/billing_logic.dart`,
  `lib/features/billing/billing_provider.dart`,
  `lib/features/billing/pos_screen.dart`,
  `lib/features/billing/receipt_screen.dart`,
  `lib/features/billing/sales_history_screen.dart`,
  `lib/features/dashboard/dashboard_screen.dart`,
  `lib/features/finance/cashbook_screen.dart`,
  `lib/features/finance/finance_provider.dart`,
  `lib/features/inventory/inventory_provider.dart`,
  `lib/features/inventory/inventory_screen.dart`,
  `lib/features/inventory/stock_operation_dialogs.dart`,
  `lib/features/medicines/medicine_detail_screen.dart`,
  `lib/features/settings/feature_gate.dart`,
  `lib/app/shell/app_shell.dart`,
  `test/day_05_test.dart`, `test/day_06_test.dart`,
  `test/week2_day02_test.dart`, `test/week3_day05_test.dart`
  (fake-repo stubs only), `docs/technical-decisions.md` (D137–D145)

## Follow-ups (Week 5)

- **Per-branch rack/shelf override** (D138): the master location
  is the default shelf; the SRS §3.3 per-branch `inventory` rack /
  shelf fields are not modelled yet.
- **Full medicine master edit form** (D138): the dialog edits
  location only; name / prices / barcode / category still have no
  edit UI.
- **Quarantine return / disposal approval** (D140, FR-INV-07):
  quarantining only parks the batch; the supplier-return or
  disposal step with its approval is not built.
- **Adjustment queue persistence** (D141): the queue is
  session-only; Firestore persistence (collection + rules +
  notifier re-read) is a follow-up.
- **Supplier payments through the layer** (D145): three records
  across two repos, still repo-direct in their notifier.
- **POS wiring for the Settings config** (D134/D136 follow-up,
  carried): payment-method picker, discount caps, receipt
  width/footer are config-only until the POS reads them.
- **Branch repository + FR-HO-08 enforcement, restore into live
  repos, franchise commission/royalty tracking** (carried from
  Day 4).
