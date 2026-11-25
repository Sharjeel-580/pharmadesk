# Day 16 — Week 3 Day 4 Progress (26 Nov 2026)

**Scope:** Windows desktop verification + CI Windows build (Week 3
brief §2), the Day 3 D109 follow-up, and the Day 2 salary-edit
follow-up.

## What shipped

### 1. Windows desktop verification + sqflite_common_ffi (D110)
- `sqflite_common_ffi ^2.4.7` added to pubspec (with `sqlite3`).
  `flutter pub get` resolves cleanly.
- New `lib/app/desktop_bootstrap.dart`: `initDesktopPlatform()` —
  on Windows only, calls `sqfliteFfiInit()` and sets the global
  `databaseFactory = databaseFactoryFfi` before the app widget is
  built, so the sync queue persists in a real SQLite file on
  Windows instead of falling back to memory. Android/iOS keep the
  platform implementation; the web entry point never imports the
  file, so the web build never sees `dart:io` or `sqflite`. On any
  non-Windows host it is a no-op that returns immediately.
- `lib/main_desktop.dart` is now `async`
  (`WidgetsFlutterBinding.ensureInitialized()` first) and awaits the
  init. Its header comment records the verification; the stale
  "Phase 3 target — foundation shell only" line is retired.
- `sync_store_io.dart`: the in-memory fallback stays only as a
  safety net for a genuinely broken SQLite setup (comment updated).
- **firebase_messaging check (D4 closed for the entry path):** a
  grep over `lib/` finds NO Dart file importing
  `package:firebase_messaging` — only the two doc comments in
  `main_desktop.dart` / `desktop_app.dart` mention it. Nothing in
  the desktop entry path can hit the missing Windows plugin; push
  stays out of scope, Firestore live reads stay the desktop update
  path.
- **Not verified here:** `flutter build windows` cannot run on this
  Linux sandbox (D11) — the CI job `build-windows` owns that check
  (D113). No Windows binary has been built yet; do not claim one
  exists until that CI run goes green.

### 2. Desktop screens audit vs SRS D-01–D-35 (D110)
Walked the router + every feature screen at desktop size
(1920×1080, widget-tested — see §6). The app is one responsive
codebase: the shell renders the desktop layout (sidebar + top bar)
at ≥900px, so there is no mobile-only screen — every present
screen is the desktop layout. **22 desktop OK, 6 partial, 7
missing** (of 35).

| Screen | Status | Notes |
|---|---|---|
| D-01 Login | Desktop OK | Email + password, forgot password, demo-mode banner |
| D-02 Dashboard (Owner / HO) | Desktop OK | Branch comparison, alerts, top sellers |
| D-03 Dashboard (Branch) | Desktop OK | Same screen, branch-scoped |
| D-04 POS / Billing | Partial | Cart, discount, payment methods, credit, hold/resume, print — **no split payment** |
| D-05 Sales History / Invoices | Desktop OK | Search/filter, reprint, return/refund |
| D-06 Orders Queue | Desktop OK | Canonical status flow, rider assignment |
| D-07 Order Detail | Desktop OK | Customer, items, prescription, timeline, rider, payment |
| D-08 Prescription Review | Desktop OK | Photo, approve/reject, notes |
| D-09 Medicine List | Desktop OK | Search/filter, stock + price at a glance |
| D-10 Medicine Detail / Edit | Partial | Master fields + FEFO batches + adjust/count — **no location field, no per-medicine stock-movement history** |
| D-11 Batch & Expiry | Partial | Expiry buckets + Alerts tab inside Inventory — **no quarantine action in the UI** (status exists in the model, D68) |
| D-12 Stock Overview | Desktop OK | Inventory screen: branch stock, low-stock, valuation |
| D-13 Stock Receive | Desktop OK | Receive dialog + PO receiving |
| D-14 Stock Adjustment | Partial | Adjust dialog with reason — **no approval queue** (adjustment applies directly) |
| D-15 Stock Count | Desktop OK | Count dialog per batch, variance shown |
| D-16 Stock Transfer | **Missing** | Schema contract only (`stockTransfers`); no UI, no flow |
| D-17 Purchase Orders | Desktop OK | List, create, approve, status |
| D-18 Goods Receiving | Desktop OK | PO receiving, partial, batch creation |
| D-19 Suppliers | Desktop OK | List/detail, purchase + payment history, balances |
| D-20 Customers | Desktop OK | List/detail, history, credit balance, statement |
| D-21 Riders & Delivery | **Missing** | Rider assignment only inside Order Detail; no rider list/management screen |
| D-22 Staff / Employees | Desktop OK | Directory, branch assignment, role |
| D-23 Attendance & Shifts | Desktop OK | Attendance grid, shift planner |
| D-24 Finance — Cashbook | **Missing** | `finance_logic` / `finance_provider` exist; no cashbook screen |
| D-25 Finance — Payables / Receivables | **Missing** | Aging logic exists (D92); no aging screen (statements live in supplier/customer detail) |
| D-26 Finance — P&L / Statements | Partial | P&L section inside the Reports hub; no dedicated finance screen, no branch-statement screen |
| D-27 Reports Hub | Desktop OK | All reports with filters; PDF/CSV export; counters caption; paging |
| D-28 Branch Management | **Missing** | Only a default-branch dropdown in Settings; no branch list/detail, no franchise settings |
| D-29 Roles & Permissions | Desktop OK | Display-only matrix tab (D49) |
| D-30 Feature Modules | Desktop OK | Enable/disable modules tab |
| D-31 Brand Settings | Desktop OK | Branding tab (name, logo, colours, preview) |
| D-32 Notifications Center | Desktop OK | Derived alerts, routes to the item |
| D-33 Audit Log | **Missing** | Audit writer exists everywhere; no viewer UI |
| D-34 Settings (Org / Branch) | Partial | Theme, default branch, printer, demo mode — **no tax config, payment methods, receipt format, discount limits, sync status** |
| D-35 Backup & Restore | **Missing** | Exporter exists in the layer; no UI trigger, no restore screen |

No desktop layout defect was found that is small and safe to fix
in this day: the shell and all 28 present screens render at
1920×1080 without overflow in the widget tests (the route walk
pumps every one). The partials and missings above are recorded as
documented follow-ups (tracker §Follow-ups), not half-built.

### 3. CI Windows build job (D113)
- New `build-windows` job in `.github/workflows/build-apk.yml`
  (the existing `build-apk` job is untouched): `windows-latest`,
  checkout, JDK 17 (Temurin), Flutter 3.47.7, `flutter pub get`,
  `flutter analyze`, `flutter build windows --release -t
  lib/main_desktop.dart`, upload `build/windows/x64/runner/Release`
  as the `pharmadesk-windows` artifact (30-day retention, same as
  the APK). The APK job owns the test run; this job owns the
  desktop binary.
- Workflow YAML validated in the sandbox
  (`python3 -c "import yaml; yaml.safe_load(...)"` — parses, both
  jobs listed). **The first push containing this job exercises it**
  — until that run goes green, no Windows build claim is made.

### 4. Day 3 follow-up: inventory receive/adjust through the layer (D111, closes D109)
- `ProductionDataLayer.receiveStock` (new) and `adjustStock`
  (extended) are the single write paths for standalone stock
  receive / adjust, like `receiveGoods` (D103) is for PO
  receiving. Each enqueues one batched-write sync payload
  (receive → batch doc + stock-transaction doc; adjust →
  stock-transaction doc + inventory-doc update), so the Day 3
  sync-status chip on the inventory screen now moves for stock
  work. Returns restock already calls `layer.adjustStock`, so it
  enqueues for free, with the sale id in the payload as the
  movement's `referenceId`.
- Idempotency: optional `idempotencyKey` per call + a registry
  (D103 pattern) — a same-key retry returns the original batch /
  movement and moves no stock twice. The receive registry check
  runs BEFORE the repo write (the repo creates a new batch row per
  call).
- Engine ordering (caught by the tests): `receiveStock` loads the
  engine from live stock BEFORE the repo creates the batch —
  loading after would double-count the new batch in the counter.
  The test pins the counter at seeded-on-hand + received.
- `InventoryEngine.receive` gains an optional `referenceType`
  (default `goodsReceipt`); a standalone receive passes
  `stockReceive` with the key as the reference — a manual receive
  has no `goodsReceipts` document.
- `InventoryNotifier.receiveStock` / `adjustStock` now call the
  layer (actor from the signed-in user, demo fallback) and
  invalidate `syncStatusProvider` after a successful write.
  Signatures unchanged — dialogs and medicine-detail callers need
  no changes. `commitSale`'s repo-direct decrements are untouched
  (they belong to the sale's own payload).
- **Not routed:** `recordStockCount` still writes repo-direct —
  same routing, left as a Day 5 follow-up. The D54 gap still
  applies at the UI level (a retry after a failed submit mints a
  new key).

### 5. Salary edit flow (D112, closes the Day 2 edit follow-up)
- `SalaryNotifier.saveRecord` — gates on `canManageSalary`
  (`hrSalary` write: Owner / HO Admin / Accountant; Auditor
  read-only; everyone else none), validates with
  `validateSalaryRecord`, saves via `saveSalaryRecord`, refreshes.
  Returns `(record, error)` like the returns notifier.
- One Edit button per salary row, rendered only when
  `canManageSalary` passes for that row's branch. The dialog
  (`lib/features/staff/salary_edit_dialog.dart`) edits base /
  allowances / deductions in whole rupees with a live net preview
  (never negative). Saving creates the month's record or replaces
  it (keyed by employee + month, never a duplicate); a SnackBar
  confirms with the new net.
- An edited demo record stops being demo (`isDemo: false` — the
  figures are staff-entered now), so its Demo badge clears and
  the monthly totals move. The dialog says so when the row shows
  demo figures.
- **Not built:** no payroll history view, no bulk edit, no approval
  step — the SRS names no approval flow for salary edits and none
  was invented.

## Verification
- `flutter analyze`: **No issues found!** (zero errors, warnings and info lints)
- New tests: **21/21** (`test/week3_day04_test.dart`)
- Full suite: **534/534** (Week 1 + Week 2 + Week 3 Days 1–4; 513 before + 21 new, no earlier test touched)
- `flutter build web --release`: **Pass** (46,397,281 bytes)
- Workflow YAML validation: **Pass** (`yaml.safe_load` parses;
  jobs `build-apk` + `build-windows` listed)
- Prescription PNGs: **verified bundled** (D61 check — both sample
  PNGs in `build/web/assets/assets/images/prescriptions/` at their
  exact source sizes, 8 "prescription" mentions in the decoded
  manifest, both sample paths present)

## Decisions
D110–D113 in `docs/technical-decisions.md`.

## Files created / changed
- Created: `lib/app/desktop_bootstrap.dart`,
  `lib/features/staff/salary_edit_dialog.dart`,
  `test/week3_day04_test.dart`, `docs/day-16-progress.md`
- Changed: `lib/main_desktop.dart`, `pubspec.yaml`,
  `pubspec.lock`, `lib/core/data/sync_store_io.dart`,
  `lib/core/data/production_data_layer.dart`,
  `lib/core/data/inventory_engine.dart`,
  `lib/features/inventory/inventory_provider.dart`,
  `lib/features/inventory/inventory_screen.dart`,
  `lib/features/staff/salary_provider.dart`,
  `lib/features/staff/salary_logic.dart`,
  `lib/features/staff/salary_screen.dart`,
  `.github/workflows/build-apk.yml`,
  `docs/week-3-tracker.md`, `docs/technical-decisions.md`

## Follow-ups for Day 5 (QA)
- **First CI `build-windows` run** (on the coordinator's push):
  watch it — until it goes green there is no verified Windows
  binary. If it fails on the FFI/sqlite3 native build, the fix
  belongs in the Windows runner config, not the Dart code.
- **Stock count through the layer** (`recordStockCount` still
  repo-direct — same D111 routing, not done in this day).
- **The seven missing desktop screens** (D-16, D-21, D-24, D-25,
  D-28, D-33, D-35) and the five partials (D-04 split payment,
  D-10 location + stock history, D-11 quarantine action, D-14
  adjustment approval queue, D-26 dedicated finance screen,
  D-34 tax/payment/receipt/discount config) — all recorded in the
  tracker as follow-ups with reasons; none is half-built.
- **D54 gap, stock dialogs:** a retry after a failed receive /
  adjust submit mints a new key (same posture as POS before the
  dialog-held key). Worth a dialog-held key if stock retries ever
  need true dedupe.
