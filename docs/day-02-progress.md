# PharmaDesk — Day 2 Progress Report (Week 1 sprint, 24 Nov 2026)

Day 2 of the 7-day UI/UX, frontend & Firebase foundation sprint.
Status: **complete, verified** (see Verification below).

## What was built

### 1. Design-system components (`lib/core/widgets/`, barrel `design_system.dart`)
All built on the Day 1 Kalora theme (`AppColors`, Inter, light + dark
`AppTheme`); components use theme colours, so every one renders in both
light and dark themes. No hardcoded hex in widgets.
- `buttons.dart` — `PharmaButton`: primary / secondary / danger / text
  variants, small + medium sizes, icon support, loading spinner state
  (disables taps while loading), optional full-width.
- `cards.dart` — `PharmaCard`: theme card style (12px radius, soft
  border), optional tap.
- `fields.dart` — `PharmaTextField` (label/hint/validation, wraps
  `TextFormField`) and `PharmaSearchField` (search icon + clear button
  that appears only while text is present).
- `badges.dart` — `StatusKind` (success / warning / danger / info /
  neutral) mapped to the Kalora palette, `StatusBadge` pill (dot +
  label, tinted background) and `PharmaChip` (selectable filter chip).
- `data_table.dart` — `PharmaDataTable<T>`: sortable columns
  (internal sort state, ascending/descending on header tap), horizontal
  scroll, built-in empty state when there are no rows.
- `dialogs.dart` — `showConfirmDialog` (returns `bool?`, danger variant
  turns the confirm button red) and `showPharmaFormDialog`.
- `loading.dart` — `ShimmerBox` (repeating pulse, no extra package),
  `SkeletonCard`, `SkeletonList`.
- `empty_state.dart` — `PharmaEmptyState`: icon + title + message +
  optional action button (no blank screens anywhere).
- `section_header.dart` — `SectionHeader`: title + subtitle + optional
  action button.
- `stat_card.dart` — `StatCard`: label, big value, icon, optional
  trend line; money via `moneyMinorUnits` (int paisa, `formatPkr`) —
  never doubles.

### 2. Branch context (`lib/core/services/branch_context.dart`)
- Two demo branches per SRS §8 (fictional): **Demo Branch — DHA**
  (`branch-dha-main` — same id as the Day 1 mock repos' sample data)
  and **Demo Branch — Gulberg** (`branch-demo-gulberg`).
- `activeBranchProvider` (Riverpod `Notifier<Branch>`): `switchTo(id)`
  changes the active branch; unknown ids are ignored.

### 3. Application shell (`lib/app/shell/app_shell.dart`)
- **Desktop (≥900px width)** — sidebar navigation + top bar. Used by
  the desktop entry and the web admin (wide screens render the desktop
  layout automatically).
- **Mobile (<900px)** — top bar + bottom navigation (Dashboard, Orders,
  Billing, Medicines, More); "More" opens a bottom sheet listing all
  14 modules.
- **Sidebar** — grouped navigation (Main / Manage / Insights / System),
  renders the active `BrandConfig` (brand initial avatar, app name,
  organization name in brand colours), selected-item highlight,
  "Demo mode — mock data" footer.
- **Top bar** — brand mark (white-label initial + app name), **branch
  switcher** (popup menu over the 2 demo branches, radio-marked active
  branch; switching updates `activeBranchProvider`, and every screen
  reading it — e.g. the module placeholder's branch chip — changes
  immediately), **theme menu** (Light / Dark / System, writes to the
  existing in-memory `themeModeProvider`), notifications + profile
  shortcuts (both navigate).
- **White-label**: the shell reads `brandConfigProvider` everywhere
  (top bar, sidebar, theme seed). A `BrandConfig.fazalDin` override
  rebrands the whole shell — covered by a widget test.

### 4. Navigation wiring (`lib/core/routing/app_router.dart`)
- `createAppRouter()` builds a fresh `GoRouter` per app instance:
  `/` redirects to `/dashboard`; all 14 module routes live inside a
  `ShellRoute` rendering `AppShell`, so nav state follows the route.
- Unknown routes show a "Page not found" screen with a working
  "Go to Dashboard" button — never a dead end.
- Each entry point owns its router instance (created once in
  `initState`): `PharmaDeskApp`, `AdminApp`, `DesktopApp` are now
  `ConsumerStatefulWidget`s. Reason: one shared global router cannot
  be reused across separate `MaterialApp.router` widgets (see D16).
- `lib/app/foundation_home.dart` (Day 1 hub) **deleted** — the shell
  replaces it; keeping both would be two versions of the truth.
- Module placeholder screens (`lib/shared/widgets/`) rebuilt from the
  design system (section header + status badges + empty state) and now
  show the active branch chip, so branch switching is visible on every
  module screen. Screens themselves stay placeholders until their day
  (Days 3–7); the navigation wiring is what Day 2 delivers.

## Files created / changed
- Created: `lib/core/services/branch_context.dart`,
  `lib/core/widgets/{buttons,cards,fields,badges,data_table,dialogs,
  loading,empty_state,section_header,stat_card,design_system}.dart`,
  `lib/app/shell/app_shell.dart`, `test/day_02_test.dart`.
- Changed: `lib/core/routing/app_router.dart`,
  `lib/app/{pharmadesk_app,admin_app,desktop_app}.dart`,
  `lib/shared/widgets/module_placeholder_screen.dart`,
  `test/widget_test.dart` (updated for the shell),
  `docs/technical-decisions.md` (D16–D18), `docs/sprint-tracker.md`.
- Deleted: `lib/app/foundation_home.dart` (superseded by the shell).

## Verification (24 Nov 2026)
- `flutter analyze` — **No issues found!**
- `flutter test` — **17/17 passed** (4 Day 1 smoke tests updated for
  the shell + 13 new Day 2 tests: buttons incl. loading/disabled,
  stat card money formatting, search-field clear, data-table sorting +
  empty state, confirm dialog true/false, dark-theme rendering of
  empty state / section header / badges / shimmer, desktop sidebar
  all-14-modules + navigation, branch switching, theme switching
  light/dark/system, mobile bottom nav + More sheet, white-label
  default brand, Fazal Din brand override, unknown-route screen).
- `flutter build web --release` — **PASSED** (137.7s compile;
  `build/web/main.dart.js` 2,350,334 bytes; title PharmaDesk).
- `flutter build apk` — **NOT attempted** (environment-blocked, D14/D15).
- `flutter build windows` / `flutter build ios` — not possible on this
  Linux VM; must be verified on real Windows/macOS hardware.

## Blockers
Same as Day 1 — none new, none Day 2 can clear:
1. **Firebase project does not exist** (Dazy's call; see
   `docs/firebase-setup-plan.md`).
2. **GitHub repo not created** (name/visibility Dazy's call).
3. **Hadi's requirements still awaited** (medicines count, delivery
   areas, payment method, branch cities, logo + brand colours).
4. **APK build environment-blocked** (Gradle kotlin-dsl plugin download
   through the sandbox proxy — D14/D15; Day 2 work does not depend on it).

## Next step
- **Day 3 (24–25 Nov):** splash / login / forgot-password / demo login
  + owner & staff dashboards on sample data (every card/action works).
  Day 3 builds on the Day 2 shell and components — no new shell work
  is needed; the dashboard route currently shows the Day 1 placeholder.
