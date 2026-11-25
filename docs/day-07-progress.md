# Day 7 — Suppliers, Purchases, Prescriptions, Reports, Notifications, Settings + Full QA

**Date:** 24 Nov 2026. Final day of the Week 1 demo sprint.
**Status:** complete. `flutter analyze` clean, all 191 tests pass, web build PASSED.

## What was built

### 1. Suppliers (`lib/features/suppliers/`)

- Directory with search, list, add/edit with validation (name + phone
  required, duplicate phone rejected), contact info (email, address,
  tax number, payment terms, active flag).
- Detail screen: contact, **computed payable** (never a stored field),
  purchase history (all POs for that supplier), append-only ledger
  (payments / purchases / adjustments) with Record payment / Add
  purchase / Adjustment actions.
- Supplier balances use the same append-only ledger pattern as the
  customer khata (D37): `lib/models/supplier_ledger.dart`,
  `balanceAfterMinor` snapshot on every entry. The old stored
  `balanceMinor` field on `Supplier` was removed.
- Seed ledger (deterministic): Sami Pharmaceuticals Rs 125,000.00,
  MedServe Rs 48,250.00 (Rs 60,000 purchase − Rs 11,750 payment),
  Hassan Traders Rs 0.00, CareLine Rs 21,000.00.

### 2. Purchases (`lib/features/purchases/`)

- Purchase orders: create (supplier picker, items from the 180-medicine
  catalog, quantities, cost prices — default cost = 80% of sale price),
  statuses Draft → Approved → Partially received → Received /
  Cancelled, with guards on every transition
  (`canApprovePo` / `canReceivePo` / `canCancelPo`).
- Goods receiving is batch-wise: per-line quantity, batch number, mfg
  and expiry date pickers; partial receiving allowed (PO becomes
  Partially received, remaining lines stay open).
- Receiving immediately adds batches to inventory (visible in the
  Inventory module at once), charges the supplier ledger with the
  received value, and invalidates inventory / dashboard / order /
  notifications providers.
- Seed: 6 POs across both branches covering every status (PO-DHA-1001
  approved, PO-DHA-1002 draft, PO-DHA-1003 received, PO-GLB-1004
  partially received, PO-GLB-1005 draft, PO-DHA-1006 cancelled).

### 3. Prescription review (`lib/features/prescriptions/`)

- Queue of the 20 seeded prescriptions (Pending / Approved / Rejected)
  with search + status filters; detail screen shows the sample photo,
  patient, doctor, medicines, notes, linked order, and status timeline.
- Review actions: Approve / Reject / Needs clearer photo — rejection
  and clearer-photo both require a note.
- **Approving a prescription unblocks any order the Day 4 prescription
  dispatch guard was holding** (seed forces `rx-dha-1` and `rx-glb-11`
  Pending and links them to today's first order of each branch, so the
  unblock is demonstrable in the walkthrough).
- New-prescription form (patient, medicines text, notes) creates a
  Pending record linked to the current branch.
- **Photos:** on-device / bundled assets only, never network URLs.
  Two sample images created as repo assets
  (`assets/images/prescriptions/sample-prescription-1.png`,
  `sample-prescription-2.png`), clearly marked SAMPLE / "DEMO ONLY —
  NOT A REAL PRESCRIPTION", fictional patients and doctors. No Cloud
  Storage on Spark (see D45).

### 4. Reports (`lib/features/reports/`)

- Computed from orders + POS sales + inventory: daily sales
  (1/7/30-day filters), best-selling medicines, low-stock, expiry
  (near-expiry / expired), stock valuation; branch filter (All / DHA /
  Gulberg) + date-range filter.
- **Export: working CSV export** — one CSV per section (daily sales,
  best sellers, low stock, expiry), downloaded in the browser via
  `package:web` Blob + anchor (`lib/core/utils/file_download.dart`,
  platform-conditional stub/web). Verified by unit tests asserting
  exact CSV content and by the web build.
- **Real PDF export** via the `pdf` package (`buildSalesReportPdf`,
  `pdf 3.13.1`): title, period, totals, daily-sales and best-sellers
  tables. Unit test asserts the bytes start `%PDF` and length > 1000.
  Downloads on web the same way as CSV.
- Print-friendly view: a printable web view of the daily-sales report
  (opens the browser print dialog on web).

### 5. Notifications (`lib/features/notifications/`)

- In-app alerts computed from mock data: low-stock, near-expiry,
  expired batches, pending prescriptions (max 5), POs awaiting
  approval, today's new orders. Each alert carries the route it opens.
- Mark read / unread per alert, mark all read; unread state kept in a
  Riverpod notifier.
- The bell in the shell top bar now shows a live unread-count Badge
  and opens the notifications list.

### 6. Settings (`lib/features/settings/`)

- **General tab:** theme (Light / Dark / System) and default branch.
- **Branding tab:** edits the white-label BrandConfig — organization
  name, app name, receipt header, primary/secondary colours — and the
  shell rebrands immediately (top bar, sidebar, badges). Includes a
  Fazal Din preset (one tap: "Fazal Din Pharma Plus" + green palette)
  and Reset to defaults.
- **Roles & Permissions tab:** read-only matrix of the 10 roles × 21
  capabilities, transcribed from SRS §5.1. A demo role picker
  highlights one column only; enforcement in production is Firestore
  rules + custom claims, not the demo UI (documented on-screen).
- **Features tab:** enable/disable modules per organization (SRS
  FR-SYS-05) — 10 toggleable modules, Settings never disableable.
  Disabled modules disappear from the sidebar and the mobile More
  sheet; opening one directly shows a clear "module is disabled" state
  with Open Feature Settings + Back to Dashboard.

### Wiring (all routes now real)

- All Day 7 routes added to `app_router.dart`, every one wrapped in
  `FeatureGate`: `/suppliers`, `/suppliers/:id`, `/purchases`,
  `/purchases/new`, `/purchases/:id`, `/prescriptions`,
  `/prescriptions/:id`, `/reports`, `/notifications`, `/settings`.
- `ModulePlaceholderScreen` deleted (file removed) — **no placeholder
  screens remain anywhere in the app**. All 14 modules are real.
- `app_shell.dart`: bell → `_NotificationsButton` with unread Badge;
  sidebar and mobile More sheet hide disabled modules.
- `order_detail_screen.dart`: prescription section now shows the
  bundled SAMPLE image and links to the prescription review screen.
- Dependencies added: `pdf 3.13.1`, `web 1.1.2` (both resolved
  cleanly; `firebase_storage` stays out of pubspec).

## Verification

| Target | Result |
|---|---|
| `flutter analyze` | **No issues found!** |
| `flutter test` | **191/191 passed** (158 Days 1–6 + 33 new Day 7 tests in `test/day_07_test.dart`) |
| `flutter build web --release` | **PASSED** — `build/web/main.dart.js` 3,951,416 bytes |
| `flutter build apk` | Not attempted (environment-blocked, D14/D15) |
| Windows / iOS builds | Not attempted (impossible on this Linux VM) |

### Day 7 tests (33, `test/day_07_test.dart`)

- Supplier logic: outstanding sums, search, validation, signed amounts.
- PO flow: guards, status transitions, totals, receiving math
  (partial receiving → Partially received), form/receiving validation.
- Widget: PO flow + receiving updates inventory and supplier balance
  (end-to-end through the real router + repos); prescription review
  transitions + order unblock; report computations + CSV content;
  notification generation + read state; branding change re-renders the
  shell (Fazal Din preset); feature toggles hide modules from the
  navigation and show the disabled state on direct open.
- Full route walk: **all 14 modules load, no "coming Week 1" text, no
  "Page not found" anywhere.**

### Fixes made during Day 7

- Missing closing brace in `purchase_list_screen.dart` state class.
- Removed unused import in `supplier.dart`; removed unused dialogs
  import; removed unused `quantity` param in `_PoLineDraft`.
- Deprecated Flutter APIs replaced: `DropdownButtonFormField value:`
  → `initialValue:`, `RadioListTile groupValue/onChanged` →
  `RadioGroup`.
- Prescription notifier: falls back to the repo when the list has not
  been loaded yet (review from a deep link).
- PO receive test: date-picker loop now taps buttons by index
  (`mfgButtons.at(i)` / `expiryButtons.at(i)`).
- Widget tests use the tall 800×1600 viewport (D33 pattern) and
  `ensureVisible` for the feature-toggle switch.
- One unused import in `test/day_07_test.dart` caught by analyze
  after the final full run — removed; analyze clean again.

## Files created / changed

**Created (35):**

- `lib/models/supplier_ledger.dart`, `lib/models/purchase_order.dart`
- `lib/features/suppliers/supplier_logic.dart`,
  `suppliers_provider.dart`, `supplier_list_screen.dart`,
  `supplier_detail_screen.dart`
- `lib/features/purchases/purchases_logic.dart`,
  `purchases_provider.dart`, `purchase_list_screen.dart`,
  `purchase_form_screen.dart`, `purchase_detail_screen.dart`
- `lib/features/prescriptions/prescriptions_logic.dart`,
  `prescriptions_provider.dart`, `prescription_list_screen.dart`,
  `prescription_detail_screen.dart`
- `lib/features/reports/reports_logic.dart`, `reports_provider.dart`,
  `reports_screen.dart`
- `lib/features/notifications/notifications_logic.dart`,
  `notifications_provider.dart`, `notifications_screen.dart`
- `lib/features/settings/feature_config.dart`, `feature_gate.dart`,
  `roles_permissions.dart`, `settings_screen.dart`
- `lib/core/utils/file_download.dart`, `file_download_stub.dart`,
  `file_download_web.dart`
- `assets/images/prescriptions/sample-prescription-1.png`,
  `sample-prescription-2.png`
- `test/day_07_test.dart`

**Changed:**

- `lib/models/supplier.dart` (stored balance removed, contact fields),
  `lib/models/prescription.dart` (`copyWith`, `medicinesText`, photo
  doc corrected), `lib/models/models.dart` (exports)
- `lib/core/services/demo_seed_data.dart` (supplier ledger seed, 6 POs,
  prescription photo assets + forced Pending links)
- `lib/core/services/repositories.dart` (supplier ledger methods, PO
  repository + mock, prescription review/create)
- `lib/core/routing/app_router.dart` (Day 7 routes + FeatureGate)
- `lib/app/shell/app_shell.dart` (notifications bell + Badge, disabled
  modules hidden)
- `lib/features/orders/order_detail_screen.dart` (prescription section)
- `pubspec.yaml` / `pubspec.lock` (`pdf`, `web`)
- `test/day_02_test.dart` (Suppliers/Prescriptions placeholder
  expectations → real screens)
- `lib/shared/widgets/module_placeholder_screen.dart` **deleted**;
  Day 7 `.gitkeep` files deleted
- Docs: `docs/demo-guide.md` (finalized), `docs/known-limitations.md`
  (new), `docs/technical-decisions.md` (D41–D51),
  `docs/sprint-tracker.md` (Day 7 + demo assembly checked off)

## Demo status vs SRS §8.4 acceptance checklist

| Criterion (SRS §8.4) | Status |
|---|---|
| Login as Owner and as Cashier with demo credentials | ✅ Pass — Day 3, re-verified in final route walk |
| Full sale (scan → pay → receipt) on desktop and mobile | ✅ Pass — Day 6 POS, web build passes; mobile layout verified by widget tests (tall viewport), not by a physical phone |
| FEFO in action + expired batch blocked | ✅ Pass — Day 5/6 shared guard, tests cover both |
| Branch switching shows different stock/sales | ✅ Pass — Day 2/3, re-verified in widget tests |
| Daily sales report and export | ✅ Pass — Day 7: CSV (per section) + real PDF export, web download verified |
| WhatsApp order through full status flow | ✅ Pass — Day 4 (manual phone/WhatsApp entry, no WhatsApp API) |
| No dead buttons in demo walkthrough | ✅ Pass — full route walk test: 14 modules, no placeholders, no dead screens |
| Client feedback / scope freeze | ❌ Not done — client walkthrough has not happened; Hadi's requirements (medicines count, delivery areas, payment method, branch cities, logo + brand colours) still awaited |

## Blockers (Dazy-only, unchanged)

- Firebase project creation (needs Dazy's Google account decision) —
  no cloud sync until then; demo is local mock data only.
- GitHub repo name/visibility.
- Hadi's requirements (medicines count, delivery areas, payment
  method, branch cities, logo + brand colours) — needed for the
  client walkthrough and for real branding.
- APK build remains environment-blocked in this sandbox (D14/D15);
  Windows build unverified on this VM.

## Notes / corrections

- Seed is **491 orders**, not 499 — the Day 3/4 docs saying 499 are
  wrong (D31); the demo guide now states 491.
- Catalogue is **180 medicines** (not 14) since Day 5; the demo guide
  now says so.
- All 14 modules are real as of Day 7; the demo guide's "placeholder
  screens" limitation is removed.
