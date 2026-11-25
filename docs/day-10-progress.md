# Day 10 Progress — Week 2 Day 3: Firestore Implementations + Auth Wiring

**Date:** 25 Nov 2026. **Status:** DONE — verified (see table below).

## What was built

The Firestore repositories, the auth repository + permission service,
and the prescription photo upload path now exist in code — all behind
the existing interfaces, all defaulting to the mock backend, so the
app works exactly as before with zero config. There is still **no
Firebase project** (Dazy-only step), so nothing here is wired to a
live backend yet: the Firestore implementations are code-ready and
tested against an in-memory fake transport.

### New files — `lib/core/data/`

| File | What it does |
|---|---|
| `firestore_transport.dart` | `FirestoreTransport` — the only seam the repositories touch Firestore through. `FirebaseFirestoreTransport` is the real implementation; tests use an in-memory fake. Owns ≤500-op batch chunking and pagination (`queryCollection` with `orderBy` + `startAfterId`, document-id order by default). No `deleteDocument` (soft-delete only). |
| `firestore_mappers.dart` | Pure model↔Firestore translation for all §3 collections, with `validateOrThrow` against `FirestoreSchema` on every write. Money is int paisa at the boundary (D6). Documented lossy mappings: order status `ready`→`preparing` (reads back `processing`), order status/source snake_case, batch `quantityReceived == quantity` on create, PO items/payments in subcollections. |
| `firestore_repositories.dart` | Firestore-backed implementations of all 9 repository interfaces. Doc id = idempotency key for sales (key), orders/POs (caller client id, D65 pattern — retry returns the original). Sequential numbers from counter docs (`branches/{branchId}/counters/{invoices\|orders\|purchaseOrders}`, starting 1001; a reserved number + failed batch = a gap, never a duplicate). Branch code from the branch doc `code` field with a demo fallback (dha→DHA, gulberg/glb→GLB). Branch-less reads enumerate org branches via the `branches` list read. `receiveStock` / `adjustStock` / `recordStockCount` run in transactions (batch + counter delta + append-only stockTransaction). Ledgers are read-then-add with a computed `balanceAfter` (documented race note). `reviewPrescription` never touches `photoStoragePath` (rules: immutable on update). |
| `auth_repository.dart` | `AuthRepository` interface + `MockAuthRepository` + `FirebaseAuthRepository`. `AppUser` is the canonical signed-in user (uid, email, displayName, orgId, branchIds, roleKey snake_case, demoRole, homeBranchId). Role comes from custom claims (`orgId` / `branchIds[]` / `role`); `appUserFromClaims` is the pure mapping (missing claims degrade to an empty role, never a crash). Demo accounts live in `demo_accounts.dart`. |
| `permission_service.dart` | `PermissionService` (`can` / `canInBranch` / `canWrite` / `isReadOnly` / `permissionFor`) over the SRS §5.1 matrix, plus `routeCapability` — only routes whose entry IS the capability are gated. Null user = allowed (the router redirect is the signed-out guard; Firestore rules remain the authority). |
| `repository_factory.dart` | `createRepositoryBundle({kind, transport, firebaseAuth, firebaseStorage, organizationId})` + `repositoryBundleProvider` (defaults to the mock bundle). All 9 `*RepositoryProvider`s + `authRepositoryProvider` + `prescriptionPhotoUploaderProvider` read from the bundle, so one override switches the whole app. Firestore kind without a transport throws `StateError` with an explanation. Auth switches to `FirebaseAuthRepository` only when a `FirebaseAuth` instance is passed; the uploader switches to Cloud Storage only when a `FirebaseStorage` instance is passed — without a project there is nothing to pass, so both stay mock/local by design. No in-app toggle, no auto `Firebase.initializeApp()`. |
| `prescription_storage.dart` | `buildPrescriptionPhotoUpload` (validates image/* content type, bytes strictly < 10 MiB, non-empty prescription id; builds `organizations/{orgId}/branches/{branchId}/prescriptions/{id}.jpg`) + `FirebasePrescriptionPhotoUploader` (real, needs a project) + `LocalPrescriptionPhotoUploader` (default; holds bytes in memory keyed by prescription id, returns a local path — never a fake cloud path). |
| `demo_accounts.dart` | Demo accounts split out of `auth_state.dart` (`DemoRole` / `DemoUser` / `DemoAccount` / `demoAccounts` / `demoPassword` + `DemoRole.roleKey` claim-key mapping). |

### Batch status (D64 — closed)

- `BatchStatus` enum (`available` / `quarantined` / `expired` / `returned`) on `InventoryItem` (default `available`); `isBatchSellable` now requires `status == available` in addition to future expiry + stock on hand. `isExpired` stays date-based.
- `sellableStockFor` (used by the Day 2 auto purchase list) automatically excludes quarantined stock — the "usable stock excludes quarantined" rule now holds end-to-end.
- Firestore mapping preserves the status; legacy docs without a status parse as `available`.

### Auth wiring

- `authProvider` state type changed `DemoUser?` → `AppUser?`; `AuthNotifier` methods are now async and delegate to the `AuthRepository`. Login + forgot-password screens await them; demo accounts keep working via the mock.
- `AppUser.branchId` returns `homeBranchId` (null for owner/all-branch roles). `seesAllBranches` = role in {super_admin, owner, ho_admin, accountant, auditor} (same set as the rules' `isHeadOffice()`).
- Role/permission enforcement in the UX layer (D70): `FeatureGate` consults the permission service (route→capability map: `/billing`→`posSell`, `/medicines`→`medicineCrud`, `/customers`→`khata`, `/suppliers`→`supplierPay`, `/purchases`→`poManage`, `/reports`→`reports`; NOT gated: `/prescriptions` — Owner has `rxReview: none` yet must view the queue, only Approve/Reject are gated — `/inventory`, `/orders`, `/notifications`, `/dashboard`). The shell sidebar + mobile More-sheet hide modules the signed-in user lacks permission for; fixed bottom-nav items are NOT filtered (index-based). Prescription detail Approve/Reject/Needs-clearer-photo buttons are disabled with an explanation when the user lacks `rxReview` (pharmacist-only, own branch).

### D54 — idempotency key holding (closed)

`SaleNotifier` holds `_pendingSaleKey` (getter `pendingSaleKey`): minted once on the first `completeSale` attempt (before validation) via `newIdempotencyKey('sale-$branchId')`, held across retries, cleared on success. Held in the notifier (the completion-state owner) rather than the POS screen widget — same guarantee; uncommitted keys are harmless to reuse. `buildSale` accepts an optional `idempotencyKey`. Actor wiring: `SaleNotifier.completeSale` and `OrderQueueNotifier.createOrder` pass the real uid/name from auth when signed in (fallback demo actor).

### D76 — medicine purchase price (found by the Day 3 tests)

The SRS §3 `medicines` doc requires `purchasePrice`, but the Day 0 `Medicine` model had no cost field and the mapper omitted it — its own `validateOrThrow` then rejected every medicine write. Fix: `Medicine.purchasePriceMinor` (int paisa, default 0, in `fromMap`/`toMap`); the mapper writes it and reads it back. Demo seed rows carry 0 until a purchase price is recorded.

### Tests — `test/week2_day03_test.dart` (46 tests)

- Mapper round-trips for all §3 collections (sale, order, medicine, customer, both ledgers, supplier, rider, prescription + photo metadata, PO).
- Batch chunking ≤500 via the fake transport (1200 ops → 500/500/200; 1 op → 1 chunk) and pagination (120 medicines → 50/50/20 pages, unique ids, `hasMore` flags).
- Idempotency doc ids: sale created twice with the same key → one doc, `INV-DHA-1001`; order/PO same pattern (`ORD-DHA-1001`, `PO-DHA-1001`).
- Batch-status guard: quarantined/expired/returned excluded from `sellableStockFor` / `isBatchSellable`.
- Auth repository: mock login success/fail, demo sign-in for all five roles, deterministic reset code, `appUserFromClaims` mapping (incl. `branch_manager` + branchIds), role display names.
- Permission service: owner (all except `rxReview`), cashier (own-branch POS/reports), pharmacist (`rxReview` own branch, POS own branch), auditor read-only, unknown role none, null user allowed, `routeCapability` mapping.
- Factory: default bundle is mock; firestore kind without transport throws `StateError`; providers resolve from the bundle.
- Storage: exact branch-scoped path, rejects non-image / ≥10 MiB / empty id; local uploader keeps bytes, never fakes a cloud path.
- Widgets: `FeatureGate` blocks `/suppliers` for a pharmacist, passes for the owner, passes `/billing` for a Gulberg cashier; prescription review buttons disabled for the owner, live for the pharmacist.
- D54: `pendingSaleKey` stable across a failed then retried `completeSale`, cleared on success; the next sale mints a new key.

## Verification

| Target | Result |
|---|---|
| `flutter analyze` | **Clean — No issues found** |
| `flutter test test/week2_day03_test.dart` (alone) | **46/46 passed** |
| `flutter test` (full suite) | **292/292 passed** (246 before Day 3 + 46 new Day 3 tests) |
| `flutter build web --release` | **Pass** — `✓ Built build/web` (46,156,443 bytes total; compile took 411s — the shared cell was busy with parallel video encodes) |

## What still needs a Firebase project (blocked, Dazy-only — unchanged)

- `firebase_options.dart` via `flutterfire configure`; the Firebase project + billing account (Dazy's Google account + card).
- Live verification of the Firestore repositories, auth claims, and the Storage upload against a real project — the fake-transport tests prove the code paths, not the live backend.
- Rules unit tests (`@firebase/rules-unit-testing`) — branch-isolation proofs.
- `setUserClaims` Function deployment (claims management, Job 6).

## Files changed

- New: `lib/core/data/demo_accounts.dart`, `auth_repository.dart`, `permission_service.dart`, `firestore_transport.dart`, `firestore_mappers.dart`, `firestore_repositories.dart`, `repository_factory.dart`, `prescription_storage.dart`, `test/week2_day03_test.dart`
- Edited: `lib/models/inventory_item.dart` (BatchStatus), `lib/models/medicine.dart` (purchasePriceMinor, D76), `lib/models/prescription.dart` (branchId + photo metadata fields), `lib/features/inventory/inventory_logic.dart` (status guard), `lib/features/authentication/auth_state.dart` (AppUser state, async, delegates to repo), `login_screen.dart`, `forgot_password_screen.dart`, `lib/features/dashboard/dashboard_screen.dart`, `lib/features/settings/feature_gate.dart`, `lib/app/shell/app_shell.dart` (sidebar/More-sheet permission filtering), `lib/features/prescriptions/prescription_detail_screen.dart` (review gating), `lib/features/billing/billing_logic.dart` + `billing_provider.dart` (D54 key holding), `lib/features/orders/orders_provider.dart` (actor wiring), `lib/core/services/repositories.dart` (branchId params, providers read the bundle), `lib/features/customers/customers_provider.dart`, `lib/features/prescriptions/prescriptions_provider.dart`, `test/day_03_test.dart` (auth group rewritten async)
