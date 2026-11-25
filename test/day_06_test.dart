// PharmaDesk Day 6 tests — POS/billing + customers.
//
// Covers: cart math (int paisa, discounts, tax, change), FEFO batch
// allocation through the Day 5 shared guard, sale completion + FEFO
// stock decrement, credit sales updating the khata, receipt text,
// khata math (outstanding, payments, credit entries), customer
// search/add validation, the sale + ledger repositories, dashboard
// figures reflecting POS sales, and the POS / receipt / sales-history
// / customer screens end to end.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharmadesk/app/pharmadesk_app.dart';
import 'package:pharmadesk/core/services/demo_seed_data.dart';
import 'package:pharmadesk/core/services/repositories.dart';
import 'package:pharmadesk/core/widgets/buttons.dart';
import 'package:pharmadesk/features/billing/billing_logic.dart';
import 'package:pharmadesk/features/billing/billing_provider.dart';
import 'package:pharmadesk/features/customers/customer_logic.dart';
import 'package:pharmadesk/features/customers/customers_provider.dart';
import 'package:pharmadesk/features/dashboard/dashboard_data.dart';
import 'package:pharmadesk/features/inventory/inventory_logic.dart';
import 'package:pharmadesk/models/customer.dart';
import 'package:pharmadesk/models/customer_ledger.dart';
import 'package:pharmadesk/models/inventory_item.dart';
import 'package:pharmadesk/models/sale.dart';

import 'test_helpers.dart';

CartLine _line({
  String medicineId = 'med-panadol-extra',
  String medicineName = 'Panadol Extra',
  int unitPriceMinor = 12000,
  int quantity = 1,
  int lineDiscountMinor = 0,
}) => CartLine(
  medicineId: medicineId,
  medicineName: medicineName,
  unitPriceMinor: unitPriceMinor,
  quantity: quantity,
  lineDiscountMinor: lineDiscountMinor,
);

InventoryItem _batch({
  String id = 'inv-test-1',
  String medicineId = 'med-panadol-extra',
  String branchId = 'branch-dha-main',
  int quantity = 20,
  DateTime? expiryDate,
  String? batchNo,
}) => InventoryItem(
  id: id,
  medicineId: medicineId,
  branchId: branchId,
  quantity: quantity,
  lowStockThreshold: 10,
  expiryDate: expiryDate,
  batchNo: batchNo ?? 'B-1',
  costMinor: 5000,
);

Sale _sale({
  String id = 'sale-test-1',
  String invoiceNumber = 'INV-DHA-1001',
  String branchId = 'branch-dha-main',
  String? customerId,
  List<SaleItem>? items,
  int subtotalMinor = 12000,
  int billDiscountMinor = 0,
  int taxMinor = 0,
  int totalMinor = 12000,
  SalePaymentMethod paymentMethod = SalePaymentMethod.cash,
  int cashReceivedMinor = 0,
  int changeMinor = 0,
  DateTime? createdAt,
}) => Sale(
  id: id,
  invoiceNumber: invoiceNumber,
  branchId: branchId,
  customerId: customerId,
  cashierName: 'Usman Tariq',
  items:
      items ??
      const [
        SaleItem(
          medicineId: 'med-panadol-extra',
          medicineName: 'Panadol Extra',
          quantity: 1,
          unitPriceMinor: 12000,
          batchId: 'inv-test-1',
          batchNo: 'B-1',
          batchExpiryDate: null,
        ),
      ],
  subtotalMinor: subtotalMinor,
  billDiscountMinor: billDiscountMinor,
  taxMinor: taxMinor,
  totalMinor: totalMinor,
  paymentMethod: paymentMethod,
  cashReceivedMinor: cashReceivedMinor,
  changeMinor: changeMinor,
  idempotencyKey: 'sale-test-key',
  createdAt: createdAt ?? DateTime(2026, 11, 24, 10, 30),
);

void main() {
  group('Cart math (pure, int paisa)', () {
    test('line totals: qty x price minus discount, never below zero', () {
      expect(_line(quantity: 3).grossMinor, 36000);
      expect(_line(quantity: 3).lineTotalMinor, 36000);
      expect(
        _line(quantity: 2, lineDiscountMinor: 5000).lineTotalMinor,
        19000,
      );
      expect(_line(lineDiscountMinor: 999999).lineTotalMinor, 0);
    });

    test('subtotal is gross minus line discounts', () {
      final lines = [
        _line(quantity: 2),
        _line(
          medicineId: 'med-risek-20',
          medicineName: 'Risek',
          unitPriceMinor: 64000,
          quantity: 1,
          lineDiscountMinor: 4000,
        ),
      ];
      expect(cartGrossMinor(lines), 88000);
      expect(cartLineDiscountsMinor(lines), 4000);
      expect(cartSubtotalMinor(lines), 84000);
    });

    test('tax is a whole percent of the discounted subtotal, truncated',
        () {
      expect(
        computeTaxMinor(taxableMinor: 10000, taxRatePercent: 16),
        1600,
      );
      expect(computeTaxMinor(taxableMinor: 999, taxRatePercent: 10), 99);
      expect(computeTaxMinor(taxableMinor: 0, taxRatePercent: 16), 0);
      expect(computeTaxMinor(taxableMinor: 10000, taxRatePercent: 0), 0);
    });

    test('bill total: subtotal - bill discount + tax, never below zero',
        () {
      expect(
        billTotalMinor(
          subtotalMinor: 84000,
          billDiscountMinor: 4000,
          taxMinor: 12800,
        ),
        92800,
      );
      expect(
        billTotalMinor(subtotalMinor: 1000, billDiscountMinor: 5000),
        0,
      );
    });

    test('change due and cash shortfall', () {
      expect(
        changeDueMinor(totalMinor: 12000, cashReceivedMinor: 20000),
        8000,
      );
      expect(
        changeDueMinor(totalMinor: 12000, cashReceivedMinor: 12000),
        0,
      );
      expect(
        changeDueMinor(totalMinor: 12000, cashReceivedMinor: 5000),
        0,
      );
      expect(
        cashShortfallMinor(totalMinor: 12000, cashReceivedMinor: 5000),
        7000,
      );
      expect(
        cashShortfallMinor(totalMinor: 12000, cashReceivedMinor: 20000),
        0,
      );
    });
  });

  group('Sale validation (pure)', () {
    test('empty cart is rejected', () {
      final errors = validateSale(
        lines: const [],
        paymentMethod: SalePaymentMethod.cash,
        cashReceivedMinor: 0,
      );
      expect(errors, contains('Add at least one medicine to the cart.'));
    });

    test('quantity above sellable stock is rejected (expired excluded)',
        () {
      final errors = validateSale(
        lines: [_line(quantity: 5)],
        paymentMethod: SalePaymentMethod.card,
        sellableStockByMedicine: {'med-panadol-extra': 3},
      );
      expect(
        errors,
        contains(
          'Panadol Extra: only 3 unit(s) sellable in stock.',
        ),
      );
    });

    test('line discount above the line gross is rejected', () {
      final errors = validateSale(
        lines: [_line(lineDiscountMinor: 20000)],
        paymentMethod: SalePaymentMethod.card,
      );
      expect(
        errors,
        contains(
          'Panadol Extra: line discount cannot exceed the line total.',
        ),
      );
    });

    test('bill discount above the subtotal is rejected', () {
      final errors = validateSale(
        lines: [_line()],
        billDiscountMinor: 20000,
        paymentMethod: SalePaymentMethod.card,
      );
      expect(
        errors,
        contains('Bill discount cannot exceed the subtotal.'),
      );
    });

    test('cash shortfall is rejected; exact cash passes', () {
      final short = validateSale(
        lines: [_line()],
        paymentMethod: SalePaymentMethod.cash,
        cashReceivedMinor: 10000,
      );
      expect(short.length, 1);
      expect(
        validateSale(
          lines: [_line()],
          paymentMethod: SalePaymentMethod.cash,
          cashReceivedMinor: 12000,
        ),
        isEmpty,
      );
    });

    test('credit needs a customer and respects the credit limit', () {
      final noCustomer = validateSale(
        lines: [_line()],
        paymentMethod: SalePaymentMethod.credit,
      );
      expect(
        noCustomer,
        contains('Credit sales need a customer — pick one first.'),
      );
      final overLimit = validateSale(
        lines: [_line()],
        paymentMethod: SalePaymentMethod.credit,
        customerId: 'cust-1',
        outstandingMinor: 1990000,
        creditLimitMinor: 2000000,
      );
      expect(overLimit.length, 1);
      expect(overLimit.first, contains('Credit limit exceeded'));
      // Inside the limit passes; no limit (0) never blocks.
      expect(
        validateSale(
          lines: [_line()],
          paymentMethod: SalePaymentMethod.credit,
          customerId: 'cust-1',
          outstandingMinor: 1900000,
          creditLimitMinor: 2000000,
        ),
        isEmpty,
      );
      expect(
        validateSale(
          lines: [_line()],
          paymentMethod: SalePaymentMethod.credit,
          customerId: 'cust-1',
          outstandingMinor: 500000,
          creditLimitMinor: 0,
        ),
        isEmpty,
      );
    });
  });

  group('FEFO allocation (pure, shared guard)', () {
    final now = DateTime(2026, 11, 24, 12);

    test('picks the earliest-expiry sellable batch', () {
      final batches = {
        'med-panadol-extra': [
          _batch(
            id: 'b-late',
            expiryDate: now.add(const Duration(days: 200)),
          ),
          _batch(
            id: 'b-soon',
            expiryDate: now.add(const Duration(days: 10)),
          ),
        ],
      };
      final result = allocateFefo(
        lines: [_line(quantity: 2)],
        batchesByMedicine: batches,
        now: now,
      );
      expect(result.items.length, 1);
      expect(result.items.first.batchId, 'b-soon');
      expect(result.decrements, [(batchId: 'b-soon', quantity: 2)]);
    });

    test('expired batches are skipped, never decremented', () {
      final batches = {
        'med-panadol-extra': [
          _batch(
            id: 'b-exp',
            quantity: 50,
            expiryDate: now.subtract(const Duration(days: 2)),
          ),
          _batch(
            id: 'b-good',
            quantity: 5,
            expiryDate: now.add(const Duration(days: 30)),
          ),
        ],
      };
      final result = allocateFefo(
        lines: [_line(quantity: 3)],
        batchesByMedicine: batches,
        now: now,
      );
      expect(result.items.first.batchId, 'b-good');
      expect(result.decrements, [(batchId: 'b-good', quantity: 3)]);
    });

    test('a line spanning two batches splits; discount stays on chunk 1',
        () {
      final batches = {
        'med-panadol-extra': [
          _batch(
            id: 'b-soon',
            quantity: 2,
            expiryDate: now.add(const Duration(days: 10)),
          ),
          _batch(
            id: 'b-late',
            quantity: 10,
            expiryDate: now.add(const Duration(days: 200)),
          ),
        ],
      };
      final result = allocateFefo(
        lines: [_line(quantity: 5, lineDiscountMinor: 3000)],
        batchesByMedicine: batches,
        now: now,
      );
      expect(result.items.length, 2);
      expect(result.items[0].quantity, 2);
      expect(result.items[0].lineDiscountMinor, 3000);
      expect(result.items[1].quantity, 3);
      expect(result.items[1].lineDiscountMinor, 0);
      expect(result.decrements.length, 2);
      // Discount total preserved across the split.
      expect(
        result.items.fold(
          0,
          (sum, item) => sum + item.lineDiscountMinor,
        ),
        3000,
      );
    });

    test('insufficient sellable stock throws; nothing is allocated', () {
      final batches = {
        'med-panadol-extra': [
          _batch(
            id: 'b-exp',
            quantity: 100,
            expiryDate: now.subtract(const Duration(days: 1)),
          ),
          _batch(
            id: 'b-good',
            quantity: 1,
            expiryDate: now.add(const Duration(days: 30)),
          ),
        ],
      };
      expect(
        () => allocateFefo(
          lines: [_line(quantity: 5)],
          batchesByMedicine: batches,
          now: now,
        ),
        throwsArgumentError,
      );
    });
  });

  group('buildSale + receipt text (pure)', () {
    test('buildSale computes totals, cash change and idempotency key', () {
      final items = [
        const SaleItem(
          medicineId: 'med-panadol-extra',
          medicineName: 'Panadol Extra',
          quantity: 2,
          unitPriceMinor: 12000,
          lineDiscountMinor: 1000,
        ),
      ];
      final sale = buildSale(
        branchId: 'branch-dha-main',
        cashierName: 'Usman Tariq',
        items: items,
        billDiscountMinor: 1000,
        taxRatePercent: 10,
        paymentMethod: SalePaymentMethod.cash,
        cashReceivedMinor: 30000,
      );
      // Subtotal 23000, bill discount 1000 -> taxable 22000, tax 2200.
      expect(sale.subtotalMinor, 23000);
      expect(sale.taxMinor, 2200);
      expect(sale.totalMinor, 24200);
      expect(sale.changeMinor, 5800);
      expect(sale.idempotencyKey, startsWith('sale-branch-dha-main-'));
      expect(sale.customerId, isNull);
    });

    test('receipt text carries invoice, items, totals and DEMO mark', () {
      final sale = _sale(
        paymentMethod: SalePaymentMethod.cash,
        cashReceivedMinor: 20000,
        changeMinor: 8000,
      );
      final text = receiptText(
        sale: sale,
        branchName: 'Demo Branch — DHA',
        branchAddress: 'DHA Phase 2, Lahore',
        brandHeader: 'PharmaDesk',
        customerName: 'Ahmed Raza',
      );
      expect(text, contains('INV-DHA-1001'));
      expect(text, contains('Panadol Extra x1'));
      expect(text, contains('TOTAL: Rs 120.00'));
      expect(text, contains('Cash received: Rs 200.00'));
      expect(text, contains('Change: Rs 80.00'));
      expect(text, contains('Customer: Ahmed Raza'));
      expect(text, contains('DEMO — not a real receipt.'));
    });
  });

  group('Khata math + customer logic (pure)', () {
    test('seeded ledger outstanding balances', () {
      final entries = generateDemoLedgerEntries();
      int outstandingFor(String customerId) => outstandingMinor(
        entries.where((e) => e.customerId == customerId),
      );
      expect(outstandingFor('cust-1'), 550000); // Rs 5,500.00
      expect(outstandingFor('cust-2'), 250000);
      expect(outstandingFor('cust-3'), 1200000);
      expect(outstandingFor('cust-4'), 1200000);
      expect(outstandingFor('cust-5'), 0);
      expect(outstandingFor('cust-6'), 0);
      // balanceAfter snapshots agree with the running sum.
      var running = 0;
      for (final entry in entries.where((e) => e.customerId == 'cust-4')) {
        running += entry.amountMinor;
        expect(entry.balanceAfterMinor, running);
      }
    });

    test('customer search matches name and phone digits', () {
      final customers = demoCustomers;
      expect(
        searchCustomers(customers, query: 'ahmed').map((c) => c.id),
        ['cust-1'],
      );
      expect(
        searchCustomers(customers, query: '0300').map((c) => c.id),
        ['cust-1', 'cust-2'],
      );
      expect(
        searchCustomers(customers, query: '1112233').map((c) => c.id),
        ['cust-1'],
      );
      expect(searchCustomers(customers, query: 'zzz'), isEmpty);
      expect(searchCustomers(customers, query: '').length, 8);
    });

    test('new customer validation: name, phone, duplicate', () {
      expect(
        validateNewCustomer(name: '', phone: '03009998877'),
        contains('Customer name is required.'),
      );
      expect(
        validateNewCustomer(name: 'Test', phone: ''),
        contains('Phone number is required.'),
      );
      expect(
        validateNewCustomer(name: 'Test', phone: '0300'),
        contains(
          'Phone number looks too short (need at least 10 digits).',
        ),
      );
      expect(
        validateNewCustomer(
          name: 'Test',
          phone: '0300-1112233',
          existingPhones: ['03001112233'],
        ),
        contains('A customer with this phone number already exists.'),
      );
      expect(
        validateNewCustomer(name: 'New Person', phone: '0300-9998877'),
        isEmpty,
      );
    });

    test('ledger entry validation: amount, overpay, reason', () {
      expect(
        validateLedgerEntry(
          kind: LedgerEntryKind.payment,
          amountMinor: 0,
          reason: '',
          outstandingMinor: 5000,
        ),
        contains('Amount must be more than zero.'),
      );
      expect(
        validateLedgerEntry(
          kind: LedgerEntryKind.payment,
          amountMinor: 6000,
          reason: '',
          outstandingMinor: 5000,
        ),
        contains('Payment cannot exceed the outstanding balance.'),
      );
      expect(
        validateLedgerEntry(
          kind: LedgerEntryKind.payment,
          amountMinor: 5000,
          reason: '',
          outstandingMinor: 5000,
        ),
        isEmpty,
      );
      expect(
        validateLedgerEntry(
          kind: LedgerEntryKind.credit,
          amountMinor: 1000,
          reason: '',
        ),
        contains('A reason is required for this entry.'),
      );
      expect(
        validateLedgerEntry(
          kind: LedgerEntryKind.credit,
          amountMinor: 1000,
          reason: 'Udhaar',
        ),
        isEmpty,
      );
    });

    test('signed amounts: credit positive, payment negative', () {
      expect(
        signedLedgerAmount(
          kind: LedgerEntryKind.credit,
          amountMinor: 5000,
        ),
        5000,
      );
      expect(
        signedLedgerAmount(
          kind: LedgerEntryKind.payment,
          amountMinor: 5000,
        ),
        -5000,
      );
      expect(
        signedLedgerAmount(
          kind: LedgerEntryKind.adjustment,
          amountMinor: 5000,
          isIncrease: false,
        ),
        -5000,
      );
      expect(
        signedLedgerAmount(
          kind: LedgerEntryKind.adjustment,
          amountMinor: 5000,
          isIncrease: true,
        ),
        5000,
      );
    });
  });

  group('Sale + customer repositories', () {
    test('sale repo assigns sequential invoice numbers per branch', () async {
      final repo = MockSaleRepository();
      final first = await repo.createSale(
        _sale(id: '', invoiceNumber: ''),
      );
      final second = await repo.createSale(
        _sale(id: '', invoiceNumber: ''),
      );
      final gulberg = await repo.createSale(
        _sale(id: '', invoiceNumber: '', branchId: 'branch-demo-gulberg'),
      );
      expect(first.id, 'sale-DHA-1001');
      expect(first.invoiceNumber, 'INV-DHA-1001');
      expect(second.invoiceNumber, 'INV-DHA-1002');
      expect(gulberg.invoiceNumber, 'INV-GLB-1001');
      final dhaSales = await repo.getSales(branchId: 'branch-dha-main');
      expect(dhaSales.length, 2);
      final all = await repo.getSales();
      expect(all.length, 3);
      expect(await repo.getById('sale-DHA-1001'), isNotNull);
      expect(await repo.getById('nope'), isNull);
    });

    test('customer repo: add + duplicate phone rejected', () async {
      final repo = MockCustomerRepository();
      final created = await repo.createCustomer(
        const Customer(id: '', name: 'New Person', phone: '0300-9998877'),
      );
      expect(created.id, 'cust-9');
      expect((await repo.getCustomers()).length, 9);
      expect(
        () => repo.createCustomer(
          const Customer(id: '', name: 'Copy', phone: '03001112233'),
        ),
        throwsArgumentError,
      );
    });

    test('ledger repo: entries append with running balanceAfter', () async {
      final repo = MockCustomerRepository();
      final before = await repo.getLedgerEntries('cust-2');
      expect(before.length, 1);
      final payment = await repo.addLedgerEntry(
        const LedgerEntry(
          id: '',
          customerId: 'cust-2',
          kind: LedgerEntryKind.payment,
          amountMinor: -100000,
          reason: 'Payment received — cash',
          balanceAfterMinor: 0,
        ),
      );
      expect(payment.balanceAfterMinor, 150000);
      final after = await repo.getLedgerEntries('cust-2');
      expect(after.length, 2);
      expect(
        () => repo.addLedgerEntry(
          const LedgerEntry(
            id: '',
            customerId: 'cust-2',
            kind: LedgerEntryKind.credit,
            amountMinor: 0,
            reason: 'zero',
            balanceAfterMinor: 0,
          ),
        ),
        throwsArgumentError,
      );
    });
  });

  group('Sale completion (notifier) + FEFO decrement', () {
    test('cash sale decrements the FEFO batch and saves the sale',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final inventoryRepo = container.read(inventoryRepositoryProvider);
      final before = await inventoryRepo.getInventory(
        branchId: 'branch-dha-main',
      );
      final panadolRows = before
          .where((r) => r.medicineId == 'med-panadol-extra')
          .toList();
      final fefo = fefoBatchFor(panadolRows)!;
      final notifier = container.read(salesProvider.notifier);
      final result = await notifier.completeSale(
        branchId: 'branch-dha-main',
        cashierName: 'Usman Tariq',
        lines: [_line(quantity: 2)],
        paymentMethod: SalePaymentMethod.cash,
        cashReceivedMinor: 30000,
      );
      expect(result.error, isNull);
      final sale = result.sale!;
      expect(sale.invoiceNumber, 'INV-DHA-1001');
      expect(sale.totalMinor, 24000);
      expect(sale.changeMinor, 6000);
      expect(sale.items.first.batchId, fefo.id);
      final after = await inventoryRepo.getInventory(
        branchId: 'branch-dha-main',
      );
      final fefoAfter = after.firstWhere((r) => r.id == fefo.id);
      expect(fefoAfter.quantity, fefo.quantity - 2);
      // Other batches untouched.
      for (final row in panadolRows) {
        if (row.id == fefo.id) continue;
        expect(
          after.firstWhere((r) => r.id == row.id).quantity,
          row.quantity,
        );
      }
      final saved = container.read(salesProvider).asData!.value;
      expect(saved.length, 1);
      expect(saved.first.id, sale.id);
    });

    test('credit sale adds a khata entry for the customer', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(salesProvider.notifier);
      final result = await notifier.completeSale(
        branchId: 'branch-dha-main',
        customerId: 'cust-1',
        cashierName: 'Usman Tariq',
        lines: [_line()],
        paymentMethod: SalePaymentMethod.credit,
      );
      expect(result.error, isNull);
      final entries = await container
          .read(customerRepositoryProvider)
          .getLedgerEntries('cust-1');
      expect(entries.length, 3);
      final latest = entries.last;
      expect(latest.kind, LedgerEntryKind.creditSale);
      expect(latest.amountMinor, 12000);
      expect(latest.balanceAfterMinor, 562000);
      expect(latest.referenceId, result.sale!.id);
    });

    test('insufficient stock completes nothing and decrements nothing',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final inventoryRepo = container.read(inventoryRepositoryProvider);
      final before = await inventoryRepo.getInventory(
        branchId: 'branch-dha-main',
      );
      final notifier = container.read(salesProvider.notifier);
      final result = await notifier.completeSale(
        branchId: 'branch-dha-main',
        cashierName: 'Usman Tariq',
        lines: [_line(quantity: 100000)],
        paymentMethod: SalePaymentMethod.card,
      );
      expect(result.sale, isNull);
      expect(result.error, isNotNull);
      final sales = container.read(salesProvider).asData?.value ?? [];
      expect(sales, isEmpty);
      final after = await inventoryRepo.getInventory(
        branchId: 'branch-dha-main',
      );
      expect(
        after.map((r) => r.quantity).toList(),
        before.map((r) => r.quantity).toList(),
      );
    });

    test('credit sale over the limit is blocked', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(salesProvider.notifier);
      // cust-3: outstanding Rs 12,000, limit Rs 15,000 — two Rs 1,850
      // Augmentin (Rs 3,700) would take it to Rs 15,700.
      final result = await notifier.completeSale(
        branchId: 'branch-dha-main',
        customerId: 'cust-3',
        cashierName: 'Usman Tariq',
        lines: [
          _line(
            medicineId: 'med-augmentin-625',
            medicineName: 'Augmentin',
            unitPriceMinor: 185000,
            quantity: 2,
          ),
        ],
        paymentMethod: SalePaymentMethod.credit,
      );
      expect(result.sale, isNull);
      expect(result.error, contains('Credit limit exceeded'));
    });
  });

  group('Ledger notifier', () {
    test('payment reduces outstanding; overpay is rejected', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(ledgerProvider('cust-1').notifier);
      await container.read(ledgerProvider('cust-1').future);
      final paid = await notifier.recordEntry(
        kind: LedgerEntryKind.payment,
        amountMinor: 100000,
        reason: 'Payment received — cash',
      );
      expect(paid.error, isNull);
      expect(paid.entry!.balanceAfterMinor, 450000);
      final entries = container.read(ledgerProvider('cust-1')).asData!.value;
      expect(outstandingMinor(entries), 450000);
      final overpay = await notifier.recordEntry(
        kind: LedgerEntryKind.payment,
        amountMinor: 99999999,
        reason: 'too much',
      );
      expect(overpay.entry, isNull);
      expect(overpay.error, contains('cannot exceed'));
    });

    test('credit entry increases outstanding', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(ledgerProvider('cust-2').notifier);
      await container.read(ledgerProvider('cust-2').future);
      final result = await notifier.recordEntry(
        kind: LedgerEntryKind.credit,
        amountMinor: 50000,
        reason: 'Udhaar — test',
      );
      expect(result.error, isNull);
      expect(result.entry!.balanceAfterMinor, 300000);
    });
  });

  group('Dashboard reflects POS sales', () {
    test('a POS sale today raises today sales + top sellers', () {
      final now = DateTime.now();
      final sale = _sale(
        createdAt: now,
        items: const [
          SaleItem(
            medicineId: 'med-panadol-extra',
            medicineName: 'Panadol Extra',
            quantity: 2,
            unitPriceMinor: 12000,
          ),
        ],
        subtotalMinor: 24000,
        totalMinor: 24000,
      );
      final without = computeDashboardKpis(
        orders: const [],
        inventory: const [],
        prescriptions: const [],
        branchId: 'branch-dha-main',
        now: now,
      );
      final withSale = computeDashboardKpis(
        orders: const [],
        inventory: const [],
        prescriptions: const [],
        sales: [sale],
        branchId: 'branch-dha-main',
        now: now,
      );
      expect(without.todaySalesMinor, 0);
      expect(withSale.todaySalesMinor, 24000);
      expect(withSale.todayOrders, 1);
      expect(withSale.revenue30dMinor, 24000);
      expect(withSale.topSellers.length, 1);
      expect(withSale.topSellers.first.medicineName, 'Panadol Extra');
      expect(withSale.topSellers.first.quantitySold, 2);
      // Other branches are unaffected.
      final otherBranch = computeDashboardKpis(
        orders: const [],
        inventory: const [],
        prescriptions: const [],
        sales: [sale],
        branchId: 'branch-demo-gulberg',
        now: now,
      );
      expect(otherBranch.todaySalesMinor, 0);
    });
  });

  group('POS + receipt + history (widget)', () {
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

    Future<void> addPanadol(WidgetTester tester) async {
      await tester.enterText(find.byType(TextField).first, 'Panadol');
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('pos-add-med-panadol-extra')),
      );
      await tester.tap(
        find.byKey(const ValueKey('pos-add-med-panadol-extra')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Cart (1)'), findsOneWidget);
    }

    testWidgets('cash sale completes and opens the receipt',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await openPos(tester);
      await addPanadol(tester);
      // Cash received Rs 200 for a Rs 120 total -> Rs 80 change.
      await tester.ensureVisible(find.text('Cash received (Rs)'));
      await tester.enterText(
        find.ancestor(
          of: find.text('Cash received (Rs)'),
          matching: find.byType(TextField),
        ),
        '200',
      );
      await tester.pumpAndSettle();
      expect(find.text('Rs 80.00'), findsWidgets);
      await tester.ensureVisible(find.text('Complete Sale'));
      await tester.tap(find.text('Complete Sale'));
      await tester.pumpAndSettle();
      expect(find.text('Receipt INV-GLB-1001'), findsOneWidget);
      expect(find.text('DEMO — not a real receipt'), findsOneWidget);
      expect(find.text('Rs 120.00'), findsWidgets);
      expect(find.text('Rs 200.00'), findsOneWidget);
    });

    testWidgets('card sale completes; share copies, print notes on test',
        (WidgetTester tester) async {
      // Clipboard.setData has no platform handler in the test env and
      // its Future never completes there — mock the platform channel
      // so the Share action can finish (on a real device it works).
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (MethodCall call) async => null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await openPos(tester);
      await addPanadol(tester);
      await tester.ensureVisible(find.text('Card'));
      await tester.tap(find.text('Card'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Complete Sale'));
      await tester.tap(find.text('Complete Sale'));
      await tester.pumpAndSettle();
      expect(find.text('Receipt INV-GLB-1001'), findsOneWidget);
      // Print first: the Share SnackBar would overlay the buttons.
      await tester.ensureVisible(find.text('Print'));
      await tester.tap(find.text('Print'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Printing is available on the web demo — use Share to copy the receipt text.',
        ),
        findsOneWidget,
      );
      // Let the Print SnackBar expire — while it is up it overlays
      // the action buttons and the Share tap would hit it instead.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Share'));
      await tester.tap(find.text('Share'));
      await tester.pumpAndSettle();
      expect(
        find.text('Receipt text copied — share it from any app.'),
        findsOneWidget,
      );
    });

    testWidgets('completed sale appears in the sales history',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await openPos(tester);
      await addPanadol(tester);
      await tester.ensureVisible(find.text('Card'));
      await tester.tap(find.text('Card'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Complete Sale'));
      await tester.tap(find.text('Complete Sale'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sales history'));
      await tester.pumpAndSettle();
      expect(find.text('INV-GLB-1001'), findsOneWidget);
      expect(find.text('Rs 120.00'), findsOneWidget);
      await tester.tap(find.text('INV-GLB-1001'));
      await tester.pumpAndSettle();
      expect(find.text('Receipt INV-GLB-1001'), findsOneWidget);
    });

    testWidgets('POS blocks expired batches via the shared guard',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final fake = _FakeInventoryRepository([
        _batch(
          id: 'inv-fake-1',
          expiryDate: today.subtract(const Duration(days: 1)),
          batchNo: 'EXP-1',
        ),
        _batch(
          id: 'inv-fake-2',
          expiryDate: today.subtract(const Duration(days: 5)),
          batchNo: 'EXP-2',
        ),
        _batch(
          id: 'inv-fake-3',
          medicineId: 'med-risek-20',
          expiryDate: today.subtract(const Duration(days: 3)),
          batchNo: 'EXP-3',
        ),
        _batch(
          id: 'inv-fake-4',
          medicineId: 'med-risek-20',
          quantity: 20,
          expiryDate: today.add(const Duration(days: 200)),
          batchNo: 'FRESH-1',
        ),
      ]);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            inventoryRepositoryProvider.overrideWithValue(fake),
          ],
          child: const PharmaDeskApp(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 1500));
      await tester.pumpAndSettle();
      // Owner keeps the default DHA branch, which the fake rows use
      // (the Cashier's home branch is Gulberg — the fake rows would
      // be out of scope there).
      await signInAsDemoRole(tester, 'Owner');
      await tester.tap(
        find.descendant(
          of: find.byType(BottomNavigationBar),
          matching: find.text('Billing'),
        ),
      );
      await tester.pumpAndSettle();

      // Panadol: every batch expired -> blocked by the shared guard.
      await tester.enterText(find.byType(TextField).first, 'Panadol');
      await tester.pumpAndSettle();
      expect(
        find.text('All batches expired — never sellable'),
        findsOneWidget,
      );
      final expiredButton = tester.widget<PharmaButton>(
        find.byKey(const ValueKey('pos-add-med-panadol-extra')),
      );
      expect(expiredButton.onPressed, isNull);

      // Risek: one expired, one sellable FEFO batch -> addable, and
      // the sale completes and decrements the FEFO batch.
      await tester.enterText(find.byType(TextField).first, 'Risek');
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('pos-add-med-risek-20')),
      );
      await tester.tap(find.byKey(const ValueKey('pos-add-med-risek-20')));
      await tester.pumpAndSettle();
      expect(find.text('Cart (1)'), findsOneWidget);
      await tester.ensureVisible(find.text('Card'));
      await tester.tap(find.text('Card'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Complete Sale'));
      await tester.tap(find.text('Complete Sale'));
      await tester.pumpAndSettle();
      expect(find.text('Receipt INV-DHA-1001'), findsOneWidget);
      expect(fake.quantityOf('inv-fake-4'), 19);
      // The expired batch is never touched by the sale.
      expect(fake.quantityOf('inv-fake-3'), 20);
    });
  });

  group('Customers (widget)', () {
    Future<void> openCustomers(WidgetTester tester) async {
      // Tall viewport: the "More" sheet is 0.7 of the height, and all
      // 14 modules must be built for the "Customers" row to exist.
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await pumpAppToLogin(tester, const PharmaDeskApp());
      await signInAsDemoRole(tester, 'Owner');
      await tester.tap(find.text('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Customers'));
      await tester.pumpAndSettle();
      expect(find.text('Customers'), findsWidgets);
    }

    testWidgets('directory lists seeded customers with khata balances',
        (WidgetTester tester) async {
      await openCustomers(tester);
      expect(find.text('Ahmed Raza'), findsOneWidget);
      expect(find.text('Rs 5,500.00'), findsOneWidget);
      expect(find.text('Rs 12,000.00'), findsWidgets);
      expect(find.text('8 customer(s)'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, 'fatima');
      await tester.pumpAndSettle();
      expect(find.text('1 customer(s)'), findsOneWidget);
      expect(find.text('Fatima Khan'), findsOneWidget);
      expect(find.text('Ahmed Raza'), findsNothing);
    });

    testWidgets('add customer dialog validates and adds',
        (WidgetTester tester) async {
      await openCustomers(tester);
      await tester.tap(find.text('Add customer'));
      await tester.pumpAndSettle();
      // Scope to the dialog: the list's search field sits behind it
      // and would otherwise be TextField at(0).
      final dialogFields = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );
      await tester.enterText(dialogFields.at(0), 'New Person');
      await tester.enterText(dialogFields.at(1), '0300-9998877');
      await tester.tap(find.text('Add customer').last);
      await tester.pumpAndSettle();
      expect(find.text('Customer added.'), findsOneWidget);
      expect(find.text('New Person'), findsOneWidget);
      expect(find.text('9 customer(s)'), findsOneWidget);
    });

    testWidgets('add customer rejects a duplicate phone',
        (WidgetTester tester) async {
      await openCustomers(tester);
      await tester.tap(find.text('Add customer'));
      await tester.pumpAndSettle();
      final dialogFields = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );
      await tester.enterText(dialogFields.at(0), 'Copy Cat');
      await tester.enterText(dialogFields.at(1), '0300-1112233');
      await tester.tap(find.text('Add customer').last);
      await tester.pumpAndSettle();
      expect(
        find.textContaining(
          'A customer with this phone number already exists.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('detail shows khata; payment reduces outstanding',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await openCustomers(tester);
      await tester.ensureVisible(find.text('Ahmed Raza'));
      await tester.tap(find.text('Ahmed Raza'));
      await tester.pumpAndSettle();
      expect(find.text('Rs 5,500.00'), findsWidgets);
      expect(find.text('Credit (udhaar)'), findsWidgets);
      expect(find.text('Payment received'), findsWidgets);
      await tester.ensureVisible(find.text('Record payment'));
      await tester.tap(find.text('Record payment'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), '1000');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(
        find.text('Payment recorded against the khata.'),
        findsOneWidget,
      );
      expect(find.text('Rs 4,500.00'), findsWidgets);
    });

    testWidgets('detail rejects a payment above the outstanding',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await openCustomers(tester);
      await tester.ensureVisible(find.text('Ahmed Raza'));
      await tester.tap(find.text('Ahmed Raza'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Record payment'));
      await tester.tap(find.text('Record payment'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), '999999');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      // The error box prefixes each error with a bullet.
      expect(
        find.textContaining('Payment cannot exceed the outstanding balance.'),
        findsOneWidget,
      );
    });

    testWidgets('add credit increases the outstanding',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await openCustomers(tester);
      await tester.ensureVisible(find.text('Fatima Khan'));
      await tester.tap(find.text('Fatima Khan'));
      await tester.pumpAndSettle();
      expect(find.text('Rs 2,500.00'), findsWidgets);
      await tester.ensureVisible(find.text('Add credit (udhaar)'));
      await tester.tap(find.text('Add credit (udhaar)'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), '500');
      await tester.enterText(find.byType(TextField).at(1), 'Udhaar — test');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Credit added to the khata.'), findsOneWidget);
      expect(find.text('Rs 3,000.00'), findsWidgets);
    });
  });
}

/// Inventory repository with crafted rows, for the POS guard test:
/// Panadol's batches are all expired, Risek has one expired and one
/// sellable batch. Unlike the Day 5 fake, this one also supports
/// [adjustStock] so the sale can complete and the FEFO decrement can
/// be asserted.
class _FakeInventoryRepository implements InventoryRepository {
  _FakeInventoryRepository(List<InventoryItem> rows) : _rows = List.of(rows);

  final List<InventoryItem> _rows;

  int quantityOf(String batchId) =>
      _rows.firstWhere((row) => row.id == batchId).quantity;

  List<InventoryItem> _scoped(String? branchId) {
    if (branchId == null) return _rows;
    return _rows.where((item) => item.branchId == branchId).toList();
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
  }) async => throw UnimplementedError();

  @override
  Future<InventoryItem> adjustStock({
    required String batchId,
    required int deltaQty,
    required String reason,
  }) async {
    final index = _rows.indexWhere((item) => item.id == batchId);
    if (index == -1) throw ArgumentError('No batch with id "$batchId".');
    final old = _rows[index];
    final nextQty = old.quantity + deltaQty;
    if (nextQty < 0) {
      throw ArgumentError('Cannot remove $deltaQty units.');
    }
    final updated = old.copyWith(quantity: nextQty);
    _rows[index] = updated;
    return updated;
  }

  @override
  Future<InventoryItem> recordStockCount({
    required String batchId,
    required int countedQty,
    String? note,
  }) async => throw UnimplementedError();
}
