# Week 4 Tracker — PharmaDesk production build

**Started:** 26 Nov 2026. **Plan:** Week 4 finishes SRS Phase 7
(Complete Desktop & Android Applications — the 7 missing + 6 partial
desktop screens from the Week 3 Day 4 audit) and deepens Phase 8 QA
(390px phone-width sweep, offline-queue behaviour, role-gate tests).
D116 (top-bar overflow at phone widths) goes FIRST. Each day ends
with its own tests, then the cumulative suite (Week 1 + Week 2 +
Week 3 + Week 4) runs as regression — per Dazy's testing rule
(25 Nov 2026).

**Backend (unchanged):** Firebase **Blaze** (pay-as-you-go).
Project + billing creation is a Dazy-only step (his Google account +
card) — still blocked. No Firebase project is created by this work;
Firestore/Storage code stays behind the mock default until then.

**Week 3 closed (verified by the parent's own re-runs):** analyze
clean, Week 3 alone 154/154, cumulative 548/548, fresh web build
pass, prescription PNGs bundled. All 59 Week 3 files pushed to
Sharjeel-580/pharmadesk (113 commits). CI run 45695219727 SUCCESS —
both jobs green ("Build release APK" 9m 11s + "Build Windows desktop
app" 5m 28s, first verified Windows binary). Week 3 APK verified
locally (68,701,450 bytes, com.pharmadesk.app 1.0.0).

## Day 1 — Responsive top bar (D116) ✅ DONE (26 Nov 2026)

**Scope:** D116 first (Week 4 brief §1) — the shared shell top bar
overflowed by 236px at a 390px viewport (Week 3 Day 5 QA finding);
every shell screen was affected. Test-first responsive pass (D117).

**What shipped:**
- Test-first: `test/week4_day01_test.dart` (6 tests) failed pre-fix
  1/6 (desktop only) with exactly the D116 symptom — top-bar Row
  overflowed by 236px, DEMO MODE badge at Rect(343.0, 453.3).
- `lib/app/shell/app_shell.dart` only: below 640px (the full bar
  measures ~615px, so 640 covers the mobile range) the app-name text
  hides (brand-mark tile stays), the branch switcher drops its store
  icon and its name cap follows the space left via LayoutBuilder
  (popup menu still shows both full names), the three icon buttons
  compact to 40px. The DEMO MODE badge is untouched — full size on
  every screen (SRS §8.2). Desktop (≥900px) unchanged, pinned by a
  1280px test.
- Two framework traps found by probes and fixed in the pass:
  `PopupMenuButton.constraints` sizes the popup menu, not the button
  (40px constraints broke the menu ListTiles); `IconButton` enforces
  a 48px tap target unless `tapTargetSize` is shrinkWrap (the bell
  stayed 48px on `constraints` alone). Both shrink via `style`.
- One settled-layout defect caught by the probes: a 32px floor on
  the switcher cap overflowed the pill Row by 14px (chrome is 36px:
  padding 16 + border 2 + chevron 18) — floor removed, cap is
  `(share − 36).clamp(0, 80)`.

**Verification:** `flutter analyze` clean; Day 1 tests **6/6**;
cumulative **554/554** (548 + 6, no earlier test touched); fresh
`flutter build web --release` pass (46,400,839 bytes, 186.5s);
prescription PNGs bundled at 114,613 + 110,613 bytes, 8
"prescription" mentions in `AssetManifest.bin`, both paths present.

**390px body findings (Day 5 sweep, NOT fixed here):** `/dashboard`
and `/medicines` clean; `/orders` 12px (sync-status chip Row,
`sync_status_widget.dart:178`); `/billing` 2 exceptions incl. a
133px overflow in the shared button Row (`buttons.dart:72`);
`/inventory` 511 exceptions — every batch row overflows
(`inventory_screen.dart:462` / `:368`, 24–56px). Details in
`docs/day-18-progress.md` §5.

**Environment note:** mid-day test runs hung, then failed at load
with "No space left on device" — `/tmp` (512 MB tmpfs) was full of
stale `flutter_tools.*` dirs (~449 MB) + an old `pharmadesk-apk3`
scratch dir. Cleaned; runs normal since. If a run hangs at loading,
check `df -h /tmp` first.

## Day 2 — Stock transfer (D-16) + Riders & delivery (D-21) ✅ DONE (26 Nov 2026)

**Scope:** the two missing operations screens from the Week 3 Day 4
audit — D-16 Stock Transfer and D-21 Riders & Delivery.

**What shipped:**
- Stock transfers, full lifecycle (D118): `StockTransfer` model
  (Requested → Approved → Dispatched → Received + Rejected /
  Cancelled), repository interface + mock + Firestore impl in the
  bundle, layer methods `createTransfer` / approve / reject /
  cancel / `dispatchTransfer` / `receiveTransfer` — dispatch
  reserves FEFO from live source stock (`transfer_out` ledger +
  audit, allocations recorded on the transfer) and receive creates
  destination batches (`transfer_in`); approval separation (SRS
  §5.2 — requester cannot approve); per-step idempotency
  registries; one sync payload per step. `stockTransfer`
  capability added to the §5.1 matrix (Owner / HO Admin /
  Regional Mgr allowed, Branch Mgr + Inventory Mgr own, Auditor
  read-only) and the transfer routes are gated on it.
- Screens: transfer list (status + branch filters, paged 10,
  SyncStatusChip), new-transfer form (source sellable on-hand per
  medicine, dialog-held key), detail (lines, FEFO allocations,
  actor trail, status-gated actions). 3 seeded demo transfers
  (Requested / Dispatched / Received), labelled demo/sample —
  read-only sample records (D122).
- Riders & delivery (D119/D121): riders stay a separate model
  (not Staff rows) with a home `branchId` added; ONE assignment
  write path (`layer.assignRider` — order `riderId` + both rider
  rows together, with inactive / cross-branch / busy / pickup /
  delivered guards); rider list (availability from `active` +
  `currentOrderId`) + detail (history + assign-an-order) +
  "Assign Rider" button on Order Detail reusing the same path.
  No rider capability invented — the SRS matrix has no rider row
  (D123).
- Routes `/inventory/transfers`, `/inventory/transfers/new`,
  `/inventory/transfers/:id`, `/riders`, `/riders/:id`; sidebar +
  mobile More-sheet entries under Inventory / Orders.
- Older tests updated for the new reality: Day 7 matrix test
  23 → 24 capabilities; Week 3 Day 4 "seven missing" test is now
  "the remaining missing" (D-16 + D-21 closed).

**Verification:** `flutter analyze` clean; Day 2 tests **27/27**;
cumulative **581/581** (554 + 27, no earlier test touched except
the two intentional updates above); fresh
`flutter build web --release` pass (186.7s, 46,472,274 bytes);
prescription PNGs bundled at 114,613 + 110,613 bytes, 8
"prescription" mentions in `AssetManifest.bin`, both paths present.

**Follow-ups:** seeded-order rider/branch mismatch (pre-existing
— generator assigns riders 1–3 regardless of branch; new
assignments enforce the branch); no rider add/edit screen (not in
the SRS scope); dispatch is all-or-nothing (no partial dispatch).
Details in `docs/day-19-progress.md` §Follow-ups.

## Day 3 — Finance hub: cashbook (D-24) + payables/receivables aging (D-25) + P&L / statements (D-26) ✅ DONE (26 Nov 2026)

**Scope:** the three missing/partial finance screens from the Week 3 Day 4 audit — D-24 Cashbook, D-25 Payables/Receivables aging, D-26 dedicated P&L / Statements screen.

**What shipped:**
- Cashbook (D124–D126, D129): income/expense entries for the active branch (unified newest-first, date filter, money-in/out/net summary, `PagedList` at 10); add-entry dialog (income/expense, date, fixed category, whole rupees, note for expenses); daily closing as a snapshot record (`DailyClosing` model + `dailyClosings` collection, D101 pattern) with the opening carried from the previous closing and a "changed since closing" flag instead of rewrites. New `recordIncome` on the financial-transactions notifier (fixed income categories, D125 — sales income is not here, it lives in the P&L).
- Aging (D127): supplier payables + customer receivables from the ONE D92 computation (FIFO, Current / 31–60 / 61–90 / 90+), per-party rows navigating to supplier/customer detail; unpaid POs shown separately as committed spend (never in the buckets — goods not received are not owed). Seeded totals: payables Rs 194,250.00, receivables Rs 32,000.00.
- P&L / Statements (D128): dedicated screen (7/30/90-day window, branch picker, CSV export, per-branch statement cards) that reads the exact `advancedReportDataProvider` the Reports hub reads — no second P&L computation; agreement pinned by test.
- Hub + navigation: `/finance` hub (three cards, each checking its §5.1 capability in the active branch), routes gated on the existing matrix rows (cashbook → `financeEntry`, aging + statements → `financeReports`); Finance is the 16th module (sidebar Insights, More sheet, feature toggle).
- Behaviour fix found by the work (D125): `addTransaction` (mock + Firestore) used to overwrite `createdAt` with now — a caller-supplied business date is now kept, so backdated income lands on its own day.
- Older tests updated for the new reality: day_02 sidebar 15 → 16 modules; day_07 route walk 15 → 16 + feature-toggle count 11 → 12; week3_day04 missing-screens test drops `/finance` (remaining missing: D-28 / D-33 / D-35).

**Verification:** `flutter analyze` clean; Day 3 tests **34/34**; cumulative **615/615** (581 + 34, no earlier test touched except the three intentional updates above); fresh `flutter build web --release` pass (183.3s, 46,516,062 bytes); prescription PNGs bundled at 114,613 + 110,613 bytes, 8 "prescription" mentions in `AssetManifest.bin`, both paths present.

**Follow-ups:** layer sync payload for cashbook writes (D129 — then add the `SyncStatusChip` to the cashbook screen); income notes need a `note` field on the transaction contract (D125); closing corrections (FR-FIN-06 reversing-entry flow) not built; cash reconciliation (expected-vs-actual drawer count) not built. Details in `docs/day-20-progress.md` §Follow-ups.

## Day 4 — System hub: branch management (D-28) + audit log (D-33) + backup & restore (D-35) + settings completion (D-34) ✅ DONE (26 Nov 2026)

**Scope:** the remaining missing screens from the Week 3 Day 4 audit plus the last partial — D-28 Branch Management, D-33 Audit Log, D-35 Backup & Restore, D-34 Settings completion. With this day all 35 desktop screens (D-01–D-35) resolve — the audit's missing list is empty.

**What shipped:**
- Branch Management (D130–D131): list (`/branches`, paged at 10) + detail (`/branches/:id`) with address, contact, manager, status, delivery areas and the franchise settings section (type, fee / royalty rates — "Not set" when never configured, never 0%). Branch model gains the SRS §3.1 fields (`type`, `managerId`, `franchiseFeeRateBps`, `royaltyRateBps`, all nullable). No `BranchRepository` invented — the directory is an in-memory notifier seeded from the demo branches; last active branch protected; deactivation is the flag (FR-HO-08 enforcement is a follow-up).
- Audit Log (D132): filterable viewer over the writer's own store (`ProductionDataLayer.auditEntries`) — branch, actor, action family, date range, paged at 10, row detail (before → after). Branch scope enforced in the filter (Branch Mgr own / Auditor all / Cashier none); in-memory session scope stated on the screen.
- Backup & Restore (D133): live status preview (section counts from a fresh export) + last manual backup this session; manual backup triggers the existing exporter (web download); restore is admin-only — paste JSON → validate → explicit confirmation (states it replaces the current restored data) → import into the restore sink with the report shown. Stated limitation: restore does NOT overwrite live repo data yet (no upsert-by-id); scheduled Cloud Function backups "not configured" (no Firebase project).
- Settings completion (D134, D136): two new tabs — Organization (tax config, payment methods, receipt format, discount limits; every default is today's behaviour: tax 0%, POS methods on, 80mm, no caps — no rate invented) and Sync (live status from the layer, "Never synced" when nothing synced). POS tax rate now reads Organization Settings (default 0%, behaviour unchanged).
- Routes + navigation (D135): `/branches`, `/branches/:id`, `/audit-log`, `/backup` — Settings sub-screens (sidebar + More sheet), capability-gated on the existing matrix rows (`branches` / `auditLog` / `sysSettings`); FeatureGate now gates non-module routes too. Module count stays 16, feature toggles stay 12.
- Older tests updated for the new reality: week3_day04 "remaining missing" test deleted (all 35 resolve — the four new routes join the `present` list); day_07 route walk gains the 4 routes and the feature-toggle test scrolls the six-tab bar into view before tapping 'Features'.

**Verification:** `flutter analyze` clean; Day 4 tests **40/40**; cumulative **654/654** (615 + 40 new − 1 removed week3_day04 missing-screens test, no earlier test touched except the two intentional updates above); fresh `flutter build web --release` pass (182.0s, 46,573,566 bytes); prescription PNGs bundled at 114,613 + 110,613 bytes, 8 "prescription" mentions in `AssetManifest.bin`, both paths present.

**Follow-ups:** Firestore branch repository + FR-HO-08 deactivation enforcement; restore into live repos (needs upsert-by-id); POS wiring for payment-method picker + discount caps + receipt width/footer; scheduled Cloud Function backups (needs Firebase project); franchise commission/royalty tracking (FR-HO-07, P3). Details in `docs/day-21-progress.md` §Follow-ups.

## Day 5 — Partials + Phase 8 QA depth: split payment (D-04) + medicine location & stock history (D-10) + quarantine action (D-11) + adjustment approval queue (D-14) + offline-queue behaviour + role-gate tests + 390px sweep + final QA pass ✅ DONE (26 Nov 2026)

**Scope:** the last partials from the Week 3 Day 4 audit plus Phase 8 QA depth, closing Week 4. Everything in the brief fit — including D129, which was "if it fits".

**What shipped:**
- Split payment (D137): `Sale.payments` (int paisa legs, legacy `paymentMethod` kept as the largest leg), split validation (sum == total, live remaining on the POS), exact cash in split mode, `payments` subcollection in the sale sync payload, split-aware receipt + history, khata entry for the credit leg only. Single-method flow unchanged.
- Medicine location + stock history (D138, D139): `location` added to the Medicine model + mappers + repo (master field = default shelf; per-branch rack/shelf is a follow-up); location-only edit dialog gated on `medicineCrud` write; stock-history section from the session ledger, newest first, paged at 10, session-only stated on screen.
- Quarantine (D140): layer `quarantineBatch` / `unquarantineBatch` (status + audit + sync, same-key retry dedupes), repo `updateBatchStatus`, buttons on both batch rows gated on `stockReceive` write, distinct "Quarantined" badge. The D68 guard already excluded quarantined batches — pinned by test, not re-implemented.
- Adjustment approval queue (D141): the Adjust dialog is request-only now (direct adjust stays as the approval-apply + system path); session-only queue with request → approve / reject, approver ≠ requester (§5.2.4), route `/inventory/adjustments` gated on `stockAdjustReq`.
- 390px sweep (D142): /orders 12px, /billing 133px, /inventory 24–56px, plus the detail badges Row 162px — all fixed structurally; sweep tests over 5 routes print zero overflows.
- Offline-queue behaviour (D143): enqueue-while-offline → held → flush on reconnect, nothing lost, no double-send; same-key dedupe; chip pending → synced.
- Role gates (D144): one test per SRS role walks 16 routes; expectations computed from the matrix itself.
- Cashbook layer writes (D145, closes D129): `recordExpense` / `recordIncome` / `recordDailyClosing` in the layer (idempotency registries, one sync payload each); notifiers route through the layer; cashbook screen shows the `SyncStatusChip`.
- Fixes found by the full suite: the receipt cash-rows gate (real D137 bug — gated on the legs-derived `cashMinor`, now on `cashReceivedMinor`), the old day_05 adjust test updated to the request flow, and fake-repo stubs for the new `updateBatchStatus` in four old test files.

**Verification:** `flutter analyze` clean; Day 5 tests **55/55** (`test/week4_day05_test.dart` — split 13, D-10 6, D-11 5, D-14 6, offline 4, role gates 11, D129 5, sweep 5); cumulative **709/709** (654 + 55 new, no earlier test touched except the two intentional updates above); fresh `flutter build web --release` pass (182.5s compile, 46,614,266 bytes); prescription PNGs bundled at 114,613 + 110,613 bytes, 8 "prescription" mentions in `AssetManifest.bin`, both paths present.

**Follow-ups:** per-branch rack/shelf override; full medicine master edit form; quarantine return/disposal approval; adjustment-queue Firestore persistence; supplier payments through the layer; POS wiring for the Settings config (payment-method picker, discount caps, receipt width/footer); branch repository + FR-HO-08 enforcement; restore into live repos; franchise commission/royalty tracking. Details in `docs/day-22-progress.md` §Follow-ups.

## Week 4 QA pass ✅ GREEN (26 Nov 2026)

Testing rule followed: Week 4 tested alone first (Day 1–5 files), then cumulative with Week 1 + Week 2 + Week 3.

- [x] `flutter analyze` — **No issues found!**
- [x] Week 4 alone (`test/week4_day01_test.dart` … `test/week4_day05_test.dart`) — **162/162 passed** (6 + 27 + 34 + 40 + 55)
- [x] Cumulative full suite (Week 1 + Week 2 + Week 3 + Week 4) — **709/709 passed** (191 Week 1 + 203 Week 2 + 154 Week 3 + 162 Week 4 − 1 removed week3_day04 missing-screens test)
- [x] Fresh `flutter build web --release` — **✓ Built build/web** (182.5s compile, 46,614,266 bytes)
- [x] Prescription PNGs (D61) — both in `build/web/assets/assets/images/prescriptions/` (114,613 + 110,613 bytes) and in the decoded manifest (8 "prescription" mentions, both sample paths present); widget test proves the prescription detail screen renders the `Image` wired to the sample asset path. No live-browser visual check (subagents cannot run the live browser).
- [x] **Verdict: Week 4 COMPLETE + VERIFIED.** All 35 desktop screens (D-01–D-35) resolve; the Day 1 390px findings are fixed with sweep tests; offline-queue and role-gate behaviour are pinned by tests; no dead buttons / placeholders introduced in Week 4 (route-walk tests cover every route in the router). Follow-ups are listed below, not hidden.

## Follow-ups (not in Week 4 build)

- **Per-branch rack/shelf override** (D138, Week 5): the master `location` is the default shelf; the SRS §3.3 per-branch `inventory` rack / shelf fields are not modelled yet.
- **Full medicine master edit form** (D138): the dialog edits location only; name / prices / barcode / category still have no edit UI.
- **Quarantine return / disposal approval** (D140, FR-INV-07): quarantining only parks the batch; the supplier-return or disposal step with its approval is not built.
- **Adjustment queue persistence** (D141): the queue is session-only; Firestore persistence (collection + rules + notifier re-read) is a follow-up.
- **Supplier payments through the layer** (D145): three records across two repos, still repo-direct in their notifier.
- **POS wiring for the Settings config** (D134/D136 follow-up): payment-method picker, discount caps, receipt width/footer are config-only until the POS reads them.
- **Branch repository + FR-HO-08 deactivation enforcement; restore into live repos (needs upsert-by-id); franchise commission/royalty tracking (FR-HO-07, P3)** (carried from Day 4).
- **Firebase project + billing (Blaze)** — Dazy-only, still blocked; no cloud sync until then.

## Blockers (Dazy-only, unchanged)

- Firebase project + billing (Blaze) creation — no cloud sync until then.
- Hadi's requirements (medicines count, delivery areas, payment method, branch cities, logo + brand colours).
- APK build remains environment-blocked in this sandbox (D52); CI is the path.
