# PharmaDesk — Demo Guide (refreshed Week 8 Day 41, 26 Nov 2026)

> **Status: refreshed for the final Week 8 handover.** Every figure
> below was re-checked against the final tree on Day 41 (see
> `docs/day-41-progress.md` for the per-figure verdicts). All 14
> modules are real — no placeholder screens remain. Demo credentials
> are rotated per demo build (SRS §8.1) — the table below is for this
> build only. Known limitations live in
> `docs/known-limitations.md` — read it before showing the demo to
> the client. Install steps, demo accounts and the admin/backup
> guide live in `docs/deployment-guide.md`; the role-based manual is
> `docs/user-manual.md`.

## What the demo is

PharmaDesk is a staff/owner pharmacy management app (Flutter +
Firebase Blaze, pay-as-you-go — decided 25 Nov 2026, D62,
superseding the 23 Nov Spark decision). This build is a **functional interactive
demo on fictional sample data** — every screen works; nothing is a
static screenshot. Look for the **DEMO MODE** badge: it is on every
screen (top bar on module screens; on the splash, login and
forgot-password screens too).

**No real data:** no real customer names, no real prices, no real
stock, no real money. Demo data never mixes with production data
(SRS §8.2).

## How to run the demo

- **Web (this build):** `flutter run -d chrome` from
  `~/workspace/fazal-din-pharma/`, or serve the built web app
  (`flutter build web --release` → `build/web/`; `main.dart.js`
  4,683,590 bytes).
- **Android APK:** CI-built release APKs exist in the workspace —
  latest `pharmadesk-week7.apk` (70,881,526 bytes, 26 Nov 2026),
  previous `pharmadesk-week6.apk` (70,865,142 bytes). Release build
  signed with the debug keys (see `docs/deployment-guide.md` §2 for
  install steps and the signing note). The APK cannot be rebuilt on
  the dev sandbox (Gradle is environment-blocked there — D14/D15/D52);
  rebuilds go through GitHub Actions CI.
- **Windows:** CI-built zips exist — latest
  `pharmadesk-windows-week7.zip` (26,276,306 bytes), previous
  `pharmadesk-windows-week6.zip` (26,273,637 bytes); unzip and run
  `pharmadesk.exe` (see `docs/deployment-guide.md` §3). The zip has
  not been launched on a real Windows PC by the team — the Linux VM
  cannot run it.
- **Backend:** none in this build. All data is local mock data; there
  is no Firebase project yet, so there is no cloud sync and no login
  beyond the demo accounts below. Firebase setup is Dazy's call
  (`docs/firebase-setup-plan.md`).

## Demo accounts

All five accounts share the password **`demo1234`**. Tap a card on
the sign-in screen to sign in with one tap, or type the email +
password.

| Role | Name | Email | Sees |
|---|---|---|---|
| Owner | Hassan Raza | `owner@demo.pharmadesk` | All branches — owner dashboard |
| Branch Manager | Bilal Ahmed | `manager@demo.pharmadesk` | Demo Branch — DHA |
| Pharmacist | Dr. Sana Malik | `pharmacist@demo.pharmadesk` | Demo Branch — DHA |
| Cashier | Usman Tariq | `cashier@demo.pharmadesk` | Demo Branch — Gulberg |
| Inventory Manager | Fatima Noor | `inventory@demo.pharmadesk` | Demo Branch — Gulberg |

Names, emails and figures are fictional.

## Demo data

- 2 demo branches: Demo Branch — DHA (busier), Demo Branch — Gulberg.
- **180 medicines** (16 categories, sample barcodes, int-paisa
  prices), 8 customers, 4 suppliers, 6 purchase orders,
  20 prescriptions.
- **491 orders over 30 days** across both branches (deterministic
  seed; earlier Day 3/4 docs saying 499 were wrong — see D31).
- Per-branch stock with mixed expiry: some batches near-expiry, a
  few expired, some low-stock — the alerts radar is live.
- Supplier ledger seed: Sami Pharmaceuticals owes Rs 125,000.00,
  MedServe Rs 48,250.00, Hassan Pharma Traders Rs 0.00, CareLine
  Rs 21,000.00.
- Two prescriptions (`rx-dha-1`, `rx-glb-11`) start Pending and are
  linked to today's first order of each branch, so the prescription
  dispatch guard and its unblock are demonstrable.

## Walkthrough — every SRS §8.4 acceptance criterion

### 1. Login as Owner and as Cashier

1. Sign in as **Owner** (`owner@demo.pharmadesk` / `demo1234`) — the
   owner dashboard shows today's sales, 30-day revenue, low-stock
   and near-expiry counts, a 30-day sales chart, per-branch
   performance, top sellers, recent orders and alerts. Every card
   opens its module.
2. Sign out (profile menu, top bar right) and sign in as **Cashier**
   (`cashier@demo.pharmadesk`) — the Gulberg branch dashboard:
   today's branch sales/orders, pending prescriptions, quick actions
   (New Sale, New Order, Stock Check, …). Each action opens its
   module.
3. Try the other roles: Pharmacist and Inventory Manager see the
   same branch dashboard with quick actions re-ordered for the role.
4. **Forgot password** — enter a demo email; the screen shows the
   demo reset code (no email is sent in the demo) and lets you set a
   new password, which then signs in. Try a wrong code first — it is
   rejected.

### 2. Full sale — scan → pay → receipt (POS)

1. As Cashier, open **Billing / POS** → New Sale.
2. Add medicines by searching name, brand or barcode (try a sample
   barcode from the catalog). Watch the batch picker: it always
   offers the **earliest-expiring batch first (FEFO)**.
3. Try adding a medicine whose only batches are expired — it is
   **blocked** ("expired batch — never sellable").
4. Apply a per-line discount and a bill discount, add tax, then pay
   **cash** (change is computed), **card**, or **khata** (adds to the
   customer's ledger; a customer over their credit limit is refused).
5. The **receipt preview** opens — Share (copies the receipt text) or
   Print (web print dialog). The sale appears immediately in Sales
   history and on the dashboard KPIs.

### 3. FEFO in action + expired batch blocked

Covered in the sale above. For a second view, open **Inventory**:
batches are listed earliest-expiry first, expired batches are marked
and can never be picked for a sale or an order.

### 4. Branch switching shows different stock/sales

Top bar, next to the app name: switch **DHA ↔ Gulberg**. Dashboards,
orders, inventory and sales figures all change — DHA is busier, with
different stock levels and different low-stock items.

### 5. Daily sales report and export

1. Open **Reports**. Pick a branch (All / DHA / Gulberg) and a range
   (1 / 7 / 30 days).
2. The four stat cards, daily-sales table, best sellers, low stock,
   expiry and stock valuation all recompute.
3. **Export CSV** — one button per section; the file downloads in the
   browser. **Export PDF** — downloads a real PDF sales report.
   **Print** — opens the browser print dialog with a print-friendly
   daily-sales view.

### 6. WhatsApp order through the full status flow

1. Open **Orders** → New Order. Source: **WhatsApp** (manual entry —
   no WhatsApp API; the staff member's phone is the WhatsApp part).
2. Add items (expired batches are un-addable), set an advance payment.
3. Advance the order through **New → Confirmed → Processing → Ready
   → Dispatched → Delivered**, assigning a rider at Ready (before
   dispatch).
4. **Prescription guard:** open today's first DHA order — it is held
   at dispatch until prescription `rx-dha-1` is approved. Open
   **Prescriptions**, approve `rx-dha-1`, go back: the order can now
   be dispatched. (Same for Gulberg with `rx-glb-11`.)

### 7. Suppliers, purchases, prescriptions, notifications, settings

- **Suppliers:** search, add/edit (duplicate phone rejected), open
  Sami Pharmaceuticals — computed payable Rs 125,000.00, purchase
  history, ledger; Record payment reduces the payable immediately.
- **Purchases:** open PO-DHA-1001 (Approved) → Receive: pick
  quantities, batch numbers, mfg/expiry dates (partial receiving
  allowed) → the batches appear in **Inventory** at once and the
  supplier payable rises by the received value. Try approving a Draft
  PO, and cancelling one — guards enforce the allowed transitions.
- **Prescriptions:** the queue shows all 20 with statuses; open one
  to see the **SAMPLE** photo (bundled asset, marked DEMO ONLY),
  Approve / Reject / Needs clearer photo (a note is required for the
  last two). The New prescription form creates a Pending record.
- **Notifications:** the bell in the top bar shows the unread count.
  Open it: low-stock, near-expiry, pending prescriptions, POs
  awaiting approval, today's new orders. Tap any alert — it opens the
  relevant screen. Mark read / unread, or Mark all read.
- **Settings:** General (theme, default branch); **Branding** — change
  the organization name and colours and watch the shell rebrand
  immediately; try the **Fazal Din preset** (one tap) and Reset;
  **Roles & Permissions** — the 10 roles × 24 capabilities matrix
  (SRS §5.1, read-only display); **Features** — switch a module off
  and it disappears from the sidebar; open it directly and you get a
  clear "module is disabled" state.

### 8. No dead buttons

Every button in the app does something real — verified by the final
full route walk (Week 8 Day 39): all 47 routes resolve at desktop
and at 390px phone width with no placeholder/404, and the fresh
390px sweep is 0 distinct overflows. If you find a button that does
nothing, that is a bug: report it.

## Known limitations (summary — full list in `docs/known-limitations.md`)

- No backend: data resets on restart; nothing syncs.
- Android APK exists (CI-built, release signed with debug keys —
  `pharmadesk-week7.apk` latest); Windows zip exists (CI-built —
  `pharmadesk-windows-week7.zip`) but has not been launched on a real
  Windows PC by the team.
- Prescription photos are bundled SAMPLE assets, not real photos.
- PDF export is a simple tabular sales report; CSV covers every
  section.
- Roles & permissions matrix is display-only; feature config is
  in-memory only; notifications are derived, not pushed.
- WhatsApp orders are manual entry — no WhatsApp API.
- Full offline POS sync is production scope, not demo.

## Changelog

- Day 3 (24 Nov 2026): guide started — splash/login/forgot-password/
  demo login, owner & branch dashboards, demo accounts table.
- Day 7 (24 Nov 2026): finalized — corrected counts (491 orders, 180
  medicines), all 14 modules real, full §8.4 walkthrough, limitations
  moved to `docs/known-limitations.md`.
- Day 41 (26 Nov 2026): Week 8 refresh — every figure re-checked
  against the final tree. Corrected: backend is Blaze, not Spark
  (D62, 25 Nov); APK exists (`pharmadesk-week7.apk` latest, CI-built,
  debug-signed); Windows zip exists (`pharmadesk-windows-week7.zip`);
  `main.dart.js` 4,683,590 bytes; supplier name is Hassan Pharma
  Traders; roles matrix is 10 × 24 capabilities; rider is assigned at
  Ready, not at dispatch; §8 now cites the final 47-route walk
  (Day 39, 0 overflows at 390px). All other figures re-verified
  unchanged (see `docs/day-41-progress.md`).
