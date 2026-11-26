# Day 37 — Week 7 Day 5 Progress (26 Nov 2026)

**Scope:** brief §6 — Demo polish, first pass (D175). Verify each
demo-critical flow against `docs/demo-guide.md` and fix any defect
found; the Day 36 follow-up (restore counter advance) was judged
to fit cleanly and was built, not deferred.

**No defect was found in the demo flows.** Branch switching, all
five demo logins, the prescription dispatch guard, FEFO and the
auto purchase list all behave as the demo guide promises — each
is now pinned by a regression test so a later Week 7 change
cannot silently break the demo. One real defect was found and
fixed in the counter-advance follow-up's own new tests (§1):
the Day 36 "consumes no counter" pin was the old behaviour, and
it changed deliberately (see §1 and "Deliberate behaviour change
to an existing test" below).

## 1. Restore counter advance — BUILT (D175, Day 36 follow-up closed)

**The gap (D174):** `FirestoreOrderRepository.upsertOrder` preserved
a backup order number (D174) but never advanced the target's
per-branch counter, so a target at 1001 restoring `ORD-DHA-1492`
would mint 1002…1491 for new orders and could eventually mint
1492 for a different order. It could not collide in practice yet
(no live Firestore; the mock derives numbers from ids), but the
fix fits cleanly in this day's scope — one pure parser, one
transactional helper, one call site — so it was built instead of
deferred to Week 8.

**The rule (sequence parsing):** `parseOrderNumberSequence`
(`lib/core/data/firestore_repositories.dart`, top-level, pure)
matches `^ORD-([A-Z0-9]+)-(\d+)$` and returns the branch code +
numeric sequence, or `null` for any other shape (hand-written,
legacy, `INV-…`, lowercase, non-numeric suffix, trailing junk).
`upsertOrder` calls it on the effective (stored) number after
the batch write succeeds — a failed restore advances nothing —
and advances only when all three hold:

- the code matches this branch's code (`branchCode(branchId)`),
  so a `GLB` number carried on a `DHA` order advances neither
  counter (that sequence belongs to the other branch);
- the sequence is at/above the 1001 floor, so a below-floor
  number can never write a low counter value;
- the advance itself is monotonic and idempotent
  (`ensureCounterAtLeast`, next to `nextCounterValue`, one
  transaction: set only when the stored value is lower), so a
  re-restore of the same number advances nothing twice — and
  it also repairs a pre-D175 restore on re-import, because it
  runs for existing docs too, not only new ones.

The `OrderRepository.upsertOrder` interface doc
(`lib/core/services/repositories.dart`) now states the advance.
The mock repo needs nothing: it derives numbers from ids and
has no counter.

**Verified:** restoring `ORD-DHA-1492` into a fresh layer, the
next genuine create is `ORD-DHA-1493` (then 1494); re-restoring
the same doc leaves the next create at 1493; a `GLB` number on
a DHA order leaves both counters at their first mint (1001);
an unparsable number (`RESTORED-42`) is kept as-is with the
counter untouched; `ORD-DHA-500` still mints 1001 next;
`ORD-DHA-1001` into a fresh layer still mints 1002 next; and
the D172 pin holds (create 1001 → replay → create 1002).

**Deliberate behaviour change to an existing test (1 test,
D175 — nothing weakened):** the Day 36 test "Firestore
upsertOrder preserves a carried order number on a new doc and
consumes no counter (D174)" pinned the old behaviour (next
create `ORD-DHA-1001`, minted upsert `ORD-DHA-1002`). It now
expects the advanced counter (next create `ORD-DHA-1493`,
minted upsert `ORD-DHA-1494`) and is renamed to say so. The
Day 34 upsert tests are untouched and still pass (number-less
upserts mint; replaying a created 1001 is a no-op advance).

## 2. Branch switching changes every figure (demo guide §4)

Regression-checked against the seeded demo data (491 orders:
DHA 319, Gulberg 172; 737 batch rows: DHA 379, Gulberg 358):

- **Dashboard KPIs** (`computeDashboardKpis`): DHA vs Gulberg
  differ on every figure — today sales Rs 6,990.00 vs
  Rs 5,210.00, today orders 7 vs 5, 30-day revenue
  Rs 494,480.00 vs Rs 271,980.00, 30-day orders 284 vs 152,
  low-stock 74 vs 72, near-expiry 129 vs 147, expired 30 vs
  29, pending prescriptions 2 vs 4 — and the recent-orders
  lists are disjoint and branch-scoped.
- **Orders / inventory / reports:** `filterOrders` gives 319
  DHA vs 172 Gulberg, each list containing only its branch;
  low-stock medicine sets differ per branch; `computeReports`
  differs on total sales, total orders, low-stock rows, stock
  valuation and the daily series.
- **Provider level:** switching `activeBranchProvider` DHA →
  Gulberg flips `dashboardKpisProvider` figures; switching
  back restores the DHA figures exactly.
- **Shell widget:** at 1920×1080 the top-bar branch switcher
  flips DHA → Gulberg (popup menu, key
  `branch-switcher-button`) and the pill shows Gulberg.

No defect found. Test-side note: the first version of the
widget test tapped `find.text('Demo Branch — Gulberg')`
ambiguously — the owner dashboard's per-branch section shows
the same name — so the tap is scoped to the
`PopupMenuItem<String>` (D24/D33 pattern, finder scoping, no
app change).

## 3. Demo login for all 5 roles (password `demo1234`)

Email + password path re-pinned for every role (the one-tap
path is already pinned in Day 3): Owner Hassan Raza
(`owner@demo.pharmadesk`, all branches), Branch Manager Bilal
Ahmed (DHA), Pharmacist Dr. Sana Malik (DHA), Cashier Usman
Tariq (Gulberg), Inventory Manager Fatima Noor (Gulberg) —
each signs in with the right role key, name and home branch.
A wrong password fails for all five with "Incorrect password
for this demo account." and nobody signs in. Widget proof: a
typed cashier login opens the branch dashboard. No defect
found; `docs/demo-guide.md` needed no change (no demo fact
moved).

## 4. Prescription dispatch guard (demo guide §6)

- Pure function: Pending blocks dispatch; Approved, Rejected
  and Needs-clearer-photo release it; a pending prescription
  never blocks the earlier steps (Confirm / Processing /
  Ready); an approved prescription whose validity expired
  still blocks dispatch (D90), one valid tomorrow does not.
- Seeded links verified: `ord-dha-1312` (New, DHA) is linked
  to Pending `rx-dha-1`; `ord-glb-1487` (New, Gulberg) is
  linked to Pending `rx-glb-11`.
- End to end through `OrderQueueNotifier` (DHA): the linked
  order advances New → Confirmed → Processing → Ready with
  the prescription still Pending, is held at dispatch
  (advance returns `false`, status stays Ready), and after
  the pharmacist approves `rx-dha-1` the same advance goes
  through to Dispatched — no order-side mutation on approval
  (D44). Gulberg mirrors at the guard level. No defect found.

## 5. FEFO cart + auto purchase list

- `fefoBatches`: earliest expiry first, no-expiry last,
  batch-number tie-break; `fefoBatchFor` picks the earliest
  SELLABLE batch, skipping expired, empty and quarantined
  rows, and returns `null` when nothing is sellable.
- Seeded FEFO: Panadol Extra at DHA picks `DHA-1-2-173`
  (earliest expiry), Risek 20 picks `DHA-3-2-863`; for every
  DHA medicine the pick is never beaten by an earlier-expiry
  sellable batch.
- `allocateFefo` (POS cart): a 5-unit line over a 3-unit
  earliest batch + 10-unit later batch splits 3 + 2,
  earliest first, the line discount carried on the first
  chunk only, expired stock never touched; expired-only and
  insufficient-stock lines throw `ArgumentError`.
- Auto purchase list (seeded): DHA 23 suggestions, Gulberg
  21, every line valid (suggested qty > 0, usable < reorder
  level, qty = reorder − usable, line total = qty × unit
  cost) and the two medicine sets differ. Synthetic check:
  a low-stock medicine on an open Draft PO is excluded (not
  suggested); without the PO it is suggested with qty 15;
  reason priority is Low stock > Near expiry > Below
  reorder level. No defect found.

## Verification

- `flutter analyze`: **clean** — "No issues found!"
- Day 37 tests alone (`test/week7_day05_test.dart`): **27/27
  passed** — branch switching (5, incl. 1 widget), demo login
  (3, incl. 1 widget), dispatch guard (4), FEFO + auto
  purchase (7), counter advance (8).
- Full cumulative suite (Weeks 1–7): **1138/1138 passed**
  (baseline 1111 + 27 new).
- Fresh `flutter build web --release`: **pass** (46,744,905 bytes),
  run sequentially after the full suite.
- Prescription PNGs bundled (114,613 + 110,613 bytes in
  `build/web/assets/assets/images/prescriptions/`, 8 manifest
  mentions, both sample paths present).

## Files changed

- New: `test/week7_day05_test.dart`, `docs/day-37-progress.md`
- Modified: `lib/core/data/firestore_repositories.dart`
  (`parseOrderNumberSequence` + `ensureCounterAtLeast` +
  `upsertOrder` advances the counter past a preserved number,
  D175), `lib/core/services/repositories.dart`
  (`upsertOrder` interface doc states the advance),
  `test/week7_day04_test.dart` (one Day 36 test updated for
  the deliberate D175 behaviour change — see §1),
  `docs/technical-decisions.md` (D175),
  `docs/week-7-tracker.md` (Day 37 section)
- Untouched: `docs/demo-guide.md` (no demo fact changed),
  `presentation-video/`, no Firebase project created, nothing
  pushed to GitHub.

## Follow-ups (Week 7)

- **Super Admin franchise-view gate — STILL OPEN, awaiting
  Dazy's decision** (brief §4): no decision recorded anywhere
  in docs/; do not guess.
- **Live-Firestore E2E for the restore counter advance
  (D175):** blocked on a live Firebase project (Dazy-only
  step) — no project exists, none was created; verification
  here is the fake-transport suite.
- **Restore counter advance — closed this day:** the D174
  follow-up is built (D175); nothing from it carries to
  Week 8.
