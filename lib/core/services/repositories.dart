import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/attendance.dart';
import '../../models/branch_inventory_location.dart';
import '../../models/branch.dart';
import '../../models/cash_reconciliation.dart';
import '../../models/closing_correction.dart';
import '../../models/customer.dart';
import '../../models/customer_ledger.dart';
import '../../models/daily_closing.dart';
import '../../models/expense.dart';
import '../../models/financial_transaction.dart';
import '../../models/goods_receipt.dart';
import '../../models/inventory_item.dart';
import '../../models/medicine.dart';
import '../../models/order.dart';
import '../../models/prescription.dart';
import '../../models/purchase_order.dart';
import '../../models/rider.dart';
import '../../models/sale.dart';
import '../../models/sale_return.dart';
import '../../models/salary_record.dart';
import '../../models/stock_adjustment_request.dart';
import '../../models/stock_transfer.dart';
import '../../models/shift.dart';
import '../../models/staff.dart';
import '../../models/supplier.dart';
import '../../models/supplier_ledger.dart';
import '../../models/supplier_payment.dart';
import '../data/repository_factory.dart';
import '../data/report_counters.dart';
import '../../features/medicines/medicine_logic.dart';
import 'branch_context.dart';
import 'demo_seed_data.dart';

/// Repository interfaces — the contract between presentation/state and
/// data sources. Screens and providers depend ONLY on these abstractions.
///
/// Day 1 ships **mock** implementations (sample data, no backend) so the
/// UI sprint can run before the Firebase project exists. In Week 2 the
/// mocks are swapped for Firestore implementations behind the same
/// interfaces — no screen rewrites.
///
/// Free-tier note: Firestore implementations must use efficient queries,
/// pagination and batched writes to stay inside Firebase Spark quotas
/// (permanent free backend — no Blaze). See docs/technical-decisions.md.

abstract class MedicineRepository {
  Future<List<Medicine>> getMedicines({String? branchId});
  Future<Medicine?> getById(String id);
  Future<Medicine?> getByBarcode(String barcode);

  /// Replaces a whole medicine (Week 4 Day 5, D138 — the location
  /// edit). The id must already exist; throws [ArgumentError] when
  /// it does not. Week 6 Day 4 (D166): also throws [ArgumentError]
  /// when the medicine's barcode is already used by a DIFFERENT
  /// medicine — barcode uniqueness is enforced here, in the repo,
  /// not the form (Day 25 follow-up). Keeping the medicine's own
  /// barcode, or an empty / absent barcode, never throws.
  /// Returns the saved medicine.
  Future<Medicine> updateMedicine(Medicine medicine);

  /// Creates or replaces a medicine by id (Week 5 Day 2, D150 —
  /// restore upsert-by-id): an existing id is replaced in place, a
  /// new id is inserted as given (an empty id gets a minted one).
  /// Unlike [updateMedicine] this never throws for a missing id,
  /// and unlike a create it never re-checks uniqueness — a restore
  /// replays data that was valid when exported. Returns the saved
  /// medicine.
  Future<Medicine> upsertMedicine(Medicine medicine);
}

abstract class OrderRepository {
  Future<List<Order>> getOrders({String? branchId});
  Future<Order?> getById(String id);
  Future<void> updateStatus(String id, OrderStatus status);

  /// Saves a new order (Day 4). The repository assigns the order id
  /// and returns the saved order.
  Future<Order> createOrder(Order order);

  /// Replaces a whole order (Day 4 edit: items, quantities, discount,
  /// rider, notes). The id must already exist.
  Future<void> updateOrder(Order order);

  /// Creates or replaces an order by id (Week 5 Day 2, D150 —
  /// restore upsert-by-id): an existing id is replaced in place, a
  /// new id is inserted as given (an empty id gets a minted one).
  /// The order number is repo-assigned on insert (same sequence as
  /// [createOrder]); an existing order keeps its number. Returns
  /// the saved order.
  Future<Order> upsertOrder(Order order);
}

abstract class InventoryRepository {
  Future<List<InventoryItem>> getInventory({String? branchId});
  Future<List<InventoryItem>> getLowStock({String? branchId});
  Future<List<InventoryItem>> getExpiringWithin({
    int days = 30,
    String? branchId,
  });

  /// Receives new stock (Day 5): adds a batch row for [medicineId] at
  /// [branchId] and returns the created row. [costMinor] is the cost
  /// price per unit in paisa.
  Future<InventoryItem> receiveStock({
    required String branchId,
    required String medicineId,
    required String batchNo,
    required DateTime mfgDate,
    required DateTime expiryDate,
    required int quantity,
    required int costMinor,
  });

  /// Adjusts one batch's quantity by [deltaQty] (positive = found /
  /// corrected up, negative = damaged / lost / written off). [reason]
  /// is required by the caller. Throws [ArgumentError] when the result
  /// would go below zero. Returns the updated row.
  Future<InventoryItem> adjustStock({
    required String batchId,
    required int deltaQty,
    required String reason,
  });

  /// Records a physical stock count for one batch: the system quantity
  /// becomes [countedQty]. Throws [ArgumentError] when [countedQty] is
  /// negative. Returns the updated row (the caller computes the
  /// variance from the pre-count quantity).
  Future<InventoryItem> recordStockCount({
    required String batchId,
    required int countedQty,
    String? note,
  });

  /// Sets a batch's status — used for quarantine / un-quarantine
  /// (Week 4 Day 5, D140 — SRS D-11). `reason` is recorded for the
  /// audit trail. The quantity is untouched: quarantine parks a
  /// batch out of the saleable pool, it does not write it off.
  /// Throws [ArgumentError] when the batch does not exist.
  Future<InventoryItem> updateBatchStatus({
    required String batchId,
    required BatchStatus status,
    String? reason,
  });

  /// Creates or replaces one batch row by id (Week 5 Day 2, D150 —
  /// restore upsert-by-id): an existing id is replaced in place
  /// (quantity, status and dates as given), a new id is inserted as
  /// given (an empty id gets a minted one). The per-(branch,
  /// medicine) on-hand counter is NOT recomputed here — counters
  /// are rollup state and are not part of a backup. Returns the
  /// saved row.
  Future<InventoryItem> upsertInventoryItem(InventoryItem item);

  /// Per-branch rack / shelf override for one medicine (Week 5 Day 3,
  /// D152 — SRS §3.3 `branches/{branchId}/inventory` doc). Returns
  /// the override, or `null` when the branch keeps the medicine at
  /// the master default shelf (no record, or a record with both
  /// fields empty).
  Future<BranchInventoryLocation?> getBranchLocation({
    required String branchId,
    required String medicineId,
  });

  /// All rack / shelf overrides at one branch (or every branch when
  /// [branchId] is omitted). Records with both fields empty are
  /// never returned — they are not overrides.
  Future<List<BranchInventoryLocation>> getBranchLocations({String? branchId});

  /// Saves a per-branch rack / shelf override (D152). Saving with
  /// both rack and shelf empty CLEARS the override — the branch
  /// falls back to the master location — and returns the cleared
  /// (empty) record. Returns the saved override.
  Future<BranchInventoryLocation> saveBranchLocation(
    BranchInventoryLocation location,
  );
}

abstract class CustomerRepository {
  Future<List<Customer>> getCustomers();
  Future<Customer?> getById(String id);

  /// Saves a new customer (Day 6). The repository assigns the id.
  /// Throws [ArgumentError] when another customer already has the
  /// same phone number (digits compared, formatting ignored).
  ///
  /// [branchId] is the branch the customer belongs to. The mock
  /// ignores it (customers are org-wide in the demo); the Firestore
  /// implementation requires it (customers live in branch
  /// subcollections) — callers pass the active branch.
  Future<Customer> createCustomer(Customer customer, {String? branchId});

  /// Khata (credit ledger) entries for one customer, oldest first.
  Future<List<LedgerEntry>> getLedgerEntries(String customerId);

  /// Appends one ledger entry (Day 6). The repository assigns the id
  /// and computes [LedgerEntry.balanceAfterMinor] from the customer's
  /// current outstanding, so the statement never drifts. The ledger
  /// is append-only — entries are never edited or deleted.
  Future<LedgerEntry> addLedgerEntry(LedgerEntry entry);

  /// Creates or replaces a customer by id (Week 5 Day 2, D150 —
  /// restore upsert-by-id): an existing id is replaced in place, a
  /// new id is inserted as given (an empty id gets a minted one).
  /// No phone-uniqueness check — a restore replays data that was
  /// valid when exported. [branchId] is the branch the customer
  /// belongs to; the mock ignores it (customers are org-wide in
  /// the demo) and the Firestore implementation files the doc
  /// under it (falling back to the first branch when omitted).
  /// Returns the saved customer.
  Future<Customer> upsertCustomer(Customer customer, {String? branchId});

  /// Creates or replaces one khata entry by id (Week 5 Day 2, D150
  /// — restore upsert-by-id): an existing id is replaced in place,
  /// a new id is inserted as given. Unlike [addLedgerEntry] the
  /// [LedgerEntry.balanceAfterMinor] is kept exactly as given — a
  /// restore replays history, it does not recompute it. Returns the
  /// saved entry.
  Future<LedgerEntry> upsertLedgerEntry(LedgerEntry entry, {String? branchId});
}

/// Completed counter (POS) sales (Day 6).
///
/// The mock keeps sales in memory for the session. Week 2 stores them
/// under `branches/{branchId}/sales/{saleId}` with the doc id = the
/// sale's client-generated idempotency key (SRS FR-POS-11), so a
/// retried write can never create a duplicate sale.
abstract class SaleRepository {
  Future<List<Sale>> getSales({String? branchId});
  Future<Sale?> getById(String id);

  /// Saves a completed sale. The repository assigns the id and the
  /// sequential per-branch invoice number (`INV-DHA-1001`, …) and
  /// returns the saved sale.
  Future<Sale> createSale(Sale sale);

  /// Replaces a whole sale (Week 2 Day 4: returns move the sale
  /// status to `partiallyReturned` / `returned`, FR-POS-08). The id
  /// must already exist; the invoice number and idempotency key are
  /// never changed here.
  Future<void> updateSale(Sale sale);

  /// Creates or replaces a sale by id (Week 5 Day 2, D150 —
  /// restore upsert-by-id): an existing id is replaced in place
  /// (status, totals and items as given), a new id is inserted as
  /// given (an empty id gets a minted one). The invoice number and
  /// idempotency key are kept as given — a restore replays history,
  /// it does not re-number it. Returns the saved sale.
  Future<Sale> upsertSale(Sale sale);
}

/// Returns / refunds against completed POS sales (Week 2 Day 4,
/// SRS §3.4 `branches/{branchId}/saleReturns`, FR-POS-08).
///
/// The mock keeps returns in memory for the session. Week 2 stores
/// them under `branches/{branchId}/saleReturns/{returnId}` with the
/// `items` subcollection; the return record itself is append-only —
/// returns are never edited or deleted.
abstract class SaleReturnRepository {
  Future<List<SaleReturn>> getReturns({String? branchId});

  /// All returns recorded against one sale, oldest first.
  Future<List<SaleReturn>> getReturnsForSale(String saleId);

  /// Saves a new return. The repository assigns the id and stamps
  /// `createdAt`, and returns the saved return.
  Future<SaleReturn> createReturn(SaleReturn saleReturn);
}

abstract class SupplierRepository {
  Future<List<Supplier>> getSuppliers();
  Future<Supplier?> getById(String id);

  /// Saves a new supplier (Day 7). The repository assigns the id.
  /// Throws [ArgumentError] when another supplier already has the
  /// same phone number (digits compared, formatting ignored).
  Future<Supplier> createSupplier(Supplier supplier);

  /// Saves an edited supplier (Day 7). The id must already exist.
  Future<void> updateSupplier(Supplier supplier);

  /// Payables ledger entries for one supplier, oldest first.
  Future<List<SupplierLedgerEntry>> getLedgerEntries(String supplierId);

  /// Appends one ledger entry (Day 7). The repository assigns the id
  /// and computes [SupplierLedgerEntry.balanceAfterMinor] from the
  /// supplier's current outstanding, so the statement never drifts.
  /// The ledger is append-only — entries are never edited or deleted.
  Future<SupplierLedgerEntry> addLedgerEntry(SupplierLedgerEntry entry);

  /// Creates or replaces a supplier by id (Week 5 Day 2, D150 —
  /// restore upsert-by-id): an existing id is replaced in place, a
  /// new id is inserted as given (an empty id gets a minted one).
  /// No phone-uniqueness check — a restore replays data that was
  /// valid when exported. Returns the saved supplier.
  Future<Supplier> upsertSupplier(Supplier supplier);

  /// Creates or replaces one payables entry by id (Week 5 Day 2,
  /// D150 — restore upsert-by-id): an existing id is replaced in
  /// place, a new id is inserted as given. Unlike [addLedgerEntry]
  /// the [SupplierLedgerEntry.balanceAfterMinor] is kept exactly as
  /// given — a restore replays history, it does not recompute it.
  /// Returns the saved entry.
  Future<SupplierLedgerEntry> upsertLedgerEntry(SupplierLedgerEntry entry);
}

abstract class PrescriptionRepository {
  Future<List<Prescription>> getPrescriptions({String? branchId});
  Future<List<Prescription>> getPending({String? branchId});
  Future<Prescription?> getById(String id);

  /// Records a pharmacist review (Day 7): sets the status to
  /// [status] (approved / rejected / needsClearerPhoto), the reviewer
  /// and the note, and stamps `reviewedAt`. Returns the updated
  /// record, or `null` when the id does not exist.
  Future<Prescription?> reviewPrescription({
    required String id,
    required PrescriptionStatus status,
    required String reviewedBy,
    String? reviewNotes,
  });

  /// Re-submits a rejected / needs-clearer-photo prescription for
  /// review (Week 2 Day 5, D91): sets the status back to Pending,
  /// clears the previous review (reviewer, time, note), sets the
  /// new [validUntil], and increments `resubmissionCount`. Returns
  /// the updated record, or `null` when the id does not exist.
  /// The caller validates (see `validateResubmit`) before calling.
  Future<Prescription?> resubmitPrescription({
    required String id,
    required DateTime validUntil,
  });

  /// Saves a manually created prescription (Day 7, new-prescription
  /// form). The repository assigns the id; the record starts Pending.
  ///
  /// [branchId] is the branch the prescription belongs to (the
  /// caller passes the active branch). The mock falls back to the id
  /// prefix when it is absent; the Firestore implementation requires
  /// it (or a branch id on the record itself).
  Future<Prescription> createPrescription(
    Prescription prescription, {
    String? branchId,
  });

  /// Creates or replaces a prescription by id (Week 5 Day 2, D150
  /// — restore upsert-by-id): an existing id is replaced in place
  /// (status, review and dates as given — unlike [createPrescription]
  /// the status is NOT reset to Pending), a new id is inserted as
  /// given (an empty id gets a minted one). [branchId] falls back
  /// to the id prefix / the record's own branch, as in
  /// [createPrescription]. Returns the saved record.
  Future<Prescription> upsertPrescription(
    Prescription prescription, {
    String? branchId,
  });
}

/// Purchase orders (Day 7, SRS FR-PUR-01/02).
///
/// The mock keeps POs in memory for the session. Week 2 stores them
/// under `branches/{branchId}/purchaseOrders/{poId}` with the
/// `items` subcollection; goods receiving creates batches +
/// stockTransactions in the same write (FR-PUR-03).
abstract class PurchaseOrderRepository {
  Future<List<PurchaseOrder>> getPurchaseOrders({
    String? branchId,
    String? supplierId,
  });
  Future<PurchaseOrder?> getById(String id);

  /// Saves a new PO (Day 7). The repository assigns the id and the
  /// sequential per-branch PO number (`PO-DHA-1001`, …) and returns
  /// the saved PO. New POs start as Draft.
  Future<PurchaseOrder> createPurchaseOrder(PurchaseOrder order);

  /// Replaces a whole PO (status changes, received quantities). The
  /// id must already exist.
  Future<void> updatePurchaseOrder(PurchaseOrder order);

  /// Creates or replaces a PO by id (Week 5 Day 2, D150 — restore
  /// upsert-by-id): an existing id is replaced in place (status,
  /// received quantities and items as given — unlike
  /// [createPurchaseOrder] the status is NOT reset to Draft), a new
  /// id is inserted as given (an empty id gets a minted one). The
  /// PO number is kept when given, else repo-assigned on insert
  /// (same sequence as [createPurchaseOrder]). Returns the saved PO.
  Future<PurchaseOrder> upsertPurchaseOrder(PurchaseOrder order);
}

abstract class RiderRepository {
  Future<List<Rider>> getRiders();
  Future<Rider?> getById(String id);

  /// Saves an edited rider (Week 4 Day 2, D121): assignment changes
  /// the rider's `currentOrderId`, so the rider row must be writable
  /// — until now the repository was read-only because nothing wrote
  /// riders. The id must already exist; throws [ArgumentError] when
  /// it does not.
  Future<void> updateRider(Rider rider);

  /// Creates or replaces a rider by id (Week 5 Day 2, D150 —
  /// restore upsert-by-id): an existing id is replaced in place, a
  /// new id is inserted as given (an empty id gets a minted one).
  /// [branchId] falls back to the record's own branch. Returns the
  /// saved rider.
  Future<Rider> upsertRider(Rider rider, {String? branchId});
}

/// Stock transfers between branches (Week 4 Day 2, D118 — SRS D-16).
///
/// The mock keeps transfers in memory for the session, seeded from
/// [demoTransfers] (one per live status). The Firestore implementation
/// stores them under `branches/{fromBranchId}/stockTransfers/{id}`
/// (schema paths already exist) — it lands with the Firebase-wiring
/// chunk, the same Day 7 → Day 3 pattern as suppliers and purchase
/// orders (D89). Screens depend only on this interface.
///
/// The repository owns the transfer NUMBER, not the layer: the mock
/// mints `TR-{fromCode}-{toCode}-{seq}` and the Firestore
/// implementation mints the same shape from the per-branch counter,
/// so a transfer created through either backend carries a number.
/// A caller-supplied non-empty id is kept as the document id (D65
/// pattern — the layer passes the idempotency key as the id, so a
/// retried create returns the existing document instead of writing
/// a second one).
abstract class StockTransferRepository {
  /// All transfers, optionally scoped to one branch — a transfer
  /// belongs to a branch when it is the source OR the destination,
  /// so a branch-scoped read returns both directions.
  Future<List<StockTransfer>> getTransfers({String? branchId});

  Future<StockTransfer?> getById(String id);

  /// Saves a new transfer (status Requested). The repository assigns
  /// the transfer number and returns the saved transfer.
  Future<StockTransfer> createTransfer(StockTransfer transfer);

  /// Replaces a whole transfer (status changes, allocations, actor
  /// stamps). The id must already exist.
  Future<void> updateTransfer(StockTransfer transfer);
}

/// Adjustment approval queue (Week 5 Day 1, D146 — SRS D-14 /
/// FR-INV-08, §5.2.4).
///
/// One document per request under
/// `branches/{branchId}/stockAdjustments/{id}` (doc id = request id).
/// The mock starts empty: requests only arise from filing in the
/// session, so there is nothing to seed. The Firestore implementation
/// stores them under the same path — it lands with the Firebase-wiring
/// chunk, the same Day 7 → Day 3 pattern as suppliers and purchase
/// orders (D89). The layer owns the write path; screens depend only
/// on this interface via the layer.
abstract class StockAdjustmentRequestRepository {
  /// All requests, optionally scoped to one branch.
  Future<List<StockAdjustmentRequest>> getRequests({String? branchId});

  Future<StockAdjustmentRequest?> getById(String id);

  /// Creates or replaces one request, keyed by its id (D65 pattern):
  /// a re-save overwrites the same document, never a duplicate — so
  /// filing and deciding share one write path. An empty id gets an
  /// assigned one (`adj-N` in the mock, a Firestore auto-id in the
  /// Firestore implementation).
  Future<StockAdjustmentRequest> saveRequest(StockAdjustmentRequest request);
}

/// Branch directory (Week 5 Day 2, D148 — SRS D-28 / FR-HO-01/02/08,
/// §3.1 `branches`).
///
/// Closes the D131 follow-up: the directory is no longer an
/// in-memory notifier seeded from the demo branches — it reads and
/// writes through this interface (mock by default, Firestore when
/// the bundle switches), the same Day 3 → Day 5 pattern as the
/// staff / transfer / adjustment-queue repos (D73/D101/D118/D146).
/// The mock is seeded from [demoBranches]; the Firestore
/// implementation stores one doc per branch under `branches/{id}`
/// (the root collection — branches are org-wide, not branch-scoped).
///
/// The repository owns the branch ROW, not the directory rules: the
/// notifier still owns validation (`validateBranchForm`), the
/// last-active-branch protection and the `branch-<slug>` id minting
/// (the form dialog builds the id; an empty id here gets a minted
/// one). Deactivation is still the `active` flag — enforcement on
/// transactions lives in the production data layer (D149, FR-HO-08),
/// which reads the branch row through this interface; the repo
/// itself enforces nothing about transacting.
abstract class BranchRepository {
  /// All branches, in display order (mock: seed order; Firestore:
  /// `name` order).
  Future<List<Branch>> getBranches();

  Future<Branch?> getById(String id);

  /// Saves a new branch. The caller supplies the id (the directory
  /// mints `branch-<slug>`); an empty id gets a minted one
  /// (`branch-<slug>` in the mock, a Firestore auto-id in the
  /// Firestore implementation). Throws [ArgumentError] when another
  /// branch already has the id.
  Future<Branch> createBranch(Branch branch);

  /// Saves an edited branch. The id must already exist; throws
  /// [ArgumentError] when it does not. The id itself never changes.
  Future<Branch> updateBranch(Branch branch);

  /// Creates or replaces a branch by id (the layer's directory
  /// write path, D146 pattern): an existing id is replaced in
  /// place, a new id is inserted as given (an empty id gets a
  /// minted one). Returns the saved branch.
  Future<Branch> saveBranch(Branch branch);
}

/// Staff directory (Week 2 Day 5, SRS §3.7 `employees` / §5.1
/// `users`).
///
/// The mock keeps staff in memory for the session, seeded from
/// [demoStaff]. The Firestore implementation stores them under
/// `branches/{branchId}/employees/{employeeId}` (schema paths
/// already exist) — it lands with the Firebase-wiring chunk, the
/// same Day 7 → Day 3 pattern as suppliers and purchase orders
/// (D89). Screens depend only on this interface.
abstract class StaffRepository {
  Future<List<Staff>> getStaff({String? branchId});
  Future<Staff?> getById(String id);

  /// Saves a new staff member. The repository assigns the id.
  /// Throws [ArgumentError] when another staff member already has
  /// the same phone number (digits compared, formatting ignored).
  Future<Staff> createStaff(Staff staff);

  /// Saves an edited staff member (details, branch, role, status).
  /// The id must already exist. Throws [ArgumentError] on a phone
  /// number that belongs to a different staff member.
  Future<void> updateStaff(Staff staff);
}

/// Attendance records (Week 2 Day 5, SRS §3.7 `attendances`).
abstract class AttendanceRepository {
  /// Attendance records, optionally scoped by branch, day and/or
  /// employee. [date] matches the calendar day.
  Future<List<Attendance>> getAttendances({
    String? branchId,
    DateTime? date,
    String? employeeId,
  });

  /// Saves a new record or replaces an existing one by id (check-in
  /// creates, check-out updates). The repository assigns the id
  /// when it is empty and returns the saved record.
  Future<Attendance> upsertAttendance(Attendance attendance);
}

/// Shifts (Week 2 Day 5, SRS §3.7 `shifts`).
abstract class ShiftRepository {
  Future<List<Shift>> getShifts({String? branchId});
  Future<Shift?> getById(String id);

  /// Saves a new shift. The repository assigns the id.
  Future<Shift> createShift(Shift shift);

  /// Saves an edited shift (name, times, assigned employees). The
  /// id must already exist.
  Future<void> updateShift(Shift shift);
}

/// Operating expenses (Week 2 Day 5, SRS §3.7 `expenses`).
abstract class ExpenseRepository {
  Future<List<Expense>> getExpenses({String? branchId});

  /// Saves a new expense. The repository assigns the id and returns
  /// the saved record. The caller also writes the matching
  /// `financialTransactions` entry (see the finance provider).
  Future<Expense> createExpense(Expense expense);
}

/// Financial transactions (Week 2 Day 5, SRS §3.7
/// `financialTransactions`). Append-only — entries are never edited
/// or deleted.
abstract class FinancialTransactionRepository {
  Future<List<FinancialTransaction>> getTransactions({String? branchId});

  /// Appends one transaction. The repository assigns the id and
  /// returns the saved record.
  Future<FinancialTransaction> addTransaction(FinancialTransaction txn);
}

/// Daily cashbook closings (Week 4 Day 3, D126 — SRS §3.7
/// `dailyClosings`, new collection; FR-FIN-02). Append-only — a
/// closing is a snapshot record, never edited. One closing per
/// (branch, day); a second close for the same day is rejected.
abstract class DailyClosingRepository {
  Future<List<DailyClosing>> getClosings({String? branchId});

  /// The closing for one branch-day, or `null` when the day was
  /// never closed.
  Future<DailyClosing?> getClosing({
    required String branchId,
    required DateTime date,
  });

  /// Saves a new closing. The repository assigns the id and returns
  /// the saved record. Throws [ArgumentError] when a closing already
  /// exists for the same branch and day.
  Future<DailyClosing> createClosing(DailyClosing closing);
}

/// Closing corrections (Week 5 Day 4, D156 — SRS D-24 / FR-FIN-06).
///
/// One document per reversing entry, written by the production data
/// layer — never directly by a screen. The mock starts empty:
/// corrections only arise from correcting a closing in the session.
/// Append-only: a correction is never edited or deleted (a wrong
/// correction is fixed by a newer correction, which re-states the
/// day in full).
abstract class ClosingCorrectionRepository {
  Future<List<ClosingCorrection>> getCorrections({String? branchId});

  /// Corrections for one original closing, oldest first.
  Future<List<ClosingCorrection>> getCorrectionsForClosing(
    String originalClosingId,
  );

  /// Saves a new correction. The repository assigns the id and
  /// returns the saved record.
  Future<ClosingCorrection> createCorrection(ClosingCorrection correction);
}

/// Cash reconciliations (Week 5 Day 4, D157 — SRS D-24 / FR-FIN-02).
///
/// One document per drawer count, written by the production data
/// layer — never directly by a screen. The mock starts empty:
/// reconciliations only arise from counting a drawer in the
/// session. Append-only: a recount is a new record, never an edit
/// of the previous count.
abstract class CashReconciliationRepository {
  Future<List<CashReconciliation>> getReconciliations({String? branchId});

  /// Reconciliations for one branch-day, oldest first.
  Future<List<CashReconciliation>> getReconciliationsForDay({
    required String branchId,
    required DateTime date,
  });

  /// Saves a new reconciliation. The repository assigns the id and
  /// returns the saved record.
  Future<CashReconciliation> createReconciliation(
    CashReconciliation reconciliation,
  );
}

/// Supplier payments (Week 2 Day 5, SRS §3.6 `supplierPayments`).
abstract class SupplierPaymentRepository {
  Future<List<SupplierPayment>> getPayments({
    String? branchId,
    String? supplierId,
  });

  /// Saves a new payment with its payable allocations. The
  /// repository assigns the id and returns the saved record. The
  /// matching supplier-ledger entry and `financialTransactions`
  /// entry are written by the production data layer in the same
  /// call (Week 5 Day 1, D147 — the layer is the single write path
  /// for supplier payments, like `recordExpense` for expenses).
  Future<SupplierPayment> createPayment(SupplierPayment payment);
}

/// Goods receipts (Week 3 Day 2, SRS §3 `goodsReceipts` / D103).
///
/// One document per receiving event, written by the production data
/// layer — never directly by a screen. The mock starts empty:
/// receipts only arise from receiving in the session, so there is
/// nothing to seed.
abstract class GoodsReceiptRepository {
  Future<List<GoodsReceipt>> getGoodsReceipts({String? branchId, String? poId});
  Future<GoodsReceipt?> getById(String id);

  /// Saves a receipt. The repository assigns the id and the
  /// sequential per-branch receipt number (`GR-DHA-1001`, …) and
  /// returns the saved receipt. A non-empty id is the idempotency
  /// key (D65 pattern): a retry with the same id returns the
  /// already-saved receipt, never a second document.
  Future<GoodsReceipt> createGoodsReceipt(GoodsReceipt receipt);
}

/// Salary records (Week 3 Day 2, SRS §3.7 `salaries` / D102).
///
/// One record per (employee, month) — the source of truth for
/// salary figures. The mock is seeded from [demoSalaryRecords]
/// (fictional demo figures, `isDemo: true`).
abstract class SalaryRepository {
  Future<List<SalaryRecord>> getSalaryRecords({
    String? branchId,
    String? month,
  });
  Future<SalaryRecord?> getById(String id);

  /// Saves (creates or replaces) one record, keyed by
  /// (employeeId, month): a re-save overwrites the same record,
  /// never a duplicate. Throws [ArgumentError] on a negative
  /// amount, a bad month (`YYYY-MM` required) or a net that does
  /// not equal base + allowances − deductions.
  Future<SalaryRecord> saveSalaryRecord(SalaryRecord record);
}

/// --- Mock implementations (sample data only) ---

class MockMedicineRepository implements MedicineRepository {
  @override
  Future<List<Medicine>> getMedicines({String? branchId}) async =>
      List.unmodifiable(demoMedicines);

  @override
  Future<Medicine?> getById(String id) async {
    for (final medicine in demoMedicines) {
      if (medicine.id == id) return medicine;
    }
    return null;
  }

  @override
  Future<Medicine?> getByBarcode(String barcode) async {
    final needle = barcode.trim();
    if (needle.isEmpty) return null;
    for (final medicine in demoMedicines) {
      if (medicine.barcode == needle) return medicine;
    }
    return null;
  }

  @override
  Future<Medicine> updateMedicine(Medicine medicine) async {
    final index = demoMedicines.indexWhere((m) => m.id == medicine.id);
    if (index == -1) {
      throw ArgumentError('No medicine with id "${medicine.id}".');
    }
    // Week 6 Day 4 (D166): a barcode already used by a DIFFERENT
    // medicine is rejected here — the repo is the one write path
    // for master edits (the form is the only caller and surfaces
    // this ArgumentError verbatim, D153). An empty barcode and the
    // medicine's own barcode pass.
    final conflict = findBarcodeConflict(
      demoMedicines,
      barcode: medicine.barcode,
      excludeId: medicine.id,
    );
    if (conflict != null) {
      throw ArgumentError(
        barcodeConflictMessage(
          medicine.barcode!.trim(),
          conflict.name,
        ),
      );
    }
    final saved = medicine.copyWith(updatedAt: DateTime.now());
    demoMedicines[index] = saved;
    return saved;
  }

  @override
  Future<Medicine> upsertMedicine(Medicine medicine) async {
    final id = medicine.id.isEmpty
        ? 'med-${demoMedicines.length + 1}'
        : medicine.id;
    final saved = medicine.copyWith(id: id, updatedAt: DateTime.now());
    final index = demoMedicines.indexWhere((m) => m.id == id);
    if (index == -1) {
      demoMedicines.add(saved);
    } else {
      demoMedicines[index] = saved;
    }
    return saved;
  }
}

class MockOrderRepository implements OrderRepository {
  /// Mutable copy of the seed orders: status updates (Day 4) rewrite
  /// entries in place, exactly like a Firestore update would.
  final List<Order> _orders = generateDemoOrders();

  @override
  Future<List<Order>> getOrders({String? branchId}) async {
    if (branchId == null) return List.unmodifiable(_orders);
    return List.unmodifiable(
      _orders.where((order) => order.branchId == branchId),
    );
  }

  @override
  Future<Order?> getById(String id) async {
    for (final order in _orders) {
      if (order.id == id) return order;
    }
    return null;
  }

  @override
  Future<void> updateStatus(String id, OrderStatus status) async {
    final index = _orders.indexWhere((order) => order.id == id);
    if (index == -1) return;
    final old = _orders[index];
    // copyWith keeps every field the Day 4 model carries (source,
    // fulfilment, discount, rider, notes, prescription) — a status
    // change must never drop them.
    _orders[index] = old.copyWith(status: status, updatedAt: DateTime.now());
  }

  @override
  Future<Order> createOrder(Order order) async {
    final branchCode = order.branchId == 'branch-dha-main' ? 'dha' : 'glb';
    final sequence = 1000 + _orders.length + 1;
    final id = 'ord-$branchCode-$sequence';
    // Week 6 Day 4 (D165): the mock assigns the same number + key
    // shape as the Firestore repo (`ORD-DHA-1001`, key = doc id)
    // and RETURNS them — a caller must never have to re-derive
    // what the repo assigned.
    final saved = order.copyWith(
      id: id,
      orderNumber: 'ORD-${branchCode.toUpperCase()}-$sequence',
      idempotencyKey: id,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    _orders.add(saved);
    return saved;
  }

  @override
  Future<void> updateOrder(Order order) async {
    final index = _orders.indexWhere((o) => o.id == order.id);
    if (index == -1) return;
    _orders[index] = order.copyWith(updatedAt: DateTime.now());
  }

  @override
  Future<Order> upsertOrder(Order order) async {
    final branchCode = order.branchId == 'branch-dha-main' ? 'dha' : 'glb';
    final id = order.id.isEmpty
        ? 'ord-$branchCode-${1000 + _orders.length + 1}'
        : order.id;
    final existingIndex = _orders.indexWhere((o) => o.id == id);
    final existing = existingIndex == -1 ? null : _orders[existingIndex];
    // Week 6 Day 4 (D165): an existing order keeps its number +
    // key; a genuinely new one gets the number derived from its
    // (possibly minted) id and the id as its key — the same stable
    // values the model itself derives (effectiveOrderNumber /
    // effectiveIdempotencyKey), so a restore never re-numbers.
    final saved = order.copyWith(
      id: id,
      orderNumber: existing != null
          ? existing.effectiveOrderNumber
          : defaultOrderNumberForId(id),
      idempotencyKey: existing != null
          ? existing.effectiveIdempotencyKey
          : id,
      updatedAt: DateTime.now(),
    );
    if (existingIndex == -1) {
      _orders.add(saved);
    } else {
      _orders[existingIndex] = saved;
    }
    return saved;
  }
}

class MockInventoryRepository implements InventoryRepository {
  final List<InventoryItem> _items = generateDemoInventory();

  List<InventoryItem> _scoped(String? branchId) {
    if (branchId == null) return _items;
    return _items.where((item) => item.branchId == branchId).toList();
  }

  @override
  Future<List<InventoryItem>> getInventory({String? branchId}) async =>
      List.unmodifiable(_scoped(branchId));

  @override
  Future<List<InventoryItem>> getLowStock({String? branchId}) async =>
      List.unmodifiable(_scoped(branchId).where((item) => item.isLowStock));

  @override
  Future<List<InventoryItem>> getExpiringWithin({
    int days = 30,
    String? branchId,
  }) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final limit = today.add(Duration(days: days));
    return List.unmodifiable(
      _scoped(branchId).where((item) {
        final expiry = item.expiryDate;
        if (expiry == null) return false;
        final expiryDay = DateTime(expiry.year, expiry.month, expiry.day);
        return !expiryDay.isBefore(today) && !expiryDay.isAfter(limit);
      }),
    );
  }

  @override
  Future<InventoryItem> receiveStock({
    required String branchId,
    required String medicineId,
    required String batchNo,
    required DateTime mfgDate,
    required DateTime expiryDate,
    required int quantity,
    required int costMinor,
  }) async {
    if (quantity <= 0) {
      throw ArgumentError('Received quantity must be above zero.');
    }
    if (costMinor < 0) {
      throw ArgumentError('Cost price cannot be negative.');
    }
    if (!expiryDate.isAfter(mfgDate)) {
      throw ArgumentError('Expiry date must be after the manufacture date.');
    }
    final branchCode = branchId == 'branch-dha-main' ? 'DHA' : 'GLB';
    final created = InventoryItem(
      id: 'inv-$branchCode-${_items.length + 1}-rx',
      medicineId: medicineId,
      branchId: branchId,
      quantity: quantity,
      lowStockThreshold: 10,
      batchNo: batchNo,
      expiryDate: expiryDate,
      mfgDate: mfgDate,
      costMinor: costMinor,
      updatedAt: DateTime.now(),
    );
    _items.add(created);
    return created;
  }

  @override
  Future<InventoryItem> adjustStock({
    required String batchId,
    required int deltaQty,
    required String reason,
  }) async {
    final index = _items.indexWhere((item) => item.id == batchId);
    if (index == -1) throw ArgumentError('No batch with id "$batchId".');
    if (deltaQty == 0) {
      throw ArgumentError('Adjustment quantity cannot be zero.');
    }
    if (reason.trim().isEmpty) {
      throw ArgumentError('An adjustment reason is required.');
    }
    final old = _items[index];
    final nextQty = old.quantity + deltaQty;
    if (nextQty < 0) {
      throw ArgumentError(
        'Cannot remove $deltaQty units — only ${old.quantity} on hand.',
      );
    }
    final updated = old.copyWith(quantity: nextQty, updatedAt: DateTime.now());
    _items[index] = updated;
    return updated;
  }

  @override
  Future<InventoryItem> recordStockCount({
    required String batchId,
    required int countedQty,
    String? note,
  }) async {
    final index = _items.indexWhere((item) => item.id == batchId);
    if (index == -1) throw ArgumentError('No batch with id "$batchId".');
    if (countedQty < 0) {
      throw ArgumentError('Counted quantity cannot be negative.');
    }
    final updated = _items[index].copyWith(
      quantity: countedQty,
      updatedAt: DateTime.now(),
    );
    _items[index] = updated;
    return updated;
  }

  @override
  Future<InventoryItem> updateBatchStatus({
    required String batchId,
    required BatchStatus status,
    String? reason,
  }) async {
    final index = _items.indexWhere((item) => item.id == batchId);
    if (index == -1) throw ArgumentError('No batch with id "$batchId".');
    final updated = _items[index].copyWith(
      status: status,
      updatedAt: DateTime.now(),
    );
    _items[index] = updated;
    return updated;
  }

  @override
  Future<InventoryItem> upsertInventoryItem(InventoryItem item) async {
    final branchCode = item.branchId == 'branch-dha-main' ? 'DHA' : 'GLB';
    final id = item.id.isEmpty
        ? 'inv-$branchCode-${_items.length + 1}-rx'
        : item.id;
    final saved = item.copyWith(id: id, updatedAt: DateTime.now());
    final index = _items.indexWhere((row) => row.id == id);
    if (index == -1) {
      _items.add(saved);
    } else {
      _items[index] = saved;
    }
    return saved;
  }

  /// Per-branch rack / shelf overrides (Week 5 Day 3, D152), keyed
  /// `branchId|medicineId`. Empty overrides are never stored — a
  /// save with both fields empty deletes the record, so the branch
  /// falls back to the master location.
  final Map<String, BranchInventoryLocation> _locations = {};

  String _locationKey(String branchId, String medicineId) =>
      '$branchId|$medicineId';

  @override
  Future<BranchInventoryLocation?> getBranchLocation({
    required String branchId,
    required String medicineId,
  }) async => _locations[_locationKey(branchId, medicineId)];

  @override
  Future<List<BranchInventoryLocation>> getBranchLocations({
    String? branchId,
  }) async {
    final values = _locations.values.where(
      (location) => branchId == null || location.branchId == branchId,
    );
    return List.unmodifiable(values);
  }

  @override
  Future<BranchInventoryLocation> saveBranchLocation(
    BranchInventoryLocation location,
  ) async {
    final key = _locationKey(location.branchId, location.medicineId);
    if (location.isEmpty) {
      _locations.remove(key);
      return location;
    }
    final saved = BranchInventoryLocation(
      branchId: location.branchId,
      medicineId: location.medicineId,
      rack: location.rack?.trim(),
      shelf: location.shelf?.trim(),
    );
    _locations[key] = saved;
    return saved;
  }
}

class MockCustomerRepository implements CustomerRepository {
  /// Mutable copies of the seed customers and ledger: adding a
  /// customer or a khata entry rewrites entries in place, exactly
  /// like a Firestore write would.
  final List<Customer> _customers = List.of(demoCustomers);
  final List<LedgerEntry> _ledger = generateDemoLedgerEntries();

  @override
  Future<List<Customer>> getCustomers() async => List.unmodifiable(_customers);

  @override
  Future<Customer?> getById(String id) async {
    for (final customer in _customers) {
      if (customer.id == id) return customer;
    }
    return null;
  }

  @override
  Future<Customer> createCustomer(Customer customer, {String? branchId}) async {
    final digits = _phoneDigits(customer.phone);
    if (digits.isEmpty) {
      throw ArgumentError('A phone number is required.');
    }
    if (_customers.any((c) => _phoneDigits(c.phone) == digits)) {
      throw ArgumentError(
        'A customer with phone ${customer.phone} already exists.',
      );
    }
    final created = customer.copyWith(
      id: 'cust-${_customers.length + 1}',
      createdAt: DateTime.now(),
    );
    _customers.add(created);
    return created;
  }

  @override
  Future<List<LedgerEntry>> getLedgerEntries(String customerId) async =>
      List.unmodifiable(
        _ledger.where((entry) => entry.customerId == customerId),
      );

  @override
  Future<LedgerEntry> addLedgerEntry(LedgerEntry entry) async {
    if (entry.amountMinor == 0) {
      throw ArgumentError('A ledger entry amount cannot be zero.');
    }
    final outstanding = _ledger
        .where((e) => e.customerId == entry.customerId)
        .fold(0, (sum, e) => sum + e.amountMinor);
    final created = entry.copyWith(
      id: 'led-${_ledger.length + 1}',
      balanceAfterMinor: outstanding + entry.amountMinor,
      createdAt: DateTime.now(),
    );
    _ledger.add(created);
    return created;
  }

  @override
  Future<Customer> upsertCustomer(Customer customer, {String? branchId}) async {
    // [branchId] is ignored here (see the interface doc) — the
    // mock keeps customers org-wide.
    final id = customer.id.isEmpty
        ? 'cust-${_customers.length + 1}'
        : customer.id;
    final index = _customers.indexWhere((c) => c.id == id);
    // A restore replays history: the given `createdAt` wins, then
    // the stored one on a replace, then "now" on a fresh insert.
    final saved = customer.copyWith(
      id: id,
      createdAt:
          customer.createdAt ??
          (index == -1 ? null : _customers[index].createdAt) ??
          DateTime.now(),
    );
    if (index == -1) {
      _customers.add(saved);
    } else {
      _customers[index] = saved;
    }
    return saved;
  }

  @override
  Future<LedgerEntry> upsertLedgerEntry(
    LedgerEntry entry, {
    String? branchId,
  }) async {
    final id = entry.id.isEmpty ? 'led-${_ledger.length + 1}' : entry.id;
    final saved = entry.copyWith(id: id);
    final index = _ledger.indexWhere((e) => e.id == id);
    if (index == -1) {
      _ledger.add(saved);
    } else {
      _ledger[index] = saved;
    }
    return saved;
  }

  static String _phoneDigits(String phone) =>
      phone.replaceAll(RegExp(r'[^0-9]'), '');
}

class MockSaleRepository implements SaleRepository {
  /// Mutable in-memory sales for the session. The demo starts with no
  /// completed POS sales — the seeded 30-day history lives in the
  /// orders stream (Day 3/4); every sale here was rung through the
  /// Day 6 POS in this session.
  final List<Sale> _sales = [];

  /// Next invoice sequence per branch code.
  final Map<String, int> _sequences = {};

  @override
  Future<List<Sale>> getSales({String? branchId}) async {
    if (branchId == null) return List.unmodifiable(_sales);
    return List.unmodifiable(_sales.where((sale) => sale.branchId == branchId));
  }

  @override
  Future<Sale?> getById(String id) async {
    for (final sale in _sales) {
      if (sale.id == id) return sale;
    }
    return null;
  }

  @override
  Future<Sale> createSale(Sale sale) async {
    final branchCode = sale.branchId == 'branch-dha-main' ? 'DHA' : 'GLB';
    final sequence = (_sequences[branchCode] ?? 1000) + 1;
    _sequences[branchCode] = sequence;
    final saved = sale.copyWith(
      id: 'sale-$branchCode-$sequence',
      invoiceNumber: 'INV-$branchCode-$sequence',
      createdAt: DateTime.now(),
    );
    _sales.add(saved);
    return saved;
  }

  @override
  Future<void> updateSale(Sale sale) async {
    final index = _sales.indexWhere((s) => s.id == sale.id);
    if (index == -1) return;
    _sales[index] = sale;
  }

  @override
  Future<Sale> upsertSale(Sale sale) async {
    final branchCode = sale.branchId == 'branch-dha-main' ? 'DHA' : 'GLB';
    final sequence = (_sequences[branchCode] ?? 1000) + 1;
    final id = sale.id.isEmpty ? 'sale-$branchCode-$sequence' : sale.id;
    if (sale.id.isEmpty) _sequences[branchCode] = sequence;
    final saved = sale.copyWith(
      id: id,
      invoiceNumber: sale.invoiceNumber.isEmpty
          ? 'INV-$branchCode-$sequence'
          : sale.invoiceNumber,
      createdAt: sale.createdAt ?? DateTime.now(),
    );
    final index = _sales.indexWhere((s) => s.id == id);
    if (index == -1) {
      _sales.add(saved);
    } else {
      _sales[index] = saved;
    }
    return saved;
  }
}

/// Sale returns (Week 2 Day 4): mutable in-memory returns for the
/// session — the demo starts with none, every return here was
/// recorded through the returns flow in this session.
class MockSaleReturnRepository implements SaleReturnRepository {
  final List<SaleReturn> _returns = [];

  @override
  Future<List<SaleReturn>> getReturns({String? branchId}) async {
    if (branchId == null) return List.unmodifiable(_returns);
    return List.unmodifiable(_returns.where((r) => r.branchId == branchId));
  }

  @override
  Future<List<SaleReturn>> getReturnsForSale(String saleId) async =>
      List.unmodifiable(_returns.where((r) => r.saleId == saleId));

  @override
  Future<SaleReturn> createReturn(SaleReturn saleReturn) async {
    final saved = saleReturn.copyWith(
      id: 'ret-${_returns.length + 1}',
      createdAt: DateTime.now(),
    );
    _returns.add(saved);
    return saved;
  }
}

class MockSupplierRepository implements SupplierRepository {
  /// Mutable copies of the seed suppliers and ledger: adding a
  /// supplier or a ledger entry rewrites entries in place, exactly
  /// like a Firestore write would.
  final List<Supplier> _suppliers = List.of(demoSuppliers);
  final List<SupplierLedgerEntry> _ledger = generateDemoSupplierLedgerEntries();

  @override
  Future<List<Supplier>> getSuppliers() async => List.unmodifiable(_suppliers);

  @override
  Future<Supplier?> getById(String id) async {
    for (final supplier in _suppliers) {
      if (supplier.id == id) return supplier;
    }
    return null;
  }

  @override
  Future<Supplier> createSupplier(Supplier supplier) async {
    final digits = _phoneDigits(supplier.phone);
    if (digits.isEmpty) {
      throw ArgumentError('A phone number is required.');
    }
    if (_suppliers.any((s) => _phoneDigits(s.phone) == digits)) {
      throw ArgumentError(
        'A supplier with phone ${supplier.phone} already exists.',
      );
    }
    // Week 6 Day 4 (D165): a new supplier is stamped with now when
    // it carries no createdAt — the creation time is known here,
    // unlike for seeded / legacy rows (null = unknown).
    final created = supplier.copyWith(
      id: 'sup-${_suppliers.length + 1}',
      createdAt: supplier.createdAt ?? DateTime.now(),
    );
    _suppliers.add(created);
    return created;
  }

  @override
  Future<void> updateSupplier(Supplier supplier) async {
    final index = _suppliers.indexWhere((s) => s.id == supplier.id);
    if (index == -1) return;
    // Week 6 Day 4 (D165): an update never rewrites createdAt — a
    // supplier passed without one keeps the stored value (mirrors
    // the Firestore impl, which drops createdAt from the merge).
    final existing = _suppliers[index];
    _suppliers[index] = supplier.copyWith(
      createdAt: supplier.createdAt ?? existing.createdAt,
    );
  }

  @override
  Future<List<SupplierLedgerEntry>> getLedgerEntries(String supplierId) async =>
      List.unmodifiable(
        _ledger.where((entry) => entry.supplierId == supplierId),
      );

  @override
  Future<SupplierLedgerEntry> addLedgerEntry(SupplierLedgerEntry entry) async {
    if (entry.amountMinor == 0) {
      throw ArgumentError('A ledger entry amount cannot be zero.');
    }
    final outstanding = _ledger
        .where((e) => e.supplierId == entry.supplierId)
        .fold(0, (sum, e) => sum + e.amountMinor);
    final created = entry.copyWith(
      id: 'sled-${_ledger.length + 1}',
      balanceAfterMinor: outstanding + entry.amountMinor,
      createdAt: DateTime.now(),
    );
    _ledger.add(created);
    return created;
  }

  @override
  Future<Supplier> upsertSupplier(Supplier supplier) async {
    // Week 6 Day 4 (D165): a restore replays the row as given. An
    // existing row keeps its stored createdAt when the incoming row
    // carries none (an update never rewrites it); a new row keeps
    // the incoming value, or null (= unknown) when it has none.
    final id = supplier.id.isEmpty
        ? 'sup-${_suppliers.length + 1}'
        : supplier.id;
    final existingIndex = _suppliers.indexWhere((s) => s.id == id);
    final existing = existingIndex == -1 ? null : _suppliers[existingIndex];
    final saved = supplier.copyWith(
      id: id,
      createdAt: supplier.createdAt ?? existing?.createdAt,
    );
    if (existingIndex == -1) {
      _suppliers.add(saved);
    } else {
      _suppliers[existingIndex] = saved;
    }
    return saved;
  }

  @override
  Future<SupplierLedgerEntry> upsertLedgerEntry(
    SupplierLedgerEntry entry,
  ) async {
    final id = entry.id.isEmpty ? 'sled-${_ledger.length + 1}' : entry.id;
    final saved = entry.copyWith(id: id);
    final index = _ledger.indexWhere((e) => e.id == id);
    if (index == -1) {
      _ledger.add(saved);
    } else {
      _ledger[index] = saved;
    }
    return saved;
  }

  static String _phoneDigits(String phone) =>
      phone.replaceAll(RegExp(r'[^0-9]'), '');
}

class MockRiderRepository implements RiderRepository {
  /// Mutable copy of the seed riders: assignment writes
  /// (`currentOrderId`) rewrite entries in place, exactly like a
  /// Firestore update would (Week 4 Day 2, D121).
  final List<Rider> _riders = List.of(demoRiders);

  @override
  Future<List<Rider>> getRiders() async => List.unmodifiable(_riders);

  @override
  Future<Rider?> getById(String id) async {
    for (final rider in _riders) {
      if (rider.id == id) return rider;
    }
    return null;
  }

  @override
  Future<void> updateRider(Rider rider) async {
    final index = _riders.indexWhere((r) => r.id == rider.id);
    if (index == -1) {
      throw ArgumentError('No rider with id "${rider.id}".');
    }
    _riders[index] = rider;
  }

  @override
  Future<Rider> upsertRider(Rider rider, {String? branchId}) async {
    final id = rider.id.isEmpty ? 'rider-${_riders.length + 1}' : rider.id;
    final saved = rider.copyWith(
      id: id,
      branchId: branchId ?? rider.branchId,
      createdAt: rider.createdAt ?? DateTime.now(),
    );
    final index = _riders.indexWhere((r) => r.id == id);
    if (index == -1) {
      _riders.add(saved);
    } else {
      _riders[index] = saved;
    }
    return saved;
  }
}

/// Stock transfers (Week 4 Day 2, D118): mutable in-memory transfers
/// for the session, seeded from [demoTransfers].
class MockStockTransferRepository implements StockTransferRepository {
  final List<StockTransfer> _transfers = List.of(demoTransfers);

  @override
  Future<List<StockTransfer>> getTransfers({String? branchId}) async {
    if (branchId == null) return List.unmodifiable(_transfers);
    return List.unmodifiable(
      _transfers.where(
        (transfer) =>
            transfer.fromBranchId == branchId ||
            transfer.toBranchId == branchId,
      ),
    );
  }

  @override
  Future<StockTransfer?> getById(String id) async {
    for (final transfer in _transfers) {
      if (transfer.id == id) return transfer;
    }
    return null;
  }

  @override
  Future<StockTransfer> createTransfer(StockTransfer transfer) async {
    final id = transfer.id.isEmpty
        ? 'tr-${_transfers.length + 1}'
        : transfer.id;
    if (_transfers.any((t) => t.id == id)) {
      // D65 pattern: a retry with the same id returns the existing
      // document instead of writing a second one.
      return _transfers.firstWhere((t) => t.id == id);
    }
    final fromCode = transfer.fromBranchId == 'branch-dha-main' ? 'DHA' : 'GLB';
    final toCode = transfer.toBranchId == 'branch-dha-main' ? 'DHA' : 'GLB';
    final created = transfer.copyWith(
      id: id,
      transferNumber: transfer.transferNumber.isEmpty
          ? 'TR-$fromCode-$toCode-${1000 + _transfers.length + 1}'
          : transfer.transferNumber,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    _transfers.add(created);
    return created;
  }

  @override
  Future<void> updateTransfer(StockTransfer transfer) async {
    final index = _transfers.indexWhere((t) => t.id == transfer.id);
    if (index == -1) {
      throw ArgumentError('No transfer with id "${transfer.id}".');
    }
    _transfers[index] = transfer.copyWith(updatedAt: DateTime.now());
  }
}

/// Adjustment approval queue (Week 5 Day 1, D146): mutable
/// in-memory requests for the session, starting empty — requests
/// only arise from filing, so there is nothing to seed.
class MockStockAdjustmentRequestRepository
    implements StockAdjustmentRequestRepository {
  final List<StockAdjustmentRequest> _requests = [];

  @override
  Future<List<StockAdjustmentRequest>> getRequests({String? branchId}) async {
    if (branchId == null) return List.unmodifiable(_requests);
    return List.unmodifiable(
      _requests.where((request) => request.branchId == branchId),
    );
  }

  @override
  Future<StockAdjustmentRequest?> getById(String id) async {
    for (final request in _requests) {
      if (request.id == id) return request;
    }
    return null;
  }

  @override
  Future<StockAdjustmentRequest> saveRequest(
    StockAdjustmentRequest request,
  ) async {
    final id = request.id.isEmpty ? 'adj-${_requests.length + 1}' : request.id;
    // An empty id gets an assigned one; a non-empty id is kept —
    // the round-trip through the map rebuilds the same request.
    final saved = StockAdjustmentRequest.fromMap(id, request.toMap());
    final index = _requests.indexWhere((item) => item.id == id);
    if (index == -1) {
      _requests.add(saved);
    } else {
      // D65 pattern: a re-save overwrites the same record, never a
      // duplicate — filing and deciding share this write path.
      _requests[index] = saved;
    }
    return saved;
  }
}

/// Branch directory (Week 5 Day 2, D148): mutable in-memory
/// branches for the session, seeded from [demoBranches] — the
/// directory's session state lives here now instead of in the
/// notifier, so a fresh mock per bundle still starts from the same
/// two demo branches and a deactivation survives a notifier
/// rebuild. The Firestore implementation stores the same rows
/// under `branches/{id}`.
class MockBranchRepository implements BranchRepository {
  final List<Branch> _branches = List.of(demoBranches);

  @override
  Future<List<Branch>> getBranches() async => List.unmodifiable(_branches);

  @override
  Future<Branch?> getById(String id) async {
    for (final branch in _branches) {
      if (branch.id == id) return branch;
    }
    return null;
  }

  @override
  Future<Branch> createBranch(Branch branch) async {
    final id = branch.id.isEmpty ? _mintId(branch.name) : branch.id;
    if (_branches.any((b) => b.id == id)) {
      throw ArgumentError('A branch with id "$id" already exists.');
    }
    final created = _withId(branch, id);
    _branches.add(created);
    return created;
  }

  @override
  Future<Branch> updateBranch(Branch branch) async {
    final index = _branches.indexWhere((b) => b.id == branch.id);
    if (index == -1) {
      throw ArgumentError('No branch with id "${branch.id}".');
    }
    // Same normalization as the Firestore mapper (D163): a stored
    // branch never keeps an empty or invalid code.
    final stored = branch.copyWith(code: branch.effectiveCode);
    _branches[index] = stored;
    return stored;
  }

  @override
  Future<Branch> saveBranch(Branch branch) async {
    final id = branch.id.isEmpty ? _mintId(branch.name) : branch.id;
    final saved = _withId(branch, id);
    final index = _branches.indexWhere((b) => b.id == id);
    if (index == -1) {
      _branches.add(saved);
    } else {
      _branches[index] = saved;
    }
    return saved;
  }

  /// `branch-<slug>` from the name — the same rule the form dialog
  /// uses (`branch_form_dialog.dart`), so a repo-minted id looks
  /// exactly like a dialog-minted one.
  static String _mintId(String name) {
    final slug = name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return 'branch-${slug.isEmpty ? 'new' : slug}';
  }

  /// A copy of [branch] carrying [id] — and the normalized code:
  /// a branch saved without one keeps the migration-safe default
  /// derived from its id (D163), never an empty code.
  static Branch _withId(Branch branch, String id) {
    return Branch(
      id: id,
      name: branch.name,
      address: branch.address,
      phone: branch.phone,
      deliveryAreas: branch.deliveryAreas,
      active: branch.active,
      createdAt: branch.createdAt ?? DateTime.now(),
      // Normalized against the NEW id: a branch minted here had an
      // empty id, so deriving from the old id would give `XX`.
      code: normalizeBranchCode(
        branch.code.isEmpty ? null : branch.code,
        branchId: id,
      ),
      type: branch.type,
      managerId: branch.managerId,
      franchiseFeeRateBps: branch.franchiseFeeRateBps,
      royaltyRateBps: branch.royaltyRateBps,
    );
  }
}

/// Staff directory (Week 2 Day 5): mutable in-memory staff for the
/// session, seeded from [demoStaff].
class MockStaffRepository implements StaffRepository {
  final List<Staff> _staff = List.of(demoStaff);

  @override
  Future<List<Staff>> getStaff({String? branchId}) async {
    if (branchId == null) return List.unmodifiable(_staff);
    return List.unmodifiable(
      _staff.where((member) => member.branchId == branchId),
    );
  }

  @override
  Future<Staff?> getById(String id) async {
    for (final member in _staff) {
      if (member.id == id) return member;
    }
    return null;
  }

  @override
  Future<Staff> createStaff(Staff staff) async {
    final digits = _phoneDigits(staff.phone);
    if (digits.isNotEmpty &&
        _staff.any((s) => _phoneDigits(s.phone) == digits)) {
      throw ArgumentError(
        'A staff member with phone ${staff.phone} already exists.',
      );
    }
    final created = staff.copyWith(
      id: 'staff-${_staff.length + 1}',
      createdAt: DateTime.now(),
    );
    _staff.add(created);
    return created;
  }

  @override
  Future<void> updateStaff(Staff staff) async {
    final index = _staff.indexWhere((s) => s.id == staff.id);
    if (index == -1) return;
    final digits = _phoneDigits(staff.phone);
    if (digits.isNotEmpty &&
        _staff.any(
          (s) => s.id != staff.id && _phoneDigits(s.phone) == digits,
        )) {
      throw ArgumentError(
        'A staff member with phone ${staff.phone} already exists.',
      );
    }
    _staff[index] = staff;
  }

  static String _phoneDigits(String phone) =>
      phone.replaceAll(RegExp(r'[^0-9]'), '');
}

/// Attendance (Week 2 Day 5): mutable in-memory records for the
/// session. The demo starts with no attendance — today fills in as
/// staff check in.
class MockAttendanceRepository implements AttendanceRepository {
  final List<Attendance> _records = [];

  @override
  Future<List<Attendance>> getAttendances({
    String? branchId,
    DateTime? date,
    String? employeeId,
  }) async {
    return List.unmodifiable(
      _records.where((record) {
        if (branchId != null && record.branchId != branchId) return false;
        if (employeeId != null && record.employeeId != employeeId) {
          return false;
        }
        if (date != null) {
          if (record.date.year != date.year ||
              record.date.month != date.month ||
              record.date.day != date.day) {
            return false;
          }
        }
        return true;
      }),
    );
  }

  @override
  Future<Attendance> upsertAttendance(Attendance attendance) async {
    if (attendance.id.isEmpty) {
      final created = attendance.copyWith(
        id: 'att-${_records.length + 1}',
        createdAt: DateTime.now(),
      );
      _records.add(created);
      return created;
    }
    final index = _records.indexWhere((r) => r.id == attendance.id);
    if (index == -1) {
      _records.add(attendance);
      return attendance;
    }
    _records[index] = attendance;
    return attendance;
  }
}

/// Shifts (Week 2 Day 5): mutable in-memory shifts for the session,
/// seeded from [generateDemoShifts].
class MockShiftRepository implements ShiftRepository {
  final List<Shift> _shifts = generateDemoShifts();

  @override
  Future<List<Shift>> getShifts({String? branchId}) async {
    if (branchId == null) return List.unmodifiable(_shifts);
    return List.unmodifiable(
      _shifts.where((shift) => shift.branchId == branchId),
    );
  }

  @override
  Future<Shift?> getById(String id) async {
    for (final shift in _shifts) {
      if (shift.id == id) return shift;
    }
    return null;
  }

  @override
  Future<Shift> createShift(Shift shift) async {
    final created = shift.copyWith(
      id: 'shift-${_shifts.length + 1}',
      createdAt: DateTime.now(),
    );
    _shifts.add(created);
    return created;
  }

  @override
  Future<void> updateShift(Shift shift) async {
    final index = _shifts.indexWhere((s) => s.id == shift.id);
    if (index == -1) return;
    _shifts[index] = shift;
  }
}

/// Expenses (Week 2 Day 5): mutable in-memory expenses for the
/// session, seeded from [generateDemoExpenses].
class MockExpenseRepository implements ExpenseRepository {
  final List<Expense> _expenses = generateDemoExpenses();

  @override
  Future<List<Expense>> getExpenses({String? branchId}) async {
    if (branchId == null) return List.unmodifiable(_expenses);
    return List.unmodifiable(
      _expenses.where((expense) => expense.branchId == branchId),
    );
  }

  @override
  Future<Expense> createExpense(Expense expense) async {
    final created = expense.copyWith(
      id: 'exp-${_expenses.length + 1}',
      createdAt: DateTime.now(),
    );
    _expenses.add(created);
    return created;
  }
}

/// Financial transactions (Week 2 Day 5): mutable in-memory
/// append-only transactions for the session, seeded with the mirror
/// of the seeded expenses.
class MockFinancialTransactionRepository
    implements FinancialTransactionRepository {
  final List<FinancialTransaction> _txns = generateDemoFinancialTransactions();

  @override
  Future<List<FinancialTransaction>> getTransactions({String? branchId}) async {
    if (branchId == null) return List.unmodifiable(_txns);
    return List.unmodifiable(_txns.where((txn) => txn.branchId == branchId));
  }

  @override
  Future<FinancialTransaction> addTransaction(FinancialTransaction txn) async {
    // Week 4 Day 3 (D125): a caller-supplied `createdAt` is the
    // transaction's business date (a backdated cashbook income entry
    // lands on its entry date, not today) — it is kept. Only a
    // missing date is stamped now.
    final created = txn.copyWith(
      id: 'ftx-${_txns.length + 1}',
      createdAt: txn.createdAt ?? DateTime.now(),
    );
    _txns.add(created);
    return created;
  }
}

/// Daily cashbook closings (Week 4 Day 3, D126): mutable in-memory
/// closings for the session. The demo starts with none — no day has
/// been closed yet, so the cashbook screen's closing history starts
/// empty and the close-day flow creates the records.
class MockDailyClosingRepository implements DailyClosingRepository {
  final List<DailyClosing> _closings = [];

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  @override
  Future<List<DailyClosing>> getClosings({String? branchId}) async {
    if (branchId == null) return List.unmodifiable(_closings);
    return List.unmodifiable(
      _closings.where((closing) => closing.branchId == branchId),
    );
  }

  @override
  Future<DailyClosing?> getClosing({
    required String branchId,
    required DateTime date,
  }) async {
    for (final closing in _closings) {
      if (closing.branchId == branchId && _sameDay(closing.date, date)) {
        return closing;
      }
    }
    return null;
  }

  @override
  Future<DailyClosing> createClosing(DailyClosing closing) async {
    if (await getClosing(branchId: closing.branchId, date: closing.date) !=
        null) {
      throw ArgumentError('A closing already exists for this branch and day.');
    }
    final created = closing.copyWith(
      id: 'dc-${_closings.length + 1}',
      closedAt: closing.closedAt ?? DateTime.now(),
    );
    _closings.add(created);
    return created;
  }
}

/// Closing corrections (Week 5 Day 4, D156): mutable in-memory
/// corrections for the session. The demo starts with none —
/// corrections only arise from correcting a closing. Append-only:
/// a correction is never edited or deleted.
class MockClosingCorrectionRepository implements ClosingCorrectionRepository {
  final List<ClosingCorrection> _corrections = [];

  @override
  Future<List<ClosingCorrection>> getCorrections({String? branchId}) async {
    if (branchId == null) return List.unmodifiable(_corrections);
    return List.unmodifiable(_corrections.where((c) => c.branchId == branchId));
  }

  @override
  Future<List<ClosingCorrection>> getCorrectionsForClosing(
    String originalClosingId,
  ) async {
    return List.unmodifiable(
      _corrections.where((c) => c.originalClosingId == originalClosingId),
    );
  }

  @override
  Future<ClosingCorrection> createCorrection(
    ClosingCorrection correction,
  ) async {
    final created = correction.copyWith(
      id: 'cc-${_corrections.length + 1}',
      correctedAt: correction.correctedAt ?? DateTime.now(),
    );
    _corrections.add(created);
    return created;
  }
}

/// Cash reconciliations (Week 5 Day 4, D157): mutable in-memory
/// drawer counts for the session. The demo starts with none —
/// reconciliations only arise from counting a drawer. Append-only:
/// a recount is a new record.
class MockCashReconciliationRepository implements CashReconciliationRepository {
  final List<CashReconciliation> _reconciliations = [];

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  @override
  Future<List<CashReconciliation>> getReconciliations({
    String? branchId,
  }) async {
    if (branchId == null) return List.unmodifiable(_reconciliations);
    return List.unmodifiable(
      _reconciliations.where((r) => r.branchId == branchId),
    );
  }

  @override
  Future<List<CashReconciliation>> getReconciliationsForDay({
    required String branchId,
    required DateTime date,
  }) async {
    return List.unmodifiable(
      _reconciliations.where(
        (r) => r.branchId == branchId && _sameDay(r.date, date),
      ),
    );
  }

  @override
  Future<CashReconciliation> createReconciliation(
    CashReconciliation reconciliation,
  ) async {
    final created = reconciliation.copyWith(
      id: 'cr-${_reconciliations.length + 1}',
      countedAt: reconciliation.countedAt ?? DateTime.now(),
    );
    _reconciliations.add(created);
    return created;
  }
}

/// Supplier payments (Week 2 Day 5): mutable in-memory payments for
/// the session. The demo starts with none — the seeded supplier
/// ledger carries one historical payment (MedServe, Rs 11,750) as a
/// ledger entry, not as a payment record, because payment records
/// only exist from the Day 5 allocation flow onward.
class MockSupplierPaymentRepository implements SupplierPaymentRepository {
  final List<SupplierPayment> _payments = [];

  @override
  Future<List<SupplierPayment>> getPayments({
    String? branchId,
    String? supplierId,
  }) async {
    var scoped = _payments;
    if (branchId != null) {
      scoped = scoped.where((payment) => payment.branchId == branchId).toList();
    }
    if (supplierId != null) {
      scoped = scoped
          .where((payment) => payment.supplierId == supplierId)
          .toList();
    }
    return List.unmodifiable(scoped);
  }

  @override
  Future<SupplierPayment> createPayment(SupplierPayment payment) async {
    if (payment.id.isNotEmpty) {
      // D65 pattern: a caller-supplied non-empty id is the document
      // id — a retry with the same id returns the existing payment
      // instead of writing a second one (the layer passes its
      // idempotency key as the id, D147).
      for (final stored in _payments) {
        if (stored.id == payment.id) return stored;
      }
    }
    final created = payment.copyWith(
      id: payment.id.isNotEmpty ? payment.id : 'spay-${_payments.length + 1}',
      createdAt: DateTime.now(),
    );
    _payments.add(created);
    return created;
  }
}

class MockPrescriptionRepository implements PrescriptionRepository {
  final List<Prescription> _prescriptions = generateDemoPrescriptions();

  List<Prescription> _scoped(String? branchId) {
    // Prescriptions carry a branchId on the Day 3 model (D69); the
    // seed encodes the branch in the id prefix (`rx-dha-…` /
    // `rx-glb-…`) for records created before that field existed.
    if (branchId == null) return _prescriptions;
    return _prescriptions.where((rx) {
      final rxBranch = rx.branchId;
      if (rxBranch != null) return rxBranch == branchId;
      final prefix = branchId == 'branch-dha-main' ? 'rx-dha-' : 'rx-glb-';
      return rx.id.startsWith(prefix);
    }).toList();
  }

  @override
  Future<List<Prescription>> getPrescriptions({String? branchId}) async =>
      List.unmodifiable(_scoped(branchId));

  @override
  Future<List<Prescription>> getPending({String? branchId}) async =>
      List.unmodifiable(
        _scoped(branchId)
            .where((rx) => rx.status == PrescriptionStatus.pending),
      );

  @override
  Future<Prescription?> getById(String id) async {
    for (final rx in _prescriptions) {
      if (rx.id == id) return rx;
    }
    return null;
  }

  @override
  Future<Prescription?> reviewPrescription({
    required String id,
    required PrescriptionStatus status,
    required String reviewedBy,
    String? reviewNotes,
  }) async {
    final index = _prescriptions.indexWhere((rx) => rx.id == id);
    if (index == -1) return null;
    final updated = _prescriptions[index].copyWith(
      status: status,
      reviewedBy: reviewedBy,
      reviewedAt: DateTime.now(),
      reviewNotes: reviewNotes?.trim().isEmpty ?? true
          ? null
          : reviewNotes!.trim(),
      clearReviewNotes: reviewNotes?.trim().isEmpty ?? true,
    );
    _prescriptions[index] = updated;
    return updated;
  }

  @override
  Future<Prescription?> resubmitPrescription({
    required String id,
    required DateTime validUntil,
  }) async {
    final index = _prescriptions.indexWhere((rx) => rx.id == id);
    if (index == -1) return null;
    final old = _prescriptions[index];
    final updated = old.copyWith(
      status: PrescriptionStatus.pending,
      clearReviewedBy: true,
      clearReviewedAt: true,
      clearReviewNotes: true,
      validUntil: validUntil,
      resubmissionCount: old.resubmissionCount + 1,
    );
    _prescriptions[index] = updated;
    return updated;
  }

  @override
  Future<Prescription> createPrescription(
    Prescription prescription, {
    String? branchId,
  }) async {
    // New records join the active branch by id prefix (see _scoped):
    // the caller passes an id of '' and the branch in the id it
    // builds; here we assign the next sequence for that branch.
    // A branch id passed explicitly (or on the record) wins over the
    // prefix and is stored on the record (Week 2 Day 3, D69).
    final explicitBranch = branchId ?? prescription.branchId;
    final isDha =
        explicitBranch == 'branch-dha-main' ||
        (explicitBranch == null && prescription.id.startsWith('rx-dha-'));
    final prefix = isDha ? 'rx-dha-' : 'rx-glb-';
    final count = _prescriptions.where((rx) => rx.id.startsWith(prefix)).length;
    final created = prescription.copyWith(
      id: '$prefix${count + 1}',
      branchId:
          explicitBranch ?? (isDha ? 'branch-dha-main' : 'branch-demo-gulberg'),
      status: PrescriptionStatus.pending,
      createdAt: DateTime.now(),
    );
    _prescriptions.add(created);
    return created;
  }

  @override
  Future<Prescription> upsertPrescription(
    Prescription prescription, {
    String? branchId,
  }) async {
    // Unlike `createPrescription` the status is kept as given — a
    // restore replays the review state, it does not reset it.
    final explicitBranch = branchId ?? prescription.branchId;
    final isDha =
        explicitBranch == 'branch-dha-main' ||
        (explicitBranch == null && prescription.id.startsWith('rx-dha-'));
    final prefix = isDha ? 'rx-dha-' : 'rx-glb-';
    final count = _prescriptions.where((rx) => rx.id.startsWith(prefix)).length;
    final id = prescription.id.isEmpty
        ? '$prefix${count + 1}'
        : prescription.id;
    final saved = prescription.copyWith(
      id: id,
      branchId:
          explicitBranch ?? (isDha ? 'branch-dha-main' : 'branch-demo-gulberg'),
      createdAt: prescription.createdAt ?? DateTime.now(),
    );
    final index = _prescriptions.indexWhere((rx) => rx.id == id);
    if (index == -1) {
      _prescriptions.add(saved);
    } else {
      _prescriptions[index] = saved;
    }
    return saved;
  }
}

/// Purchase orders (Day 7): mutable in-memory POs for the session.
class MockPurchaseOrderRepository implements PurchaseOrderRepository {
  final List<PurchaseOrder> _orders = generateDemoPurchaseOrders();

  @override
  Future<List<PurchaseOrder>> getPurchaseOrders({
    String? branchId,
    String? supplierId,
  }) async {
    var scoped = _orders;
    if (branchId != null) {
      scoped = scoped.where((po) => po.branchId == branchId).toList();
    }
    if (supplierId != null) {
      scoped = scoped.where((po) => po.supplierId == supplierId).toList();
    }
    return List.unmodifiable(scoped);
  }

  @override
  Future<PurchaseOrder?> getById(String id) async {
    for (final po in _orders) {
      if (po.id == id) return po;
    }
    return null;
  }

  @override
  Future<PurchaseOrder> createPurchaseOrder(PurchaseOrder order) async {
    // Client-generated id (auto purchase approval, D65): a retry with
    // the same key returns the already-created PO, never a duplicate.
    if (order.id.isNotEmpty) {
      for (final existing in _orders) {
        if (existing.id == order.id) return existing;
      }
    }
    final branchCode = order.branchId == 'branch-dha-main' ? 'DHA' : 'GLB';
    final sequence = 1000 + _orders.length + 1;
    final saved = order.copyWith(
      id: order.id.isEmpty ? 'po-$branchCode-$sequence' : order.id,
      poNumber: 'PO-$branchCode-$sequence',
      status: PurchaseOrderStatus.draft,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    _orders.add(saved);
    return saved;
  }

  @override
  Future<void> updatePurchaseOrder(PurchaseOrder order) async {
    final index = _orders.indexWhere((po) => po.id == order.id);
    if (index == -1) return;
    _orders[index] = order.copyWith(updatedAt: DateTime.now());
  }

  @override
  Future<PurchaseOrder> upsertPurchaseOrder(PurchaseOrder order) async {
    // Unlike `createPurchaseOrder` the status is kept as given — a
    // restore replays the PO state, it does not reset it to Draft.
    final branchCode = order.branchId == 'branch-dha-main' ? 'DHA' : 'GLB';
    final sequence = 1000 + _orders.length + 1;
    final id = order.id.isEmpty ? 'po-$branchCode-$sequence' : order.id;
    final saved = order.copyWith(
      id: id,
      poNumber: order.poNumber.isEmpty
          ? 'PO-$branchCode-$sequence'
          : order.poNumber,
      createdAt: order.createdAt ?? DateTime.now(),
      updatedAt: DateTime.now(),
    );
    final index = _orders.indexWhere((po) => po.id == id);
    if (index == -1) {
      _orders.add(saved);
    } else {
      _orders[index] = saved;
    }
    return saved;
  }
}

class MockGoodsReceiptRepository implements GoodsReceiptRepository {
  final List<GoodsReceipt> _receipts = [];

  @override
  Future<List<GoodsReceipt>> getGoodsReceipts({
    String? branchId,
    String? poId,
  }) async {
    var scoped = _receipts;
    if (branchId != null) {
      scoped = scoped.where((r) => r.branchId == branchId).toList();
    }
    if (poId != null) {
      scoped = scoped.where((r) => r.poId == poId).toList();
    }
    return List.unmodifiable(scoped);
  }

  @override
  Future<GoodsReceipt?> getById(String id) async {
    for (final receipt in _receipts) {
      if (receipt.id == id) return receipt;
    }
    return null;
  }

  @override
  Future<GoodsReceipt> createGoodsReceipt(GoodsReceipt receipt) async {
    // Client id = idempotency key (D65 pattern): a retry with the
    // same key returns the already-saved receipt, never a second
    // document — the production layer relies on this.
    if (receipt.id.isNotEmpty) {
      for (final existing in _receipts) {
        if (existing.id == receipt.id) return existing;
      }
    }
    final branchCode = receipt.branchId == 'branch-dha-main' ? 'DHA' : 'GLB';
    final sequence = 1000 + _receipts.length + 1;
    final saved = receipt.copyWith(
      id: receipt.id.isEmpty ? 'gr-$branchCode-$sequence' : receipt.id,
      receiptNumber: 'GR-$branchCode-$sequence',
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    _receipts.add(saved);
    return saved;
  }
}

class MockSalaryRepository implements SalaryRepository {
  MockSalaryRepository() : _records = demoSalaryRecords();

  final List<SalaryRecord> _records;

  @override
  Future<List<SalaryRecord>> getSalaryRecords({
    String? branchId,
    String? month,
  }) async {
    var scoped = _records;
    if (branchId != null) {
      scoped = scoped.where((r) => r.branchId == branchId).toList();
    }
    if (month != null) {
      scoped = scoped.where((r) => r.month == month).toList();
    }
    return List.unmodifiable(scoped);
  }

  @override
  Future<SalaryRecord?> getById(String id) async {
    for (final record in _records) {
      if (record.id == id) return record;
    }
    return null;
  }

  @override
  Future<SalaryRecord> saveSalaryRecord(SalaryRecord record) async {
    // Repository re-checks (D100 pattern — mirrors the pure
    // `validateSalaryRecord` in salary_logic.dart, which the future
    // edit UI will use): negative amounts, a bad month, or a
    // negative net never reach the store.
    if (record.employeeId.isEmpty || record.branchId.isEmpty) {
      throw ArgumentError('A salary record needs an employee and a branch.');
    }
    if (!RegExp(r'^\d{4}-(0[1-9]|1[0-2])$').hasMatch(record.month)) {
      throw ArgumentError('Month must look like YYYY-MM (e.g. 2026-11).');
    }
    if (record.baseSalaryMinor < 0 ||
        record.allowancesMinor < 0 ||
        record.deductionsMinor < 0) {
      throw ArgumentError('Salary amounts cannot be negative.');
    }
    if (record.netMinor < 0) {
      throw ArgumentError(
        'Net salary cannot be negative — deductions exceed pay.',
      );
    }
    final index = _records.indexWhere(
      (r) => r.employeeId == record.employeeId && r.month == record.month,
    );
    final saved = record.copyWith(
      id: record.id.isEmpty
          ? 'sal-${record.employeeId}-${record.month}'
          : record.id,
      createdAt: index == -1
          ? DateTime.now()
          : _records[index].createdAt ?? DateTime.now(),
      updatedAt: DateTime.now(),
    );
    if (index == -1) {
      _records.add(saved);
    } else {
      _records[index] = saved;
    }
    return saved;
  }
}

/// Default providers — mock implementations until the Firebase data layer
/// lands in Week 2. Screens inject these providers, never the mocks.
///
/// Week 2 Day 3 (D75): every provider reads the repository bundle
/// ([repositoryBundleProvider]), so overriding that one provider
/// switches the whole app from mock to Firestore. The default bundle
/// is the mock bundle — the app works exactly as before with zero
/// config.
final medicineRepositoryProvider = Provider<MedicineRepository>(
  (ref) => ref.watch(repositoryBundleProvider).medicines,
);

final orderRepositoryProvider = Provider<OrderRepository>(
  (ref) => ref.watch(repositoryBundleProvider).orders,
);

final inventoryRepositoryProvider = Provider<InventoryRepository>(
  (ref) => ref.watch(repositoryBundleProvider).inventory,
);

final customerRepositoryProvider = Provider<CustomerRepository>(
  (ref) => ref.watch(repositoryBundleProvider).customers,
);

final saleRepositoryProvider = Provider<SaleRepository>(
  (ref) => ref.watch(repositoryBundleProvider).sales,
);

final saleReturnRepositoryProvider = Provider<SaleReturnRepository>(
  (ref) => ref.watch(repositoryBundleProvider).saleReturns,
);

final supplierRepositoryProvider = Provider<SupplierRepository>(
  (ref) => ref.watch(repositoryBundleProvider).suppliers,
);

final prescriptionRepositoryProvider = Provider<PrescriptionRepository>(
  (ref) => ref.watch(repositoryBundleProvider).prescriptions,
);

final purchaseOrderRepositoryProvider = Provider<PurchaseOrderRepository>(
  (ref) => ref.watch(repositoryBundleProvider).purchaseOrders,
);

final riderRepositoryProvider = Provider<RiderRepository>(
  (ref) => ref.watch(repositoryBundleProvider).riders,
);

/// Week 4 Day 2 stock transfers (D118): mock-backed by default —
/// the provider reads from the [RepositoryBundle], so the mock bundle
/// is the default and a Firestore bundle override switches it to the
/// Firestore implementation exactly like the Day 3 repos (D101
/// pattern).
final stockTransferRepositoryProvider = Provider<StockTransferRepository>(
  (ref) => ref.watch(repositoryBundleProvider).stockTransfers,
);

/// Week 5 Day 1 adjustment queue (D146): mock-backed by default —
/// the provider reads from the [RepositoryBundle], so the mock bundle
/// is the default and a Firestore bundle override switches it to the
/// Firestore implementation exactly like the Day 3 repos (D101
/// pattern).
final stockAdjustmentRequestRepositoryProvider =
    Provider<StockAdjustmentRequestRepository>(
      (ref) => ref.watch(repositoryBundleProvider).stockAdjustments,
    );

/// Week 5 Day 2 branch directory (D148): mock-backed by default —
/// the provider reads from the [RepositoryBundle], so the mock bundle
/// is the default and a Firestore bundle override switches it to the
/// Firestore implementation exactly like the Day 3 repos (D101
/// pattern).
final branchRepositoryProvider = Provider<BranchRepository>(
  (ref) => ref.watch(repositoryBundleProvider).branches,
);

/// Week 2 Day 5 repositories (D89): mock-backed by default — the
/// providers below read from the [RepositoryBundle] (Week 3 Day 1,
/// D101), so the mock bundle is the default and a Firestore bundle
/// override switches all six to their Firestore implementations
/// exactly like the Day 3 repos. Each provider reads the bundle, so
/// screens inject these providers, never the repos directly.
final staffRepositoryProvider = Provider<StaffRepository>(
  (ref) => ref.watch(repositoryBundleProvider).staff,
);

final attendanceRepositoryProvider = Provider<AttendanceRepository>(
  (ref) => ref.watch(repositoryBundleProvider).attendance,
);

final shiftRepositoryProvider = Provider<ShiftRepository>(
  (ref) => ref.watch(repositoryBundleProvider).shifts,
);

final expenseRepositoryProvider = Provider<ExpenseRepository>(
  (ref) => ref.watch(repositoryBundleProvider).expenses,
);

final financialTransactionRepositoryProvider =
    Provider<FinancialTransactionRepository>(
      (ref) => ref.watch(repositoryBundleProvider).financialTransactions,
    );

final supplierPaymentRepositoryProvider = Provider<SupplierPaymentRepository>(
  (ref) => ref.watch(repositoryBundleProvider).supplierPayments,
);

/// Week 4 Day 3 repositories (D126): mock-backed by default — the
/// provider below reads from the [RepositoryBundle], so the mock
/// bundle is the default and a Firestore bundle override switches it
/// to the Firestore implementation exactly like the Day 3 repos
/// (D101 pattern).
final dailyClosingRepositoryProvider = Provider<DailyClosingRepository>(
  (ref) => ref.watch(repositoryBundleProvider).dailyClosings,
);

/// Week 5 Day 4 repositories (D156/D157): mock-backed by default —
/// the providers below read from the [RepositoryBundle], so the mock
/// bundle is the default and a Firestore bundle override switches
/// them to their Firestore implementations exactly like the Day 3
/// repos (D101 pattern).
final closingCorrectionRepositoryProvider =
    Provider<ClosingCorrectionRepository>(
      (ref) => ref.watch(repositoryBundleProvider).closingCorrections,
    );

final cashReconciliationRepositoryProvider =
    Provider<CashReconciliationRepository>(
      (ref) => ref.watch(repositoryBundleProvider).cashReconciliations,
    );

/// Week 3 Day 2 repositories (D102/D103): mock-backed by default —
/// the providers below read from the [RepositoryBundle], so the mock
/// bundle is the default and a Firestore bundle override switches
/// both to their Firestore implementations exactly like the Day 3
/// repos (D101 pattern).
final goodsReceiptRepositoryProvider = Provider<GoodsReceiptRepository>(
  (ref) => ref.watch(repositoryBundleProvider).goodsReceipts,
);

final salaryRepositoryProvider = Provider<SalaryRepository>(
  (ref) => ref.watch(repositoryBundleProvider).salary,
);

/// Week 3 Day 3 report counters (D105/D106): mock-backed by
/// default — the provider reads from the [RepositoryBundle], so the
/// mock bundle is the default and a Firestore bundle override
/// switches it to the rollup-doc reader exactly like the Day 3 repos
/// (D101 pattern).
final reportCounterRepositoryProvider = Provider<ReportCounterRepository>(
  (ref) => ref.watch(repositoryBundleProvider).reportCounters,
);
