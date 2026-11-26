/// Firestore schema — collection paths + document field contracts.
///
/// Week 2 Day 1 (SRS §3). This module is the **single source of truth**
/// for where production data lives. It contains NO Firebase calls: there
/// is no Firebase project yet (D13), so nothing here talks to the cloud.
/// The Firestore implementations (Week 2 Day 2+) build their document
/// paths and payloads from these constants, and the rules draft in
/// `firebase/firestore.rules` enforces the same shapes server-side.
///
/// Conventions (SRS §3):
/// - Root collections hold organization-wide data; branch-scoped data
///   lives in subcollections under `branches/{branchId}/`.
/// - Every document carries `organizationId` (+ `branchId` where
///   branch-scoped) and `createdAt` / `updatedAt` (server timestamps).
/// - Money is ALWAYS int minor units (paisa) — never floats (D6).
/// - Document ID = the client-generated idempotency key for sales and
///   orders, so a retried write can never duplicate (SRS §2.5,
///   FR-POS-11). Every other document uses a Firestore auto-ID, except
///   counters and per-(branch, medicine) inventory docs.
/// - History collections (`stockTransactions`, `financialTransactions`,
///   customer/supplier `ledger`, `auditLogs`) are append-only: create,
///   never update or delete.
/// - No document is ever hard-deleted by application code (soft delete
///   via `status` / `deletedAt` only).
library;

/// Firestore batched writes accept at most 500 operations (SRS §3).
const maxFirestoreBatchWrites = 500;

/// Placeholder organization id for the demo org. The real id comes from
/// the `organizations` document created when the Firebase project
/// exists; until then every local document is stamped with this value
/// so the shape is already correct.
const demoOrganizationId = 'org-fazal-din-demo';

/// One field of a Firestore document: its name, Firestore type,
/// whether a write must include it, and a short note.
class FirestoreField {
  const FirestoreField(
    this.name,
    this.type, {
    this.required = false,
    this.notes = '',
  });

  final String name;

  /// Firestore type as written in SRS §3, e.g. `string`, `int (paisa)`,
  /// `timestamp`, `map`, `string[]`, `bool`.
  final String type;
  final bool required;
  final String notes;
}

/// Fields every document carries (SRS §3 conventions).
const commonFields = <FirestoreField>[
  FirestoreField('organizationId', 'string', required: true),
  FirestoreField('createdAt', 'timestamp', required: true),
  FirestoreField('updatedAt', 'timestamp', required: true),
];

/// Fields every branch-scoped document carries, in addition to
/// [commonFields].
const branchScopedFields = <FirestoreField>[
  FirestoreField('branchId', 'string', required: true),
];

/// Collection paths and document field contracts, transcribed from
/// SRS §3. Keys are collection path patterns; `{branchId}` marks a
/// branch subcollection.
class FirestoreSchema {
  FirestoreSchema._();

  // -- Root collections (organization-wide) ---------------------------

  static const String organizations = 'organizations';
  static const String branches = 'branches';
  static const String users = 'users';
  static const String manufacturers = 'manufacturers';
  static const String medicineCategories = 'medicineCategories';
  static const String medicines = 'medicines';
  static const String suppliers = 'suppliers';
  static const String expenseCategories = 'expenseCategories';
  static const String auditLogs = 'auditLogs';

  // -- Branch subcollections (SRS §3.3–§3.7) -------------------------

  static const String batches = 'batches';
  static const String inventory = 'inventory';
  static const String stockTransactions = 'stockTransactions';
  static const String stockTransfers = 'stockTransfers';
  static const String stockAdjustments = 'stockAdjustments';
  static const String stockCounts = 'stockCounts';
  static const String customers = 'customers';
  static const String customerLedger = 'ledger';
  static const String sales = 'sales';
  static const String saleItems = 'items';
  static const String salePayments = 'payments';
  static const String saleReturns = 'saleReturns';
  static const String prescriptions = 'prescriptions';
  static const String orders = 'orders';
  static const String orderItems = 'items';
  static const String riders = 'riders';
  static const String purchaseOrders = 'purchaseOrders';
  static const String purchaseOrderItems = 'items';
  static const String goodsReceipts = 'goodsReceipts';
  static const String goodsReceiptItems = 'items';
  static const String salaries = 'salaries';
  static const String purchaseReturns = 'purchaseReturns';
  static const String supplierPayments = 'supplierPayments';
  static const String supplierLedger = 'ledger';
  static const String employees = 'employees';
  static const String attendances = 'attendances';
  static const String shifts = 'shifts';
  static const String expenses = 'expenses';
  static const String financialTransactions = 'financialTransactions';
  static const String notifications = 'notifications';
  static const String cashDrawers = 'cashDrawers';
  static const String dailyClosings = 'dailyClosings';
  static const String closingCorrections = 'closingCorrections';
  static const String cashReconciliations = 'cashReconciliations';
  static const String counters = 'counters';

  // -- Organization subcollections ------------------------------------

  static const String orgRoles = 'roles';
  static const String orgSettings = 'settings';
  static const String orgFeatureModules = 'featureModules';
  static const String orgWarehouses = 'warehouses';
  static const String orgSubscriptions = 'subscriptions';

  // -- Path builders ---------------------------------------------------

  static String organizationDoc(String orgId) => 'organizations/$orgId';

  static String organizationSubcollection(String orgId, String name) =>
      'organizations/$orgId/$name';

  static String branchDoc(String branchId) => 'branches/$branchId';

  /// `branches/{branchId}/{subcollection}`.
  static String branchCollection(String branchId, String subcollection) =>
      'branches/$branchId/$subcollection';

  /// `branches/{branchId}/{subcollection}/{docId}`.
  static String branchDocPath(
    String branchId,
    String subcollection,
    String docId,
  ) => 'branches/$branchId/$subcollection/$docId';

  /// `branches/{branchId}/{parent}/{parentId}/{child}` — e.g. a sale's
  /// `items` subcollection or a customer's `ledger`.
  static String nestedCollection(
    String branchId,
    String parent,
    String parentId,
    String child,
  ) => 'branches/$branchId/$parent/$parentId/$child';

  // Convenience builders for the collections the app writes most.
  static String salesPath(String branchId) => branchCollection(branchId, sales);

  static String saleDocPath(String branchId, String saleId) =>
      branchDocPath(branchId, sales, saleId);

  static String saleItemsPath(String branchId, String saleId) =>
      nestedCollection(branchId, sales, saleId, saleItems);

  /// `branches/{branchId}/sales/{saleId}/payments` (D137 — SRS §3.4).
  static String salePaymentsPath(String branchId, String saleId) =>
      nestedCollection(branchId, sales, saleId, salePayments);

  static String saleReturnsPath(String branchId) =>
      branchCollection(branchId, saleReturns);

  /// `branches/{branchId}/goodsReceipts`.
  static String goodsReceiptsPath(String branchId) =>
      branchCollection(branchId, goodsReceipts);

  static String goodsReceiptDocPath(String branchId, String receiptId) =>
      branchDocPath(branchId, goodsReceipts, receiptId);

  static String goodsReceiptItemsPath(String branchId, String receiptId) =>
      nestedCollection(branchId, goodsReceipts, receiptId, goodsReceiptItems);

  /// `branches/{branchId}/salaries` (Week 3 Day 2, D102).
  static String salariesPath(String branchId) =>
      branchCollection(branchId, salaries);

  static String salaryDocPath(String branchId, String salaryId) =>
      branchDocPath(branchId, salaries, salaryId);

  static String saleReturnDocPath(String branchId, String returnId) =>
      branchDocPath(branchId, saleReturns, returnId);

  static String saleReturnItemsPath(String branchId, String returnId) =>
      nestedCollection(branchId, saleReturns, returnId, saleItems);

  static String ordersPath(String branchId) =>
      branchCollection(branchId, orders);

  static String orderDocPath(String branchId, String orderId) =>
      branchDocPath(branchId, orders, orderId);

  static String inventoryPath(String branchId) =>
      branchCollection(branchId, inventory);

  /// One doc per (branch, medicine): the doc id IS the medicine id.
  static String inventoryDocPath(String branchId, String medicineId) =>
      branchDocPath(branchId, inventory, medicineId);

  static String batchesPath(String branchId) =>
      branchCollection(branchId, batches);

  static String stockTransactionsPath(String branchId) =>
      branchCollection(branchId, stockTransactions);

  /// `branches/{branchId}/stockTransfers` (Week 4 Day 2, D118).
  static String stockTransfersPath(String branchId) =>
      branchCollection(branchId, stockTransfers);

  /// `branches/{branchId}/stockAdjustments` (Week 5 Day 1, D146).
  static String stockAdjustmentsPath(String branchId) =>
      branchCollection(branchId, stockAdjustments);

  static String stockAdjustmentDocPath(String branchId, String requestId) =>
      branchDocPath(branchId, stockAdjustments, requestId);

  static String stockTransferDocPath(String branchId, String transferId) =>
      branchDocPath(branchId, stockTransfers, transferId);

  static String customerLedgerPath(String branchId, String customerId) =>
      nestedCollection(branchId, customers, customerId, customerLedger);

  static String supplierLedgerPath(String supplierId) =>
      'suppliers/$supplierId/$supplierLedger';

  static String countersPath(String branchId) =>
      branchCollection(branchId, counters);

  /// `branches/{branchId}/counters/{counterId}` — sequential numbers
  /// (invoice / order / PO) and pre-computed aggregates (SRS §2.9).
  static String counterDocPath(String branchId, String counterId) =>
      branchDocPath(branchId, counters, counterId);

  /// `branches/{branchId}/counters/daily-{yyyy-MM-dd}` — one doc per
  /// branch per day, written by the daily counters rollup Function
  /// (Job 3, `firebase/functions-design.md`; Week 3 Day 3, D105).
  static String dailyCounterDocId(DateTime date) =>
      'daily-${date.year}-${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  static String dailyCounterDocPath(String branchId, DateTime date) =>
      counterDocPath(branchId, dailyCounterDocId(date));

  // -- Cloud Storage paths (Blaze, D62) -------------------------------
  //
  // Prescription photos live in Cloud Storage (bytes) with metadata
  // on the Firestore prescription doc. Same branch scoping as the
  // Firestore model; enforced by `firebase/storage.rules`.

  /// `organizations/{orgId}/branches/{branchId}/prescriptions/{prescriptionId}.jpg`.
  static String storagePrescriptionPath(
    String orgId,
    String branchId,
    String prescriptionId,
  ) =>
      'organizations/$orgId/branches/$branchId/prescriptions/$prescriptionId.jpg';

  /// `organizations/{orgId}/medicines/{medicineId}.jpg`.
  static String storageMedicineImagePath(String orgId, String medicineId) =>
      'organizations/$orgId/medicines/$medicineId.jpg';

  /// `organizations/{orgId}/brand/logo.png`.
  static String storageBrandLogoPath(String orgId) =>
      'organizations/$orgId/brand/logo.png';

  /// `organizations/{orgId}/backups/{date}/` — written by the
  /// scheduled backup Cloud Function (see `firebase/functions-design.md`).
  static String storageBackupPrefix(String orgId, String date) =>
      'organizations/$orgId/backups/$date/';

  /// A client-generated idempotency key is a valid Firestore document
  /// id as long as it is non-empty and contains no `/`. Sales and
  /// orders use their key as the doc id (SRS §2.5).
  static bool isValidIdempotencyKey(String key) =>
      key.isNotEmpty && !key.contains('/');

  /// Field contracts per collection, transcribed from SRS §3. The key
  /// is the collection path pattern; the list always starts with the
  /// common fields. Only the fields the app writes are listed — the
  /// rules draft validates the required ones.
  static const Map<String, List<FirestoreField>> fieldsByCollection = {
    'organizations': [
      FirestoreField('name', 'string', required: true),
      FirestoreField('slug', 'string', required: true),
      FirestoreField('brandName', 'string'),
      FirestoreField(
        'brandLogoPath',
        'string',
        notes:
            'Cloud Storage path '
            '(organizations/{orgId}/brand/logo.png) — see '
            'firebase/storage.rules',
      ),
      FirestoreField('brandPrimaryColor', 'string'),
      FirestoreField('brandSecondaryColor', 'string'),
      FirestoreField('timezone', 'string'),
      FirestoreField('currency', 'string', notes: 'PKR default'),
      FirestoreField('status', 'string', notes: 'active / suspended'),
    ],
    'branches': [
      FirestoreField('organizationId', 'string', required: true),
      FirestoreField(
        'type',
        'string',
        required: true,
        notes: 'own / franchise',
      ),
      FirestoreField('name', 'string', required: true),
      FirestoreField(
        'code',
        'string',
        required: true,
        notes: 'short uppercase branch code (e.g. DHA), used in '
            'sequential numbers; the mapper writes the model code '
            'when valid, else the default derived from the branch '
            'id (D163)',
      ),
      FirestoreField('address', 'string'),
      FirestoreField('city', 'string'),
      FirestoreField('phone', 'string'),
      FirestoreField('managerId', 'string'),
      FirestoreField('status', 'string', notes: 'active / closed'),
      FirestoreField('franchiseFeeRate', 'int', notes: 'basis points'),
      FirestoreField('royaltyRate', 'int', notes: 'basis points, nullable'),
    ],
    'users': [
      FirestoreField('organizationId', 'string', required: true),
      FirestoreField('name', 'string', required: true),
      FirestoreField('email', 'string', required: true),
      FirestoreField('phone', 'string'),
      FirestoreField('status', 'string', notes: 'active / disabled'),
      FirestoreField('roleKeys', 'string[]'),
      FirestoreField('branchAccess', 'map', notes: 'branchId -> manage / view'),
      FirestoreField('lastLoginAt', 'timestamp'),
    ],
    'organizations/{orgId}/roles': [
      FirestoreField('name', 'string', required: true),
      FirestoreField('isSystem', 'bool'),
      FirestoreField('description', 'string'),
      FirestoreField('permissions', 'string[]', notes: 'permission keys'),
    ],
    'organizations/{orgId}/settings': [
      FirestoreField(
        'value',
        'dynamic',
        notes:
            'Per-org config: tax defaults, receipt format, '
            'discount limits, …',
      ),
    ],
    'organizations/{orgId}/featureModules': [
      FirestoreField('enabled', 'bool', required: true),
      FirestoreField('config', 'map'),
    ],
    'medicines': [
      FirestoreField('organizationId', 'string', required: true),
      FirestoreField('name', 'string', required: true),
      FirestoreField('genericName', 'string'),
      FirestoreField('brand', 'string'),
      FirestoreField('manufacturerId', 'string'),
      FirestoreField('categoryId', 'string'),
      FirestoreField('dosageForm', 'string'),
      FirestoreField('strength', 'string'),
      FirestoreField('unit', 'string'),
      FirestoreField('packSize', 'string'),
      FirestoreField('sku', 'string', notes: 'Unique per org'),
      FirestoreField('barcode', 'string'),
      FirestoreField(
        'location',
        'string',
        notes: 'Shelf / bin — default storage location (D138)',
      ),
      FirestoreField('purchasePrice', 'int (paisa)', required: true),
      FirestoreField('sellingPrice', 'int (paisa)', required: true),
      FirestoreField('taxRateBps', 'int'),
      FirestoreField(
        'prescriptionClass',
        'string',
        notes: 'otc / prescription / controlled',
      ),
      FirestoreField('storageInstructions', 'string'),
      FirestoreField('minStock', 'int'),
      FirestoreField('maxStock', 'int'),
      FirestoreField('reorderLevel', 'int'),
      FirestoreField(
        'imagePath',
        'string',
        notes:
            'Cloud Storage path '
            '(organizations/{orgId}/medicines/{id}.jpg) or local/asset '
            'ref for demo',
      ),
      FirestoreField('isActive', 'bool', required: true),
    ],
    'suppliers': [
      FirestoreField('organizationId', 'string', required: true),
      FirestoreField('name', 'string', required: true),
      FirestoreField('contactPerson', 'string'),
      FirestoreField('phone', 'string', required: true),
      FirestoreField('email', 'string'),
      FirestoreField('address', 'string'),
      FirestoreField('taxNumber', 'string'),
      FirestoreField('paymentTerms', 'string'),
      FirestoreField('isActive', 'bool', required: true),
    ],
    'branches/{branchId}/batches': [
      FirestoreField('medicineId', 'string', required: true),
      FirestoreField('batchNumber', 'string', required: true),
      FirestoreField('manufacturingDate', 'timestamp'),
      FirestoreField('expiryDate', 'timestamp', required: true),
      FirestoreField('purchasePrice', 'int (paisa)'),
      FirestoreField('quantityReceived', 'int', required: true),
      FirestoreField('quantityRemaining', 'int', required: true),
      FirestoreField(
        'status',
        'string',
        notes: 'available / quarantined / expired / returned',
      ),
    ],
    'branches/{branchId}/inventory': [
      FirestoreField('warehouseId', 'string'),
      FirestoreField('quantityOnHand', 'int', required: true),
      FirestoreField('quantityReserved', 'int', required: true),
      FirestoreField(
        'rack',
        'string',
        notes:
            'Per-branch override (D152): when set, stock views show '
            'rack/shelf instead of the master medicine location; '
            'empty = fall back to the master location.',
      ),
      FirestoreField(
        'shelf',
        'string',
        notes: 'Per-branch override (D152) — see `rack`.',
      ),
    ],
    'branches/{branchId}/stockTransactions': [
      FirestoreField('medicineId', 'string', required: true),
      FirestoreField('batchId', 'string'),
      FirestoreField(
        'type',
        'string',
        required: true,
        notes:
            'receive / sale / return / adjustment / transfer_in / '
            'transfer_out / damage / expiry',
      ),
      FirestoreField(
        'quantity',
        'int',
        required: true,
        notes: 'Signed: negative = stock out',
      ),
      FirestoreField('unitCost', 'int (paisa)'),
      FirestoreField(
        'referenceType',
        'string',
        notes: 'sale / order / purchase_order / count / …',
      ),
      FirestoreField('referenceId', 'string'),
      FirestoreField('userId', 'string'),
      FirestoreField('reason', 'string'),
      FirestoreField('approvedBy', 'string'),
    ],
    'branches/{branchId}/stockTransfers': [
      FirestoreField('transferNumber', 'string', required: true),
      FirestoreField('fromBranchId', 'string', required: true),
      FirestoreField('toBranchId', 'string', required: true),
      FirestoreField(
        'status',
        'string',
        notes:
            'requested / approved / dispatched / received / rejected / '
            'cancelled — Week 4 Day 2 (D120): `rejected` is added to '
            'the SRS contract, which listed no rejection state even '
            'though approval implies one',
      ),
      FirestoreField(
        'items',
        'map[]',
        required: true,
        notes:
            'Embedded lines ({medicineId, medicineName, quantity}) — '
            'Week 4 Day 2 (D120): the SRS contract named no items '
            'shape, so the lines live on the transfer doc instead of '
            'a subcollection (a transfer is one small document)',
      ),
      FirestoreField('note', 'string'),
      FirestoreField('requestedBy', 'string'),
      FirestoreField('approvedBy', 'string'),
      FirestoreField(
        'dispatchedBy',
        'string',
        notes: 'Added Week 4 Day 2 (D120)',
      ),
      FirestoreField(
        'receivedBy',
        'string',
        notes: 'Added Week 4 Day 2 (D120)',
      ),
      FirestoreField(
        'dispatchAllocations',
        'map[]',
        notes:
            'Added Week 4 Day 2 (D120): the FEFO allocations '
            'recorded at dispatch ({medicineId, batchId, batchNo, '
            'quantity, mfgDate, expiryDate, unitCostMinor}) — the '
            'receive step recreates the destination batches from '
            'these, so it never guesses which batch the units left in',
      ),
      FirestoreField(
        'isDemo',
        'bool',
        notes: 'True for seeded sample transfers (D118)',
      ),
    ],
    'branches/{branchId}/stockCounts': [
      FirestoreField('status', 'string', notes: 'open / submitted / approved'),
      FirestoreField('countedBy', 'string'),
      FirestoreField('approvedBy', 'string'),
    ],
    // Adjustment approval queue (Week 5 Day 1, D146 — SRS D-14 /
    // FR-INV-08, §5.2.4): one doc per request, doc id = the request
    // id (`adj-N`, also the idempotency key for the approval apply).
    // Not in the SRS §3 list — the SRS names the approval flow but
    // gives it no collection; the queue needs a durable home now
    // that it is persisted. The doc is created pending and updated
    // in place when decided (never deleted); the stock movement it
    // applies lives in `stockTransactions`, not here.
    'branches/{branchId}/stockAdjustments': [
      FirestoreField('batchId', 'string', required: true),
      FirestoreField('batchNo', 'string', required: true),
      FirestoreField('medicineId', 'string', required: true),
      FirestoreField('medicineName', 'string', required: true),
      FirestoreField('deltaQty', 'int', required: true, notes: 'Signed'),
      FirestoreField('reason', 'string', required: true),
      FirestoreField('requesterId', 'string', required: true),
      FirestoreField('requesterName', 'string', required: true),
      FirestoreField('requestedAt', 'timestamp', required: true),
      FirestoreField(
        'status',
        'string',
        required: true,
        notes: 'pending / approved / rejected',
      ),
      FirestoreField('decidedById', 'string'),
      FirestoreField('decidedByName', 'string'),
      FirestoreField('decidedAt', 'timestamp'),
      FirestoreField('decisionNote', 'string'),
      FirestoreField(
        'movementId',
        'string',
        notes: 'Ledger movement id once approved',
      ),
    ],
    'branches/{branchId}/customers': [
      FirestoreField('name', 'string', required: true),
      FirestoreField('phone', 'string', required: true),
      FirestoreField('address', 'string'),
      FirestoreField('creditLimit', 'int (paisa)'),
      FirestoreField('loyaltyPoints', 'int'),
      FirestoreField('isActive', 'bool', required: true),
    ],
    'branches/{branchId}/customers/{customerId}/ledger': [
      FirestoreField(
        'type',
        'string',
        required: true,
        notes: 'credit_sale / payment / adjustment',
      ),
      FirestoreField(
        'amount',
        'int (paisa)',
        required: true,
        notes: 'Signed: + = customer owes more',
      ),
      FirestoreField('referenceType', 'string'),
      FirestoreField('referenceId', 'string'),
      FirestoreField('balanceAfter', 'int (paisa)', required: true),
    ],
    'branches/{branchId}/sales': [
      FirestoreField('invoiceNumber', 'string', required: true),
      FirestoreField('customerId', 'string', notes: 'Nullable = walk-in'),
      FirestoreField('cashierId', 'string'),
      FirestoreField('pharmacistId', 'string', notes: 'Nullable'),
      FirestoreField('subtotal', 'int (paisa)', required: true),
      FirestoreField('discountTotal', 'int (paisa)'),
      FirestoreField('taxTotal', 'int (paisa)'),
      FirestoreField('grandTotal', 'int (paisa)', required: true),
      FirestoreField(
        'status',
        'string',
        notes: 'completed / returned / partially_returned / voided',
      ),
      FirestoreField(
        'idempotencyKey',
        'string',
        required: true,
        notes: 'Also the document id',
      ),
    ],
    'branches/{branchId}/sales/{saleId}/items': [
      FirestoreField('medicineId', 'string', required: true),
      FirestoreField('batchId', 'string'),
      FirestoreField('medicineName', 'string', required: true),
      FirestoreField('unitPrice', 'int (paisa)', required: true),
      FirestoreField('quantity', 'int', required: true),
      FirestoreField('discount', 'int (paisa)'),
      FirestoreField('lineTotal', 'int (paisa)', required: true),
    ],
    'branches/{branchId}/sales/{saleId}/payments': [
      FirestoreField(
        'method',
        'string',
        required: true,
        notes: 'cash / card / credit',
      ),
      FirestoreField('amount', 'int (paisa)', required: true),
      FirestoreField('reference', 'string'),
    ],
    'branches/{branchId}/saleReturns': [
      FirestoreField('saleId', 'string', required: true),
      FirestoreField('reason', 'string'),
      FirestoreField('status', 'string'),
      FirestoreField('refundedAmount', 'int (paisa)'),
      FirestoreField('approvedBy', 'string'),
    ],
    'branches/{branchId}/saleReturns/{returnId}/items': [
      FirestoreField('saleItemId', 'string', notes: 'medicineId|saleBatchId'),
      FirestoreField('medicineId', 'string', required: true),
      FirestoreField('medicineName', 'string', required: true),
      FirestoreField('quantity', 'int', required: true),
      FirestoreField('unitPrice', 'int (paisa)', required: true),
      FirestoreField('lineDiscount', 'int (paisa)'),
      FirestoreField('refundMinor', 'int (paisa)', required: true),
      FirestoreField('restockBatchId', 'string'),
      FirestoreField('restockBatchNo', 'string'),
    ],
    'branches/{branchId}/prescriptions': [
      FirestoreField('customerId', 'string'),
      FirestoreField('orderId', 'string', notes: 'Nullable'),
      FirestoreField('saleId', 'string', notes: 'Nullable'),
      FirestoreField(
        'photoStoragePath',
        'string',
        notes:
            'Cloud Storage path '
            '(organizations/{orgId}/branches/{branchId}/prescriptions/'
            '{prescriptionId}.jpg) — the bytes live in Storage, the '
            'metadata lives here',
      ),
      FirestoreField('photoContentType', 'string', notes: 'e.g. image/jpeg'),
      FirestoreField('photoUploadedAt', 'timestamp'),
      FirestoreField('photoUploadedBy', 'string'),
      FirestoreField(
        'localPhotoPath',
        'string',
        notes:
            'On-device cache copy (nullable) — the Storage path '
            'above is the source of truth',
      ),
      FirestoreField(
        'reminderSentAt',
        'timestamp',
        notes:
            'Stamped by the prescription-reminder Function so a '
            'prescription is reminded at most once a day',
      ),
      FirestoreField(
        'reviewStatus',
        'string',
        notes: 'pending / approved / rejected',
      ),
      FirestoreField('reviewedBy', 'string'),
      FirestoreField('reviewedAt', 'timestamp'),
      FirestoreField('notes', 'string'),
      FirestoreField(
        'validUntil',
        'timestamp',
        notes:
            'Last valid day of the prescription (Week 2 Day 5, D90). '
            'An approved prescription past this day cannot unblock '
            'an order. Null on legacy records = no expiry recorded.',
      ),
      FirestoreField(
        'resubmissionCount',
        'int',
        notes:
            'How many times the prescription was re-submitted for '
            'review after rejection / clearer-photo (Week 2 Day 5, '
            'D91).',
      ),
    ],
    'branches/{branchId}/orders': [
      FirestoreField('orderNumber', 'string', required: true),
      FirestoreField('customerId', 'string'),
      FirestoreField('source', 'string', notes: 'whatsapp / phone / walk_in'),
      FirestoreField(
        'status',
        'string',
        notes:
            'pending / confirmed / preparing / out_for_delivery / '
            'delivered / cancelled',
      ),
      FirestoreField('deliveryAddress', 'string'),
      FirestoreField('deliveryCharge', 'int (paisa)'),
      FirestoreField('subtotal', 'int (paisa)'),
      FirestoreField('grandTotal', 'int (paisa)', required: true),
      FirestoreField('paymentMethod', 'string'),
      FirestoreField('paymentStatus', 'string'),
      FirestoreField('riderId', 'string', notes: 'Nullable'),
      FirestoreField('createdBy', 'string'),
      FirestoreField('prescriptionId', 'string', notes: 'Nullable'),
      FirestoreField(
        'idempotencyKey',
        'string',
        required: true,
        notes: 'Also the document id',
      ),
    ],
    'branches/{branchId}/riders': [
      FirestoreField('userId', 'string', notes: 'Nullable'),
      FirestoreField('name', 'string', required: true),
      FirestoreField('phone', 'string'),
      FirestoreField('vehicle', 'string'),
      FirestoreField('status', 'string'),
      FirestoreField(
        'branchId',
        'string',
        notes:
            'Extra (Week 4 Day 2, D119): the rider\'s home branch — '
            'riders live in a branch-scoped collection, so the doc '
            'carries its branch like the employees extras in D99',
      ),
    ],
    'branches/{branchId}/purchaseOrders': [
      FirestoreField('poNumber', 'string', required: true),
      FirestoreField('supplierId', 'string', required: true),
      FirestoreField(
        'status',
        'string',
        notes:
            'draft / approved / partially_received / received / '
            'cancelled',
      ),
      FirestoreField('totalAmount', 'int (paisa)', required: true),
      FirestoreField('approvedBy', 'string'),
    ],
    'branches/{branchId}/goodsReceipts': [
      FirestoreField('poId', 'string', required: true),
      FirestoreField('receiptNumber', 'string'),
      FirestoreField('receivedBy', 'string'),
      FirestoreField('status', 'string'),
      // Extended Week 3 Day 2 (D104): the SRS contract named no
      // receipt date, supplier or value, but a receipt that cannot
      // say when the goods arrived, from whom, or for how much is
      // not an audit record — the production receiving write fills
      // all three, and the mapper validates them.
      FirestoreField(
        'receivedAt',
        'timestamp',
        required: true,
        notes: 'Added Week 3 Day 2 (D104)',
      ),
      FirestoreField(
        'supplierId',
        'string',
        required: true,
        notes: 'Added Week 3 Day 2 (D104)',
      ),
      FirestoreField(
        'totalValueMinor',
        'int (paisa)',
        required: true,
        notes:
            'Added Week 3 Day 2 (D104): the value the supplier '
            'ledger is charged for this receipt',
      ),
    ],
    'branches/{branchId}/goodsReceipts/{receiptId}/items': [
      FirestoreField('medicineId', 'string', required: true),
      FirestoreField('medicineName', 'string'),
      FirestoreField('quantityReceived', 'int', required: true),
      FirestoreField('batchNo', 'string'),
      FirestoreField('mfgDate', 'timestamp'),
      FirestoreField('expiryDate', 'timestamp'),
      FirestoreField('unitCostMinor', 'int (paisa)'),
    ],
    'branches/{branchId}/purchaseReturns': [
      FirestoreField('poId', 'string'),
      FirestoreField('receiptId', 'string'),
      FirestoreField('supplierId', 'string', required: true),
      FirestoreField('reason', 'string'),
      FirestoreField('status', 'string'),
      FirestoreField('amount', 'int (paisa)'),
    ],
    'branches/{branchId}/supplierPayments': [
      FirestoreField('supplierId', 'string', required: true),
      FirestoreField('amount', 'int (paisa)', required: true),
      FirestoreField('method', 'string'),
      FirestoreField('reference', 'string'),
      FirestoreField('paidBy', 'string'),
      FirestoreField(
        'paidAt',
        'timestamp',
        required: true,
        notes:
            'Added Week 3 Day 1 (D99): the SRS contract listed no '
            'payment date, but the model requires one and the '
            'statement sorts by it',
      ),
      FirestoreField(
        'allocations',
        'map[]',
        notes:
            'Added Week 3 Day 1 (D99): the FIFO allocations '
            '({ledgerEntryId, amount}) — the SRS contract listed no '
            'allocations, but the payment record must show which '
            'payables it settled (D92)',
      ),
    ],
    'suppliers/{supplierId}/ledger': [
      FirestoreField(
        'type',
        'string',
        required: true,
        notes: 'purchase / payment / return',
      ),
      FirestoreField('amount', 'int (paisa)', required: true, notes: 'Signed'),
      FirestoreField('balanceAfter', 'int (paisa)', required: true),
    ],
    'branches/{branchId}/employees': [
      FirestoreField('userId', 'string', notes: 'Nullable'),
      FirestoreField('name', 'string', required: true),
      FirestoreField('phone', 'string'),
      FirestoreField('jobTitle', 'string'),
      FirestoreField('salary', 'int (paisa)', notes: 'Nullable'),
      FirestoreField('joiningDate', 'timestamp'),
      FirestoreField('status', 'string'),
      // Extras (Week 3 Day 1, D99): the local Staff model carries
      // these and the mapper writes them so a round-trip is exact.
      // `salary` / `joiningDate` are NOT written — the model has no
      // salary field (D89: salary figures are not shown) and no
      // joining date, so they are never invented. Week 3 Day 2
      // (D102) settles where salary figures DO live: a separate
      // `salaries` payroll record per (employee, month) below — the
      // `salary` field on the employee doc stays unwritten by the
      // staff mapper and is never the source of truth.
      FirestoreField('email', 'string', notes: 'Extra: local Staff.email'),
      FirestoreField(
        'role',
        'string',
        notes: 'Extra: Day 0 StaffRole name (owner / pharmacist / counter / rider)',
      ),
      FirestoreField(
        'roleKey',
        'string',
        notes: 'Extra: SRS §5.1 role key (owner / branch_manager / …)',
      ),
    ],
    // Payroll records (Week 3 Day 2, D102): one document per
    // (employee, month) — the source of truth for salary figures.
    // The doc id is `sal-{employeeId}-{yyyy-MM}`. `isDemo` marks
    // seeded demo figures (fictional sample payroll, never real).
    'branches/{branchId}/salaries': [
      FirestoreField('employeeId', 'string', required: true),
      FirestoreField(
        'month',
        'string',
        required: true,
        notes: 'YYYY-MM, e.g. 2026-11',
      ),
      FirestoreField('baseSalaryMinor', 'int (paisa)', required: true),
      FirestoreField('allowancesMinor', 'int (paisa)'),
      FirestoreField('deductionsMinor', 'int (paisa)'),
      FirestoreField(
        'netMinor',
        'int (paisa)',
        required: true,
        notes: 'Always base + allowances − deductions',
      ),
      FirestoreField(
        'isDemo',
        'bool',
        notes: 'True for seeded demo figures (D102)',
      ),
    ],
    'branches/{branchId}/attendances': [
      FirestoreField('employeeId', 'string', required: true),
      FirestoreField('date', 'timestamp', required: true),
      FirestoreField('checkIn', 'timestamp'),
      FirestoreField('checkOut', 'timestamp'),
      FirestoreField('status', 'string'),
      FirestoreField(
        'note',
        'string',
        notes: 'Extra (Week 3 Day 1, D99): manager note on the record',
      ),
    ],
    'branches/{branchId}/shifts': [
      FirestoreField('name', 'string', required: true),
      FirestoreField('startTime', 'string'),
      FirestoreField('endTime', 'string'),
      FirestoreField('employeeIds', 'string[]'),
    ],
    'branches/{branchId}/expenses': [
      FirestoreField('categoryId', 'string'),
      FirestoreField(
        'category',
        'string',
        notes:
            'Extra (Week 3 Day 1, D99): display name of the fixed-list '
            'category; `categoryId` holds the same name until '
            'categories become documents',
      ),
      FirestoreField('amount', 'int (paisa)', required: true),
      FirestoreField('description', 'string'),
      FirestoreField('expenseDate', 'timestamp'),
      FirestoreField('createdBy', 'string'),
      FirestoreField('approvedBy', 'string'),
    ],
    'branches/{branchId}/financialTransactions': [
      FirestoreField(
        'type',
        'string',
        required: true,
        notes:
            'income / expense / supplier_payment / customer_payment / '
            'adjustment',
      ),
      FirestoreField('amount', 'int (paisa)', required: true, notes: 'Signed'),
      FirestoreField('category', 'string'),
      FirestoreField('referenceType', 'string'),
      FirestoreField('referenceId', 'string'),
      FirestoreField('createdBy', 'string'),
    ],
    'branches/{branchId}/notifications': [
      FirestoreField('userId', 'string', notes: 'Nullable = broadcast'),
      FirestoreField('type', 'string'),
      FirestoreField('title', 'string', required: true),
      FirestoreField('body', 'string'),
      FirestoreField('data', 'map'),
      FirestoreField('isRead', 'bool', required: true),
      FirestoreField(
        'channel',
        'string',
        notes: 'in_app / push / sms / whatsapp',
      ),
    ],
    'branches/{branchId}/cashDrawers': [
      FirestoreField('openedBy', 'string'),
      FirestoreField('openedAt', 'timestamp'),
      FirestoreField('closedAt', 'timestamp'),
      FirestoreField('openingBalance', 'int (paisa)'),
      FirestoreField('expectedClosing', 'int (paisa)'),
      FirestoreField('actualClosing', 'int (paisa)'),
      FirestoreField('difference', 'int (paisa)'),
      FirestoreField('status', 'string', notes: 'open / closed'),
    ],
    // Daily cashbook closings (Week 4 Day 3, D126 — new collection,
    // not in the SRS §3 list: the SRS names daily closing (FR-FIN-02)
    // but gives it no collection; `cashDrawers` is the physical
    // drawer count (expected vs actual cash), while a closing is the
    // cashbook day's snapshot — totals in/out + carried balance).
    // Append-only: one doc per (branch, day), never edited.
    'branches/{branchId}/dailyClosings': [
      FirestoreField('date', 'timestamp', required: true),
      FirestoreField('totalIncome', 'int (paisa)', required: true),
      FirestoreField('totalExpense', 'int (paisa)', required: true),
      FirestoreField('openingBalance', 'int (paisa)', required: true),
      FirestoreField('closingBalance', 'int (paisa)', required: true),
      FirestoreField('closedBy', 'string'),
      FirestoreField('closedAt', 'timestamp'),
      FirestoreField('note', 'string'),
      FirestoreField('isDemo', 'bool'),
    ],
    // Closing corrections (Week 5 Day 4, D156 — FR-FIN-06): the
    // reversing entry for a wrong closing. A correction never edits
    // its original — it is a new doc linked by `originalClosingId`
    // that re-states the day's totals in full. Append-only: a wrong
    // correction is fixed by a newer correction, never an edit.
    'branches/{branchId}/closingCorrections': [
      FirestoreField('originalClosingId', 'string', required: true),
      FirestoreField('date', 'timestamp', required: true),
      FirestoreField('correctedIncome', 'int (paisa)', required: true),
      FirestoreField('correctedExpense', 'int (paisa)', required: true),
      FirestoreField('correctedClosingBalance', 'int (paisa)', required: true),
      FirestoreField('reason', 'string', required: true),
      FirestoreField('correctedBy', 'string'),
      FirestoreField('correctedAt', 'timestamp'),
      FirestoreField('note', 'string'),
      FirestoreField('isDemo', 'bool'),
    ],
    // Cash reconciliations (Week 5 Day 4, D157 — FR-FIN-02): one
    // doc per drawer count — expected drawer vs counted cash and
    // the recorded difference. Append-only: a recount is a new doc,
    // never an edit of the previous count.
    'branches/{branchId}/cashReconciliations': [
      FirestoreField('date', 'timestamp', required: true),
      FirestoreField('expected', 'int (paisa)', required: true),
      FirestoreField('counted', 'int (paisa)', required: true),
      FirestoreField('difference', 'int (paisa)', required: true),
      FirestoreField('note', 'string'),
      FirestoreField('countedBy', 'string'),
      FirestoreField('countedAt', 'timestamp'),
      FirestoreField('isDemo', 'bool'),
    ],
    'branches/{branchId}/counters': [
      FirestoreField('value', 'int', required: true),
    ],
    // Daily rollup counters (Week 3 Day 3, D105): one doc per branch
    // per day, written by the counters rollup Function (Job 3). The
    // sequential counters above keep an int `value`; a daily rollup
    // doc carries a `value` MAP of that day's totals instead — the
    // two shapes share the collection but never the same doc id
    // (`daily-{date}` vs `invoices` / `orders` / …). `cogsMinor` /
    // `grossProfitMinor` extend the Job 3 spec (which listed only
    // sales totals + counts) so the P&L and branch comparison can
    // also read from counters; the rollup subtracts refunds from
    // `salesTotalMinor` and costs by the D81/D93 rule.
    'branches/{branchId}/counters/daily-{date}': [
      FirestoreField(
        'value',
        'map',
        required: true,
        notes:
            '{salesTotalMinor, salesCount, ordersCount, cogsMinor, '
            'grossProfitMinor} — all int paisa / counts for the day',
      ),
      FirestoreField(
        'date',
        'string',
        required: true,
        notes: 'yyyy-MM-dd, matches the doc id',
      ),
      FirestoreField('branchId', 'string', required: true),
      FirestoreField('computedAt', 'timestamp'),
      FirestoreField(
        'source',
        'string',
        notes: "'rollup' — written by the counters rollup Function",
      ),
    ],
    'auditLogs': [
      FirestoreField('userId', 'string', required: true),
      FirestoreField('action', 'string', required: true),
      FirestoreField('entityType', 'string', required: true),
      FirestoreField('entityId', 'string', required: true),
      FirestoreField('oldValues', 'map'),
      FirestoreField('newValues', 'map'),
      FirestoreField('ipAddress', 'string'),
    ],
  };

  /// Validates that [doc] carries the required fields for
  /// [collectionPattern] (plus the common fields). Returns the list of
  /// problems; empty = valid. Used by tests and by the export/import
  /// validator — the Firestore rules draft enforces the same required
  /// fields server-side.
  static List<String> validateDocument(
    String collectionPattern,
    Map<String, dynamic> doc,
  ) {
    final errors = <String>[];
    final fields = fieldsByCollection[collectionPattern];
    if (fields == null) {
      return ['Unknown collection pattern "$collectionPattern".'];
    }
    for (final field in fields) {
      if (field.required && !doc.containsKey(field.name)) {
        errors.add('Missing required field "${field.name}".');
      }
    }
    for (final field in commonFields) {
      if (field.required && !doc.containsKey(field.name)) {
        errors.add('Missing common field "${field.name}".');
      }
    }
    return errors;
  }
}
