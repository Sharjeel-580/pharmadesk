# Day 12 — Week 2 Day 5 progress: Staff & HR + ledgers + prescriptions + advanced analytics

**Date:** 25 Nov 2026. **Status:** DONE — Week 2 build complete; QA pass next.
**Decisions:** D89–D98 in `docs/technical-decisions.md`.

## What was built

### 1. Staff & HR basics (new `lib/features/staff/`)

- **Staff directory** (`staff_list_screen.dart`, route `/staff`): CRUD, branch
  assignment, job title, phone, active/inactive, search. Role assignment
  from the 10 SRS §5.1 roles (`roleKey` on the extended `Staff` model,
  `effectiveRoleKey` falls back to the legacy `StaffRole` map; a rider
  maps to literal `'rider'` → permission service returns `none`).
  Add/edit dialog with the 10-role dropdown; read-only roles see the
  permission explanation instead of the buttons.
- **Attendance** (`attendance_screen.dart`, route `/staff/attendance`):
  today's rows for the active branch, summary StatCards, check-in /
  check-out, mark absent / on leave. One check-in per employee per day;
  inactive staff refused; late = check-in after shift start + 15-min
  grace (D89); under 4 hours worked = half day; late wins over half day.
- **Shifts** (`shifts_screen.dart`, route `/staff/shifts`): create/edit
  with `HH:MM` start/end and staff checkboxes; end must be after start
  the same day (overnight shifts out of scope, D89); at least one
  employee assigned.
- **Logic** (`hr_logic.dart`): `canManageStaff` (`users` capability),
  `canManageHr` (`hrAttendance`), `validateStaff` (name/job title/phone
  required, phone ≥ 10 digits, duplicate phone rejected on digits,
  email must contain `@` if given, roleKey must be one of the 10 SRS
  keys), `searchStaff`, `validateShift`, `staffRoleForRoleKey`,
  `attendanceStatusFor`, `validateCheckIn` / `validateCheckOut`,
  `todaysAttendance` + counts.
- **Providers** (`staff_provider.dart`): `StaffDirectoryNotifier`,
  `AttendanceNotifier`, `ShiftsNotifier` + `staffProvider`,
  `staffByIdProvider`, `branchStaffProvider`, `attendanceProvider`,
  `todayAttendanceProvider`, `shiftsProvider`, `branchShiftsProvider`.
  All mutations gated through `permissionService` + `authProvider`.
- **Seed:** 10 fictional staff (7 DHA, 3 Gulberg), 3 shifts
  (Morning/Evening DHA, Morning Gulberg), roleKeys spanning owner,
  branch_manager, pharmacist, cashier, inventory_manager, accountant.
- **Matrix:** two new capabilities — `hrAttendance` (Owner/HO allowed,
  Branch Mgr own, Auditor read-only) and `hrSalary` (Owner/HO/Accountant
  allowed, Auditor read-only). Capabilities are now **23 (was 21)**;
  feature modules are now **11 (was 10)**; app modules are **15 (was 14)**.

### 2. Purchase/supplier ledgers fully wired

- **New models:** `Expense` (fixed categories: Rent, Utilities,
  Salaries, Transport, Supplies, Marketing, Maintenance, Other),
  `FinancialTransaction` (signed int paisa; income/expense/
  supplierPayment/customerPayment/adjustment), `SupplierPayment`
  (method cash/bankTransfer/cheque/online, `PaymentAllocation`
  ledgerEntryId + amountMinor, `unallocatedMinor`).
- **New repos** (mock-backed providers, `lib/core/services/repositories.dart`):
  `StaffRepository`, `AttendanceRepository`, `ShiftRepository`,
  `ExpenseRepository`, `FinancialTransactionRepository` (append-only),
  `SupplierPaymentRepository`. Firestore implementations deferred to
  the Firebase-wiring chunk (D89); schema paths already exist in
  `firestore_schema.dart` §3.6/§3.7.
- **Supplier payments** (`finance_logic.dart` + `finance_provider.dart`):
  payment → allocated oldest-first (FIFO) against open payables,
  allocations sum to the payment, overpayment refused; writes the
  payment record + a negative supplier-ledger entry + a negative
  `financialTransactions` supplierPayment entry; invalidates ledger /
  outstanding / transactions / advanced reports. Gated on `supplierPay`
  (Owner/HO/Accountant only).
- **Aging** (D92): Current 0–30, 31–60, 61–90, 90+ days; `openPayableBalances`,
  `computeAging`, `supplierLedgerSignedEntries`, `allocateSupplierPayment`,
  `validateSupplierPayment`, `validateExpense`, `supplierStatement`
  (oldest-first; stored `balanceAfterMinor` is the running balance),
  `supplierStatementCsv`. Customer khata aging uses the same FIFO buckets
  (`customerAgingProvider`).
- **Screens:** supplier detail shows payable aging chips, a gated
  "Record payment" (method dropdown + reference field), "Export statement
  (CSV)" (web download, selectable-text dialog elsewhere), and a
  "Payments" section with allocation counts. Customer detail shows khata
  aging chips when outstanding > 0. Khata payments now also write a
  positive `customerPayment` financial transaction (credit sales and
  adjustments write none — they are not money movement).
- **Expenses module:** record expenses by category, branch-scoped, date
  picker (max today); each expense writes a matching negative
  `financialTransactions` expense entry. 9 fictional expenses seeded
  over the last 30 days (DHA rent Rs 85,000, salaries Rs 120,000,
  utilities Rs 18,500, transport Rs 3,200, supplies Rs 4,500; Gulberg
  rent Rs 60,000, salaries Rs 75,000, utilities Rs 12,000, maintenance
  Rs 2,800).
- **Route-gate finding (D94):** the Day 3 `FeatureGate` maps
  `/suppliers` to `supplierPay`, on which a Branch Manager is `none` —
  so the gate stops them before the detail screen. The screen-level
  disabled button is for read-only roles (Auditor). Mapping unchanged;
  both paths are tested.

### 3. Prescription workflow hardened

- **Validity (D90):** `validUntil` + `resubmissionCount` on
  `Prescription` (model, Firestore schema + mappers, both repo
  implementations). Default validity 30 days from issue; the
  new-prescription dialog shows the date with a "Change date" picker
  (range today → +365 days). Null validity on legacy records = valid.
  Seeded prescriptions carry validity; the 2nd prescription of each
  branch is seeded already expired — never the forced-Pending linked
  record, so the Day 7 hold → approve → dispatch path is unaffected.
  The Day 4 dispatch guard now also blocks an approved-but-expired
  prescription.
- **Re-review (D91):** rejected / needs-clearer-photo records can be
  re-submitted (detail-screen button gated by `canResubmitFor` =
  `canWrite(posSell)` OR `canWrite(rxReview)` in-branch); re-submit
  returns the record to Pending, clears the previous review, sets a new
  future validity date, increments `resubmissionCount`.
- **Detail screen:** validity badge (Valid until / Expired), resubmission
  count note, linked-order text distinguishes pending vs approved-but-
  expired. Badge row changed Row → Wrap (D96: it overflowed 36px at
  800px phone width once the third badge was added).
- Review actions remain gated by the permission service per the SRS
  matrix; photo handling still uses the Day 3 Storage path with the
  on-device fallback (bundled samples stay samples).

### 4. Advanced analytics / reports (extends the existing reports screen)

- **Logic** (`lib/features/reports/analytics_logic.dart`):
  `computeProfitAndLoss` (revenue = windowed non-cancelled orders + POS
  sales, refunds subtracted; COGS via D81 — sold batch `costMinor`,
  fallback purchase price; expenses from `expenses`; other income from
  `financialTransactions` type `income`; refunds reduce revenue only,
  COGS not clawed back — D93), `computeWeeklyTrend` (7-day buckets),
  `computeSlowMovers` (stocked + unsold in window, worst stock value
  first, top 10; zero-stock excluded as out-of-stock), `computeExpiryLoss`
  (expired batches at cost), `computeBranchAnalytics` (per-branch sales,
  gross profit, stock value, outstanding with D79 attribution, expiry
  loss).
- **Providers** (`reports_provider.dart`): `AdvancedReportData` +
  `advancedReportDataProvider` family `(branchId, days)`.
- **Screen** (`reports_screen.dart`): weekly sales trend, branch
  comparison (with D79 footnote), slow movers, expiry loss with total
  value, P&L (revenue/COGS/gross/other income/expenses/net), expenses
  list with a gated "Record expense" dialog. CSV export for every new
  section via the existing `_exportCsv` helper
  (`weeklyTrendCsv`, `branchComparisonCsv`, `slowMoversCsv`,
  `profitLossCsv`, `expiryLossCsv` — the expiry-loss CSV carries a
  total-loss summary row; per-row money is omitted because report rows
  carry no batch cost and inventing one would be wrong).

### 5. Navigation

- `Staff & HR` module (`/staff`, `Icons.badge_outlined`,
  "Week 2 — Day 5") in `appModules`, routes `/staff`,
  `/staff/attendance`, `/staff/shifts`; sidebar Manage group + mobile
  More sheet, with Attendance/Shifts sub-items (same pattern as
  Purchases/Auto and Billing/Returns); `staff` feature module in
  `feature_config.dart`. Everything works on mobile AND desktop
  (verified at 800×1600 and 1280×800 in tests); Kalora design system,
  Inter, light theme (dark theme via the shared theme, unchanged).

## Files changed

**Created:** `lib/models/attendance.dart`, `lib/models/shift.dart`,
`lib/models/expense.dart`, `lib/models/financial_transaction.dart`,
`lib/models/supplier_payment.dart`, `lib/features/staff/hr_logic.dart`,
`lib/features/staff/staff_provider.dart`,
`lib/features/staff/staff_list_screen.dart`,
`lib/features/staff/attendance_screen.dart`,
`lib/features/staff/shifts_screen.dart`,
`lib/features/finance/finance_logic.dart`,
`lib/features/finance/finance_provider.dart`,
`lib/features/reports/analytics_logic.dart`,
`test/week2_day05_test.dart`.

**Edited:** `lib/models/staff.dart`, `lib/models/prescription.dart`,
`lib/models/models.dart`, `lib/core/services/demo_seed_data.dart`,
`lib/core/services/repositories.dart`,
`lib/features/settings/roles_permissions.dart`,
`lib/features/settings/feature_config.dart`,
`lib/core/routing/app_router.dart`, `lib/app/shell/app_shell.dart`,
`lib/core/data/firestore_schema.dart`,
`lib/core/data/firestore_mappers.dart`,
`lib/core/data/firestore_repositories.dart`,
`lib/features/prescriptions/prescriptions_logic.dart`,
`lib/features/prescriptions/prescriptions_provider.dart`,
`lib/features/prescriptions/prescription_detail_screen.dart`,
`lib/features/prescriptions/prescription_list_screen.dart`,
`lib/features/orders/order_logic.dart`,
`lib/features/orders/order_detail_screen.dart`,
`lib/features/orders/orders_provider.dart`,
`lib/features/reports/reports_provider.dart`,
`lib/features/reports/reports_screen.dart`,
`lib/features/suppliers/supplier_detail_screen.dart`,
`lib/features/customers/customer_detail_screen.dart`,
`lib/features/customers/customers_provider.dart`,
`test/day_02_test.dart`, `test/day_07_test.dart` (deliberate updates —
see D97).

## Verification

| Target | Result |
|---|---|
| `flutter analyze` | **Clean — No issues found** |
| New tests `test/week2_day05_test.dart` | **60/60 PASS** (logic: HR validation/roles/permissions, shifts/attendance rules, aging/allocation, supplier statement CSV, prescription validity + re-review + dispatch guard, P&L/trend/slow movers/expiry loss/branch comparison, CSV content; providers: staff CRUD gating, attendance check-in/out, shifts, expense mirror, supplier payment allocation end-to-end, Firestore mapper round-trip; widgets: staff search + add, attendance check-in/out, shifts list, supplier aging + payment + payments list, Branch Manager route gate, Auditor disabled button, prescription re-review, reports sections) |
| Full suite `flutter test` | **394/394 PASS** (334 before Day 5 + 60 new Day 5 tests). First full run was 393/394 — one Day 4 printer widget test failed because the Day 5 sidebar additions pushed 'Settings' out of the initially-built ListView range; fixed by scrolling first (D98) and the re-run is green. |
| `flutter build web --release` | **Pass — ✓ Built build/web, 46,323,939 bytes** |
| Prescription PNGs bundled (D61 check) | **Pass** — both PNGs on disk in `build/web/assets/assets/images/prescriptions/` (114,613 + 110,613 bytes) and in the decoded manifest (8 "prescription" mentions, both sample paths present). Note: `AssetManifest.bin.json` is a base64 blob — raw grep returns 0; decode first (D61). |

## Test updates to earlier files (deliberate, D87 pattern — see D97)

- `test/day_07_test.dart`: roles matrix 21 → 23 capabilities; feature
  modules 10 → 11; route walk 14 → 15 routes (`/staff` added);
  supplier-payment widget test expects 3 dialog fields (amount + reason
  + reference).
- `test/day_02_test.dart`: desktop sidebar 14 → 15 modules
  (`Staff & HR` added in sidebar order).

## What did NOT change

- No Firebase project, credentials, `google-services.json`, billing, or
  `Firebase.initializeApp()` — factory default stays MOCK.
- No prices in code (all figures live only in the proposal/video).
- No customer app. No changes to `presentation-video/`.
- Day 7 order-unblock behaviour intact (hold → approve → dispatch);
  the Day 4 dispatch guard only gained the expiry condition.
- The seeded supplier ledger's historical MedServe payment
  (Rs 11,750) stays a ledger entry only — payment records exist only
  from the Day 5 allocation flow onward.

## Blockers (unchanged, Dazy-only)

- Firebase project + billing creation (his Google account + card).
- Hadi requirements still unknown — medicines count, delivery areas,
  payment method, branch cities, logo/brand colours. Never invented.
- APK build environment-blocked in this sandbox (Gradle/Kotlin issue);
  CI on GitHub Actions is the path. Windows/iOS unverifiable here.

## Follow-ups (not Day 5)

- Firestore implementations for the six new repos (Staff, Attendance,
  Shift, Expense, FinancialTransaction, SupplierPayment) — Firebase-
  wiring chunk; schema contracts already exist.
- `goodsReceipts` document + routing receiving through the production
  data layer (D95 — functionally covered by Day 7 receiving).
- Salary screen (gates on the existing `hrSalary` capability).
