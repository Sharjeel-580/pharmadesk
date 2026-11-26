# Day 41 — Week 8 Day 4 Progress (26 Nov 2026)

**Scope:** brief §4 — handover docs (D179). Three docs: a new
deployment guide, a new staff/owner user manual, and a refresh of
`docs/demo-guide.md` with EVERY figure re-checked against the final
tree. The admin manual + backup/restore guide gap (Day 38 §3 item 9)
is folded into the deployment guide as a concise admin section
(§8) instead of a separate doc — that gap is now closed, not carried.

**Result: done, docs only — no app code changed, no new test needed.**
`flutter analyze` clean, full cumulative suite **1191/1191 passed**
(12:58), fresh web build pass (`main.dart.js` 4,683,590 bytes),
prescription PNGs bundled (114,613 + 110,613 bytes). 0 new tests: every
figure corrected in the demo guide was already pinned by an existing
test (named in §3), and the remaining corrections are file/build
checks (APK/Windows files on disk, the fresh build figure, the D62
decision record) — not testable claims. No test was written for prose.

## 1. What each doc covers

### `docs/deployment-guide.md` (new)
- **Handover set (§1):** the exact files — `pharmadesk-week7.apk`
  (70,881,526 bytes, latest) + week-6 fallback, `pharmadesk-windows-week7.zip`
  (26,276,306 bytes, latest) + week-6 fallback, `build/web/`, and the
  three docs. APK/Windows files are untracked CI artifacts in the
  workspace, not in git — hand over the files, not a repo link.
- **Android install (§2):** copy, tap, allow "Install unknown apps"
  for the source app, install. Signing stated plainly: release build
  signed with the **debug keys** (Flutter template default,
  `android/app/build.gradle.kts`; CI runs `flutter build apk --release`) —
  fine for demo, NOT a Play Store release; a Play-signed build needs a
  real keystore (separate, Dazy-approved step) and would require
  uninstalling the demo first.
- **Windows (§3):** unzip, keep `data/` with it, run `pharmadesk.exe`.
  Honest status: CI-built on a Windows runner, but **not launched on a
  real Windows PC by the team** — the Linux VM cannot run it; the web
  build is the known-good fallback.
- **Web admin (§4):** no separate admin build — same app, desktop
  layout ≥ 900 px. `flutter build web --release` or
  `flutter run -d chrome`; `main.dart.js` 4,683,590 bytes; PNG check.
- **Demo accounts (§5):** all five + `demo1234`, with the
  never-use-in-production warning and the note that the other five
  SRS roles have no demo account.
- **Sample data (§6):** what is fictional (180 medicines, 491 orders,
  319 DHA / 172 Gulberg, 8 customers, 4 suppliers, 6 POs, 20
  prescriptions, supplier payables), DEMO MODE badge, demo data never
  mixes with production, **data resets on restart**, sample
  prescription photos, no real data import yet (FR-INV-14 gap).
- **Firebase project (§7):** what still needs doing, step by step —
  project + billing (Blaze, Dazy-only), app registration
  (`google-services.json` / `GoogleService-Info.plist` /
  `firebase_options.dart` via `flutterfire configure`), services
  (Email/Password Auth, Firestore `asia-south1`, Storage, Functions,
  FCM), then Muse wires the already-existing Firestore layer. Until
  then the app runs on the mock bundle and nothing syncs.
- **Admin section (§8):** brand settings (Fazal Din preset + Reset),
  the role matrix (10 roles × 24 capabilities, per-role table for the
  five demo roles, pharmacist-only rxReview and Owner-only backup
  gates called out), feature modules on/off (12 toggleable), and
  backup export + restore steps with the full D169/D173/D174/D175
  semantics (never deletes; counters not restored; split-payment legs
  not restored — Firestore-only gap; re-key by idempotencyKey; order
  numbers preserved + counter advances; overwrite policy; audit/sync
  sections local-only).
- **Not included (§9):** production credentials, real data import,
  Excel export, thermal printer, keyboard shortcuts, purchase
  returns, employee-performance report, login activity, seed script,
  FCM notifications, optional modules (O-1–O-11; M-23/M-24 do not
  exist), franchise onboarding / Super Admin franchise-view gate
  (pending Dazy's decision), live-Firestore verification, mobile
  camera scan, Play Store / iOS builds.
- **First-run checklist (§10):** install, sign in as Owner, confirm
  the DEMO MODE badge, branch-switch check (DHA Rs 6,990.00 vs
  Gulberg Rs 5,210.00), one sale + one approval, export a backup.

### `docs/user-manual.md` (new)
Short, role-based, plain language (no jargon — FEFO, khata and POS
are defined in one line each). One section per role, in the order
they use the app, each opening with its demo login:
- **Owner (Hassan Raza):** all-branches dashboard, alerts bell,
  branch comparison, Finance (cashbook / payables / P&L), Reports
  (PDF + CSV, no .xlsx), Staff, Settings (Branding, Roles matrix,
  Features), Backup. Cannot approve prescriptions.
- **Branch Manager (Bilal Ahmed, DHA):** branch dashboard, order
  queue + full status flow (rider at Ready), POS, Inventory
  (receive/count/adjust-request/transfer), Purchases (PO approve +
  receive, partial receiving), Customers/Suppliers (view), staff
  (own branch), branch-scoped reports/finance. Cannot approve
  prescriptions, pay suppliers, see salaries, change settings, or
  restore backups.
- **Pharmacist (Dr. Sana Malik, DHA):** prescription queue + review
  (Approve immediate, Reject / Needs clearer photo need a note),
  the dispatch-guard unblock (`rx-dha-1` / `rx-glb-11`), POS,
  medicine lookup. Cannot receive/adjust stock, manage POs or
  suppliers, or change settings.
- **Cashier (Usman Tariq, Gulberg):** POS end to end — search /
  simulate scan (`8901000000001`), FEFO automatic, expired blocked,
  discounts/tax, cash (change computed) / card / khata (credit-limit
  refusal), split payments, Complete Sale (disabled when empty,
  double-tap safe), receipt Share/Print, sales history, new orders,
  khata lookup. Cannot receive stock, manage medicines, approve
  prescriptions, or change settings.
- **Inventory Manager (Fatima Noor, Gulberg):** stock overview,
  batches/expiry (earliest first, expired never sellable), receive
  stock, stock count, adjustment requests (reason required, never
  below zero), transfers, auto purchase list (DHA 23 / Gulberg 21
  suggestions — rule stated, not just the count), POs, suppliers /
  medicines view, branch reports. Cannot sell at POS, approve
  prescriptions or adjustments, pay suppliers, or restore backups.
- **Every role:** notifications (derived, not pushed), reports,
  audit log (append-only), offline queue, quarantine, "Page not
  found" → Go to Dashboard, branch-check-first troubleshooting.
- Every step is grounded in a screen that exists (D-01–D-35 /
  M-01–M-24, Day 39 walk) and in the role matrix
  (`lib/features/settings/roles_permissions.dart`, extracted per role
  for this doc) and the D70 permission gates (pharmacist-only
  rxReview, Owner-only backup). No flow is described that the app
  does not have.

### `docs/demo-guide.md` (refreshed in place)
Nine corrections (§2) + header/status refresh + changelog entry.
Every other figure re-checked and left untouched (§3).

## 2. Demo-guide figures corrected (9)

| # | What was wrong | Correction | Grounding |
|---|---|---|---|
| 1 | "Flutter + Firebase Spark, permanently free" | "Flutter + Firebase Blaze, pay-as-you-go — decided 25 Nov 2026, D62, superseding the 23 Nov Spark decision" | D62 in `docs/technical-decisions.md`; `docs/firebase-setup-plan.md` Step 1 |
| 2 | "Android APK: not in this build … No APK exists from this build" | CI-built release APKs exist: `pharmadesk-week7.apk` (70,881,526 bytes, latest), `pharmadesk-week6.apk` (70,865,142 bytes); release signed with debug keys; rebuilds via CI only | Files on disk (`ls -l`); CI workflow `flutter build apk --release`; `android/app/build.gradle.kts` (`signingConfig = debug`) |
| 3 | "`main.dart.js` 3,951,416 bytes" | **4,683,590 bytes** | Fresh `flutter build web --release` this day (also Day 39/40) |
| 4 | "Windows: unverified on this Linux VM; needs real Windows hardware" | CI-built zips exist: `pharmadesk-windows-week7.zip` (26,276,306 bytes, latest), week-6 (26,273,637 bytes); unzip + run `pharmadesk.exe`; still not launched on a real Windows PC by the team | Files on disk; `unzip -l` shows `pharmadesk.exe` (15,983,104 bytes in the week-7 zip); CI `build-windows` job |
| 5 | Supplier "Hassan Traders Rs 0.00" | **"Hassan Pharma Traders Rs 0.00"** | `lib/core/services/demo_seed_data.dart:694` (`name: 'Hassan Pharma Traders'`); seed doc comment |
| 6 | "10 roles × 21 capabilities matrix" | **"10 roles × 24 capabilities"** | `lib/features/settings/roles_permissions.dart` — 24 `RoleCapability` entries; pinned by `test/day_07_test.dart:797` (`expect(roleCapabilities.length, 24)`) |
| 7 | "assigning a rider at dispatch" (§6 step 3) | **"assigning a rider at Ready (before dispatch)"** | Day 38 §6 / `test/week8_day01_test.dart` — WhatsApp order "takes rider `rider-1` at Ready" |
| 8 | §8 "verified by the full route walk test (14 modules…)" | Now cites the final walk: **all 47 routes resolve at desktop and 390px, 0 distinct overflows** (Week 8 Day 39) | `docs/day-39-progress.md` §1–§3; `test/week8_day02_test.dart` |
| 9 | Known limitations: "No APK from this build (environment-blocked); Windows unverified" | APK exists (CI-built, debug-signed, week-7 latest); Windows zip exists (CI-built) but not launched on real Windows hardware by the team | Same grounding as #2/#4 |

Also refreshed (not figures): header now "refreshed Week 8 Day 41,
26 Nov 2026 … figures re-checked" with pointers to the deployment
guide / user manual; changelog gained the Day 41 entry listing all
nine corrections.

## 3. Demo-guide figures re-checked and UNCHANGED (verdict: still true)

Checked against the final tree — source file or pinning test named
for each. Nothing here moved.

| Figure in the guide | Verdict | Grounding |
|---|---|---|
| Demo accounts: 5 roles, names, emails, home branches, password `demo1234`, one-tap cards | **True** | `lib/core/data/demo_accounts.dart` (all five accounts, `demoPassword = 'demo1234'`); Day 38 §1 pins Owner + Cashier sign-in |
| 2 demo branches: DHA (busier), Gulberg | **True** | `lib/core/services/branch_context.dart` (D18); Day 38 §4 KPIs |
| 180 medicines, 16 categories, sample barcodes, int-paisa prices | **True** | `test/day_05_test.dart:51` (180: 14 core + 166); 16 distinct `cat-*` ids in `demo_seed_data.dart` |
| 8 customers, 4 suppliers, 6 purchase orders, 20 prescriptions | **True** | Seed: 8 `cust-*`, 4 `Supplier(`, 6 `PurchaseOrder(`, 10 prescriptions per branch × 2 (`generateDemoPrescriptions`, `i < 10` per branch) |
| 491 orders over 30 days (deterministic seed) | **True** | `test/day_05_test.dart:125` pins 491 (D31); Day 38 §4: 319 DHA + 172 Gulberg = 491 |
| Supplier payables: Sami Rs 125,000.00, MedServe Rs 48,250.00, CareLine Rs 21,000.00 | **True** | `demo_seed_data.dart:669-670, 716-721, 733-762` (ledger entries); Day 38 §2 |
| `rx-dha-1` / `rx-glb-11` start Pending, linked to today's first order of each branch | **True** | D44; seed lines 1446-1451; Day 38 §6 pins the DHA link (`ord-dha-1312` / `rx-dha-1`) |
| Dispatch guard: order held at dispatch until prescription approved, then unblocks | **True** | Day 38 §6 (guard pin + approval clears it); D28/D44 |
| Branch switching: DHA today Rs 6,990.00 vs Gulberg Rs 5,210.00; all KPIs differ; orders 319 vs 172 | **True** (guide states no numbers — the qualitative claim) | Day 38 §4 pins every KPI (today sales/orders, 30-day revenue/orders, low-stock, near-expiry, expired, pending prescriptions) |
| FEFO picks: Panadol Extra → `DHA-1-2-173`, Risek 20 → `DHA-3-2-863`; expired-only Levaquin (`med-gen-021`, barcode `8902000000020`) blocked | **True** | Day 38 §3 pins both batch numbers + the Levaquin refusal (scan `notSellable`, `allocateFefo` throws, sale saves nothing) |
| Daily report today: DHA 7 orders / Rs 6,990.00; Gulberg 5 / Rs 5,210.00; CSV + real PDF export | **True** | Day 38 §5 pins the rows, CSV header + today's row, `%PDF` bytes, wired Export actions |
| Forgot password shows the demo reset code; wrong code rejected | **True** | `lib/features/authentication/forgot_password_screen.dart` (code shown on screen, wrong codes rejected) |
| PO-DHA-1001 (Approved); receiving adds batches + raises supplier payable; Draft approve / cancel guards | **True** | Seed line 782-785 (`poNumber: 'PO-DHA-1001'`, `status: approved`); D42/D43 |
| Prescription review: Approve / Reject / Needs clearer photo; note required for the last two; Approve is pharmacist-only | **True** | D44; Day 39 §4 (Approve immediate + snackbar; pharmacist-only per SRS §5.1 `rxReview`) |
| Auto purchase list (no count stated in the guide) | **True — no figure to correct.** Re-checked counts: **DHA 23, Gulberg 21** suggestions | `test/week7_day05_test.dart:871-872` (`dha.suggestions hasLength(23)`, `glb.suggestions hasLength(21)`); rules in D63 |
| DEMO MODE badge on every screen; demo data never mixes with production; data resets on restart; no cloud sync | **True** | `lib/app/shell/app_shell.dart` + `demo_mode_badge.dart`; `docs/known-limitations.md` §1 |
| "Full offline POS sync is production scope, not demo" | **True** | Day 38 §2 + §9 POS row (offline queue exists locally; cloud sync needs the project) |
| "14 modules are real, no placeholders" | **True** | Day 39 walk: 47 routes resolve, no placeholder/404 (D48 deleted the last placeholder) |
| Roles matrix display-only; feature config in-memory; notifications derived, not pushed; WhatsApp orders manual entry | **True** | D48/D49/D50; Day 38 §9 |

**Note on "21 capabilities" (correction #6):** the Day 38 §9 text
also says "10 roles × 21 capabilities" — that was the Day 7 count.
The matrix grew (stock-transfer split D118 and the adjustment
request/approve split); the code has 24 rows and the Day 7 test pins
24. Only the demo guide is corrected today — the Day 38 progress doc
is a historical record and is left as written.

## 4. Why 0 new tests

The task allows `test/week8_day04_test.dart` only where a doc claim
needs a test pin. Every corrected figure was already pinned:
- 24 capabilities — `test/day_07_test.dart:797`.
- Rider at Ready — `test/week8_day01_test.dart` (WhatsApp order flow).
- Supplier name "Hassan Pharma Traders" — seed source + `test/week4_day03_test.dart:823`.
- FEFO / guard / KPIs / seed counts / auto-purchase counts — Day 38
  (`week8_day01`), Day 5 (`day_05`), Week 7 Day 5 (`week7_day05`).
- Blaze vs Spark — a decision record (D62), not app behaviour; no
  test asserts a backend plan.
- APK / Windows files, `main.dart.js` size, PNG sizes — file and
  build checks, verified by `ls`/`stat` and the fresh build this day,
  not by a unit test.
- Prose (deployment steps, manual wording) — no tests for prose, per
  the task.

No existing test was touched, renamed or weakened; no production code
changed at all this day. `test/week8_day04_test.dart` was therefore
**not created**, and the commit message's "0 new tests" is the honest
count.

## 5. Verification

- `flutter analyze`: **clean** — "No issues found!" (18.4s).
- Day tests: **none** (0 new tests — see §4).
- Full cumulative suite (Weeks 1–8): **1191/1191 passed** (12:58;
  log at `~/workspace/fazal-din-pharma-week8-day41-full-suite.log`).
- Fresh `flutter build web --release`: **pass** — `main.dart.js`
  **4,683,590 bytes** (121.9s compile).
- Prescription PNGs bundled: **confirmed** — 114,613 + 110,613 bytes
  in `build/web/assets/assets/images/prescriptions/`.
- APK/Windows files re-verified on disk this day:
  `pharmadesk-week7.apk` 70,881,526 bytes,
  `pharmadesk-week6.apk` 70,865,142 bytes,
  `pharmadesk-windows-week7.zip` 26,276,306 bytes (contains
  `pharmadesk.exe`, 15,983,104 bytes),
  `pharmadesk-windows-week6.zip` 26,273,637 bytes.

## 6. Files changed

- New: `docs/deployment-guide.md`, `docs/user-manual.md`,
  `docs/day-41-progress.md` (this file)
- Modified: `docs/demo-guide.md` (9 corrections + header/changelog),
  `docs/technical-decisions.md` (D179),
  `docs/week-8-tracker.md` (Day 41 section)
- Untouched: `presentation-video/`; no app code; no pubspec change;
  no new test file; no Firebase project created; nothing pushed to
  GitHub.

## 7. Follow-ups (Week 8)

- **Super Admin franchise-view gate — STILL OPEN, awaiting Dazy's
  decision** (brief §4): no decision recorded anywhere in docs/; do
  not guess. Noted in the deployment guide §8.2 as an open decision.
- **Live-Firestore E2E (all of it)** — BLOCKED on a live Firebase
  project (Dazy-only step): rules, custom claims, App Check, FCM,
  scheduled exports, sync sender, seed script — verification here is
  the fake-transport suite + file checks, stated plainly in the
  deployment guide §7/§9.
- **§8.4 criterion 8 (client feedback + scope freeze)** —
  BLOCKED-CLIENT; needs the Phase 5 client walkthrough.
- **Day 38 fix-list items** (Excel export, bulk import FR-INV-14,
  POS keyboard shortcuts, purchase returns, employee-performance
  report, login activity, seed script, thermal printer) — unchanged:
  documented gaps, none built today (docs day). The admin manual +
  backup/restore guide item is now CLOSED (folded into the deployment
  guide §8); the other eight stay documented gaps for Day 42 / the
  final report.
