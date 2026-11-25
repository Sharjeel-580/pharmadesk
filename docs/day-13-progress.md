# Day 13 — Week 3 Day 1 progress: Firestore implementations for the six Day 5 repos

**Date:** 25 Nov 2026. **Status:** DONE.
**Decisions:** D99–D101 in `docs/technical-decisions.md`.

## What was built

### 1. Firestore repositories for the six Day 5 repos

Six new classes in `lib/core/data/firestore_repositories.dart`, behind
the existing interfaces — no screen rewrites, mock behaviour unchanged:

- `FirestoreStaffRepository` — `branches/{branchId}/employees`
- `FirestoreAttendanceRepository` — `branches/{branchId}/attendances`
- `FirestoreShiftRepository` — `branches/{branchId}/shifts`
- `FirestoreExpenseRepository` — `branches/{branchId}/expenses`
- `FirestoreFinancialTransactionRepository` — `branches/{branchId}/financialTransactions`
- `FirestoreSupplierPaymentRepository` — `branches/{branchId}/supplierPayments`

Same Day 3 conventions (D73): transport seam only, `fetchAll` paging,
branch enumeration for null-branch reads, client-side filters where
Firestore cannot compare fields (attendance date/employee, payment
supplier). Updates preserve the original `createdAt` and no-op on a
missing id, exactly like the mocks.

### 2. Mappers for all six collections

In `lib/core/data/firestore_mappers.dart`, each `*ToFirestore` validates
via `validateOrThrow` against the §3 contract:

- **Staff:** `active` bool ↔ `status` string (`active` / `disabled`);
  `email` / `role` / `roleKey` extras; legacy bool `active` accepted on
  read. Salary / joiningDate never written (D99).
- **Attendance:** calendar day + check-in/out as Timestamps, status as
  the enum name, `note` extra.
- **Shift:** `HH:MM` strings stay strings, `employeeIds` stays a
  `string[]`.
- **Expense:** category name written into both `categoryId` (§3) and the
  `category` extra; read prefers `category`, falls back to `categoryId`.
- **Financial transaction:** type snake_case in §3
  (`supplier_payment` / `customer_payment`); signed int paisa kept.
- **Supplier payment:** method enum name (read also accepts
  snake_case), `paidAt` Timestamp, FIFO allocations embedded as a list
  of `{ledgerEntryId, amount}` maps on the doc (D92).

### 3. Schema contract extensions (D99)

`firestore_schema.dart` §3.6/§3.7: `supplierPayments` gains `paidAt`
(required) + `allocations`; `employees` gains `email`/`role`/`roleKey`;
`attendances` gains `note`; `expenses` gains `category`. All four
extensions are marked in the contract with their reason. `salary` /
`joiningDate` stay listed but are never written — the Staff model has
neither, so they would be invented.

### 4. Idempotency + validation (D100)

- Caller-supplied non-empty id = doc id on all six creates (D65
  pattern): a retry returns the existing document. Empty id = Firestore
  auto-id, like the mocks. Attendance upsert is idempotent by
  construction (same id overwrites the same doc), so the append-only
  transaction collection never double-appends on retry.
- Repository validation mirrors the mocks + the providers' pure
  validators: staff name/branch required, phone uniqueness org-wide on
  digits; expense amount > 0 + fixed-list category; transaction amount
  ≠ 0; payment supplier required, amount > 0, non-empty allocations
  must sum to the payment (empty list accepted).

### 5. Factory wiring (D101, closes D89)

`RepositoryBundle` gains the six repos (both kinds); the six providers
in `lib/core/services/repositories.dart` now read from the bundle
instead of owning a mock instance each. Mock bundle stays the default;
a Firestore-bundle override switches all six at once, like the Day 3
repos. Firestore kind without a transport still throws `StateError`.

## Verification

- `flutter analyze` — **No issues found!** (one info-level lint fixed
  in-day: a fold parameter named `sum` shadowed a type name)
- New tests **51/51** (`test/week3_day01_test.dart`): schema-contract
  extensions, mapper round-trips (all six + legacy/edge reads),
  `validateOrThrow` failures per collection, repo CRUD + branch scoping
  + filters, idempotency retries, validation failures, factory wiring
  (mock default, Firestore-kind StateError, provider override
  end-to-end). One test was fixed in-day (my own test bug: the payment
  idempotency retry changed the amount but kept the original
  allocations, so the allocation-sum guard correctly fired first).
- Full suite **445/445** (191 Week 1 + 203 Week 2 + 51 Day 1) — no
  earlier test was updated or broken.
- `flutter build web --release` — **Pass** (46,341,002 bytes);
  prescription PNGs verified bundled (114,613 + 110,613 bytes, D61
  check).

## No earlier-test updates

None. The Day 5 mocks and screens are untouched; the providers serve
the same mock instances through the bundle as before.

## Follow-ups for Day 2

- `goodsReceipts` document + receiving routed through the production
  data layer (D95) — still open.
- Salary screen (gates on the existing `hrSalary` capability) — still
  open. Note for that work: the Firestore staff mapper deliberately
  does NOT write `salary` (D99) — the salary screen will need a
  decision on where salary figures live (model field vs. a separate
  payroll record) before the mapper can carry them.
- Live verification against a real Firestore (rules unit tests,
  emulator runs) is still blocked on the Firebase project (Dazy-only).
- The `branches` list read (`branchIds()`) is the one extra read
  every null-branch call makes — same as Day 3; at 8-branch scale
  this is fine, but a cached branch list would help if list calls
  grow.
