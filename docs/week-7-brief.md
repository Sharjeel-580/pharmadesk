# Week 7 Brief — PharmaDesk

**Status: DRAFT (not yet started).** Coordinator to spawn after Week 6 push + CI green.

## Where we are
- Week 6 COMPLETE + VERIFIED (coordinator-verified; parent independent verification in progress): analyze clean, Week 6 tests 136/136, cumulative **1008/1008**, web build pass.
- Week 6 closed: FR-HO-08 guard on the six finance writes (D161), payment idempotency via D115 dialog-held keys (D162), ActiveBranchNotifier directory support (D163), branch code validation (D164), model gaps Supplier.createdAt / Order.orderNumber+idempotencyKey (D165), barcode uniqueness at repo (D166), POS tax live-watch (D167), branch code form field (D168), restore semantics decided — accept as documented (D169), Phase 8 QA depth (D170).
- Seeded barcodes verified distinct: 180/180, no seed rows changed.
- Decisions continue from **D171**. Tracker: `docs/week-6-tracker.md` (read before starting); new tracker `docs/week-7-tracker.md`.
- **Parent verification of Week 6 (independent re-runs, 2026-11-26):** pending — see coordinator report. If the parent sends a CI-fix message, that takes priority over Week 7 work.

## Week 7 scope (from Week 6 follow-ups, in priority order)

### 1. Quarantine outcome queue — persist it (D141 posture, carried)
The quarantine outcome queue is still session-only while the outcome itself IS persisted on the batch row. Persist the queue the same way the adjustment queue was persisted in Week 5 (D146, `branches/{branchId}/...`), so a restart no longer loses pending outcomes. Tests: queue survives a repo restart; outcomes still land on the batch row exactly once.

### 2. Fake transport — `runTransaction` + `runBatchedWrites`
Firestore order-repo return values are currently verified by code inspection only (D165) because the fake transport has no `runTransaction` / `runBatchedWrites`. Add both to the fake transport so the production data layer can be tested end-to-end in the fake layer. Tests: transaction commit/rollback semantics, batched-write atomicity, order-repo return values through the fake transport.

### 3. Cross-backend restore edge (Day 24, D169)
Mock-export sale doc id ≠ idempotency key. Re-key restore by idempotencyKey so a mock export restored into the Firestore layer (and vice versa) matches sales correctly. Full end-to-end verification stays blocked on a live Firebase project (Dazy-only step) — implement behind the same mock-default guard, cover with fake-transport tests, and record the unverified-E2E caveat plainly in the tracker.

### 4. Super Admin franchise-view gate — PENDING DAZY'S DECISION
Still open since Week 5 (asked in the Week 5 report; no answer yet). If Dazy has decided by the time Week 7 runs, implement his choice (a role check outside the matrix). **If no decision yet, DO NOT guess — skip this item and note it as still open.**

### 5. Phase 8 QA depth — continued
- Fresh full 390px sweep + 47-route walk using the CORRECTED `FlutterError.onError` trap (the D160-drain caveat: Day 27 "0 overflows" figures were undercounted by the old `takeException` drain — they meant "no single-overflow found"). The corrected trap is now the standard; every sweep figure must say which trap measured it.
- Verify the D170 overflow fixes in place (supplier detail, `/reports` dropdown + PagedListControls, supplier payment dialog dropdown, `/branches` row).
- Offline-queue + role-gate coverage for every new flow added in Week 7.
- Finance agreement third pass over the newly guarded finance writes + idempotent payments (cashbook vs P&L vs supplier ledger).

### 6. Demo polish — first pass
With the data layer hardened, one focused pass on demo-critical flows: branch switching must change every figure (regression-check the demo guide), demo login for all 5 roles still works, prescription dispatch guard still blocks correctly, FEFO cart + auto purchase list still behave. Any defect found is fixed in Week 7; anything needing Hadi's input is recorded, never invented.

## Out of scope (do not build)
- Franchise onboarding (Phase 2 scope — not yet).
- Firebase project / billing creation — Dazy-only step, never create it.
- Pushing to GitHub — the parent pushes committed files via browser upload.

## Standing rules (unchanged)
- Day-builder subagents, coordinator self-verifies every claim with its own re-runs (analyze + day tests + cumulative).
- Testing rule: each day tested alone, then ALL weeks together (cumulative/regression, Weeks 1–7).
- Quality: smooth/clean from day one, test everything, no dirty UI, everything easy to access. Users internal only (staff/owner) — NO customer app, ever.
- Commit per day/milestone with verification numbers. Clean tree at week end. Never touch `presentation-video/`.
- Report to the parent ONLY when the whole week is complete or a Dazy-only blocker appears.
