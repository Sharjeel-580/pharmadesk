# Day 38 — Week 8 Day 1 Progress (26 Nov 2026)

**Scope:** brief §1 — SRS acceptance checklist, formal pass (D176).
Re-verify EVERY SRS §8.4 demo acceptance criterion on the final tree,
one by one, with evidence, then the §9 production-scope checklist row
by row. Anything failing goes on the Week 8 fix list; anything needing
the client or a live Firebase project is recorded as a known caveat,
never invented or silently passed.

**Result: 7 of the 8 §8.4 criteria PASS on this tree** (each pinned by
a new test in `test/week8_day01_test.dart`, 21 new tests). **Criterion
8 is BLOCKED-CLIENT** — it needs the client walkthrough (Phase 5),
which has not happened; there is no client feedback and no signed
scope freeze anywhere in docs. No code fix was needed today: no §8.4
criterion failed on this tree. The §9 pass found **5 GAPs that are
buildable in Week 8** (Excel export, bulk catalogue import, keyboard
shortcuts, purchase returns, employee-performance report) plus gaps
that need the client or a live Firebase project; they are listed in
§3 as the Week 8 fix list, not smuggled into this day.

## 1. §8.4 demo acceptance criteria

### 1. PASS — Client can log in as Owner and as Cashier
- Logic: owner (`owner@demo.pharmadesk` / `demo1234`) signs in as
  Hassan Raza, all branches; cashier signs in as Usman Tariq, home
  branch Gulberg — right role key, name and branch for both.
- Widget: a typed owner login opens the owner dashboard.
- Tests: "owner and cashier sign in with the demo credentials",
  "typed owner login opens the owner dashboard". (All five roles were
  already re-pinned in Day 37; this day re-pins the two the
  criterion names.)

### 2. PASS — Full sale (scan → pay → receipt) on desktop and on mobile
- Logic (cashier, Gulberg): scanning the seeded Panadol Extra barcode
  `8901000000001` resolves to the FEFO batch; a 2-unit cash sale
  (Rs 1,000 handed over) saves with an invoice number, the sale line
  carries the scanned FEFO batch id, that batch's stock drops by
  exactly 2, the sale is listed, and `receiptText` carries the
  invoice number, the branch name and the total.
- Widget desktop (1440×900): POS renders, empty cart leaves
  "Complete Sale" disabled (an honest disabled state, not a dead
  button), "Simulate scan" adds a line and enables it, Card is picked
  on the payment segmented button, "Complete Sale" navigates to the
  receipt screen (`Receipt <invoiceNumber>`, Invoice row) — **0
  distinct overflows** (corrected `FlutterError.onError` trap).
- Widget mobile (390×844): the same flow end to end — scan, Card,
  complete, receipt — **0 distinct overflows** (same trap).
- Tests: "scan → FEFO allocate → completeSale → receipt (cashier,
  Gulberg)", "desktop POS completes a card sale and opens the
  receipt", "mobile POS completes a card sale at 390px".

### 3. PASS — FEFO in action; expired batch blocked
- Seeded FEFO: Panadol Extra at DHA picks batch `DHA-1-2-173`
  (earliest-expiry sellable), Risek 20 picks `DHA-3-2-863` — asserted
  on **batch number**, as in Day 37 (the row id is a mock id,
  `inv-DHA-2`, not the number; see "Test-side corrections").
- Expired-only medicine: Levaquin (`med-gen-021`, barcode
  `8902000000020`) is seeded at DHA with exactly one batch, expired,
  with stock on hand. Scanning it reports `notSellable`;
  `allocateFefo` throws `ArgumentError`; `completeSale` returns
  "only 0 unit(s) sellable" and saves nothing (sale count unchanged).
- Synthetic: an expired batch with the earliest expiry is never
  picked — `fefoBatchFor` returns the later valid batch. (`fefoBatches`
  only *orders* — earliest first, expired included; only the pick
  skips the expired row. The first version of this test asserted the
  filtered order and was corrected, not the app.)
- Tests: "seeded FEFO picks the earliest-expiry batch (Panadol Extra,
  DHA)", "expired-only medicine: scan refuses, allocation throws,
  sale saves nothing", "an expired batch is never picked even with
  the earliest expiry".

### 4. PASS — Branch switching shows different stock/sales
- Dashboard KPIs, re-pinned exactly (Day 37 figures, same seed, same
  day): DHA today sales Rs 6,990.00 vs Gulberg Rs 5,210.00; today
  orders 7 vs 5; 30-day revenue Rs 494,480.00 vs Rs 271,980.00;
  30-day orders 284 vs 152; low-stock 74 vs 72; near-expiry 129 vs
  147; expired 30 vs 29; pending prescriptions 2 vs 4.
- Orders: 319 DHA vs 172 Gulberg. Reports (30-day): total sales,
  total orders, stock valuation and the daily series all differ per
  branch.
- Tests: "dashboard KPIs differ on every figure, DHA busier (Day 37
  pin)", "orders and reports are branch-scoped".

### 5. PASS — Daily sales report and export
- Daily report for today: DHA 7 orders / Rs 6,990.00 (one daily row,
  7 orders, 699000 minor); Gulberg 5 / Rs 5,210.00.
- CSV: `dailySalesCsv` starts `Date,Orders,Sales (Rs)` and contains
  today's row `2026-11-26,7,6990.00`; best-sellers CSV header pins.
- PDF: `buildSalesReportPdf` (30-day DHA report) returns real PDF
  bytes (`%PDF` magic, > 1,000 bytes).
- Widget: the reports screen carries one wired "Export PDF" action
  and wired "Export CSV" actions (every `SectionHeader` action has a
  non-null `onAction`).
- Tests: "daily report for today: DHA 7 orders / Rs 6,990.00,
  Gulberg 5 / Rs 5,210.00", "daily sales CSV exports the report
  rows", "sales report PDF is real PDF bytes", "reports screen offers
  wired Export PDF and Export CSV actions".
- Note (not a failure of this criterion): **Excel export does not
  exist** — zero matches for `xlsx`/`excel` anywhere in `lib/` or
  `test/`. §8.4 asks for "export it" (CSV + PDF satisfy it); Excel is
  a §9 Reports-row gap (§3).

### 6. PASS — WhatsApp order through the full status flow
- End to end through `OrderQueueNotifier`: a WhatsApp-source delivery
  order (DHA, Panadol Extra ×2) is created with number `ORD-DHA-…`,
  advances New → Confirmed → Processing → Ready, takes rider
  `rider-1` at Ready, advances Dispatched → Delivered, and a further
  advance returns `false` (Delivered is terminal). Status re-read
  from the repository after every step.
- Guard still holds (Day 37 pin): `ord-dha-1312` linked to Pending
  `rx-dha-1` is blocked at dispatch ("still pending pharmacist
  review"); after approval the reason clears.
- Tests: "WhatsApp order walks New → Delivered with a rider
  assigned", "prescription-linked order is still held at dispatch
  (guard pin)".

### 7. PASS — No dead buttons in the demo walkthrough (scoped)
- Route walk (owner, 1280×800): all 14 demo-walkthrough routes
  resolve with their screen marker and no "Page not found" / "coming
  Week 1" placeholder — `/dashboard`, `/billing`, `/billing/history`,
  `/inventory`, `/orders`, `/reports`, `/finance`, `/suppliers`,
  `/purchases`, `/prescriptions`, `/customers`, `/settings`,
  `/branches`, `/notifications`.
- Wired primary actions, checked by `onPressed != null` (not just
  presence): POS "Complete Sale" is `null` with an empty cart and
  non-null once a line is scanned; every reports "Export PDF"/"Export
  CSV" action is wired; the order-detail "Mark Confirmed" button is
  wired and, when tapped, advances the order to Confirmed (button
  becomes "Mark Processing", stored status Confirmed).
- Scope note, stated plainly: this is the **demo-walkthrough**
  scope — the exhaustive 35-desktop + 24-mobile screen walk with the
  corrected trap is D177 / Day 39. If it finds a dead button there,
  that is a Day 39 defect, not a contradiction of this verdict.
- Tests: "demo-walkthrough routes resolve, no placeholder, no 404",
  "order detail advance button is wired and advances".

### 8. BLOCKED-CLIENT — Client feedback recorded; scope freeze signed (Phase 5)
- No client walkthrough has happened; no client feedback is recorded
  anywhere in docs; no scope freeze is signed. Phase 5 (client
  testing & feedback, SRS §10) has not started — the demo has not
  been put in Hadi's hands (v4 video + pricing PDF send is
  unconfirmed, per memory). There is nothing to verify on this tree,
  so nothing is claimed. **Needs: the client walkthrough + a signed
  Phase 5 scope freeze.**

## 2. §9 production-scope checklist

Verdicts: PASS = the row works end to end on this tree (named test
or concrete check); GAP = built partially or not at all, fixable in
code; BLOCKED-CLIENT / BLOCKED-DAZY = needs the client / a live
Firebase project. "Existing test" citations name the files that
carry the coverage; they were not re-run individually today (the
full cumulative suite is green — see Verification).

| Area | Verdict | Evidence |
|---|---|---|
| Organization | **GAP** | White-label Brand Settings work (incl. the Fazal Din preset, `white_label.dart`: default `PharmaDesk`, preset `Fazal Din's Pharma Plus`); but only the demo org exists (`demoOrganizationId = 'org-fazal-din-demo'`). Real org setup needs the client's brand assets (Appendix A Q15). |
| Branches | **GAP** | 2 demo branches seeded (`demoBranches`, 2 entries). 8 own branches need the client's branch list (Appendix A Q1); architecture supports unlimited branches. Franchises stay out of scope (later phase). |
| Users & roles | **GAP** | Matrix + gates built and tested: 10 roles × 21 capabilities displayed (`roles_permissions.dart`); in-app enforcement via `permission_service.dart` + route gates (D174: all 10 roles × `/inventory/quarantine-outcomes`). Real staff accounts do not exist — needs the client staff list (Appendix A Q7). |
| Core modules A–G | **GAP** | Transfers PASS (screens + `transfer_logic.dart`; tests week2_day01, week4_day02/04/05, week5_day01/02/04/05); stock counts PASS (`stock_operation_dialogs.dart` + engine; tests week2_day01/02/04/05, week3_day03); branch financial statements PASS (`statements_screen.dart` per-branch cards; D128, week4_day03); branch comparison PASS (tested today, §9 test 1). **Missing: purchase returns** — no flow in `lib/` (only a `SupplierLedgerEntryKind.purchaseReturn` label); **employee-performance reports** — no such report in `lib/`; **login activity + performance** — only the `lastLoginAt` schema field. Attendance + shifts and salary records exist as screens (tests week2_day01/04/05, week3_day01). |
| POS | **GAP** | Split payments PASS (D137; tests week2_day01, week3_day03, week4_day05, week5_day05, week6_day05); offline queue PASS (a completed sale enqueues exactly one sync op — tested today, §9 test 2; drain via `processSyncQueue` tested week2_day01, week3_day03, week4_day05, week5_day05, week6_day05). **Missing: keyboard shortcuts** — zero matches for `Shortcuts`/`CallbackAction`/`LogicalKeyboardKey`/`RawKeyboardListener` in `lib/` (SRS §4.3 lists them Demo ✓ / Prod ✓); **thermal printer** — browser print works, but network/USB printers are documented stubs that report "not configured" (`receipt_printer.dart`) — needs the client's printer model (Appendix A Q6); **mobile camera scanning** — only `SimulatedBarcodeScanner` exists, `HardwareBarcodeScanner` is a stub (wedge scanners work through the scan field as typed input). |
| Inventory | **GAP** | Batches, FEFO, quarantine, rack/shelf locations (model `BranchInventoryLocation` + `branch_shelf_dialog.dart`, wired from medicine detail; tests day_05, week3_day05, week4_day05, week5_day01) and stock valuation all present. **Missing: bulk catalogue import (FR-INV-14)** — zero matches for bulk/catalogue import in `lib/`. |
| Orders & delivery | **GAP** | Full order flow PASS (tested today, criterion 6); rider management + assignment PASS (rider list/detail, `assignRider` one write path, D121). **Missing: dispatch/delivery customer notifications** — `firebase_messaging` is a dependency but has zero usage in `lib/` (only doc comments noting no Windows implementation); provider TBD per SRS R-13. No rider role exists in the SRS §5 matrix, so no separate rider app is specified — the dispatch-side screens are the scope. |
| Finance | **PASS** | Payables/receivables aging (tests day_07, week2_day05, week3_day03, week4_day03); branch statements (`statements_screen.dart`, per-branch cards); audit-friendly append-only records + audit log (D161/D162 guarded writes, finance agreement re-verified in D174). |
| Reports | **GAP** | Full report set + branch/date filters PASS; custom date filter exists (`showDatePicker`, `reports_screen.dart:897`); PDF + CSV export PASS (tested today, criterion 5). **Missing: Excel export** — zero matches for `xlsx`/`excel` in `lib/` or `test/`. |
| Optional modules | **BLOCKED-CLIENT** | O-1–O-11 unselected — the client has not chosen any (Appendix A Q14). Nothing is built as an optional module; expiry/low-stock alerts exist as built-in notifications, not as the priced O-4 module. |
| Security | **GAP** | In-app RBAC + route gates PASS (D174); audit logs PASS; Firestore + Storage rules exist as files (`firebase/firestore.rules`, `firebase/storage.rules`) — **but DRAFT, not deployed** (tested today, §9 test 3: header says "DRAFT ONLY … NOT deployed anywhere"; no `firebase_options.dart` anywhere). **Missing: custom claims** — zero matches in `lib/`/`firebase/` (`setUserClaims` is design-only in `firebase/functions-design.md`, Job 6); **App Check** — zero matches; **session/device management** — nothing in `lib/` (only the demo-session password reset); **secrets management** — `flutter_secure_storage` is a dependency with zero usage in `lib/`. Live-rules verification is BLOCKED-DAZY (no project). |
| Data | **BLOCKED-CLIENT** (with a GAP) | No client catalogue or stock register exists (Appendix A Q3); demo data is fictional and must not carry into production. The import path itself is also missing (bulk import GAP, Inventory row). |
| Infra | **BLOCKED-DAZY** | No Firebase project exists (no `firebase_options.dart`; rules draft-only). `firebase/functions-design.md` is design only — no Cloud Functions deployed, no scheduled exports, no FCM, no monitoring. Local backup/restore (export/import) works and is tested (Weeks 5–7). |
| Handover | **GAP** | Source code ✓; data model + rules + indexes ✓ (`firebase/` + SRS §3); backup/restore works in-app. **Not yet done: deployment guide, staff/owner user manual, admin manual, backup/restore guide** — deployment guide + user manual are D179 / Day 41; admin manual + backup/restore guide have no owner yet (see §3). Production credentials cannot be handed over — no project yet (BLOCKED-DAZY). |
| Support | **BLOCKED-CLIENT** | Post-launch bug-fix window + support plan terms are TBD — a commercial decision, not a technical one (SRS §9). |

### §8.3 demo deliverables (noted, not re-verified in depth)
1. Android demo APK — exists in the workspace (`pharmadesk-week6.apk`, CI-built). The demo guide's "No APK exists from this build" (Day 7) is stale.
2. Windows demo build — zips exist (`pharmadesk-windows-week3/4/5/6.zip`); still unverified on this Linux VM (needs real Windows hardware).
3. Demo Firebase project (Blaze) — **BLOCKED-DAZY**, none exists; no cloud-sync claim is made (SRS §8.3 item 3 allows exactly this).
4. Firestore seed data / seed script — **GAP**: no Firestore seed script exists (only the in-app mock seed `lib/core/services/demo_seed_data.dart`).
5. Demo credentials + user guide — credentials in the demo guide; the user manual is D179 / Day 41.
6. Screenshots + walkthrough video — `presentation-video/` exists (v4); not touched today.
7. Known-limitations document — exists (`docs/known-limitations.md`).

### Demo-guide discrepancies found (NOT fixed today — Day 41 refreshes it)
- Header says "Flutter + Firebase Spark, permanently free" — stale: Blaze was decided 25 Nov (Dazy), and the pubspec description still says Spark too.
- "Android APK: not in this build … No APK exists from this build" — stale: `pharmadesk-week6.apk` exists (CI-built).
- "Web … `main.dart.js` 3,951,416 bytes" — stale figure; today's web build is bigger (see Verification).
- "Full offline POS sync is production scope, not demo" — still true and consistent with the §9 POS GAP above.
- No demo fact (figure, login, guard, FEFO pick, purchase-list count) moved — the guide's §4/§6 figures still match the tree.

## 3. Week 8 fix list (from this day — for Day 39/42, not built today)

Buildable gaps, in priority order:
1. **Excel export** (§9 Reports; SRS §4.7 + FR-REP-05) — PDF + CSV exist; `.xlsx` needs a writer (no `excel` package in pubspec — adding a dependency in the final week needs a coordinator call, not a silent `pub add`).
2. **Bulk catalogue import, FR-INV-14** (§9 Inventory + Data) — Excel/CSV import with a validation report; also the path real client data would take.
3. **POS keyboard shortcuts, desktop** (§9 POS; SRS §4.3 Demo ✓) — e.g. focus scan, complete sale; none exist today.
4. **Purchase returns** (§9 Core modules D) — record a return against a PO/supplier with ledger + stock effect; only the ledger kind label exists.
5. **Employee-performance report** (§9 Core modules G) — sales by staff/cashier over a window; branch comparison exists, per-employee does not.
6. **Firestore seed script** (§8.3 item 4) — reproducible seed into a real project, for when the demo project exists.
7. **Thermal printer integration** (§9 POS) — needs the client's printer model first (Appendix A Q6); network/USB are honest stubs today.
8. **Login activity + performance** (§9 Core modules E) — surface `lastLoginAt` + per-staff activity; schema field only today.
9. **Handover docs without an owner yet** — admin manual + backup/restore guide (deployment guide + user manual are D179 / Day 41).

Not buildable without others (recorded, not on the fix list):
- Demo + production Firebase projects, custom claims, App Check, FCM, scheduled exports — **BLOCKED-DAZY** (project + billing creation is Dazy-only).
- Real org/branch/staff/data setup, optional-module selection, support terms, scope freeze — **BLOCKED-CLIENT** (Appendix A answers + Phase 5 walkthrough).

## 4. Test-side corrections made while building (no app defect)

- **FEFO pick asserted on the wrong field:** the first version asserted `fefoBatchFor(...).id == 'DHA-1-2-173'`; the pick's **batch number** is `DHA-1-2-173`, its row id is the mock id `inv-DHA-2` (Day 37 asserted `.batchNo`). Corrected to `.batchNo`, plus the Risek pin.
- **`fefoBatches` does not filter:** the first version of the synthetic test asserted `fefoBatches(..., now: ...)` returns the valid batch first — the function takes no `now` and only *orders* (earliest first, expired included); only `fefoBatchFor` skips expired rows. Test corrected to assert the ordering and the pick separately.
- **Cashier POS tests hit the FeatureGate:** `pumpRouterAppAsRole` injects the user without the sign-in flow, so the active branch stays the default DHA — a Gulberg cashier cannot use it and the POS renders the "No permission" screen instead. Real sign-in switches to the user's home branch (`auth_state.dart:64`). The tests now mirror sign-in with `switchTo(_glb)` before navigating. App behaviour is correct; the harness needed the mirror.
- **Order-detail tap missed:** the advance button sits below the fold; the tap needs `ensureVisible` first (hit-test warning otherwise).
- **Analyze hygiene:** three imports removed (`demo_accounts.dart` — also provided by `auth_state.dart`; `inventory_engine.dart` and `demo_seed_data.dart` — unused). No app code changed.

## Verification

- `flutter analyze`: **clean** — "No issues found!"
- Day 38 tests alone (`test/week8_day01_test.dart`): **21/21 passed** — criterion 1 (2), criterion 2 (3, incl. desktop + mobile widget sales), criterion 3 (3), criterion 4 (2), criterion 5 (4, incl. PDF/CSV), criterion 6 (2), criterion 7 (2), §9 evidence (3: branch comparison, sync enqueue, rules draft).
- Full cumulative suite (Weeks 1–8): **1159/1159 passed** (baseline 1138 + 21 new) — **confirmed** in the resume run (33:21).
- Fresh `flutter build web --release`: **pass** — `main.dart.js` **4,683,437 bytes**, run sequentially after the full suite — **confirmed** in the resume run.
- Prescription PNGs bundled (114,613 + 110,613 bytes in `build/web/assets/assets/images/prescriptions/`).

## Files changed

- New: `test/week8_day01_test.dart`, `docs/day-38-progress.md`
- Modified: `docs/technical-decisions.md` (D176), `docs/week-8-tracker.md` (Day 38 section)
- Untouched: `docs/demo-guide.md` (discrepancies noted in §2, refresh is Day 41), `presentation-video/`, no Firebase project created, nothing pushed to GitHub.

## Follow-ups (Week 8)

- **Super Admin franchise-view gate — STILL OPEN, awaiting Dazy's decision** (brief §4): no decision recorded anywhere in docs/; do not guess.
- **Live-Firestore E2E (all of it)** — BLOCKED on a live Firebase project (Dazy-only step): rules, custom claims, App Check, FCM, scheduled exports, sync sender, seed script — verification here is the fake-transport suite + file checks, stated plainly.
- **§8.4 criterion 8 (client feedback + scope freeze)** — BLOCKED-CLIENT; needs the Phase 5 client walkthrough.
- **Week 8 fix list (§3)** — 9 buildable gaps for Day 39/42; Excel export needs a coordinator call before a dependency is added.
