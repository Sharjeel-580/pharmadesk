# Day 40 — Week 8 Day 3 Progress (26 Nov 2026)

**Scope:** brief §3 — fake-transport copies sweep (D178). Find EVERY
per-file fake-transport copy in `test/`, determine for each whether
any production-layer test relies on it for transaction/batch
atomicity, upgrade the ones that are relied on to the D172
behaviour, leave the rest as-is with the reason recorded per copy.
Add regression tests in `test/week8_day03_test.dart`. No existing
test weakened.

**Result: 12 non-canonical copies found, 0 upgraded.** No
production-layer test in any of the 12 files relies on its copy for
atomicity — no test in those files would pass/fail differently if a
transaction or batched write failed part-way. Every
atomicity-sensitive production test lives in week7_day02–05, which
already import the canonical D172 fake from
`test/week2_day03_test.dart`. The sweep therefore changes no copy
and no existing test; it pins the finding with 8 new tests
(**8/8**). `flutter analyze` clean.

## 1. How the copies were found (not trusted from the tracker list)

`grep -rn "implements FirestoreTransport" test/ lib/` plus a grep
for `runTransaction` / `runBatchedWrites` across `test/`:

- 13 classes implement `FirestoreTransport` in `test/`: the
  canonical `FakeFirestoreTransport` in `test/week2_day03_test.dart`
  (already D172) + 12 non-canonical copies (table §2).
- `lib/` has exactly one other implementation, the real
  `FirebaseFirestoreTransport` — untouched, as always.
- No test file calls `transport.runTransaction` /
  `transport.runBatchedWrites` directly: every use goes through a
  production repository or the production data layer. The test in
  the task's definition of "relies on atomicity" is therefore
  applied per file to the repository/layer paths its tests exercise:
  a copy is relied on for atomicity only if some test in its file
  would pass/fail differently if a transaction or batched write
  failed part-way (i.e. a test that makes one fail, or asserts
  post-failure store state).
- `test/week8_day01_test.dart` and `test/week8_day02_test.dart`
  contain no fake transport. `test/test_helpers.dart`,
  `test/day_0*.dart`, `test/widget_test.dart`,
  `test/week2_day01/02/05_test.dart` contain none either.

The production call sites that matter (all in
`lib/core/data/firestore_repositories.dart`): `nextCounterValue`
(:181) and `ensureCounterAtLeast` (:210) — transactions;
`createOrder` (:481), `updateOrder` (:537), `upsertOrder` (:614),
`receiveStock` (:762), `_mutateBatch` (:963), `createSale` (:1313),
`upsertSale` (:1372), `createReturn` (:1445),
`createPurchaseOrder` (:1919), `updatePurchaseOrder` (:1967),
`upsertPurchaseOrder` (:2034) — batched writes; goods-receipt
create (:3436) — counter transaction + batch. Every other
repository's writes are plain `getDocument` / `setDocument` /
`updateDocument` and can never touch a transaction or a batch,
whatever fake it is constructed with.

## 2. Per-copy verdicts (all 12 — none upgraded)

| # | File | Copy | Production paths exercised through it | Relies on atomicity? | Verdict + reason |
|---|---|---|---|---|---|
| 1 | `test/week2_day04_test.dart:151` | `_FakeTransport` (private) | `FirestoreSaleReturnRepository.createReturn` (batch of sets, success path only); `FirestoreSaleRepository.updateSale` (plain update) | No | **Left as-is.** `createReturn` emits only `set` ops, which cannot fail part-way in either fake; no test in the file makes a transaction or batch fail. The two tests using it are 'FirestoreSaleReturnRepository over the fake transport' and 'FirestoreSaleRepository.updateSale writes the status'. |
| 2 | `test/week3_day01_test.dart:35` | `FakeFirestoreTransport` (public) | Staff / Attendance / Shift / Expense / FinancialTransaction / SupplierPayment / Medicine repos — plain get/set/update only; none of those repos calls `runTransaction` / `runBatchedWrites` anywhere in `lib/` | No | **Left as-is.** No transaction or batch is ever issued through this copy, so atomicity cannot matter for it. Pinned by the day test (§4, staff round-trip). |
| 3 | `test/week3_day02_test.dart:52` | `FakeFirestoreTransport` (public) | `FirestoreGoodsReceiptRepository.createGoodsReceipt` (counter transaction + batch of sets, success path only: create → GR-DHA-1001, retry returns original, second → GR-DHA-1002); `FirestoreSalaryRepository.saveSalaryRecord` (plain set). The layer tests in the file run on mock repos, not this copy. | No | **Left as-is.** The counter + batch path is exercised only on success; the validation test ('create rejects a receipt without PO or branch') throws before any transport call. No test makes either operation fail part-way. Pinned by the day test (§4, goods-receipt numbering). |
| 4 | `test/week3_day03_test.dart:54` | `FakeFirestoreTransport` (public) | `FirestoreReportCounterRepository` — reads only (`getDailyCounter` / `getDailyCounters` / `listDailyCountersPaged`). The layer tests in the file run on mock repos. | No | **Left as-is.** A read-only repo issues no transaction or batch at all. Pinned by the day test (§4, counter hit + miss). |
| 5 | `test/week4_day02_test.dart:1121` | `_FakeFirestoreTransport` (private) | `FirestoreStockTransferRepository.createTransfer` (counter transaction + plain set, success + D65 retry only); `FirestoreRiderRepository.updateRider` (plain update). The layer tests in the file run on mock repos. | No | **Left as-is.** The counter transaction is exercised only on success; no test makes it fail part-way. The tests using it are 'transfer create numbers, reads both directions, updates' and 'rider updateRider round-trips the live order'. |
| 6 | `test/week4_day03_test.dart:1068` | `_FakeFirestoreTransport` (private) | `FirestoreDailyClosingRepository` — plain writes only (the file's own `_FakeFirestoreTransaction` comment says "the repo tests never transact"). | No | **Left as-is.** No transaction or batch is ever issued through this copy. |
| 7 | `test/week5_day01_test.dart:136` | `_MemoryTransport` (private) | `FirestoreStockAdjustmentRequestRepository.saveRequest` — plain set. The copy's `runTransaction` / `runBatchedWrites` both throw `UnimplementedError`. | No | **Left as-is.** The stub is never called: the only repo constructed with it never issues a transaction or batch, and no test in the file calls either method directly. The throw is the deliberate "not used here" signal, not a gap. |
| 8 | `test/week5_day02_test.dart:176` | `_MemoryTransport` (private) | `FirestoreBranchRepository` round-trips — plain get/set/update only. The copy's `runTransaction` / `runBatchedWrites` both throw `UnimplementedError`. The `createOrder` / `importBackup` tests in the file run through the mock-repo `_Harness`, never this copy. | No | **Left as-is.** Same reason as #7: the stub is never called. |
| 9 | `test/week5_day03_test.dart:129` | `FakeFirestoreTransport` (public) | `FirestoreInventoryRepository.saveBranchLocation` — plain merge-set only. (`receiveStock` / `_mutateBatch` do use a transaction, but no test in this file calls them through the Firestore repo.) | No | **Left as-is.** The only Firestore-repo path exercised is a plain merge-set. Pinned by the day test (§4, merge-set keeps counters). |
| 10 | `test/week6_day03_test.dart:475` | `_MemoryTransport` (private) | `FirestoreBranchRepository` round-trip — plain get/set/update only. Both transaction/batch methods throw `UnimplementedError`. | No | **Left as-is.** Same reason as #7: the stub is never called. |
| 11 | `test/week6_day04_test.dart:967` | `_MemoryTransport` (private) | `FirestoreMedicineRepository` barcode test — plain upsert only. Both transaction/batch methods throw `UnimplementedError`. The `createOrder` / `upsertOrder` tests in the file run on `MockOrderRepository`, never this copy. | No | **Left as-is.** Same reason as #7: the stub is never called. |
| 12 | `test/week7_day01_test.dart:200` | `_MemoryTransport` (private) | `FirestoreQuarantineOutcomeRequestRepository.saveRequest` — plain set. Both transaction/batch methods throw `UnimplementedError`. The layer tests in the file run on mock repos. | No | **Left as-is.** Same reason as #7: the stub is never called. |

Why "success path only" is not reliance: the old copies and the
D172 copy are observationally identical on every success path —
the old transaction handle already lets reads see its own writes
(it works on the live map), and the old batch applies the same ops
in the same order. They differ ONLY when an operation throws
mid-transaction or mid-batch (old: earlier writes stay; D172:
nothing applies). A file with no test that makes one throw cannot
distinguish the two, so upgrading it would be churn with zero
test signal — the brief says to leave such copies as-is with the
reason recorded, which is what §2 does.

Cross-checks done before concluding: every `throws` in the seven
files with real (non-stub) copies is a validation/factory error
that fires before any transport call, or a mock-repo layer test —
none is a fake-transport failure assertion. The week4_day02
'dispatch short of stock throws and holds nothing' test is a
mock-repo layer test, not a fake-transport test.

## 3. Why the canonical fake is the only one that needed D172

The atomicity-sensitive production tests all live in
week7_day02–05, and all four files `import
'week2_day03_test.dart'` — the canonical fake. That is where the
D172 behaviour is actually relied on: failed counter transactions
consuming no number (`createOrder` numbering), restore replays via
`upsertOrder` / `upsertSale` through the batch path, and the
cross-backend restore in week7_day03–05. No other file's tests
touch those paths through a local copy, which is why the Week 7
brief scoped the D172 upgrade to the canonical copy only, and why
this sweep upgrades nothing further.

## 4. New tests — `test/week8_day03_test.dart` (8 tests, 8/8)

**Part A — the canonical D172 standard, re-pinned (4 tests).**
The sweep holds every copy against this standard, so the day file
re-pins it directly on the canonical fake (imported from
`week2_day03_test.dart`, as week7_day02 does): failed transaction
applies nothing; failed batch applies nothing (including the good
set earlier in the batch); reads inside a transaction see its own
writes; failed counter transaction consumes no value.

**Part B — untouched PUBLIC copies, behaviour unchanged where it
matters (4 tests).** Each public copy is imported with a prefix
(the four files all define a public `FakeFirestoreTransport`) and
its production path re-exercised:

- week3_day01: staff `createStaff` + `getById` + branch-scoped
  list round-trip (plain set path).
- week3_day02: goods-receipt create → `GR-DHA-1001`, retry returns
  the original with no counter consumed, second create →
  `GR-DHA-1002` (counter-transaction + batch success path).
- week3_day03: report-counter `getDailyCounter` hit
  (`salesTotalMinor` 250000, `ordersCount` 25) + miss.
- week5_day03: branch-location merge-set keeps `quantityOnHand` 5
  on save and on clear.

**Private copies cannot be pinned from this file:** Dart
library-private names (`_FakeTransport`,
`_FakeFirestoreTransport`, `_MemoryTransport`) are not visible
across libraries, so a day-file test of them would test a different
object, not the copy. Their behaviour is pinned by their own
files' tests (named in §2), which the cumulative suite re-runs —
all green (§5).

No existing test was touched, renamed or weakened. No test
assertion changed for a behaviour change, because no behaviour
changed.

## 5. Verification

- `flutter analyze`: clean ("No issues found!").
- Day tests: `test/week8_day03_test.dart` **8/8 passed**.
- Full cumulative suite: **1191/1191 passed** (1183 baseline + 8 new, 13:02). (Log kept in the workspace at `~/workspace/fazal-din-pharma-week8-day40-full-suite.log`, not `/tmp`, per the Day 39 lesson.)
- Fresh `flutter build web --release`: **pass** — `main.dart.js` 4,683,590 bytes (unchanged from Day 39, as expected — no production code changed this day).
- Prescription PNGs bundled: **confirmed** — 114,613 + 110,613 bytes in `build/web/assets/assets/images/prescriptions/`.

## 6. Files changed

- **Tests:** `test/week8_day03_test.dart` (new, 8 tests). No
  production code changed, no other test file changed.
- **Docs:** `docs/day-40-progress.md` (this file),
  `docs/week-8-tracker.md` (Day 40 section),
  `docs/technical-decisions.md` (D178).

## 7. Follow-ups (Week 8)

- Day 41 (D179): handover docs — deployment guide, staff/owner
  user manual, demo-guide refresh.
- Day 42 (D180): final QA sweep.
- **Super Admin franchise-view gate — SKIPPED, still open (brief
  §4):** no Dazy decision is recorded anywhere in `docs/`; nothing
  was guessed or built.
- **Caveat (stated, not hidden):** full end-to-end verification
  against live Firestore stays BLOCKED on a live Firebase project
  (Dazy-only step) — no project exists, none was created, no live
  Firebase call was made. Verification here is the fake-transport
  suite (`test/week8_day03_test.dart`, 8 tests) + the cumulative
  suite.
- **Untouched:** `presentation-video/`; no new routes, no new
  capabilities, no matrix changes; no dependency added (pubspec
  untouched); no production code changed at all this day.
