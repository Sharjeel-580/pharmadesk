# Week 5 Tracker — PharmaDesk (production hardening + franchise-ready foundations)

**Baseline:** Week 4 verified — analyze clean, Week 4 alone 162/162, cumulative 709/709, web build pass. HEAD `242a3b7`. All 35 desktop screens D-01–D-35 resolve. Decisions continue from D146 in `docs/technical-decisions.md`.

**Scope (brief `docs/week-5-brief.md`):** (1) data-layer completion — adjustment-queue Firestore persistence, supplier payments through the layer, Firestore branch repository + FR-HO-08 deactivation enforcement, restore into live repos (upsert-by-id); (2) feature completion — full medicine master edit form, per-branch rack/shelf override, quarantine return/disposal approval, POS wiring for org Settings config, closing corrections (FR-FIN-06) + cash reconciliation; (3) franchise foundations — FR-HO-07 commission/royalty tracking, schema + head-office view only; (4) Phase 8 QA depth — route walk + 390px sweep re-run, offline-queue + role-gate coverage for new flows, finance hub second QA pass.

**Standing rules:** each day tested alone first, then cumulative (Weeks 1+2+3+4+5); quality rules apply; users internal only; Blaze design, NO Firebase project creation; commit per day with verification numbers; NEVER push; report only when the whole week is complete or a Dazy-only blocker appears.

## Day 23 — Data layer, part 1: adjustment-queue persistence + supplier payments through the layer
- **Status:** done (26 Nov 2026)
- **Scope:** Firestore persistence for the adjustment approval queue (collection `branches/{branchId}/stockAdjustments` + rules + repository (mock + Firestore) + layer file/load/update + notifier re-read on start; semantics preserved: approver ≠ requester, re-validation at approval, request id as idempotency key); supplier payments moved through the production data layer (`recordSupplierPayment`: one layer method, idempotency registry, one batched-write sync payload per payment — same three records, same ledger/aging numbers as the old repo-direct path). Details in `docs/day-23-progress.md` (D146, D147).
- **Verification:** `flutter analyze` clean; Day 23 tests **18/18** (`test/week5_day01_test.dart`); cumulative full suite **727/727** (709 + 18); fresh `flutter build web --release` pass (46,624,146 bytes); prescription PNGs bundled (114,613 + 110,613 bytes, 8 manifest mentions)

## Day 24 — Data layer, part 2: branch repository + FR-HO-08 + restore into live repos
- **Status:** done (26 Nov 2026)
- **Scope:** Firestore branch repository (interface + mock + Firestore impl, mapper, layer `loadBranches`/`getBranch`/`saveBranch`, directory notifier persists through the layer — D148, D131 closed); FR-HO-08 deactivation enforcement in the production data layer (sale / order / receive-goods / receive-stock / adjust / stock-count / quarantine / transfer create+dispatch+receive refused on a deactivated branch, duplicate retry still returns the original, unknown branch ids not refused — D149); restore upserts by id into the live repos (upsert methods on 9 repo interfaces + 2 ledger upserts, async `importBackup`, report counts measured against live repos, `branches` section added to exports, sink still records every validated doc — D150, D133 closed). Details in `docs/day-24-progress.md` (D148, D149, D150).
- **Verification:** `flutter analyze` clean; Day 24 tests **31/31** (`test/week5_day02_test.dart`); cumulative full suite **758/758** (727 + 31); fresh `flutter build web --release` pass (46,661,326 bytes); prescription PNGs bundled (114,613 + 110,613 bytes)

## Day 25 — Feature completion, part 1: medicine master edit form + per-branch rack/shelf
- **Status:** done (26 Nov 2026)
- **Scope:** full medicine master edit form (name / prices in int paisa / barcode / category / location — replaces the location-only dialog, D138 closed); per-branch rack/shelf override on the `branches/{branchId}/inventory` doc (SRS §3.3; master location stays the default shelf, override wins when set, clear falls back). Details in `docs/day-25-progress.md` (D151, D152, D153).
- **Verification:** `flutter analyze` clean; Day 25 tests **24/24** (`test/week5_day03_test.dart`); cumulative full suite **782/782** (758 + 24); fresh `flutter build web --release` pass (46,674,326 bytes); prescription PNGs bundled (114,613 + 110,613 bytes, same sizes as Days 23/24); 0 RenderFlex overflows at 390px in the Day 3 widget tests

## Day 26 — Feature completion, part 2: quarantine return/disposal + POS Settings wiring + closing corrections
- **Status:** done (26 Nov 2026)
- **Scope:** quarantine return/disposal approval flow (FR-INV-07, D140 closed: return → status `returned` + qty 0, dispose → status `disposed` + qty kept as destroyed count, approver ≠ requester, audited, one sync payload); POS wiring for org Settings config (payment-method picker filtered by enabled set, discount caps enforced, receipt width/footer from settings — tax already wired, D134/D136 follow-up closed); closing corrections (FR-FIN-06: append-only reversing entries, original never rewritten, adjusted totals shown) + cash reconciliation (expected drawer vs counted, difference recorded). Details in `docs/day-26-progress.md` (D154, D155, D156, D157).
- **Verification:** `flutter analyze` clean; Day 26 tests **40/40** (`test/week5_day04_test.dart`); cumulative full suite **822/822** (782 + 40); fresh `flutter build web --release` pass (46,717,515 bytes); prescription PNGs bundled (114,613 + 110,613 bytes, same sizes as Days 23–25); 0 RenderFlex overflows at 390px in the Day 4 widget tests

## Day 27 — Franchise foundations + Phase 8 QA depth
- **Status:** done (26 Nov 2026)
- **Scope:** FR-HO-07 franchise commission/royalty tracking — schema + head-office view only, no onboarding flow (D158, D159: royalty/fee computation over branch sales in int paisa, same revenue base as the P&L; HO-only view at `/finance/franchise` gated on the existing `branches` capability at write level — Super Admin / Owner / HO Admin, Auditor excluded; finance-hub card + sidebar + More-sheet navigation); Phase 8 QA depth (D160: full 47-route walk, 390px sweep over the new/changed screens, offline-queue + role-gate coverage for the new flows, second QA pass over the finance hub numbers — cashbook vs P&L agreement, aging buckets vs supplier ledger). Details in `docs/day-27-progress.md` (D158, D159, D160).
- **Verification:** `flutter analyze` clean; Day 27 tests **50/50** (`test/week5_day05_test.dart`); cumulative full suite **872/872** (822 + 50); fresh `flutter build web --release` pass (46,725,756 bytes); prescription PNGs bundled (114,613 + 110,613 bytes, same sizes as Days 23–26); 0 RenderFlex overflows at 390px in the Day 5 widget tests

## QA pass (coordinator — my own re-runs, not the builders' claims)
- **Status:** done (26 Nov 2026) — **Verdict: Week 5 COMPLETE + VERIFIED. GREEN ✅**
- `flutter analyze` — **No issues found!** (my run, 14.5s)
- Week 5 alone (day01–day05) — **163/163 passed** (18 + 31 + 24 + 40 + 50)
- Full cumulative suite (Weeks 1+2+3+4+5) — **872/872 passed** (191 + 203 + 154 + 162 + 163)
- Fresh `flutter build web --release` — **✓ Built build/web** (my run, 175.6s)
- Prescription PNGs bundled (114,613 + 110,613 bytes in `build/web/assets/assets/images/prescriptions/`)
- Tree clean except known untracked (`docs/week-5-brief.md`, `pharmadesk-week2.apk`, `pharmadesk-week3.apk`, `pharmadesk-week4.apk`, `pharmadesk-windows-week3.zip`, `pharmadesk-windows-week4.zip`, `presentation-video/` — untouched). **Nothing pushed** — parent pushes committed files via browser upload.
- Per-day verification: each day's analyze / day-test / cumulative numbers reproduced exactly on my own re-runs (Day 23: 727, Day 24: 758, Day 25: 782, Day 26: 822, Day 27: 872). No coordinator corrections/amendments were needed — unlike Week 3, no day commit had to be amended.
- Commits (local master, on top of Week 4 HEAD `242a3b7`): Day 23 `acd6525`, Day 24 `a7e0ae5`, Day 25 `867d2a4`, Day 26 `70436fd`, Day 27 `f9e5949`. Push scope for the parent: `git log --name-only acd6525^..HEAD`, unique.
- Decisions recorded: D146–D160.

## Follow-ups (not in Week 5 build)
- **Super Admin gate note (flag, not a defect — Day 27):** Super Admin passes the franchise view because the matrix grants it `allowed` on `branches`; excluding it would need a role check outside the matrix. The brief said "Owner / HO Admin only" — if Dazy wants literally that, it is a follow-up decision.
- **Finance writes still not FR-HO-08-guarded (D149 boundary, carried):** `recordExpense` / `recordIncome` / `recordSupplierPayment` / closings / corrections / reconciliations are not deactivation-guarded — only the 10 stock/sale write paths are.
- **Quarantine outcome queue is session-only (D141 posture):** the outcome itself IS persisted on the batch row; queue persistence is a follow-up.
- **POS tax rate read once in `initState` (D136):** not live-updated while POS is open; payment methods are live-watched.
- **Notifier-held idempotency keys for payments (Day 23):** the layer mints a key per `recordPayment` call, so a UI double-tap could still create two payments; the D115 dialog-held-key pattern is the fix, for cashbook + supplier-payment dialogs together.
- **Restore does not delete (Day 24):** records deleted after export do not come back; counters are not restored; sale payments subcollection is not restored; mock-export sale doc id differs from the idempotency key (cross-backend edge).
- **ActiveBranchNotifier.switchTo still reads demoBranches only (Day 24):** a branch added via the directory cannot become the active branch (provider-cycle risk; deliberate design decision needed).
- **Model gaps (Day 24):** `Supplier` has no `createdAt`; `Order` has no `orderNumber`/`idempotencyKey`; Branch mapper cannot validate §3 `code` (model has no `code`).
- **Barcode uniqueness unenforced (Day 25):** belongs in the repo, not the form, if the business wants it.
- **Expected drawer deliberately excludes cash supplier payments and sale-return cash refunds (Day 26, documented in `finance_logic.dart`).**
- **Franchise onboarding is Phase 2 scope (not built);** live Firestore verification still blocked on the Firebase project + billing (Dazy-only step, untouched).
