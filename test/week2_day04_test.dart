// Week 2 Day 4 tests — advanced POS + owner dashboard.
//
// Barcode-scan lookup (incl. the expired-batch refusal), parked-sale
// park/resume/discard, return maths + restock + khata adjustment +
// status transitions, branch-comparison computations, permission
// gating on returns, printer settings + service, Firestore
// sale-status / sale-return mappers + the Firestore returns
// repository (fake transport — there is no Firebase project yet,
// D13), and the widget flows (POS scan field, hold/resume, return
// end-to-end, owner dashboard live KPIs + branch comparison,
// printer test print).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmadesk/app/pharmadesk_app.dart';
import 'package:pharmadesk/core/data/auth_repository.dart';
import 'package:pharmadesk/core/data/firestore_mappers.dart';
import 'package:pharmadesk/core/data/firestore_repositories.dart';
import 'package:pharmadesk/core/data/firestore_schema.dart';
import 'package:pharmadesk/core/data/firestore_transport.dart';
import 'package:pharmadesk/core/data/inventory_engine.dart'
    show WriteOperation, WriteOperationKind;
import 'package:pharmadesk/core/services/branch_context.dart';
import 'package:pharmadesk/core/services/demo_seed_data.dart';
import 'package:pharmadesk/core/services/repositories.dart';
import 'package:pharmadesk/core/widgets/buttons.dart';
import 'package:pharmadesk/features/authentication/auth_state.dart';
import 'package:pharmadesk/features/billing/barcode_scanner.dart';
import 'package:pharmadesk/features/billing/billing_logic.dart';
import 'package:pharmadesk/features/billing/billing_provider.dart';
import 'package:pharmadesk/features/billing/parked_sales.dart';
import 'package:pharmadesk/features/billing/receipt_printer.dart';
import 'package:pharmadesk/features/billing/return_form_screen.dart';
import 'package:pharmadesk/features/billing/returns_logic.dart';
import 'package:pharmadesk/features/billing/returns_provider.dart';
import 'package:pharmadesk/features/dashboard/dashboard_screen.dart';
import 'package:pharmadesk/features/dashboard/owner_dashboard_data.dart';
import 'package:pharmadesk/models/customer_ledger.dart';
import 'package:pharmadesk/models/inventory_item.dart';
import 'package:pharmadesk/models/medicine.dart';
import 'package:pharmadesk/models/prescription.dart';
import 'package:pharmadesk/models/purchase_order.dart';
import 'package:pharmadesk/models/sale.dart';
import 'package:pharmadesk/models/sale_return.dart';

import 'test_helpers.dart';

const _dha = 'branch-dha-main';
const _glb = 'branch-demo-gulberg';

AppUser _userFor(String roleKey, [List<String> branches = const [_dha]]) {
  return AppUser(
    uid: 'u-$roleKey',
    email: '$roleKey@fazaldin.pk',
    displayName: roleKey,
    orgId: demoOrganizationId,
    branchIds: branches,
    roleKey: roleKey,
  );
}

Medicine _medicine({
  String id = 'med-1',
  String name = 'Panadol Extra',
  String? barcode = '8901000000001',
  int priceMinor = 12000,
}) {
  return Medicine(
    id: id,
    name: name,
    brand: 'GSK',
    categoryId: 'cat-pain',
    strength: '500mg',
    packSize: '20 tablets',
    price: priceMinor / 100,
    barcode: barcode,
  );
}

InventoryItem _batch({
  String id = 'b1',
  String medicineId = 'med-1',
  String branchId = _dha,
  int quantity = 10,
  int costMinor = 5000,
  DateTime? expiryDate,
  BatchStatus status = BatchStatus.available,
}) {
  return InventoryItem(
    id: id,
    medicineId: medicineId,
    branchId: branchId,
    quantity: quantity,
    lowStockThreshold: 10,
    batchNo: 'B-$id',
    expiryDate: expiryDate ?? DateTime.now().add(const Duration(days: 365)),
    mfgDate: DateTime.now().subtract(const Duration(days: 30)),
    costMinor: costMinor,
    status: status,
  );
}

Sale _sale({
  String id = 'sale-1',
  String branchId = _dha,
  String invoiceNumber = 'INV-DHA-1001',
  List<SaleItem> items = const [],
  String? customerId,
  SalePaymentMethod paymentMethod = SalePaymentMethod.cash,
  int totalMinor = 24000,
  SaleStatus status = SaleStatus.completed,
}) {
  return Sale(
    id: id,
    invoiceNumber: invoiceNumber,
    branchId: branchId,
    customerId: customerId,
    cashierName: 'Cashier',
    items: items,
    subtotalMinor: totalMinor,
    totalMinor: totalMinor,
    paymentMethod: paymentMethod,
    idempotencyKey: 'key-$id',
    status: status,
    createdAt: DateTime.now(),
  );
}

SaleItem _saleItem({
  String medicineId = 'med-1',
  String medicineName = 'Panadol Extra',
  int quantity = 2,
  int unitPriceMinor = 12000,
  int lineDiscountMinor = 0,
  String? batchId = 'b1',
}) {
  return SaleItem(
    medicineId: medicineId,
    medicineName: medicineName,
    quantity: quantity,
    unitPriceMinor: unitPriceMinor,
    lineDiscountMinor: lineDiscountMinor,
    batchId: batchId,
    batchNo: 'B-$batchId',
  );
}

/// In-memory [FirestoreTransport] for the returns repository tests
/// (same shape as the Day 3 fake, trimmed to what these tests use).
class _FakeTransport implements FirestoreTransport {
  final Map<String, Map<String, dynamic>> docs = {};
  int _sequence = 0;

  @override
  Future<Map<String, dynamic>?> getDocument(String path) async =>
      docs[path];

  @override
  Future<List<FirestoreDocument>> queryCollection(
    String collectionPath, {
    Map<String, Object?> whereEquals = const {},
    String? orderBy,
    bool descending = false,
    int? limit,
    String? startAfterId,
  }) async {
    final prefix = '$collectionPath/';
    final found = <FirestoreDocument>[];
    for (final entry in docs.entries) {
      if (!entry.key.startsWith(prefix)) continue;
      final id = entry.key.substring(prefix.length);
      if (id.contains('/')) continue;
      var matches = true;
      for (final filter in whereEquals.entries) {
        if (entry.value[filter.key] != filter.value) matches = false;
      }
      if (matches) found.add(FirestoreDocument(id: id, data: entry.value));
    }
    found.sort((a, b) => a.id.compareTo(b.id));
    var page = found;
    if (startAfterId != null) {
      final index = page.indexWhere((doc) => doc.id == startAfterId);
      page = index == -1 ? [] : page.sublist(index + 1);
    }
    if (limit != null && page.length > limit) page = page.sublist(0, limit);
    return page;
  }

  @override
  Future<void> setDocument(
    String path,
    Map<String, dynamic> data, {
    bool merge = false,
  }) async {
    if (merge && docs.containsKey(path)) {
      docs[path] = {...docs[path]!, ...data};
    } else {
      docs[path] = Map.of(data);
    }
  }

  @override
  Future<void> updateDocument(String path, Map<String, dynamic> data) async {
    final existing = docs[path];
    if (existing == null) throw ArgumentError('No document at $path');
    docs[path] = {...existing, ...data};
  }

  @override
  Future<String> addDocument(
    String collectionPath,
    Map<String, dynamic> data,
  ) async {
    final id = 'auto-${++_sequence}';
    docs['$collectionPath/$id'] = Map.of(data);
    return id;
  }

  @override
  Future<void> runBatchedWrites(List<WriteOperation> operations) async {
    for (final op in operations) {
      final data = op.data ?? const {};
      switch (op.kind) {
        case WriteOperationKind.set:
          await setDocument(op.path, data);
        case WriteOperationKind.update:
          await updateDocument(op.path, data);
        case WriteOperationKind.delete:
          docs.remove(op.path);
      }
    }
  }

  @override
  Future<T> runTransaction<T>(
    Future<T> Function(FirestoreTransaction tx) action,
  ) async {
    return action(_FakeTransaction(this));
  }

  @override
  String newDocumentId(String collectionPath) => 'new-${++_sequence}';
}

class _FakeTransaction implements FirestoreTransaction {
  _FakeTransaction(this.transport);

  final _FakeTransport transport;

  @override
  Future<Map<String, dynamic>?> get(String path) =>
      transport.getDocument(path);

  @override
  void set(String path, Map<String, dynamic> data, {bool merge = false}) {
    if (merge && transport.docs.containsKey(path)) {
      transport.docs[path] = {...transport.docs[path]!, ...data};
    } else {
      transport.docs[path] = Map.of(data);
    }
  }

  @override
  void update(String path, Map<String, dynamic> data) {
    final existing = transport.docs[path];
    if (existing == null) throw ArgumentError('No document at $path');
    transport.docs[path] = {...existing, ...data};
  }
}

/// A fake printer that captures what would be printed (widget test).
class _FakePrinter implements ReceiptPrinter {
  String? lastPrinted;
  var drawerOpened = false;

  @override
  PrinterStatus get status =>
      const PrinterStatus(available: true, message: 'Fake — ready');

  @override
  Future<PrinterResult> printText(String text) async {
    lastPrinted = text;
    return const PrinterResult(success: true, message: 'Printed (fake).');
  }

  @override
  Future<PrinterResult> openCashDrawer() async {
    drawerOpened = true;
    return const PrinterResult(
      success: true,
      message: 'Drawer opened (fake).',
    );
  }
}

void main() {
  group('Barcode scan lookup (pure)', () {
    final medicines = [_medicine()];
    final batches = {
      'med-1': [_batch()],
    };

    test('finds a medicine by barcode and picks the FEFO batch', () {
      final result = scanBarcode(
        medicines: medicines,
        batchesByMedicine: batches,
        code: '8901000000001',
      );
      expect(result.outcome, BarcodeScanOutcome.found);
      expect(result.medicine?.id, 'med-1');
      expect(result.fefoBatch?.id, 'b1');
      expect(result.sellableQuantity, 10);
    });

    test('unknown barcode is notFound', () {
      final result = scanBarcode(
        medicines: medicines,
        batchesByMedicine: batches,
        code: '9999999999999',
      );
      expect(result.outcome, BarcodeScanOutcome.notFound);
      expect(result.medicine, isNull);
    });

    test('expired-only batches are refused, never added', () {
      final expired = {
        'med-1': [
          _batch(
            expiryDate: DateTime.now().subtract(const Duration(days: 1)),
          ),
        ],
      };
      final result = scanBarcode(
        medicines: medicines,
        batchesByMedicine: expired,
        code: '8901000000001',
      );
      expect(result.outcome, BarcodeScanOutcome.notSellable);
      expect(result.medicine?.id, 'med-1');
      expect(result.fefoBatch, isNull);
    });

    test('quarantined batch is refused even with stock and future expiry', () {
      final quarantined = {
        'med-1': [_batch(status: BatchStatus.quarantined)],
      };
      final result = scanBarcode(
        medicines: medicines,
        batchesByMedicine: quarantined,
        code: '8901000000001',
      );
      expect(result.outcome, BarcodeScanOutcome.notSellable);
    });

    test('out-of-stock batches are refused', () {
      final empty = {
        'med-1': [_batch(quantity: 0)],
      };
      final result = scanBarcode(
        medicines: medicines,
        batchesByMedicine: empty,
        code: '8901000000001',
      );
      expect(result.outcome, BarcodeScanOutcome.notSellable);
    });

    test('findMedicineByBarcode trims and rejects empty codes', () {
      expect(
        findMedicineByBarcode(medicines, '  8901000000001  ')?.id,
        'med-1',
      );
      expect(findMedicineByBarcode(medicines, '   '), isNull);
    });

    test('hardware scanner stub explains the integration point', () {
      expect(
        () => const HardwareBarcodeScanner().scan('8901000000001'),
        throwsUnsupportedError,
      );
    });

    test('simulated scanner looks up through the repositories', () async {
      final scanner = SimulatedBarcodeScanner(
        medicines: MockMedicineRepository(),
        inventory: MockInventoryRepository(),
      );
      final found = await scanner.scan('8901000000001');
      expect(found.outcome, BarcodeScanOutcome.found);
      expect(found.medicine?.id, 'med-panadol-extra');
      final missing = await scanner.scan('0000000000000');
      expect(missing.outcome, BarcodeScanOutcome.notFound);
    });
  });

  group('Parked sales (session)', () {
    test('park with an empty cart returns null', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final parked = container.read(parkedSalesProvider.notifier).park(
        branchId: _dha,
        lines: const [],
        cashierName: 'Cashier',
      );
      expect(parked, isNull);
      expect(container.read(parkedSalesProvider), isEmpty);
    });

    test('park / resume / discard round-trips lines, customer, notes', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(parkedSalesProvider.notifier);
      final lines = [
        CartLine(
          medicineId: 'med-1',
          medicineName: 'Panadol Extra',
          unitPriceMinor: 12000,
          quantity: 2,
        ),
      ];
      final parked = notifier.park(
        branchId: _dha,
        lines: lines,
        customerId: 'cust-1',
        notes: 'Coming back in an hour',
        cashierName: 'Cashier',
      );
      expect(parked, isNotNull);
      expect(container.read(parkedSalesProvider), hasLength(1));
      expect(
        container.read(branchParkedSalesProvider(_glb)),
        isEmpty,
        reason: 'parked sales are branch-scoped',
      );
      final resumed = notifier.resume(parked!.id);
      expect(resumed, isNotNull);
      expect(resumed!.lines.single.quantity, 2);
      expect(resumed.customerId, 'cust-1');
      expect(resumed.notes, 'Coming back in an hour');
      expect(container.read(parkedSalesProvider), isEmpty);
      expect(notifier.resume(parked.id), isNull);
      final parkedAgain = notifier.park(
        branchId: _dha,
        lines: lines,
        cashierName: 'Cashier',
      );
      notifier.discard(parkedAgain!.id);
      expect(container.read(parkedSalesProvider), isEmpty);
    });
  });

  group('Return maths (pure)', () {
    final sale = _sale(items: [_saleItem()]);
    const key = 'med-1|b1';

    test('chunk refund pro-rates the line discount', () {
      final discounted = _saleItem(
        quantity: 4,
        unitPriceMinor: 10000,
        lineDiscountMinor: 4000,
      );
      // 1 of 4 units: 10000 − 4000×1/4 = 9000.
      expect(chunkRefundMinor(item: discounted, quantity: 1), 9000);
      // All 4: the full discount comes back.
      expect(chunkRefundMinor(item: discounted, quantity: 4), 36000);
      expect(chunkRefundMinor(item: discounted, quantity: 0), 0);
    });

    test('computeRefund sums the returned chunks', () {
      expect(
        computeRefundMinor(sale: sale, quantities: {key: 1}),
        12000,
      );
      expect(
        computeRefundMinor(sale: sale, quantities: {key: 2}),
        24000,
      );
    });

    test('validateReturn requires a reason and a quantity', () {
      expect(
        validateReturn(
          sale: sale,
          existingReturns: const [],
          quantities: {key: 1},
          reason: '   ',
        ),
        contains('A reason for the return is required.'),
      );
      expect(
        validateReturn(
          sale: sale,
          existingReturns: const [],
          quantities: {key: 0},
          reason: 'Wrong medicine',
        ),
        contains('Pick at least one item to return.'),
      );
    });

    test('validateReturn refuses more than still returnable', () {
      final first = SaleReturn(
        id: 'ret-1',
        branchId: _dha,
        saleId: 'sale-1',
        invoiceNumber: 'INV-DHA-1001',
        items: [
          SaleReturnItem(
            medicineId: 'med-1',
            medicineName: 'Panadol Extra',
            quantity: 1,
            unitPriceMinor: 12000,
            refundMinor: 12000,
            saleBatchId: 'b1',
          ),
        ],
        reason: 'Damaged pack',
        refundedAmountMinor: 12000,
        approvedBy: 'u-owner',
        approvedByName: 'owner',
      );
      expect(
        validateReturn(
          sale: sale,
          existingReturns: [first],
          quantities: {key: 2},
          reason: 'Wrong medicine',
        ),
        isNotEmpty,
        reason: 'only 1 of the 2 units is still returnable',
      );
      expect(
        validateReturn(
          sale: sale,
          existingReturns: [first],
          quantities: {key: 1},
          reason: 'Wrong medicine',
        ),
        isEmpty,
      );
      expect(
        validateReturn(
          sale: _sale(status: SaleStatus.voided),
          existingReturns: const [],
          quantities: {key: 1},
          reason: 'Wrong medicine',
        ),
        contains('This sale was voided — it cannot be returned.'),
      );
    });

    test('returnStatusAfter is partial until everything is back', () {
      SaleReturn retFor(int qty) => SaleReturn(
        id: 'ret-$qty',
        branchId: _dha,
        saleId: 'sale-1',
        invoiceNumber: 'INV-DHA-1001',
        items: [
          SaleReturnItem(
            medicineId: 'med-1',
            medicineName: 'Panadol Extra',
            quantity: qty,
            unitPriceMinor: 12000,
            refundMinor: 12000 * qty,
            saleBatchId: 'b1',
          ),
        ],
        reason: 'r',
        refundedAmountMinor: 12000 * qty,
        approvedBy: 'u',
        approvedByName: 'u',
      );
      expect(
        returnStatusAfter(sale: sale, allReturns: [retFor(1)]),
        SaleStatus.partiallyReturned,
      );
      expect(
        returnStatusAfter(sale: sale, allReturns: [retFor(1), retFor(1)]),
        SaleStatus.returned,
      );
    });

    test('restockTarget prefers the original batch, then FEFO', () {
      final inventory = [
        _batch(id: 'b-old', expiryDate: DateTime.now().add(const Duration(days: 10))),
        _batch(id: 'b-new', expiryDate: DateTime.now().add(const Duration(days: 300))),
      ];
      expect(
        restockTarget(
          inventory: inventory,
          medicineId: 'med-1',
          originalBatchId: 'b-old',
        )?.id,
        'b-old',
      );
      expect(
        restockTarget(
          inventory: inventory,
          medicineId: 'med-1',
          originalBatchId: 'gone',
        )?.id,
        'b-old',
        reason: 'earliest-expiry available batch when the original is gone',
      );
      expect(
        restockTarget(
          inventory: inventory,
          medicineId: 'med-2',
          originalBatchId: null,
        ),
        isNull,
        reason: 'no batch of the medicine at all — never invent one',
      );
    });
  });

  group('Sale returns (notifier) end-to-end', () {
    Future<({ProviderContainer container, Sale sale})> completeSale({
      required String branchId,
      int quantity = 2,
      SalePaymentMethod method = SalePaymentMethod.cash,
      String? customerId,
      DemoRole role = DemoRole.cashier,
    }) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(authProvider.notifier).signInAsDemo(role);
      final inventory = await container
          .read(inventoryRepositoryProvider)
          .getInventory(branchId: branchId);
      final stocked = inventory.firstWhere(
        (item) => item.medicineId == 'med-panadol-extra' && item.quantity > 0,
      );
      final medicine = await container
          .read(medicineRepositoryProvider)
          .getById(stocked.medicineId);
      final result = await container
          .read(salesProvider.notifier)
          .completeSale(
            branchId: branchId,
            customerId: customerId,
            cashierName: 'Cashier',
            lines: [
              CartLine(
                medicineId: stocked.medicineId,
                medicineName: medicine?.name ?? stocked.medicineId,
                unitPriceMinor: medicine?.priceMinor ?? 12000,
                quantity: quantity,
              ),
            ],
            paymentMethod: method,
            cashReceivedMinor: 100000,
          );
      expect(result.sale, isNotNull, reason: result.error);
      return (container: container, sale: result.sale!);
    }

    Future<int> stockOf(ProviderContainer container, String batchId) async {
      final inventory = await container
          .read(inventoryRepositoryProvider)
          .getInventory();
      return inventory.firstWhere((item) => item.id == batchId).quantity;
    }

    test('partial return restocks, refunds and moves the sale status',
        () async {
      final (:container, :sale) = await completeSale(branchId: _glb);
      final batchId = sale.items.first.batchId!;
      final before = await stockOf(container, batchId);
      final result = await container
          .read(saleReturnsProvider.notifier)
          .createReturn(
            sale: sale,
            quantities: {
              returnChunkKey(sale.items.first.medicineId, batchId): 1,
            },
            reason: 'Wrong medicine dispensed',
            approver: container.read(authProvider),
          );
      expect(result.error, isNull, reason: result.error);
      expect(result.saleReturn, isNotNull);
      expect(result.saleReturn!.refundedAmountMinor, 12000);
      expect(await stockOf(container, batchId), before + 1);
      final updated = await container
          .read(saleRepositoryProvider)
          .getById(sale.id);
      expect(updated?.status, SaleStatus.partiallyReturned);
    });

    test('full return moves the sale to returned', () async {
      final (:container, :sale) = await completeSale(branchId: _glb);
      final batchId = sale.items.first.batchId!;
      final result = await container
          .read(saleReturnsProvider.notifier)
          .createReturn(
            sale: sale,
            quantities: {
              returnChunkKey(sale.items.first.medicineId, batchId): 2,
            },
            reason: 'Customer changed mind',
            approver: container.read(authProvider),
          );
      expect(result.saleReturn, isNotNull);
      final updated = await container
          .read(saleRepositoryProvider)
          .getById(sale.id);
      expect(updated?.status, SaleStatus.returned);
    });

    test('credit-sale return comes off the customer khata', () async {
      final (:container, :sale) = await completeSale(
        branchId: _glb,
        quantity: 1,
        method: SalePaymentMethod.credit,
        customerId: 'cust-1',
      );
      final entriesBefore = await container
          .read(customerRepositoryProvider)
          .getLedgerEntries('cust-1');
      final outstandingBefore = entriesBefore.fold(
        0,
        (sum, entry) => sum + entry.amountMinor,
      );
      expect(outstandingBefore, 550000 + sale.totalMinor);
      final result = await container
          .read(saleReturnsProvider.notifier)
          .createReturn(
            sale: sale,
            quantities: {
              returnChunkKey(
                sale.items.first.medicineId,
                sale.items.first.batchId,
              ): 1,
            },
            reason: 'Expired pack found',
            approver: container.read(authProvider),
          );
      expect(result.saleReturn, isNotNull);
      final entriesAfter = await container
          .read(customerRepositoryProvider)
          .getLedgerEntries('cust-1');
      final outstandingAfter = entriesAfter.fold(
        0,
        (sum, entry) => sum + entry.amountMinor,
      );
      expect(
        outstandingAfter,
        outstandingBefore - result.saleReturn!.refundedAmountMinor,
      );
      expect(outstandingAfter, 550000);
    });

    test('a second return cannot exceed what is still returnable',
        () async {
      final (:container, :sale) = await completeSale(branchId: _glb);
      final key = returnChunkKey(
        sale.items.first.medicineId,
        sale.items.first.batchId,
      );
      final notifier = container.read(saleReturnsProvider.notifier);
      final first = await notifier.createReturn(
        sale: sale,
        quantities: {key: 1},
        reason: 'First return',
        approver: container.read(authProvider),
      );
      expect(first.saleReturn, isNotNull);
      final second = await notifier.createReturn(
        sale: sale,
        quantities: {key: 2},
        reason: 'Too many',
        approver: container.read(authProvider),
      );
      expect(second.saleReturn, isNull);
      expect(second.error, contains('Only 1 unit(s)'));
    });

    test('permission gating: pharmacist cannot approve, owner can',
        () async {
      final (:container, :sale) = await completeSale(branchId: _dha);
      final key = returnChunkKey(
        sale.items.first.medicineId,
        sale.items.first.batchId,
      );
      final notifier = container.read(saleReturnsProvider.notifier);
      // The matrix gives the pharmacist `none` on posRefund (D70 —
      // read the matrix, not the job title).
      final pharmacist = _userFor('pharmacist');
      final denied = await notifier.createReturn(
        sale: sale,
        quantities: {key: 1},
        reason: 'Wrong medicine',
        approver: pharmacist,
      );
      expect(denied.saleReturn, isNull);
      expect(denied.error, contains('POS refund permission'));
      // A cashier from the OTHER branch cannot approve either.
      final otherBranchCashier = _userFor('cashier', [_glb]);
      final deniedBranch = await notifier.createReturn(
        sale: sale,
        quantities: {key: 1},
        reason: 'Wrong medicine',
        approver: otherBranchCashier,
      );
      expect(deniedBranch.saleReturn, isNull);
      // The owner approves anywhere.
      final owner = _userFor('owner', [_dha, _glb]);
      final allowed = await notifier.createReturn(
        sale: sale,
        quantities: {key: 1},
        reason: 'Wrong medicine',
        approver: owner,
      );
      expect(allowed.saleReturn, isNotNull);
    });
  });

  group('Owner dashboard data (pure + providers)', () {
    final now = DateTime.now();
    final branches = demoBranches;
    final dhaSale = _sale(
      id: 'sale-dha',
      branchId: _dha,
      totalMinor: 24000,
      items: [_saleItem(quantity: 2)],
    );
    final glbSale = _sale(
      id: 'sale-glb',
      branchId: _glb,
      totalMinor: 12000,
      items: [_saleItem(quantity: 1)],
    );

    test('gross profit uses batch cost, falls back to purchase price',
        () {
      final inventory = [_batch(id: 'b1', costMinor: 5000)];
      final medicines = [
        _medicine(id: 'med-1'),
        Medicine(
          id: 'med-2',
          name: 'Augmentin',
          brand: 'GSK',
          categoryId: 'cat-abx',
          strength: '625mg',
          packSize: '10 tablets',
          price: 100.0,
          purchasePriceMinor: 6000,
        ),
      ];
      final sale = _sale(
        items: [
          _saleItem(quantity: 2, unitPriceMinor: 12000, batchId: 'b1'),
          _saleItem(
            medicineId: 'med-2',
            medicineName: 'Augmentin',
            quantity: 1,
            unitPriceMinor: 10000,
            batchId: 'missing-batch',
          ),
        ],
        totalMinor: 34000,
      );
      // (24000 − 2×5000) + (10000 − 6000) = 18000.
      expect(
        computeGrossProfitMinor(
          sales: [sale],
          inventory: inventory,
          medicines: medicines,
          now: now,
        ),
        18000,
      );
      // Today's refund takes the profit back with it.
      final ret = SaleReturn(
        id: 'ret-1',
        branchId: _dha,
        saleId: sale.id,
        invoiceNumber: sale.invoiceNumber,
        items: const [],
        reason: 'r',
        refundedAmountMinor: 12000,
        approvedBy: 'u',
        approvedByName: 'u',
        createdAt: now,
      );
      expect(
        computeGrossProfitMinor(
          sales: [sale],
          inventory: inventory,
          medicines: medicines,
          returns: [ret],
          now: now,
        ),
        6000,
      );
    });

    test('outstanding khata is the ledger sum', () {
      final entries = generateDemoLedgerEntries();
      expect(computeOutstandingKhataMinor(entries), 3200000);
    });

    test('branch comparison attributes khata only via credit sales', () {
      final inventory = [
        _batch(id: 'b-dha', branchId: _dha, quantity: 10, costMinor: 5000),
        _batch(id: 'b-glb', branchId: _glb, quantity: 5, costMinor: 8000),
      ];
      final prescriptions = [
        Prescription(
          id: 'rx-dha-1',
          customerId: 'cust-1',
          imageUrl: 'sample',
          branchId: _dha,
          status: PrescriptionStatus.pending,
          createdAt: now,
        ),
        Prescription(
          id: 'rx-glb-1',
          customerId: 'cust-2',
          imageUrl: 'sample',
          branchId: _glb,
          status: PrescriptionStatus.approved,
          createdAt: now,
        ),
      ];
      final purchaseOrders = [
        PurchaseOrder(
          id: 'po-1',
          poNumber: 'PO-DHA-1001',
          branchId: _dha,
          supplierId: 'sup-1',
          items: const [],
          status: PurchaseOrderStatus.draft,
        ),
        PurchaseOrder(
          id: 'po-2',
          poNumber: 'PO-GLB-1001',
          branchId: _glb,
          supplierId: 'sup-1',
          items: const [],
          status: PurchaseOrderStatus.received,
        ),
      ];
      final ledger = [
        LedgerEntry(
          id: 'led-x',
          customerId: 'cust-1',
          kind: LedgerEntryKind.creditSale,
          amountMinor: 24000,
          reason: 'Credit sale',
          referenceId: 'sale-dha',
          balanceAfterMinor: 24000,
          createdAt: now,
        ),
        LedgerEntry(
          id: 'led-y',
          customerId: 'cust-2',
          kind: LedgerEntryKind.credit,
          amountMinor: 100000,
          reason: 'Manual udhaar — no branch',
          balanceAfterMinor: 100000,
          createdAt: now,
        ),
      ];
      final rows = computeBranchComparison(
        branches: branches,
        orders: const [],
        sales: [dhaSale, glbSale],
        inventory: inventory,
        prescriptions: prescriptions,
        purchaseOrders: purchaseOrders,
        ledgerEntries: ledger,
        now: now,
      );
      expect(rows, hasLength(2));
      final dha = rows.firstWhere((row) => row.branchId == _dha);
      expect(dha.todaySalesMinor, 24000);
      expect(dha.todayOrders, 1);
      expect(dha.stockValueMinor, 50000);
      expect(dha.outstandingMinor, 24000);
      expect(dha.pendingPrescriptions, 1);
      expect(dha.openPurchaseOrders, 1);
      final glb = rows.firstWhere((row) => row.branchId == _glb);
      expect(glb.todaySalesMinor, 12000);
      expect(glb.stockValueMinor, 40000);
      expect(
        glb.outstandingMinor,
        0,
        reason: 'the manual entry has no sale reference — unattributed',
      );
      expect(glb.pendingPrescriptions, 0);
      expect(glb.openPurchaseOrders, 0);
    });

    test('branchComparisonProvider: owner sees all, manager sees one',
        () async {
      final ownerContainer = ProviderContainer();
      addTearDown(ownerContainer.dispose);
      await ownerContainer
          .read(authProvider.notifier)
          .signInAsDemo(DemoRole.owner);
      final ownerRows = await ownerContainer.read(
        branchComparisonProvider.future,
      );
      expect(ownerRows.map((row) => row.branchId), containsAll([_dha, _glb]));

      final managerContainer = ProviderContainer();
      addTearDown(managerContainer.dispose);
      await managerContainer
          .read(authProvider.notifier)
          .signInAsDemo(DemoRole.branchManager);
      final managerRows = await managerContainer.read(
        branchComparisonProvider.future,
      );
      expect(
        managerRows.map((row) => row.branchId),
        [_dha],
        reason: 'branch manager sees only the home branch (DHA)',
      );
    });

    test('ownerLiveKpisProvider reads the seeded org figures', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final kpis = await container.read(ownerLiveKpisProvider('all').future);
      expect(kpis.outstandingKhataMinor, 3200000);
      expect(kpis.openPurchaseOrders, 4);
      expect(kpis.grossProfitMinor, 0, reason: 'no POS sales yet');
    });
  });

  group('Printer settings + service', () {
    test('settings default to browser print and update', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(printerSettingsProvider.notifier);
      expect(container.read(printerSettingsProvider).type, PrinterType.browser);
      notifier.setName('Counter printer');
      notifier.setType(PrinterType.network);
      notifier.setNetworkHost('192.168.1.50');
      notifier.setNetworkPort(9100);
      final settings = container.read(printerSettingsProvider);
      expect(settings.name, 'Counter printer');
      expect(settings.networkHost, '192.168.1.50');
      expect(settings.networkPort, 9100);
    });

    test('test receipt names the printer and the demo body', () {
      const settings = PrinterSettings(name: 'Counter printer');
      final text = testReceiptText(
        settings,
        now: DateTime(2026, 11, 25, 20, 0),
      );
      expect(text, contains('TEST PRINT'));
      expect(text, contains('Counter printer'));
      expect(text, contains('25/11/2026, 20:00'));
    });

    test('web printer reports unavailable in the test env (stub)', () async {
      // flutter test runs on the VM, not the web — the conditional
      // import picks the stub, so canPrintReceipt is false here.
      const printer = WebReceiptPrinter();
      expect(printer.status.available, isFalse);
      final result = await printer.printText('hello');
      expect(result.success, isFalse);
      final drawer = await printer.openCashDrawer();
      expect(drawer.success, isFalse);
      expect(drawer.message, contains('Cash drawer kick'));
    });

    test('network / USB stubs never pretend to print', () async {
      const network = NetworkReceiptPrinter(networkHost: '');
      expect(network.status.available, isFalse);
      expect(network.status.message, contains('no printer IP'));
      final noHost = await network.printText('hello');
      expect(noHost.success, isFalse);
      const usb = UsbReceiptPrinter();
      expect(usb.status.available, isFalse);
      expect((await usb.printText('hello')).success, isFalse);
    });
  });

  group('Firestore mappers + returns repository', () {
    test('sale status round-trips through the mapper', () {
      final sale = _sale(
        status: SaleStatus.partiallyReturned,
        items: [_saleItem()],
      );
      final doc = saleToFirestore(sale, orgId: demoOrganizationId);
      expect(doc['status'], 'partially_returned');
      final back = saleFromFirestore(
        sale.id,
        doc,
        itemDocs: [saleItemToFirestore(_saleItem())],
      );
      expect(back.status, SaleStatus.partiallyReturned);
      expect(back.invoiceNumber, 'INV-DHA-1001');
    });

    test('sale return round-trips through the mapper', () {
      final saleReturn = SaleReturn(
        id: 'ret-1',
        branchId: _dha,
        saleId: 'sale-1',
        invoiceNumber: 'INV-DHA-1001',
        items: [
          SaleReturnItem(
            medicineId: 'med-1',
            medicineName: 'Panadol Extra',
            quantity: 1,
            unitPriceMinor: 12000,
            refundMinor: 12000,
            saleBatchId: 'b1',
            restockBatchId: 'b1',
            restockBatchNo: 'B-b1',
          ),
        ],
        reason: 'Wrong medicine',
        refundedAmountMinor: 12000,
        approvedBy: 'u-owner',
        approvedByName: 'Owner',
      );
      final doc = saleReturnToFirestore(saleReturn, orgId: demoOrganizationId);
      expect(doc['refundedAmount'], 12000);
      expect(doc['saleId'], 'sale-1');
      final back = saleReturnFromFirestore(
        'ret-1',
        doc,
        itemDocs: [
          saleReturnItemToFirestore(saleReturn.items.first),
        ],
      );
      expect(back.refundedAmountMinor, 12000);
      expect(back.items.first.saleBatchId, 'b1');
      expect(back.items.first.restockBatchId, 'b1');
      expect(back.status, SaleReturnStatus.completed);
    });

    test('FirestoreSaleReturnRepository over the fake transport', () async {
      final transport = _FakeTransport();
      transport.docs['branches/branch-dha-main'] = {'name': 'DHA'};
      transport.docs['branches/branch-demo-gulberg'] = {'name': 'Gulberg'};
      final repo = FirestoreSaleReturnRepository(
        transport: transport,
        organizationId: demoOrganizationId,
      );
      final saved = await repo.createReturn(
        SaleReturn(
          id: '',
          branchId: _dha,
          saleId: 'sale-1',
          invoiceNumber: 'INV-DHA-1001',
          items: [
            SaleReturnItem(
              medicineId: 'med-1',
              medicineName: 'Panadol Extra',
              quantity: 1,
              unitPriceMinor: 12000,
              refundMinor: 12000,
              saleBatchId: 'b1',
            ),
          ],
          reason: 'Wrong medicine',
          refundedAmountMinor: 12000,
          approvedBy: 'u-owner',
          approvedByName: 'Owner',
        ),
      );
      expect(saved.id, isNotEmpty);
      final branchReturns = await repo.getReturns(branchId: _dha);
      expect(branchReturns, hasLength(1));
      expect(branchReturns.first.refundedAmountMinor, 12000);
      expect(await repo.getReturns(branchId: _glb), isEmpty);
      final forSale = await repo.getReturnsForSale('sale-1');
      expect(forSale, hasLength(1));
    });

    test('FirestoreSaleRepository.updateSale writes the status', () async {
      final transport = _FakeTransport();
      final repo = FirestoreSaleRepository(
        transport: transport,
        organizationId: demoOrganizationId,
      );
      final sale = _sale(items: [_saleItem()]);
      await transport.setDocument(
        FirestoreSchema.saleDocPath(_dha, sale.id),
        saleToFirestore(sale, orgId: demoOrganizationId),
      );
      await repo.updateSale(sale.copyWith(status: SaleStatus.returned));
      final doc = await transport.getDocument(
        FirestoreSchema.saleDocPath(_dha, sale.id),
      );
      expect(doc?['status'], 'returned');
    });
  });

  group('POS scan + hold/resume (widget)', () {
    Future<void> openPos(WidgetTester tester) async {
      await pumpAppToLogin(tester, const PharmaDeskApp());
      await signInAsDemoRole(tester, 'Cashier');
      await tester.tap(
        find.descendant(
          of: find.byType(BottomNavigationBar),
          matching: find.text('Billing'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Billing & POS'), findsOneWidget);
    }

    testWidgets('simulate scan adds the first sellable medicine',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await openPos(tester);
      await tester.ensureVisible(find.text('Simulate scan'));
      await tester.tap(find.text('Simulate scan'));
      await tester.pumpAndSettle();
      expect(find.text('Cart (1)'), findsOneWidget);
      expect(find.text('Panadol Extra 500mg'), findsWidgets);
    });

    testWidgets('typed barcode + Enter adds the medicine; unknown errors',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await openPos(tester);
      final barcode = demoMedicines
          .firstWhere((m) => m.id == 'med-panadol-extra')
          .barcode!;
      await tester.enterText(
        find.byKey(const ValueKey('pos-scan-field')),
        barcode,
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.text('Cart (1)'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('pos-scan-field')),
        '9999999999999',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(
        find.text('No medicine with barcode "9999999999999".'),
        findsOneWidget,
      );
      expect(find.text('Cart (1)'), findsOneWidget);
    });

    testWidgets('hold parks the cart; resume restores it; discard drops it',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await openPos(tester);
      await tester.ensureVisible(find.text('Simulate scan'));
      await tester.tap(find.text('Simulate scan'));
      await tester.pumpAndSettle();
      expect(find.text('Cart (1)'), findsOneWidget);
      await tester.ensureVisible(find.text('Hold sale'));
      await tester.tap(find.text('Hold sale'));
      await tester.pumpAndSettle();
      expect(find.text('Cart (0)'), findsOneWidget);
      expect(find.text('Held sales (1)'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('pos-resume-held-1')));
      await tester.tap(find.byKey(const ValueKey('pos-resume-held-1')));
      await tester.pumpAndSettle();
      expect(find.text('Cart (1)'), findsOneWidget);
      expect(find.text('Held sales (0)'), findsOneWidget);
      await tester.ensureVisible(find.text('Hold sale'));
      await tester.tap(find.text('Hold sale'));
      await tester.pumpAndSettle();
      expect(find.text('Held sales (1)'), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const ValueKey('pos-discard-held-2')),
      );
      await tester.tap(find.byKey(const ValueKey('pos-discard-held-2')));
      await tester.pumpAndSettle();
      expect(find.text('Held sales (0)'), findsOneWidget);
      expect(find.text('Cart (0)'), findsOneWidget);
    });
  });

  group('Return flow (widget) end-to-end', () {
    Future<void> completeCashSale(WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await pumpAppToLogin(tester, const PharmaDeskApp());
      await signInAsDemoRole(tester, 'Cashier');
      await tester.tap(
        find.descendant(
          of: find.byType(BottomNavigationBar),
          matching: find.text('Billing'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'Panadol');
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('pos-add-med-panadol-extra')),
      );
      await tester.tap(
        find.byKey(const ValueKey('pos-add-med-panadol-extra')),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Cash received (Rs)'));
      await tester.enterText(
        find.ancestor(
          of: find.text('Cash received (Rs)'),
          matching: find.byType(TextField),
        ),
        '200',
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Complete Sale'));
      await tester.tap(find.text('Complete Sale'));
      await tester.pumpAndSettle();
      expect(find.text('Receipt INV-GLB-1001'), findsOneWidget);
    }

    testWidgets('cash sale → receipt → return → returns list',
        (WidgetTester tester) async {
      await completeCashSale(tester);
      await tester.ensureVisible(find.text('Return items'));
      await tester.tap(find.text('Return items'));
      await tester.pumpAndSettle();
      expect(find.text('New return'), findsOneWidget);
      expect(find.textContaining('INV-GLB-1001'), findsWidgets);
      await tester.ensureVisible(find.byTooltip('Return one more'));
      await tester.tap(find.byTooltip('Return one more'));
      await tester.pumpAndSettle();
      expect(find.text('Rs 120.00'), findsWidgets);
      await tester.enterText(
        find.ancestor(
          of: find.text('Reason for the return (required)'),
          matching: find.byType(TextField),
        ),
        'Wrong medicine dispensed',
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Confirm return'));
      await tester.tap(find.text('Confirm return'));
      await tester.pumpAndSettle();
      expect(find.text('Returns & refunds'), findsOneWidget);
      expect(find.textContaining('INV-GLB-1001'), findsWidgets);
      expect(find.text('Full return'), findsOneWidget);
      expect(find.text('-Rs 120.00'), findsOneWidget);
    });

    testWidgets('returns list empty state links to the new-return form',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await pumpAppToLogin(tester, const PharmaDeskApp());
      await signInAsDemoRole(tester, 'Cashier');
      await tester.tap(
        find.descendant(
          of: find.byType(BottomNavigationBar),
          matching: find.text('Billing'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Returns & refunds'));
      await tester.tap(find.text('Returns & refunds'));
      await tester.pumpAndSettle();
      expect(find.text('No returns yet'), findsOneWidget);
      await tester.ensureVisible(find.text('New return').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('New return').first);
      await tester.pumpAndSettle();
      expect(find.text('New return'), findsOneWidget);
    });

    testWidgets('pharmacist sees why Confirm is disabled',
        (WidgetTester tester) async {
      // A completed DHA sale + a pharmacist approver, pumped
      // straight into the form (no router needed — confirm is
      // disabled, so nothing navigates).
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container
          .read(authProvider.notifier)
          .signInAsDemo(DemoRole.pharmacist);
      final inventory = await container
          .read(inventoryRepositoryProvider)
          .getInventory(branchId: _dha);
      final stocked = inventory.firstWhere(
        (item) => item.medicineId == 'med-panadol-extra' && item.quantity > 0,
      );
      final medicine = await container
          .read(medicineRepositoryProvider)
          .getById(stocked.medicineId);
      final completed = await container
          .read(salesProvider.notifier)
          .completeSale(
            branchId: _dha,
            cashierName: 'Cashier',
            lines: [
              CartLine(
                medicineId: stocked.medicineId,
                medicineName: medicine?.name ?? stocked.medicineId,
                unitPriceMinor: medicine?.priceMinor ?? 12000,
                quantity: 1,
              ),
            ],
            paymentMethod: SalePaymentMethod.cash,
            cashReceivedMinor: 100000,
          );
      expect(completed.sale, isNotNull);
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: ReturnFormScreen(saleId: completed.sale!.id),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('New return'), findsOneWidget);
      expect(
        tester
            .widget<PharmaButton>(find.widgetWithText(PharmaButton, 'Confirm return'))
            .onPressed,
        isNull,
        reason: 'pharmacist has no posRefund (matrix)',
      );
      expect(
        find.textContaining('cannot approve returns in this branch'),
        findsOneWidget,
      );
    });
  });

  group('Owner dashboard (widget)', () {
    testWidgets('renders live KPIs, branch comparison and alerts feed',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await pumpAppToLogin(tester, const PharmaDeskApp());
      await signInAsDemoRole(tester, 'Owner');
      expect(find.text('Owner dashboard'), findsOneWidget);
      expect(find.text('Gross profit — today'), findsOneWidget);
      expect(find.text('Outstanding khata'), findsOneWidget);
      expect(find.text('Rs 32,000.00'), findsWidgets);
      expect(find.text('Open purchase orders'), findsOneWidget);
      expect(find.text('Branch comparison'), findsOneWidget);
      expect(find.text('Demo Branch — DHA'), findsWidgets);
      expect(find.text('Demo Branch — Gulberg'), findsWidgets);
      expect(find.text('Alerts feed'), findsOneWidget);
    });
  });

  group('Printer settings (widget)', () {
    testWidgets('test print goes through the configured printer',
        (WidgetTester tester) async {
      final fakePrinter = _FakePrinter();
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            receiptPrinterProvider.overrideWithValue(fakePrinter),
          ],
          child: const PharmaDeskApp(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 1500));
      await tester.pumpAndSettle();
      expect(find.text('Sign in'), findsOneWidget);
      await signInAsDemoRole(tester, 'Owner');
      // Day 5: the sidebar gained the Staff & HR module (+ its
      // Attendance/Shifts sub-items), so 'Settings' no longer sits in
      // the initially-built ListView range — scroll it into view
      // first (Day 2 scrollListToTitle pattern), instead of
      // ensureVisible, which needs the element to already exist.
      final sidebarList = find.byType(ListView);
      final settingsItem = find.descendant(
        of: sidebarList,
        matching: find.text('Settings'),
      );
      for (var i = 0; i < 12 && settingsItem.evaluate().isEmpty; i++) {
        await tester.drag(sidebarList, const Offset(0, -300));
        await tester.pumpAndSettle();
      }
      await tester.ensureVisible(settingsItem);
      await tester.pumpAndSettle();
      await tester.tap(settingsItem);
      await tester.pumpAndSettle();
      expect(find.text('Receipt printer'), findsOneWidget);
      await tester.ensureVisible(find.text('Test print'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Test print'));
      await tester.pumpAndSettle();
      expect(fakePrinter.lastPrinted, contains('TEST PRINT'));
      expect(find.text('Printed (fake).'), findsOneWidget);
    });
  });
}
