# PharmaDesk — Cloud Functions design (Week 2 Day 1)

**Status: DESIGN ONLY — no code is deployed and no Functions code is
written in this chunk.** The backend is Firebase **Blaze** (D62,
25 Nov 2026), which unlocks Cloud Functions. Implementation is a
follow-up for the Firebase-wiring chunk, which needs the Firebase
project + billing enabled first (Dazy-only step) and verifies against
the Functions emulator + the deployed project. Nothing here is
deployed from this machine.

## Why Functions exist at all

On Blaze, server-side logic has a home again. The rules stay the
same: **Firestore security rules are the enforcer** (branch isolation,
role checks, append-only history) and **client transactions are the
write path** for sales, stock and money. Functions do only what a
client cannot do reliably:

- scheduled jobs (nothing on a phone runs on a schedule),
- cross-branch aggregation that would burn client read quota,
- privileged writes (custom claims, scheduled backups).

Functions NEVER bypass the rules model — they run with the Admin SDK,
so each function re-checks org/branch scope in code before it writes.

## Conventions for every job below

- **Runtime:** Node.js 20, TypeScript, `firebase-functions` v2
  (`onSchedule`, `onCall`, `onDocumentWritten`), Admin SDK.
- **Region:** `asia-south1` (closest to Pakistan; keeps latency and
  egress low).
- **Idempotency:** every scheduled job writes a run record first —
  `organizations/{orgId}/scheduledRuns/{jobId}-{date}` — inside a
  transaction; if the record already exists the job exits immediately.
  A retry can therefore never double-notify, double-count or
  double-export.
- **Failure handling:** a failed run throws (so Cloud Scheduler
  retries with back-off); the run record carries `status: failed` +
  the error, and the next scheduled run picks the work up again. No
  partial state is ever left unmarked.
- **Quota discipline:** jobs read with collection-group queries
  scoped by `organizationId`, paginated (500 docs/page), and write
  in batches of ≤ 500. The free tier covers most usage at 8-branch
  scale; overage is cents — see SRS §2.9 (Blaze revision).

## Job 1 — Daily expiry scan + alerts

| Field | Spec |
|---|---|
| Trigger | `onSchedule`, every day 06:00 PKT (`0 6 * * *`, timezone `Asia/Karachi`) |
| Logic | Collection-group query on `batches` where `organizationId == org` and `expiryDate` within 0–30 days or already past. For each branch: one `notifications` doc per bucket (expired / ≤7 days / ≤30 days) listing the batch count + the worst offenders (max 10 medicine names), addressed to the branch's pharmacist + inventory manager roles (`userId: null`, `data: {role: pharmacist}` — the app filters by role). Also writes one `auditLogs` entry per branch summarising the scan. |
| Collections touched | `batches` (read), `branches/{id}/notifications` (write), `auditLogs` (write), `scheduledRuns` (run record) |
| Idempotency | Run record `expiry-scan-{yyyy-MM-dd}`; a second run the same day exits. Notification docs use deterministic ids (`expiry-{branchId}-{yyyy-MM-dd}-{bucket}`) so a retry overwrites the same doc instead of duplicating it. |
| Failure | Throw → Scheduler retries; the run record stays `failed` until a run succeeds. |

## Job 2 — Low-stock digest

| Field | Spec |
|---|---|
| Trigger | `onSchedule`, every day 07:00 PKT |
| Logic | Per branch, read `inventory` docs where `quantityOnHand <= reorderLevel` (the medicine doc carries `reorderLevel`; the job joins in code, paginated). One digest `notifications` doc per branch (`low-stock-{branchId}-{date}`) with the medicine list + quantities, addressed to the inventory-manager role. Branches with nothing low get no notification and no write. |
| Collections touched | `inventory`, `medicines` (read), `branches/{id}/notifications` (write), `scheduledRuns` |
| Idempotency | Run record `low-stock-digest-{date}` + deterministic notification ids (same pattern as Job 1). |
| Failure | Same as Job 1. |

## Job 3 — Daily counters rollup

| Field | Spec |
|---|---|
| Trigger | `onSchedule`, every day 00:05 PKT (rolls up *yesterday*) |
| Logic | For each branch: query `sales` + `orders` with `createdAt` in yesterday's window, sum grand totals + counts, and write `branches/{id}/counters/daily-{yyyy-MM-dd}` (`value` is a map: `{salesTotalMinor, salesCount, ordersCount}`) plus update the running `counters/today-sales` / `counters/today-profit` docs the dashboards read (SRS §2.9 denormalized read models). This is what lets dashboards read counters instead of scanning the whole sales collection. **Week 3 Day 3 extension (D105):** the `value` map also carries `cogsMinor` and `grossProfitMinor` (D81/D93 cost rule — batch `costMinor`, fallback medicine `purchasePriceMinor`, else 0; orders use `purchasePriceMinor`), and `salesTotalMinor` is revenue with refunds subtracted (a returned sale is not revenue kept; COGS is not clawed back, because restocked units return to sellable stock). The extension is what lets the reports screen read the weekly trend, branch comparison and P&L from counters too — the doc also carries `date` (`yyyy-MM-dd`), `branchId`, `computedAt` and `source: 'rollup'` (see `firestore_schema.dart`, `branches/{branchId}/counters/daily-{date}`). Clients can never write these docs (rules draft denies `daily-*` writes — a client that could write its own counters could fake the reports); the repository surface is read-only. |
| Collections touched | `sales`, `orders` (read), `branches/{id}/counters` (write), `scheduledRuns` |
| Idempotency | Run record `counters-rollup-{date}`; the daily counter doc id is the date, so a retry overwrites the same doc with the same sums. |
| Failure | Same as Job 1. A missed day is caught by the next run (it rolls up every date with no counter doc yet, max 7 days back). |

## Job 4 — Scheduled backup export

| Field | Spec |
|---|---|
| Trigger | `onSchedule`, every Sunday 02:00 PKT (weekly full export) + every day 02:30 PKT (incremental: only docs with `updatedAt` in the last 24h) |
| Logic | Admin SDK `firestore.exportDocuments` (or a manual collection walk if the export API is unavailable on the chosen plan) → writes the export to Cloud Storage at `organizations/{orgId}/backups/{yyyy-MM-dd}/` (see `storage.rules`: Functions write with the Admin SDK, clients can only read). Writes a `scheduledRuns` record with the Storage path + doc counts. Old exports are pruned by a Cloud Storage lifecycle rule (keep 30 daily + 12 weekly — the rule itself lives in the bucket config, not in code). |
| Collections touched | All Firestore collections (read), Cloud Storage `backups/` (write), `scheduledRuns` |
| Idempotency | Run record `backup-{date}-{weekly|daily}`; a retry re-exports to the same dated path (overwrite, same bytes). |
| Failure | Same as Job 1. The in-app JSON export (`lib/core/data/backup_export.dart`) remains the manual fallback — the client can always export from the app even if this job is down. |

## Job 5 — Prescription review reminders

| Field | Spec |
|---|---|
| Trigger | `onSchedule`, every 6 hours |
| Logic | Collection-group query on `prescriptions` where `reviewStatus == pending` and `createdAt` older than 24h. For each, write one `notifications` doc for the branch's pharmacists (`data: {prescriptionId, role: pharmacist}`). Then stamp the prescription doc with `reminderSentAt: <today>` in the same batch — the query excludes docs whose `reminderSentAt` is today, so a prescription is reminded at most once a day. |
| Collections touched | `prescriptions` (read + `reminderSentAt` write), `branches/{id}/notifications` (write), `scheduledRuns` |
| Idempotency | Run record `rx-reminders-{date}-{slot}` + the `reminderSentAt` stamp (a retry finds nothing to remind). |
| Failure | Same as Job 1. |

## Job 6 — Custom claims management (callable, not scheduled)

| Field | Spec |
|---|---|
| Trigger | `onCall` `setUserClaims` |
| Logic | Caller must be authenticated and carry `role` owner or ho_admin (checked in code against their own claims). Input: `{uid, orgId, branchIds[], role}`. Validates the role is one of the 10 SRS §5 roles and the branches belong to the org (reads `branches/{id}`). Sets the Auth custom claims AND mirrors them on the `users/{uid}` doc (`roleKeys`, `branchAccess`) in one write, then writes an `auditLogs` entry. Until this function is deployed, claims are set from an admin machine with the Admin SDK (same payload, same validation — see `firebase/README.md`). |
| Collections touched | `users/{uid}` (write), `auditLogs` (write); Auth custom claims |
| Idempotency | Setting the same claims twice is a no-op (Admin SDK overwrites identical claims); the audit entry is the only append, and it is itself the record that the change happened. |
| Failure | Throws `HttpsError` (permission-denied / invalid-argument) — the caller sees the reason; nothing is half-written (claims set only after the doc validation passes). |

## What stays OUT of Functions (deliberately)

- **Sale commit / stock deduction / khata writes** — client
  transaction via `ProductionDataLayer` (the data layer already
  builds the batched-write payload). Moving money through a callable
  would add latency at the counter for no safety gain; the rules
  validate every document.
- **Prescription photo upload** — direct client → Cloud Storage
  upload (rules enforce branch + role + image + size). The client
  writes the metadata (`photoStoragePath`, …) to the Firestore doc
  after a successful upload.
- **Push delivery itself** — FCM send is a function *call* away, but
  no notification-sending function is specced until the app has real
  users; in-app `notifications` docs are the channel for now.

## Follow-up (Firebase-wiring chunk)

1. Create the Firebase project + enable billing (Dazy-only).
2. `firebase init functions` (TypeScript, `asia-south1`), implement
   Jobs 1–6 from this spec.
3. Verify each job against the Functions emulator with seed data,
   then deploy to the demo project and check the run records +
   notifications land.
4. Add a rules test (`@firebase/rules-unit-testing`) for
   `firestore.rules` + `storage.rules` — branch isolation must be
   proven by a test that reads another branch's doc and gets denied.
