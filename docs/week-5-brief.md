# Week 5 Brief — PharmaDesk (draft, starts only after Week 4 CI is green)

**Standing orders (Dazy, 25 Nov 2026):** auto-continue Weeks 3/4/5+; each week tested alone first, then ALL completed weeks together (cumulative/regression); quality rules (smooth/clean from day one, test everything, no dirty UI, easy access for admin + staff); users internal only (staff/owner, NO customer app); desktop/web is the main offer, mobile APK is a $300 add-on; Firebase Blaze backend (project + billing is a Dazy-only step — still blocked, do NOT create it); push ONLY committed files (parent pushes via browser upload — coordinator never pushes); report only when the whole week is complete or a Dazy-only blocker appears.

**Week 4 verified (26 Nov ~06:10 PKT, parent's own re-run):** analyze clean, Week 4 alone 162/162, cumulative 709/709, fresh web build pass, prescription PNGs bundled. All 35 desktop screens D-01–D-35 now resolve. All Week 4 files pushed to public repo Sharjeel-580/pharmadesk; CI watched (APK + Windows jobs). Week 4 closed: D116 responsive top bar (390px), stock transfer + riders, finance hub (cashbook/aging/P&L), system hub (branch management/audit log/backup-restore/settings), partials + Phase 8 QA (split payment, location/stock history, quarantine, approval queue, offline queue, role gates).

## Week 5 scope — production hardening + franchise-ready foundations (SRS Phase 8 depth)

1. **Data-layer completion (Week 4 follow-ups, do first):**
   - Adjustment-queue Firestore persistence (queue is session/in-memory until Firebase exists — persist via the production layer).
   - Supplier payments through the production data layer.
   - Firestore branch repository + FR-HO-08 deactivation enforcement on transactions (deactivated branch cannot transact).
   - Restore into live repos (needs upsert-by-id — restore must overwrite live repo data, currently does not).
2. **Feature completion:**
   - Full medicine master edit form.
   - Per-branch rack/shelf override (D138 follow-up).
   - Quarantine return/disposal approval flow.
   - POS wiring for org Settings config: payment-method picker, discount caps, receipt width/footer (tax already wired).
   - Closing corrections (FR-FIN-06) + cash reconciliation.
3. **Franchise foundations (Phase 2 prep, P3):** franchise commission/royalty tracking (FR-HO-07) — schema + head-office view only; no franchise onboarding flow yet (that is Phase 2 business scope, not V1).
4. **Phase 8 QA depth:** re-run the full route walk + 390px sweep after the new screens; offline-queue + role-gate tests cover the new flows; a second QA pass over the finance hub numbers (cashbook vs P&L agreement, aging buckets vs supplier ledger).

## Verification (same bar as Weeks 2–4)
- `flutter analyze` — zero issues; full suite green (Week 5 alone, then cumulative Weeks 1+2+3+4+5); fresh `flutter build web --release` passes; prescription PNGs still bundled.
- Commit per day/milestone with verification numbers in the message. Clean tree at week end. No push (parent pushes). No Firebase project creation. No Hadi contact. No invented requirements.
- Keep `docs/week-5-tracker.md` updated daily (same format as the Week 4 tracker) and `docs/technical-decisions.md` with new decisions (continue D-numbering from D146).
