# Week 2 Tracker — PharmaDesk production build

**Started:** 25 Nov 2026. **Plan:** Week 2 builds the production
system on the Week 1 demo (SRS Phase 6 adapted). Each day ends with
its own tests, then the cumulative suite (all complete weeks together)
runs as regression — per Dazy's testing rule (25 Nov 2026).

**Backend (revised 25 Nov 2026, D62):** Firebase **Blaze**
(pay-as-you-go) — supersedes the 23 Nov permanent-free Spark decision
(D2). Unlocks Cloud Functions + Cloud Storage; free quotas cover most
usage at 8-branch scale, overage is cents. Project + billing creation
is a Dazy-only step (his Google account + card) — still blocked.

## Day 1 — Production data layer ✅ DONE (25 Nov 2026)

- [x] Firestore schema module (`lib/core/data/firestore_schema.dart`) — paths + field contracts per SRS §3, incl. Cloud Storage paths (Blaze)
- [x] Security rules draft (`firebase/firestore.rules`) + indexes (`firebase/firestore.indexes.json`) + README
- [x] Cloud Storage rules draft (`firebase/storage.rules`) — branch-scoped prescription photos
- [x] Cloud Functions design (`firebase/functions-design.md`) — 6 jobs specced, no code yet (Firebase-wiring chunk)
- [x] Offline sync queue (`sync_queue.dart` + platform stores) — idempotency dedupe, back-off, conflict policy
- [x] Inventory engine (`inventory_engine.dart`) — reserve → confirm/release, FEFO via the Day 5 guard, ≤500-op batches, append-only ledger, counters
- [x] Audit logs (`audit_log.dart`) — append-only, wired into engine + layer + queue conflicts
- [x] Export/backup (`backup_export.dart`) — JSON export (web download) + validated, idempotent import
- [x] `ProductionDataLayer` wired behind the repo interfaces — POS sale commit + order creation
- [x] Blaze pivot: `firebase_storage` re-added (`^14.1.0` — ^13 conflicted with `firebase_auth` 7.x); SRS v0.3, roadmap + setup plan revised
- [x] Prescription-image defect (D61): `flutter clean` + rebuild fixed the stale asset bundle — PNGs verified in `build/web` + manifest + widget test
- [x] Verification: `flutter analyze` clean, full suite **221/221** (191 Week 1 + 30 Day 1), web build passes
- Details: `docs/day-08-progress.md`

## Day 2 — Auto Purchase List screen ✅ DONE (25 Nov 2026)

Hadi asked for this specifically, so it was prioritised ahead of the
Firestore implementations (those shift to Day 3, with the auth
wiring — see below).

- [x] Auto purchase list screen (`lib/features/purchases/auto_purchase_logic.dart` + `auto_purchase_provider.dart` + `auto_purchase_list_screen.dart`) — suggestions from live inventory (low stock / below reorder level / near-expiry with low usable stock), suggested qty = reorder − usable, unit cost FEFO → 80% of sale price, open-PO exclusions with count + names, edit qty / supplier / remove, refresh, approve → one Draft PO per supplier through the normal purchases flow
- [x] Idempotent approval (D65): in-flight guard + client-generated approval key reused on retry + mock PO repo dedupes on client id
- [x] Route `/purchases/auto` (FeatureGate, Purchases module) + sidebar sub-item + mobile More-sheet sub-item + entry button on the Purchases list screen; branch-scoped, wide table + mobile cards
- [x] Verification: `flutter analyze` clean, new tests **25/25** (`test/week2_day02_test.dart`), full suite **246/246**, web build **Pass** (3,993,101 bytes)
- Details: `docs/day-09-progress.md`

## Day 3 — Firestore implementations + auth wiring ✅ DONE (25 Nov 2026)

- [x] Firestore repository implementations behind the existing interfaces (no screen rewrites) — `lib/core/data/firestore_transport.dart` (transport seam, ≤500 chunking, pagination), `firestore_mappers.dart` (all §3 collections, `validateOrThrow`), `firestore_repositories.dart` (9 repos; idempotency-key doc ids; counter-doc sequential numbers from 1001)
- [x] Repository factory / provider switch — `repository_factory.dart`, defaults to MOCK; Firestore kind without a transport throws `StateError`; auth/uploader switch only when a `FirebaseAuth` / `FirebaseStorage` instance is passed (none exists yet — both stay mock/local by design)
- [x] Batch status (D64 closed): `BatchStatus` on `InventoryItem` + `isBatchSellable` requires `available`; `sellableStockFor` (Day 2 auto purchase list) excludes quarantined end-to-end
- [x] Auth wiring: `AuthRepository` + `MockAuthRepository` + `FirebaseAuthRepository`; `AppUser` canonical user (claims `orgId` / `branchIds[]` / `role`); login + forgot-password screens delegate to the repo (demo accounts keep working via mock); `AppUser.branchId` = home branch
- [x] Role enforcement in the UX layer (D70): `PermissionService` over the SRS §5.1 matrix; `FeatureGate` consults it; sidebar + More-sheet hide unpermitted modules; prescription review buttons gated (pharmacist-only, own branch). Firestore rules remain the authority
- [x] Prescription photo upload path (D74): branch-scoped Storage path, metadata on the doc; local fallback holds bytes in memory, never fakes a cloud path
- [x] Idempotency-key holding across retries in the POS notifier (D54 closed): `SaleNotifier.pendingSaleKey` minted once, held across retries, cleared on success
- [x] Medicine purchase price (D76, found by the tests): `Medicine.purchasePriceMinor` — the §3 schema requires `purchasePrice` and the mapper omitted it
- [ ] `firebase_options.dart` via `flutterfire configure` — BLOCKED on the Firebase project (Dazy-only)
- [ ] Prescription photo upload flow (on-device capture → Cloud Storage → metadata on the doc) — code-ready; live upload blocked on the project
- [ ] Rules unit tests (`@firebase/rules-unit-testing`) — branch-isolation proofs
- [ ] Auth wiring: Firebase Auth + custom claims via the `setUserClaims` Function; demo login replaced — interface + mock done; live switch blocked on the project
- [x] Verification: `flutter analyze` clean, new tests **46/46** (`test/week2_day03_test.dart`), full suite **292/292**, web build **Pass** (46,156,443 bytes)
- Details: `docs/day-10-progress.md`

## Day 4 — Advanced POS + owner dashboard ✅ DONE (25 Nov 2026)

**Plan change:** the tracker originally listed Day 4 as "Goods
receiving via the production data layer" — that item is deferred to a
later day. Day 4 was re-scoped to Advanced POS + owner dashboard per
the Week 2 plan (barcode scan, printer, parked sales, returns,
owner-dashboard deepening).

- [x] Barcode-scan simulation hooks — scan field on the POS screen (autofocus + Enter-to-add), barcode → medicine → FEFO batch via the Day 5 guard (expired/quarantined/out-of-stock never added), `BarcodeScanner` abstraction + `SimulatedBarcodeScanner` + documented hardware integration point (`barcode_scanner.dart`)
- [x] Printer integration points — `ReceiptPrinter` interface (print receipt, open cash drawer, status) + working web-print implementation (popup print dialog, `receipt_print_web.dart`) + documented network/USB stubs that never pretend to print; printer settings entry in Settings → General (name/type, test print that actually prints, drawer test)
- [x] Sale holds (parked sales) — park cart with customer + notes, resume, discard; session-only, held carts never touch stock; listed on the POS screen (`parked_sales.dart`)
- [x] Returns / refunds (SRS §3 `saleReturns`) — pick sale, items + quantities (capped at still-returnable), reason required, refund in paisa, approval by the §5.1 `posRefund` matrix (pharmacist CANNOT approve — D80); on confirm: restock to original batch or earliest-expiry available batch (D78), sale status returned/partially_returned, stock ledger + audit entries, khata adjustment for credit sales; returns list screen with status
- [x] Owner dashboard deepened — live KPIs (today's sales, gross profit POS-only D81, outstanding khata, low-stock, near-expiry, pending prescriptions, open POs), branch-comparison view (head office sees all, branch users only their branch, enforced by the permission service), alerts feed from the notifications module; mobile cards + desktop wide shell
- [x] Verification: `flutter analyze` clean, new tests **42/42** (`test/week2_day04_test.dart`), full suite **334/334**, web build **Pass** (46,214,159 bytes). Two build/test bugs found and fixed in-day: sale-list staleness after return (D88), `@staticInterop` instance members breaking the web build (D85)
- Details: `docs/day-11-progress.md`; decisions D77–D88 in `docs/technical-decisions.md`

## Day 5 — Staff & HR + ledgers + prescriptions + advanced analytics ✅ DONE (25 Nov 2026)

**Week 2 build complete — QA pass next.**

- [x] Staff & HR (`lib/features/staff/`) — directory (CRUD, branch, job title, phone, status, 10-role assignment via `roleKey`), shifts (create/assign, HH:MM, no overnight), attendance (check-in/out per employee per day, late = start + 15-min grace, half day < 4h, today's view). Matrix gains `hrAttendance` + `hrSalary` (23 capabilities, was 21); 10 fictional staff + 3 shifts seeded. Salary figures not shown; `hrSalary` gates a future salary screen.
- [x] Ledgers fully wired — supplier payments allocated FIFO against open payables (payment record + ledger entry + financial-transaction entry, overpayment refused), aging buckets Current 0–30 / 31–60 / 61–90 / 90+ for payables and customer khata, supplier statement view + CSV export, "Payments" section. Expenses module (fixed categories, branch-scoped, feeds `financialTransactions`); 9 expenses seeded.
- [x] Prescriptions hardened — validity (30-day default, expired approved blocks dispatch like pending), re-review (rejected/needs-clearer-photo → Pending, count + 1, gated by `posSell` OR `rxReview` write), validity badge + resubmission note on detail screen, date picker on the new-prescription dialog. Day 7 hold → approve → dispatch path intact.
- [x] Advanced analytics (extends the reports screen) — weekly sales trend, branch comparison (D79 attribution), slow movers, expiry loss, P&L (D81/D93 cost rule), expenses list; CSV export for every new section.
- [x] Navigation — `Staff & HR` module (`/staff`, `/staff/attendance`, `/staff/shifts`), sidebar Manage group + mobile More sheet; 15 app modules, 11 feature modules.
- [x] Goods receiving (deferred tracker item) — CHECKED: Day 7 batch-wise receiving already covers it functionally (per-line qty, batch no, mfg/expiry, partial receiving, inventory + ledger writes). Remaining gap is only the separate SRS `goodsReceipts` document + routing receiving through the production data layer — follow-up, not a Day 5 build (D95).
- [x] Verification: `flutter analyze` clean, new tests **60/60** (`test/week2_day05_test.dart`), full suite **394/394**, web build **Pass** (46,323,939 bytes), prescription PNGs verified bundled (D61 check). One Day 4 printer widget test broke on the longer sidebar and was fixed in-test by scrolling first (D98).
- Details: `docs/day-12-progress.md`; decisions D89–D98 in `docs/technical-decisions.md`

## Week 2 QA pass ✅ GREEN (25 Nov 2026, coordinator re-run on final tree `d8fe9a2`)

Testing rule followed: Week 2 tested alone first, then cumulative with Week 1.

- [x] `flutter analyze` — **No issues found!**
- [x] Week 2 alone (`test/week2_day01_test.dart` … `test/week2_day05_test.dart`) — **203/203 passed** (30 + 25 + 46 + 42 + 60)
- [x] Cumulative full suite (Week 1 + Week 2) — **394/394 passed** (191 Week 1 + 203 Week 2)
- [x] Fresh `flutter build web --release` — **✓ Built build/web** (168.7s compile)
- [x] Prescription PNGs (D61) — both in `build/web/assets/assets/images/prescriptions/` (114,613 + 110,613 bytes) and in `AssetManifest.bin` (2 mentions each); widget test proves the prescription detail screen renders the `Image` wired to the sample asset path. No live-browser visual check (subagents cannot run the live browser).
- [x] **Verdict: Week 2 COMPLETE + VERIFIED.** No dead buttons / placeholders introduced in Week 2 (route-walk test covers all 15 modules).

## Follow-ups (not in Week 2 build)

- [ ] Firestore implementations for the six Day 5 repos (Staff, Attendance, Shift, Expense, FinancialTransaction, SupplierPayment) — Firebase-wiring chunk; schema contracts already exist in `firestore_schema.dart` §3.6/§3.7
- [ ] `goodsReceipts` document + receiving through the production data layer (D95)
- [ ] Salary screen (gates on the existing `hrSalary` capability)
- [ ] Reports on pre-aggregated counters (daily rollup Function output) + pagination
- [ ] Sync-status UI (pending counts, last-sync time) on offline-capable screens

## Blockers (Dazy-only, unchanged)

- Firebase project + billing (Blaze) creation — no cloud sync until then.
- GitHub repo `Sharjeel-580/pharmadesk` — CREATED + VERIFIED 25 Nov 16:02 (public, empty). Code push via the browser upload route is a later chunk's work; CI/APK path unblocks once the code is pushed.
- Hadi's requirements (medicines count, delivery areas, payment method, branch cities, logo + brand colours).
- APK build remains environment-blocked in this sandbox (D52); CI is the fix path once the repo has code.
