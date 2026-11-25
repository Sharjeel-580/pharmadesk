# PharmaDesk — Day 1 Progress Report (Week 1 sprint, 23 Nov 2026)

Day 1 of the 7-day UI/UX, frontend & Firebase foundation sprint.
Master prompt: Week 1 sprint (PharmaDesk). Status: **complete, verified —
except the Android APK build, which is environment-blocked (see Blocker 4)**
by re-run on 23 Nov 2026 ~19:18 PKT (see Verification below).

## What was done

### 1. Rebrand: `pharma_plus` → `pharmadesk`
- Dart package renamed to `pharmadesk`; Android `applicationId` + namespace
  and iOS bundle ID set to `com.pharmadesk.app` (generic white-label product
  ID — deliberately NOT client-specific).
- Display name PharmaDesk everywhere (Android, iOS, Windows binary, web
  title/manifest).
- The Day 0 customer-app shell (`lib/app/customer_app.dart`) is **flagged
  for conversion, not deleted**: PharmaDesk is staff/owner-only, so this
  shell becomes the staff phone app in Phase 1. A widget test asserts the
  flag ("Legacy customer shell is flagged for conversion").

### 2. Design system (Kalora blue)
- Palette: primary `#164AAB`, deep blue `#073477`, background `#F3F6FA`
  (`lib/core/constants/app_colors.dart` — verified in file).
- Inter bundled (Regular/Medium/SemiBold/Bold); light + dark themes
  (`lib/core/theme/app_theme.dart`, `theme_mode_provider.dart`).
- White-label `BrandConfig` (`lib/core/theme/white_label.dart`): name, logo,
  primary/secondary colour per organization.

### 3. App shell & navigation
- GoRouter module map (`lib/core/routing/app_router.dart`) with a
  foundation home hub (`lib/app/foundation_home.dart`) linking the Week 1
  modules; three entry points kept: `lib/main.dart` (phone),
  `lib/main_admin.dart` (web admin), `lib/main_desktop.dart` (Windows).
- Feature folders created under `lib/features/` (authentication, dashboard,
  orders, medicines, inventory, billing, customers, suppliers, purchases,
  prescriptions, reports, notifications, settings, profile). Screens are
  placeholders (`lib/shared/widgets/module_placeholder_screen.dart`) until
  their day (Day 2–7).

### 4. Architecture
- Repository interfaces + mock implementations with sample data
  (`lib/core/services/repositories.dart`); money in int minor units
  (`lib/core/utils/money.dart`); error types (`lib/core/errors/`).
- Stack: Flutter 3.47.7 / Dart 3.13.5, `flutter_riverpod ^3.5.0`,
  `go_router ^18.1.4`, `dio ^5.11.1` (reserved, unused on Day 1),
  `sqflite ^2.4.6` (future offline), `flutter_secure_storage ^11.2.0`.
- Data models complete with `fromMap`/`toMap` (`lib/models/` — Medicine,
  Order, Prescription, Customer, Staff, Rider, Branch, Inventory).

### 5. Backend decision applied (Dazy, 23 Nov 2026)
- **Firebase Spark, permanent free.** Laravel + PostgreSQL + VPS dropped.
  Blaze pay-as-you-go explicitly out of scope.
- Cloud Storage and Cloud Functions are **not available on Spark**
  (verified 23 Nov 2026 against Firebase pricing pages): prescription
  photos stay on-device, no scheduled backend jobs, logic in app +
  Firestore security rules.
- `firebase_storage` **removed from pubspec** on Day 1 so no Week 2 code
  can accidentally wire it. Kept: `firebase_core`, `cloud_firestore`,
  `firebase_auth`, `firebase_messaging` (FCM is free on Spark).
- Full rationale in `docs/technical-decisions.md` (D1–D6) and SRS v0.2
  (`~/workspace/goals/mobile-app-development-outreach/files/pharmadesk-srs-architecture.md`).

### 6. Git
- Local git repo initialised on Day 1 and initial commit created
  (this report included). No remote yet — GitHub repo still Dazy's call.

## Verification (re-run 23 Nov 2026, ~19:15–19:18 PKT)
- `flutter analyze` — **No issues found!**
- `flutter test` — **4/4 passed** (PharmaDesk staff app builds; legacy
  customer shell flagged for conversion; admin web panel builds; Windows
  desktop shell builds).
- NOT verified on this Linux machine: Windows and iOS builds (need real
  Windows/macOS hardware) — see README "Known limitations".

## Build results per target (23 Nov 2026)
- `flutter analyze` — **No issues found!**
- `flutter test` — **4/4 passed**.
- `flutter build web --release` — **PASSED** (658.2s; `main.dart.js`
  2,286,947 bytes; title/manifest PharmaDesk; Inter fonts in output).
- `flutter build apk --debug` — **FAILED, environment-blocked** (see
  Blocker 4 below). No APK produced. Not a code problem.
- `flutter build windows` / `flutter build ios` — not possible on this
  Linux VM; must be verified on real Windows/macOS hardware.

## Blocker 4 (new): APK build blocked by the sandbox, not by code
Gradle 9.3.1 had to be installed manually (wrapper download fails:
Java ignores the shell proxy vars). Daemon dispatch was fixed with
`-Djava.net.preferIPv4Stack=true` (localhost dual-stack mismatch in
/etc/hosts). The remaining hard stop: Gradle's HTTP client cannot
download the `kotlin-dsl` plugin from the Gradle plugin portal through
the sandbox egress proxy (`ProtocolException: The server failed to
respond with a valid HTTP response`), although curl/Python fetch the
same URL fine (HTTP 200). Machine-local Gradle config (proxy +
truststore) lives in `/root/.gradle/` (not in the repo). Fix options:
pre-populate the Gradle cache via curl, or build the APK on CI / a
machine with direct internet. Do not claim the APK builds until one
of these produces a real APK.

## Blockers (1–3 only Dazy can clear; 4 is an environment issue)
1. **Firebase project does not exist.** No `google-services.json`,
   `GoogleService-Info.plist` or `firebase_options.dart`; entry points do
   not call `Firebase.initializeApp()`. Nothing talks to a backend yet.
   Needs a dedicated new Firebase project for Fazal Din's, under Dazy's
   Google account. Full plan: `docs/firebase-setup-plan.md`.
2. **GitHub repo not created** (name/visibility Dazy's call) — needed for
   CI builds and code backup.
3. **Hadi's requirements still awaited** — medicines count, delivery areas,
   payment method, branch cities, logo + brand colours. Without these,
   scope + quotation cannot be confirmed and Phase 1 cannot start properly.
4. **APK build environment-blocked.** Gradle's HTTP client cannot download
   the `kotlin-dsl` plugin through the sandbox egress proxy (see Blocker 4
   above). Not a code problem. Fix options: pre-populate the Gradle cache
   via curl, or build the APK on CI / a machine with direct internet.
   Day 2 work does not depend on it.

## Next step
- **Day 2 (24 Nov):** design-system components + application shell
  (desktop sidebar/top nav, mobile bottom nav, theme switching) — can start
  without the blockers above; Firebase wiring waits on blocker 1.
