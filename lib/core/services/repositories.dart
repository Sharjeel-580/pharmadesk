import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/customer.dart';
import '../../models/customer_ledger.dart';
import '../../models/inventory_item.dart';
import '../../models/medicine.dart';
import '../../models/order.dart';
import '../../models/prescription.dart';
import '../../models/purchase_order.dart';
import '../../models/rider.dart';
import '../../models/sale.dart';
import '../../models/supplier.dart';
import '../../models/supplier_ledger.dart';
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
}

abstract class CustomerRepository {
  Future<List<Customer>> getCustomers();
  Future<Customer?> getById(String id);

  /// Saves a new customer (Day 6). The repository assigns the id.
  /// Throws [ArgumentError] when another customer already has the
  /// same phone number (digits compared, formatting ignored).
  Future<Customer> createCustomer(Customer customer);

  /// Khata (credit ledger) entries for one customer, oldest first.
  Future<List<LedgerEntry>> getLedgerEntries(String customerId);

  /// Appends one ledger entry (Day 6). The repository assigns the id
  /// and computes [LedgerEntry.balanceAfterMinor] from the customer's
  /// current outstanding, so the statement never drifts. The ledger
  /// is append-only — entries are never edited or deleted.
  Future<LedgerEntry> addLedgerEntry(LedgerEntry entry);
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

  /// Saves a manually created prescription (Day 7, new-prescription
  /// form). The repository assigns the id; the record starts Pending.
  Future<Prescription> createPrescription(Prescription prescription);
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
}

abstract class RiderRepository {
  Future<List<Rider>> getRiders();
  Future<Rider?> getById(String id);
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
    _orders[index] = old.copyWith(
      status: status,
      updatedAt: DateTime.now(),
    );
  }

  @override
  Future<Order> createOrder(Order order) async {
    final branchCode = order.branchId == 'branch-dha-main'
        ? 'dha'
        : 'glb';
    final sequence = 1000 + _orders.length + 1;
    final saved = order.copyWith(
      id: 'ord-$branchCode-$sequence',
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
      List.unmodifiable(
        _scoped(branchId).where((item) => item.isLowStock),
      );

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
    final updated = old.copyWith(
      quantity: nextQty,
      updatedAt: DateTime.now(),
    );
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
}

class MockCustomerRepository implements CustomerRepository {
  /// Mutable copies of the seed customers and ledger: adding a
  /// customer or a khata entry rewrites entries in place, exactly
  /// like a Firestore write would.
  final List<Customer> _customers = List.of(demoCustomers);
  final List<LedgerEntry> _ledger = generateDemoLedgerEntries();

  @override
  Future<List<Customer>> getCustomers() async =>
      List.unmodifiable(_customers);

  @override
  Future<Customer?> getById(String id) async {
    for (final customer in _customers) {
      if (customer.id == id) return customer;
    }
    return null;
  }

  @override
  Future<Customer> createCustomer(Customer customer) async {
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
    return List.unmodifiable(
      _sales.where((sale) => sale.branchId == branchId),
    );
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
}

class MockSupplierRepository implements SupplierRepository {
  /// Mutable copies of the seed suppliers and ledger: adding a
  /// supplier or a ledger entry rewrites entries in place, exactly
  /// like a Firestore write would.
  final List<Supplier> _suppliers = List.of(demoSuppliers);
  final List<SupplierLedgerEntry> _ledger =
      generateDemoSupplierLedgerEntries();

  @override
  Future<List<Supplier>> getSuppliers() async =>
      List.unmodifiable(_suppliers);

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
    final created = supplier.copyWith(
      id: 'sup-${_suppliers.length + 1}',
    );
    _suppliers.add(created);
    return created;
  }

  @override
  Future<void> updateSupplier(Supplier supplier) async {
    final index = _suppliers.indexWhere((s) => s.id == supplier.id);
    if (index == -1) return;
    _suppliers[index] = supplier;
  }

  @override
  Future<List<SupplierLedgerEntry>> getLedgerEntries(
    String supplierId,
  ) async => List.unmodifiable(
    _ledger.where((entry) => entry.supplierId == supplierId),
  );

  @override
  Future<SupplierLedgerEntry> addLedgerEntry(
    SupplierLedgerEntry entry,
  ) async {
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

  static String _phoneDigits(String phone) =>
      phone.replaceAll(RegExp(r'[^0-9]'), '');
}

class MockRiderRepository implements RiderRepository {
  @override
  Future<List<Rider>> getRiders() async => List.unmodifiable(demoRiders);

  @override
  Future<Rider?> getById(String id) async {
    for (final rider in demoRiders) {
      if (rider.id == id) return rider;
    }
    return null;
  }
}

class MockPrescriptionRepository implements PrescriptionRepository {
  final List<Prescription> _prescriptions = generateDemoPrescriptions();

  List<Prescription> _scoped(String? branchId) {
    // Prescriptions carry no branchId on the Day 0 model; the seed
    // encodes the branch in the id prefix (`rx-dha-…` / `rx-glb-…`).
    // Week 2 adds a real branchId field when the model is migrated.
    if (branchId == null) return _prescriptions;
    final prefix = branchId == 'branch-dha-main' ? 'rx-dha-' : 'rx-glb-';
    return _prescriptions
        .where((rx) => rx.id.startsWith(prefix))
        .toList();
  }

  @override
  Future<List<Prescription>> getPrescriptions({String? branchId}) async =>
      List.unmodifiable(_scoped(branchId));

  @override
  Future<List<Prescription>> getPending({String? branchId}) async =>
      List.unmodifiable(
        _scoped(
          branchId,
        ).where((rx) => rx.status == PrescriptionStatus.pending),
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
  Future<Prescription> createPrescription(Prescription prescription) async {
    // New records join the active branch by id prefix (see _scoped):
    // the caller passes an id of '' and the branch in the id it
    // builds; here we assign the next sequence for that branch.
    final isDha = prescription.id.startsWith('rx-dha-');
    final prefix = isDha ? 'rx-dha-' : 'rx-glb-';
    final count = _prescriptions
        .where((rx) => rx.id.startsWith(prefix))
        .length;
    final created = prescription.copyWith(
      id: '$prefix${count + 1}',
      status: PrescriptionStatus.pending,
      createdAt: DateTime.now(),
    );
    _prescriptions.add(created);
    return created;
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
    final branchCode = order.branchId == 'branch-dha-main' ? 'DHA' : 'GLB';
    final sequence = 1000 + _orders.length + 1;
    final saved = order.copyWith(
      id: 'po-$branchCode-$sequence',
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
}

/// Default providers — mock implementations until the Firebase data layer
/// lands in Week 2. Screens inject these providers, never the mocks.
final medicineRepositoryProvider = Provider<MedicineRepository>(
  (ref) => MockMedicineRepository(),
);

final orderRepositoryProvider = Provider<OrderRepository>(
  (ref) => MockOrderRepository(),
);

final inventoryRepositoryProvider = Provider<InventoryRepository>(
  (ref) => MockInventoryRepository(),
);

final customerRepositoryProvider = Provider<CustomerRepository>(
  (ref) => MockCustomerRepository(),
);

final saleRepositoryProvider = Provider<SaleRepository>(
  (ref) => MockSaleRepository(),
);

final supplierRepositoryProvider = Provider<SupplierRepository>(
  (ref) => MockSupplierRepository(),
);

final prescriptionRepositoryProvider = Provider<PrescriptionRepository>(
  (ref) => MockPrescriptionRepository(),
);

final purchaseOrderRepositoryProvider = Provider<PurchaseOrderRepository>(
  (ref) => MockPurchaseOrderRepository(),
);

final riderRepositoryProvider = Provider<RiderRepository>(
  (ref) => MockRiderRepository(),
);
