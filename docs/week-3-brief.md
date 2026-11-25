# Week 3 Brief — PharmaDesk (draft, starts only after Week 2 CI is green)

**Standing orders (Dazy, 25 Nov 2026):** auto-continue Weeks 3/4/5+; each week tested alone first, then ALL completed weeks together (cumulative/regression); quality rules (smooth/clean from day one, test everything, no dirty UI, easy access for admin + staff); users internal only (staff/owner, NO customer app); desktop/web is the main offer, mobile APK is a $300 add-on; Firebase Blaze backend (project + billing is a Dazy-only step — still blocked, do NOT create it); push ONLY committed files (parent pushes via browser upload — coordinator never pushes); report only when the whole week is complete or a Dazy-only blocker appears.

**Week 2 verified (25 Nov ~22:30 PKT):** analyze clean, 203/203 Week 2 tests, 394/394 cumulative, web build pass, prescription PNGs in build/web. All 110 Week 2 files pushed to public repo Sharjeel-580/pharmadesk; CI "Build APK" run watched to green before Week 3 starts.

## Week 3 scope — finish SRS Phase 7 (Complete Desktop & Android Applications), start Phase 8 QA

1. **Week 2 follow-ups (do first):**
   - Firestore implementations for the six Day 5 repos (Staff, Attendance, Shift, Expense, FinancialTransaction, SupplierPayment) — schema contracts already in `firestore_schema.dart` §3.6/§3.7.
   - `goodsReceipts` document + receiving routed through the production data layer (D95).
   - Salary screen (gates on the existing `hrSalary` capability).
   - Reports on pre-aggregated counters (daily rollup Function output) + pagination.
   - Sync-status UI (pending counts, last-sync time) on offline-capable screens.
2. **Phase 7 completion:**
   - Desktop (Windows): verify `main_desktop.dart` + desktop screens build and run correctly per SRS (D-01–D-35); fix Windows-only issues (sqflite_common_ffi, firebase_messaging has no Windows implementation — Firestore live reads instead).
   - Android: APK via CI is the path (sandbox Gradle blocked, D52); keep the CI workflow green on every push; verify the release APK installs and runs (demo login, POS flow smoke test on the APK if a device/emulator is available, otherwise CI build + web parity).
   - Any remaining SRS Phase 7 production screens/flows not covered in Week 2 (check SRS §9 production scope vs. what exists; close gaps or list them as documented follow-ups with reasons).
3. **Phase 8 start:** full QA pass — per-week + cumulative testing rule applies; update `docs/week-3-tracker.md` daily (same format as Week 2 tracker) and `docs/technical-decisions.md` with new decisions (continue D-numbering from D98).

## Verification (same bar as Week 2)
- `flutter analyze` — zero issues; full suite green (Week 3 alone, then cumulative Week 1+2+3); fresh `flutter build web --release` passes; prescription PNGs still bundled.
- Commit per day/milestone with verification numbers in the message. Clean tree at week end. No push (parent pushes). No Firebase project creation. No Hadi contact. No invented requirements.
