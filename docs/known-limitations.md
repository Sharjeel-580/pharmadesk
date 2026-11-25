# PharmaDesk — Known Limitations (Day 7, final Week 1 demo — updated Week 2 Day 1)

This document is the honest boundary of the Week 1 demo. Everything
here is deliberate — either out of scope for the demo (SRS §8.5), or
blocked on a decision only Dazy can make. Nothing here is a hidden
defect: if it is listed, it is known and accepted for this build.

## 1. No backend — no cloud sync, no real login

- There is **no Firebase project yet** (Dazy's decision, see
  `docs/firebase-setup-plan.md`). No credentials, no
  `google-services.json`, no `Firebase.initializeApp()`.
- All data is local mock data in memory. **Data resets when the app
  restarts.** Nothing syncs between devices, branches, or users.
- **Week 2 Day 1 update:** the offline sync queue, audit log and
  production data layer now exist **locally** (in-memory on web,
  sqflite-backed on mobile) — sales/orders are deduplicated, stock
  reservations and audit entries work, and JSON export/import is
  available. But there is still **no cloud to sync to**: the queue
  holds operations until the Firebase project exists, and on web it
  resets on restart. Cloud sync, real login and claims arrive with
  the Firebase-wiring chunk.
- **Week 2 Day 3 update:** the Firestore implementations now exist
  in code (`lib/core/data/firestore_*.dart`, `repository_factory.dart`)
  and are tested against an in-memory fake transport — but they are
  still **unwired**: the app defaults to the mock bundle, and the
  Firestore kind needs a transport + (for auth/storage) a Firebase
  project that does not exist yet. Cloud sync, real login and claims
  arrive with the Firebase-wiring chunk.
- The five demo accounts (`demo1234`) are a local mock login. There is
  no real authentication, no password hashing, no sessions. **Week 2
  Day 3 update:** the login screens now delegate to an `AuthRepository`
  interface (mock implementation), and `AppUser` carries the custom-
  claims shape (`orgId` / `branchIds[]` / `role`) — the Firebase Auth
  implementation exists but cannot run without a project.
- Demo passwords are shared and public by design — never use them in
  production.

## 2. APK not built in this sandbox

- `flutter build apk` is **environment-blocked** in this dev sandbox:
  Gradle's HTTP client cannot download the kotlin-dsl plugin through
  the egress proxy (docs/technical-decisions.md D14/D15). This is an
  environment limit, not a code problem — the web build passes and
  `flutter analyze` is clean.
- The APK must be built on GitHub Actions (CI) or a machine with
  direct Gradle access. No APK exists from this build — do not claim
  one does.

## 3. Windows build unverified on this VM

- Windows builds cannot run on this Linux VM. The Windows target is
  unverified; it needs real Windows hardware. The same applies to iOS
  (needs macOS). The demo deliverable for Hadi is the **web build**
  (and, once CI runs, the APK).

## 4. Prescription photos are bundled samples, not real photos

- The backend is now Firebase **Blaze** (D62, 25 Nov 2026), so
  production prescription photos go to **Cloud Storage**
  (`organizations/{orgId}/branches/{branchId}/prescriptions/{id}.jpg`,
  metadata on the Firestore doc, rules in
  `firebase/storage.rules`) — captured on-device, stored in the cloud,
  shareable across branches/devices. The upload flow itself lands in
  the Firebase-wiring chunk; the design (paths, metadata fields,
  rules) is already in place.
- In this demo the two prescription images are **bundled sample
  assets** (`assets/images/prescriptions/sample-prescription-1.png`,
  `sample-prescription-2.png`), clearly marked SAMPLE / "DEMO ONLY —
  NOT A REAL PRESCRIPTION", with fictional patients and doctors.
- The "new prescription" form creates a record with the first sample
  image attached (there is no camera/gallery picker in the demo).
- Never present a sample image as a real patient's prescription.

## 5. PDF export — real, but basic

- PDF export is **real** (via the `pdf` package, `pdf 3.13.1`): the
  sales report PDF contains the title, period, totals, daily-sales
  and best-sellers tables. A unit test asserts the output starts with
  `%PDF`.
- It is a simple tabular report — no logo, no receipt-style layout,
  no per-branch breakdown in the PDF itself (branch is in the period
  line). CSV export covers every section; the PDF covers the sales
  summary only.
- Print uses the browser print dialog on web (print-friendly view of
  the daily-sales report).

## 6. Full offline POS is production, not demo

- The demo POS works fully on mock data (FEFO cart, discount/tax,
  cash/card/khata, receipt, sales history), but true offline-first
  behaviour — queued sales syncing when connectivity returns,
  conflict resolution, multi-device stock — is a production concern
  (SRS §6) and is **not** demonstrated here. In the demo, "offline"
  just means "no backend at all".

## 7. Roles & permissions are display-only in the demo

- The Settings → Roles & Permissions matrix is the real SRS §5.1
  matrix (10 roles × 21 capabilities), but it is **read-only display**.
  The demo role picker only highlights a column; it does not enforce
  anything. Production enforcement is Firestore security rules +
  custom claims (SRS §5.2) — not built yet.
- **Week 2 Day 3 update:** the matrix is now enforced in the UX
  layer — `FeatureGate` blocks modules the signed-in user has no
  capability for, the sidebar/More-sheet hide unpermitted modules,
  and prescription review buttons are gated (pharmacist-only, own
  branch). This is defense in depth only: **Firestore rules remain
  the authority**, and the rules themselves are still unwired (no
  project). The demo role picker still does not change enforcement.

## 8. Feature config is demo-local

- Disabling a module hides it from navigation and shows a clear
  "disabled" state — that behaviour is real in the demo. But the
  setting is **in-memory only**: it resets on restart, and it is not
  per-organization in any backend (there is no backend). Production
  stores it per organization in Firestore (SRS FR-SYS-05).

## 9. Notifications are derived, not pushed

- Alerts are computed from the mock data at load time (low-stock,
  near-expiry, pending prescriptions, POs awaiting approval, today's
  orders). There is **no push notification** (no FCM in the demo, no
  backend to send from). Marking read/unread is in-memory only.

## 10. WhatsApp orders are manual entry

- Orders can be entered as "phone / WhatsApp" source, but there is
  **no WhatsApp API integration** — no message is sent or received by
  the app. The full status flow (New → Delivered) is real; the
  WhatsApp part is the staff member's phone, as specified in SRS §8.

## 11. Demo data is fictional and limited

- 2 fictional branches (DHA, Gulberg), 180 sample medicines, 491
  seeded orders over 30 days, 8 customers, 4 suppliers, 6 purchase
  orders, 20 prescriptions. Figures, names, prices and stock levels
  are invented for the demo.
- Branch cities, delivery areas, medicine count and payment methods
  for the real Fazal Din business are **unknown** — Hadi's
  requirements are still awaited. Nothing in the demo should be read
  as the real business's data.

## 13. Auto Purchase List notes (Week 2 Day 2)

- The list suggests from live inventory; the reorder (par) level is
  the sum of the batch low-stock thresholds (seeded 10 per batch),
  not a separately configured par level per medicine.
- There is no batch `status` field on `InventoryItem` yet, so the
  "non-quarantined" part of the usable-stock rule is currently the
  sellable guard (non-expired, in stock) — see D64.
- **Week 2 Day 3 update (D64 closed):** the batch `status` field has
  landed (`available` / `quarantined` / `expired` / `returned`) and
  quarantined stock is excluded from usable stock end-to-end.
- The catalogue has no medicine→supplier field: the preferred
  supplier per line is taken from the most recent PO for that
  medicine, falling back to the first active supplier. Staff can
  change it per line; there is no supplier lead-time / pack-size
  catalogue yet.
- Approval creates Draft POs only — a manager still approves each PO
  on the Purchases screen before goods can be received.

## 12. What is explicitly NOT in the demo (SRS §8.5)

- Customer-facing app (removed from scope 23 Nov — staff/owner only).
- Real payments, real money movement, real supplier payments.
- Barcode hardware scanning (sample barcodes exist in the catalog;
  scanning is simulated by search).
- AI modules (optional in the SRS; not in Week 1).
- Franchise management (first version is the 8 own branches only).
- Multi-language UI beyond the current English interface.
