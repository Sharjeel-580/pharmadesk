# PharmaDesk — Enterprise Pharmacy Management & Franchise ERP

White-label pharmacy software — one Flutter codebase, three frontends,
one Firebase backend (Spark free tier, permanent).

First client: **Fazal Din's Pharma Plus, DHA Lahore** (8 own branches +
~120 franchises, Punjab). The product is generic: every pharmacy
organization customizes its own app name, logo and colors (Brand Settings).

Source of truth for scope, phases and data model:
`~/workspace/goals/mobile-app-development-outreach/files/fazal-din-pharmacy-roadmap.md`
Full requirements + architecture:
`~/workspace/goals/mobile-app-development-outreach/files/pharmadesk-srs-architecture.md`

## The three frontends (one codebase)

| Frontend | Users | Entry point | Run / build |
|---|---|---|---|
| **Staff phone app** (Android + iOS) | Owner / staff | `lib/main.dart` (default) | `flutter run` / `flutter build apk` |
| **Admin web panel** | Owner / staff | `lib/main_admin.dart` | `flutter run -d chrome -t lib/main_admin.dart` / `flutter build web -t lib/main_admin.dart` |
| **Windows desktop app** (counter staff) | Counter staff | `lib/main_desktop.dart` | `flutter run -d windows -t lib/main_desktop.dart` / `flutter build windows -t lib/main_desktop.dart` |

**Why separate entry points (not flavors):** each frontend is a different
app for different users, with its own home screen and (later) its own auth
flow. They share `lib/models/`, `lib/core/` and `lib/shared/`. Flavors
would have been the alternative; entry points are simpler at this stage
and each target builds independently in CI.

**Staff-only product:** PharmaDesk is NOT a customer-facing shopping app.
The Day 0 customer-app shell (`lib/app/customer_app.dart`) is flagged for
conversion into the staff phone app in Phase 1 — no customer features are
built on it.

## Project layout (Week 1 — Day 1)

```text
lib/
  main.dart            # staff phone app entry (default)
  main_admin.dart      # admin web entry
  main_desktop.dart    # Windows counter entry
  app/
    pharmadesk_app.dart  # PharmaDeskApp root (Riverpod + GoRouter + theme)
    foundation_home.dart # Day 1 navigation hub (module cards)
    customer_app.dart    # ⚠️ legacy customer shell — FLAGGED FOR CONVERSION
    admin_app.dart       # AdminApp shell
    desktop_app.dart     # DesktopApp shell (Phase 3)
  core/
    constants/         # app_colors.dart (Kalora palette), app_constants.dart
    theme/             # app_theme.dart (light/dark, Inter), white_label.dart,
                       #   theme_mode_provider.dart
    routing/           # app_router.dart (GoRouter + Week 1 module map)
    services/          # repositories.dart (interfaces + mock implementations)
    utils/             # money.dart (int minor-unit calculations)
    errors/            # app_errors.dart
  shared/
    widgets/           # module_placeholder_screen.dart
  models/              # one file per Firestore collection
    models.dart        # barrel — import this
    medicine.dart      # medicines
    order.dart         # orders (+ OrderItem)
    prescription.dart  # prescriptions
    customer.dart      # customers (+ CustomerAddress)
    staff.dart         # staff (owner/pharmacist/counter/rider roles)
    rider.dart         # riders
    branch.dart        # branches
    inventory_item.dart # inventory (per-branch stock)
    model_utils.dart   # Timestamp/String/int → DateTime helpers
  features/            # one folder per Week 1 module (screens land Day 2–7)
assets/
  fonts/               # Inter Regular/Medium/SemiBold/Bold (bundled)
  images/ icons/ branding/  # white-label assets per organization
docs/
  day-01-progress.md       # Day 1 progress report
  technical-decisions.md   # architecture decisions (living record)
  firebase-setup-plan.md   # Firebase project setup steps (not started)
```

## Design

Kalora-inspired premium corporate: primary blue `#164AAB`, deep blue
`#073477`, white, background `#F3F6FA`, Inter typography, light + dark
themes. The previous emerald/lime direction is retired.

## Dependencies

- Flutter 3.47.7 / Dart 3.13.5; `flutter_riverpod`, `go_router`, `dio`,
  `sqflite`, `flutter_secure_storage`.
- Firebase: `firebase_core`, `cloud_firestore`, `firebase_auth`,
  `firebase_messaging` (FCM is free on Spark). **`firebase_storage` was
  removed on Day 1** — Cloud Storage requires Blaze and the backend is
  permanent-free Spark; prescription photos stay on-device.

## Firebase — NOT configured yet

No Firebase project exists for this client yet, so there is no
`google-services.json`, `GoogleService-Info.plist` or `firebase_options.dart`,
and no `Firebase.initializeApp()` call in the entry points. Creating the
dedicated Firebase project is a Dazy decision (see
`docs/firebase-setup-plan.md`). Once it exists: run `flutterfire configure`,
then wire `Firebase.initializeApp()` into all three entry points.

## Known limitations

- `firebase_messaging` has **no Windows implementation**. The desktop app
  therefore reads live order updates from Firestore instead of push
  notifications.
- `sqflite` needs `sqflite_common_ffi` on Windows and has no web support
  (Week 2 decision when offline storage is wired).
- Windows and iOS builds cannot run on this Linux machine — they must be
  verified on real Windows/macOS hardware.

## Status

**Week 1 — Day 1 complete** (foundation): rebranded to PharmaDesk,
design system + themes, GoRouter navigation, repository interfaces with
mock data, white-label branding config. See `docs/day-01-progress.md`.
Screens are placeholders until their day (Day 2–7); models are complete
with `fromMap`/`toMap`. Firebase setup is blocked on Dazy creating the
project.
