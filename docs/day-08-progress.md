# Day 8 Progress — Week 2 Day 1: Production Data Layer

**Date:** 25 Nov 2026. **Status:** DONE — verified (see table below).

## What was built

The production data layer (SRS Phase 6, adapted — no Firebase project
exists yet). All writes now go through `ProductionDataLayer`, which
wraps the existing mock repositories; screens are unchanged.

### New module — `lib/core/data/`

| File | What it does |
|---|---|
| `firestore_schema.dart` | Collection-path constants + field contracts exactly per SRS §3 (root collections + `branches/{branchId}/` subcollections); `validateDocument`; `maxFirestoreBatchWrites = 500`; idempotency-key validation; Cloud Storage path helpers (Blaze) — `organizations/{orgId}/branches/{branchId}/prescriptions/{id}.jpg` etc. Prescription contract: `photoStoragePath`, `photoContentType`, `photoUploadedAt`, `photoUploadedBy`, `localPhotoPath` (on-device cache only), `reminderSentAt` |
| `audit_log.dart` | Append-only `AuditLogEntry` (actor, action, entity type/id, branch, before/after summaries — never full snapshots) + `AuditLogWriter` / `InMemoryAuditLogWriter`; factories for stock movement, sale committed, duplicate sale skipped, money movement, sync conflict |
| `sync_queue.dart` | `SyncOperation` (pending/syncing/synced/conflict/failed), `SyncStore` + `InMemorySyncStore` (dedupe by idempotency key), `backoffForAttempt` (2s, 4s, 8s… cap 300s), `SyncConflictException`, `SyncQueue` (enqueue/processNext/processAll). Conflict policy: last-writer-wins via `updatedAt` EXCEPT money/stock docs → `conflict` status + audit entry, never silently overwritten or retried |
| `sync_store.dart` / `sync_store_io.dart` / `sync_store_web.dart` | Conditional import (same pattern as `file_download.dart`): sqflite-backed store on mobile/VM (PRIMARY KEY = idempotency key, lazy open, falls back to in-memory with `durable == false` if open fails), in-memory on web. **On web the queue resets on restart until Firestore exists.** |
| `inventory_engine.dart` | `InventoryEngine` (reserve → confirm on payment / release on cancel; FEFO via the Day 5 guard `fefoBatches`/`isBatchSellable` — reused, never re-implemented; `reserveBatches` re-validates exact FEFO batches; `quantityOnHand`/`quantityReserved` move synchronously with the batch snapshot + ledger), `StockMovement` + append-only `StockLedger`, `StockCounter`, `StockReservation`, `LocalWriteBatch` (mirrors Firestore WriteBatch, `chunks()` at ≤500 ops) |
| `backup_export.dart` | `DataExporter` (all repos, per-branch or org-wide, JSON with ISO dates, money in int paisa, web download via the existing file-download util), `jsonSafe`, `RestoreSink` + `InMemoryRestoreSink`, `ImportPolicy` (skipExisting default / overwrite), `DataImporter` (validates format/version/structure BEFORE any write; re-import never duplicates). Restore target is the sink, NOT live mock repos (mocks have no upsert-by-id — documented gap; the Firestore impl restores by doc id directly) |
| `production_data_layer.dart` | `ProductionDataLayer` + Riverpod provider `productionDataLayerProvider`. Wraps mock repos; `commitSale` (dedupe registry by key → duplicate returns the original sale, no double stock/money; reserve → repo decrement → save sale → engine confirm → khata → audit → sync enqueue with batched-write payload), `createOrder` (same dedupe/audit/enqueue; caller may pass an explicit `idempotencyKey`), `adjustStock`, `releaseSaleReservations`, export/import, audit/sync accessors. Actor defaults `demo-user` / `Demo staff` (Day 9 wires the real Firebase Auth uid) |

### Wiring (surgical — screens unchanged)

- `lib/features/billing/billing_provider.dart` — `SaleNotifier.completeSale` commits via `ProductionDataLayer.commitSale` (FEFO allocation + validation stay in the notifier); credit khata entry passed in, layer sets reason `Credit sale {invoiceNumber}` + referenceId.
- `lib/features/orders/orders_provider.dart` — `OrderQueueNotifier.createOrder` routes via the layer, optional `idempotencyKey` param.

### Firebase drafts — `firebase/`

| File | What it does |
|---|---|
| `firestore.rules` (578 lines, DRAFT, undeployed) | Deny-by-default, branch isolation via custom claims (`orgId`, `branchIds[]`, `role`), head-office roles read all branches of their org, auditor read-only everywhere, history collections append-only, money must be int, sale/order doc id must equal `idempotencyKey`, prescription `photoStoragePath` must be a Storage path (never a public http(s) URL) |
| `firestore.indexes.json` | 16 composite indexes (branch+status+createdAt etc.) |
| `storage.rules` (136 lines, DRAFT, Blaze) | Paths `organizations/{orgId}/branches/{branchId}/prescriptions/{file}`, `.../medicines/{file}`, `.../brand/{file}`, `.../backups/{file}` (Functions-only write, clients read-only for owner/HO admin); images only, ≤10 MB prescriptions / ≤5 MB others; same claims model |
| `functions-design.md` | Design only, no code: 6 jobs (1. daily expiry scan 06:00 PKT; 2. low-stock digest 07:00; 3. daily counters rollup 00:05; 4. scheduled backup export Sun 02:00 weekly + daily 02:30 incremental; 5. prescription review reminders every 6h with `reminderSentAt` stamp; 6. callable `setUserClaims`). Conventions: Node 20/TS, region `asia-south1`, idempotency via `scheduledRuns/{jobId}-{date}` run records + deterministic doc ids, failure → throw for Scheduler retry |
| `README.md` | Files table, deploy commands (rules/indexes/storage; Functions deferred), claims via `setUserClaims` Function (Admin SDK fallback), enforced/not-enforced list, Blaze cost notes |

### Backend pivot — Blaze (D62, 25 Nov 2026)

Dazy's order ("jo best rahy ga vo kro, free walaa ya paid jo b")
lifted the permanent-free Spark constraint. `firebase_storage`
re-added (`^14.1.0` — `^13.x` conflicted with `firebase_auth` 7.x;
the resolver itself suggested 14.1.0). Prescription photos designed
for Cloud Storage; Functions design only. SRS → v0.3, roadmap +
`docs/firebase-setup-plan.md` revised to Blaze. Still forbidden: no
Firebase project, no billing, no google-services.json, no
`Firebase.initializeApp()` — Dazy-only (his Google account + card).

### Defect fixed — prescription PNGs missing from the web build (D61)

- **First diagnosis was wrong:** not a stale build — `flutter clean`
  + full rebuild produced the same missing PNGs.
- **Real root cause (verified in the SDK source):** Flutter
  directory assets are **NOT recursive** — `flutter_tools`
  `asset.dart` (`_parseAssetFromDirectory`) uses non-recursive
  `listSync()` and keeps only direct `File` children. `assets/images/`
  bundled `.gitkeep` but silently skipped `prescriptions/`.
- **Fix:** declare `- assets/images/prescriptions/` explicitly in
  pubspec (comment points to D61).
- **Manifest gotcha:** `AssetManifest.bin.json` is a JSON string
  holding a **base64-encoded** blob — raw grep for "prescription"
  returns 0 even when bundled. Check `AssetManifest.bin` (greppable)
  or base64-decode first.

## Verification

| Check | Result |
|---|---|
| `flutter analyze` | **No issues found!** (after adding `firebase_storage`) |
| `flutter test` (full suite) | **221/221 passed** — 191 Week 1 + 30 Day 1 (`test/week2_day01_test.dart`). Covers: schema paths/field contracts/idempotency keys, Cloud Storage branch-scoped paths, reservation confirm/release, FEFO + expired-never-sellable guard, `reserveBatches` re-validation, adjust never-below-zero, batch chunking (1200 → 500/500/200; 500 → 1 chunk), duplicate sale commit (stock charged once, 1 sale, audit `sale.committed` ×1 + `sale.duplicate_skipped` ×1 + `stock.sale` ×1, 1 sync op), credit sale khata + money audit, failed commit releases reservation, order dedupe, adjustStock flow, back-off values + retry-then-sync with fake clock, money/stock conflict flagged + audit, `processAll` drain, platform store is sqflite on VM, export sections (medicines 180, orders 491, customers 8, prescriptions 20, POs 6, suppliers 4), per-branch export scoping, export-after-sale, import round-trip (created total → 0 created/skip all → overwrite all), import validation rejects bad format/version/missing id before any write, prescription-image widget test |
| `flutter build web --release` | **Pass** — `build/web/main.dart.js` 3,965,696 bytes |
| Prescription PNGs in build output | **Pass** — both at `build/web/assets/assets/images/prescriptions/` with exact source sizes (114,613 / 110,613 bytes) |
| Prescription PNGs in manifest | **Pass** — `AssetManifest.bin`: 8 "prescription" mentions, both paths present; `AssetManifest.bin.json` decoded (base64): same, both paths present |
| Prescription widget test | **Pass** — detail screen renders an `Image` wired to the sample asset path + "SAMPLE image bundled" caption. Caveat (D60): the test asset bundle cannot serve real app-asset bytes in `flutter test`, so real-bytes rendering is proven by the build-output check, not the widget test |
| Screens / no dead buttons | Unchanged — surgical wiring only; all 14 modules still load (covered by the Day 7 route-walk test) |

## Docs updated

- `docs/technical-decisions.md` — D53–D62 (schema source of truth; **D54 idempotency-key scope limitation** — key is minted per `completeSale`/`createOrder` call today, so a retry AFTER a failed attempt mints a new key and would NOT dedupe; POS screen must hold the key in cart state — Day 9 wiring item; layer API already accepts an explicit key; D55 sync queue; D56 engine reuses Day 5 guard; D57 audit summaries-not-snapshots; D58 restore-target-is-sink; D59 rules/claims; D60 test asset bundle; D61 PNG root cause + fix; D62 Blaze pivot).
- `docs/known-limitations.md` — §1 updated: queue/audit/layer exist locally; still no cloud until the Firebase project exists.
- `docs/firebase-setup-plan.md` — revised to Blaze (plan, services, quotas table).
- `docs/week-2-tracker.md` — started; Day 1 checked off, Days 2–5 planned.
- SRS (v0.3) + roadmap — backend sections revised to Blaze with a dated change note.
- `lib/models/prescription.dart` — doc comment updated (demo = bundled samples; production = Blaze Storage paths; `imageUrl` is the demo-era field, Firebase-wiring chunk migrates it).

## Blockers (unchanged, Dazy-only)

- Firebase project + billing (Blaze) — no cloud sync, no Functions, no Storage until then.
- GitHub repo `Sharjeel-580/pharmadesk` — created + verified 25 Nov 16:02 (public, empty). Code push via the browser upload route is a later chunk's work; local commit only in this chunk.
- Hadi's requirements (medicines count, delivery areas, payment method, branch cities, logo + brand colours).
- APK build remains environment-blocked in this sandbox (D52); CI is the fix path once the repo has code.
- Windows/iOS unverifiable on this Linux VM — never claimed.

## Follow-ups (next chunks)

- Firebase-wiring chunk: `flutterfire configure` (blocked on the project), Firestore repository implementations, prescription photo upload flow, rules unit tests for branch isolation, Functions implementation in the emulator.
- Day 2/3 (see `docs/week-2-tracker.md`): Auth + claims wiring, auto purchase list screen, goods receiving via the layer, reports on pre-aggregated counters, sync-status UI.
- D54: hold the idempotency key in POS cart state across retries.
