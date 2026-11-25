# Day 11 Progress — Week 2 Day 4: Advanced POS + Owner Dashboard

**Date:** 25 Nov 2026. **Status:** DONE — verified (see table below).

## What was built

Advanced POS (barcode-scan hooks, printer integration, parked sales,
returns/refunds per SRS §3 `saleReturns`) and a deepened owner
dashboard (live KPIs, branch comparison, alerts feed) — all on the
existing mock-first production data layer. There is still **no
Firebase project** (Dazy-only step), so nothing here is wired to a
live backend yet: the Firestore `saleReturns` repository is
code-ready and tested against an in-memory fake transport.

### New files — models + repositories

| File | What it does |
|---|---|
| `lib/models/sale_return.dart` | `SaleReturn` / `SaleReturnItem` / `SaleReturnStatus` (`completed` / `reversed`); `isFullReturn` compares per-medicine returned vs sold quantities; `saleBatchId` = the batch the stock originally sold from, `restockBatchId`/`restockBatchNo` = where it went back. |
| `lib/models/sale.dart` (edited) | `SaleStatus` (`completed` / `partiallyReturned` / `returned` / `voided`) + `status` field (default `completed`); `saleStatusFromString` accepts snake_case and camelCase. |
| `lib/core/services/repositories.dart` (edited) | `SaleRepository.updateSale` (status-only update) + new `SaleReturnRepository` interface (`getReturns`, `getReturnsForSale`, `createReturn`) with `MockSaleReturnRepository` (ids `ret-N`) and `saleReturnRepositoryProvider`. |
| `lib/core/data/firestore_schema.dart` (edited) | Path helpers `saleReturnsPath` / `saleReturnDocPath` / `saleReturnItemsPath`; contract entry `branches/{branchId}/saleReturns/{returnId}/items` (incl. `saleItemId` = `medicineId\|saleBatchId`). |
| `lib/core/data/firestore_mappers.dart` (edited) | `saleToFirestore` now writes the real status (was hardcoded `'completed'`); `saleReturnToFirestore` / `saleReturnFromFirestore` / `saleReturnItemToFirestore` (saleItemId written as `medicineId\|saleBatchId`, split back on read). |
| `lib/core/data/firestore_repositories.dart` (edited) | `FirestoreSaleRepository.updateSale` (merge update of the status field only); `FirestoreSaleReturnRepository` (create with batched writes, `getReturns`, `getReturnsForSale` via filter). |
| `lib/core/data/repository_factory.dart` (edited) | `RepositoryBundle.saleReturns` (mock + Firestore kinds). |

### New files — POS features

| File | What it does |
|---|---|
| `lib/features/billing/barcode_scanner.dart` | Pure `findMedicineByBarcode` (trimmed exact match) + `scanBarcode` (pure lookup → found / notFound / notSellable, FEFO batch + sellable qty; reuses the Day 5 guard — expired / quarantined / out-of-stock is never added). `BarcodeScanner` interface, `SimulatedBarcodeScanner` (repo-backed), `HardwareBarcodeScanner` stub that throws `UnsupportedError` explaining HID keyboard-wedge scanners work as-is via the scan field and SDK scanners implement the interface. |
| `lib/features/billing/receipt_printer.dart` | `PrinterType` (`browser` / `network` / `usb`), `PrinterSettings`, `PrinterResult`, `ReceiptPrinter` interface (status / printText / openCashDrawer), `WebReceiptPrinter` (uses the existing web print path; drawer kick honestly returns failure — a browser cannot send a drawer signal), `NetworkReceiptPrinter` + `UsbReceiptPrinter` documented stubs that report "not configured / not implemented" and never pretend to print, `printerForSettings`, `testReceiptText` (pure helper), `PrinterSettingsNotifier` + `printerSettingsProvider` (session-only), `receiptPrinterProvider` (overridable in tests). |
| `lib/features/billing/receipt_print_web.dart` (edited) | `printText` opens a popup window via js_interop, writes HTML-escaped text, calls print; falls back to `window.print()` if the popup is blocked. **Build fix (D85):** `@staticInterop` classes cannot declare instance members — they live in extensions now; the first web build failed on this. |
| `lib/features/billing/receipt_print_stub.dart` (edited) | No-op `printText` for non-web targets. |
| `lib/features/billing/parked_sales.dart` | `ParkedSale` (id, branchId, lines copy, customerId, notes, cashierName, parkedAt, subtotalMinor) + `ParkedSalesNotifier` (park returns null on an empty cart; resume removes + returns; discard) + `parkedSalesProvider` / `branchParkedSalesProvider`. Held carts never touch stock; session-only. |
| `lib/features/billing/returns_logic.dart` | Pure return maths: `returnChunkKey` (`medicineId\|batchId`), `soldChunkQuantities`, `alreadyReturnedChunkQuantities`, `returnableChunkQuantities`, `chunkRefundMinor` (unit price × qty − pro-rated line discount, truncated), `computeRefundMinor`, `validateReturn` (reason required, ≥1 item, qty ≤ still-returnable, voided sale refused), `returnStatusAfter`, `restockTarget`. |
| `lib/features/billing/returns_provider.dart` | `SaleReturnsNotifier.createReturn`: (1) permission via `permissionService.canWrite(user, 'posRefund', branchId)`; (2) validate; (3) restock each chunk via `ProductionDataLayer.adjustStock` (stock ledger + audit); (4) sale status update via repo **+ refresh of the in-memory sale list** (D88 — without it every sale lookup kept the old status); (5) credit sale → negative `adjustment` ledger entry (refund off khata); (6) save return + audit entry `sale.returned`; refresh + invalidate sales / inventory / dashboard / comparison / live-KPI providers. Providers: `saleReturnsProvider`, `branchSaleReturnsProvider`, `saleReturnsForSaleProvider`. |
| `lib/features/billing/returns_list_screen.dart` | Route `/billing/returns`: branch-scoped newest-first list, Full/Partial badge from the sale status, refund, reason, approver, date; empty state with a working "New return" action. |
| `lib/features/billing/return_form_screen.dart` | Route `/billing/returns/new?sale=<id>`: sale picker dropdown, per-chunk qty steppers capped at still-returnable, live refund preview, reason field (required), `posRefund` gating with an explanation when the user cannot approve, Confirm button. |
| `lib/features/billing/pos_screen.dart` (edited) | Scan field (key `pos-scan-field`, autofocus + refocus after scan, Enter-to-add via `onSubmitted`) placed **after** the search field so Day 6 tests' `find.byType(TextField).first` keeps working (D83); "Simulate scan" button (key `pos-simulate-scan`, feeds the first sellable catalogue barcode); scan error message; `_addMedicine` now takes a required `sellableStock` and enforces the cap in one place (pick row, scan, stepper all funnel through it); notes field (held with a parked sale only — `Sale` has no notes field); Hold sale button (key `pos-hold-sale`, disabled when the cart is empty) + Complete Sale in a Row; `_HeldSalesCard` (Resume key `pos-resume-<id>`, Discard key `pos-discard-<id>`, customer name, subtotal, held time, notes); header action replaced by a Wrap row with "Sales history" + "Returns & refunds" buttons. |
| `lib/features/billing/receipt_screen.dart` (edited) | "Return items" button → `/billing/returns/new?sale=<id>`. |
| `lib/core/routing/app_router.dart` (edited) | `/billing/returns` and `/billing/returns/new` routes (FeatureGate; `/billing` prefix → `posRefund` / `posSell` capability gating applies). |
| `lib/app/shell/app_shell.dart` (edited) | "Returns & refunds" sub-item under Billing & POS in the desktop sidebar and the mobile More sheet. |

### Owner dashboard (deepened)

| File | What it does |
|---|---|
| `lib/features/dashboard/owner_dashboard_data.dart` | Pure `BranchComparisonRow` (today's sales/orders, stock value, outstanding, low-stock, near-expiry, expired, pending prescriptions, open POs, alert count), `OwnerLiveKpis`, `computeGrossProfitMinor` (POS sales only — orders excluded, no batch cost; cost = batch `costMinor`, fallback medicine `purchasePriceMinor`, else 0; today's refunds subtracted; bill discount/tax ignored — D81), `computeOutstandingKhataMinor`, `countOpenPurchaseOrders` (Draft / Approved / Partially received), `computeBranchComparison`. |
| `lib/features/dashboard/dashboard_screen.dart` (edited) | New providers `ownerLiveKpisProvider` (family by scope `'all'` / branchId), `branchComparisonProvider` (visibility enforced via `permissionService.permissionFor(user, 'allBranches')`: allowed/readOnly → all demo branches; own → only `branchIds`; empty → active branch), `dashboardAlertsFeedProvider` (family, from the notifications module). `_OwnerDashboard` is now a ConsumerWidget with 3 extra live KPI cards (Gross profit — today, Outstanding khata, Open purchase orders) + `_BranchComparisonCard` (rows with a Wrap of mini-stats, tap switches branch + goes to orders, footer explains the khata-attribution rule D79) + `_AlertsFeedSection` (top 6 from notifications, tap navigates) alongside the existing `_AlertsSection`. **Removed** the old `_BranchPerformanceCard` / `_BranchPerformanceRow` — superseded by the comparison card (D84, D87). |
| `lib/features/settings/settings_screen.dart` (edited) | `_PrinterCard` in the General tab: name field, type dropdown (key `printer-type-dropdown`), network host/port fields shown only for network type, "Test print" button (key `printer-test-print`), "Open cash drawer" button, status line from `receiptPrinterProvider.status`. |
| Invalidation rename (D84) | `branchPerformanceProvider` removed; `ref.invalidate(branchComparisonProvider)` now in `lib/features/billing/billing_provider.dart`, `lib/features/inventory/inventory_provider.dart`, `lib/features/purchases/purchases_provider.dart`, `lib/features/prescriptions/prescriptions_provider.dart`. |

### Returns permission — the matrix governs, not the job title (D80)

The task text said "approval by role (pharmacist/manager)", but the
SRS §5.1 `posRefund` matrix says: Super Admin none, Owner allowed,
HO Admin allowed, Regional Mgr none, **Branch Mgr own, Pharmacist
none, Cashier own**, Inventory Mgr none, Accountant none, Auditor
none. So a **pharmacist CANNOT approve returns**; Branch Manager /
Cashier own-branch, Owner / HO Admin all branches. Implemented via
`permissionService.canWrite` (D70: read the matrix, not the job
title). The form disables Confirm with an explanation when the user
lacks the permission.

### Decisions (D77–D88)

Recorded in `docs/technical-decisions.md`:

- **D77 refund rule:** refund = returned chunks' line totals only;
  bill discount and tax are NOT refunded (re-allocating them per
  chunk would invent a split).
- **D78 restock rule:** restock into the original batch if it still
  exists; else the earliest-expiry `available` batch of the same
  medicine; else reject the return — never invent a batch, never move
  stock to another medicine. Batch status decides sellability via the
  Day 5 guard.
- **D79 khata attribution:** per-branch outstanding counts only
  ledger entries whose `referenceId` is one of that branch's credit
  sales; manual entries (no sale ref, incl. all seeded opening
  entries) are unattributed and count only in the org-wide total; the
  comparison table footer explains this.
- **D80 returns permission:** the §5.1 `posRefund` matrix governs
  (see above) — pharmacist cannot approve returns.
- **D81 gross profit scope:** POS sales only; orders excluded and
  documented.
- **D82 printer honesty:** web test print is real (popup print
  dialog); network/USB honestly report unavailability; the browser
  cannot send a cash-drawer signal.
- **D83 scan-field placement:** after the search field, so Day 6
  tests keep working.
- **D84 branchPerformanceProvider removed:** replaced by
  `branchComparisonProvider`; invalidations renamed in 4 providers.
- **D85 js_interop `@staticInterop`:** instance members must live in
  extensions — declaring them in the class fails the web build.
- **D86 test lesson:** `ensureVisible` + tap needs a
  `pumpAndSettle` between them when the target sits in a scrolling
  list (sidebar), or the tap fires mid-scroll-animation and misses.
- **D87 Day 3 test update:** 'Branch performance' → 'Branch
  comparison' — the card was replaced, not a regression.
- **D88 sale-list refresh after return:** `updateSale` in the repo
  leaves the in-memory `SaleNotifier` stale; `createReturn` refreshes
  `salesProvider` after the status update.

### Bugs found by verification, fixed in this day

1. **Sale status staleness after a return (D88):** the returns list
   showed "Partial return" for a full return because `saleByIdProvider`
   read the stale in-memory sale list. Fixed by refreshing
   `salesProvider` in `SaleReturnsNotifier.createReturn` after
   `updateSale`.
2. **Web build failed on `@staticInterop` (D85):** instance members
   declared in `_PopupWindow` / `_PopupDocument` are illegal —
   moved to extensions; build passes.
3. **Test-only fixes:** gross-profit test return needed `createdAt`
   (refund subtraction is day-scoped); `ensureVisible` → settle →
   tap in the printer/empty-state tests (D86); duplicate 'New return'
   finder (header action + empty-state action) needs `.first`.

## Verification

| Target | Result |
|---|---|
| `flutter analyze` | **No issues found!** (final run after all fixes) |
| New tests `test/week2_day04_test.dart` alone | **42/42 passed** (scan lookup incl. expired/quarantined/out-of-stock refusal, hardware stub throws, simulated scanner; parked park/resume/discard + branch scoping; return maths + restock + khata adjustment + status transitions; permission gating pharmacist denied / other-branch cashier denied / owner allowed; owner dashboard data incl. gross profit + seeded ledger total Rs 32,000 + branch comparison + open POs 4; printer settings + fake-printer test print; Firestore sale/return mapper round-trips + `_FakeTransport` repo tests; widget tests — POS simulate scan, typed barcode + Enter, unknown barcode error, hold/resume/discard, return flow end-to-end cash sale → receipt → return → returns list, empty-state navigation, pharmacist Confirm disabled, owner dashboard widget, printer settings widget) |
| Full suite `flutter test` | **334/334 passed** (292 before Day 4 + 42 new). One Day 3 widget test was updated (D87: 'Branch performance' → 'Branch comparison') — the only failure in the first full run; fixed and re-run green. |
| `flutter build web --release` | **Pass** — `✓ Built build/web`, 46,214,159 bytes total, compile 171.9s. First attempt failed on D85 (js_interop); fixed and rebuilt. |
| Dead buttons / regressions | None found. All new buttons navigate or act; the returns empty-state "New return" action was fixed from an initial dead-button mistake during the build. |

## Blockers (unchanged, Dazy-only)

- Firebase project + billing (Blaze) creation — no cloud sync until then.
- Hadi's requirements (medicines count, delivery areas, payment method, branch cities, logo + brand colours) — still unknown, never invented.
- APK build remains environment-blocked in this sandbox (D52); CI is the path once the repo has code.
- `presentation-video/` untouched.
