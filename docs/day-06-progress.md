# PharmaDesk — Day 6 Progress Report (Week 1 sprint, 24 Nov 2026)

Day 6 of the 7-day UI/UX, frontend & Firebase foundation sprint.
Status: **complete, verified** (see Verification below).

## What was built

### 1. Sale + khata models (`lib/models/sale.dart`, `lib/models/customer_ledger.dart`)
- `Sale` / `SaleItem`: completed counter sale with per-branch sequential
  invoice number, branch, optional customer, cashier, items snapshotting
  name + unit price + the batch picked (batch id/no/expiry), subtotal
  (after line discounts), bill discount, tax, total, payment method
  (cash / card / credit-khata), cash received + change, and a
  client-generated `idempotencyKey` (SRS FR-POS-11: a retried sale can
  never duplicate — Week 2 uses the key as the Firestore document id).
  All money int minor units (paisa).
- `LedgerEntry`: one append-only khata entry — kind (credit sale /
  credit / payment / adjustment), **signed** amount in int paisa
  (positive = customer owes more, negative = paid), reason, reference
  to the sale for credit sales, and `balanceAfterMinor` snapshot per
  entry so the statement reads like a bank statement.
- `Customer` gains `creditLimitMinor` (int paisa, default 0 = no limit
  set) plus `copyWith`; seeded limits for the first four customers
  (Rs 10,000–20,000). `fromMap`/`toMap` round-trip it.

### 2. Seed khata (`lib/core/services/demo_seed_data.dart`)
`generateDemoLedgerEntries()`: deterministic opening ledger — Ahmed
Raza owes Rs 5,500.00, Fatima Khan Rs 2,500.00, Bilal Hussain
Rs 12,000.00, Ayesha Siddiqui Rs 12,000.00, Usman Ghani settled
(Rs 0.00); the other three customers have no khata history.
`balanceAfterMinor` snapshots agree with the running sum (pinned by
a test).

### 3. Repositories (`lib/core/services/repositories.dart`)
- New `SaleRepository` + `MockSaleRepository` (in-memory for the
  session; the demo starts with no POS sales — the seeded 30-day
  history lives in the orders stream): `getSales` (branch-scoped),
  `getById`, `createSale` (assigns id + sequential per-branch invoice
  number, `INV-DHA-1001` / `INV-GLB-1001` …).
- `CustomerRepository` gains `createCustomer` (assigns id, rejects a
  duplicate phone — digits compared, formatting ignored),
  `getLedgerEntries` and `addLedgerEntry` (assigns id and computes
  `balanceAfterMinor` from the live outstanding, so the statement
  never drifts). The mock now holds mutable customer + ledger lists.

### 4. Billing logic (`lib/features/billing/billing_logic.dart`)
Pure, unit-tested: `CartLine` (gross / line total, never below zero),
cart gross / line discounts / subtotal, `computeTaxMinor` (whole
percent of the discounted subtotal, truncated), bill total (never
below zero), change due / cash shortfall, `validateSale` (non-empty
cart, line discount ≤ gross, bill discount ≤ subtotal, tax 0–100%,
qty ≤ sellable stock, cash covers the total, credit needs a customer
and must stay inside a set credit limit), `allocateFefo` and
`buildSale`, `receiptText`.
**FEFO allocation (D35):** each cart line walks its sellable batches
in FEFO order via the Day 5 shared guard (`fefoBatches` /
`isBatchSellable` — the expired-never-sellable rule is NOT
re-implemented here, D30); a line spanning two batches becomes two
`SaleItem`s, the first chunk carrying the line discount so the
discount total is preserved exactly. Insufficient sellable stock
throws `ArgumentError` and nothing is allocated.

### 5. Customer logic (`lib/features/customers/customer_logic.dart`)
Pure, unit-tested: `outstandingMinor` (sum of signed entries — never
a stored field), `searchCustomers` (name substring, phone digits),
`validateNewCustomer` (name, ≥10-digit phone, duplicate phone),
`validateLedgerEntry` (amount > 0, payment ≤ outstanding, reason
required for credit/adjustment), `signedLedgerAmount`.

### 6. POS / billing (`lib/features/billing/`)
- `pos_screen.dart` — route `/billing`: search by name/brand/barcode
  (sample barcodes), pick rows with FEFO batch + sellable stock and
  the shared guard (all-expired → "Expired", disabled), cart with
  quantity steppers capped at sellable stock, per-line discount
  fields, bill discount, tax rate (0/5/10/16/18%), customer picker,
  payment method (Cash / Card / Credit-khata), cash received with
  live change/shortfall, validation errors, Complete Sale.
- `billing_provider.dart` — `SaleNotifier.completeSale`: re-reads
  live branch inventory, validates against live sellable stock +
  live khata (outstanding + limit), allocates FEFO, decrements
  batches through the inventory repo, saves the sale, appends a
  khata entry for credit sales, refreshes and invalidates inventory
  + dashboard providers. A double-tap / retry while a sale is in
  flight is blocked (FR-POS-11, D34). `branchSalesProvider`
  (branch-scoped, newest first) + `saleByIdProvider`.
- `receipt_screen.dart` — route `/billing/receipt/:id`: branch,
  invoice, items with batch + expiry, discounts, tax, totals,
  payment method, cash received/change, cashier, date/time, DEMO
  watermark; actions Share (copies receipt text to clipboard),
  Print (browser print dialog on web via conditional import,
  `dart:js_interop`; other targets get a clear note), New Sale,
  View customer.
- `sales_history_screen.dart` — route `/billing/history`: completed
  sales for the active branch, newest first; tap opens the receipt.

### 7. Customers (`lib/features/customers/`)
- `customer_list_screen.dart` — route `/customers`: search by name/
  phone, seeded directory with khata outstanding per row, Add
  customer dialog (validated: name, phone, duplicate).
- `customer_detail_screen.dart` — route `/customers/:id`: contact +
  credit limit + outstanding, purchase history (orders + POS sales,
  newest first, each linking to its order/receipt), khata ledger
  (entries with balance after) with Record payment / Add credit
  (udhaar) / Adjustment dialogs — all validated, all int paisa.
- `customers_provider.dart` — `CustomerDirectoryNotifier`
  (add + refresh) and `LedgerNotifier` (family per customer:
  payment / credit / adjustment through the repo, refresh).
  Outstanding is always computed from the ledger.

### 8. Dashboard wiring
`computeDashboardKpis` gains an optional `sales` parameter (default
empty — all Day 3 tests unchanged): completed POS sales count toward
today's sales/orders, 30-day revenue, the daily series and top
sellers. `dashboardKpisProvider` and `branchPerformanceProvider`
fetch sales and pass them in, so a cash sale rung through the POS
shows on the dashboards immediately (D36).

### 9. Routing + shell
Real routes replace the placeholders: `/billing`, `/billing/history`,
`/billing/receipt/:id`, `/customers`, `/customers/:id`. The Day 2
shell test and Day 3 quick-actions test updated from the "coming
Day 6" placeholder to the real POS screen (same precedent as Day 5).

## Files created / changed
- Created: `lib/models/{sale,customer_ledger}.dart`,
  `lib/features/billing/{billing_logic,billing_provider,pos_screen,receipt_screen,sales_history_screen,receipt_print,receipt_print_stub,receipt_print_web}.dart`,
  `lib/features/customers/{customer_logic,customers_provider,customer_list_screen,customer_detail_screen}.dart`,
  `lib/core/widgets/error_box.dart`, `test/day_06_test.dart`,
  `docs/day-06-progress.md`.
- Changed: `lib/models/{customer.dart (creditLimitMinor + copyWith),models.dart}`,
  `lib/core/services/{demo_seed_data.dart (ledger seed, credit limits),repositories.dart (SaleRepository, customer/ledger methods)}`,
  `lib/features/dashboard/{dashboard_data.dart (sales in KPIs),dashboard_screen.dart (fetch sales)}`,
  `lib/core/routing/app_router.dart` (real billing/customer routes),
  `lib/core/widgets/design_system.dart` (error_box export),
  `test/{day_02_test.dart,day_03_test.dart}` (placeholder expectations → real POS),
  `docs/technical-decisions.md` (D34–D40), `docs/sprint-tracker.md`.
- Deleted: `lib/features/{billing,customers}/.gitkeep` (superseded by
  real files).

## Verification (24 Nov 2026)
- `flutter analyze` — **No issues found!**
- `flutter test` — **158/158 passed** (116 Day 1–5 + 42 Day 6:
  cart math, tax/change, validation incl. credit limit, FEFO
  allocation incl. split + expired-skip + insufficient, buildSale +
  receipt text, khata math + seeded balances, customer search /
  validation, sale repo invoice numbering + branch scoping, customer
  repo duplicate phone + ledger balanceAfter, notifier sale
  completion + FEFO decrement + credit-sale ledger entry +
  insufficient-stock no-op + over-limit block, ledger payment /
  credit flows, dashboard KPIs with POS sales, POS widget flows
  (cash with change, card, share/print, history, expired guard via
  fake inventory repo), customer widget flows (directory search,
  add + duplicate rejection, detail payment / overpay rejection /
  add credit)).
- `flutter build web --release` — **PASSED** (138.5s compile;
  `build/web/main.dart.js` 3,075,882 bytes).
- `flutter build apk` — **NOT attempted** (environment-blocked, D14/D15).
- `flutter build windows` / `flutter build ios` — not possible on this
  Linux VM; must be verified on real Windows/macOS hardware.

## Fixes found by testing (not just tests)
- The Day 2 shell test and Day 3 quick-actions test still expected
  the "Billing & POS — coming Week 1 — Day 6" placeholder — updated
  to the real POS screen (same precedent as Day 5).
- `Clipboard.setData` has no platform handler in the widget-test
  environment: its Future never completes there, so the Share
  SnackBar never appeared. The app code is correct on real devices;
  the test mocks `SystemChannels.platform` (D40). A SnackBar shown
  by one action overlays the buttons and swallows the next tap —
  the test lets it expire (5s pump) before tapping the next action.
- `LedgerNotifier` in Riverpod 3 takes its family argument as a
  constructor parameter — there is no `arg` getter (D39).
- `Iterable.fold(0, …)` infers `num` (not `int`) when its result
  feeds a `+` expression — the dashboard day-sales fold needed
  explicit `<int>` type arguments (D39).

## Blockers
Same as Day 1–5 — none new, none Day 6 can clear:
1. **Firebase project does not exist** (Dazy's call; see
   `docs/firebase-setup-plan.md`).
2. **GitHub repo not created** (name/visibility Dazy's call).
3. **Hadi's requirements still awaited** (medicines count, delivery
   areas, payment method, branch cities, logo + brand colours).
4. **APK build environment-blocked** (D14/D15; Day 6 work does not
   depend on it).

## Next step
- **Day 7 (24 Nov):** suppliers, purchases, prescription review
  (on-device photos only), basic reports, notifications, settings,
  branding, roles/permissions, feature config + full QA. Day 7 builds
  on the Day 6 sale/customer models (supplier balances mirror the
  khata pattern; reports read orders + POS sales).
