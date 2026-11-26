# Day 34 — Week 7 Day 2 Progress (26 Nov 2026)

**Scope:** brief §2 — fake transport `runTransaction` +
`runBatchedWrites` (D172). Firestore order-repo return values
were verified by code inspection only (D165) because the fake
transport had no transaction / batched-write semantics; the
production data layer runs through both, so it could not be
tested end-to-end in the fake layer. This day gives the
canonical fake both operations, atomically, and closes the
D165 gap with round-trip tests through the fake transport.

## What shipped

### 1. Atomic fake transport — D172 (`test/week2_day03_test.dart`)

- **`runTransaction` — commit/rollback:** the transaction handle
  now works on a copy of the store (`_copyDocs`, each document
  map copied too), so reads inside a transaction see its own
  writes; a throw discards every write it made and the error
  propagates; a completed action commits all writes at once.
  The old class comment ("transactions apply writes immediately
  (no rollback) — tests never rely on rollback") is replaced by
  the new posture.
- **`runBatchedWrites` — all-or-nothing:** every operation —
  across all 500-op chunks — is applied to the working copy
  first and committed only when the whole list succeeds. A
  single bad operation (e.g. an update of a missing document)
  leaves the store exactly as it was, including operations in
  earlier chunks. The `batchChunks` seam still records the chunk
  sizes attempted, so the 500 / 500 / 200 chunking test keeps
  passing.
- **Deliberate divergence from real Firestore (recorded in
  D172, not hidden):** real Firestore is atomic per 500-op batch
  chunk, not across chunks. The fake is deliberately stricter:
  a whole `runBatchedWrites` call is all-or-nothing. Verified
  safe — every call site in `lib/` builds one op per doc + one
  per item of a single order / sale / PO (tens of ops at most),
  so no app call ever spans a chunk boundary and the stricter
  fake can never hide a real partial commit.

### 2. Defect found by the new tests, fixed the same day

- **`FirestoreOrderRepository.upsertOrder` minted an id but
  stored an empty key** (`lib/core/data/firestore_repositories.dart`):
  with an empty-id order it keyed off
  `order.effectiveIdempotencyKey`, which falls back to the
  order's own (empty) id — so it returned AND stored
  `idempotencyKey: ''` instead of the minted doc id.
  `createOrder` already passed `idempotencyKey: docId`
  explicitly and the mock's `upsertOrder` already keys a new
  upsert off the minted id, so the Firestore repo was the odd
  one out. A new doc now keys off `docId` (the D53 rule — the
  doc id IS the key); an existing doc keeps its stored key
  (falling back to the model's effective value only when the
  stored doc lacks one, as before). No existing test needed
  updating — the behaviour was previously untested (D165
  inspection-only), and the new test pins the fixed behaviour.
- **Untouched:** the real `FirebaseFirestoreTransport`;
  `updateOrder` (it only runs when the doc was found, so its
  key fallback is always a non-empty id); the order repo's
  numbering, dedupe and item-subcollection logic; every other
  fake-transport copy in other test files (only the canonical
  one in `week2_day03_test.dart` is upgraded, per the brief).

### 3. New tests — `test/week7_day02_test.dart` (18 tests)

The file imports the canonical fake, `seedBranches` and
`sampleOrder` from `test/week2_day03_test.dart` rather than
carrying a second copy of the transport.

- **Transaction commit/rollback (6):** commit lands set +
  update + merge together, reads see own writes, return value
  passes through; a throw discards every write (created doc
  absent, pre-existing doc unchanged) and propagates; a failed
  counter increment consumes no value; a committed transaction
  is visible to the next one; get reads pre-existing data /
  null when missing; an update of a missing doc inside a
  transaction rolls the whole transaction back.
- **Batched-write atomicity (4):** a successful batch applies
  set + update + delete together; a failing batch applies
  nothing — not even the sets before the bad operation; the
  all-or-nothing holds across the 500-op chunk boundary (501
  sets + 1 bad update in the second chunk → 0 docs, chunks
  recorded [500, 2]); an empty batch is a no-op.
- **Order-repo return values through the fake transport (8,
  D165 closed):** `createOrder` with a client id returns id +
  `ORD-DHA-1001` + key == id, stored doc and `getById`
  read-back agree; `createOrder` with no id mints one and keys
  off it; a duplicate `createOrder` returns the original
  number/key and consumes no counter value (next new order is
  1002); `upsertOrder` for a new order returns the assigned
  number + key; `upsertOrder` on an existing order keeps its
  number/key and consumes no counter (restore never
  re-numbers); `upsertOrder` with no id mints one and assigns a
  number; `getById` returns the same number/key the create
  returned; a failed counter transaction leaves the next order
  at `ORD-DHA-1002`, not 1003.

## Verification

- `flutter analyze`: clean, zero issues (re-run after the
  `upsertOrder` fix).
- Day 34 tests alone (`test/week7_day02_test.dart`): **18/18**.
- The fake's home file (`test/week2_day03_test.dart`):
  **46/46** after the change.
- Cumulative full suite: **1046/1046** (1028 + 18 new).
- Fresh `flutter build web --release`: pass
  (46,742,627 bytes), run sequentially after the full suite.
- Prescription PNGs bundled (114,613 + 110,613 bytes in
  `build/web/assets/assets/images/prescriptions/`, 8 manifest
  mentions in `AssetManifest.bin`).

## Follow-ups (Week 7)

- **Cross-backend restore edge (Day 24, D169)** (brief §3):
  mock-export sale doc id ≠ idempotency key — still open.
- **Super Admin franchise-view gate — STILL OPEN, awaiting
  Dazy's decision** (brief §4): no decision recorded anywhere
  in docs/; do not guess.
- **Other fake-transport copies:** the local fakes in
  `week2_day04`, `week3_day01–03`, `week4_day02–03`,
  `week5_day01` (and others) still have the old
  apply-immediately transaction / non-atomic batch behaviour.
  They are per-file test doubles, not the canonical fake, and
  none of their tests rely on rollback — left as-is per the
  brief's scope. If a later day needs atomicity from one of
  them, upgrade that copy then (or point it at the canonical
  fake) rather than now.
