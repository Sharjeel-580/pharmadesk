# Day 35 — Week 7 Day 3 Progress (26 Nov 2026)

**Scope:** brief §3 — cross-backend restore re-key by
idempotencyKey (D173). A mock export restored into the Firestore
layer wrote the sale doc under the exported mock id
(`sale-DHA-1001`), not the idempotency key, breaching the D53
doc-id invariant (doc id = idempotency key, SRS §2.5, enforced by
the Firestore rules). This day re-keys the restore by key, keeps
ImportReport counting correct, and leaves the D169 semantics
untouched (restore never deletes; counters and sale-payment legs
stay unrestored).

## What shipped

### 1. The restore re-keys sales + orders by idempotencyKey — D173 (`lib/core/data/production_data_layer.dart`)

- **New helper `_restoreDocId`:** for the `sales` and `orders`
  sections, the doc id the restore writes under is the payload's
  non-empty `idempotencyKey`; every other section keeps the
  exported id, and a missing or empty key keeps it too (a sale
  whose key falls back to its id round-trips unchanged).
  `importBackup` computes the effective id once per doc and uses
  it for the existence check, the sink record, the write and the
  report — so a re-keyed sale counts once, not twice. The sink
  records the EFFECTIVE id: it is the record of what was
  actually written.
- **Existence is measured by key too (`_restoreDocExists` +
  `_restoreHasKey`):** for sales/orders, `getById(effectiveId)`
  OR a scan for a stored record with the same key. Without the
  scan, re-importing a mock layer's own export would count its
  sales as `created` instead of `overwritten` (the target holds
  them under their mock ids). For orders the re-key is a no-op
  today — the mock and Firestore repos both mint the key equal
  to the id — but the rule is applied anyway so a hand-built
  backup with a differing order key restores under the key,
  like a sale.
- **The export is unchanged:** a mock export still carries the
  mock-assigned id; only the restore re-keys. `DataImporter`
  (the sink-only importer) is unchanged — its pinned
  upsert-by-id behaviour stands; the re-key lives in the live
  restore path only.

### 2. The mock's `upsertSale` matches by key — D173 (`lib/core/services/repositories.dart`)

- `MockSaleRepository.upsertSale` now matches an existing sale
  by id OR by non-empty idempotencyKey. A restore of a sale the
  mock already holds under its mock-assigned id therefore
  REPLACES that same sale in place under its canonical id
  instead of duplicating it: a re-import of the layer's own
  export stays one sale, and the report counts it as
  overwritten, not created. A sale is one record per key.
  `upsertSale`'s only caller in `lib/` is the restore
  (`_restoreDoc`), so the change is restore-scoped in practice.
- **Firestore `upsertSale` behaviour unchanged**
  (`lib/core/data/firestore_repositories.dart`): the layer now
  passes it `sale.id` == key, so the doc lands under the key.
  Only its stale comment was updated (it said the restore
  writes "under the exported id").
- **Header comments** in `lib/core/data/backup_export.dart`
  (restore limits) now state the D173 re-key.

### 3. What the new tests proved about the Firestore leg gap

While writing the split-payment test, the first version
asserted the two legs survive a Firestore restore — it failed:
`saleToFirestore` writes NO `payments` list into the sale doc
(legs live only in the `payments` subcollection) and
`saleFromFirestore` reads back `payments == []`. That is the
D169 Firestore-only gap, already documented — totals, method
and cash received survive; the per-leg split is lost on
Firestore while the restore never rewrites the subcollection.
The test now pins exactly that (totals survive, legs empty,
subcollection count 0) instead of asserting a round-trip that
does not exist. In the mock the legs DO round-trip (pinned in
week6_day05).

### 4. Deliberate behaviour changes to existing tests (3 tests, 4 assertions)

The re-key changes what id a restored sale lands under, so
three existing tests that read a restored sale back by its old
mock id were updated — nothing was weakened, each now asserts
the new (correct) id AND that the old id no longer lands:

- `test/week5_day02_test.dart` — "restore overwrites a changed
  sale record": reads back by key `sale-d150-1`, asserts the
  changed total + preserved invoice, asserts `getById(saleId)`
  is null and `getSales()` is still length 1 (no duplicate).
- `test/week6_day05_test.dart` — split-payment round-trip test:
  reads back by key `sale-d169-split-1`, asserts id == key and
  the old mock id is null; the "NOT fixed here" comment now
  says D173 fixed the restore side. The counters test reads
  back by key `sale-d169-counter-1` (plus an assertion that the
  mock id differs from the key, which keeps the `saved`
  variable used). The "restore recreates a missing doc" test
  reads back by key `sale-d169-recreate-1` and asserts the old
  mock id is null.

### 5. Super Admin franchise-view gate — SKIPPED, still open (brief §4)

Searched `docs/` for any Dazy decision on the gate: none is
recorded anywhere (brief §4, D159, Week 5/6 trackers and the
Day 30 note all say "pending Dazy's decision"). Per the brief,
nothing was guessed or built. The gate stays as Day 27 left
it: Super Admin / Owner / HO Admin pass the franchise view on
write-level `branches`; Auditor excluded. This item stays open
in the Week 7 tracker follow-ups.

## New tests — `test/week7_day03_test.dart` (15 tests)

The file imports the canonical fake, `seedBranches` and
`sampleSale` from `test/week2_day03_test.dart` (Day 34 fake,
with `runTransaction` + `runBatchedWrites`) rather than
carrying a second copy. A `_FirestoreHarness` builds a
`ProductionDataLayer` whose sale + order repos are the
Firestore implementations over the fake transport; every other
repo is a mock.

- **Mock export → Firestore layer (5):** the sale lands under
  the key (transport doc at the key path exists, nothing under
  the mock id; repo read-back by key has totals + items, by
  mock id is null); the stored doc satisfies the D53 / rules
  invariant (`idempotencyKey` == doc id); split-payment totals
  survive while the legs are lost on Firestore (D169 gap) and
  the payments subcollection stays empty (count 0); re-restore
  under `skipExisting` counts the sale once (created 1, then
  created 0 / skipped 1, still 1 sale); re-restore under
  `overwrite` counts once (created 1, then overwritten 1,
  still 1 sale).
- **Firestore export → mock layer, reverse (2):** a
  Firestore-native sale (doc id == key) restores into the mock
  under its key with totals + items intact; re-restore counts
  once (created 1, then skipped 1, still 1 sale).
- **Same-layer mock re-import (2):** edited-total re-import
  under overwrite replaces in place under the key (created 0,
  overwritten 1, still 1 sale, old mock id null, new total
  read back by key); under `skipExisting` the sale is left
  alone (skipped 1, created 0, old total kept).
- **D169 semantics intact (3):** a sale made in the target
  after the export survives the restore (both sales present);
  the export has no `counters` / `inventoryCounters` /
  `salePayments` sections and a sale-only restore writes no
  counter doc (`countIn('branches/branch-dha-main/counters')`
  == 0); the sink records the effective id (snapshot has the
  key, not the mock id).
- **Edges (3):** a sale doc without an idempotencyKey restores
  under its exported id (`Sale.fromMap` falls back key = id);
  a sale whose key already equals its id restores unchanged
  (created 1, then skipped 1); orders re-key is a no-op — a
  mock order restores into the Firestore layer under its id
  (== key, stored `idempotencyKey` agrees) and a re-restore
  creates nothing.

## Verification

- `flutter analyze`: clean, zero issues.
- Day 35 tests alone (`test/week7_day03_test.dart`): **15/15**.
- Cumulative full suite: **1061/1061** (1046 + 15 new).
  First full run after the fix showed **1060 pass, 1 fail** —
  the week6_day05 "restore recreates a missing doc" test, the
  same deliberate re-key change (it read the recreated sale
  back by its old mock id); updated as §4 above and the suite
  re-ran green.
- Fresh `flutter build web --release`: pass
  (46,743,377 bytes), run sequentially after the full suite.
- Prescription PNGs bundled (114,613 + 110,613 bytes in
  `build/web/assets/assets/images/prescriptions/`).

## Caveat — stated plainly, not hidden

**Full end-to-end verification against live Firestore stays
BLOCKED on a live Firebase project (a Dazy-only step).**
No Firebase project exists; none was created, and no live
Firebase call was made. The verification available here is the
fake-transport tests above: the mock export → Firestore-layer
restore runs through the real `FirestoreSaleRepository` /
`FirestoreOrderRepository` code over the Day 34 fake transport
(including its `runBatchedWrites` atomicity), and the stored
fake doc satisfies the doc-id == key invariant the real rules
enforce. Whether the real Firestore rules accept the restored
doc, and whether a real cross-backend restore behaves the same
under live Firestore, is unverified until a project exists.

## Known limitation (one-time, recorded)

A target that already holds a sale under a pre-D173 restore's
exported id keeps that stale doc (restore never deletes, D169);
the re-keyed doc under the key is canonical, and any later
re-restore is idempotent against the key doc. In practice this
cannot have happened yet — no live Firestore exists, and in
the mock the key-matching upsert replaces the old-id copy in
place — but a Firestore target restored cross-backend before
this fix would carry one stale doc per sale.

## Follow-ups (Week 7)

- **Super Admin franchise-view gate — STILL OPEN, awaiting
  Dazy's decision** (brief §4): no decision recorded anywhere
  in docs/; do not guess.
- **Live-Firestore E2E for the re-key** (above): blocked on a
  live Firebase project (Dazy-only step).
