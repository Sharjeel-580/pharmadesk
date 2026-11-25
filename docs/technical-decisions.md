# PharmaDesk — Technical Decisions (Day 1, 23 Nov 2026)

Living record of architecture decisions. Newest first. Each entry states
the decision, the reason, and what it blocks or requires later.

## D1. Rebrand: `pharma_plus` → `pharmadesk` (Day 1)
- Dart package renamed to `pharmadesk`; Android `applicationId` +
  namespace and iOS bundle ID set to **`com.pharmadesk.app`** (generic
  white-label product ID — deliberately NOT client-specific).
- Display name everywhere: **PharmaDesk**. Web title/manifest, Windows
  binary name (`pharmadesk`), macOS/iOS names updated.
- The Day 0 customer-app shell (`lib/app/customer_app.dart`) is **flagged
  for conversion, not deleted**: PharmaDesk is staff/owner-only, so this
  shell becomes the staff phone app in Phase 1.

## D2. Backend: Firebase Spark, permanent free (Dazy, 23 Nov 2026)
- Backend is **Firebase Spark (free tier) permanently**. Laravel +
  PostgreSQL + VPS were dropped (would cost ~$5–10/month). Blaze
  pay-as-you-go is explicitly **out of scope** — the design must stay
  inside free quotas (efficient queries, pagination, caching, batched
  writes, denormalized counters where they save reads).
- Verified against Firebase's pricing pages via web search (23 Nov 2026):
  - **On Spark:** Firestore (1 GiB stored, 50,000 reads/day,
    20,000 writes/day, 20,000 deletes/day), Auth (50,000 MAU),
    FCM (free), Hosting (10 GB).
  - **NOT on Spark (Blaze-only):** Cloud Storage (since 3 Feb 2026 —
    no bucket access at all on Spark) and Cloud Functions (new
    deployments require Blaze). Phone Auth is also Blaze-gated.
- Consequences (recorded in SRS v0.2, 23 Nov 2026):
  - Prescription photos stay **on-device** (local storage) — never
    cloud URLs, because there is no cloud bucket on Spark.
  - **No scheduled backend jobs** and no server-side functions —
    logic lives in the app + Firestore security rules.
  - `firebase_storage` was **removed from pubspec** on Day 1 so no
    Week 2 code can accidentally wire it. Re-add only if Blaze is
    ever approved (it is not).
  - Email/Password auth for staff. Phone OTP is **not** planned until
    verified available on Spark — do not promise it.

## D3. Stack (verified compatible, Day 1)
- Flutter 3.47.7 (stable) / Dart 3.13.5, Java 17, Android SDK present.
- `flutter_riverpod: ^3.5.0` (state), `go_router: ^18.1.4` (routing),
  `dio: ^5.11.1` (reserved for future REST needs — unused on Day 1),
  `sqflite: ^2.4.6` (future offline), `flutter_secure_storage: ^11.2.0`.
- Firebase: `firebase_core ^5.2.0`, `cloud_firestore ^7.2.0`,
  `firebase_auth ^7.1.0`, `firebase_messaging ^17.1.0` (FCM is free
  on Spark).

## D4. `firebase_messaging` has no Windows implementation (known)
- Push notifications on the Windows desktop app are out of scope; the
  desktop app reads live order updates from Firestore instead.

## D5. `sqflite` platform limits
- sqflite works on Android/iOS. **Windows needs `sqflite_common_ffi`**
  (Week 2 decision when offline storage is wired). **Web has no
  sqflite** — web uses Firestore offline persistence / in-memory cache.
- sqflite is imported nowhere on Day 1 code paths; adding it to pubspec
  does not affect the web build.

## D6. Money is integers, never doubles
- All money is stored and calculated in **minor units (paisa)** as `int`
  (`lib/core/utils/money.dart`). Never use `double` for money.
- Known tech debt: the Day 0 data models still store `price` /
  `totalAmount` as `double`. POS/billing code converts at the boundary.
  Week 2 decision: migrate the models to int minor units.

## D7. Design: Kalora blue, Inter, light + dark
- Palette: primary `#164AAB`, deep blue `#073477`, white, background
  `#F3F6FA`, soft blue `#DCE7F5`, dark text `#17243A`, secondary text
  `#64748B`, success `#20A779`, warning `#E9A23B`, danger `#DC4545`.
- Inter (Regular/Medium/SemiBold/Bold OTFs) bundled in `assets/fonts/`.
- The previous emerald/lime direction is retired.
- Light + dark themes; the theme seed follows the active brand color.

## D8. White-label branding
- `BrandConfig` (`lib/core/theme/white_label.dart`) holds organization
  name, app name, logo, primary/secondary color, receipt branding.
  A Riverpod provider serves the active brand; the theme derives from it.
- Default brand is generic PharmaDesk; a Fazal Din override is defined.
  Stored per organization in Firestore (`organizations/{id}/settings`)
  once the backend is wired.

## D9. Architecture: repositories + mocks
- Screens depend on repository **interfaces** (`lib/core/services/`);
  Day 1 ships mock implementations with sample data. Week 2 swaps in
  Firestore implementations behind the same interfaces — no screen
  rewrites. Firestore implementations must be quota-efficient (D2).

## D10. Order status vocabulary (to align on Day 4)
- The Day 0 model enum is `placed / confirmed / preparing /
  outForDelivery / delivered / cancelled`. The Week 1 prompt's Day 4
  list is `New / Confirmed / Processing / Ready / Dispatched /
  Delivered / Cancelled`. Align on Day 4 by extending the model enum;
  do not silently rename existing values (stored data compatibility).

## D11. Builds: what this Linux environment can and cannot do
- **Can:** `flutter analyze`, `flutter test`, `flutter build web`,
  `flutter build apk` (Android SDK present).
- **Cannot:** `flutter build windows` (needs Windows + VS toolchain),
  `flutter build ios` (needs macOS + Xcode). Both must be verified on
  real Windows/macOS hardware before any claim is made about them.

## D12. Git: local repo only, no remote
- Day 1 initialised a local git repo in `~/workspace/fazal-din-pharma/`.
  No remote exists; nothing is pushed. Dazy has not approved a repo
  (name/visibility his call). Local commit identity: Muse.

## D13. No credentials in the repo
- No Firebase project exists yet; no `google-services.json`,
  `GoogleService-Info.plist` or `firebase_options.dart` in the repo.
  Nothing is created in Google Cloud from this machine. See
  `docs/firebase-setup-plan.md` for the steps Dazy must take.

## D14. APK build is BLOCKED in this sandbox (corrects D11, 23 Nov 2026)
- D11's "Can: `flutter build apk`" is **wrong for this VM**. The build
  fails deterministically downloading the `kotlin-dsl` Gradle plugin:
  Gradle's HTTP client gets `ProtocolException: The server failed to
  respond with a valid HTTP response` through the sandbox egress proxy,
  while curl/Python fetch the same URL (HTTP 200). Java's own
  `HttpURLConnection` also fails through this proxy (NoSuchElement
  Exception in `doTunneling0`). The daemon does receive the proxy
  system properties (verified by probe task). This is an environment
  limitation, not a code defect. Do not claim an APK builds here until
  a real APK file exists.
- Workarounds (Day 2): pre-populate the Gradle cache via curl + a
  file:// Maven repo from an init script, or build on CI / a machine
  with direct internet.

## D15. Gradle proxy + daemon setup (machine-local, NOT in the repo)
- Gradle distribution 9.3.1 manually installed under
  `/root/.gradle/wrapper/dists/gradle-9.3.1-all/9ot9r568e8zfvvd4mn8rbu1j0/`
  (the wrapper JVM's user home is `/root`, not `/home/hatch`; the
  folder hash is Gradle 9's own, not MD5-of-URL).
- `/root/.gradle/gradle.properties` holds the egress proxy
  (`systemProp.*`), `org.gradle.jvmargs` (proxy + truststore +
  `-Djava.net.preferIPv4Stack=true`), and `org.gradle.daemon=false`.
  `/root/.gradle/egress-cacerts.jks` holds the egress CA. The proxy
  password lives only in that machine-local file — never in the repo.
- Daemon dispatch is flaky under CPU throttling (startup ~20s vs the
  daemon's 10s health check); `preferIPv4Stack` fixed the systematic
  failure, occasional retries may still be needed.

## D16. Router: one GoRouter instance per app entry point (Day 2)
- Day 1 kept a single global `appRouter`. Day 2 replaces it with
  `createAppRouter()` — each entry point (`PharmaDeskApp`, `AdminApp`,
  `DesktopApp`, now `ConsumerStatefulWidget`s) creates its own router
  once in `initState`. A single shared global router cannot be reused
  across separate `MaterialApp.router` widgets, and per-instance
  routers also let tests pump each app independently.
- `/` redirects to `/dashboard`; all 14 module routes live inside a
  `ShellRoute` rendering `AppShell`. Unknown routes show a "Page not
  found" screen with a working way back (errorBuilder), never a dead end.

## D17. Shell breakpoint + white-label rendering (Day 2)
- Desktop layout (sidebar + top bar) at viewport width ≥900px; mobile
  layout (top bar + bottom nav + "More" sheet) below that. The web
  admin entry uses the desktop layout automatically on wide screens —
  no separate admin shell.
- The shell renders the active `BrandConfig` (brand initial avatar,
  app/organization name, brand primary/secondary colours) in the top
  bar and sidebar; the theme seed follows the brand primary. A
  `BrandConfig.fazalDin` provider override rebrands the whole shell
  (widget-tested).

## D19. Demo roles are a separate vocabulary from Day 0 StaffRole (Day 3)
- The SRS §8.1 demo roles are Owner / Branch Manager / Pharmacist /
  Cashier / Inventory Manager. The Day 0 `StaffRole` enum is owner /
  pharmacist / counter / rider — a different vocabulary (counter ≠
  cashier, no branch manager / inventory manager, rider is
  delivery-only).
- Day 3 defines its own `DemoRole` enum in the auth layer instead of
  forcing the SRS roles into `StaffRole`. Aligning the two (and the
  Day 4 order-status vocabulary, D10) is a Week 2 decision when the
  Firestore staff/roles collections are designed — do not silently
  rename either enum before then.

## D20. Auth gating: GoRouter redirect + refresh listenable (Day 3)
- The router's `redirect` sends signed-out users to `/login` and keeps
  signed-in users out of the auth pages. It re-runs when auth state
  changes via a small `AuthRefreshNotifier extends ChangeNotifier`
  (a subclass is needed because `notifyListeners` is protected) that
  each app entry bumps from a `ref.listen(authProvider, …)` in `build`.
- `createAppRouter()` with no `isSignedIn` stays **ungated** (default
  signed-in) so router-only tests and entries that have not wired auth
  still work; the dashboard falls back to the branch view when no user
  is signed in. Screens also call `context.go` explicitly after
  sign-in/sign-out — the redirect is the guard, not the only path.
- Auth pages (`/splash`, `/login`, `/forgot-password`) live outside
  the `ShellRoute`; `/authentication` redirects to `/login`.

## D21. Prescription model has no branchId — mock scopes by id prefix (Day 3)
- The Day 0 `Prescription` model carries no `branchId`. The mock
  repository scopes prescriptions per branch by the seed id prefix
  (`rx-dha-…` / `rx-glb-…`), and dashboard providers fetch the list
  already branch-scoped — `computeDashboardKpis` counts whatever list
  it is given and does not filter prescriptions itself.
- Week 2 adds a real `branchId` field when the models are migrated to
  int minor units (D6). Until then, do not rely on prescription
  branch scoping anywhere except through the repository methods.

## D22. Seed data: deterministic, relative to now (Day 3)
- Demo seed data (`lib/core/services/demo_seed_data.dart`) uses fixed
  `Random` seeds and dates relative to `DateTime.now()`, so "today"
  always has sales and figures are stable across runs. DHA is
  deliberately busier than Gulberg so branch switching shows different
  figures. 499 orders / 30 days in this build.
- All seed names, prices and stock are fictional (SRS §8.2).

## D23. StatCard value scaling + KPI grid cell height (Day 3)
- Day 2 `StatCard` wrapped long money values ("Rs 1,234,567.00") to a
  second line and overflowed fixed-height grid cells. The value is now
  scaled down with a `FittedBox` (single line, always fits).
- The dashboard KPI grid uses a fixed `mainAxisExtent` (200) instead
  of `childAspectRatio`: aspect ratios made wide-screen cells too
  short for the card content (label row + value + delta + padding).

## D24. Test lessons: splash spinner, scrollUntilVisible, off-screen taps (Day 3)
- The splash shows an indeterminate spinner, so `pumpAndSettle`
  never finishes while it is visible — tests advance the fake clock
  past the 1.2s splash delay with `tester.pump(Duration)` first, then
  settle (see `test/test_helpers.dart`).
- `scrollUntilVisible` with no `scrollable` argument resolves
  `find.byType(Scrollable)` — the login form's text fields each
  contain their own Scrollable, so it throws "Too many elements".
  Use `tester.ensureVisible` (nearest scrollable ancestor) or pass an
  explicit scrollable finder.
- `tester.tap` on a widget below the fold silently misses (hit-test
  warning, no navigation) — `ensureVisible` before tapping anything
  that may be off-screen (demo-login cards, quick actions, long-form
  buttons).

## D25. Order status vocabulary aligned (Day 4)
- The Day 0 enum is extended, not renamed (D10 closed): new values
  `newOrder`, `processing`, `ready`, `dispatched` join `placed /
  confirmed / preparing / outForDelivery / delivered / cancelled`.
  `orderStatusFromString` parses both vocabularies (plus `'new'`).
- Canonical flow (pure, `lib/features/orders/order_logic.dart`):
  New → Confirmed → Processing → Ready → Dispatched → Delivered,
  plus Cancelled as a side exit. `canonicalStatus` maps legacy onto
  it (`placed` ≈ New, `preparing` ≈ Processing, `outForDelivery` ≈
  Dispatched); every guard, label and filter works on the canonical
  value, so old and new orders behave identically.
- Guards: advance is impossible on Delivered/Cancelled (no next
  step); cancel is allowed until Delivered; edit is allowed until
  Delivered or Cancelled. Labels read the Week 1 vocabulary for both
  old and new values.

## D26. Order model — Day 4 fields (Day 4)
- `Order` gains `source` (phone / WhatsApp / walk-in — staff-entered
  only, no WhatsApp API), `fulfillment` (delivery / pickup) and
  `discountMinor` (int paisa, default 0), plus `copyWith` and int
  getters `subtotalMinor` / `totalMinor`. `fromMap`/`toMap`
  round-trip the new fields; Day 0 maps without them default to
  phone / delivery / 0 discount. `OrderItem.lineTotalMinor` is int
  paisa (D6: no doubles in money math).

## D27. Order queue state: one notifier, branch filter in the UI (Day 4)
- `OrderQueueNotifier` (AsyncNotifier) owns the in-memory order list
  for the session and writes through to the repository on every
  mutation (create / edit / advance / cancel), then refreshes — the
  queue, detail screen and dashboard share one source of truth.
  Branch scoping lives in the UI (active branch), not the notifier.
- `OrderRepository` gains `createOrder` (assigns the id) and
  `updateOrder`; `updateStatus` now uses `copyWith`, so a status
  change never drops source, discount, rider, notes or prescription.
- New `RiderRepository` + mock over 4 seeded riders (3 active).

## D28. Prescription dispatch guard (Day 4)
- An order whose linked prescription is still `pending` review must
  never be dispatched (Day 0 model rule, SRS §8). Enforced as a
  pure function (`advanceBlockedReason` in `order_logic.dart`) and
  in the detail screen: the Advance button explains why instead of
  advancing, and a warning banner shows while the prescription is
  pending. Full pharmacist review lands on Day 7.

## D30. Expired-never-sellable: one shared guard (Day 5)
- The rule "an expired batch can never be sold" lives in exactly one
  place: `isBatchSellable` / `canSellMedicine` / `fefoBatchFor` in
  `lib/features/inventory/inventory_logic.dart` (pure functions,
  `now` injectable for tests). A batch is sellable only when its
  expiry day is still ahead (expires today = expired, same as
  `InventoryItem.isExpired`) AND it has stock on hand.
- The Day 4 order form now calls this guard (it previously checked a
  single row's `isExpired` — that check is removed, not duplicated).
  The Day 6 POS must call it too — never re-implement the rule.
- Expiry buckets are exact: ≤0 days expired, 1–30 / 31–60 / 61–90 /
  >90 fresh; null expiry counts as fresh.
- FEFO: earliest expiry first, no-expiry last, batch number breaks
  ties. `fefoBatchFor` is the batch an order/POS picks from.

## D31. Seeded order count is 491, not 499 (Day 5 correction)
- The Day 3/4 docs and sprint tracker state "499 orders". The Day 4
  code (commit `2e1954d`) itself generates **491** — verified in a
  clean worktree at that commit. Day 5 changes nothing in the order
  stream (orders still pick only from the 14 core medicines), so 491
  is the correct figure; the Day 5 test pins it. If a future seed
  change moves the count, the test must be updated deliberately, not
  silently.

## D32. Catalogue + inventory model (Day 5)
- Catalogue is 180 medicines (14 core + 166 deterministic generated
  rows, `Random(23)`), inside the SRS §8 demo range of 150–250.
  `Medicine` gains a `barcode` (13-digit sample EAN) and a
  `priceMinor` int-paisa getter (D6: the stored `price` stays double
  until the Week 2 model migration).
- One `InventoryItem` is ONE BATCH: 1–3 batch rows per medicine per
  branch, each with `mfgDate` and `costMinor` (int paisa) and a
  `copyWith` for stock operations. Dashboard low-stock / near-expiry
  counts are per batch row, as before — the figures grow with the
  catalogue, which is correct (more batches = more rows).
- Stock operations (`receiveStock` / `adjustStock` /
  `recordStockCount`) are repository methods; `InventoryNotifier`
  owns the list and invalidates the dashboard + order-form inventory
  providers after every write, so figures update without a restart.
  Adjustments require a reason and can never take a batch below zero
  (repository throws `ArgumentError`; the notifier returns null).

## D33. Test lessons: tall viewport for long forms (Day 5)
- At the default 800×600 test size, buttons near the top/bottom of a
  long scrollable form sit under the shell top bar / bottom nav and
  `tester.tap` silently misses (hit-test warning, no action).
  `ensureVisible` alone does not fix it — it can park the widget
  exactly under the bar. For form tests that tap low rows, set a tall
  viewport first (`tester.view.physicalSize = Size(800, 1600)`,
  `devicePixelRatio = 1.0`, `addTearDown(tester.view.reset)`).

## D34. Sale idempotency: client key + in-flight guard (Day 6)
- Every POS sale carries a client-generated `idempotencyKey`
  (`sale-<branchId>-<millis>`, SRS FR-POS-11). Week 2 uses it as the
  Firestore document id, so a retried write can never create a
  duplicate sale. In the Day 6 mock the repository still assigns its
  own id + invoice number; the key is stored on the sale.
- The notifier also blocks a second `completeSale` while one is in
  flight (`_completing` flag), so a double-tap on Complete Sale
  cannot save twice in one session.

## D35. FEFO allocation across batches (Day 6)
- `allocateFefo` (billing_logic) walks a cart line's sellable batches
  in FEFO order and decrements earliest-expiry first. A line that
  needs more than one batch's stock splits into one `SaleItem` per
  batch chunk; the first chunk carries the line discount, so the
  discount total is preserved exactly. Insufficient sellable stock
  throws `ArgumentError` and the sale completes nothing — no partial
  decrements, no saved sale.
- The receipt shows the batch + expiry per item chunk, so FEFO is
  visible to the cashier and the client (SRS §8.4 acceptance).

## D36. POS sales feed the dashboard KPIs (Day 6)
- `computeDashboardKpis` gains an optional `sales` list (default
  empty): completed POS sales count toward today's sales/orders,
  30-day revenue, the daily series and top sellers, branch-scoped
  like orders. The dashboard providers fetch sales from the sale
  repository. The seeded 30-day history still lives in the orders
  stream; the mock sale list starts empty and grows only from POS
  sales rung in the session.

## D37. Khata ledger: signed amounts, computed outstanding (Day 6)
- Ledger amounts are signed int paisa: positive = the customer owes
  more (credit / credit sale), negative = paid. Outstanding is
  always the SUM of the entries — never a stored balance field that
  can drift. Each entry snapshots `balanceAfterMinor` at insert
  (computed by the repository) so the statement reads like a bank
  statement. The ledger is append-only: entries are never edited or
  deleted (SRS §3 history rules).
- A credit sale appends a `creditSale` entry automatically; manual
  credit (udhaar) and adjustments need a reason; a payment may not
  exceed the outstanding.

## D38. Customer credit limit (Day 6)
- `Customer.creditLimitMinor` (int paisa, 0 = no limit set). A credit
  sale that would take outstanding + sale total past a set limit is
  blocked at validation (in the notifier, against live khata state)
  and in the pure `validateSale`. Seeded limits: Rs 10,000–20,000
  for the first four customers.

## D39. Riverpod 3 + Dart inference lessons (Day 6)
- Family notifiers take their argument as a **constructor
  parameter** (`LedgerNotifier(this.customerId)`) — Riverpod 3 has
  no `arg` getter on the notifier. The provider is created with the
  constructor tear-off (`LedgerNotifier.new`).
- `Iterable.fold(0, …)` infers `num`, not `int`, when its result
  feeds a `+` expression (the dashboard day-sales fold): give the
  fold an explicit `<int>` type argument.
- A `DropdownButton<String?>` with a null value needs a null-valued
  item (walk-in) plus a hint; while lookup providers are still
  loading, fall back to null (D29, re-applied on the POS customer
  picker).

## D40. Test lessons: clipboard + SnackBar overlays (Day 6)
- `Clipboard.setData` has no platform handler in the widget-test
  environment — its Future never completes there (a scratch probe
  hung on it). The app code is correct on real devices; the Share
  test mocks `SystemChannels.platform` (scoped, cleared in tearDown).
- A SnackBar overlays the bottom action buttons: a tap meant for a
  button underneath hits the SnackBar instead. Tests that tap two
  SnackBar-showing actions in a row must let the first SnackBar
  expire (`pump(Duration(seconds: 5))`) before tapping the second.
- The "More" sheet's ListView is lazy: at the default 800×600 size
  the Customers row is not built. Customer tests use a tall
  800×1600 viewport so all 14 modules exist (D33 pattern).
- `find.byType(TextField).at(n)` counts fields behind a modal dialog
  too — scope dialog field finders with
  `find.descendant(of: find.byType(AlertDialog), …)`.

## D29. Seed determinism + test lessons (Day 4)
- Adding random draws to the seed generator shifts the deterministic
  stream for every later order: after the Day 4 source/fulfilment
  draws, "today" had 13 orders but zero New ones. The seed now
  forces the first two orders of each branch today to `newOrder`,
  so the queue's New filter is never empty in the demo.
- Tests must pick live orders by guard (`canAdvance` etc.), not by
  a fixed status — a fixed status may not exist in today's mix.
- `DropdownButton` crashes when its value has no matching item:
  while lookup providers are still loading, the form falls back to
  null (hint) until the data arrives.
- Below-the-fold buttons silently miss taps — `ensureVisible`
  before tapping (D24, re-learned on the detail/form screens).

## D18. Demo branches for the branch switcher (Day 2)
- Two fictional demo branches per SRS §8: "Demo Branch — DHA"
  (`branch-dha-main`) and "Demo Branch — Gulberg"
  (`branch-demo-gulberg`), in `lib/core/services/branch_context.dart`.
  The DHA branch reuses the Day 1 mock repos' branch id so sample
  orders/inventory line up with it. Switching is in-memory only (mock
  data, no backend); Week 2 replaces the list with Firestore branches.

## D41. Supplier ledger mirrors the customer khata (Day 7)
- Supplier balances use the same append-only ledger pattern as the
  customer khata (D37): `lib/models/supplier_ledger.dart`, signed int
  paisa, `balanceAfterMinor` snapshot on every entry. Outstanding is
  always computed from the ledger, never a stored field — the old
  stored `balanceMinor` on `Supplier` was removed.
- Ledger entry kinds: purchase (+), payment (−), adjustment (signed).
  The repository assigns the id and computes `balanceAfterMinor`;
  callers never set it.

## D42. Purchase-order receiving coordination (Day 7)
- Receiving a PO is a cross-module write: it adds batches to
  inventory (via the inventory repo, with mfg/expiry per line),
  charges the supplier ledger with the received value, and
  invalidates the inventory, dashboard, order and notifications
  providers so every screen reflects it at once.
- Partial receiving is allowed: a PO with some (not all) lines fully
  received becomes Partially received; remaining quantities stay open
  for a later receiving. `statusAfterReceiving` is pure logic in
  `purchases_logic.dart`, tested without widgets.
- PO number is sequential per branch (`PO-DHA-1001`…), assigned by
  the mock repo at creation; the PO starts in Draft.

## D43. PO / receiving guards are pure functions (Day 7)
- `canApprovePo`, `canReceivePo`, `canCancelPo`, `validateReceiving`,
  `applyReceiving`, `validatePurchaseOrderForm` live in
  `purchases_logic.dart` with no Flutter dependency, so the full
  transition matrix is unit-tested. Screens only call them.
- Default cost price on a new PO line is 80% of the medicine's sale
  price (editable per line).

## D44. Prescription review + order unblock (Day 7)
- Approving a prescription unblocks any order the Day 4 prescription
  dispatch guard was holding: the guard re-checks the prescription
  status live, so no order-side mutation is needed on approval — the
  order provider is invalidated and the guard sees Approved.
- Seed forces `rx-dha-1` and `rx-glb-11` Pending and links them to
  today's first order of each branch, so the hold → approve → dispatch
  path is demonstrable without hunting for a linked order.
- Rejection and "needs clearer photo" both require a note
  (`validateReview`); approval does not.

## D45. Prescription photos: on-device / bundled samples only (Day 7)
- On Firebase Spark there is no Cloud Storage (Blaze-only), so
  prescription photos can never be public/cloud URLs. In production
  they are private on-device files. In this demo they are bundled
  sample assets (`assets/images/prescriptions/sample-prescription-*.png`),
  generated with PIL, clearly marked SAMPLE / "DEMO ONLY — NOT A REAL
  PRESCRIPTION", fictional patients and doctors.
- The model doc was corrected: a photo field must never be described
  as a URL. The "new prescription" form attaches the first sample
  image (no camera/gallery picker in the demo).

## D46. Real PDF export via the `pdf` package (Day 7)
- `pdf 3.13.1` resolved cleanly and produces a real PDF
  (`buildSalesReportPdf` in `reports_logic.dart`): title, period,
  totals, daily-sales and best-sellers tables. A unit test asserts
  the bytes start with `%PDF` and length > 1000.
- CSV export covers every report section; the PDF covers the sales
  summary only (simple tabular layout, no logo). Both download on web
  through the same `file_download` helper.

## D47. Web file download via `package:web` (Day 7)
- `lib/core/utils/file_download.dart` is a platform-conditional
  export (stub on non-web, `package:web` + `dart:js_interop` on web):
  Blob + object URL + anchor click. `web 1.1.2` added to pubspec.
- The old `dart:html` import is gone — `package:web` is the supported
  API on current Flutter. The stub returns a no-op so non-web builds
  still compile.

## D48. Feature config + FeatureGate (Day 7)
- 10 toggleable modules in `feature_config.dart`
  (`featureModuleForRoute` maps routes to modules); Settings is never
  disableable. State lives in a `FeatureConfigNotifier` (in-memory
  only in the demo; production stores it per organization in
  Firestore, SRS FR-SYS-05).
- Every route is wrapped in `FeatureGate`: a disabled module opened
  directly shows a clear "module is disabled" state with Open Feature
  Settings + Back to Dashboard. The shell hides disabled modules from
  the sidebar and the mobile More sheet.
- `ModulePlaceholderScreen` was deleted with the last placeholder —
  no placeholder screens remain in the app.

## D49. Roles & permissions matrix is display-only (Day 7)
- The 10 roles × 21 capabilities matrix in
  `roles_permissions.dart` is transcribed from SRS §5.1 and shown
  read-only in Settings. The demo role picker only highlights a
  column. Production enforcement is Firestore security rules +
  custom claims (SRS §5.2), not the demo UI — stated on-screen so
  nobody mistakes the matrix for enforcement.

## D50. Notifications are derived, not pushed (Day 7)
- Alerts are computed from mock data at load time
  (`notifications_logic.dart`): low-stock, near-expiry, expired
  batches, pending prescriptions (max 5), POs awaiting approval,
  today's new orders. Each alert carries the route it opens.
- There is no FCM / push in the demo (no backend to send from).
  Read/unread state is a Riverpod notifier, in-memory only.
- The shell bell is `_NotificationsButton` with a live unread-count
  Badge, wired to `unreadNotificationsProvider`.

## D51. Prescription notifier repo fallback + test lessons (Day 7)
- `PrescriptionsNotifier.review`/`create` fall back to the repo when
  the list has not been loaded yet (e.g. review opened from a deep
  link before the queue screen loaded). Same pattern as the POS
  customer picker fallback (D29).
- PO receive widget test: the date-picker loop taps buttons by index
  (`mfgButtons.at(i)` / `expiryButtons.at(i)`) — tapping by text
  matched the wrong dialog when two pickers were open in sequence.
- Branding test: the Fazal Din preset re-renders the shell in the
  same pump — brand state is a Riverpod notifier the shell watches,
  so no navigation is needed to see the change.

## D52. APK build attempt (cache pre-populate) — BLOCKED, new failure (24 Nov 2026, ~03:00–03:35 PKT)
- Fix path (a) was tried once, time-boxed: curl-based recursive Maven
  mirror + `file://` repo + init script, `flutter build apk --debug`.
  **No APK was produced. The build is still blocked — but no longer
  on downloads.** The stopping failure is a Kotlin/Gradle version
  incompatibility, not a missing artifact, so per the attempt's rules
  the work stopped here.
- What was built (machine-local only, nothing in the repo):
  - `/home/hatch/.gradle/maven-mirror/maven_mirror.py` — recursive
    POM resolver over curl (Central + Google Maven + Plugin Portal);
    fixes found along the way: `${project.*}` properties, exact-version
    ranges like `[1.1.7]`, parent POMs + imported BOMs must also exist
    as files in the repo (Gradle parses them).
  - `/home/hatch/.gradle/local-maven/` — file:// Maven repo, **664
    modules, 463 MB**, zero unresolved modules (roots: kotlin-dsl
    plugin 6.4.2, KGP 2.2.20/2.4.0, AGP 9.1.0, AGP 8.11.1 for
    flutter_tools, Firebase BOM 35.2.0 + firestore/auth/messaging).
  - Init script `/root/.gradle/init.d/local-maven.init.gradle`
    (also copied under `/home/hatch/.gradle/init.d/`, which Gradle
    does not read): pluginManagement + dependencyResolutionManagement
    repositories replaced with the file repo only, and
    `gradle.startParameter.offline = true` so no network repo is ever
    consulted (a transport failure on google()/central() would abort
    the build even for artifacts present in the file repo).
- Corrections to D14/D15 (learned this attempt):
  - Gradle's user home is Java `user.home` = **`/root/.gradle`**, NOT
    `$HOME` (`/home/hatch/.gradle`). `/root` is wiped on a runtime
    restart: the restart at ~22:05 UTC deleted `/root/.gradle` and
    `/tmp` (mirror script + POM cache lost), while `/home/hatch`
    survived. The Day 1 Gradle setup must be re-restored after a
    restart; the mirror tooling now lives under `/home/hatch` so it
    survives.
  - The wrapper really does want hash dir
    `9ot9r568e8zfvvd4mn8rbu1j0` (not the MD5-hex `a3a9c1a…` dir);
    the distribution was re-installed there from the surviving
    `/home/hatch` copy (plain `cp -r`; `/root` is a different device,
    hardlinks fail cross-device).
  - `flutter pub get` works fine through the proxy (Dart toolchain
    is unaffected); only Gradle's/Java's HTTP client is broken.
  - Daemon dispatch: the project's `android/gradle.properties`
    overrides user-home `org.gradle.jvmargs`, so the `preferIPv4Stack`
    in user-home gradle.properties never reaches the daemon JVM —
    dispatch failed twice ("Could not dispatch a message to the
    daemon", 4.5–4.9s). It succeeded only with
    `JAVA_TOOL_OPTIONS="-Djava.net.preferIPv4Stack=true"` on the
    flutter invocation (env only, machine-local).
- Where it stopped (build6, 62s in; direct gradlew --stacktrace
  confirms the same):
  - `NoSuchMethodError: StartParameterInternal.getIsolatedProjects()`,
    thrown from KGP's `ProjectIsolationStartParameterAccessorG76`
    while applying the Kotlin plugin in the flutter_tools included
    build (`dev.flutter.flutter-plugin-loader` resolution).
  - Cause: Gradle 9.3.1's `kotlin-dsl` plugin 6.4.2 depends on
    `kotlin-gradle-plugin:2.2.21` (runtime scope), which wins Gradle's
    conflict resolution over the `kotlin("jvm") version "2.2.20"`
    pinned by flutter_tools; KGP 2.2.21 calls a Gradle internal method
    that Gradle 9.3.1 does not have. This resolution happens on any
    machine — it is not caused by the mirror.
- Remaining fix path: **CI build on GitHub Actions once a repo is
  approved** (path (b)). The alternative within this sandbox would be
  a version alignment (newer Gradle where the method exists, or a KGP
  compatible with Gradle 9.3.1) — that changes the wrapper/SDK
  versions, which is outside fix path (a) and was not attempted.
- Reuse notes: re-running the mirror is cheap (POM cache persists
  under `/home/hatch/.gradle/maven-mirror/pom-cache`); after any
  runtime restart, restore `/root/.gradle` (wrapper dist +
  `gradle.properties` + `init.d`) from `/home/hatch/.gradle` before
  building, and invoke flutter with the `JAVA_TOOL_OPTIONS` above.

## D53. Production data layer: schema module is the source of truth (Week 2 Day 1)
- `lib/core/data/firestore_schema.dart` holds every collection path
  (root + `branches/{branchId}/` subcollections) and the field
  contracts transcribed from SRS §3, plus `validateDocument`.
  The Firestore implementations (Day 2+) build paths/payloads from
  these constants; the rules draft enforces the same shapes.
  No Firebase calls live in the module — there is no project yet.
- Doc id = client idempotency key for sales and orders only (SRS
  §2.5, FR-POS-11); inventory docs are keyed by medicine id; everything
  else uses auto-IDs.

## D54. Idempotency key scope: per completion attempt today (Week 2 Day 1)
- `ProductionDataLayer` dedupes on the key: a retried commit with the
  same key returns the original sale/order and moves no stock or money
  (tested). But the key is generated once per `completeSale` /
  `createOrder` call today (`buildSale` mints it at completion), so a
  retry AFTER a failed attempt mints a new key and would NOT dedupe.
  True retry-dedupe needs the caller to hold the key across retries —
  the POS screen must keep the key in cart state (Day 9 wiring item).
  The layer API already accepts an explicit key; only the callers
  need to hold it.

## D55. Sync queue: in-memory on web, sqflite on mobile (Week 2 Day 1)
- `SyncQueue` + pluggable `SyncStore`: `InMemorySyncStore` (web, and
  tests) and `SqfliteSyncStore` (Android/iOS, one row per op, PRIMARY
  KEY = idempotency key so storage itself enforces dedupe).
  Platform picked by conditional import (`sync_store.dart`), same
  pattern as `file_download.dart` — web never imports sqflite.
- On the web the queue resets on restart (documented); Firestore's
  own offline persistence takes over when the project exists.
- Retry back-off: 2s, 4s, 8s … capped at 5 min. Conflict policy:
  last-writer-wins via `updatedAt` EXCEPT money/stock docs, which go
  to `conflict` status + an audit entry and wait for a human — never
  silently overwritten, never silently retried.

## D56. Inventory engine reuses the Day 5 guard, never re-implements it (Week 2 Day 1)
- `InventoryEngine` allocates via `fefoBatches` / `isBatchSellable`
  from `inventory_logic.dart` (D30). Reserve → confirm on payment /
  release on cancel; only `confirm` decrements `quantityOnHand` and
  writes ledger entries. Batch snapshot + counter + ledger move
  together, synchronously, before any `await`.
- `LocalWriteBatch` mirrors Firestore's WriteBatch and chunks at 500
  ops; the layer enqueues the sale's batched-write payload (sale doc +
  items + inventory updates + stock transactions + khata entry) as one
  sync operation — the future Firestore transport executes one chunk
  per real batched write.

## D57. Audit log: append-only, summaries not snapshots (Week 2 Day 1)
- `AuditLogEntry` (`lib/core/data/audit_log.dart`): actor, action,
  entity, branch, before/after SUMMARIES (e.g. `qty 12 -> 9`), never
  full document snapshots (quota + 1 MiB doc limit). Every stock/money
  mutation in the engine, the layer and the queue's conflict path
  writes one. Local writer is in-memory; Firestore writes to root
  `auditLogs` with the same shape.

## D58. Backup: export is complete, restore target is a sink (Week 2 Day 1)
- `DataExporter` exports every repository (per-branch or org-wide) to
  one JSON document; dates are ISO strings, money stays int paisa;
  downloads on web via the existing `file_download` util.
- Restore writes into a `RestoreSink` (in-memory for now), NOT the
  live mock repos: the mocks have no upsert-by-id (they assign ids on
  create), so a live-repo restore cannot honour doc-id idempotency
  yet. The Firestore implementation restores by doc id directly.
  Import validates format/version/structure BEFORE any write and
  applies skip-existing (default) or overwrite policy — re-importing
  the same backup never duplicates a document (tested).

## D59. Security rules draft: claims design (Week 2 Day 1)
- `firebase/firestore.rules` (DRAFT, undeployed — no project yet):
  deny-by-default; branch isolation via custom claims
  (`orgId`, `branchIds[]`, `role`); head-office roles
  (owner / HO admin / accountant / auditor) read all branches of
  their org; auditor read-only everywhere; history collections
  append-only; money fields must be ints; sale/order doc id must
  equal `idempotencyKey`; prescription `localPhotoPath` must be a
  local path, never a URL.
- `firebase/firestore.indexes.json`: 16 composite indexes
  (branch+status+createdAt and similar, SRS §3).
- Claims are set by the `setUserClaims` Cloud Function
  (`firebase/functions-design.md`, Job 6) or, until Functions are
  deployed, from an admin machine with the Admin SDK.
  Approval separation (requester ≠ approver) stays app logic, not
  rules — rules cannot compare `requestedBy` to the approver across
  two writes without a lookup.

## D60. Test asset bundle cannot serve app assets (Week 2 Day 1)
- Probe-verified: in `flutter test`, `rootBundle.load` fails even
  for `AssetManifest.json` — the test environment's asset bundle does
  not serve the app's declared assets. Consequence: the prescription
  detail widget test asserts the `Image` widget is wired to the sample
  asset path (AssetImage assetName) + the SAMPLE caption, NOT that the
  bytes decode in-test. Real-bytes rendering is verified by the web
  build check (PNGs present in `build/web` + `AssetManifest.bin.json`).
  Do not "fix" the test by removing the image assertion; fix the
  harness if it ever starts serving assets.

## D61. Prescription sample PNGs missing from the web build — ROOT CAUSE FOUND + FIXED (Week 2 Day 1)
- Symptom: `build/web/assets/assets/images/` had only `.gitkeep`;
  zero `prescription` matches in the manifest, while the source PNGs
  exist (tracked, 114,613 + 110,613 bytes) and `pubspec.yaml` declares
  `assets/images/`. First diagnosis ("stale build") was WRONG —
  `flutter clean` + full rebuild (200s) produced the same missing
  PNGs.
- **Root cause (verified in the SDK source):** Flutter directory
  assets are **NOT recursive**. In `flutter_tools`
  `asset.dart` (`_parseAssetFromDirectory`), the collector does
  `directory.listSync()` — non-recursive — and keeps only direct
  `File` children. So `assets/images/` bundled `.gitkeep` but
  silently skipped the `prescriptions/` subdirectory. The same
  non-recursive scan is in `needsBuild`, so the stale-check missed it
  too.
- **Fix:** declare the subdirectory explicitly in pubspec:
  `- assets/images/prescriptions/` (with a comment pointing here).
  After the fix, both PNGs are in
  `build/web/assets/assets/images/prescriptions/` (exact byte sizes)
  and in the runtime manifest.
- **Manifest check gotcha:** `AssetManifest.bin.json` is a JSON
  string holding a **base64-encoded** blob — raw `grep` for
  "prescription" returns 0 even when the assets ARE bundled. The
  correct check is `AssetManifest.bin` (plain binary, greppable) or
  base64-decode the `.bin.json` first. Decoded manifest after the
  fix: 8 "prescription" mentions, both sample paths present.
- **Rule going forward:** every new asset subdirectory must be
  declared explicitly in pubspec; verify on every web build (files
  on disk + decoded manifest), not byte count alone.

## D63. Auto purchase list suggestion rules (Week 2 Day 2)
- One suggestion per medicine per branch, computed from live batch
  rows by the pure functions in
  `lib/features/purchases/auto_purchase_logic.dart`.
- **Usable stock** = `sellableStockFor` (the Day 5 shared guard,
  D30): non-expired batches with stock on hand only.
- **Reorder (par) level** = the sum of `lowStockThreshold` over the
  medicine's batch rows at the branch. The threshold already lives
  on the batch row (seeded 10 per batch), so no new model field was
  invented; the par level follows the branch's own alert levels.
- **Suggested quantity** = reorder level − usable stock, floored at
  0; only lines with suggested quantity > 0 appear.
- **Reason** (priority order): usable stock 0 → `Low stock`; a
  sellable batch expiring within 30 days → `Near expiry — usable
  stock low`; otherwise `Below reorder level`. Near-expiry alone,
  with usable stock at/above the reorder level, suggests nothing —
  the task's "whose usable stock is low" qualifier is the gate.
- **Unit cost** = the FEFO batch's cost, falling back to the
  earliest-expiry batch with a cost, then to 80% of the sale price
  (the Day 7 PO-form default, D43).
- **Exclusions:** a medicine on an open PO (Draft / Approved /
  Partially received, same branch, units still outstanding) is
  excluded. The count counts only medicines that would otherwise
  have been suggested.
- **Preferred supplier:** the catalogue has no medicine→supplier
  field, so the suggestion reuses history — the supplier of the most
  recent non-cancelled PO for that medicine at the branch, falling
  back to the first active supplier. Staff override it per line;
  approval groups by the line's supplier.

## D64. No batch status field yet — "non-quarantined" = sellable (Week 2 Day 2)
- The SRS batch status (available / quarantined / expired /
  returned, `firestore_schema.dart`) has no field on
  `InventoryItem` yet, so a quarantined batch cannot be represented
  in the model. The auto purchase list's "non-expired,
  non-quarantined" usable-stock rule is therefore implemented as the
  sellable guard (D30) — non-expired, in stock. When the status
  field lands (Week 2 model migration, D6), re-check the rule and
  exclude quarantined batches explicitly; do not assume the guard
  covers it.

## D65. Purchase-order idempotency: client-generated ids (Week 2 Day 2)
- Auto purchase approval mints one client-generated key per tap
  (`auto-po-<branch>-<millis>`), reused on retry, with a
  per-supplier key (`<key>-<supplierId>`) for each PO created.
- Three layers: (1) the approve button is disabled while an approval
  is in flight (`isApproving` on the notifier state); (2) the
  notifier remembers completed keys for the session and returns the
  already-created POs on a repeat submission; (3)
  `MockPurchaseOrderRepository.createPurchaseOrder` returns the
  existing PO when a non-empty client id is submitted again, and
  still assigns the sequential PO number. `buildNewPurchaseOrder`
  and `PurchaseOrdersNotifier.createOrder` accept the optional
  id/key. A retry after a partial failure reuses the per-supplier
  keys, so POs that already succeeded are returned, not duplicated.
- This is the same pattern D54 describes for sales/orders (doc id =
  idempotency key), applied to POs; the Firestore implementation
  must use the client id as the doc id the same way.

## D66. Riverpod 3.5 does not export `Override` publicly (Week 2 Day 2)
- `Override` is a sealed class in `riverpod`'s `override.dart`
  (a `part` of `framework.dart`) but it is NOT in the public
  `show` list of `lib/riverpod.dart` — so `List<Override>` cannot be
  named in test code and `flutter analyze` reports
  "The name 'Override' isn't a type". Override lists must be built
  inline where the `ProviderContainer(overrides: …)` parameter
  types them contextually; do not try to name the type in a helper
  signature (and `List<dynamic>` is not assignable to the parameter
  either). The Day 2 test helper takes an optional pre-built
  `ProviderContainer` instead.

## D67. Test lesson: off-screen taps need `ensureVisible` (Week 2 Day 2, D33 re-applied)
- The wide auto purchase table is taller than the 900px test
  viewport and wider than 1280px: the approve button sits below the
  fold and the remove button sits off the right edge (horizontal
  scroll). `tester.tap` on either silently misses (hit-test
  warning, no action) — the approval tests then saw zero POs
  created. `ensureVisible` before tapping both fixes it. Same rule
  as D33 for long forms; apply it to any button below the fold or
  past a horizontal scroll edge.

## D62. Backend pivot: Spark (permanent free) → Blaze pay-as-you-go (25 Nov 2026, Dazy)
- **Decision (Dazy, 25 Nov 15:56: "jo best rahy ga vo kro, free walaa ya paid jo b"):** the permanent-free Spark constraint (D2, 23 Nov) is LIFTED. Backend is now **Firebase Blaze (pay-as-you-go)**. Parent's call: Blaze unlocks Cloud Functions + Cloud Storage; at 8-branch scale cost stays near-zero (free quotas cover most usage, overage is cents); Flutter-native, fits the deadline.
- **What changes:**
  - `firebase_storage` is back in pubspec (it was removed on Day 1 because Storage is Blaze-only — that reason is gone).
  - Prescription photos: captured on-device, stored in **Cloud Storage** at `organizations/{orgId}/branches/{branchId}/prescriptions/{id}.jpg`, metadata on the Firestore prescription doc (`photoStoragePath`, `photoContentType`, `photoUploadedAt`, `photoUploadedBy`); `localPhotoPath` is only the on-device cache copy. Enforced by `firebase/storage.rules` (branch isolation + role checks, same claims model). The bundled SAMPLE images stay local demo assets.
  - Cloud Functions: **design only** in this chunk (`firebase/functions-design.md` — 6 jobs: expiry scan, low-stock digest, counters rollup, scheduled backup export, prescription reminders, claims management). No deployable Functions code until the Firebase-wiring chunk (needs the project + billing first).
  - Scheduled backup export is now a Function (Job 4); the in-app JSON export stays the manual fallback.
  - Claims are set by the `setUserClaims` Function (Job 6); admin-machine Admin SDK is the fallback until Functions deploy.
- **What does NOT change:** Firestore schema (§3), security rules + branch isolation + roles, offline sync queue, inventory engine, audit logs, export/backup, and the quota-efficient design (caching, batched writes ≤500, pagination, counters). The core data layer is backend-plan-agnostic. The only difference is the ceiling: on Blaze, exceeding the free tier bills the overage instead of stopping Firestore until reset.
- **Still forbidden:** no Firebase project, no billing setup, no google-services.json, no Firebase.initializeApp() — project + billing need Dazy's Google account + card (Dazy-only step).
- **History note:** D2 stays as written (it records the 23 Nov decision); this entry supersedes it. Do not rewrite D2 — the pivot is the record.

## D68. Batch status field (Week 2 Day 3, closes D64)
- `BatchStatus` enum (`available` / `quarantined` / `expired` / `returned`) on `InventoryItem`, default `available`; `isBatchSellable` now requires `status == available` in addition to future expiry + stock on hand. `isExpired` stays date-based. `sellableStockFor` (Day 2 auto purchase list) automatically excludes quarantined stock — the "usable stock excludes quarantined" rule now holds end-to-end. Firestore mapping preserves the status; legacy docs without a status parse as `available`.

## D69. Prescription gains branchId + photo metadata fields (Week 2 Day 3)
- `Prescription` gains `branchId`, `photoStoragePath`, `photoContentType`, `photoUploadedAt`, `photoUploadedBy`, `localPhotoPath` (all nullable). `fromMap` accepts both `reviewStatus`/`status` and `notes`/`reviewNotes`; `toMap` writes both `status` and `reviewStatus`. Mock `_scoped` prefers `branchId` when present, else the id-prefix fallback (`rx-dha-…` / `rx-glb-…`, D21). Mock `createPrescription` stores an explicit `branchId`.

## D70. Permission service: the SRS §5.1 matrix governs actions, not module viewing (Week 2 Day 3)
- `PermissionService` (`can` / `canInBranch` / `canWrite` / `isReadOnly` / `permissionFor`); null user = allowed (the router redirect is the signed-out guard; Firestore rules remain the authority). Route→capability map: `/billing`→`posSell`, `/medicines`→`medicineCrud`, `/customers`→`khata`, `/suppliers`→`supplierPay`, `/purchases`→`poManage`, `/reports`→`reports`. NOT gated: `/prescriptions` (Owner has `rxReview: none` yet must view the queue; only Approve/Reject actions are gated), `/inventory` and `/orders` (viewing is not a matrix capability; Cashier has `stockReceive: none` yet must run Stock Check), `/notifications`, `/dashboard`. `FeatureGate` takes the capability from the route internally (router passes `state.uri.path`, no router edits needed). Shell sidebar + mobile More-sheet hide modules the signed-in user lacks permission for (null user → show all); fixed bottom-nav items are NOT filtered (index-based). Prescription detail Approve/Reject/Needs-clearer-photo buttons are disabled with an explanation when the user lacks `rxReview` (pharmacist-only, own branch).
- Test lesson: do not assume the matrix from the role name — read it. Cashier CAN view reports (`own`) and Pharmacist CAN sell (`own`); both are branch-scoped, not denied. The matrix is the source of truth, not intuition.

## D71. Firestore transport seam (Week 2 Day 3)
- Firestore repositories talk to Firestore ONLY through the `FirestoreTransport` interface; `FirebaseFirestoreTransport` is the real implementation; tests use an in-memory fake. The transport owns ≤500-op batch chunking and pagination (`queryCollection` with `orderBy` + `startAfterId`, default document-id order). No `deleteDocument` method (soft-delete only); deletes exist only as `WriteOperationKind.delete` inside batched writes for subcollection item maintenance. Mappers stamp `Timestamp.fromDate(now)` (client clock), not server timestamps — documented tradeoff (server timestamps would need a second read to confirm the value).

## D72. Firestore mapper lossy mappings (Week 2 Day 3)
- Pure model↔Firestore translation with documented lossy mappings: money int paisa (OrderItem/Medicine/Order double rupees converted at the boundary); sale doc uses schema names (`subtotal`, `discountTotal`, `taxTotal`, `grandTotal`) + extras (`paymentMethod`, `cashierName`, `cashReceivedMinor`, `changeMinor`, `billDiscountMinor`); order status `newOrder`/`placed`→`pending`, `ready`→`preparing` (lossy — reads back as `processing`), `pending`→`newOrder`; source `walkIn`→`walk_in`; order `discountMinor` stored as extra; batch `quantityReceived == quantity` on create, only `quantityRemaining` updated later, dropped on read; `lowStockThreshold` extra; ledger `amount`/`balanceAfter` (schema) vs `amountMinor`/`balanceAfterMinor` (model), both accepted on read; PO status `partially_received` snake_case; items/payments in subcollections, never embedded in sale/order/PO docs; counter docs carry `value` + org/branch fields.

## D73. Firestore repository rules (Week 2 Day 3)
- Same interfaces as the mocks; doc id = idempotency key for sales (key), orders/POs (caller client id, D65 pattern — retry returns existing); sequential numbers from counter docs `branches/{branchId}/counters/{invoices|orders|purchaseOrders}` via transaction, starting 1001 (reserved number + failed batch = gap, never duplicate); branch code from the branch doc `code` field with demo fallback (dha→DHA, gulberg/glb→GLB); branch-scoped reads with null branch enumerate org branches via the `branches` list read (preserves mock "all" semantics); `getById` searches branches when the branch is unknown; low-stock/expiry filtered client-side (Firestore cannot compare two fields); ledgers read-then-add with computed `balanceAfter` (documented race note — a real concurrent-writer race needs a transaction; the queue serialises writes in practice); `receiveStock`/`adjustStock`/`recordStockCount` run in transactions (batch doc + counter delta + append-only stockTransaction); `updateOrder`/`updatePurchaseOrder` preserve the original `createdAt` and delete trailing stale item docs on shrunk lists; `updateSupplier` is a merge-update preserving `createdAt`; `reviewPrescription` update map never touches `photoStoragePath` (rules: immutable on update).

## D74. Prescription photo upload (Week 2 Day 3)
- `buildPrescriptionPhotoUpload` validates (image/* content type, bytes strictly < 10 MiB = 10,485,760, non-empty prescription id) and builds `organizations/{orgId}/branches/{branchId}/prescriptions/{id}.jpg`. `FirebasePrescriptionPhotoUploader` (real, needs a project) vs `LocalPrescriptionPhotoUploader` (default; holds bytes in memory keyed by prescription id, returns `localPath: prescriptions/{id}.jpg`, `storagePath: null` — never a fake cloud path).

## D75. Repository factory / provider switch (Week 2 Day 3)
- `createRepositoryBundle({kind, transport, firebaseAuth, firebaseStorage, organizationId})`; `repositoryBundleProvider` defaults to the mock bundle; all 9 `*RepositoryProvider`s + `authRepositoryProvider` + `prescriptionPhotoUploaderProvider` read from the bundle, so one override switches the whole app. Firestore kind without a transport throws `StateError` with an explanation. Auth switches to `FirebaseAuthRepository` only when a `FirebaseAuth` instance is passed; the uploader switches to Cloud Storage only when a `FirebaseStorage` instance is passed — without a project there is nothing to pass, so both stay mock/local by design. No in-app toggle, no auto `Firebase.initializeApp()`. Note: this creates Dart-legal import cycles (repositories ↔ factory, auth_repository ↔ factory, prescription_storage ↔ factory); all initialisation is lazy via providers.

## D76. Medicine purchase price was missing from the model (Week 2 Day 3, found by the tests)
- The SRS §3 `medicines` doc requires `purchasePrice`, but the Day 0 `Medicine` model had no cost field and the mapper omitted it — its own `validateOrThrow` then rejected every medicine write. Fix: `Medicine.purchasePriceMinor` (int paisa, default 0, in `fromMap`/`toMap`); the mapper writes it and reads it back. Demo seed rows carry 0 until a purchase price is recorded. Lesson: the schema is the contract — when a mapper's comment says a required field is "omitted, never invented", that is a bug, not a design choice.

## D77. Refund rule: line totals only (Week 2 Day 4)
- A return refunds the returned chunks' line totals only (unit price × qty − pro-rated line discount, truncated). Bill discount and tax are NOT refunded — re-allocating them per chunk would invent a split that no record supports. `chunkRefundMinor` / `computeRefundMinor` in `returns_logic.dart`.

## D78. Restock rule: original batch, else earliest-expiry available batch, else reject (Week 2 Day 4)
- A returned chunk restocks into its original batch if it still exists; else the earliest-expiry `available` batch of the same medicine; else the return is rejected. Never invent a batch, never move stock to another medicine. Batch status decides sellability via the Day 5 guard (`isBatchSellable`).

## D79. Khata attribution is per-branch only for sale-linked entries (Week 2 Day 4)
- Per-branch outstanding counts only ledger entries whose `referenceId` is one of that branch's credit sales; manual entries (no sale ref, incl. all seeded opening entries) are unattributed and count only in the org-wide total. The branch-comparison table footer explains this; the org-wide total in the KPI card is the SUM of all entries (D37).

## D80. Returns permission: the SRS §5.1 posRefund matrix governs, not the job title (Week 2 Day 4)
- `posRefund`: Super Admin none, Owner allowed, HO Admin allowed, Regional Mgr none, Branch Mgr own, **Pharmacist none**, Cashier own, Inventory Mgr none, Accountant none, Auditor none. So a pharmacist CANNOT approve returns, despite the task text saying "pharmacist/manager" — the matrix is the source of truth (D70 lesson: read the matrix, not the job title). Enforced via `permissionService.canWrite(user, 'posRefund', branchId)` in `SaleReturnsNotifier.createReturn`; the form disables Confirm with an explanation when the user lacks it.

## D81. Gross profit is POS sales only (Week 2 Day 4)
- `computeGrossProfitMinor` covers POS sales only — only they carry batch costs (batch `costMinor`, fallback medicine `purchasePriceMinor`, else 0). Orders are excluded and documented: they have no batch costs. Today's refunds are subtracted; bill discount/tax are ignored.

## D82. Printer honesty: web test print is real, network/USB report unavailability (Week 2 Day 4)
- The web printer's test print really prints (popup print dialog via `printText`); network/USB printers honestly report "not configured / not implemented" and never pretend to print. The browser cannot send a cash-drawer kick signal — `WebReceiptPrinter.openCashDrawer` returns failure with that explanation instead of faking success.

## D83. POS scan field sits after the search field (Week 2 Day 4)
- The barcode scan field is placed AFTER the search field in the "Add medicines" card so Day 6 tests' `find.byType(TextField).first` (the search field) keeps working. `_addMedicine` takes a required `sellableStock` and enforces the cap in one place — pick row, scan and stepper all funnel through it.

## D84. branchPerformanceProvider removed, replaced by branchComparisonProvider (Week 2 Day 4)
- The Day 3 branch-performance card is superseded by the branch-comparison card (same branches, richer per-branch stats: sales, stock value, outstanding, alerts). `branchPerformanceProvider` deleted; `ref.invalidate(branchComparisonProvider)` in billing, inventory, purchases and prescriptions providers.

## D85. js_interop @staticInterop: instance members must live in extensions (Week 2 Day 4)
- `@staticInterop` classes cannot declare instance members — the first Day 4 web build failed with "cannot declare instance members" on `_PopupWindow` / `_PopupDocument` in `receipt_print_web.dart`. Fix: empty `@staticInterop` classes + `extension …Members on …` blocks holding the `external` instance members. `flutter analyze` does NOT catch this; only the web build does.

## D86. Test lesson: settle between ensureVisible and tap in scrolling lists (Week 2 Day 4)
- `ensureVisible` starts a scroll animation; tapping immediately after fires at the pre-animation position and misses (hit-test warning, tap on sidebar 'Settings' missed). Pattern: `ensureVisible` → `pumpAndSettle` → `tap`. Applies wherever the target sits in a `ListView` (sidebar, long forms).

## D87. Day 3 test update: 'Branch performance' → 'Branch comparison' (Week 2 Day 4)
- The Day 3 widget test expected the old card title; Day 4 replaced the card (D84), so the test was updated to the new title. A replaced UI element is not a regression — but the test update belongs in the day's diff, not hidden.

## D88. Sale-list refresh after a return status update (Week 2 Day 4, found by the tests)
- `SaleRepository.updateSale` writes the new status to the repo, but the in-memory `SaleNotifier` list still holds the old sale — so the receipt, history and returns list all kept showing the old status (a full return displayed as "Partial return"). Fix: `SaleReturnsNotifier.createReturn` calls `ref.read(salesProvider.notifier).refresh()` after `updateSale`. Lesson: any repo write that bypasses a notifier's state must refresh that notifier, or every derived lookup goes stale.

## D89. Staff & HR: reuse the Day 0 Staff model, mock-first repos (Week 2 Day 5)
- The staff directory reuses the extended Day 0 `Staff` model (added `phone`, `jobTitle`, `roleKey`, `copyWith`, `effectiveRoleKey`) — no separate Employee model; SRS §3.7 `employees` is the Firestore-side name. Six new repos (`Staff`, `Attendance`, `Shift`, `Expense`, `FinancialTransaction`, `SupplierPayment`) are mock-backed providers NOT yet in the Day 3 `RepositoryBundle` — Firestore implementations land with the Firebase-wiring chunk (same Day 7 → Day 3 pattern as suppliers/purchase orders). Firestore schema paths for all six collections already exist in `firestore_schema.dart` §3.6/§3.7, so the contract is ready.
- Overnight shifts are out of scope (`validateShift` requires end after start the same day). Late = check-in after shift start + **15-minute grace** (documented demo rule). Salary figures are NOT shown in the Day 5 directory; the `hrSalary` capability exists so a future salary screen gates on the matrix.

## D90. Prescription validity: 30-day default, expired blocks dispatch (Week 2 Day 5)
- Default validity is 30 days from issue (a documented demo rule — the SRS names no validity period; the new-prescription form lets staff change the date). `isPrescriptionExpired` compares calendar days; a null `validUntil` on legacy records = treated as valid. `canUnblockOrder` = approved AND not expired, and the Day 4 dispatch guard (`advanceBlockedReason`) blocks dispatch for an approved-but-expired prescription with an explanatory message, like a pending one.

## D91. Prescription re-review: rejected / needs-clearer-photo can re-submit (Week 2 Day 5)
- `canResubmit` only for `rejected` / `needsClearerPhoto`. Re-submission returns the record to Pending, clears the previous review, sets a new (future) validity date, increments `resubmissionCount`. Who may re-submit is derived from the matrix — `canWrite(posSell)` OR `canWrite(rxReview)` in-branch — because the SRS has no "re-submit" capability; Inventory Manager, Accountant, Regional Mgr, Super Admin and Auditor may not re-submit. `resubmitPrescription` is implemented in both the mock and `FirestorePrescriptionRepository`; `validUntil` / `resubmissionCount` are in the Firestore schema contract and mappers.

## D92. Aging buckets + FIFO allocation (Week 2 Day 5)
- Buckets: Current 0–30 days, 31–60, 61–90, 90+ over 90 days. Supplier payments allocate oldest-first (FIFO); allocations always sum to the payment; a payment above the outstanding payable is refused. The same FIFO aging applies to customer khata outstanding. Supplier statement ordering is oldest-first and the stored `balanceAfterMinor` is the running balance, never recomputed.

## D93. Profit & loss cost rule (Week 2 Day 5)
- Reuses D81 (POS batch `costMinor`, fallback medicine `purchasePriceMinor`, else 0; orders use `purchasePriceMinor`). Refunds reduce revenue only — COGS is NOT clawed back, because restocked units return to sellable stock. Other income comes only from `financialTransactions` of type `income`; expenses come from the `expenses` collection (each expense writes a matching negative transaction, so the two sources never double-count).

## D94. Suppliers route gate: Branch Manager is stopped before the screen (Week 2 Day 5, found by the tests)
- The Day 3 `FeatureGate` maps `/suppliers` to `supplierPay`, on which a Branch Manager is `none` in the SRS §5.1 matrix — so the gate shows "No permission for Suppliers" before the detail screen (and its disabled Record payment button) is ever reached. That mapping is Day 3's deliberate, matrix-faithful design and was NOT changed in Day 5. The screen-level disabled button with explanation is for roles that can VIEW but not pay — i.e. Auditor (read-only on `supplierPay`): the gate lets them in, `canWrite` is false, the button renders disabled. Widget tests cover both paths (gate screen for Branch Manager, disabled button for Auditor).

## D95. Goods receiving: functionally covered by Day 7 batch-wise receiving (Week 2 Day 5)
- The tracker's deferred "Goods receiving" item was checked against Day 7: per-line quantity, batch number, mfg/expiry pickers, partial receiving, inventory + supplier-ledger writes are all built. The remaining gap is only the separate SRS `goodsReceipts` document and routing receiving through the production data layer — recorded as a follow-up, not built in Day 5.

## D96. Prescription detail badges wrap on narrow screens (Week 2 Day 5, found by the tests)
- The detail header Row (status + received + validity badges) overflowed 36px at 800px phone width once the validity badge was added. Fix: `Wrap` with spacing/runSpacing instead of `Row` + `SizedBox` gaps. Lesson: any header row that gains a third chip needs a wrap, not a wider row.

## D97. Day 5 test updates to earlier tests (D87 pattern, Week 2 Day 5)
- Deliberate, disclosed updates (not hidden): Day 7 roles-matrix test 21 → 23 capabilities (new `hrAttendance` + `hrSalary`); Day 7 feature-modules test 10 → 11 (`staff` module); Day 2 sidebar test 14 → 15 modules (`Staff & HR`); Day 7 route walk 14 → 15 routes (`/staff`); Day 7 supplier-payment widget test expects 3 dialog fields (amount + reason + reference — the Day 5 payment flow adds the reference field). Test-harness note: `signInAsDemoRole` taps the login screen of the REAL app widget; router-harness tests sign in through the container (`container.read(authProvider.notifier).signInAsDemo(DemoRole.…)`) instead.

## D98. Sidebar growth breaks ensureVisible on lazy ListView items (Week 2 Day 5, found by the full suite)
- The Day 5 sidebar additions (Staff & HR module + Attendance/Shifts sub-items) pushed 'Settings' out of the initially-built range of the lazy sidebar ListView, so the Day 4 printer widget test's `ensureVisible(find.text('Settings'))` threw "No element" — the element must already exist for `ensureVisible` to work. Fix (in the Day 4 test, not the app): scroll the ListView with drags until the item exists, then `ensureVisible` → `pumpAndSettle` → tap (Day 2 `scrollListToTitle` pattern). Lesson: any test that reaches a bottom-of-sidebar item must scroll first; adding a sidebar item can break such tests even when the app is fine.

## D99. Schema contract extensions for the six Day 5 collections (Week 3 Day 1)
- The §3.6/§3.7 contracts in `firestore_schema.dart` were complete enough to build against, but four gaps needed closing before the mappers could write exact round-trips — each extension is marked in the contract with its reason:
  - `supplierPayments`: added `paidAt` (timestamp, **required** — the SRS contract listed no payment date, but the model requires one and the statement sorts by it) and `allocations` (`map[]` — the FIFO `{ledgerEntryId, amount}` record; the contract listed no allocations, but the payment must show which payables it settled, D92).
  - `employees`: added `email`, `role` (Day 0 `StaffRole` name), `roleKey` (SRS §5.1 key) as optional extras — the local `Staff` model carries them and the mapper writes them so a round-trip is exact.
  - `attendances`: added `note` (optional extra — manager note on the record).
  - `expenses`: added `category` (display name; `categoryId` holds the same fixed-list name until categories become documents — see D100).
- **Not extended, deliberately:** `salary` / `joiningDate` stay in the `employees` contract but the mapper writes neither — the `Staff` model has no salary field (D89: salary figures are not shown) and no joining date, so both would be invented. A doc carrying them (written elsewhere) keeps them; the model drops them on read.

## D100. Day 5 Firestore mappings + validation (Week 3 Day 1)
- **Lossy mappings** (in `firestore_mappers.dart`, same header-note pattern as D72): staff `active` bool ↔ §3 `status` string (`active` / `disabled`); legacy docs with a bool `active` field are accepted on read. Transaction type is snake_case in §3 (`supplier_payment` / `customer_payment`) vs camelCase enum — translated both ways. Expense category: the demo categories are a fixed list, so the category NAME is the id for now — written into both `categoryId` (§3) and the `category` extra; the read side prefers `category`, falls back to `categoryId`. Payment `method` is the enum name (`bankTransfer`); the read side also accepts snake_case (`bank_transfer`). Supplier-payment allocations are stored as a list of `{ledgerEntryId, amount}` maps ON the payment doc (never a subcollection) — the FIFO record, D92.
- **Idempotency-key doc ids (D65 pattern, all six creates):** a caller-supplied non-empty id is the doc id — a retry returns the existing document instead of writing a second one. An empty id gets a Firestore auto-id, like the mocks assigning `staff-N` / `exp-N` / …. Attendance `upsertAttendance` is idempotent by construction: the same id overwrites the same doc (check-in creates, check-out rewrites), so a retried check-out can never duplicate a day. The append-only `financialTransactions` collection therefore never double-appends on retry.
- **Repository validation** mirrors the mocks + the providers' pure validators (`hr_logic.dart`, `finance_logic.dart`) — screens validate first, the repository re-checks what it owns: staff name non-empty + branch required, phone uniqueness org-wide on digits (formatting ignored) for create/update; expense amount > 0 and category in the fixed list; transaction amount ≠ 0 (signed amounts kept — negative is money out); payment supplier required, amount > 0, and a non-empty allocation list must sum to the payment (a shortfall means the outstanding figure moved under the caller — refuse, never record half-allocated, same rule as `validateSupplierPayment`); an empty allocation list is accepted. Updates preserve the original `createdAt` and no-op on a missing id, exactly like the mocks.

## D102. Salary figures live in a separate payroll record, not on the Staff model (Week 3 Day 2)
- **Decision:** one `SalaryRecord` per (employee, month) — `branches/{branchId}/salaries/{sal-{employeeId}-{yyyy-MM}}` — is the source of truth for salary figures. The `Staff` model gains NO salary field, and the staff mapper still writes no `salary` (D99 stands: the `employees.salary` contract field stays unwritten).
- **Why a separate record, not a Staff field:**
  - **Sensitivity:** `hrSalary` holders are only Owner / HO Admin / Accountant (Auditor read-only). A Branch Manager has `users: own` but `hrSalary: none` — a salary field on `Staff` would leak figures into every directory fetch, including to users who must never see them. The separate collection is readable only by `hrSalary` holders (rules draft updated to match).
  - **History:** monthly figures change over time (raises, allowances, deductions). A per-month record is the history; a single field on the employee is the current value only and can never answer "what was March's payroll?".
  - **Net invariant:** the record stores base + allowances + deductions AND the computed net; the repositories refuse a record whose net disagrees (net is always `base + allowances − deductions`, never a stored balance that can drift — same principle as the ledgers, D37/D41).
- **Demo figures:** seeded records for all 10 demo staff for the current month (`demoSalaryRecords`), sized to the role (Owner Rs 250,000 … Counter Rs 55,000), all `isDemo: true`. The screen labels them demo/sample on sight (banner + per-row badge) and says plainly they are not real payroll. No salary figure is ever invented as real data.
- **Not built yet:** the edit flow. The repository's `saveSalaryRecord` exists (upsert by employee+month, validated) for the future payroll-edit screen, guarded by `canManageSalary` (`hrSalary` write). The Day 2 screen is display-only.

## D103. Goods receiving runs through the production data layer (Week 3 Day 2, closes D95)
- **What changed:** `ProductionDataLayer.receiveGoods` is now the single write path for receiving (the Day 7 flow — per-line qty, batch no, mfg/expiry, partial receiving — is unchanged for the user). The purchases notifier calls the layer instead of the inventory / PO / supplier repos directly; the receiving dialog mints one idempotency key per dialog and passes it on every submit.
- **One receiving event writes, in order:** (1) the `goodsReceipts` doc (+ `items` subcollection docs) via the `GoodsReceiptRepository` interface — doc id = the idempotency key; (2) one batch per received line via the inventory repo, booked into the engine (`receive` ledger movements + audit, one per batch); (3) the PO update (received quantities + Partially received / Received); (4) the supplier-ledger purchase charge; (5) one `goods.received` audit entry; (6) one batched-write sync payload (receipt doc + items + batch docs + stock transactions + ledger entry + PO update) for the future Firestore transport.
- **Idempotency:** a retry with the same key returns the original receipt + the PO state that receive produced, and moves no stock or money (registry, same as sales/orders). The dialog-held key closes the D54 gap for receiving: a failed submit keeps the dialog open, so the retry reuses the key.
- **Fail-closed orphan guard:** a receipt id already in the store but NOT in the registry means a previous attempt wrote the receipt and then failed before finishing — retrying would receive the stock a second time (the inventory repo creates a new batch row per call, no batch dedupe). The layer throws `StateError` with the receipt number instead of double-receiving. The Firestore transport will execute the whole receive as one batched write, which removes the window entirely.
- **Engine:** `InventoryEngine.receive` books repository-created batches into the engine snapshot (batch + counter + `receive` ledger movement + audit per batch) — the counterpart of `confirm` for stock-in. The expired-never-sellable guard does not apply to receiving (incoming stock is new by definition); sellability is decided when the batch is later sold (D30).

## D104. Schema contract extensions: goodsReceipts + salaries (Week 3 Day 2)
- `goodsReceipts` gains `receivedAt` (timestamp, required), `supplierId` (required) and `totalValueMinor` (int paisa, required) — the SRS contract named no receipt date, supplier or value, but a receipt that cannot say when the goods arrived, from whom, or for how much is not an audit record. The `items` subcollection contract is added (`medicineId`, `quantityReceived`, `batchNo`, `mfgDate`, `expiryDate`, `unitCostMinor`).
- New `branches/{branchId}/salaries` contract (D102): `employeeId`, `month` (`YYYY-MM`), `baseSalaryMinor`, `allowancesMinor`, `deductionsMinor`, `netMinor` (required — always base + allowances − deductions), `isDemo`.
- Path builders added: `goodsReceiptsPath` / `goodsReceiptDocPath` / `goodsReceiptItemsPath`, `salariesPath` / `salaryDocPath`.

## D101. The six Day 5 repos join the RepositoryBundle (Week 3 Day 1, closes D89)
- `RepositoryBundle` gains `staff`, `attendance`, `shifts`, `expenses`, `financialTransactions`, `supplierPayments`; both kinds build them (Firestore implementations over the transport, mocks otherwise). The six providers in `lib/core/services/repositories.dart` now read from the bundle (`ref.watch(repositoryBundleProvider).staff`, …) instead of owning a mock instance each — the same switch the Day 3 repos already use (D75). The mock bundle stays the default, so screens behave exactly as before with zero rewrites; a Firestore-bundle provider override switches all six at once. Firestore kind without a transport still throws `StateError`. The D89 comment block is updated to record the closure.

## D105. Daily report counters: rollup doc shape + read-only repository (Week 3 Day 3)
- **Doc:** `branches/{branchId}/counters/daily-{yyyy-MM-dd}`, written by the daily counters rollup Function (Job 3, `firebase/functions-design.md`). The `value` map carries `{salesTotalMinor, salesCount, ordersCount, cogsMinor, grossProfitMinor}` plus `date` (`yyyy-MM-dd`), `branchId`, `computedAt`, `source: 'rollup'`. The two cost fields EXTEND the Job 3 spec (which listed only sales totals + counts) so the P&L and branch comparison can also read from counters; the spec text is updated to match, not left stale.
- **Cost rule (D81/D93, reused — never re-implemented):** `salesTotalMinor` is non-cancelled orders + POS sales with refunds subtracted; COGS is batch `costMinor` (fallback medicine `purchasePriceMinor`, else 0) for POS sales and `purchasePriceMinor` for orders. Refunds reduce revenue only — COGS is not clawed back, because restocked units return to sellable stock.
- **Read-only by design:** `FirestoreReportCounterRepository` has no create/update — a client that could write its own counters could fake the reports. The rules draft denies client writes to `daily-*` docs (the sequential-counter write rule now excludes that prefix; the Admin-SDK Function write is unaffected by rules). The doc also carries the `value is int` guard on sequential counters, which would reject the rollup's map value anyway.
- **Legacy docs:** a rollup doc written before the D105 extension (only the original three fields) still parses — the mapper defaults a missing `cogsMinor` to 0 and derives `grossProfitMinor` as revenue − COGS.
- **Mock:** `MockReportCounterRepository` computes the same figures from the same mock repos the live reports read (`computeDailyCounters`, pure, over orders/sales/returns/inventory/medicines) — derived from the seeded demo data, never invented, never a second seed. The mock bundle shares the repo instances with the counter repo so a sale rung in the session changes the counters. The Day 3 test pins exact agreement with the live computation (30-day DHA + 7-day Gulberg totals, per-day, P&L revenue/COGS, weekly trend).
- **Schema:** new contract key `branches/{branchId}/counters/daily-{date}` (the existing `counters` entry keeps its int `value` for sequential numbers — the two shapes share the collection but never a doc id) + `dailyCounterDocId` / `dailyCounterDocPath` builders.

## D106. Counters-first reports with full-coverage fallback, never mixed (Week 3 Day 3)
- `advancedReportDataProvider` reads the counters first: the weekly trend, branch-comparison sales/profit and P&L revenue/COGS come from the counters ONLY when they cover EVERY day of the window for EVERY branch in scope (one counter per day — a missing day means "not rolled up yet", a zero day means "rolled up, nothing sold"). Anything short falls back to the live computation for the WHOLE window — a partial counter set is never mixed with live figures (the two would double-count or disagree). Stock value, outstanding, expiry loss, slow movers and expenses always stay live — no counter covers them.
- The screen says which path it took (`AdvancedReportData.countersUsed` / `counterDays`): "Pre-aggregated daily counters • N day(s) covered" vs "Live computed — no daily counters yet for this window", so a stale-looking figure is never mistaken for a counter-backed one. `ProfitLoss.copyWith` / `BranchAnalyticsRow.copyWith` re-derive gross/net from overridden revenue/COGS so a counter-backed row can never disagree with its inputs.
- **Bug found by the tests:** `weeklyTrendFromCounters` first chunked the flat per-branch counter list by 7 — an org-wide scope (2 counters/day) produced 9 buckets instead of 5. Fixed by grouping counters by calendar day first, then chunking days into 7-day buckets; single-branch input is unchanged.

## D107. One page size, two paging shapes (Week 3 Day 3)
- **Page size is 10 everywhere** (`reportPageSize`): report tables, sales history, counter pages — one number so a page means the same thing on desktop and mobile and in the mock and Firestore implementations.
- **In-memory lists** (`paginateList`): 1-based index pages, clamped into range; an empty list is one empty page so the screen still renders its empty state. **Repository reads** (`paginate` cursor pages): id-cursor pages mirroring the transport's `startAfterId` — the mock counter repo pages this way so its page boundaries match the Firestore repo's exactly (chained to all 30 days, no duplicates, pinned by tests).
- **Widget:** `PagedList` / `PagedListControls` — Previous/Next + "Page x of y", buttons disabled at the boundaries (no wrap-around, no dead tap). Applied to the reports screen's daily sales, low stock, expiry (expired + expiring combined, expired first), weekly trend, branch comparison, slow movers and expenses lists — replacing the old `take(20)` / `take(10)` truncations — and to sales history. Best sellers stays unpaged (capped at 10 by the computation itself).
- **Firestore side:** `listDailyCountersPaged` uses the transport's paged fetch (document-id order, oldest first). The counters collection also holds the sequential-number docs (`invoices`, `orders`, …), so pages are filtered to `daily-*` ids and fetching continues until the page is full or the collection is exhausted — a page is never short just because a sequential counter sorted in between.

## D108. Sync-status UI never fakes a sync (Week 3 Day 3)
- `SyncStatusChip` (reusable, compact) reads live from the production data layer: pending operations via `pendingSyncOperations()` and last-sync time via `ProductionDataLayer.lastSyncAt` → `SyncQueue.lastSyncedAt`, which is set ONLY when `processNext` actually syncs an operation (never on enqueue, never on a failed send). Until the Firebase project exists the queue is only enqueued, never drained — so the demo honestly shows "Never synced" instead of an invented time.
- **States:** queue empty → "All synced"; pending → "N pending sync" (never "synced"); nothing ever synced → "Last sync" reads "Never synced"; the queue store throws → "Sync status unavailable" (the provider resolves the failure to `available: false` instead of throwing, so the chip renders instead of crashing the screen). Tapping the chip refreshes it; the notifiers that write through the layer (POS sale, order creation, goods receiving) invalidate `syncStatusProvider` after a successful write.
- **Last-sync format:** "HH:MM" today, "d/M HH:MM" on another day.

## D109. Sync-status placement: survey of which screens write through the queue (Week 3 Day 3)
- **Writes through the layer's sync queue (chip placed, live count moves):** POS (`commitSale` enqueues one sale payload), orders (`createOrder` enqueues one order payload), purchases receiving (`receiveGoods` enqueues one batched-write payload, D103). The chip sits under each screen's header.
- **Inventory (chip placed, documented caveat):** stock receive / adjust today write to the inventory repo directly, NOT through the layer or the queue — so the chip there surfaces the queue state where stock work happens and reads "All synced" until a queued write from another screen exists. It is placed anyway because inventory is offline-capable and the queue state is what its user needs to see; routing inventory receive/adjust through the layer so they enqueue (like receiving does) is a Day 4 follow-up, not smuggled into this day.
- **Not placed:** returns restock goes through `layer.adjustStock`, which (like inventory adjust) enqueues nothing — so no chip on the returns screens; adding one would show a count that never moves for returns work. Sales history, dashboard and reports only read — no chip.

## D110. Windows desktop verification: sqflite_common_ffi + no firebase_messaging in the entry path (Week 3 Day 4)
- **sqflite_common_ffi wired:** `sqflite_common_ffi ^2.4.7` added to pubspec (with `sqlite3`); `lib/app/desktop_bootstrap.dart` exports `initDesktopPlatform()`, which on Windows only calls `sqfliteFfiInit()` and sets the global `databaseFactory = databaseFactoryFfi` before the app widget is built. `lib/main_desktop.dart` is now `async` (`WidgetsFlutterBinding.ensureInitialized()` first) and awaits it. The sync store then opens a real SQLite file on Windows instead of falling back to memory — the `SqfliteSyncStore` in-memory fallback stays only as a safety net for a genuinely broken SQLite setup (its comment is updated to say so).
- **Windows-only on purpose:** Android/iOS keep the platform implementation; the web entry point never imports the bootstrap file, so the web build never sees `dart:io` or `sqflite` (same conditional-import rule as `sync_store_web.dart`, D61-adjacent). On any non-Windows host the init is a no-op that returns immediately (tested on this Linux sandbox).
- **firebase_messaging check (D4 closed for the entry path):** a grep over `lib/` finds NO Dart file importing `package:firebase_messaging` — only the two doc comments in `main_desktop.dart` / `desktop_app.dart` mention it. Nothing in the desktop entry path can hit the missing Windows plugin; push stays out of scope and Firestore live reads stay the desktop update path. `main_desktop.dart` now records the verification in its header comment.
- **Not verified here:** `flutter build windows` cannot run on this Linux sandbox (D11) — the CI job `build-windows` owns that check (D113). No Windows binary has been built yet; do not claim one exists until that CI run goes green.
- **Stale comment fixed:** `main_desktop.dart`'s "Phase 3 target — foundation shell only" line is retired; the desktop entry renders the full shared shell (sidebar + top bar) and every routed screen.

## D111. Inventory receive/adjust (and returns restock) enqueue sync payloads — closes D109 (Week 3 Day 4)
- **Layer methods:** `ProductionDataLayer.receiveStock` (new) and `adjustStock` (extended) are now the single write paths for standalone stock receive / adjust, the same way `receiveGoods` (D103) is for PO receiving. Each enqueues one batched-write sync payload: receive → batch doc + stock-transaction doc (`create`); adjust → stock-transaction doc + inventory-doc quantity update (`update`). The Day 3 sync-status chip on the inventory screen now moves for stock work, and returns restock — which already calls `layer.adjustStock` — enqueues for free, with the sale id carried into the payload as the movement's `referenceId`.
- **Idempotency:** both methods take an optional `idempotencyKey` (minted per call when omitted) and keep a registry like the receipt registry (D103): a same-key retry returns the original batch / movement and moves no stock twice. The registry check for receive runs BEFORE the repo write — the inventory repo creates a new batch row per call, so checking after would already have duplicated the batch.
- **Engine ordering (bug avoided by the tests):** `receiveStock` loads the engine from live stock BEFORE the repo creates the batch — `loadBatches` resets the counters from the physical rows, so loading after the create and then booking the receive would count the new batch twice. The test pins the counter at seeded-on-hand + received (not +2×). Same order as `receiveGoods`.
- **Reference type:** `InventoryEngine.receive` gains an optional `referenceType` (default `goodsReceipt`, unchanged for PO receiving). A standalone receive passes `stockReceive` with the idempotency key as the reference id — a manual receive has no `goodsReceipts` document, so the key stands in for a receipt id instead of mislabelling the movement as a goods receipt.
- **Notifier routing:** `InventoryNotifier.receiveStock` / `adjustStock` call the layer (actor from the signed-in user, demo fallback) and invalidate `syncStatusProvider` after a successful write, like the POS / orders / purchases notifiers (D108). The notifier signatures are unchanged (`receiveStock` returns the created batch; `adjustStock` returns the updated row or `null` on rejection) — the dialogs and the medicine-detail receive call need no changes. `commitSale`'s repo-direct decrements are untouched: they belong to the sale's own payload.
- **Not routed (follow-up):** `recordStockCount` still writes repo-direct — same routing, left for Day 5 QA so this day's diff stays reviewable. The D54 gap also still applies at the UI level: the dialogs mint a fresh key per submit, so a retry after a failed submit uses a new key (same posture as POS before the dialog-held key).

## D112. Salary edit flow (Week 3 Day 4, closes the Day 2 edit follow-up)
- **Write path:** `SalaryNotifier.saveRecord` (returns `(record, error)` like the returns notifier) gates on `canManageSalary` (`hrSalary` write: Owner / HO Admin / Accountant in-branch; Auditor read-only; everyone else none — the matrix, D70/D102, read from `PermissionService` via `salary_logic.dart`), validates with `validateSalaryRecord`, then calls `saveSalaryRecord` and refreshes. The repository still re-checks the same rules (D100 pattern).
- **UI:** one Edit button per salary row, rendered only when `canManageSalary` passes for that row's branch; the dialog (`salary_edit_dialog.dart`, same AlertDialog + `PharmaTextField` pattern as the stock dialogs) edits base / allowances / deductions in whole rupees with a live net preview (`Net = base + allowances − deductions`, never negative). Saving creates the record when the month has none, or replaces it (keyed by employee + month, never a duplicate). A SnackBar confirms the save with the new net.
- **Edited demo figures stop being demo:** a saved record has `isDemo: false` — the figures are staff-entered now, not the seeded sample payroll — so the row's Demo badge clears and the monthly totals move. The dialog says so when the row currently shows demo figures.
- **Not built:** no payroll history view, no bulk edit, no approval step for salary changes — the SRS names no approval flow for salary edits and none was invented. The dialog's gate is re-checked in the notifier, so a dialog opened by any other path still cannot save without `hrSalary` write.

## D113. CI Windows build job (Week 3 Day 4)
- **New job `build-windows`** in `.github/workflows/build-apk.yml` (the existing `build-apk` job is untouched — same steps, still the APK path): `windows-latest` runner, checkout, JDK 17 (Temurin), Flutter 3.47.7, `flutter pub get`, `flutter analyze`, `flutter build windows --release -t lib/main_desktop.dart`, upload `build/windows/x64/runner/Release` as the `pharmadesk-windows` artifact (30-day retention, same as the APK). The APK job owns the test run; this job owns the desktop binary.
- **First run is the verification:** the first push containing this job exercises it — until that run goes green, no Windows build claim is made (D110). The workflow YAML parses cleanly (validated with `yaml.safe_load` in the sandbox); the job itself can only run on a Windows runner.

## D114. Stock count through the production data layer — closes the D111 follow-up (Week 3 Day 5)
- **Layer method:** `ProductionDataLayer.recordStockCount` is now the single write path for physical stock counts, the same way `receiveStock` / `adjustStock` (D111) are for receive / adjust. The variance (counted − system) is booked through the engine (`adjust`, reason "Stock count", ledger movement + audit) and the repository is set to the counted quantity — the same end state as the old repo-direct write, now with a ledger trail and an audit entry.
- **Idempotency:** optional `idempotencyKey` + a registry like the receive/adjust registries (D111): a same-key retry returns the original count and applies no correction twice. The count dialog holds one key across retries (D115).
- **Zero variance:** a count that matches the system books no movement and enqueues no sync payload — there is no quantity change to sync. The repo write still happens (it stamps `updatedAt`).
- **Sync:** a non-zero correction enqueues one sync payload (stock-transaction doc + inventory-doc update — the same payload shape as an adjustment, via the shared `_enqueueAdjustSync`), so the Day 3 sync-status chip moves for stock counts. With this, every inventory write path (POS sale, order, goods receiving, receive, adjust, count, returns restock) enqueues — the D109 survey has no repo-direct writer left on an offline-capable screen.
- **Notifier routing:** `InventoryNotifier.recordStockCount` calls the layer (actor from the signed-in user, demo fallback) and invalidates `syncStatusProvider` after a successful write, like receive/adjust (D111). Signature gains only the optional key; the `(item, variance)` return and the `null`-on-rejection contract are unchanged, so the dialog and the medicine-detail caller need no changes.

## D115. Dialog-held idempotency keys — closes the D54 UI gap for the stock dialogs (Week 3 Day 5)
- **The gap (D54):** the layer dedupes on the key, but the stock dialogs minted a fresh key per submit (the layer minted one per call), so a retry after a failed submit would NOT dedupe — the same posture POS had before its dialog-held key (Week 2 Day 3).
- **Fix:** each of the three stock dialogs (`_ReceiveStockDialog`, `_AdjustStockDialog`, `_StockCountDialog`) mints one key in its state (`late final`, `newIdempotencyKey('stock-receive-…' / 'stock-adjust-…' / 'stock-count-…')`) and passes it through the notifier (which gains an optional `idempotencyKey` on all three methods, forwarded to the layer) on every submit. Same pattern as the PO receiving dialog's held key (D103) and the POS held sale key. D54 is now closed for every dialog that writes through the layer.
- **Receive dialog could not retry at all:** its `_save` had no error handling — a layer throw left the dialog stuck on loading with the button disabled, so the held key would have been moot. `_save` now catches the failure, shows "Receive failed — please try again.", and re-enables the button; the retry reuses the held key. The adjust/count dialogs already handled a null return this way; only the receive dialog needed the catch.
- **Scope note:** the returns restock path calls `layer.adjustStock` without an explicit key (one shot per return, no retry UI) — unchanged, same as before.

## D116. Phase 8 QA start: route-walk coverage + phone-width top-bar overflow (Week 3 Day 5)
- **Route-walk coverage is now complete:** the Day 7 walk (15 module routes) + the Day 4 desktop audit (19 routes) left 11 routes unwalked — the new/order/edit forms, the detail routes and the returns routes. The Day 5 QA walk covers all 11 (`/orders/new`, `/orders/:id`, `/orders/:id/edit`, `/customers/:id`, `/suppliers/:id`, `/purchases/new`, `/purchases/:id`, `/prescriptions/:id`, `/billing/returns`, `/billing/returns/new`, `/billing/receipt/:id`) with a per-screen marker, no placeholder and no "Page not found". Every route in the router is now walked by at least one test.
- **QA finding — top bar overflows at phone widths (documented, NOT fixed):** at a 390px viewport the shared shell top bar overflows by 236px on the right (brand mark + app name + branch switcher up to 180px + DEMO MODE badge + three icon buttons do not fit). Every shell screen is affected — it is the shared `_TopBar`, not one screen. It was never caught before because every mobile test ran at 800px wide. The fix is a responsive top-bar pass (hide the app-name text and shrink the branch-switcher cap below ~600px); it is NOT a one-line fix, and the DEMO MODE badge must stay visible on every screen (SRS §8.2), so the change needs care — recorded as a follow-up, not half-fixed in the QA day. The mobile More-sheet entries are verified at the established 800px mobile test width instead.
- **Doc correction (no D-number):** D110's "Not verified here" line cited "(D11)" for the sandbox Windows-build block; the citation is corrected to D52 per the Day 5 brief (D52 documents the sandbox build block).
