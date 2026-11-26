# Day 18 — Week 4 Day 1 Progress (26 Nov 2026)

**Scope:** Week 4 brief §1 — D116 FIRST: the shared shell top bar
overflowed by 236px at a 390px viewport (Week 3 Day 5 QA finding).
Responsive top-bar pass, test-first. This is the first Week 4 item
and it unblocks the later 390px QA sweep.

## What shipped

### 1. Test-first reproduction (D116 confirmed failing)
- New `test/week4_day01_test.dart` (6 tests) pumps the shell at
  390×844 and asserts top-bar fit by rect: every top-bar widget
  (branch switcher, DEMO MODE badge, theme / notifications / profile
  buttons) must sit inside the 390px viewport.
- Pre-fix run: **1/6 passed** (only the 1280px desktop test). The
  failure is exactly the D116 symptom: `A RenderFlex overflowed by
  236 pixels on the right` in the `_TopBar` Row
  (`app_shell.dart:94`), constraints w=366; the DEMO MODE badge sat
  at Rect(343.0, 453.3) — 63px past the right edge. The same
  overflow also made the notifications bell untappable (it sat
  off-screen, so the tap missed and the buttons test failed on a
  missing 'Notifications' screen).

### 2. Responsive top bar (D117)
- `lib/app/shell/app_shell.dart` only — no other screen touched:
  - Below `_TopBar.compactBreakpoint` = **640px** the app-name text
    is hidden (the brand-mark initial tile stays and still
    identifies the app).
  - The branch switcher drops its store icon and its name cap
    follows the space the top bar leaves it, via `LayoutBuilder`
    (a fixed cap cannot fit both a 390px and a 360px phone). The
    popup menu itself still shows both full branch names with
    addresses.
  - The three icon buttons compact to **40px** (from 48px).
  - The DEMO MODE badge is **untouched** — full size at every
    width, on every screen (SRS §8.2). The switcher and the buttons
    give way around it instead.
  - The breakpoint is 640px, not 600px: the full bar measures
    ~615px wide, so below ~615px it overflows; 640px covers the
    whole mobile-layout range (390–899px) with margin. At or above
    it the bar is byte-for-byte the old layout, and the desktop
    layout (≥900px, sidebar + top bar) is unchanged — pinned by
    the 1280px test (app name shown, switcher ≥170px wide).
- Two framework traps found by the probe runs (both recorded in
  code comments, both would have shipped as real bugs):
  - `PopupMenuButton.constraints` sizes the popup **menu**, not the
    button — passing tight 40px constraints squeezed the profile /
    theme menus to 40px wide and broke their ListTiles ("Leading
    widget consumes the entire tile width"). The buttons shrink via
    `style` (`tapTargetSize: shrinkWrap` + 40px `minimumSize`)
    instead.
  - `IconButton` enforces a 48px tap target while its tap-target
    size is padded (the theme default) — the `constraints` parameter
    alone cannot shrink the notifications bell below 48px. Same
    `style` fix; the bell measured 48×48 before it, 40×40 after.
- One real defect caught by the probes and fixed in the same pass:
  the first LayoutBuilder cap had a 32px floor
  (`(share − 34).clamp(32, 80)`), but the pill chrome is
  36px (padding 16 + border 2 + chevron 18), so at the settled
  390px share the text (32) + chevron (18) needed 50px in a
  35.8px Row — a **14px overflow in the settled layout**, not a
  transient one (the switcher rect was 53.8px wide while its Row
  overflowed). The floor is removed
  (`(share − 36).clamp(0, 80)`): the name cap is now 25.8px in the
  widget-test environment (where the test font renders the badge
  ~142px wide) and ~60px on a real device with Inter — a truncated
  branch name is shown while the space allows, and the bar fits at
  any phone width.

### 3. Tests (6 new, all 390px unless noted)
- Dashboard top bar fits; app name hidden; badge visible;
  switcher ≤140px wide.
- Orders top bar fits; badge visible.
- Branch switcher opens and switches DHA → Gulberg at 390px
  (menu scoped by `PopupMenuItem<String>` — the dashboard body
  lists the other branch name too, and `byType` matches the exact
  reified type).
- Theme / notifications / profile buttons present and tappable at
  390px (bell navigates, theme menu opens, profile menu offers
  sign-out).
- Desktop top bar unchanged at 1280px.
- Route walk: top bar fits + badge visible on all five primary
  shell routes (`/dashboard`, `/orders`, `/billing`, `/medicines`,
  `/inventory`).
- The tests assert **top-bar fit only**. Screen-body overflows at
  390px are drained and logged, not asserted — they are Day 5
  sweep findings, recorded in §5 below, not half-fixed here.

## Verification
- `flutter analyze`: **No issues found!**
- New tests: **6/6** (`test/week4_day01_test.dart`)
- Full suite: **554/554** (Week 1 + Week 2 + Week 3 + Week 4 Day 1;
  548 before + 6 new, no earlier test touched)
- `flutter build web --release`: **Pass** (46,400,839 bytes, 186.5s
  compile)
- Prescription PNGs (D61 check): both sample PNGs in
  `build/web/assets/assets/images/prescriptions/` at their exact
  source sizes (114,613 + 110,613 bytes), 8 "prescription" mentions
  in `AssetManifest.bin`, both sample paths present.

## Decisions
D117 in `docs/technical-decisions.md`.

## Files created / changed
- Created: `test/week4_day01_test.dart`, `docs/day-18-progress.md`
- Changed: `lib/app/shell/app_shell.dart`,
  `docs/week-4-tracker.md`, `docs/technical-decisions.md`

## 390px body-overflow findings (Day 5 sweep — NOT fixed here)
Recorded by the route-walk test's drained exceptions, exact first
lines as observed (top bar is clean on all five routes — the
dashboard's earlier 14px entry was the pill defect in §2, fixed):
- `/dashboard`: clean — no body overflow at 390px.
- `/medicines`: clean — no body overflow at 390px.
- `/orders`: 1 overflow — `A RenderFlex overflowed by 12 pixels on
  the right`, sync-status chip Row
  (`lib/core/widgets/sync_status_widget.dart:178`).
- `/billing`: 2 exceptions — including a **133px** overflow in the
  shared button Row (`lib/core/widgets/buttons.dart:72`, POS action
  row); the second is grouped in the same drain.
- `/inventory`: 511 exceptions — the batch-row Rows
  (`lib/features/inventory/inventory_screen.dart:462`, 340×;
  `:368`, 169×) overflowing by 24 / 28 / 37 / 42 / 56px (plus a few
  13 / 23px ones). Every visible batch row overflows at 390px —
  the inventory list is the worst 390px screen after the top bar.

## Environment note (sandbox, not the repo)
- Mid-day the test runs hung, then failed at load with
  `FileSystemException: No space left on device` — `/tmp` (a 512 MB
  tmpfs) was 100% full with stale `flutter_tools.*` compiler dirs
  (~449 MB) plus an old `pharmadesk-apk3` scratch dir (66 MB) from
  earlier sessions. Deleted the stale dirs; `/tmp` back to 1% used
  and every run after that completed normally (~35s per file). If a
  future run hangs at loading or fails with errno 28, check
  `df -h /tmp` first — it is not a code defect.

## Follow-ups (not in Day 1)
- **Day 5 sweep:** the §5 body overflows (orders sync chip,
  billing button row, inventory batch rows) — fix there, with the
  same rect-based 390px tests extended to the bodies.
- **First CI `build-windows` run** (on the coordinator's push):
  watch it — until it goes green there is no verified Windows
  binary. (Unchanged from Week 3.)
- **Live Firestore verification** — blocked on the Firebase project
  + billing (Dazy-only step). Firestore code stays behind the mock
  default until then; no live read/write has been exercised.
