# Week 8 Brief — PharmaDesk (FINAL planned week)

**Status: DRAFT (not yet started).** Coordinator to spawn after Week 7 push + CI green.

## Where we are
- Week 7 COMPLETE + VERIFIED (coordinator-verified; parent independent verification in progress): analyze clean, Week 7 tests 130/130, cumulative **1138/1138**, web build pass.
- Week 7 closed: quarantine outcome queue persistence (D171), fake transport `runTransaction` + `runBatchedWrites` (D172), restore re-key by idempotencyKey (D173), Phase 8 QA depth with the corrected `FlutterError.onError` trap (D174), demo polish + restore counter advance (D175).
- Decisions continue from **D176**. Tracker: `docs/week-7-tracker.md` (read before starting); new tracker `docs/week-8-tracker.md`.
- **Parent verification of Week 7 (independent re-runs, 2026-11-26):** pending — see coordinator report. If the parent sends a CI-fix message, that takes priority over Week 8 work.

## Week 8 scope — Phase 8 completion + handover (LAST planned week)

### 1. SRS acceptance checklist — formal pass (D176)
Re-verify EVERY SRS §8.4 demo acceptance criterion on the final tree, one by one, with evidence (test name or manual check) recorded in the tracker. Then the §9 production-scope checklist (8 own branches, roles, offline, backup). Anything failing goes on the fix list and is fixed in Week 8; anything needing Hadi's input or a live Firebase project is recorded as a known caveat, never invented or silently passed.

### 2. Full screen walk — final (D177)
Re-walk ALL 35 desktop screens (D-01–D-35) and ALL 24 mobile screens (M-01–M-24) on the final tree: every screen resolves, every button does what its label says, no dead ends. 390px sweep with the corrected `FlutterError.onError` trap; every figure states its trap.

### 3. Fake-transport copies — sweep (D178)
Per-file fake-transport copies (non-canonical test doubles in week2_day04, week3_day01–03, week4_day02–03, week5_day01, etc.) still have the old apply-immediately transaction / non-atomic batch behaviour. Upgrade every copy that the production-layer tests rely on for atomicity; leave the rest as documented with the reason recorded. No test may be weakened to pass.

### 4. Handover docs (D179)
- Deployment guide: how the APK + Windows build + web admin reach Hadi's team (install steps, demo accounts, what is sample data, what needs the Firebase project).
- Staff/owner user manual: short, role-based (owner, branch manager, pharmacist, cashier, inventory manager) — what each role does day to day, in plain language.
- Demo guide refresh (`docs/demo-guide.md`): re-check every figure against the final tree (branch switching, demo logins, prescription dispatch guard, FEFO cart, auto purchase list).

### 5. Final QA sweep (D180)
- Cumulative suite green on the final tree; fresh web build pass; prescription PNGs bundled.
- Finance agreement final pass (cashbook vs P&L vs supplier ledger vs closings).
- Offline-queue + role-gate coverage for every flow added in Week 8.

## Out of scope (do not build)
- Franchise onboarding (Phase 2 scope — not yet).
- Super Admin franchise-view gate — STILL pending Dazy's decision; do NOT guess, do NOT build it; it is noted for the final report.
- Live-Firestore E2E — blocked on a live Firebase project (Dazy-only step); the fake-transport suite is the verification, and the caveat is stated plainly.
- Firebase project / billing creation — Dazy-only step, never create it.
- Pushing to GitHub — the parent pushes committed files via browser upload.

## After Week 8 (parent's job, not the coordinator's)
The parent does the final full testing (independent analyze + full cumulative suite + fresh web build + CI green + final APK/Windows download and verification) and delivers the FINAL report to Dazy. The coordinator's job ends when Week 8 is complete and verified — it does NOT write the final report.

## Standing rules (unchanged)
- Day-builder subagents, coordinator self-verifies every claim with its own re-runs (analyze + day tests + cumulative).
- Testing rule: each day tested alone, then ALL weeks together (cumulative/regression, Weeks 1–8).
- Quality: smooth/clean from day one, test everything, no dirty UI, everything easy to access. Users internal only (staff/owner) — NO customer app, ever.
- Commit per day/milestone with verification numbers. Clean tree at week end. Never touch `presentation-video/`.
- Report to the parent ONLY when the whole week is complete or a Dazy-only blocker appears.
