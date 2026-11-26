# Day 25 Progress — Feature completion, part 1 (Week 5 Day 3)

**Date:** 26 Nov 2026. **Scope:** full medicine master edit form + per-branch
rack/shelf override — the two D138 follow-ups from Week 4 Day 5.
Decisions D151, D152, D153 in `docs/technical-decisions.md`.

## What changed

### 1. Full medicine master edit form (D153 — closes the D138 follow-up)
- `lib/features/medicines/medicine_edit_dialog.dart` — the location-only
  dialog is replaced by `showEditMedicineDialog`: name, sale price,
  purchase price, MRP (optional), barcode (optional), category
  (dropdown of the 16 catalogue labels), location. All fields prefilled;
  prices enter as rupees and convert to int paisa at the boundary (D6).
  Saves through the existing `MedicineRepository.updateMedicine` — no
  extension needed; the whole-record `copyWith` carries untouched fields
  (brand, strength, pack size, Rx flag) from the existing record.
- `lib/features/medicines/medicine_validation.dart` (new) — D151:
  `parseRupeesToMinor` / `formatMinorUnitsAsRupees` /
  `validateMedicineEdit` (one error string per invalid field).
- `lib/models/medicine.dart` — `copyWith` gains `clearBarcode`
  (the `clearLocation` / `clearMrp` pattern), so clearing the barcode
  or MRP actually clears it.
- Detail screen: "Edit location" becomes two buttons in a wrapping row —
  "Edit medicine" (`medicine-edit`) and "Branch shelf"
  (`medicine-branch-shelf`) — both gated on the existing `medicineCrud`
  write, branch-scoped. Read-only roles see no edit UI.

### 2. Per-branch rack/shelf override (D152 — SRS §3.3 / FR-INV-10)
- `lib/models/branch_inventory_location.dart` (new) — one record per
  (branch, medicine): `branchId`, `medicineId`, `rack?`, `shelf?`,
  `displayLabel` ("Rack B • Shelf 1"), `isEmpty` (both blank = no override).
  The master `Medicine.location` stays the default shelf.
- `lib/features/inventory/inventory_logic.dart` — `effectiveLocation`
  (override wins, else master, else null) and `branchLocationFor`.
  Both stock views read the same function: the detail screen's Location
  row (suffixed "(this branch)" when the override shows) and the
  inventory screen's per-medicine group line ("Location: …").
- `lib/core/services/repositories.dart` — `InventoryRepository` gains
  `getBranchLocation` / `getBranchLocations` / `saveBranchLocation`.
  Mock keeps an in-memory map keyed `branchId|medicineId`; saving with
  both fields empty deletes the record (clear = fall back to master).
- `lib/core/data/firestore_repositories.dart` — Firestore impl over the
  transport at `branches/{branchId}/inventory/{medicineId}` (doc id =
  medicine id). The save is a merge-set, so the doc's quantity counters
  are never dropped; clearing writes nulls.
- `lib/core/data/firestore_mappers.dart` — `branchInventoryLocationToFirestore`
  / `branchInventoryLocationFromFirestore`. No `validateOrThrow`: the §3
  contract requires quantities on the doc and a location-only write does
  not own them (same posture as `inventoryCounterToFirestore`).
- `lib/core/data/firestore_schema.dart` — `rack` / `shelf` notes updated
  (override semantics); no contract change (the fields were already listed).
- `lib/features/inventory/branch_shelf_dialog.dart` (new) — rack/shelf
  dialog; both empty clears the override. Saves through
  `InventoryNotifier.saveBranchLocation`, which invalidates
  `branchLocationsProvider` (new `FutureProvider.family` per branch),
  so detail + inventory screens refresh at once.
- No new capability: the shelf dialog reuses the existing `medicineCrud`
  write gate (D140 pattern).

## Decisions worth remembering
- **D151 — no creation flow exists to copy validation from.** Verified
  before writing: no add-medicine UI, no `validateMedicine` anywhere —
  the catalogue is seed-only. Rules come from the schema (§3 `medicines`:
  name / purchasePrice / sellingPrice required, int paisa), the seed
  (13-digit EAN-13 barcodes; every categoryId a key of
  `medicineCategoryLabels`; every MRP null or 1.1× sale price — never
  below it). A future creation flow must reuse `validateMedicineEdit`,
  not invent a second set. No barcode-uniqueness check: no such rule
  exists anywhere in the app.
- **D152 — the override is NOT on the batch.** `InventoryItem` is one
  batch (1–3 rows per medicine per branch); rack/shelf on the batch
  would have been per-batch, not per-branch. It lives on the per-
  (branch, medicine) inventory doc, exactly where SRS §3.3 puts it.
- **Read-only role for tests is Auditor, not Cashier.** Cashier's
  `medicineCrud` is `none`, so the route itself is gated for Cashier;
  Auditor is `readOnly` and actually renders the detail screen.

## Files changed
- New: `lib/models/branch_inventory_location.dart`,
  `lib/features/medicines/medicine_validation.dart`,
  `lib/features/inventory/branch_shelf_dialog.dart`,
  `test/week5_day03_test.dart`, `docs/day-25-progress.md`.
- Edited: `lib/models/medicine.dart`, `lib/models/models.dart`,
  `lib/features/medicines/medicine_edit_dialog.dart`,
  `lib/features/medicines/medicine_detail_screen.dart`,
  `lib/features/inventory/inventory_logic.dart`,
  `lib/features/inventory/inventory_provider.dart`,
  `lib/features/inventory/inventory_screen.dart`,
  `lib/core/services/repositories.dart`,
  `lib/core/data/firestore_repositories.dart`,
  `lib/core/data/firestore_mappers.dart`,
  `lib/core/data/firestore_schema.dart`,
  `docs/technical-decisions.md` (D151–D153),
  `docs/week-5-tracker.md` (Day 25).
- Tests only: `test/day_05_test.dart`, `test/day_06_test.dart`,
  `test/week2_day02_test.dart`, `test/week3_day05_test.dart` (the four
  fake inventory repos gain throwing/delegating location methods —
  D150 pattern, interface grew); `test/week4_day05_test.dart` (the two
  location tests now drive the full form, same flow, new keys; the
  Cashier test also asserts the branch-shelf button is absent).

## Verification
- `flutter analyze`: **No issues found!**
- Day tests `test/week5_day03_test.dart`: **24/24** — validation
  (9: parse/format, each field incl. invalid price/barcode/category),
  override model + rule (4), mock repo (2), Firestore repo via fake
  transport (1), master-edit round-trip through `updateMedicine` (2),
  widget: full edit end-to-end at 390px, dialog 390px fit, invalid
  sale price blocks save, MRP/barcode errors, Auditor sees no edit UI,
  shelf set → detail + inventory show override → clear → master (6).
- Full suite `flutter test`: **782/782** (baseline 758 + 24 new).
- `flutter build web --release`: **pass** — `build/web` 46,674,326 bytes;
  prescription PNGs still bundled in
  `build/web/assets/assets/images/prescriptions/`
  (`sample-prescription-1.png` 114,613 bytes,
  `sample-prescription-2.png` 110,613 bytes, same sizes as Days 23/24).
- 390px: edit dialog + detail screen + inventory screen — 0 RenderFlex
  overflows in the Day 3 widget tests (drained exceptions).

## Follow-ups (not in this day)
- Quarantine return/disposal approval (D140), POS wiring for the
  Settings config (D134/D136), closing corrections (FR-FIN-06) + cash
  reconciliation — Day 26 scope.
- Franchise commission/royalty tracking (FR-HO-07) + Phase 8 QA depth
  — Day 27 scope.
- Finance writes are still not FR-HO-08-guarded (D149 boundary,
  carried from Day 24).
- Barcode uniqueness is unenforced anywhere (D151) — if the business
  wants it, it belongs in the repo, not the form.
- Firestore location writes have never talked to a real Firestore
  (no Firebase project — Dazy-only step, still blocked); live
  verification (rules unit tests, emulator runs) is still open,
  like every other Firestore repo.
