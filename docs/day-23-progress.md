# Day 23 — Week 5 Day 1 Progress (26 Nov 2026)

**Scope:** data-layer completion, part 1 — the two Week 4
follow-ups: adjustment-queue Firestore persistence (D141) and
supplier payments through the production data layer (D145).
Both are wiring moves: no computation, no screen redesign, no
new capability — the queue becomes durable and supplier payments
go through the same layer pattern as the cashbook.

## What shipped

### 1. Adjustment-queue persistence — D141 closed (D146)

- **Collection contract (`firestore_schema.dart`):**
  `branches/{branchId}/stockAdjustments/{id}` — new collection,
  not in the SRS §3 list (the SRS names the approval flow but
  gives it no collection). Doc id = request id (`adj-N`, also the
  idempotency key for the approval apply). Fields: batch / medicine
  (denormalized, as before), signed `deltaQty`, `reason`,
  requester + `requestedAt`, `status` (pending / approved /
  rejected), decision stamps + `movementId`. Path builders
  `stockAdjustmentsPath` / `stockAdjustmentDocPath`.
- **Repository (`StockAdjustmentRequestRepository`, D73/D118
  pattern):** `getRequests` / `getById` / `saveRequest` — one
  upsert for filing AND deciding (a re-save overwrites the same
  doc, never a duplicate, D65). Mock starts empty (requests only
  arise from filing); Firestore impl over the transport
  (`createdAt` preserved on rewrite, branch fan-out on
  null-branch reads). Joins the `RepositoryBundle` + provider
  like the Day 3 repos. The model gains `toMap` / `fromMap`
  (`status` is the enum name, dates are Timestamps) and the
  mappers round-trip through them.
- **Rules (`firebase/firestore.rules`):** new
  `stockAdjustments` block mirroring the batch rule — read
  in-branch; create/update for the requester ∪ approver roles
  (Owner / HO Admin / Branch Mgr / Inventory Mgr); `deltaQty`
  an int ≠ 0; `status` in pending / approved / rejected; never
  deleted. Branch isolation intact — no rule weakened.
  (`supplierPayments` already had its block; no change needed.)
- **Layer (`fileAdjustmentRequest` / `loadAdjustmentRequests` /
  `updateAdjustmentRequest`, D103/D111 pattern):** filing
  persists the request + enqueues one sync payload (the request
  doc); the registry is keyed by request id, and a re-file first
  checks the store (`getById`) so a fresh layer instance (e.g.
  after an app restart) dedupes instead of writing a second doc
  or payload. Decisions persist via `updateAdjustmentRequest`
  (one update payload). The repo is an optional constructor param
  with a fresh-mock default, so older direct constructions keep
  working untouched.
- **Notifier re-read:** `build()` starts `refresh()` and the
  mutating methods await that load first, so ids are minted past
  the persisted sequence and decisions never act on a stale empty
  state. `refresh()` merges persisted ∪ in-memory (persisted
  wins, except an in-memory decided copy over a still-pending
  persisted one — the interleave where the decision persist
  failed; the next decision write repairs it). Filing persists
  BEFORE the state updates; approve/reject persist the decision
  BEFORE the state updates — a retry after a failed decision
  persist replays the apply as a duplicate (no second stock move,
  D111) and then persists.
- **Semantics unchanged:** request validation, approver ≠
  requester (§5.2.4), re-validation at approval time (request
  stays pending when stock moved), request id as idempotency key.
  Approve now enqueues 3 payloads (file + apply + decision)
  where D141 enqueued 1 (apply only) — pinned by test, not a
  regression.
- **`requestAdjustment` / `rejectAdjustment` are `async` now:**
  the Adjust dialog, the queue screen and the two D-14 tests were
  updated to await them — the only intentional old-test changes
  this day.

### 2. Supplier payments through the layer — D145 closed (D147)

- **Layer method (`recordSupplierPayment`, D145 pattern):** one
  call writes the same three records in the same order with the
  same values as the old repo-direct path — payment, negative
  supplier-ledger entry (same reason text: `Payment made —
  <method>` + optional reference, or the caller's reason),
  `financialTransactions` entry of type `supplierPayment` — and
  enqueues one batched-write payload holding all three docs. The
  idempotency key (minted per call when omitted) is the payment
  record's id (D65, like receipts); the registry returns the
  original payment + ledger + transaction on retry — no money
  moves twice. The layer re-checks the shape it owns (positive
  amount, allocations sum to it); the notifier still owns
  permission + outstanding + allocation computation.
- **Numbers unchanged (wiring move, not a computation change):**
  pinned equal to the old path's week2_day05 figures — MedServe
  Rs 48,250 settled in full, allocation `sled-2`, ledger entry
  −4,825,000 paisa with balance 0, transaction −4,825,000 paisa,
  outstanding + aging total 0 after payment.
- **Mock alignment:** `MockSupplierPaymentRepository.createPayment`
  now honours a caller-supplied non-empty id (D65 — retry returns
  the original), like `MockStockTransferRepository` and the
  Firestore impl already did; an empty id still gets `spay-N`.
  No test asserted a mock-assigned id, so no old test changed.
- **Notifier:** `SupplierPaymentsNotifier.recordPayment` keeps
  permission + validation and now calls the layer, then
  invalidates `syncStatusProvider` too (D145 pattern — the chip
  moves for supplier payments).
- **Out of scope (deliberate):**
  `PurchasesNotifier.recordSupplierPayment` writes one ledger
  entry only (a PO-flow quick payment, no payment record) — it is
  not a three-record payment and stays repo-direct.

## What broke while building (and the fix)

- **Rebuild test read the state before the load landed:**
  `container.invalidate(provider)` rebuilds lazily, so the first
  read after it returns the empty `build()` state — the test now
  reads once (triggering the rebuild + load) and only then waits
  before reading again. This is a test-harness property, not an
  app defect: a watching screen triggers the rebuild on watch.
- **Two analyze findings on the first pass:** a doc comment with
  a bare `<method>` (now in backticks) and the
  `supplier_ledger.dart` import in `finance_provider.dart`, made
  unused by the layer move (removed). Both fixed; analyze clean.

## Verification

- `flutter analyze` — **No issues found!**
- Day 1 tests (`test/week5_day01_test.dart`) — **18/18 passed**
  (schema + mapper 3, layer queue persistence 5, notifier re-read
  + semantics 5, supplier payments through the layer 5)
- Cumulative full suite — **727/727 passed** (709 baseline + 18 new;
  first run was 726/727 — the old D-14 approve test still expected
  1 sync payload where D146 now enqueues 3 (file + apply +
  decision); expectation updated with a comment, re-run green)
- Fresh `flutter build web --release` — **✓ Built build/web**
  (409.5s compile under load, 46,624,146 bytes)
- Prescription PNGs — both in
  `build/web/assets/assets/images/prescriptions/` at **114,613 +
  110,613 bytes**, 8 "prescription" mentions in the decoded
  `AssetManifest.bin`, both sample paths present.

## Files changed

- New: `test/week5_day01_test.dart`
- Modified: `lib/models/stock_adjustment_request.dart`
  (`toMap` / `fromMap`, doc comment),
  `lib/core/data/firestore_schema.dart` (collection + paths +
  contract), `lib/core/data/firestore_mappers.dart` (mapper pair),
  `lib/core/services/repositories.dart` (interface + mock +
  provider, supplier-payment doc comment, mock D65 id),
  `lib/core/data/firestore_repositories.dart` (Firestore impl),
  `lib/core/data/repository_factory.dart` (bundle),
  `lib/core/data/production_data_layer.dart`
  (`recordSupplierPayment`, `file/load/updateAdjustmentRequest`,
  `_enqueueFinanceSync` `kind` param, provider wiring),
  `lib/features/inventory/stock_adjustment_queue.dart` (persist +
  re-read), `lib/features/inventory/stock_operation_dialogs.dart`
  (await), `lib/features/inventory/adjustment_queue_screen.dart`
  (await + doc comment),
  `lib/features/finance/finance_provider.dart` (layer call +
  sync invalidation), `firebase/firestore.rules`
  (`stockAdjustments` block),
  `test/week4_day05_test.dart` (await on the two D-14 request /
  reject call sites — intentional update only),
  `docs/technical-decisions.md` (D146, D147)

## Follow-ups (Week 5)

- **Notifier-held idempotency keys for payments:** the layer
  mints a key per `recordPayment` call, like `recordExpense`
  (D145) — a double-tap in the UI would still create two
  payments. The D115 dialog-held-key pattern (mint once per
  dialog submit, hold across retries) is the fix, for the
  cashbook + supplier-payment dialogs together.
- **Per-branch rack/shelf override** (D138), **full medicine
  master edit form** (D138), **quarantine return/disposal
  approval** (D140), **POS wiring for the Settings config**
  (D134/D136), **branch repository + FR-HO-08 enforcement,
  restore into live repos, franchise commission/royalty
  tracking** (carried from Week 4).
