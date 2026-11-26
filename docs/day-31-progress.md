# Day 31 Progress — Model gaps + barcode uniqueness + POS tax live-watch (Week 6 Day 4)

**Date:** 26 Nov 2026. **Status:** done. Decisions: **D165** (Supplier.createdAt + Order.orderNumber/idempotencyKey), **D166** (barcode uniqueness at the repo), **D167** (POS tax live-watch), **D168** (branch code field in the form). Full detail in `docs/technical-decisions.md`.

## What changed

### Part A — Model gaps, migration-safe defaults (D165)

- `Supplier` gains `createdAt` (`DateTime?`, default `null` = "unknown, never invented"). Seeded suppliers (all four) keep `null` — they predate the field and the demo has no founding date for them. A supplier created through a repository is stamped `DateTime.now()` at creation (mock `createSupplier`; Firestore `createSupplier` stamps and returns it); an update never rewrites it (mock keeps the stored value when the incoming row carries none; Firestore already dropped `createdAt` from its merge-update). `fromMap`/`toMap` round-trip it; the mapper writes the model's value when set and otherwise the stamp's "now"; a legacy doc without the field reads back `null`. No schema change — `createdAt` is already in `commonFields`.
- `Order` gains `orderNumber` (default `''` = not assigned) and `idempotencyKey` (default `''` = not assigned), D164 posture: `effectiveOrderNumber` derives `ORD-DHA-1001` from `ord-dha-1001` when unset; `effectiveIdempotencyKey` falls back to the order id (D53 doc-id rule). The key is stable per order — re-serializing never mints a new one. `toMap` writes the effective values (like `Branch.toMap` writing `effectiveCode`), so a backup export never carries an empty number/key.
- Mapper: `orderToFirestore`'s `orderNumber` parameter is now optional — an explicit value wins, else the model's effective values; a legacy order still writes a valid §3 doc instead of failing validation on the required `orderNumber`. `orderFromFirestore` maps missing fields to `''` (effective getters derive), never a crash.
- Repos return what they assign (fix found while wiring the fields): `FirestoreOrderRepository.createOrder` and `upsertOrder` used to return `copyWith(id: docId)` only — the number and key they had just computed were dropped. Both now return them; `updateOrder` keeps the stored number/key and falls back to the model's effective values (not the bare id) when the stored doc lacks them. The mock mirrors it (`createOrder` assigns `ORD-<BRANCH>-<seq>` + key = id; `upsertOrder` keeps an existing order's values, derives a new one's from its minted id — a restore never re-numbers).

### Part B — Barcode uniqueness at the medicine master repo (D166)

- `MedicineRepository.updateMedicine` (mock + Firestore) rejects a barcode already used by a DIFFERENT medicine: `ArgumentError('Barcode "<code>" is already used by "<name>". Give this medicine a different barcode or leave it empty.')`. Keeping the medicine's own barcode on edit is fine; an empty/absent barcode is fine; surrounding whitespace is trimmed before comparing. The check is the pure `findBarcodeConflict` (`medicine_logic.dart`) with one shared `barcodeConflictMessage`, so both backends reject in identical words.
- The edit dialog needed no change — it already catches `ArgumentError` from `updateMedicine` and shows it inline (D153); pinned by widget test.
- Restore is exempt: `upsertMedicine` never re-checks (D150 posture — a restore replays data that was valid when exported).
- **Seeded-data duplicate result: NONE.** All 180 catalogue medicines carry a barcode and all 180 are distinct (core `8901000000001…14`, generated `8902000000000+i`). No seed row was changed.

### Part C — POS tax live-watch (D167)

- `build()` now `ref.listen`s on `orgSettingsProvider` (D20 precedent). When the setting changes and the cashier has NOT picked a rate from the tax dropdown this sale, `_taxRatePercent` updates and the Tax row + total rebuild at once — the sale re-rates without restarting.
- The cashier's pick wins: once a rate is picked from the dropdown (`_taxRateUserSet`), later Settings changes no longer touch this sale. The override lasts for the screen's lifetime; a fresh POS screen starts from the setting again.
- Dropdown safety: the offered rates always include the current rate (`{0, 5, 10, 16, 18, _taxRatePercent}`, sorted) — a Settings rate outside the usual set (e.g. 7%) renders as its own item instead of crashing the `DropdownButton` (a value with no matching item is a framework error).

### Part D — Branch code field in the add/edit branch form (D168)

- The form has a `Branch code (optional)` field, prefilled with the stored code on edit. Validation is the same rule as the mapper: blank is valid (derived default from the id, D164); otherwise the trimmed + uppercased input must be 2–8 uppercase letters/digits (`isValidBranchCode`, new pure function in `branch.dart` — `normalizeBranchCode` now uses it instead of its own inline regex). Invalid input shows `Branch code must be 2–8 uppercase letters or digits (e.g. DHA). Leave it blank to use the default.` and never saves. A typed code is normalized on save (`'lhr'` → `'LHR'`); blank saves `code: ''` and the repository derives the default as before. `BranchDirectoryNotifier.addBranch` / `updateBranch` pass the code into `validateBranchForm`, so the check holds below the dialog too.

## Files

| File | Change |
|---|---|
| `lib/models/supplier.dart` | `createdAt` field + `copyWith` / `fromMap` / `toMap` (D165) |
| `lib/models/order.dart` | `orderNumber` + `idempotencyKey`, `effectiveOrderNumber` / `effectiveIdempotencyKey`, `defaultOrderNumberForId`, `copyWith` / `fromMap` / `toMap` (D165) |
| `lib/models/branch.dart` | `isValidBranchCode` (D168); `normalizeBranchCode` reuses it |
| `lib/core/data/firestore_mappers.dart` | Supplier mapper writes/reads `createdAt`; order mapper falls back to the model's effective number/key, reads legacy docs safe (D165) |
| `lib/core/data/firestore_repositories.dart` | Firestore medicine `updateMedicine` barcode check (D166); order `createOrder` / `upsertOrder` return number+key, `updateOrder` effective fallbacks (D165); supplier `createSupplier` returns the stamped `createdAt` (D165) |
| `lib/core/services/repositories.dart` | Mock medicine `updateMedicine` barcode check (D166); mock order `createOrder` / `upsertOrder` assign + return number/key (D165); mock supplier `createSupplier` stamps, `updateSupplier` / `upsertSupplier` preserve `createdAt` (D165) |
| `lib/features/medicines/medicine_logic.dart` | `findBarcodeConflict` + `barcodeConflictMessage` (D166) |
| `lib/features/billing/pos_screen.dart` | `ref.listen` live-watches the tax rate; `_taxRateUserSet` manual-override flag; dropdown items always include the current rate (D167) |
| `lib/features/branches/branch_directory.dart` | `validateBranchForm` gains the `code` rule; `addBranch` / `updateBranch` pass it (D168) |
| `lib/features/branches/branch_form_dialog.dart` | Code field (prefill, normalize on save, blank → derived default) (D168) |
| `test/week6_day04_test.dart` | 32 new tests (below) |
| `docs/technical-decisions.md` | D165, D166, D167, D168 |
| `docs/week-6-tracker.md` | Day 31 section |

## Verification (measured by the builder, coordinator re-runs)

- `flutter analyze`: **clean** — "No issues found!"
- Day 31 tests alone (`test/week6_day04_test.dart`): **32/32 passed** — Part A: supplier model/mapper round-trips + legacy null, seeded suppliers null, order effective derivation + stable re-serialization, mapper round-trips + legacy-safe reads, seeded orders (491, first `ord-dha-1001` → `ORD-DHA-1001`), mock order/supplier repo number+key+createdAt behaviour. Part B: pure helper (conflict / own / empty / whitespace), seeded catalogue 180/180 distinct, mock repo reject/own/empty/upsert-exempt, Firestore repo reject/own/empty over the memory transport, edit-dialog widget test (error shown, dialog stays open, nothing written). Part C: Settings 0% → 10% re-rates the open sale (dropdown + `Tax (10%)` row), 7% renders via the dynamic item, cashier-picked 5% survives a later Settings change to 16%. Part D: `isValidBranchCode` + `validateBranchForm` pins, form widget tests (blank → `''` / `TOW`, `'lhr'` → `'LHR'`, invalid shows the error and never saves, edit prefills `ISB`).
- Full cumulative suite (Weeks 1–6): **954/954 passed** (baseline 922 + 32).
- Fresh `flutter build web --release`: **pass** — "✓ Built build/web" (46,732,782 bytes); prescription PNGs bundled (114,613 + 110,613 bytes, 8 manifest mentions).
- Nothing pushed — parent pushes committed files via browser upload.

## Follow-ups found

- Firestore `createOrder` / `upsertOrder` return-value fix (D165) is verified through the mock repo + mapper tests; the Firestore order repo itself has no test transport with `runTransaction` + `runBatchedWrites`, so its end-to-end return was verified by code inspection only. If Day 32 extends the fake transport, a Firestore order-repo round-trip test is the natural addition.
- `ref.listen` in `build()` (D167) follows the D20 precedent; a future refactor that moves the POS rate into a provider would remove the listener, but nothing in this change needs it.
