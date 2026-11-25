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

  static String saleReturnsPath(String branchId) =>
      branchCollection(branchId, saleReturns);

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
      FirestoreField('code', 'string', required: true),
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
      FirestoreField('rack', 'string'),
      FirestoreField('shelf', 'string'),
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
      FirestoreField('fromBranchId', 'string', required: true),
      FirestoreField('toBranchId', 'string', required: true),
      FirestoreField(
        'status',
        'string',
        notes: 'requested / approved / dispatched / received / cancelled',
      ),
      FirestoreField('requestedBy', 'string'),
      FirestoreField('approvedBy', 'string'),
    ],
    'branches/{branchId}/stockCounts': [
      FirestoreField('status', 'string', notes: 'open / submitted / approved'),
      FirestoreField('countedBy', 'string'),
      FirestoreField('approvedBy', 'string'),
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
    ],
    'branches/{branchId}/attendances': [
      FirestoreField('employeeId', 'string', required: true),
      FirestoreField('date', 'timestamp', required: true),
      FirestoreField('checkIn', 'timestamp'),
      FirestoreField('checkOut', 'timestamp'),
      FirestoreField('status', 'string'),
    ],
    'branches/{branchId}/shifts': [
      FirestoreField('name', 'string', required: true),
      FirestoreField('startTime', 'string'),
      FirestoreField('endTime', 'string'),
      FirestoreField('employeeIds', 'string[]'),
    ],
    'branches/{branchId}/expenses': [
      FirestoreField('categoryId', 'string'),
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
    'branches/{branchId}/counters': [
      FirestoreField('value', 'int', required: true),
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
