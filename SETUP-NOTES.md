# Pharma Plus — Setup Notes (Foundation, 23 Nov 2026)

Foundation set up on Dazy's order ("Start kro roadmap poora app sw ka").
Roadmap (source of truth):
`~/workspace/goals/mobile-app-development-outreach/files/fazal-din-pharmacy-roadmap.md`

## What was created

Project home: `~/workspace/fazal-din-pharma/` — Flutter project `pharma_plus`.

### Flutter project (created with `flutter create`)
- App name: `pharma_plus` — package ID: **`com.fazaldin.pharmaplus`**
  (Android `applicationId` + namespace, iOS bundle ID — both set explicitly;
  `flutter create` defaults had produced `pharma_plus`/`pharmaPlus` variants)
- Platforms: `android/`, `ios/`, `web/`, `windows/`
- Flutter 3.47.7 (stable) / Dart 3.13.5 — verified with `flutter --version`

### Dependencies (pubspec.yaml — `flutter pub get` OK, 23 deps resolved)
- `firebase_core: ^5.2.0`
- `cloud_firestore: ^7.2.0`
- `firebase_auth: ^7.1.0`
- `firebase_storage: ^14.1.0`
- `firebase_messaging: ^17.1.0`

### Three frontends — one codebase, separate entry points
| Frontend | Entry point | App widget |
|---|---|---|
| Customer mobile app (default) | `lib/main.dart` | `lib/app/customer_app.dart` |
| Admin web panel | `lib/main_admin.dart` | `lib/app/admin_app.dart` |
| Windows desktop shell (counter) | `lib/main_desktop.dart` | `lib/app/desktop_app.dart` |

Choice documented in `README.md`: separate entry points (not flavors) —
each frontend is a different app for different users sharing models/services.
Screens are placeholders listing the roadmap §2/§3 features; no Firebase
initialisation yet (no project exists).

### Data models — `lib/models/` (roadmap §4 Firestore collections)
- `models.dart` (barrel), `model_utils.dart` (Timestamp/String/int → DateTime)
- `medicine.dart` — `medicines`
- `order.dart` — `orders` (+ `OrderItem` line items, `OrderStatus` enum)
- `prescription.dart` — `prescriptions` (+ `PrescriptionStatus` enum)
- `customer.dart` — `customers` (+ `CustomerAddress`)
- `staff.dart` — `staff` (+ `StaffRole`: owner/pharmacist/counter/rider)
- `rider.dart` — `riders`
- `branch.dart` — `branches`
- `inventory_item.dart` — `inventory` (per-branch stock, low-stock + expiry)

All models are plain classes with `fromMap`/`toMap`; dates accept Firestore
`Timestamp`, ISO strings or epoch millis.

## What works (verified 23 Nov 2026)
- `flutter --version` — Flutter 3.47.7 / Dart 3.13.5
- `flutter create` — 97 files, all four platforms
- `flutter pub add` + `flutter pub get` — all five Firebase packages resolved
- `flutter analyze` — **No issues found!**
- `flutter test` — **3/3 passed** (Customer app builds, Admin web panel builds,
  Windows desktop shell builds — `test/widget_test.dart`)

## What does NOT work yet / what is next
1. **Firebase project does not exist.** No `google-services.json`,
   `GoogleService-Info.plist` or `firebase_options.dart`; entry points do
   not call `Firebase.initializeApp()`. Nothing in the app talks to a
   backend yet — models and shells only.
2. **Phase 1 build** (MVP screens + services + auth + Firestore wiring)
   starts after Hadi's requirements and Dazy's scope confirmation.
3. **CI builds** (GitHub Actions APK/AAB/Windows/Web) need a repo first.
4. **Known limitation:** `firebase_messaging` has no Windows implementation
   — desktop reads live updates from Firestore instead of push.

## What still needs Dazy
1. **Firebase project** — create a dedicated new Firebase project for
   Fazal Din's Pharma Plus under his Google account (separate from 60Score
   and from Dazy's own projects; the roadmap requires the client's data to
   live in the client's own project). Then `flutterfire configure` can add
   the platform config files.
2. **GitHub repo** — create the repo for this project (name/visibility his
   call) so CI builds and code backup exist.
3. **Hadi's requirements** — branch count, payment method, delivery areas,
   medicine catalogue source / SKU count, logo + brand colours (Phase 0).
   Without these, scope + quotation cannot be confirmed and Phase 1 cannot
   start properly.
4. **Quotation / price** — not fixed; comes after scope confirmation.

## What was deliberately NOT done
- No Firebase project, Google Cloud resource or GitHub repo created.
- No contact with Hadi or anyone else; nothing sent anywhere.
- 60Score app and all other projects untouched.

---

# Day 1 — PharmaDesk rebrand + foundation (Week 1 sprint, 23 Nov 2026)

Master prompt: Week 1 (7-day UI/frontend/Firebase foundation sprint).
See `docs/day-01-progress.md` for the full Day 1 report and
`docs/technical-decisions.md` for the decisions record.

**Rebrand:** project renamed `pharma_plus` → `pharmadesk`; applicationId /
iOS bundle ID `com.pharmadesk.app`; display name PharmaDesk everywhere
(Android, iOS, Windows binary, web title/manifest).

**Stack added:** `flutter_riverpod ^3.5.0`, `go_router ^18.1.4`,
`dio ^5.11.1`, `sqflite ^2.4.6`, `flutter_secure_storage ^11.2.0`.

**Design system:** Kalora blue palette (`#164AAB` primary, `#073477` deep
blue), Inter bundled, light + dark themes, white-label `BrandConfig`
(name/logo/colors per organization).

**Architecture:** GoRouter module map (14 Week 1 modules), repository
interfaces + mock implementations (sample medicines/orders/inventory),
money in int minor units, error types.

**Customer app:** flagged for conversion — PharmaDesk is staff/owner-only;
the Day 0 customer shell becomes the staff phone app in Phase 1.

**Backend decision (Dazy, 23 Nov 2026): Firebase Spark, PERMANENT free.**
No Blaze. Verified 23 Nov 2026: Cloud Storage and Cloud Functions are
Blaze-only (Storage since 3 Feb 2026) — prescription photos stay on-device,
no scheduled jobs, logic in app + security rules. `firebase_storage` was
removed from pubspec on Day 1.

**Still missing (unchanged):** Firebase project + config files, GitHub repo,
Hadi's requirements, quotation.
