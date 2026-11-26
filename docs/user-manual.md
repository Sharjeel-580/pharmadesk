# PharmaDesk — Staff & Owner User Manual (Week 8 Day 41, 26 Nov 2026)

Plain-language manual for the people who will use PharmaDesk every
day. No jargon: a "branch" is one shop, "POS" is the billing counter
screen, "khata" is a customer's credit ledger, "FEFO" means the
system always sells the batch that expires first.

**This manual describes the demo build** (version `1.0.0+1`): the
screens are real and every step below works, but all data is
fictional sample data and **resets when the app restarts** — nothing
you enter in the demo is kept. Look for the **DEMO MODE** badge on
every screen. The full handover (install steps, what is sample data,
what still needs the Firebase project) is in
`docs/deployment-guide.md`; the scripted demo is in
`docs/demo-guide.md`.

**Everyone starts the same way — signing in:**

1. Open PharmaDesk. The sign-in screen shows five account cards.
2. Tap your card — you are signed in at once. Or type your email and
   the password `demo1234` (the same password for all five demo
   accounts).
3. Your dashboard opens. The top bar shows your branch; the bell
   shows unread alerts.
4. To sign out, use the profile menu at the top-right of the top bar.
5. If you forget the password: on the sign-in screen tap "Forgot
   password", enter your demo email — the screen shows the demo reset
   code (no email is sent) — enter that code plus a new password.

**Switching branch:** the top bar, next to the app name, switches
branch (DHA ↔ Gulberg). Your home branch is fixed per account (see
each role below); only the Owner sees all branches. After switching,
the dashboard, orders, stock and sales figures all change — check
that they did before you act on them.

**If a button is greyed out or a screen says "No permission":** your
role cannot do that step. It is not a fault — ask the Owner or your
branch manager. Only the Pharmacist can approve prescriptions, and
only the Owner can change brand settings, manage branches, or restore
a backup.

---

## Owner — Hassan Raza (`owner@demo.pharmadesk` / `demo1234`)

You see **all branches**. Your day starts on the owner dashboard.

1. **Morning check — dashboard.** Today's sales, 30-day revenue,
   low-stock and near-expiry counts, a 30-day sales chart,
   per-branch performance, top sellers, recent orders and alerts.
   Every card opens its module. DHA is busier than Gulberg — if the
   two branches ever show identical figures, something is wrong.
2. **Alerts — bell, top bar.** Low stock, near-expiry and expired
   batches, pending prescriptions, purchase orders awaiting approval,
   today's new orders. Tap any alert — it opens the right screen.
   Mark read/unread, or Mark all read.
3. **Branch comparison.** The dashboard's branch comparison shows
   both branches side by side. Open **Branches** to see each branch's
   detail, or add a branch (name, code of 2–8 uppercase letters or
   digits, rates). Branch codes are optional — leave blank for the
   default.
4. **Money — Finance.** Cashbook (add income/expense entries),
   Payables & Receivables (who owes you, who you owe — supplier
   payments are recorded here and reduce the payable at once), P&L &
   Statements (per-branch statements and branch comparison).
5. **Reports.** Daily sales, best sellers, low stock, expiry and
   stock valuation. Pick a branch (All / DHA / Gulberg) and a range
   (1 / 7 / 30 days, or custom dates). **Export PDF** downloads a
   real PDF sales report; **Export CSV** downloads the section's data
   (CSV opens in Excel). **Print view** opens a print-friendly page.
   There is no Excel (.xlsx) export in this build.
6. **Staff.** Staff directory, attendance & shifts, salary records.
   You can see everything; branch managers see only their own
   branch's staff.
7. **Settings — the parts only you touch.** General (theme, default
   branch); **Branding** — change the organization name and colours,
   or tap the **Fazal Din preset** for one-tap rebranding to "Fazal
   Din's Pharma Plus", and Reset to go back; **Roles & Permissions**
   — the 10 roles × 24 capabilities matrix (read-only display);
   **Features** — switch a module off and it disappears from the
   sidebar (opening it directly shows "module is disabled").
8. **Backup.** Backup & Restore (`/backup`) is yours (with HO Admin
   and Super Admin). Export a backup JSON regularly and keep the file
   — see the backup/restore steps in `docs/deployment-guide.md` §8.4–8.5.
   Remember: a restore never deletes anything, counters are not
   restored, and split-payment legs are not restored.
9. **What you cannot do:** approve prescriptions (that is the
   Pharmacist's job — your Approve button is disabled on purpose).
   You can sell at POS and you can approve purchase orders and stock
   adjustments.

---

## Branch Manager — Bilal Ahmed (`manager@demo.pharmadesk` / `demo1234`)

You run **Demo Branch — DHA** (your home branch). Your day starts on
the branch dashboard: today's branch sales/orders, pending
prescriptions, and quick actions (New Sale, New Order, Stock Check).

1. **Morning check — branch dashboard.** Today's sales and orders,
   pending prescriptions, low-stock and near-expiry counts for DHA
   only. Quick actions open each module.
2. **Orders — the queue.** Open **Orders**: newest first. Open an
   order to see its status timeline and advance it: New → Confirmed
   → Processing → Ready → Dispatched → Delivered. Assign a rider at
   **Ready** (before dispatch). Delivered is the end — an order
   cannot advance past it.
   - **New Order:** source is Phone, WhatsApp or Walk-in (WhatsApp
     here means manual entry — a staff member takes the order on
     their phone; there is no WhatsApp API). Add items (expired
     batches cannot be added), set an advance payment if taken.
   - **Prescription hold:** if an order is linked to a prescription
     that is still Pending, dispatch is blocked and the screen tells
     you why. It unblocks when the Pharmacist approves the
     prescription — you do not need to do anything to the order.
3. **Counter — Billing / POS.** You can sell at POS in your own
   branch, exactly like a cashier (see the Cashier section). The
   receipt preview opens after a sale; Share copies the receipt text,
   Print opens the web print dialog.
4. **Stock — Inventory.** Stock overview, batches and expiry
   (batches listed earliest-expiry first; expired batches are marked
   and can never be sold). Receive stock, run a stock count, request
   a stock adjustment (you can also approve adjustments in your
   branch), and request/approve stock transfers.
5. **Purchases.** Purchase orders: create one, approve a Draft,
   receive goods (pick quantities, batch numbers, mfg/expiry dates —
   partial receiving is allowed; the batches appear in Inventory at
   once and the supplier payable rises by the received value).
   Cancelling follows the same guards — the screen only offers the
   transitions that are allowed.
6. **Customers & suppliers.** Customer directory with purchase
   history and khata; supplier profiles with purchase history and
   ledger. You cannot record a supplier payment (Owner only).
7. **Staff — your branch.** Attendance & shifts for DHA staff, and
   the staff directory for your branch. You cannot see salary records
   or other branches' staff.
8. **Reports & finance — your branch.** Reports and finance screens
   show DHA figures. You can add income/expense entries; P&L and
   statements are branch-scoped for you.
9. **What you cannot do:** approve prescriptions, record supplier
   payments, see salary records, change brand or feature settings,
   manage branches, or restore backups.

---

## Pharmacist — Dr. Sana Malik (`pharmacist@demo.pharmadesk` / `demo1234`)

You work at **Demo Branch — DHA**. Your main job is the prescription
queue; you can also sell at POS and look up medicines.

1. **Prescriptions — the queue.** Open **Prescriptions**: all of
   DHA's prescriptions with their status (Pending, Approved,
   Rejected, Needs clearer photo). The queue shows the SAMPLE photo
   (bundled asset, marked DEMO ONLY — never a real patient's photo).
2. **Review one.** Open a prescription to see the photo and the
   medicines written on it. Then choose:
   - **Approve** — applies at once. Any order that was held at
     dispatch because of this prescription can now be dispatched;
     you do not need to touch the order.
   - **Reject** — a note is required; say why.
   - **Needs clearer photo** — a note is required; say what is
     unreadable.
   - Approval needs no note. Rejection and "needs clearer photo"
     always need one — the screen will not let you submit without it.
3. **Why it matters:** an order linked to a Pending prescription can
   never be dispatched — the system blocks it and shows the reason.
   Your approval is the unblock. Two prescriptions start Pending for
   exactly this demo: `rx-dha-1` (DHA) and `rx-glb-11` (Gulberg, for
   the Gulberg team).
4. **Counter — Billing / POS.** You can sell in your own branch like
   a cashier (see the Cashier section) — including the FEFO batch
   picker, which always offers the earliest-expiring batch first.
5. **Medicines.** Search the catalogue by name, brand or barcode;
   open a medicine to see its batches, expiry dates and stock per
   branch. You can edit medicine details in your branch.
6. **What you cannot do:** receive stock, adjust stock, manage
   purchase orders or suppliers, record supplier payments, see salary
   records, change settings, or restore backups. You see reports for
   your branch.

---

## Cashier — Usman Tariq (`cashier@demo.pharmadesk` / `demo1234`)

You work the counter at **Demo Branch — Gulberg**. POS is your home
screen.

1. **New sale — Billing / POS → New Sale.**
2. **Add medicines.** Search by name, brand or barcode, or tap
   "Simulate scan" and enter a sample barcode (try Panadol Extra,
   `8901000000001`). The batch picker always offers the
   **earliest-expiring batch first** — that is FEFO, and it is
   automatic; you do not choose the batch by hand.
3. **Expired is blocked.** A medicine whose only batches are expired
   cannot be added at all ("expired batch — never sellable"). If a
   medicine will not add, check its batches in Inventory — do not
   work around it.
4. **Discounts and tax.** Apply a per-line discount and a bill
   discount if the customer is entitled, add tax. The totals update
   as you go.
5. **Pay.** Three ways: **cash** (enter the amount handed over —
   change is computed for you), **card**, or **khata** (adds the sale
   to the customer's credit ledger). For khata, pick the customer
   first: a customer over their credit limit is refused — the screen
   tells you, and the sale does not go through. You can also split a
   payment across methods.
6. **Complete Sale.** The button stays disabled until the cart has
   something in it. Tap it once — a second tap while it is working
   cannot save the sale twice. The **receipt preview** opens: Share
   copies the receipt text, Print opens the web print dialog. The
   sale appears at once in Sales history and on the dashboard.
7. **Sales history.** Billing → Sales history lists your sales with
   invoice numbers; open one to see its receipt again.
8. **New orders.** Orders → New Order: take a phone, WhatsApp
   (manual entry) or walk-in order; add items, set an advance
   payment. Advance orders through their statuses as the Branch
   Manager section describes.
9. **Customers.** Look up a customer, see purchase history and the
   khata balance (outstanding is the sum of the ledger — it is never
   typed in by hand). You can add a manual credit entry or record a
   payment against the khata, with a reason; a payment cannot exceed
   what is owed.
10. **What you cannot do:** receive or adjust stock, manage
    medicines, approve prescriptions, manage purchase orders or
    suppliers, record supplier payments, or change settings. Your
    dashboard is the Gulberg branch dashboard with counter quick
    actions (New Sale, New Order, Stock Check).

---

## Inventory Manager — Fatima Noor (`inventory@demo.pharmadesk` / `demo1234`)

You run stock at **Demo Branch — Gulberg**. Your day starts in
**Inventory**.

1. **Stock overview.** Low-stock items, batches expiring within 30
   days, expired batches. Counts are per batch row: one medicine can
   have 1–3 batch rows per branch, each with its own mfg/expiry
   dates and cost.
2. **Batches & expiry.** Batches are listed earliest-expiry first.
   Expired batches are marked and can never be picked for a sale or
   an order. A batch that expires today counts as expired.
3. **Receive stock.** Inventory → "Receive stock": pick the medicine
   and batch, enter quantity, mfg/expiry dates and cost. The batch
   appears in stock at once. (Receiving a purchase order works the
   same way from Purchases → open the PO → "Receive goods".)
4. **Stock count.** Inventory → "Stock count": count a batch on the
   shelf and record it; differences are recorded as a count, with a
   reason.
5. **Stock adjustment.** Request an adjustment (reason required).
   Adjustments can never take a batch below zero. You request;
   approval is the Owner's or the Branch Manager's.
6. **Stock transfer.** Request a transfer between branches, and
   approve transfers in your branch. The transfer moves through
   Requested → Dispatched → Received; each step is recorded.
7. **Auto purchase list.** Purchases → Auto purchase list: the system
   suggests what to order, one line per medicine, from live stock —
   suggested quantity is the reorder level minus usable (non-expired,
   in-stock) stock; a line appears only when something is actually
   needed. Reasons are Low stock, Near expiry with low usable stock,
   or Below reorder level. Medicines already on an open purchase
   order are excluded. Review the lines, change quantities or the
   supplier per line, then approve — one purchase order is created
   per supplier (Draft). Approving twice with the same tap cannot
   create the orders twice.
8. **Purchase orders.** Create, view and receive them; approve a
   Draft PO. Partial receiving is allowed — a partly received PO
   stays open for the rest.
9. **Suppliers & medicines.** Supplier profiles, contacts, purchase
   history and ledgers (view only — you cannot record a supplier
   payment). Medicine catalogue: search, view batches, edit medicine
   details in your branch.
10. **Reports.** Reports for your branch (stock valuation, expiry,
    low stock). You can see finance screens for your branch but you
    cannot add finance entries.
11. **What you cannot do:** sell at POS, approve prescriptions,
    record supplier payments, approve stock adjustments, see salary
    records, change brand or feature settings, or restore backups.

---

## Every role — the things that are the same for everyone

- **Notifications (bell, top bar).** Low-stock, near-expiry,
  pending prescriptions, purchase orders awaiting approval, today's
  new orders. Tap an alert to open the right screen. These are
  computed from the data at load time — they are not push
  notifications, and nothing is sent to your phone.
- **Reports.** Everyone sees the reports for their branch; only the
  Owner sees all branches. Export CSV downloads the section's data;
  Export PDF downloads a real PDF sales report.
- **Audit log.** Every stock and money change is recorded with who
  did it and the before/after figures. The log is append-only —
  entries are never edited or deleted.
- **Offline.** A completed sale is queued for sync when there is no
  connection; the queue is held until the backend exists. On the web
  the queue resets on restart.
- **Quarantine.** A batch that fails a check can be quarantined
  (Inventory → quarantine outcomes). Quarantined stock is not
  sellable and is excluded from usable stock until it is decided.
- **If the app shows "Page not found":** use "Go to Dashboard". If a
  screen looks empty, check the branch in the top bar first — you
  may be looking at the other branch's data.
- **If something does not match this manual:** note the screen, the
  role you signed in as, and the exact steps, and report it — do not
  work around it, especially on money or stock steps.
