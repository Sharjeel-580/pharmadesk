# PharmaDesk — Demo Sprint Tracker (coordinator's log)

Order from Dazy (24 Nov 2026 ~00:29 PKT): build the functional interactive demo, work day and night until done. "Jha zarort meri bata dena" — only Dazy-clearable blockers go to him.

## Plan
- [x] Day 1 (23 Nov): foundation — rebrand, Kalora design, GoRouter, mock repos. Commit `3d5d93f`. analyze clean, tests 4/4, web build PASSED. APK env-blocked (D14/D15).
- [x] Day 2 (24 Nov): design-system components + app shell (desktop sidebar/top nav, mobile bottom nav, theme switching) — analyze clean, tests 17/17, web build PASSED. Commit `3fb8637` (verified).
- [x] Day 3 (24 Nov): splash/login/forgot-password/demo login + owner & staff dashboards (sample data, every card/action works) — analyze clean, tests 47/47, web build PASSED. Committed (see `git log`).
- [x] Day 4: orders (New → Confirmed → Processing → Ready → Dispatched → Delivered → Cancelled; manual phone/WhatsApp entry, NO WhatsApp API) — analyze clean, tests 84/84, web build PASSED. Commit `Day 4: orders` (see `git log`).
- [x] Day 5: medicine catalog + inventory (batches, mfg/expiry, buckets 30/60/90/expired, expired never sellable) — analyze clean, tests 116/116, web build PASSED (3,013,035 bytes). Commit `Day 5: catalog + inventory` (see `git log`).
- [x] Day 6: POS/billing (cart, FEFO batch selection via the Day 5 shared guard, discount, tax, cash/card/khata, receipt preview/print/share, sales history; money int minor units) + customers (directory, history, khata, outstanding, payments) — analyze clean, tests 158/158, web build PASSED (3,075,882 bytes). Commit `Day 6: POS + customers` (see `git log`).
- [x] Day 7: suppliers, purchases, prescription review (on-device photos only), basic reports, notifications, settings, branding, roles/permissions, feature config + full QA — analyze clean, tests 191/191 (33 new), web build PASSED (3,951,416 bytes). No placeholders remain; all 14 modules real. Commit `Day 7: suppliers + purchases + prescriptions + reports + settings + QA` (see `git log`).
- [x] Demo assembly per SRS §8: 2 fictional branches, 180 sample medicines, demo guide finalized + credentials, known-limitations doc, DEMO MODE indicator
- [x] APK cache pre-populate fix — tried ONCE, time-boxed: mirror built (664 modules, 463 MB, `~/.gradle/local-maven/`) but build stops on KGP 2.2.21 vs Gradle 9.3.1 `NoSuchMethodError` — NOT a download failure. No APK. Recorded as D52, commit `4d184a5`. Remaining fix: CI build on GitHub Actions once a repo is approved.
- [x] Final verification + report to parent

## Hard rules
- Backend: Firebase Spark permanently free. Blaze out of scope. No Cloud Storage / Functions. `firebase_storage` stays out of pubspec.
- NO Firebase project creation (no credentials, no google-services.json). Mock repos + sample data only.
- Local git only: commit at end of each day, never push, never create a remote.
- Never claim a target works until its build succeeds. APK env-blocked (D14/D15). Windows/iOS cannot be verified on this Linux VM.
- Every button must work — no fake buttons, no dead screens.

## Dazy-only blockers (collect, do not stop work)
- Firebase project creation (needs Dazy's Google account decision)
- GitHub repo name/visibility
- Hadi's requirements (medicines count, delivery areas, payment method, branch cities, logo/colours)

## Log
- 24 Nov 00:30 — Sprint started. Day 2 agent spawned.
- 24 Nov ~03:35 — SPRINT COMPLETE: Days 2–7 all verified (analyze clean, tests 191/191, web build PASSED). APK attempt tried once — blocked on KGP/Gradle version mismatch (D52); CI build is the remaining path. Demo is the web build; final report sent to parent.
- 24 Nov ~01:00 — Day 2 done: design-system components + app shell, 17/17 tests, web build PASSED. Day 3 (login + dashboards) is next.
- 24 Nov ~20:30 — Day 3 done: splash/login/forgot-password/demo login (5 roles, mock reset flow) + owner & branch dashboards on 499 seeded orders, DEMO MODE badge everywhere; analyze clean, tests 47/47, web build PASSED (2,729,264 bytes). Demo guide started (`docs/demo-guide.md`). Day 4 (orders) is next.
- 24 Nov ~20:45 — Day 4 done: orders module — queue (branch-scoped, status filters + search), detail (timeline, totals, rider, prescription link, advance/cancel/edit with guards + prescription dispatch guard), create/edit form (validation, int-paisa totals, expired batches un-addable); status vocabulary aligned per D10 (enum extended, legacy kept); analyze clean, tests 84/84, web build PASSED (2,890,063 bytes). Day 5 (medicines + inventory) is next.
- 24 Nov ~01:52 — Day 5 done: catalogue 14 → 180 medicines (16 categories, barcodes, int-paisa prices), multi-batch inventory (1–3 batches/medicine/branch, mfg/expiry/cost), expiry buckets + FEFO, shared expired-never-sellable guard (order form rewired to it), receive/adjust/count operations, alerts tab + dashboard alert deep-links; analyze clean, tests 116/116, web build PASSED (3,013,035 bytes). Correction found: seeded orders are 491, not the 499 the Day 3/4 docs state (D31). Day 6 (POS + customers) is next.
- 24 Nov ~02:30 — Day 6 done: POS/billing (search by name/brand/barcode, FEFO batch pick via the Day 5 shared guard, cart with per-line discount, bill discount, tax, cash/card/khata, change, receipt preview with Share-copy + web print + sales history, idempotency key) + customers (directory with khata outstanding, add with validation, detail with purchase history + credit ledger, payments/credit/adjustments, credit limits); POS sales feed the dashboard KPIs immediately; analyze clean, tests 158/158, web build PASSED (3,075,882 bytes). Day 2/3 placeholder tests updated to the real POS screen. Day 7 (suppliers, purchases, prescriptions, reports, notifications, settings + full QA) is next.
- 24 Nov ~21:50 — Day 7 DONE (final sprint day): suppliers (ledger-pattern payable, 4 suppliers seeded) + purchases (6 POs, batch-wise receiving into inventory + supplier ledger) + prescriptions (20 seeded, review + order unblock, bundled SAMPLE photos) + reports (CSV per section + real PDF via `pdf` package) + notifications (derived alerts, bell with unread Badge) + settings (branding with Fazal Din preset, 10×21 roles matrix read-only, feature config with FeatureGate) + full QA; `ModulePlaceholderScreen` deleted — no placeholders remain, all 14 modules real; analyze clean, tests 191/191 (33 new Day 7), web build PASSED (3,951,416 bytes). Docs: `docs/day-07-progress.md`, `docs/known-limitations.md`, `docs/demo-guide.md` finalized, D41–D51. Week 1 sprint complete — demo assembly done. Remaining: APK (env-blocked, needs CI), Firebase project + GitHub repo + Hadi requirements (all Dazy-only blockers).
