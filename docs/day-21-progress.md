# Day 21 — Week 4 Day 4 Progress (26 Nov 2026)

**Scope:** the system hub — the remaining missing screens from the
Week 3 Day 4 audit plus the last partial: D-28 Branch Management,
D-33 Audit Log, D-35 Backup & Restore, D-34 Settings completion
(Week 4 brief §2). With this day, **all 35 desktop screens
(D-01–D-35) resolve** — the audit's missing list is empty.

## What shipped

### 1. Branch Management — D-28 (D130, D131)
- `lib/features/branches/branch_list_screen.dart` (`/branches`):
  the demo branches plus any added this session, paged at 10
  (D107), with Own/Franchise and Active/Deactivated chips. Tapping
  a row opens the detail screen. Adding is write-gated (the
  Auditor sees the list but no Add button).
- `lib/features/branches/branch_detail_screen.dart`
  (`/branches/:id`): address, contact, manager, status, delivery
  areas, plus the **franchise settings** section (branch type,
  franchise fee rate, royalty rate). Edit and activate/deactivate
  are write-gated; deactivation asks for confirmation and cites
  FR-HO-08 (a deactivated branch cannot transact, history
  preserved).
- **Branch model extended with the SRS §3.1 fields** (D130):
  `Branch` gains `type` (`own` / `franchise`, default `own`),
  `managerId`, `franchiseFeeRateBps`, `royaltyRateBps` — all
  nullable, with `fromMap`/`toMap`/`copyWith` round-trips. A rate
  of `null` means "not configured" and is shown as **"Not set"**,
  never as 0%: no franchise rate, commission or royalty percentage
  was invented anywhere (FR-HO-07 is P3 — franchise commission /
  royalty tracking is Phase 2; V1 is the 8 own branches).
- **No `BranchRepository` invented** (D131): there is none in the
  codebase and the demo branches live as the `demoBranches` const,
  so the directory is an in-memory notifier
  (`branchDirectoryProvider`, seeded from the demo branches, same
  session-only posture as feature config and brand settings) with
  add / update / activate / deactivate + validation. Production
  persistence is the `branches` collection (SRS §3.1) when the
  Firestore branch repository lands — a follow-up, not smuggled in
  here. The last active branch cannot be deactivated (the app
  always needs one branch to work in).

### 2. Audit Log — D-33 (D132)
- `lib/features/audit/audit_log_screen.dart` (`/audit-log`):
  filters by branch, actor, action family and date range (All /
  Today / Last 7 days / Last 30 days), paged at 10 (D107), newest
  first, with a Refresh action. Tapping a row opens the detail
  dialog (actor, user id, branch, entity, when, summary, before →
  after — what changed).
- **The viewer reads the SAME store the writer writes** (D132):
  `ProductionDataLayer.auditEntries` — the in-memory
  `InMemoryAuditLogWriter` until the Firebase project exists (the
  Firestore implementation writes the same shape to the root
  `auditLogs` collection). There is no second audit implementation.
  The screen says the log is in-memory for the session instead of
  implying a permanent record.
- **Branch scope is enforced in the filter** (D132): Super Admin /
  Owner / HO Admin / Auditor see all branches; a Branch Manager
  sees only their own branches; everyone else sees nothing (the
  route gate already blocks them — the filter never leaks through
  either).

### 3. Backup & Restore — D-35 (D133)
- `lib/features/backup/backup_screen.dart` (`/backup`): backup
  status, manual backup, restore (admin only).
- **Status is live, not stored** (D133): a preview of what a
  backup would contain right now (section counts + total docs,
  from a fresh export of the layer) plus the last manual backup
  this session (time, size, sections). The scheduled Cloud
  Function export (SRS §2.6 — weekly full + daily incremental)
  does not exist yet — there is no Firebase project — so the
  screen says "not configured" instead of inventing a schedule.
- **Manual backup triggers the existing exporter** (D133): the
  layer's `exportBackup` / `downloadBackup` (`DataExporter`) — on
  web it downloads the JSON file; the screen never re-implements
  export. The "what is included" card lists the sections and notes
  that prescription photo bytes are NOT in the JSON backup (only
  their metadata — the bytes live in Cloud Storage, SRS §3.4).
- **Restore is admin-only and confirmed** (D133): paste a backup
  JSON document → validated first (`DataImporter.validateBackup`,
  errors shown, nothing written) → an explicit confirmation dialog
  states that it replaces the current restored data (overwrite
  policy, same id replaced never duplicated) → import into the
  layer's restore sink with the report shown (created /
  overwritten / skipped). **Limitation, stated on the screen:**
  the restore target is the in-memory restore sink — the live demo
  repositories have no upsert-by-id, so a restore does NOT
  overwrite live repo data yet. The confirmation copy says exactly
  what it replaces.

### 4. Settings completion — D-34 (D134, D136)
- `lib/features/settings/org_settings.dart`: `OrgSettings` +
  `OrgSettingsNotifier` (`orgSettingsProvider`), session-only like
  the rest of the demo settings; production persists per
  organization (`organizations/{orgId}/settings`, SRS §3.1).
  Every default is the behaviour the app already has today:
  - **Tax:** 0% — the POS charges 0% today and the SRS names no
    tax rate anywhere (only per-medicine `taxRateBps` and per-
    supplier `taxNumber`). The POS now reads this rate for new
    bills (D136 — the default is unchanged, so existing behaviour
    is identical until an owner changes the setting).
  - **Payment methods:** cash / card / credit (khata) on — what
    the POS offers today; bank transfer, JazzCash, Easypaisa off
    (FR-POS-04 names them as configurable recorded methods).
  - **Receipt format:** 80mm thermal paper (default) or 58mm,
    plus a footer line. The receipt header already lives in Brand
    Settings; this is the format, not the header.
  - **Discount limits:** both `null` = no cap — the SRS names
    role-based limits (FR-POS-03) but gives no numbers, and the
    POS enforces no cap today, so no number is invented.
- The Settings screen grew from 4 tabs to 6: **Organization**
  (tax config, payment methods, receipt format, discount limits)
  and **Sync** (D134). The Sync tab shows the live sync status
  from the layer — the same `syncStatusProvider` the sync chip
  reads (D108): pending count, last-sync time ("Never synced"
  when nothing has synced yet, never an invented time), and the
  pending operations themselves.

### 5. Routes + navigation (D135)
- Routes `/branches`, `/branches/:id`, `/audit-log`, `/backup`,
  all behind `FeatureGate`. They are sub-screens of Settings for
  navigation (sidebar + mobile More-sheet entries under Settings,
  Salary / Finance sub-item pattern) — not new modules, so the
  module count stays 16 and the feature-toggle count stays 12.
- Route gates (`routeCapability`): `/branches` → `branches`,
  `/audit-log` → `auditLog`, `/backup` → `sysSettings` — all
  existing §5.1 matrix rows, no new capability invented.
- **FeatureGate now gates non-module routes too** (D135): until
  now a route with no feature module returned its child ungated,
  which would have left the system-hub screens open to any role.
  A route with a capability mapping is now checked even when it
  has no module (no behaviour change for existing routes — none
  of them carries a capability without a module).

### 6. Older tests updated for the new reality (not regressions)
- `test/week3_day04_test.dart`: the "remaining missing desktop
  screens have no route" test is deleted — all 35 screens resolve
  now. The four new routes join the `present` list with
  body-only markers ('Add branch', 'Franchise settings', the audit
  empty message, 'Backup status').
- `test/day_07_test.dart`: route walk gains the 4 new routes; the
  feature-toggle test scrolls the six-tab Settings bar into view
  before tapping 'Features' (at 1280px the tab bar scrolls and
  the last tab sits off-screen — D24 pattern).

## Verification
- `flutter analyze`: **clean — no issues**.
- Day tests `test/week4_day04_test.dart`: **40/40** — branch
  model round-trips + defaults + rate labels, directory seed /
  add / duplicate / update / deactivate-last-active / validation,
  branch gates per role, audit filter (branch / actor / action
  family / date range / newest-first / scope / distinct lists),
  backup round-trip (export → validate → import, second import
  adds nothing, overwrite replaces, bad format/version/sections
  rejected, malformed doc aborts, section counts + size
  formatting, status notifier), org-settings defaults + bounds
  (tax / payment methods / paper width / footer / discount caps),
  route-capability map, and 11 widget tests (route walk, Settings
  Organization + Sync tabs, branch add end to end, branch detail,
  cashier stopped at all three routes, auditor read-only on
  branches + audit log and stopped at backup, sidebar entries,
  seeded audit entries render, backup create + bad-JSON error,
  restore round-trip through the confirm dialog).
- Full suite: **654/654** (615 + 40 new − 1 removed
  week3_day04 missing-screens test; no earlier test touched
  except the two intentional updates above).
- Fresh `flutter build web --release`: **pass** (182.0s,
  46,573,566 bytes); prescription PNGs bundled at **114,613 +
  110,613 bytes**, 8 "prescription" mentions in
  `AssetManifest.bin`, both paths present.

## Decisions
- D130 — Branch model gains the SRS §3.1 fields; rates nullable
  basis points, "Not set" never 0%.
- D131 — Branch directory is an in-memory notifier (no repository
  invented); last active branch protected; deactivation is the
  flag, transaction enforcement is a follow-up.
- D132 — Audit viewer reads the writer's store; branch scope
  enforced in the filter; in-memory session scope stated on the
  screen.
- D133 — Backup status is a live preview + session record;
  restore is validate → confirm → import into the restore sink
  (live repos not overwritten yet — stated on the screen);
  scheduled backups "not configured".
- D134 — Org settings defaults are today's behaviour (tax 0%,
  POS methods on, 80mm, no caps); payment-method and
  discount-limit POS wiring are follow-ups.
- D135 — FeatureGate capability-gates non-module routes;
  system-hub screens are Settings sub-screens, not new modules.
- D136 — POS tax rate reads Organization Settings (default 0%,
  behaviour unchanged).
- See `docs/technical-decisions.md`.

## Files changed
- New: `lib/features/branches/branch_directory.dart`,
  `lib/features/branches/branch_form_dialog.dart`,
  `lib/features/branches/branch_list_screen.dart`,
  `lib/features/branches/branch_detail_screen.dart`,
  `lib/features/audit/audit_logic.dart`,
  `lib/features/audit/audit_log_screen.dart`,
  `lib/features/backup/backup_logic.dart`,
  `lib/features/backup/backup_provider.dart`,
  `lib/features/backup/backup_screen.dart`,
  `lib/features/settings/org_settings.dart`,
  `test/week4_day04_test.dart`.
- Edited: `lib/models/branch.dart` (SRS §3.1 fields),
  `lib/features/settings/settings_screen.dart` (Organization +
  Sync tabs), `lib/features/settings/feature_gate.dart`
  (non-module capability gating),
  `lib/core/data/permission_service.dart` (3 route capabilities),
  `lib/core/routing/app_router.dart` (4 routes),
  `lib/app/shell/app_shell.dart` (Settings sub-items, sidebar +
  More sheet), `lib/features/billing/pos_screen.dart` (tax rate
  from org settings), `test/week3_day04_test.dart`,
  `test/day_07_test.dart` (intentional updates),
  `docs/week-4-tracker.md`, `docs/technical-decisions.md`.
- No new dependencies.

## Follow-ups (not in this day)
- **Firestore branch repository:** the `branches` collection
  (SRS §3.1) with a `BranchRepository` (D101 pattern) so branches
  persist and the directory is not session-only; deactivation
  enforcement on transactions (FR-HO-08 — a deactivated branch
  cannot transact) belongs with it.
- **Restore into the live repositories (D133):** live repos need
  upsert-by-id before a restore can overwrite live demo data;
  until then restore targets the in-memory sink only.
- **POS wiring for org settings (D134):** the payment-method
  picker and the discount caps are config-only until the POS
  reads `orgSettingsProvider` for them (tax already reads it,
  D136). Same for the receipt paper width / footer on the printed
  receipt.
- **Scheduled backups (SRS §2.6):** the Cloud Function export
  (weekly full + daily incremental) needs the Firebase project.
- **Franchise commission / royalty tracking (FR-HO-07, P3):**
  rates are recorded per branch now; the tracking/reporting
  itself is Phase 2.
- **390px body findings (Day 5 sweep, unchanged):** `/orders`
  12px, `/billing` 133px, `/inventory` batch-row overflows — still
  open for the Day 5 sweep, not touched here.
