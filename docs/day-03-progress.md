# PharmaDesk — Day 3 Progress Report (Week 1 sprint, 24 Nov 2026)

Day 3 of the 7-day UI/UX, frontend & Firebase foundation sprint.
Status: **complete, verified** (see Verification below).

## What was built

### 1. Demo authentication (`lib/features/authentication/`)
Mock auth only — no Firebase project exists, no backend calls. The
signed-in demo user lives in `authProvider` (Riverpod) for the session.
- `auth_state.dart` — `DemoRole` (Owner, Branch Manager, Pharmacist,
  Cashier, Inventory Manager), `DemoUser`, the 5 demo accounts (all
  password `demo1234`, see `docs/demo-guide.md`), `AuthNotifier`:
  email/password sign-in (unknown email / wrong password errors),
  one-tap demo sign-in, sign-out, and a working mock forgot-password
  flow (deterministic 6-digit reset code per email; a successful reset
  replaces the in-memory password for the session, so the new password
  signs in afterwards). Branch-scoped roles start in their home branch
  on sign-in; the owner keeps the active branch.
- `splash_screen.dart` — branded white-label splash (brand initial +
  app/organization name, DEMO MODE badge, spinner), 1.2s, then routes
  to the dashboard when a demo session exists, else to login.
- `login_screen.dart` — validated email/password form (email format,
  password ≥ 6 chars, error banner), "Forgot password?" link, and the
  5 one-tap demo-account cards (role, person, email, description) with
  the demo password shown on screen.
- `forgot_password_screen.dart` — honest mock flow in 3 steps: enter
  a demo email → the screen shows the demo reset code with a clear
  "no email is sent in the demo" notice → enter code + new password →
  success step with "Sign in now". Unknown emails and wrong codes are
  rejected; never a dead button.
- `profile_screen.dart` — the real Profile screen: signed-in user
  (name, email, role, branch), DEMO MODE badge, sign-out button; an
  empty state with a working way to sign in when nobody is signed in.

### 2. DEMO MODE indicator (SRS §8.2)
New `DemoModeBadge` (`lib/core/widgets/demo_mode_badge.dart`, exported
from the design-system barrel): a warning-amber "DEMO MODE" pill. It
is in the app-shell top bar (so every module screen carries it) and on
the splash, login and forgot-password screens, which sit outside the
shell. The sidebar footer already said "Demo mode — mock data".

### 3. Routing + shell (`lib/core/routing/app_router.dart`, app entries)
- `/splash`, `/login`, `/forgot-password` live outside the `ShellRoute`.
- Auth guard via `redirect` + `AuthRefreshNotifier` (a `ChangeNotifier`
  the app entries bump when `authProvider` changes): signed-out users
  are sent to `/login`, signed-in users are kept out of the auth pages.
  `createAppRouter()` without `isSignedIn` stays ungated (router-only
  tests); the dashboard then falls back to the branch view.
- `/dashboard` → real `DashboardScreen`; `/profile` → real
  `ProfileScreen`; `/authentication` redirects to `/login`.
- Shell top bar: profile icon is now a menu (signed-in name/role,
  Profile, Sign out; "Sign in" when signed out). The three app entries
  (`PharmaDeskApp`, `AdminApp`, `DesktopApp`) all wire the auth
  refresh the same way.

### 4. Demo seed data (`lib/core/services/demo_seed_data.dart`)
Deterministic (fixed `Random` seeds) and relative to `DateTime.now()`,
so "today" always has sales while figures are stable across runs.
- 14 sample medicines (the 3 Day 1 medicines unchanged), 8 sample
  customers, 4 sample suppliers (balances in int minor units).
- 499 orders over the last 30 days across both branches — DHA busier
  (8–13/day) than Gulberg (4–7/day); today is a live mix of statuses,
  past days mostly delivered with a few cancelled.
- Per-branch inventory (one row per medicine per branch) with mixed
  expiry: most far out, ~25% near-expiry (10–29 days), some within
  days, a few already expired; ~20% of rows at/below the low-stock
  threshold.
- 20 sample prescriptions (10 per branch): pending / approved /
  rejected / needs-clearer-photo mix. `imageUrl` is a demo placeholder
  label, not a real photo (Spark has no Cloud Storage — D2).
- Repositories (`lib/core/services/repositories.dart`) now serve the
  seed data; `OrderRepository.getOrders` filters by branch; new
  `getInventory` on the inventory repo; new `CustomerRepository`,
  `SupplierRepository`, `PrescriptionRepository` (+ providers) for the
  later days. New `Supplier` model (`lib/models/supplier.dart`, money
  in int minor units).

### 5. Dashboards (`lib/features/dashboard/`)
All figures computed from the mock data — nothing hardcoded
(`dashboard_data.dart`: pure, unit-tested `computeDashboardKpis`).
Money is int minor units throughout (Day 0 doubles converted at the
boundary with `rupeesToMinorUnits`).
- **Owner dashboard**: today's sales/orders, 30-day revenue/orders,
  low-stock + near-expiry counts (with expired count), 30-day sales
  bar chart (plain Flutter widgets, no chart package), per-branch
  performance (tap a branch → switches the active branch and opens
  its orders), top-selling medicines, recent orders, alerts.
- **Branch dashboard** (Manager / Pharmacist / Cashier / Inventory
  Manager, scoped to the active branch): today's branch sales/orders,
  pending prescriptions, low-stock + near-expiry, role-ordered quick
  actions (Cashier: New Sale first; Pharmacist: Prescriptions first;
  Inventory Manager: Stock Check first), chart, top sellers, recent
  orders, alerts. Every card/action navigates to a working destination
  (module screens are placeholders until their day — navigation lands).
- `widgets/sales_chart.dart` — 30-bar chart, today highlighted.

Verified live figures (24 Nov 2026 run): 499 orders; owner today
Rs 23,970.00 / 14 orders; 30-day revenue Rs 852,490.00 / 451 orders;
low stock 3, near-expiry 13, expired 2, pending prescriptions 6
(DHA 3, Gulberg 3). DHA today Rs 20,630.00 / 11 orders; Gulberg
Rs 3,340.00 / 3 orders. Top sellers: Augmentin, Concor, Glucophage,
Risek, Ca-C 1000.

### 6. Fixes found by testing (not just tests)
- `StatCard` (Day 2 component): long money values ("Rs 1,234,567.00")
  wrapped to a second line and overflowed KPI grid cells — the value
  is now scaled down with a `FittedBox` instead of wrapping.
- KPI grid used `childAspectRatio`, which made wide-screen cells too
  short — now a fixed `mainAxisExtent` (200).
- Dashboard providers fetched prescriptions unscoped, so branch
  dashboards showed the all-branches pending count — now fetched
  branch-scoped (D21).

## Files created / changed
- Created: `lib/core/widgets/demo_mode_badge.dart`,
  `lib/core/services/demo_seed_data.dart`,
  `lib/models/supplier.dart`,
  `lib/features/authentication/{auth_state,splash_screen,login_screen,forgot_password_screen,profile_screen}.dart`,
  `lib/features/dashboard/{dashboard_data,dashboard_screen}.dart`,
  `lib/features/dashboard/widgets/sales_chart.dart`,
  `test/test_helpers.dart`, `test/day_03_test.dart`,
  `docs/day-03-progress.md`, `docs/demo-guide.md`.
- Changed: `lib/core/routing/app_router.dart`,
  `lib/app/{pharmadesk_app,admin_app,desktop_app}.dart`,
  `lib/app/shell/app_shell.dart` (DEMO MODE badge, profile menu),
  `lib/core/services/repositories.dart`,
  `lib/core/widgets/{design_system,stat_card}.dart`,
  `lib/models/models.dart`,
  `test/{day_02_test,widget_test}.dart` (auth-gated flow: sign in
  before asserting on the shell; dashboard expectations),
  `docs/technical-decisions.md` (D19–D24),
  `docs/sprint-tracker.md`.
- Deleted: `lib/features/{authentication,dashboard}/.gitkeep`
  (superseded by real files).

## Verification (24 Nov 2026)
- `flutter analyze` — **No issues found!**
- `flutter test` — **47/47 passed** (4 Day 1 smoke + 13 Day 2 shell/
  component + 30 Day 3: mock auth incl. reset flow, splash/login/
  forgot-password widget flows, demo login per role, KPI computation
  incl. branch scoping + cancelled-order exclusion, seed-data sanity,
  owner/branch dashboard rendering + branch switching + quick-action
  navigation, auth redirect both directions, DEMO MODE badge).
- `flutter build web --release` — **PASSED** (133.7s compile;
  `build/web/main.dart.js` 2,729,264 bytes; title PharmaDesk).
- `flutter build apk` — **NOT attempted** (environment-blocked, D14/D15).
- `flutter build windows` / `flutter build ios` — not possible on this
  Linux VM; must be verified on real Windows/macOS hardware.

## Blockers
Same as Day 1–2 — none new, none Day 3 can clear:
1. **Firebase project does not exist** (Dazy's call; see
   `docs/firebase-setup-plan.md`).
2. **GitHub repo not created** (name/visibility Dazy's call).
3. **Hadi's requirements still awaited** (medicines count, delivery
   areas, payment method, branch cities, logo + brand colours).
4. **APK build environment-blocked** (D14/D15; Day 3 work does not
   depend on it).

## Next step
- **Day 4 (25 Nov):** orders — status flow New → Confirmed →
  Processing → Ready → Dispatched → Delivered → Cancelled (align the
  Day 0 enum per D10), manual phone/WhatsApp entry, NO WhatsApp API.
  Day 4 builds on the Day 3 dashboards (recent-orders rows and quick
  actions already navigate to `/orders`).
