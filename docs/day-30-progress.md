# Day 30 Progress — Active-branch directory support + branch code validation (Week 6 Day 3)

**Date:** 26 Nov 2026. **Status:** done. Decisions: **D163** (active-branch directory resolution), **D164** (Branch `code` + mapper §3 validation). Full detail in `docs/technical-decisions.md`.

## What changed

### Part A — ActiveBranchNotifier resolves the directory (D163)

- `ActiveBranchNotifier.switchTo` now resolves the id against the branch directory first (the directory seeds from `demoBranches` and holds every branch added through Branch Management) and falls back to `demoBranches`. A directory-added branch can now become the active branch — previously impossible.
- The lookup is a one-shot `ref.read(branchDirectoryProvider)` inside `switchTo`, never a `ref.watch` in `build()`: watching the directory from `build()` would rebuild the notifier (resetting the active branch to the first demo branch) on every directory change and would put a build-time edge between the two providers. The provider graph stays acyclic (verified: no `activeBranchProvider` reference in `lib/core/data/`); the new static Dart import cycle `branch_context ↔ branch_directory` is documented as harmless (both files' top-levels are `const`/lazy; the codebase already carries five such cycles).
- `switchTo` now returns `bool`: `true` = switched, `false` = unknown id, active branch left unchanged (previously silently ignored). The four existing callers (shell switcher, dashboard branch row, sign-in home branch, settings) ignore the return value and work unchanged.
- A deactivated branch CAN become active: FR-HO-08 guards transactions, not viewing — its history stays readable (same as the franchise view, D158).
- The shell branch switcher (`_BranchSwitcher`) now watches `branchDirectoryProvider` and lists the directory instead of the `demoBranches` const, so a directory-added branch is selectable in the UI.
- Known limitation: `switchTo` resolves the in-memory directory snapshot; a branch persisted by an earlier session is switchable once the directory's initial async `refresh()` lands (same timing as the branch list screen itself). A switch attempted before that returns `false`, state unchanged, no crash.

### Part B — Branch mapper §3 code validation (D164)

- `Branch` gains `code` (`final String`, default `''` = not set; constructor stays `const`). `effectiveCode` returns the stored code when valid, otherwise the migration-safe default derived from the id. `copyWith` gains `code`; `toMap` writes `effectiveCode`, so a backup export never carries an empty code.
- Validation (pure functions in `lib/models/branch.dart`): a code is valid when 2–8 uppercase letters/digits. `normalizeBranchCode` trims + uppercases (`'dha'` → `'DHA'`); missing/invalid codes fall back to `defaultBranchCodeForId` — never throws, never empty. Default derivation: `dha` → `DHA`, `gulberg`/`glb` → `GLB`, else last dash-segment up to 3 chars (`branch-model-town` → `TOW`), segment initials for a one-letter last segment (`branch-x` → `BX`). Demo branches carry explicit codes (`DHA` / `GLB`).
- `branchToFirestore` now writes `'code': branch.effectiveCode` and DOES `validateOrThrow('branches', doc)` — the D148 blocker (model had no `code`) is gone. `branchFromFirestore` normalizes the same way, so legacy docs without (or with an invalid) code read back with the derived default.
- One derivation, not two: `FirestoreBranchRepository._fallbackBranchCode` delegates to `defaultBranchCodeForId`; `branchCode()` still prefers the doc's `code` field.
- `MockBranchRepository`: `_withId` carries the code normalized against the NEW id (a minted `branch-<slug>` id derives its own code — deriving from the pre-mint empty id would have given `XX`); `updateBranch` never stores an empty code. Also fixed the stale `_withId` comment (it claimed `copyWith` had no `id` parameter — D148 added it).
- §3 schema `branches.code` field note now records the mapper behaviour. Firestore rules need no change (`validBranchDoc` does not constrain `code`).
- NOT done here (Day 31 scope): the add/edit branch form has no code field — a form-built branch gets the derived default; `Supplier.createdAt`, `Order.orderNumber`/`idempotencyKey` are the other Day 24 model gaps.

### Part C — Super Admin franchise-view gate: SKIPPED, still open

No Dazy decision is recorded anywhere in `docs/` — `week-6-brief.md` §3, D159 and the Week 5 tracker all say "pending Dazy's decision". Per the brief, nothing was guessed or built. The gate stays as Day 27 left it: Super Admin / Owner / HO Admin pass the franchise view on write-level `branches`; Auditor excluded. This item stays open in the Week 6 tracker follow-ups.

## Files

| File | Change |
|---|---|
| `lib/models/branch.dart` | `code` field + `effectiveCode`, `defaultBranchCodeForId` / `normalizeBranchCode`, `fromMap`/`toMap`/`copyWith` |
| `lib/core/services/branch_context.dart` | Demo branches gain codes; `switchTo` resolves the directory, returns `bool` (D163) |
| `lib/app/shell/app_shell.dart` | Switcher lists `branchDirectoryProvider` (D163) |
| `lib/core/data/firestore_mappers.dart` | Branch mapper writes + validates `code`, legacy-safe read (D164) |
| `lib/core/data/firestore_repositories.dart` | `_fallbackBranchCode` delegates to the shared derivation (D164) |
| `lib/core/services/repositories.dart` | Mock branch repo carries/normalizes the code (D164) |
| `lib/core/data/firestore_schema.dart` | `branches.code` field note records the mapper behaviour |
| `test/week6_day03_test.dart` | 17 new tests (below) |
| `docs/technical-decisions.md` | D163, D164 |
| `docs/week-6-tracker.md` | Day 30 section |

## Verification (measured by the builder, coordinator re-runs)

- `flutter analyze`: **clean** — "No issues found!" (one unused import in the new test file found on the first run, removed, re-verified clean).
- Day 30 tests alone (`test/week6_day03_test.dart`): **17/17 passed** — Part A: demo switch unchanged, directory-added branch becomes active, unknown id returns `false` with state unchanged, later directory add/rename never resets the active branch, switch resolves the edited record, deactivated branch can become active, shell-switcher widget test (directory branch appears in the menu and switches). Part B: code derivation, normalization (case/space/invalid → default), model migration + `toMap`/`fromMap` round-trip, mapper round-trip + §3 validation, legacy docs (missing/lowercase/invalid code), Firestore repo round-trip over the memory transport, mock repo create (explicit + minted id) and update.
- Full cumulative suite (Weeks 1–6): **922/922 passed** (baseline 905 + 17). Measured with the new test file before the unused-import removal; after the removal, analyze is clean and the day file re-ran 17/17. The import removal touches no production or test logic.
- Fresh `flutter build web --release`: **pass** — "✓ Built build/web" (46,729,240 bytes); prescription PNGs bundled (114,613 + 110,613 bytes, 8 manifest mentions).
- Nothing pushed — parent pushes committed files via browser upload.

## Follow-ups found

- Add-branch form has no code field (Day 31 follow-up — see above).
- `switchTo` resolves the in-memory directory snapshot only (timing note above).
- Super Admin franchise-view gate still awaits Dazy's decision (Part C).
