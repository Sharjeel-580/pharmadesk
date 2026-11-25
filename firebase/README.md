# PharmaDesk — Firebase config (DRAFT)

**Status: DRAFT — nothing here is deployed.** There is no Firebase
project yet (D13, Dazy's decision). These files exist so the backend
can be switched on the day the project is created, without redesigning
anything: the app's data layer (`lib/core/data/`) already builds the
paths and payloads these rules expect.

## Files

| File | Purpose |
|---|---|
| `firestore.rules` | Security rules: branch isolation + role checks, deny-by-default. |
| `firestore.indexes.json` | Composite indexes for the branch+status+createdAt queries (SRS §3). |
| `storage.rules` | Cloud Storage rules: branch-scoped prescription photos, medicine images, brand logo, backups (Blaze). |
| `functions-design.md` | Cloud Functions design (scheduled jobs + claims) — spec only, no code yet. |

## Deploy (only once the Firebase project exists)

```sh
# From this directory, after `firebase login` + `firebase use <project>`:
firebase deploy --only firestore:rules
firebase deploy --only firestore:indexes
firebase deploy --only storage
# Functions deploy comes with the Firebase-wiring chunk (see
# functions-design.md) — `firebase deploy --only functions`.
```

Verify in the Firebase console: Firestore → Rules (published version
matches this file) and Firestore → Indexes (all 16 composite indexes
`Enabled`). Rules changes take effect immediately; index builds take
a few minutes.

## Custom claims — how roles map to the rules

Claims are set by the `setUserClaims` Cloud Function
(`functions-design.md`, Job 6) or, until Functions are deployed, from
an admin machine with the Admin SDK (same payload, same validation).
Every user gets three claims:

| Claim | Type | Meaning |
|---|---|---|
| `orgId` | string | Organization the user belongs to (e.g. the Fazal Din org id). |
| `branchIds` | string[] | Branches the user may work in. Head-office roles still list their branches; the rules grant them cross-branch READ. |
| `role` | string | One of the 10 SRS §5 roles below. |

### The 10 roles (SRS §5.1)

| Role key | Claim `role` | Branch scope |
|---|---|---|
| Super Admin (vendor) | `super_admin` | All branches, all orgs (vendor support only) |
| Organization Owner | `owner` | All branches of the org (read + write) |
| Head Office Admin | `ho_admin` | All branches of the org (read + write) |
| Regional Manager | `regional_manager` | Own region's branches (read; transfers) |
| Branch Manager | `branch_manager` | Own branch only |
| Pharmacist | `pharmacist` | Own branch only; sole prescription reviewer |
| Cashier | `cashier` | Own branch only; POS + khata |
| Inventory Manager | `inventory_manager` | Own branch only; stock + purchasing |
| Accountant | `accountant` | All branches (read + finance writes) |
| Auditor | `auditor` | All branches, **read-only everywhere** |

Branch managers, pharmacists, cashiers and inventory managers get
`branchIds: [<their branch>]` only. A branch manager's credentials
can never read another branch's documents — even by guessing document
ids — because every branch-scoped rule checks `branchId in
request.auth.token.branchIds` (or a head-office role).

### What the rules enforce (and what they don't)

- **Enforced:** branch isolation, role-gated writes, append-only
  history collections (no update/delete on `stockTransactions`,
  `financialTransactions`, ledgers, `auditLogs`), money fields must be
  ints (paisa), counters never negative, sale/order doc id must equal
  the `idempotencyKey` field (a retried write can never duplicate),
  prescription `photoStoragePath` must be a Storage path (never a
  public http(s) URL — the bytes are governed by `storage.rules`).
- **Not enforced by rules:** multi-document integrity (sale + stock
  deduction + ledger entry in one transaction) — that is the client's
  job, done in a Firestore transaction / batched write by
  `ProductionDataLayer` (see `lib/core/data/`). The rules validate
  each document's shape; the transaction guarantees they land together.
- **Approval separation** (SRS §5.2.4 — the requester cannot approve
  their own stock adjustment / PO) is enforced in app logic
  (`purchases_logic.dart` guards), not in rules: rules cannot compare
  `requestedBy` to the approver across two writes without a lookup.

## Cost notes — Blaze pay-as-you-go (SRS §2.9)

The backend is Firebase **Blaze** (D62, 25 Nov 2026): the free quotas
still cover most usage at 8-branch scale and overage is cents — the
design stays quota-efficient exactly as it was on Spark (counters +
denormalized read models, batched writes under 500 ops, paginated
lists, listeners only on small live collections), because cheap is
still better than wasteful. What Blaze changes is the ceiling: if
usage ever exceeds the free tier, the product keeps working and the
bill is the overage, instead of Firestore stopping until the daily
reset. Monitor usage in the Firebase console with an alert at 70% of
the free tier; review the bill monthly with the client. If the
Blaze bill ever grows unexpectedly, the first lever is the same
quota-efficient design (fewer reads, more counters), not a
re-architecture.
