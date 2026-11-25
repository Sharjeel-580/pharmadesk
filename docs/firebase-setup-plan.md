# PharmaDesk — Firebase Setup Plan

**Status (Day 1, 23 Nov 2026): NOT STARTED — no Firebase project exists.**
Nothing in this document has been executed. No credentials exist, no
project was created, and no config files are in the repo. The app runs
on mock repositories until this plan is completed.

## Who does what

| Step | Owner |
|---|---|
| 1. Create the Firebase project | **Dazy** (his Google account, dedicated new project for the client — separate from 60Score and from Dazy's own projects) |
| 2. Register apps + download config files | Dazy (or Muse in the browser once the project exists) |
| 3. `flutterfire configure`, `Firebase.initializeApp()` | Muse (code) |
| 4. Enable Auth + Firestore + rules | Muse (code + console steps) |
| 5. Wire repositories from mock → Firestore | Muse (Week 2) |

## Step 1 — Create the project (Dazy)
1. Firebase Console → Add project. Name: `PharmaDesk` (project ID will
   be auto-generated; record it here when created).
2. **Plan: Blaze (pay-as-you-go). Attach a billing account** (Dazy's
   card — Dazy-only step). Blaze was chosen 25 Nov 2026 (D62, superseding
   the 23 Nov Spark decision): free quotas cover most usage at
   8-branch scale, overage is cents, and Blaze unlocks Cloud Storage +
   Cloud Functions. Set a billing alert at first setup so spend is
   visible before it grows.
3. Google Analytics: optional — leave off unless Dazy wants it.

## Step 2 — Register the apps
- **Android:** package name `com.pharmadesk.app` → download
  `google-services.json` into `android/app/`.
- **iOS:** bundle ID `com.pharmadesk.app` → download
  `GoogleService-Info.plist` into `ios/Runner/`.
- **Web:** register a web app → run `flutterfire configure` to generate
  `lib/firebase_options.dart` (never hand-write API keys into source).
- **Windows:** Firebase on Windows is supported through the same
  `firebase_options.dart` for core/Firestore/Auth; **FCM has no Windows
  implementation** — desktop reads live updates from Firestore instead.

## Step 3 — Enable services (Blaze)
- **Authentication:** enable **Email/Password** (staff login). Phone OTP
  is billed per SMS on Blaze — do not enable or promise it without
  verification.
- **Cloud Firestore:** create the database. **Region: `asia-south1`
  (Mumbai)** recommended for Pakistan latency. Region is permanent once
  chosen — confirm before creating.
- **Cloud Messaging (FCM):** free; configure for Android/Web.
- **Cloud Storage:** enable — prescription photos live here
  (branch-scoped paths, `firebase/storage.rules`).
- **Cloud Functions:** enable — scheduled jobs + claims per
  `firebase/functions-design.md` (implemented in the Firebase-wiring
  chunk, not in this step).

## Step 4 — Firestore collections (data model)
Per the Week 1 prompt §5 and the SRS data model:

`organizations`, `branches`, `users`, `roles`, `medicines`, `batches`,
`inventory`, `orders`, `order_items`, `customers`, `customer_ledger`,
`suppliers`, `purchases`, `prescriptions`, `notifications`, `settings`,
`audit_logs`

Rules principles (to be written as `firestore.rules` in Week 2):
- Default deny. Every document carries `organizationId` + `branchId`.
- Users can read/write only their organization's data, and only the
  branches their role allows (enforced by rules + custom claims —
  never frontend-only).
- `prescriptions` contain only metadata — **photo bytes live in Cloud
  Storage** (`organizations/{orgId}/branches/{branchId}/prescriptions/{id}.jpg`,
  `photoStoragePath` on the doc); never store a public photo URL.
- Audit-sensitive collections (`audit_logs`, financial records) are
  append-only: no update/delete from clients.

## Blaze free-tier quotas + billing (verified 23 Nov 2026, plan revised 25 Nov 2026)
Design to stay inside the free quotas — at 8-branch scale the Blaze
bill stays near-zero:

| Product | Free quota (Blaze) |
|---|---|
| Firestore stored data | 1 GiB |
| Firestore reads | 50,000 / day |
| Firestore writes | 20,000 / day |
| Firestore deletes | 20,000 / day |
| Auth | 50,000 monthly active users |
| FCM | Free (no quota) |
| Cloud Storage | 5 GiB stored, then billed per GB |
| Cloud Functions | 2M invocations / month free, then billed |
| Phone Auth | Billed per SMS |

Quota-efficiency rules for Week 2 implementation: paginate every list,
cache reference data (medicines, categories) locally, use batched writes
for multi-document operations, avoid listeners on large collections, and
denormalize counters (e.g. branch daily totals) instead of counting
documents on every dashboard load. On Blaze, exceeding the free tier
bills the overage instead of stopping the product — set billing alerts
at setup and review spend monthly with the client. If a quota is hit,
the app must show a clear offline/limit state, never crash.

## Step 5 — Wire the app (Week 2, after credentials exist)
1. `flutterfire configure` (adds `firebase_options.dart`).
2. Add `Firebase.initializeApp()` in `lib/main.dart`,
   `lib/main_admin.dart`, `lib/main_desktop.dart`.
3. Implement Firestore repositories behind the existing interfaces in
   `lib/core/services/repositories.dart`; swap the providers from mock
   to Firestore. No screen rewrites.
4. Smoke test: login → dashboard loads from Firestore → create an order
   → status update visible on a second device (or web admin).

## Blockers (right now)
1. **No Firebase project** — Dazy must create it (Step 1).
2. **No config files** — depend on Step 2.
3. **Hadi's requirements** (branch count, medicine catalogue, hardware)
   — needed for scope/quotation, not for the Firebase setup itself.
