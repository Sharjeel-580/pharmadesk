# Week 6 Brief — PharmaDesk

**Status: DRAFT (not yet started).** Coordinator to spawn after Week 5 push + CI green.

## Where we are
- Week 5 COMPLETE + VERIFIED (coordinator-verified; parent independent verification in progress): analyze clean, Week 5 tests 163/163, cumulative **872/872**, web build pass.
- Week 5 closed: adjustment-queue Firestore persistence (D146), supplier payments through the layer (D147), branch repository + FR-HO-08 enforcement (D148/D149), restore upsert-by-id (D150), medicine master edit form + per-branch rack/shelf (D151–D153), quarantine return/disposal approval (D154), POS Settings wiring (D155), closing corrections + cash reconciliation (D156/D157), franchise commission/royalty schema + HO view (D158/D159), Phase 8 QA depth (D160).
- Decisions continue from **D161**. Tracker: `docs/week-5-tracker.md` (read before starting); new tracker `docs/week-6-tracker.md`.
- **Parent verification of Week 5 (independent re-runs, 2026-11-26):** pending — see coordinator report. If the parent sends a CI-fix message, that takes priority over Week 6 work.

## Week 6 scope (from Week 5 follow-ups, in priority order)

### 1. FR-HO-08 guard — finance writes (D149 boundary, carried)
Extend the deactivation guard to `recordExpense` / `recordIncome` / `recordSupplierPayment` / closings / corrections / reconciliations. Same guard pattern as the 10 write paths guarded in Week 5. Tests: deactivated branch cannot post any finance write; error path is explicit and visible in the UI.

### 2. Payment idempotency — D115 pattern (Day 23 gap)
Notifier-held idempotency keys can still double-charge on a UI double-tap. Apply the D115 dialog-held-key pattern to the cashbook + supplier-payment dialogs together (one key held by the dialog for its whole lifetime, not the notifier). Tests: double-submit produces exactly one payment.

### 3. Super Admin franchise-view gate — PENDING DAZY'S DECISION
Super Admin currently passes the franchise view because the role matrix grants `allowed` on `branches`; the Week 5 brief said "Owner / HO Admin only". If Dazy has decided by the time Week 6 runs, implement his choice (a role check outside the matrix). **If no decision yet, DO NOT guess — skip this item and note it as still open.**

### 4. ActiveBranchNotifier — directory-added branches
`switchTo` still reads demoBranches only; a directory-added branch cannot become active (provider-cycle risk — needs a deliberate design decision). Design the safe resolution, document it (D-number), implement, test.

### 5. Model gaps
- `Supplier.createdAt`
- `Order.orderNumber` + `idempotencyKey`
- Branch mapper: validate §3 `code`
All with migration-safe defaults for seeded data. Tests cover mapper round-trips.

### 6. Barcode uniqueness + POS tax live-watch
- Enforce barcode uniqueness at the medicine master (reject duplicates with a clear message; report existing duplicates in seed data, if any, as a data note — do not silently change seed data).
- POS tax rate: currently read once in `initState` (D136). Make it live-watched like payment methods, so a Settings change applies without restarting the sale.

### 7. Restore semantics — decide and document
Restore currently does not delete (records deleted after export do not come back); counters not restored; sale-payments subcollection not restored. Decide: accept as documented behaviour (record the decision) or extend restore to cover counters + sale-payments. Either way the behaviour must be stated plainly in the backup screen and the tracker.

### 8. Phase 8 QA depth — continued
- Re-run the 47-route walk + 390px sweep after the new screens.
- Finance agreement second pass over the newly guarded finance writes.
- Offline-queue + role-gate coverage for every new flow added in Week 6.

## Out of scope (do not build)
- Franchise onboarding (Phase 2 scope — not yet).
- Firebase project / billing creation — Dazy-only step, never create it.
- Pushing to GitHub — the parent pushes committed files via browser upload.

## Standing rules (unchanged)
- Day-builder subagents, coordinator self-verifies every claim with its own re-runs (analyze + day tests + cumulative).
- Testing rule: each day tested alone, then ALL weeks together (cumulative/regression, Weeks 1–6).
- Quality: smooth/clean from day one, test everything, no dirty UI, everything easy to access. Users internal only (staff/owner) — NO customer app, ever.
- Commit per day/milestone with verification numbers. Clean tree at week end. Never touch `presentation-video/`.
- Report to the parent ONLY when the whole week is complete or a Dazy-only blocker appears.
