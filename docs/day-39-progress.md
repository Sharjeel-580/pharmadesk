# Day 39 — Week 8 Day 2 Progress (26 Nov 2026)

**Scope:** brief §2 — full screen walk, final (D177). Walk ALL 35
desktop screens (D-01–D-35) and ALL 24 mobile screens (M-01–M-24)
on the final tree: every screen resolves, every button does what its
label says, no dead ends, no placeholder/404. Fresh full 390px sweep
with the CORRECTED `FlutterError.onError` trap (D170/D174 standard).
Fix every walk defect the same day. Triage the Day 38 fix list.

**Result: the walk passes.** All 47 routes resolve at desktop
(1920×1080) and at phone width (390×844) with their markers, no
placeholder/404, and the fresh 390px sweep is **0 distinct
overflows** (corrected trap). The walk found **77 distinct overflows
at 390px** before fixes (76 on 15 routes + 1 login divider) — all
fixed in code the same day, each with a regression test in
`test/week8_day02_test.dart` (24 new tests, **24/24**). Two screens
do not exist and are recorded, not passed: M-23 Live Control Center
(O-11) and M-24 AI Assistant (O-2) — optional modules, never
selected, **BLOCKED-CLIENT**. No fix-list feature was built today;
today was the walk.

## 1. Desktop walk — D-01–D-35 (owner, 1920×1080)

Every row below was pumped as the owner at 1920×1080, navigated to
its route, and asserted on its marker. All PASS.

| Screen | Route | Marker asserted | Verdict |
|---|---|---|---|
| D-01 Login | `/login` (signed out) | Sign-in form renders | PASS |
| D-02 Dashboard (Owner / HO) | `/dashboard` | "Branch comparison" | PASS |
| D-03 Dashboard (Branch) | `/dashboard` (branch_manager) | "Branch dashboard", no owner comparison | PASS |
| D-04 POS / Billing | `/billing` | "Add medicines" | PASS |
| D-05 Sales History / Invoices | `/billing/history` | "Sales history" | PASS |
| D-06 Orders Queue | `/orders` | "newest first" | PASS |
| D-07 Order Detail | `/orders/ord-dha-1001` | "Status timeline" | PASS |
| D-08 Prescription Review | `/prescriptions/rx-dha-1` | "rx-dha-1" | PASS |
| D-09 Medicine List | `/medicines` | "Panadol Extra" | PASS |
| D-10 Medicine Detail / Edit | `/medicines/med-panadol-extra` | "Batches —" | PASS |
| D-11 Batch & Expiry | `/inventory` | "expiring ≤ 30 days" | PASS |
| D-12 Stock Overview | `/inventory` | "low stock" | PASS |
| D-13 Stock Receive | `/inventory` | "Receive stock" button | PASS |
| D-14 Stock Adjustment | `/inventory/adjustments` | "Adjustment Approvals" | PASS |
| D-15 Stock Count | `/inventory` (dialog) | "Stock count" tooltip → count dialog | PASS |
| D-16 Stock Transfer | `/inventory/transfers` (+ new + detail) | "Stock Transfers" | PASS |
| D-17 Purchase Orders | `/purchases` | "Purchase orders, goods receiving" | PASS |
| D-18 Goods Receiving | `/purchases/po-dha-1001` | "Receive goods" | PASS |
| D-19 Suppliers | `/suppliers` (+ detail) | "Profiles, contacts, purchase history" | PASS |
| D-20 Customers | `/customers` (+ detail) | "Directory, purchase history and khata" | PASS |
| D-21 Riders & Delivery | `/riders` (+ detail) | "Riders & Delivery" | PASS |
| D-22 Staff / Employees | `/staff` | "Staff directory" | PASS |
| D-23 Attendance & Shifts | `/staff/attendance`, `/staff/shifts` | "Attendance —" / "Shifts —" | PASS |
| D-24 Finance — Cashbook | `/finance/cashbook` | "Cashbook" | PASS |
| D-25 Finance — Payables / Receivables | `/finance/aging` | "Payables & Receivables" | PASS |
| D-26 Finance — P&L / Statements | `/finance/statements` | "P&L & Statements" | PASS |
| D-27 Reports Hub | `/reports` | "Daily sales" | PASS * |
| D-28 Branch Management | `/branches` (+ detail) | "Add branch" | PASS |
| D-29 Roles & Permissions | `/settings` → tab | "Roles & Permissions" | PASS |
| D-30 Feature Modules | `/settings` → tab | "Features" | PASS |
| D-31 Brand Settings | `/settings` → tab | "Branding" | PASS |
| D-32 Notifications Center | `/notifications` | "Alerts computed from live demo data" | PASS |
| D-33 Audit Log | `/audit-log` | "No audit entries match these filters." | PASS |
| D-34 Settings (Org / Branch) | `/settings` | settings tabs render | PASS |
| D-35 Backup & Restore | `/backup` | "Backup status" | PASS |

\* D-27: the screen resolves and PDF + CSV export are wired (Day 38
§5). Native `.xlsx` export is a documented post-handover gap —
coordinator decision, see §6.

Extra routes walked beyond the 35 (same shell, asserted in the same
tests): `/profile`, `/orders/new`, `/orders/:id/edit`,
`/inventory/quarantine-outcomes`, `/billing/returns`,
`/billing/returns/new`, `/billing/receipt/sale-missing`,
`/finance`, `/finance/franchise`, `/branches/:id` — all resolve with
markers, no placeholder/404. Unknown routes show "Page not found"
with a working "Go to Dashboard" button (verified, §4).

## 2. Mobile walk — M-01–M-24 (390×844, corrected trap)

Same 47 routes at 390×844, each asserted on its marker, with the
corrected `FlutterError.onError` trap installed (see §3). All
resolve; sweep total 0.

| Screen | Route | Verdict |
|---|---|---|
| M-01 Login | `/login` (signed out, 390px) | PASS (1 divider overflow found + fixed, §4) |
| M-02 Owner Dashboard | `/dashboard` | PASS |
| M-03 Branch Manager Dashboard | `/dashboard` (branch_manager) | PASS |
| M-04 Staff Dashboard (role-based) | `/dashboard` (cashier, pharmacist) | PASS |
| M-05 Quick Sale (mobile POS) | `/billing` | PASS |
| M-06 Orders List | `/orders` | PASS |
| M-07 Order Detail | `/orders/ord-dha-1001` | PASS |
| M-08 Prescription Review | `/prescriptions/rx-dha-1` | PASS |
| M-09 Medicine Search & Detail | `/medicines`, `/medicines/med-panadol-extra` | PASS |
| M-10 Stock Check | `/inventory` | PASS |
| M-11 Stock Receive (mobile) | `/inventory` → "Receive stock" dialog | PASS † |
| M-12 Stock Count (mobile) | `/inventory` → "Stock count" dialog | PASS |
| M-13 Stock Transfer Request | `/inventory/transfers` (+ new + detail) | PASS |
| M-14 Purchase Orders (view/approve) | `/purchases` (+ detail) | PASS |
| M-15 Suppliers (view) | `/suppliers` (+ detail) | PASS |
| M-16 Customers (view + khata) | `/customers` (+ detail) | PASS |
| M-17 Rider — My Deliveries | `/riders`, `/riders/rider-1` | PASS ‡ |
| M-18 Finance Snapshot | `/finance`, `/finance/cashbook` | PASS |
| M-19 Reports (mobile) | `/reports` | PASS |
| M-20 Notifications | `/notifications` | PASS |
| M-21 Branch Switcher | shell top-bar switcher | PASS — lists both branches, switches DHA ↔ Gulberg |
| M-22 Profile & Settings | `/profile` | PASS |
| M-23 Owner Live Control Center (O-11) | — does not exist | **BLOCKED-CLIENT** (optional module, never selected) |
| M-24 AI Assistant (O-2) | — does not exist | **BLOCKED-CLIENT** (optional module, never selected) |

† M-11: the receive dialog opens and works; the *camera* barcode
scan itself is not in the widget walk (known §9 gap — mobile camera
scan missing, not a walk defect).

‡ M-17: covered via the rider list + rider detail routes; there is
no separate rider-role "my deliveries" route — the detail screen is
the deliveries view.

## 3. Fresh full 390px sweep — 0 distinct overflows (corrected trap)

**Trap (stated, D170/D174 standard):** `FlutterError.onError`
installed before pumping, counting DISTINCT `RenderFlex overflowed`
messages (each occurrence inside a distinct message counted once);
forwarded to the previous handler. The D160 `takeException` drain
is NOT the measurement — it collapses simultaneous overflows into
"Multiple exceptions (N)…" with no "RenderFlex overflowed" text.

- **Before fixes:** **76 distinct overflows on 15 routes** (per-route
  probe, trap) + 1 login divider overflow (M-01 test) = **77 total**.
  Per route: `/orders/ord-dha-1001` 1, `/inventory/transfers` 1,
  `/inventory/transfers/new` 2, `/inventory/transfers/tr-demo-1` 1,
  `/riders` 1, `/riders/rider-1` 1, `/customers/cust-1` 1,
  `/purchases/new` 1, `/purchases/auto` 37, `/purchases/po-dha-1001`
  4, `/staff` 8, `/staff/attendance` 7, `/staff/salary` 8,
  `/settings` 1, `/audit-log` 2.
- **After the first fix batch (fixes 1–10 in §4):** 76 → **34**
  (`/purchases/auto` 13, `/staff` 7, `/staff/attendance` 7,
  `/staff/salary` 7; every other route 0).
- **After the StatusBadge Wrap + name-row Wraps (fixes 11–12):**
  34 → **13** (`/purchases/auto` only).
- **After the salary net-amount fix + auto badge cap:** **0**.
  Final probe: `PROBE TOTAL :: 0` over all 47 routes.
- **Day tests:** the mobile walk and the fresh sweep test both assert
  0 distinct overflows; **24/24 pass**.

**A note on the measure:** the test font renders text ~1.8× wider
than real Roboto (D170 comment in `lib/core/widgets/badges.dart`).
Every fix below therefore either wraps (never ellipsizes money or
names) or scales down a complete figure — nothing is hidden by
clipping, and on a real phone each fix renders at full size or
unchanged. The D170 standard treats the trap count as the measure,
and it is 0.

**D170 fixes re-verified (still in place, 6 tests, trap):**
supplier detail screen fits at 390px (badge + large-payable
variants), `/reports` branch filter dropdown fits when open,
supplier payment dialog method dropdown fits, `/branches` list rows
fit, sales history paged list fits (D170 `PagedListControls` Wrap
fix). All 6 pass.

**Transient 176px overflow (first run only):** one early run showed
a disposed Row overflowing 176px (creator DEFUNCT — splash →
login/dashboard transition). It never reappeared in any post-fix
run (probe runs 2–4 and the full day file, all green); not a
screen defect, not chased further.

## 4. Defects found + fixed (same day, code fix + regression test)

All twelve are 390px layout defects found by the walk/sweep. No
screen was broken at desktop width; every fix preserves the desktop
layout and the real-phone rendering.

1. **StatusBadge root cause — internal `Row` → `Wrap`
   (`lib/core/widgets/badges.dart`).** The badge's inner
   `Row(mainAxisSize: min)` never wraps its label: in a narrow
   parent the label Text is laid out unbounded and the badge measured
   110px inside a 77px parent. A micro-probe of four variants
   (loose Flexible / tight Flexible / direct Text / Wrap) proved only
   the Wrap fits (77.0×27.0, label flows below the dot). The Wrap
   preserves D170: money stays complete, wraps instead of
   ellipsizing. This one fix cleared the badge rows in the order
   detail, transfer detail, rider detail, purchase detail, auto
   list, and the staff/attendance/salary name rows.
2. **Badge rows → Wrap (spacing 8, runSpacing 8):**
   `order_detail_screen.dart:82` (3 badges),
   `stock_transfer_detail_screen.dart:100`,
   `rider_detail_screen.dart:81`, `purchase_detail_screen.dart:67`.
3. **`isExpanded: true` on DropdownButtonFormField:**
   `stock_transfer_form_screen.dart:90` and `:120`,
   `purchase_form_screen.dart:148` (supplier field).
4. **Filter dropdowns capped at 280px + `isExpanded: true`:**
   `stock_transfer_list_screen.dart:70`,
   `rider_list_screen.dart:60`, `staff_list_screen.dart:82`,
   `salary_screen.dart:97`, `audit_log_screen.dart:309/:323/:334/:345`
   (all four filters). The cap keeps desktop filters side-by-side
   (unlike a bare `isExpanded`).
5. **Single-column dropdowns → `isExpanded: true`:**
   `auto_purchase_list_screen.dart:701` (supplier dropdown),
   `settings_screen.dart:159` (default branch).
6. **Login divider (`login_screen.dart:226`):** label Text wrapped
   in `ConstrainedBox(maxWidth: 220)` + `TextOverflow.ellipsis`
   (fits on a real phone unchanged; degrades gracefully in the test
   font).
7. **Customer detail `_DetailRow` (`customer_detail_screen.dart:475`):**
   value Text → `Flexible` (wraps).
8. **Purchase detail `_TotalRow` (`purchase_detail_screen.dart:291`):**
   label Text → `Flexible` (label wraps; money value stays complete).
9. **Auto list "Estimated total" row
   (`auto_purchase_list_screen.dart:292`):** label → `Flexible`.
10. **Audit log restructure (`audit_log_screen.dart`):** outer
    `Padding > Column` → `SingleChildScrollView(padding: 24, child:
    Column(...))`; data branch `Expanded(Column([filters,
    Expanded(SingleChildScrollView(PagedList))]))` → plain
    `Column([filters, PagedList])` (PagedList is a plain Column and
    scrolls with the page — the staff-list pattern). Fixed the 116px
    BOTTOM overflow and the filter dropdown in one change.
11. **Name rows → Wrap (D170 branches pattern: badge flows below the
    name when they don't fit; name wraps, never ellipsized):**
    `staff_list_screen.dart:267` (name + Active/Inactive),
    `attendance_screen.dart:236` (name + displayStatus),
    `salary_screen.dart:408` (name + conditional Demo badge).
12. **Salary net amount (`salary_screen.dart:450`):**
    `ConstrainedBox(maxWidth: 150)` + `FittedBox(fit:
    BoxFit.scaleDown, alignment: centerRight)` around the net Text.
    The avatar Row's non-flex children (avatar 48 + gaps + net Text
    ~194–210px in the test font + edit button 48) exceeded the
    310px card. The figure stays complete and scales only when it
    doesn't fit; on a real phone the net is ~110px, under the cap,
    so it renders unchanged. (Flex-sharing was rejected: it would
    force the net to wrap mid-number on real phones too.)

A first hypothesis (badge `Flexible` → `Flexible(fit:
FlexFit.loose)`) was tried and superseded by the Wrap fix after the
micro-probe proved loose does not wrap.

**Buttons do what they say (8 checks, all pass):**
- Inventory "Receive stock" opens the receive dialog.
- Stock count opens the count dialog from a batch row.
- Purchase detail "Receive goods" opens the receive dialog
  ("Receive goods — PO-DHA-1001").
- Cashbook "Add entry" opens the add-entry dialog.
- Prescription Approve approves immediately (snackbar "Prescription
  rx-dha-1 approved — linked orders can now be dispatched.") and the
  Approve action disappears. Review is pharmacist-only (SRS §5.1
  `rxReview`): the Owner sees the button disabled, so this taps as
  the pharmacist — the test pumps as pharmacist, not owner.
- Notifications "Mark all read" → badge "All notifications read".
- Order form empty save → error box "Please fix the following:".
- Unknown route shows "Page not found" with a working "Go to
  Dashboard" button.

## 5. Day 38 fix-list triage (docs/day-38-progress.md §3)

None of the nine items was a walk defect, and none was built today
— today was the walk; the walk's defects were the 12 layout fixes
in §4, all fixed. Disposition of each item:

| Item | Disposition | Reason |
|---|---|---|
| 1. Excel export | **Documented post-handover gap** | Coordinator decision (§6): no new dependency in Week 8; CSV already works and opens in Excel with the same data. |
| 2. Bulk catalogue import (FR-INV-14) | **Deferred — stays a documented gap** | Feature build, not a walk defect. No build scope on a walk day; Day 42 is a QA sweep, not a build day. Needs a coordinator call if it is to be built at all. |
| 3. POS keyboard shortcuts | **Deferred — stays a documented gap** | Same: feature build, no build scope today or on Day 42. |
| 4. Purchase returns | **Deferred — stays a documented gap** | Same: record-a-return against a PO/supplier with ledger + stock effect is a feature build, not a walk defect. (The `/billing/returns` screen itself resolves and renders.) |
| 5. Employee-performance report | **Deferred — stays a documented gap** | Same: per-employee report is a feature build. |
| 6. Firestore seed script | **Deferred — stays a documented gap** | Needs a real Firebase project to seed into (BLOCKED-DAZY); the in-app mock seed already exists. |
| 7. Thermal printer integration | **BLOCKED-CLIENT** | Coordinator decision (§6): needs the client's printer model; manual-entry fallback stays. |
| 8. Login activity + performance | **Deferred — stays a documented gap** | Feature build (surface `lastLoginAt` + per-staff activity); schema field only today. |
| 9. Admin manual + backup/restore guide | **Deferred to Day 41 (D179)** | Documentation, not a walk defect. Day 41 owns handover docs; if its scope does not cover the admin manual + backup/restore guide, they stay a documented post-handover gap. |

Not on the fix list (recorded, unchanged): demo + production
Firebase projects, custom claims, App Check, FCM, scheduled exports
— BLOCKED-DAZY; real org/branch/staff/data setup, optional-module
selection, support terms, scope freeze — BLOCKED-CLIENT.

## 6. Coordinator decisions (recorded, not re-litigated)

- **Excel export — NO new dependency in Week 8** (no `excel`
  package in pubspec). CSV export already works and opens in Excel
  with the same data; native `.xlsx` stays a documented
  post-handover gap.
- **Thermal printer integration — BLOCKED-CLIENT** (needs the
  client's printer model; keep the manual-entry fallback).

## 7. Test-side corrections made while building (no app defect)

- **Receive stock matched twice:** `find.text('Receive stock')`
  finds the header action and the per-batch action; the test uses
  `.first`.
- **Approve has no dialog:** the first version expected an "Approve
  prescription" dialog — Approve applies immediately with a
  snackbar; the note dialog is only for Reject. Test renamed and
  re-asserted on the snackbar + the vanished Approve action.
- **Snackbar timing:** the snackbar lives 4s, so a full
  `pumpAndSettle` waits it out — the test checks it after a 500ms
  pump, then settles and asserts Approve is gone.
- **Approve is pharmacist-only:** pumping as owner leaves the button
  disabled (SRS §5.1 `rxReview`); the test pumps as pharmacist.
- **Features tab off-viewport at 390px:** the Settings TabBar is
  scrollable, so the M-23/M-24 test calls `ensureVisible` before
  tapping "Features".
- **Two unused items removed** (unused `_org` const; `demo_accounts.dart`
  import — re-exported by `auth_state.dart`). `flutter analyze`
  clean.
- **Probe/micro files deleted before commit:**
  `test/week8_day02_probe_test.dart`,
  `test/week8_day02_micro_test.dart`,
  `test/week8_day02_micro2_test.dart` — scaffolding only, not part
  of the deliverable.

## 8. Verification

- `flutter analyze`: clean ("No issues found!").
- Day tests: `test/week8_day02_test.dart` **24/24 passed**.
- Full cumulative suite: **1183/1183 passed** (1159 baseline + 24
  new, 12:15). Note: the first suite run was killed at +1059 by a
  service restart that wiped `/tmp` (the log was there); the run was
  restarted with its log in the workspace and completed green —
  same tree, no code changed between the runs.
- Fresh `flutter build web --release`: **pass** — `main.dart.js`
  4,683,590 bytes.
- Prescription PNGs bundled: **confirmed** — 114,613 + 110,613 bytes
  in `build/web/assets/assets/images/prescriptions/`.

## 9. Files changed

- **Code (17 files, §4):** `lib/core/widgets/badges.dart`,
  `lib/features/audit/audit_log_screen.dart`,
  `lib/features/authentication/login_screen.dart`,
  `lib/features/customers/customer_detail_screen.dart`,
  `lib/features/inventory/stock_transfer_detail_screen.dart`,
  `lib/features/inventory/stock_transfer_form_screen.dart`,
  `lib/features/inventory/stock_transfer_list_screen.dart`,
  `lib/features/orders/order_detail_screen.dart`,
  `lib/features/purchases/auto_purchase_list_screen.dart`,
  `lib/features/purchases/purchase_detail_screen.dart`,
  `lib/features/purchases/purchase_form_screen.dart`,
  `lib/features/riders/rider_detail_screen.dart`,
  `lib/features/riders/rider_list_screen.dart`,
  `lib/features/settings/settings_screen.dart`,
  `lib/features/staff/attendance_screen.dart`,
  `lib/features/staff/salary_screen.dart`,
  `lib/features/staff/staff_list_screen.dart`.
- **Tests:** `test/week8_day02_test.dart` (new, 24 tests).
- **Docs:** `docs/day-39-progress.md` (this file),
  `docs/week-8-tracker.md` (Day 39 section),
  `docs/technical-decisions.md` (D177).

## 10. Follow-ups (Week 8)

- Day 40 (D178): fake-transport copies sweep.
- Day 41 (D179): handover docs — deployment guide, staff/owner user
  manual, demo-guide refresh; admin manual + backup/restore guide
  either covered there or carried as a documented gap (§5 item 9).
- Day 42 (D180): final QA sweep — re-verifies the walk (including
  the 0-overflow sweep) and records the six deferred fix-list items
  as documented gaps unless the coordinator orders a build.
- **Super Admin franchise-view gate — SKIPPED, still open (brief
  §4):** no Dazy decision is recorded anywhere in `docs/`; nothing
  was guessed or built.
- **Caveat (stated, not hidden):** full end-to-end verification
  against live Firestore stays BLOCKED on a live Firebase project
  (Dazy-only step) — no project exists, none was created, no live
  Firebase call was made. Verification here is the widget walk +
  sweep (`test/week8_day02_test.dart`, 24 tests).
- **Untouched:** `presentation-video/`; no new routes, no new
  capabilities, no matrix changes; no dependency added (pubspec
  untouched).
