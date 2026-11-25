# PharmaDesk — Day 5 Progress Report (Week 1 sprint, 24 Nov 2026)

Day 5 of the 7-day UI/UX, frontend & Firebase foundation sprint.
Status: **complete, verified** (see Verification below).

## What was built

### 1. Seed catalogue expanded: 14 → 180 medicines (D30)
`lib/core/services/demo_seed_data.dart`: the 14 core medicines stay
exactly as they were (same ids, prices, barcodes added) and 166
generated rows join them — 180 total, inside the SRS §8 demo range of
150–250. Generated rows are deterministic (`Random(23)`): 16
categories, plausible brand names, strengths/pack sizes from fixed
pools, whole-rupee prices, unique 13-digit sample barcodes. Every
medicine has 1–3 batch rows per branch (was: exactly 1), each with
mfg date (12–36 months before expiry) and cost price (~70–90% of
sale price). Expiry mix unchanged in shape (~55% far out, ~25%
near-expiry, some within days, a few expired; ~20% low stock).
**Seeded orders are untouched: still 491, still only the core 14**
— the order generator picks from `demoMedicinesCore` only, so the
Day 4 order stream is byte-identical (D31 corrects the old "499"
figure — the Day 4 code itself generates 491).

### 2. Shared inventory logic (`lib/features/inventory/inventory_logic.dart`)
Pure functions, unit-tested without widgets: expiry buckets
(Expired / ≤30 / 31–60 / 61–90 / Fresh, with exact boundaries —
expires today counts as expired), FEFO ordering (earliest expiry
first, no-expiry last), sellable/total stock, grouping by medicine,
bucket counts, short-date formatting.
**THE GUARD (D30): `isBatchSellable` / `canSellMedicine` /
`fefoBatchFor` — the expired-never-sellable rule lives here in ONE
place.** A batch is sellable only when its expiry day is still ahead
AND it has stock. The Day 4 order form and the Day 6 POS both call
this instead of re-implementing the rule.

### 3. Catalogue logic (`lib/features/medicines/medicine_logic.dart`)
Pure functions: 16 categories with labels, search (name / brand /
barcode substring), category filter, sort by name / price (int paisa)
 / sellable stock.

### 4. Medicine catalogue (`lib/features/medicines/medicine_list_screen.dart`)
Route `/medicines`. Search field, category chips with counts (All +
16), sort dropdown, result count, rows with name/strength, brand/
pack/category, barcode, price in int paisa (`formatPkr(priceMinor)`),
and a stock badge — sellable units, Low stock, Out of stock, or
Expired stock — plus an Rx-only badge. Row tap opens the detail.

### 5. Medicine detail (`lib/features/medicines/medicine_detail_screen.dart`)
Route `/medicines/:id`. Info (name, brand, category, strength, pack,
sale price + MRP in int paisa, barcode, Rx/OTC badge, sellable/low-
stock status), stock per branch (sellable vs total), and the active
branch's batches in FEFO order with mfg/expiry, quantities, cost and
status — expired batches flagged red ("Expired — never sellable").
Batch actions (Adjust / Count) and Receive stock open the shared
stock dialogs.

### 6. Inventory screen (`lib/features/inventory/inventory_screen.dart`)
Route `/inventory`, branch-scoped to the active branch. Summary
chips (medicines, low stock, expiring ≤30, expired), expiry-bucket
filter chips with counts, search, one group per medicine with its
batches in FEFO order (batch no., mfg/expiry, days left, qty, cost,
status badge) and a per-medicine Receive button. **Alerts tab:**
expired batches, expiring within 30 days, low stock — tapping any
alert opens the medicine detail. Dashboard alert rows now deep-link
to the medicine detail too (fallback `/inventory`).

### 7. Stock operations (mock repo, in-memory, branch-scoped)
`InventoryRepository` gains `receiveStock` (new batch row),
`adjustStock` (increase/decrease with required reason, never below
zero — `ArgumentError` otherwise) and `recordStockCount` (sets the
quantity; caller reports the variance). `InventoryNotifier`
(`lib/features/inventory/inventory_provider.dart`) owns the batch
list, writes through to the repo and refreshes, and invalidates the
dashboard KPI/alert/branch-performance providers and the order
form's inventory provider — so every operation updates the displayed
stock immediately and is reflected in the dashboards' low-stock /
near-expiry figures. Dialogs (`stock_operation_dialogs.dart`) are
shared by the inventory screen and the medicine detail; receive
prefills mfg = today, expiry = today + 1 year, so it is submittable
without opening the date pickers.

### 8. Order form wired to the shared guard (D30)
`lib/features/orders/order_form_screen.dart`: the pick row now takes
all batch rows for the medicine, shows the FEFO batch + sellable
stock, and disables Add ("Expired") exactly when
`canSellMedicine` is false — a medicine with one expired and one
sellable batch stays addable via the FEFO batch. The old single-row
`isExpired` check is gone, not duplicated.

## Files created / changed
- Created: `lib/features/{medicines/medicine_logic,medicines/medicine_list_screen,medicines/medicine_detail_screen,inventory/inventory_logic,inventory/inventory_provider,inventory/inventory_screen,inventory/stock_operation_dialogs}.dart`,
  `test/day_05_test.dart`, `docs/day-05-progress.md`.
- Changed: `lib/models/{medicine.dart (barcode, priceMinor),inventory_item.dart (mfgDate, costMinor, copyWith)}`,
  `lib/core/services/{demo_seed_data.dart (180 medicines, multi-batch inventory),repositories.dart (getByBarcode, receive/adjust/count)}`,
  `lib/features/orders/order_form_screen.dart` (shared guard),
  `lib/features/dashboard/dashboard_screen.dart` (alert deep-links),
  `lib/core/routing/app_router.dart` (real `/medicines`, `/medicines/:id`,
  `/inventory` routes; Medicines/Inventory leave the placeholder map),
  `test/{day_02_test.dart,day_03_test.dart}` (placeholder expectations →
  real screens; inventory length + catalogue count assertions),
  `docs/technical-decisions.md` (D30–D33), `docs/sprint-tracker.md`.
- Deleted: `lib/features/{medicines,inventory}/.gitkeep` (superseded by
  real files).

## Verification (24 Nov 2026)
- `flutter analyze` — **No issues found!**
- `flutter test` — **116/116 passed** (84 Day 1–4 + 32 Day 5:
  seed catalogue 180 / barcodes / categories / multi-batch mfg<expiry,
  orders still 491 core-only, barcode lookup, bucket boundaries,
  FEFO ordering, sellable guard incl. expires-today + empty batches,
  mixed vs all-expired, stock totals, catalogue search/filter/sort,
  repo receive/adjust/count + rejections + branch scoping, notifier
  refresh + dashboard low-stock reflection, catalogue widget search/
  filter/sort/detail, receive/adjust/count widget flows, inventory
  bucket filter + alerts → detail, branch re-scoping, order-form
  expired guard via repository override).
- `flutter build web --release` — **PASSED** (140.1s compile;
  `build/web/main.dart.js` 3,013,035 bytes).
- `flutter build apk` — **NOT attempted** (environment-blocked, D14/D15).
- `flutter build windows` / `flutter build ios` — not possible on this
  Linux VM; must be verified on real Windows/macOS hardware.

## Fixes found by testing (not just tests)
- The Day 3/4 docs' "499 orders" is wrong: the Day 4 code itself
  generates **491** (verified against commit `2e1954d` in a worktree).
  Day 5 changes nothing in the order stream — recorded as D31, and
  the Day 5 test pins 491.
- Widget taps on the order form miss at the default 800×600 test size:
  pick-row buttons sit under the shell top bar / bottom nav. The
  guard test now runs at a tall 800×1600 viewport (D33).
- The "All batches" chip first toggled through the Fresh bucket by
  mistake — it now has its own clear handler.
- A sort test computed the priciest medicine over the full catalogue
  while filtered to antibiotics — the test now scopes the expectation
  to the filtered category.

## Blockers
Same as Day 1–4 — none new, none Day 5 can clear:
1. **Firebase project does not exist** (Dazy's call; see
   `docs/firebase-setup-plan.md`).
2. **GitHub repo not created** (name/visibility Dazy's call).
3. **Hadi's requirements still awaited** (medicines count, delivery
   areas, payment method, branch cities, logo + brand colours).
4. **APK build environment-blocked** (D14/D15; Day 5 work does not
   depend on it).

## Next step
- **Day 6 (24 Nov):** POS/billing (cart, FEFO batch selection via the
  Day 5 shared guard, discount, tax, receipt preview/print; money int
  minor units) + customers (directory, history, khata, outstanding,
  payments). Day 6 builds on the Day 5 guard (`canSellMedicine` /
  `fefoBatchFor`), the 180-medicine catalogue and the batch rows.
