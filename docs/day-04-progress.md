# PharmaDesk — Day 4 Progress Report (Week 1 sprint, 24 Nov 2026)

Day 4 of the 7-day UI/UX, frontend & Firebase foundation sprint.
Status: **complete, verified** (see Verification below).

## What was built

### 1. Order status vocabulary aligned (D10 closed, D25)
`lib/models/order.dart`: the Day 0 enum (`placed / confirmed /
preparing / outForDelivery / delivered / cancelled`) is **extended**,
not renamed — new Week 1 values `newOrder`, `processing`, `ready`,
`dispatched` join it, and `orderStatusFromString` parses both old and
new stored strings (plus `'new'`). Labels in
`lib/features/dashboard/dashboard_data.dart` now read the Week 1
vocabulary for both: `placed` → "New", `preparing` → "Processing",
`outForDelivery` → "Dispatched". The canonical flow is
New → Confirmed → Processing → Ready → Dispatched → Delivered, plus
Cancelled (pure logic in `lib/features/orders/order_logic.dart`:
`canonicalStatus`, `nextOrderStatus`, `canAdvance` / `canCancel` /
`canEdit`, `advanceLabel`, `orderTimeline`).

### 2. Order model — Day 4 fields (D26)
`Order` gains `source` (phone / WhatsApp / walk-in — staff-entered
only, **no WhatsApp API**), `fulfillment` (delivery / pickup),
`discountMinor` (int paisa, default 0), plus `copyWith` and int
getters `subtotalMinor` / `totalMinor`. `fromMap`/`toMap` round-trip
the new fields; Day 0 maps without them default sanely (phone,
delivery, 0 discount). `OrderItem.lineTotalMinor` is int paisa.

### 3. Order queue (`lib/features/orders/order_list_screen.dart`)
Route `/orders`. Branch-scoped to the active branch (Day 2
switcher); status filter chips (All + 7 canonical statuses, with
counts — legacy `preparing` counts under Processing), search by
order no. / customer name / phone (dashes ignored), newest first.
Rows show source icon, customer, fulfilment, time, total and the
design-system status badge; tap opens the detail screen.

### 4. Order detail (`lib/features/orders/order_detail_screen.dart`)
Route `/orders/:id`. Customer (+ phone/address), source, items with
quantities × unit price, subtotal / discount / total (int paisa),
delivery vs pickup, rider (name/phone/vehicle or "No rider assigned
yet"), notes, linked prescription (id, review status, photo label,
review note), and the 6-step status timeline — timestamps only where
the data has them (`createdAt` for New, `updatedAt` for the current
step; nothing invented). Actions: **Advance** ("Mark …"),
**Cancel** (confirm dialog, danger), **Edit** — each behind its
guard (Delivered/Cancelled: no advance, no cancel, no edit, with a
clear read-only banner). **Prescription guard:** an order whose
linked prescription is still pending review cannot be dispatched —
the button explains why instead of advancing (D28). The dashboard's
recent-orders rows now open the order's detail screen directly.

### 5. Create / edit order (`lib/features/orders/order_form_screen.dart`)
Routes `/orders/new` and `/orders/:id/edit`, one shared form.
Customer dropdown (8 seeded customers, or Walk-in — picking a
customer prefills their default delivery address), source
segmented control, medicine search + add (first 6 matches, each
with price and the branch inventory row: batch no., expiry date,
stock on hand; **expired batches cannot be added**), quantity
steppers / remove, discount in whole rupees, delivery vs pickup
(pickup clears the rider), rider dropdown (active riders only),
optional prescription dropdown (seeded prescriptions for the
branch — **no new photo capture; that is Day 7**), notes.
Validation on save: customer or walk-in, at least one item,
quantities ≥ 1, discount ≥ 0 and ≤ subtotal, delivery needs an
address — all problems listed in one error box. A saved order
appears in the queue immediately and opens its detail screen.
Edit is the same form prefilled; Delivered/Cancelled orders open
read-only with a notice and a "Back to Order" button instead of
Save.

### 6. State + repositories
`lib/features/orders/orders_provider.dart`: `OrderQueueNotifier`
(AsyncNotifier) owns the in-memory order list, writes through to
the repository on create/edit/advance/cancel and refreshes, so the
queue, detail and dashboard share one source of truth.
`OrderRepository` gains `createOrder` (assigns the id) and
`updateOrder`; `updateStatus` now uses `copyWith`, so a status
change never drops source, discount, rider, notes or prescription.
New `RiderRepository` + `MockRiderRepository` over 4 seeded riders
(3 active, 1 inactive) in `demo_seed_data.dart`. Seed orders now
carry source / fulfilment / rider (out-for-delivery + delivered
orders had a rider), and **the first two orders of each branch
today are always New** — the Day 4 seed change shifted the
deterministic random stream and left today with zero New orders,
which the queue must never show (D29).

## Files created / changed
- Created: `lib/features/orders/{order_logic,orders_provider,order_list_screen,order_detail_screen,order_form_screen}.dart`,
  `test/day_04_test.dart`, `docs/day-04-progress.md`.
- Changed: `lib/models/order.dart`, `lib/core/services/{demo_seed_data,repositories}.dart`,
  `lib/core/routing/app_router.dart` (real `/orders`, `/orders/new`,
  `/orders/:id`, `/orders/:id/edit` routes; Orders leaves the
  placeholder map), `lib/features/dashboard/{dashboard_data.dart
  (labels),dashboard_screen.dart (recent rows → detail)}`,
  `test/{day_03_test,widget_test}.dart` (placeholder expectations →
  real Orders screen), `docs/technical-decisions.md` (D25–D29),
  `docs/sprint-tracker.md`.
- Deleted: `lib/features/orders/.gitkeep` (superseded by real files).

## Verification (24 Nov 2026)
- `flutter analyze` — **No issues found!**
- `flutter test` — **84/84 passed** (47 Day 1–3 + 37 Day 4: status
  flow + guards incl. legacy mapping, prescription dispatch guard,
  timeline, int-paisa totals incl. discount clamp at 0, queue
  filtering/search/branch scoping, create/edit validation, model
  round-trip, repo create/update/status-preservation, rider repo,
  notifier guards, queue/detail/form widget flows incl. advance,
  cancel-with-confirm, create-save, read-only delivered edit, edit
  totals).
- `flutter build web --release` — **PASSED** (136.7s compile;
  `build/web/main.dart.js` 2,890,063 bytes — final build, after the
  seed change below).
- `flutter build apk` — **NOT attempted** (environment-blocked, D14/D15).
- `flutter build windows` / `flutter build ios` — not possible on this
  Linux VM; must be verified on real Windows/macOS hardware.

## Fixes found by testing (not just tests)
- Dropdown values must exist in the item list: while the lookup
  providers are still loading, a set value (e.g. a delivered
  order's customer) with an empty item list crashes
  `DropdownButton` — the form now falls back to null (hint) until
  the data arrives (D29).
- Below-the-fold buttons silently miss taps in tests and on small
  screens — `ensureVisible` before tapping (D24, re-learned).
- Tests must pick live orders by guard (`canAdvance` etc.), not by
  a fixed status: the deterministic seed's "today" mix changed
  when the seed started consuming extra random draws.

## Blockers
Same as Day 1–3 — none new, none Day 4 can clear:
1. **Firebase project does not exist** (Dazy's call; see
   `docs/firebase-setup-plan.md`).
2. **GitHub repo not created** (name/visibility Dazy's call).
3. **Hadi's requirements still awaited** (medicines count, delivery
   areas, payment method, branch cities, logo + brand colours).
4. **APK build environment-blocked** (D14/D15; Day 4 work does not
   depend on it).

## Next step
- **Day 5 (25 Nov):** medicine catalogue + inventory (batches,
  mfg/expiry, buckets 30/60/90/expired, expired never sellable —
  the order form already blocks adding expired batches).
  Day 5 builds on the Day 4 order form's batch/expiry display and
  the Day 3 inventory seed.
