import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/repositories.dart';
import 'auth_repository.dart';
import 'firestore_repositories.dart';
import 'firestore_schema.dart';
import 'firestore_transport.dart';
import 'prescription_storage.dart';
import 'report_counters.dart';

/// Repository factory + backend switch (Week 2 Day 3, D75).
///
/// Every repository the app uses is built by
/// [createRepositoryBundle]. The app defaults to the **mock** bundle
/// (same in-memory data as before — zero config, the app works
/// exactly as now). The **Firestore** bundle is built only when the
/// Firebase project exists: it needs a [FirestoreTransport] (backed
/// by `FirebaseFirestore`), and optionally Firebase Auth + Storage
/// for the real auth repository and photo uploader.
///
/// Switching is a provider override — nothing else changes:
///
/// ```dart
/// ProviderScope(
///   overrides: [
///     repositoryBundleProvider.overrideWithValue(
///       createRepositoryBundle(
///         kind: BackendKind.firestore,
///         transport: FirebaseFirestoreTransport(),
///         firebaseAuth: FirebaseAuth.instance,
///         firebaseStorage: FirebaseStorage.instance,
///       ),
///     ),
///   ],
///   child: const PharmaDeskApp(),
/// )
/// ```
///
/// There is deliberately no in-app toggle and no automatic
/// Firebase initialisation: constructing the Firestore bundle
/// without a transport throws a [StateError] with the reason, and
/// `FirebaseFirestore.instance` itself throws until
/// `Firebase.initializeApp()` has run (D13 — project + billing are
/// Dazy-only). The switch happens once, in the Firebase-wiring
/// chunk, not per screen.

enum BackendKind { mock, firestore }

/// One built set of repositories + auth + photo upload.
class RepositoryBundle {
  const RepositoryBundle({
    required this.kind,
    required this.medicines,
    required this.orders,
    required this.inventory,
    required this.customers,
    required this.sales,
    required this.saleReturns,
    required this.suppliers,
    required this.prescriptions,
    required this.purchaseOrders,
    required this.riders,
    required this.stockTransfers,
    required this.stockAdjustments,
    required this.branches,
    required this.staff,
    required this.attendance,
    required this.shifts,
    required this.expenses,
    required this.financialTransactions,
    required this.supplierPayments,
    required this.goodsReceipts,
    required this.salary,
    required this.reportCounters,
    required this.dailyClosings,
    required this.closingCorrections,
    required this.cashReconciliations,
    required this.auth,
    required this.photoUploader,
  });

  final BackendKind kind;
  final MedicineRepository medicines;
  final OrderRepository orders;
  final InventoryRepository inventory;
  final CustomerRepository customers;
  final SaleRepository sales;
  final SaleReturnRepository saleReturns;
  final SupplierRepository suppliers;
  final PrescriptionRepository prescriptions;
  final PurchaseOrderRepository purchaseOrders;
  final RiderRepository riders;

  /// Week 4 Day 2 (D118): stock transfers join the bundle the same
  /// way as the Day 3 repos (D101 pattern).
  final StockTransferRepository stockTransfers;

  /// Week 5 Day 1 (D146): the adjustment approval queue joins the
  /// bundle the same way.
  final StockAdjustmentRequestRepository stockAdjustments;

  /// Week 5 Day 2 (D148): the branch directory joins the bundle the
  /// same way — the mock is seeded from the demo branches, the
  /// Firestore implementation reads `branches/{id}`.
  final BranchRepository branches;

  /// Week 3 Day 1 (D101): the six Day 5 repos join the bundle —
  /// Firestore implementations behind the same interfaces, mock
  /// by default like the Day 3 repos.
  final StaffRepository staff;
  final AttendanceRepository attendance;
  final ShiftRepository shifts;
  final ExpenseRepository expenses;
  final FinancialTransactionRepository financialTransactions;
  final SupplierPaymentRepository supplierPayments;

  /// Week 3 Day 2 (D102/D103): goods receipts + salary records
  /// join the bundle the same way.
  final GoodsReceiptRepository goodsReceipts;
  final SalaryRepository salary;

  /// Week 3 Day 3 (D105/D106): daily report counters join the
  /// bundle the same way — the mock computes them from the seeded
  /// demo data, the Firestore implementation reads the rollup
  /// Function's output docs.
  final ReportCounterRepository reportCounters;

  /// Week 4 Day 3 (D126): daily cashbook closings join the bundle
  /// the same way.
  final DailyClosingRepository dailyClosings;

  /// Week 5 Day 4 (D156/D157): closing corrections + cash
  /// reconciliations join the bundle the same way.
  final ClosingCorrectionRepository closingCorrections;
  final CashReconciliationRepository cashReconciliations;

  final AuthRepository auth;
  final PrescriptionPhotoUploader photoUploader;
}

/// Builds a repository bundle for [kind].
///
/// - [BackendKind.mock] (default): the Week 1 mocks + mock auth +
///   the local photo uploader. No Firebase needed.
/// - [BackendKind.firestore]: the Firestore repositories over
///   [transport] (required — throws [StateError] when missing),
///   Firebase Auth when [firebaseAuth] is given (else the mock auth
///   stays, so the demo login keeps working), and the Firebase photo
///   uploader when [firebaseStorage] is given (else the local one).
RepositoryBundle createRepositoryBundle({
  BackendKind kind = BackendKind.mock,
  FirestoreTransport? transport,
  FirebaseAuth? firebaseAuth,
  FirebaseStorage? firebaseStorage,
  String organizationId = demoOrganizationId,
}) {
  if (kind == BackendKind.firestore) {
    final firestoreTransport =
        transport ??
        (throw StateError(
          'Cannot build the Firestore bundle: no FirestoreTransport '
          'was given. The Firebase project does not exist yet (D13) — '
          'create it, run the Firebase setup, then pass a '
          'FirebaseFirestoreTransport here.',
        ));
    return RepositoryBundle(
      kind: kind,
      medicines: FirestoreMedicineRepository(
        transport: firestoreTransport,
        organizationId: organizationId,
      ),
      orders: FirestoreOrderRepository(
        transport: firestoreTransport,
        organizationId: organizationId,
      ),
      inventory: FirestoreInventoryRepository(
        transport: firestoreTransport,
        organizationId: organizationId,
      ),
      customers: FirestoreCustomerRepository(
        transport: firestoreTransport,
        organizationId: organizationId,
      ),
      sales: FirestoreSaleRepository(
        transport: firestoreTransport,
        organizationId: organizationId,
      ),
      saleReturns: FirestoreSaleReturnRepository(
        transport: firestoreTransport,
        organizationId: organizationId,
      ),
      suppliers: FirestoreSupplierRepository(
        transport: firestoreTransport,
        organizationId: organizationId,
      ),
      prescriptions: FirestorePrescriptionRepository(
        transport: firestoreTransport,
        organizationId: organizationId,
      ),
      purchaseOrders: FirestorePurchaseOrderRepository(
        transport: firestoreTransport,
        organizationId: organizationId,
      ),
      riders: FirestoreRiderRepository(
        transport: firestoreTransport,
        organizationId: organizationId,
      ),
      stockTransfers: FirestoreStockTransferRepository(
        transport: firestoreTransport,
        organizationId: organizationId,
      ),
      stockAdjustments: FirestoreStockAdjustmentRequestRepository(
        transport: firestoreTransport,
        organizationId: organizationId,
      ),
      branches: FirestoreBranchRepository(
        transport: firestoreTransport,
        organizationId: organizationId,
      ),
      staff: FirestoreStaffRepository(
        transport: firestoreTransport,
        organizationId: organizationId,
      ),
      attendance: FirestoreAttendanceRepository(
        transport: firestoreTransport,
        organizationId: organizationId,
      ),
      shifts: FirestoreShiftRepository(
        transport: firestoreTransport,
        organizationId: organizationId,
      ),
      expenses: FirestoreExpenseRepository(
        transport: firestoreTransport,
        organizationId: organizationId,
      ),
      financialTransactions: FirestoreFinancialTransactionRepository(
        transport: firestoreTransport,
        organizationId: organizationId,
      ),
      supplierPayments: FirestoreSupplierPaymentRepository(
        transport: firestoreTransport,
        organizationId: organizationId,
      ),
      goodsReceipts: FirestoreGoodsReceiptRepository(
        transport: firestoreTransport,
        organizationId: organizationId,
      ),
      salary: FirestoreSalaryRepository(
        transport: firestoreTransport,
        organizationId: organizationId,
      ),
      reportCounters: FirestoreReportCounterRepository(
        transport: firestoreTransport,
        organizationId: organizationId,
      ),
      dailyClosings: FirestoreDailyClosingRepository(
        transport: firestoreTransport,
        organizationId: organizationId,
      ),
      closingCorrections: FirestoreClosingCorrectionRepository(
        transport: firestoreTransport,
        organizationId: organizationId,
      ),
      cashReconciliations: FirestoreCashReconciliationRepository(
        transport: firestoreTransport,
        organizationId: organizationId,
      ),
      auth: firebaseAuth == null
          ? MockAuthRepository()
          : FirebaseAuthRepository(firebaseAuth: firebaseAuth),
      photoUploader: firebaseStorage == null
          ? LocalPrescriptionPhotoUploader()
          : FirebasePrescriptionPhotoUploader(storage: firebaseStorage),
    );
  }
  // The mock counter repository reads from the same mock repos the
  // live reports read, so its figures are derived from the seeded
  // demo data (D105) — one shared instance of each repo feeds both
  // the bundle and the counter computation.
  final mockOrders = MockOrderRepository();
  final mockSales = MockSaleRepository();
  final mockSaleReturns = MockSaleReturnRepository();
  final mockInventory = MockInventoryRepository();
  final mockMedicines = MockMedicineRepository();
  return RepositoryBundle(
    kind: kind,
    medicines: mockMedicines,
    orders: mockOrders,
    inventory: mockInventory,
    customers: MockCustomerRepository(),
    sales: mockSales,
    saleReturns: mockSaleReturns,
    suppliers: MockSupplierRepository(),
    prescriptions: MockPrescriptionRepository(),
    purchaseOrders: MockPurchaseOrderRepository(),
    riders: MockRiderRepository(),
    stockTransfers: MockStockTransferRepository(),
    stockAdjustments: MockStockAdjustmentRequestRepository(),
    branches: MockBranchRepository(),
    staff: MockStaffRepository(),
    attendance: MockAttendanceRepository(),
    shifts: MockShiftRepository(),
    expenses: MockExpenseRepository(),
    financialTransactions: MockFinancialTransactionRepository(),
    supplierPayments: MockSupplierPaymentRepository(),
    goodsReceipts: MockGoodsReceiptRepository(),
    salary: MockSalaryRepository(),
    reportCounters: MockReportCounterRepository(
      orders: mockOrders,
      sales: mockSales,
      returns: mockSaleReturns,
      inventory: mockInventory,
      medicines: mockMedicines,
    ),
    dailyClosings: MockDailyClosingRepository(),
    closingCorrections: MockClosingCorrectionRepository(),
    cashReconciliations: MockCashReconciliationRepository(),
    auth: MockAuthRepository(),
    photoUploader: LocalPrescriptionPhotoUploader(),
  );
}

/// The repository bundle for the app: the mock bundle until the
/// Firebase project exists. Override this provider (see above) to
/// switch the whole app to Firestore — every repository provider
/// below reads from it, so screens never change.
final repositoryBundleProvider = Provider<RepositoryBundle>(
  (ref) => createRepositoryBundle(kind: BackendKind.mock),
);
