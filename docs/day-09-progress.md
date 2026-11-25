# Day 9 Progress — Week 2 Day 2: Auto Purchase List Screen

**Date:** 25 Nov 2026. **Status:** DONE — verified (see table below).

## What was built

The demo only had low-stock alerts + manual PO creation. There is now
a real, working, dedicated Auto Purchase List screen (Hadi asked for
it specifically), at `/purchases/auto` under the Purchases module.

### New module — `lib/features/purchases/`

| File | What it does |
|---|---|
| `auto_purchase_logic.dart` | Pure suggestion maths (no widgets/providers): per-medicine usable stock, reorder level, suggested quantity, reason, unit cost, open-PO exclusions, preferred supplier, grouping by supplier, totals in paisa, validation |
| `auto_purchase_provider.dart` | `AutoPurchaseListNotifier` — loads inventory + catalogue + POs + suppliers for the active branch, holds staff edits (quantity, supplier, removed lines), refresh/recompute, idempotent approval through the normal purchases flow |
| `auto_purchase_list_screen.dart` | The screen: wide DataTable on desktop (≥900px), cards on mobile; edit qty, per-line supplier picker, remove line, refresh, approve → Draft POs; excluded-items banner, empty state, error + success banners |

### Suggestion rules (D63)

- One suggestion per medicine, branch-scoped. Usable stock is the
  Day 5 shared guard (`sellableStockFor`, D30): non-expired batches
  with stock on hand only — expired stock never counts as usable.
- Reorder (par) level = the sum of `lowStockThreshold` over the
  medicine's batch rows at the branch (each seeded batch carries 10).
- Suggested quantity = reorder level − usable stock, floored at 0;
  only lines with suggested quantity > 0 appear.
- Reason, highest priority first: `Low stock` (usable stock 0),
  `Near expiry — usable stock low` (a sellable batch expires within
  30 days), otherwise `Below reorder level`.
- Unit cost = the FEFO batch's cost, falling back to the
  earliest-expiry batch with a cost, then to 80% of the sale price
  (the Day 7 PO-form default, D43).
- Exclusions: a medicine already on an open PO (Draft / Approved /
  Partially received, same branch, units still outstanding) is
  excluded so nothing is double-ordered. The banner names the
  excluded items and counts them — the count is only medicines that
  would otherwise have been suggested.
- Preferred supplier: the catalogue has no medicine→supplier field,
  so the suggestion reuses history — the supplier of the most recent
  non-cancelled PO for that medicine at the branch, falling back to
  the first active supplier. Staff can change it per line; approval
  groups by the line's supplier.

### Approval → purchase orders (D65)

- Approval groups the approved lines by supplier and creates **one
  Draft PO per supplier** through `PurchaseOrdersNotifier.createOrder`
  (the existing purchases flow), so the POs appear in the Purchases
  module immediately and follow Draft → Approved → receiving with
  batch-wise receiving + supplier ledger.
- Idempotency, three layers: (1) the approve button is disabled
  while an approval is in flight (`isApproving`); (2) every approval
  carries a client-generated key, minted once per tap and reused on
  retry, and completed keys return the already-created POs; (3) the
  mock PO repository dedupes on a non-empty client id and still
  assigns the sequential PO number (`PO-DHA-…`). A retry after a
  failed attempt reuses the per-supplier keys, so a partial approval
  never duplicates the POs that already succeeded.
- Lines set to quantity 0 are not ordered. Quantities are integers
  ≥ 0 (digits-only input + provider rejection of negatives).

### Navigation / discoverability

- Route `/purchases/auto`, wrapped in `FeatureGate` (maps to the
  Purchases module via `featureModuleForRoute`, so disabling
  Purchases hides/gates it too). Declared **before**
  `/purchases/:id` so the static segment wins.
- Sidebar: "Auto Purchase List" sub-item under Purchases (desktop);
  mobile "More" sheet: same sub-item under Purchases.
- Purchases list screen: an "Auto Purchase List" button above the
  PO list.
- Branch scope: the list is for the active branch only (shown in the
  header); switching branches reloads it; a PO never mixes branches.

### Supporting changes

- `lib/features/purchases/purchases_logic.dart` —
  `buildNewPurchaseOrder` accepts an optional client-generated `id`.
- `lib/features/purchases/purchases_provider.dart` —
  `createOrder` accepts an optional `idempotencyKey`.
- `lib/core/services/repositories.dart` —
  `MockPurchaseOrderRepository.createPurchaseOrder` returns the
  existing PO when a non-empty client id is submitted again.
- `lib/app/shell/app_shell.dart` — sidebar sub-item + More-sheet
  sub-item under Purchases.
- `lib/core/routing/app_router.dart` — the `/purchases/auto` route.
- `lib/features/purchases/purchase_list_screen.dart` — entry button.

## Verification

| Check | Result |
|---|---|
| `flutter analyze` | **No issues found!** |
| `flutter test test/week2_day02_test.dart` (new file, alone) | **25/25 passed** — suggestion maths (reorder − usable, expired-never-usable, near-expiry rule, cost fallback, branch isolation), exclusions (open statuses cover, Received/Cancelled do not, other-branch PO does not, fully-received line does not), grouping by supplier + paisa totals, validation, preferred-supplier history/fallback, idempotent approval (same key twice; concurrent double approval), widget tests (renders seeded DHA list, edit qty updates total, remove drops the line, approve creates Draft POs visible in Purchases, double-tap creates one PO per supplier, Purchases-list entry button, empty state with a well-stocked repo) |
| `flutter test` (full suite) | **246/246 passed** — 221 Week 1 + Day 1, + 25 Day 2 (incl. the fixed Week 1 sidebar test, now also covering the new sub-item) |
| `flutter build web --release` | **Pass** — `build/web/main.dart.js` 3,993,101 bytes |
| Screen / no dead buttons | Every action works end-to-end: Refresh recomputes, qty edit + supplier change + remove, approve (incl. empty/zero-qty validation error), success banner links to Purchases, empty state links to Purchases |

### Fixes made during Day 2

- `flutter analyze` caught 3 unused imports (new files) + the test's
  `List<Override>` — Riverpod 3.5 does not export `Override`
  publicly (D66); the override list is now built inline where the
  constructor parameter types it contextually.
- 4 widget tests first failed on off-screen taps (D33, re-learned):
  the approve button sits below the fold and the remove button sits
  off the right edge of the wide table — `ensureVisible` before
  tapping both; the Purchases-list button got a key because its label
  also appears in the sidebar.
- **Regression found by the full suite:** the Week 1 sidebar test
  ("desktop sidebar lists all 14 modules and navigates") failed
  after the new sub-item lengthened the sidebar list — the 300px
  drag steps parked Medicines half under the brand header and the
  tap missed (D67). Fixed in the test with `ensureVisible` before
  tapping (D24 pattern) and extended the same test to tap the new
  "Auto Purchase List" sub-item and land on the screen. No app
  behaviour changed — the sidebar navigation itself was correct.

## Docs updated

- `docs/technical-decisions.md` — D63–D67 (suggestion rules, no
  batch status field yet, PO idempotency, `Override` not exported,
  off-screen tap lesson).
- `docs/week-2-tracker.md` — Day 2 checked off (auto purchase list);
  the originally planned Firestore implementations shift to Day 3
  with the auth wiring (Hadi's list was prioritised).
- `docs/known-limitations.md` — §13 added (auto purchase list notes).

## Blockers (unchanged, Dazy-only)

- Firebase project + billing (Blaze) — no cloud sync until then.
- GitHub repo `Sharjeel-580/pharmadesk` — created + verified 25 Nov
  16:02 (public, empty). Code push via the browser upload route is a
  later chunk's work; local commit only in this chunk.
- Hadi's requirements (medicines count, delivery areas, payment
  method, branch cities, logo + brand colours).
- APK build remains environment-blocked in this sandbox (D52); CI is
  the fix path once the repo has code.
- Windows/iOS unverifiable on this Linux VM — never claimed.

## Follow-ups

- When the SRS batch `status` field (available / quarantined /
  expired / returned) lands on `InventoryItem`, re-check the usable
  stock rule: quarantined batches must be excluded from usable stock
  explicitly instead of relying on the sellable guard (D64).
- The per-supplier grouping reuses PO history for the preferred
  supplier; a real supplier→medicine catalogue (preferred supplier
  per medicine, lead times, pack sizes) is a later production step —
  the screen already lets staff override the supplier per line.
