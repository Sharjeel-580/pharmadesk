# Week 4 Brief — PharmaDesk (draft, starts only after Week 3 CI is green)

**Standing orders (Dazy, 25 Nov 2026):** auto-continue Weeks 3/4/5+; each week tested alone first, then ALL completed weeks together (cumulative/regression); quality rules (smooth/clean from day one, test everything, no dirty UI, easy access for admin + staff); users internal only (staff/owner, NO customer app); desktop/web is the main offer, mobile APK is a $300 add-on; Firebase Blaze backend (project + billing is a Dazy-only step — still blocked, do NOT create it); push ONLY committed files (parent pushes via browser upload — coordinator never pushes); report only when the whole week is complete or a Dazy-only blocker appears.

**Week 3 verified (26 Nov ~01:05 PKT, parent's own re-run):** analyze clean, Week 3 alone 154/154, cumulative 548/548, fresh web build pass, prescription PNGs bundled. All Week 3 files pushed to public repo Sharjeel-580/pharmadesk; CI watched (incl. first `build-windows` run). Week 3 closed: Firestore impls for the six Day 5 repos, goodsReceipts + production receiving (D95), salary screen, pre-aggregated counters + pagination, sync-status UI, Windows desktop verification, Phase 8 QA start.

## Week 4 scope — finish SRS Phase 7 desktop screens + Phase 8 QA depth

1. **D116 FIRST (new QA finding, Week 3):** shared shell top bar overflows by 236px at 390px phone width (every shell screen; all mobile tests ran at 800px). Responsive top-bar pass — must keep the DEMO MODE badge visible (SRS §8.2). Add a 390px-width widget test that fails before the fix and passes after.
2. **Missing desktop screens (7, from Week 3 Day 4 audit):** D-16 stock transfer, D-21 riders, D-24 cashbook, D-25 payables/receivables, D-28 branch management, D-33 audit log, D-35 backup/restore. Build them to the SRS spec (production data layer where it exists, mock default otherwise). None half-built — finish each or document why not.
3. **Partial desktop screens (6):** D-04 split payment, D-10 location/stock history, D-11 quarantine action, D-14 adjustment approval queue, D-26 P&L screen, D-34 settings. Complete each to spec.
4. **Phase 8 QA depth:** route walk already covers every route (D114–D116); extend QA to (a) a real-phone-width (390px) sweep of the shell screens, (b) offline-queue behaviour (enqueue while offline, flush on reconnect — mock transport), (c) role-gated screens (each role sees only its capabilities — PermissionService + FeatureGate checks in tests).
5. **CI:** the `build-windows` job added in Week 3 Day 4 — keep it green; if the first Windows run failed on push, fix the workflow/files it flags (do NOT fight Windows builds in the sandbox, D11).

## Verification (same bar as Weeks 2–3)
- `flutter analyze` — zero issues; full suite green (Week 4 alone, then cumulative Week 1+2+3+4); fresh `flutter build web --release` passes; prescription PNGs still bundled.
- Commit per day/milestone with verification numbers in the message. Clean tree at week end. No push (parent pushes). No Firebase project creation. No Hadi contact. No invented requirements.
- Keep `docs/week-4-tracker.md` updated daily (same format as the Week 3 tracker) and `docs/technical-decisions.md` with new decisions (continue D-numbering from D117).
