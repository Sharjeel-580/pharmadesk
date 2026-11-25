# Day 14 — Week 3 Day 2 progress: goodsReceipts + salary screen

**Date:** 25 Nov 2026. **Status:** DONE.
**Decisions:** D102–D104 in `docs/technical-decisions.md`.

## What was built

### 1. goodsReceipts document + receiving through the production data layer (D103, closes D95)

Day 7 batch-wise receiving already covered receiving functionally; the
missing piece was the production record of the event. `ProductionDataLayer.receiveGoods`
is now the single write path — the purchases notifier calls the layer
instead of the inventory / PO / supplier repos directly, and the
receiving dialog is unchanged for the user (same screens, same flows):

- **One `goodsReceipts` document per receiving event** (id = the
  idempotency key, `GR-DHA-1001`… number from the counter docs) with
  its `items` subcollection — which lines arrived, as which batches,
  at what value, received by whom and when. New model
  `lib/models/goods_receipt.dart`; interfaces + mocks in
  `lib/core/services/repositories.dart`; Firestore implementation +
  mappers in `lib/core/data/firestore_repositories.dart` /
  `firestore_mappers.dart`; both join the `RepositoryBundle`
  (D101 pattern).
- **The rest of the receive moves with it:** one batch per received
  line via the inventory repo, booked into the engine by the new
  `InventoryEngine.receive` (batch snapshot + counter + one `receive`
  ledger movement + audit per batch); the PO update (received
  quantities + Partially received / Received); the supplier-ledger
  purchase charge; one `goods.received` audit entry; one batched-write
  sync payload (receipt doc + items + batch docs + stock transactions
  + ledger entry + PO update).
- **Idempotency:** a retry with the same key returns the original
  receipt + the PO state that receive produced and moves no stock or
  money. The receiving dialog mints the key once per dialog and passes
  it on every submit, so a retry after a failed attempt reuses it —
  this closes the D54 gap for receiving (the key is held across
  retries in the dialog session).
- **Fail-closed orphan guard:** a receipt id already in the store but
  NOT in the layer's registry means a previous attempt wrote the
  receipt and then failed before finishing — retrying would receive
  the stock a second time (the inventory repo creates a new batch row
  per call). The layer throws `StateError` with the receipt number
  instead of double-receiving. The Firestore transport will execute
  the whole receive as one batched write, which removes the window
  entirely.

### 2. Salary screen (D102)

- **Where salary figures live — decided first:** a separate payroll
  record, `SalaryRecord`, one per (employee, month), doc id
  `sal-{employeeId}-{yyyy-MM}` — NOT a field on the `Staff` model.
  Reasons: sensitivity (a Branch Manager has `users: own` but
  `hrSalary: none`, so a salary field on Staff would leak figures into
  every directory fetch) and history (monthly figures change; a
  per-month record is the history). The `employees.salary` contract
  field stays unwritten by the staff mapper (D99 stands); the payroll
  record is the source of truth. Net is always
  base + allowances − deductions — the repositories refuse a record
  whose net disagrees.
- **The screen** (`lib/features/staff/salary_screen.dart`, route
  `/staff/salary`): per-employee rows (name, job title, branch, base /
  allowances / deductions / net) + monthly totals card (total net,
  base, allowances, deductions, recorded count), branch-scoped
  (head-office users get the All-branches dropdown), month navigation
  (no future months), empty states for months with no records.
- **Gating:** `hrSalary` at the route (`routeCapability` +
  `FeatureGate`) AND in-screen — Owner / HO Admin / Accountant view,
  Auditor read-only, everyone else (incl. Branch Manager) is stopped
  with an explanation. Sidebar + mobile More-sheet + staff-directory
  entries hide for users who may not view salary.
- **Demo figures, labelled as demo:** seeded records for all 10 demo
  staff for the current month (`demoSalaryRecords`, sized to the role:
  Owner Rs 250,000 … Counter Rs 55,000), all `isDemo: true`. The
  screen shows a demo banner and a per-row Demo badge and says plainly
  the figures are fictional sample payroll, not real payroll. No salary
  figure is invented as real data.
- **Not built:** the edit flow. The repository's `saveSalaryRecord`
  (upsert by employee+month, validated) exists for the future
  payroll-edit screen, guarded by `canManageSalary`. The Day 2 screen
  is display-only.

### 3. Schema, rules, navigation

- Schema contract extensions (D104): `goodsReceipts` gains
  `receivedAt` / `supplierId` / `totalValueMinor` + the items
  subcollection contract; new `salaries` collection contract; path
  builders for both.
- Rules draft: new `salaries` match block — readable only by the
  `hrSalary` holders (owner / ho_admin / accountant / auditor),
  writable only by owner / ho_admin / accountant, money must be ints.
  The `goodsReceipts` rules already existed.
- Navigation: `/staff/salary` route; Staff & HR module description
  updated; sidebar + More-sheet Salary sub-items (permission-gated);
  Salary chip on the staff directory (permission-gated).

## Verification

- `flutter analyze` — **No issues found!**
- New tests **29/29** (`test/week3_day02_test.dart`): GoodsReceipt
  model + mock repo, layer receiving (receipt/ledger/PO/audit/sync,
  partial receiving, duplicate key, guards, orphan guard), notifier
  integration (Day 7 flows through the layer), Firestore repos
  (mapper round-trips, sequential numbers, idempotent re-save),
  salary logic (net, month helpers, validation, `hrSalary` matrix,
  rows + totals, demo seed), salary repos (mock + Firestore), the
  D102 pin (Staff carries no salary field; figures come from the
  salary repo), factory wiring, and salary-screen widget tests
  (owner rows + demo banner + totals, branch-manager gate,
  month navigation, entry visibility).
- Full suite **474/474** (191 Week 1 + 203 Week 2 + 51 Week 3 Day 1 +
  29 Day 2).
- `flutter build web --release` — **Pass** (46,364,991 bytes).
  Prescription PNGs verified bundled (D61 check: both files on disk
  at exact sizes + 8 "prescription" mentions in the decoded
  manifest).

## Earlier-test update (D87/D97 pattern — deliberate, disclosed)

- `test/day_07_test.dart` route walk: added `/staff/salary` to the
  walked routes (the new route loads, no placeholder, no dead end).
  No other earlier test was touched; no earlier expectation changed.

## Follow-ups for Day 3

- Reports on pre-aggregated counters (daily rollup Function output) +
  pagination, and sync-status UI (pending counts, last-sync time) on
  offline-capable screens — the receiving sync payload enqueued here
  is exactly the kind of op the sync-status UI will surface
  (`pendingSyncCount()` / `pendingSyncOperations()` already exist on
  the layer).
- The salary edit flow (repository `saveSalaryRecord` is ready;
  screen + `canManageSalary` gating still to build) and the payroll
  month-close concept, if Hadi asks for it — not in the SRS.
- Live verification of the Firestore goods-receipt + salary repos
  against a real project/emulator is still open (no Firebase project
  yet — Dazy-only blocker, unchanged).
