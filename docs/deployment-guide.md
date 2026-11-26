# PharmaDesk — Deployment Guide (Week 8 Day 41, 26 Nov 2026)

How the demo build reaches Hadi's team: what to hand over, how each
part installs, which accounts to use, what is sample data, and what
still needs the Firebase project (a Dazy-only step). This guide is
for the **demo handover** — nothing here is production yet.

**Build this guide describes:** app version `1.0.0+1`
(`pubspec.yaml`), Flutter 3.47.7, package `com.pharmadesk.app`.
Web build `main.dart.js` 4,683,590 bytes (rebuilt Day 41 — see
`docs/day-41-progress.md` for the fresh figure if it moved).

**Standing facts:** users are internal only (staff/owner) — there is
no customer app. The app runs on the local mock data layer until the
Firebase project exists; nothing syncs. No Firebase project has been
created and no live Firebase call is made by this build.

## 1. What to hand over

| Item | File (in `~/workspace/fazal-din-pharma/`) | Notes |
|---|---|---|
| Android app (latest) | `pharmadesk-week7.apk` — 70,881,526 bytes, 26 Nov 2026 | CI-built release APK, debug-signed (see §2) |
| Android app (previous) | `pharmadesk-week6.apk` — 70,865,142 bytes, 26 Nov 2026 | Keep as fallback; hand over the week-7 file first |
| Windows app (latest) | `pharmadesk-windows-week7.zip` — 26,276,306 bytes, 26 Nov 2026 | CI-built on a Windows runner; contains `pharmadesk.exe` |
| Windows app (previous) | `pharmadesk-windows-week6.zip` — 26,273,637 bytes, 26 Nov 2026 | Keep as fallback |
| Web admin | `build/web/` (rebuild: `flutter build web --release`) | Serve the folder; no separate admin build exists |
| This guide + user manual | `docs/deployment-guide.md`, `docs/user-manual.md` | Hand both over with the app |
| Demo guide | `docs/demo-guide.md` | The scripted walkthrough (figures re-checked Day 41) |
| Known limitations | `docs/known-limitations.md` | Read before the demo, not after |

The APK and Windows zip are **untracked workspace files** (CI
artifacts copied into the workspace) — they are not in git. Hand
over the files themselves, not a repo link. The web build is rebuilt
from the committed tree; the APK/Windows files are the CI builds of
that same tree.

**Do not hand over:** `presentation-video/` is a separate deliverable
and is not part of this guide's handover set.

## 2. Android — install the APK

1. Copy `pharmadesk-week7.apk` to the phone (USB, WhatsApp, Drive —
   any way the file arrives intact).
2. On the phone, tap the APK file to install.
3. Android will ask to allow installs from that source ("Install
   unknown apps" / "Allow from this source") — allow it for the app
   you opened the file from (file manager, browser or chat app), then
   tap Install again. This is normal: the APK does not come from the
   Play Store.
4. Open **PharmaDesk**. The splash screen shows, then the sign-in
   screen with the five demo-account cards (§5).

**Signing — read this before promising anything:** the APK is a
**release build signed with the debug keys** (the Flutter template
default in `android/app/build.gradle.kts`; CI builds
`flutter build apk --release`). That is fine for a demo install. It
is **not** a Play Store release: a Play Store release needs a real
release keystore + signing config, which is a separate, Dazy-approved
step. A phone that later installs a Play-signed build will treat it
as a different app signature — the demo install would need to be
uninstalled first. Never present the demo APK as the Play Store
build.

**If install fails:** check the file size against §1 (a truncated
download is the usual cause — re-copy it), and check there is free
space (the APK is ~71 MB; the installed app needs more). The APK
build itself cannot be rebuilt on the dev sandbox (Gradle is
environment-blocked there — see `docs/technical-decisions.md`
D14/D15/D52); rebuilds go through GitHub Actions CI.

## 3. Windows — run the desktop build

1. Copy `pharmadesk-windows-week7.zip` to the Windows PC and unzip
   it (right-click → Extract All). Keep everything in the one
   extracted folder — do not move `pharmadesk.exe` out on its own;
   the `data/` folder next to it belongs with it.
2. Double-click `pharmadesk.exe` in the extracted folder. The app
   opens full-screen on the desktop layout (sidebar + top bar).
3. Sign in with a demo account (§5).

**Honest status:** the zip is built by CI on a Windows runner
(`flutter build windows --release -t lib/main_desktop.dart`), but it
has **not been launched on a real Windows PC by the team** — the
Linux VM cannot run it. If it fails to start on Hadi's PC, that is a
first-run report, not a broken handover: note the exact error and
send it back. The web build (§4) is the fallback that is known to
run.

**Notes:** the desktop build is the counter/office build
(`lib/main_desktop.dart` — it wires `sqflite_common_ffi` for the
offline sync queue and never touches `firebase_messaging`, which has
no Windows implementation). Push notifications do not exist on
Windows; the desktop app reads live order updates from Firestore
instead, once the project exists.

## 4. Web admin — serve `build/web/`

There is **no separate admin build**. The web app is the same app;
on a wide screen (≥ 900 px) it shows the desktop layout
automatically, which is the admin view.

1. Rebuild (or use the existing build): from
   `~/workspace/fazal-din-pharma/`, `flutter build web --release`.
   The output is `build/web/`; `main.dart.js` is 4,683,590 bytes.
2. Serve the folder with any static server, for example from inside
   `build/web/`: `python3 -m http.server 8000` — then open
   `http://localhost:8000`. Or run it directly during the demo:
   `flutter run -d chrome` from the project folder.
3. Sign in with a demo account (§5). The owner account sees the
   all-branches dashboard; that is the admin view.

The two prescription sample images are bundled in the web build
(`build/web/assets/assets/images/prescriptions/` —
`sample-prescription-1.png` 114,613 bytes,
`sample-prescription-2.png` 110,613 bytes). If a prescription photo
ever shows as missing, the build is stale — rebuild.

## 5. Demo accounts

All five accounts share the password **`demo1234`**. On the sign-in
screen, tap a card to sign in with one tap, or type the email +
password. Names, emails and figures are fictional (SRS §8.2).

| Role | Name | Email | Sees |
|---|---|---|---|
| Owner | Hassan Raza | `owner@demo.pharmadesk` | All branches — owner dashboard |
| Branch Manager | Bilal Ahmed | `manager@demo.pharmadesk` | Demo Branch — DHA |
| Pharmacist | Dr. Sana Malik | `pharmacist@demo.pharmadesk` | Demo Branch — DHA |
| Cashier | Usman Tariq | `cashier@demo.pharmadesk` | Demo Branch — Gulberg |
| Inventory Manager | Fatima Noor | `inventory@demo.pharmadesk` | Demo Branch — Gulberg |

**Demo passwords are shared and public by design — never use them in
production.** Real staff accounts do not exist yet; they need the
client's staff list (SRS Appendix A Q7) and the Firebase project
(§7). The five demo roles are the only accounts in this build; the
full role vocabulary also has Super Admin, HO Admin, Regional
Manager, Accountant and Auditor, which have no demo account.

**Forgot password (demo):** enter a demo email on the
forgot-password screen; the screen shows the demo reset code (no
email is sent in the demo). Enter that code + a new password and the
new password signs in. A wrong code is rejected.

## 6. What is sample data — and what it is not

- **Everything in the demo is fictional:** 180 medicines (16
  categories, sample barcodes), 491 orders over 30 days across both
  branches (319 DHA, 172 Gulberg), 8 customers, 4 suppliers, 6
  purchase orders, 20 prescriptions (10 per branch). Supplier
  opening payables: Sami Pharmaceuticals Rs 125,000.00, MedServe
  Distributors Rs 48,250.00, CareLine Supplies Rs 21,000.00, Hassan
  Pharma Traders Rs 0.00. Branch figures differ on purpose — DHA is
  busier (today Rs 6,990.00 vs Gulberg Rs 5,210.00).
- **Look for the DEMO MODE badge:** it is on every screen (top bar
  on module screens; splash, login and forgot-password too).
- **Demo data never mixes with production data** (SRS §8.2). The
  demo runs on the local mock data layer; there is no backend to
  carry it into.
- **Data resets on restart.** All data is local mock data in memory;
  nothing syncs between devices, branches or users. A sale rung in
  the demo is gone when the app restarts. Do not enter real customer
  names, real prices, real stock or real money into the demo — it
  will not be kept, and it must not be treated as the business record.
- **Prescription photos are bundled SAMPLE assets**, marked SAMPLE /
  "DEMO ONLY — NOT A REAL PRESCRIPTION", with fictional patients and
  doctors. Never present a sample image as a real patient's
  prescription.
- **No real data import exists yet.** Bulk catalogue import
  (FR-INV-14) is a documented gap — real medicines, stock and
  customers cannot be imported into this build. The only data in the
  app is the seed.

## 7. What still needs the Firebase project (Dazy-only step)

**Nothing in this section has been done, and nothing here is done by
the handover itself.** The Firebase project + billing creation is a
Dazy-only step (his Google account + card). Muse must never create
the project or billing, and this build makes no live Firebase call.

1. **Create the project (Dazy):** Firebase Console → Add project,
   name `PharmaDesk` (project ID is auto-generated; record it in
   `docs/firebase-setup-plan.md` when created). **Plan: Blaze
   (pay-as-you-go)** — decided 25 Nov 2026 (D62, superseding the
   23 Nov Spark decision). Attach a billing account and set a billing
   alert at first setup so spend is visible before it grows. Free
   quotas cover most usage at 8-branch scale; overage is cents.
   Blaze (not Spark) is what unlocks Cloud Storage + Cloud Functions.
2. **Register the apps (Dazy, or Muse in the browser once the project
   exists):** Android package `com.pharmadesk.app` →
   `google-services.json` into `android/app/`; iOS bundle ID
   `com.pharmadesk.app` → `GoogleService-Info.plist` into
   `ios/Runner/`; web app → `flutterfire configure` generates
   `lib/firebase_options.dart` (never hand-write API keys into
   source).
3. **Enable services (Blaze):** Authentication — Email/Password
   (staff login; phone OTP is billed per SMS on Blaze — do not enable
   or promise it without verification). Cloud Firestore — create the
   database, region **`asia-south1` (Mumbai)** recommended for
   Pakistan latency (region is permanent once chosen — confirm before
   creating). Cloud Storage — prescription photos live here
   (`organizations/{orgId}/branches/{branchId}/prescriptions/{id}.jpg`).
   Cloud Functions — scheduled jobs + claims per
   `firebase/functions-design.md`. Cloud Messaging (FCM) — free;
   configure for Android/Web.
4. **Then Muse wires it (code, no Dazy step):** `Firebase.initializeApp()`,
   repositories switch from mock to Firestore (the Firestore
   implementations already exist in `lib/core/data/firestore_*.dart`
   and are tested against an in-memory fake transport — they are
   unwired today), the DRAFT rules in `firebase/firestore.rules` /
   `firebase/storage.rules` are deployed, custom claims are set
   (`setUserClaims` Function, Job 6), and the demo seed is replaced
   by real data.

**Until then:** the app runs on the mock bundle, the offline sync
queue holds operations with nowhere to send them (on web it resets
on restart), and there is no cloud sync, no real login and no push.
The full step list lives in `docs/firebase-setup-plan.md`.

## 8. Admin section — brand, roles, backup & restore

This section folds in the admin manual + backup/restore guide
(Day 38 §3 item 9) — there is no separate admin doc.

### 8.1 Brand settings (white-label)

Settings → **Branding** tab (Owner only — see the role matrix
below). Change the organization name and colours and the shell
rebrands immediately (top bar, sidebar, theme seed follow the brand
primary). **Fazal Din preset:** one tap applies
"Fazal Din's Pharma Plus" (organization + app name, DHA Lahore
receipt header); Reset returns to the generic PharmaDesk brand.
Brand state is in-memory in the demo; in production it is stored per
organization in Firestore. The default brand is generic PharmaDesk,
deliberately not client-specific.

### 8.2 Roles & permissions — what each role may do

Settings → **Roles & Permissions** tab shows the matrix: **10 roles
× 24 capabilities** (SRS §5.1, transcribed). The matrix is shown
read-only; in-app enforcement is the `PermissionService` (route
gates + action gates), and Firestore security rules + custom claims
are the production authority (rules are DRAFT and undeployed until
§7 is done).

The five demo roles, in short (matrix values; "own" = within the
user's own branch only):

| Capability | Owner | Branch Mgr | Pharmacist | Cashier | Inventory Mgr |
|---|---|---|---|---|---|
| Brand / modules / branches | yes | — | — | — | — |
| View all branches | yes | own | own | own | own |
| Manage users & roles | yes | own | — | — | — |
| POS sell / discount | yes | own | own | own | — |
| POS refund / return | yes | own | — | own | — |
| Prescription review & approve | — | — | own | — | — |
| Medicine master | yes | own | own | — | own |
| Stock receive / count | yes | own | — | — | own |
| Stock adjustment request | yes | own | — | — | own |
| Stock adjustment approve | yes | own | — | — | — |
| Stock transfer request/approve | yes | own | — | — | own |
| Purchase orders | yes | own | — | — | own |
| Supplier payment | yes | — | — | — | — |
| Customer credit (khata) | yes | own | — | own | — |
| Finance entry | yes | own | — | own | — |
| Finance reports / P&L | yes | own | — | — | — |
| Reports (all) | yes | own | own | own | own |
| HR attendance / shifts | yes | own | — | — | — |
| HR salary records | yes | — | — | — | — |
| Audit log view | yes | own | — | — | — |
| System settings / backup | yes | — | — | — | — |

Notable gates a demo will hit: prescription Approve/Reject is
**pharmacist-only** (the Owner sees the button disabled); the
backup/restore screen is Owner/HO Admin/Super Admin only
("System settings / backup"); the cashier cannot receive stock or
manage medicines. The sidebar and mobile More sheet hide modules the
signed-in user has no permission for.

**Open decision — do not guess:** whether Super Admin also sees the
franchise view, or only Owner / HO Admin, is **pending Dazy's
decision**. Nothing about the franchise view is built or promised
here; the decision is recorded for the final report.

### 8.3 Feature modules on/off

Settings → **Features** tab (Owner only). 12 toggleable modules
(Orders, Medicines, Inventory, Billing & POS, Customers, Suppliers,
Purchases, Prescriptions, Reports, Finance, Staff, Notifications);
Dashboard, Settings and Profile are always on. Switching a module
off removes it from navigation; opening it directly shows a clear
"module is disabled" state. Feature config is in-memory in the demo;
production stores it per organization.

### 8.4 Backup — export

Backup & Restore screen (`/backup`, Owner only). **Export:** tap the
export/backup action; on web it downloads one JSON file (format
`"pharmadesk-backup"`, version 1). The export covers every
repository's data — per-branch or org-wide — with money in int paisa
and dates as ISO strings. Keep the file somewhere safe; it is the
only copy of the data, and demo data resets on restart (§6).

On Blaze, a scheduled Cloud Function also exports Firestore to Cloud
Storage weekly/daily (`firebase/functions-design.md`, Job 4) — that
job does not exist yet (§7). The in-app JSON export stays the manual
path and the fallback if the scheduled job is down.

### 8.5 Restore — import a backup (read before doing it)

1. Open Backup & Restore (`/backup`) as Owner.
2. Paste the backup JSON document into the **Backup JSON** field
   (format `"pharmadesk-backup"`, version 1).
3. Tap **Validate & restore**. The file is validated (format /
   version / structure) **before anything is written**; invalid
   files are rejected with the errors shown, nothing applied.
4. Read the confirm dialog — it states the document count and the
   overwrite policy — and confirm **Restore backup**.
5. The screen reports `created / overwritten / skipped` counts.

**Restore semantics (D169 — decided behaviour, stated on the screen
as "What restore does NOT do"):**

- **Restore never deletes.** It only adds or replaces documents that
  are in the backup. Records created after the export stay exactly
  as they are. A record that was in the backup **comes back even if
  it was deleted after the export**. A restore is not a rollback to
  the export.
- **Counters are not restored.** The export deliberately has no
  `counters` / `inventoryCounters` section. Report counters and stock
  counters are rollup figures recomputed from the restored records,
  so they follow the restored data instead of being written back.
  Batch rows themselves do revert (they are in the backup).
- **Split-payment legs are not restored.** The export has no
  `salePayments` section. A sale comes back with its total, payment
  method and cash received; the per-method split of a split payment
  is not restored (in Firestore the legs live only in the `payments`
  subcollection, which a restore never writes). In the mock the legs
  do round-trip inside the sale document — the gap is Firestore-only.
- **Re-key by idempotencyKey (D173):** on restore, sales and orders
  are re-keyed by their `idempotencyKey` before writing — the doc id
  IS the key (D53) — so a mock export restored into Firestore lands
  under the key, and re-restoring the same backup counts once (no
  duplicates). A target that already holds a sale under a pre-D173
  restore's exported id keeps that stale doc (restore never deletes);
  the re-keyed doc under the key is canonical.
- **Order numbers are preserved and the counter advances (D174/D175):**
  a restored order keeps its number (e.g. `ORD-DHA-1492` stays
  `ORD-DHA-1492`); the per-branch counter advances past the restored
  numbers so the next new order never collides with one.
- **Audit history and the pending sync queue are not restored into
  live history** — they land in the local restore record only.
- **Restore policy is overwrite** (a document with the same id is
  replaced, never duplicated); re-importing the same backup never
  duplicates a document.

**If a restore looks wrong:** do not re-restore blindly — the second
restore is idempotent against the keyed docs, so it will not fix a
misread file. Check the reported counts and the validation errors
first, and keep the backup file.

## 9. What is NOT included in this handover

- **No production credentials.** No Firebase project, no
  `google-services.json`, no `GoogleService-Info.plist`, no
  `firebase_options.dart` — none exist (§7, Dazy-only).
- **No real data import.** Bulk catalogue import (FR-INV-14) does
  not exist; no client catalogue, stock register or staff list has
  been loaded.
- **No Excel export.** Reports export PDF + CSV (CSV opens in Excel
  with the same data). Native `.xlsx` is a documented post-handover
  gap (coordinator decision Day 39 — no new dependency in Week 8).
- **No thermal printer.** Browser print works; network/USB printers
  are honest stubs that report "not configured" — needs the client's
  printer model.
- **No POS keyboard shortcuts, no purchase returns, no
  employee-performance report, no login-activity view, no Firestore
  seed script.** Documented gaps (Day 38 §3 / Day 39 §5); none is
  built in this handover.
- **No dispatch/delivery customer notifications.** FCM is unwired
  (provider TBD); WhatsApp orders are manual entry — no WhatsApp API.
- **No optional modules.** O-1–O-11 unselected (client has not
  chosen any). The Owner Live Control Center (O-11) and AI Assistant
  (O-2) screens do not exist.
- **No franchise onboarding, no Super Admin franchise-view gate**
  (pending Dazy's decision, §8.2).
- **No live-Firestore verification.** Rules are DRAFT and undeployed;
  custom claims, App Check, session/device management and secrets
  management are not in place. Verification so far is the
  fake-transport suite + widget tests, stated plainly.
- **No mobile camera barcode scan.** Only the simulated scanner
  exists; wedge scanners work through the scan field as typed input.
- **No Play Store build, no iOS build.** iOS needs macOS + Xcode and
  has not been attempted.

## 10. First-run checklist (for the person receiving the handover)

1. Install one build (§2, §3 or §4) and sign in as Owner
   (`owner@demo.pharmadesk` / `demo1234`).
2. Confirm the **DEMO MODE** badge is visible on every screen.
3. Switch branch DHA ↔ Gulberg in the top bar — dashboards, orders,
   inventory and sales figures must all change (DHA today
   Rs 6,990.00, Gulberg Rs 5,210.00).
4. Run one sale as Cashier (Gulberg) and one prescription approval as
   Pharmacist (DHA) — see `docs/demo-guide.md` §2/§6 or
   `docs/user-manual.md`.
5. Export a backup from `/backup` and keep the JSON file.
6. Read `docs/known-limitations.md` before showing the demo to
   anyone else.
7. Anything that does not match this guide is a bug — report it with
   the screen, the role signed in, and the exact steps.
