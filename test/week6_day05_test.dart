// Week 6 Day 5 tests — restore semantics (D169) + Phase 8 QA depth
// (D170, final day).
//
// - D169 (brief §7, closes the Week 5 follow-up): restore semantics
//   DECIDED — accepted as documented behaviour, NOT extended.
//   A restore only adds or replaces the documents in the backup; it
//   never deletes anything (records created after the export survive
//   it; a record that was in the backup comes back even if it was
//   deleted after the export — that corrects the brief's loose
//   parenthetical, which said the opposite). Counters are not
//   restored (rollup state, recomputed from the restored records)
//   and the sale payment legs are not restored (the sale doc carries
//   the total, method and cash received). The behaviour is stated in
//   plain language on the backup screen and in the confirm dialog.
//   The cross-backend edge was pinned here, not fixed: a mock-export
//   sale doc id differs from its idempotency key. Week 7 Day 3
//   (D173) fixed the restore side — the restore re-keys by
//   idempotencyKey — and updated the two assertions below that read
//   the restored sale back by its old mock id.
// - D170 (brief §8): 47-route walk re-run; 390px sweep over every
//   new/changed Week 6 screen + the Day 29 supplier-detail overflow
//   fix; finance agreement second pass over the newly guarded
//   finance writes (D161/D162); offline-queue + role-gate coverage
//   for every new Week 6 flow. The sweep uses a FlutterError trap,
//   not the D160 `takeException` drain — the drain undercounts: two
//   overflows in one pump collapse into one "Multiple exceptions"
//   string that contains no "RenderFlex overflowed" text at all
//   (proved by the harness test below, and by the supplier screen:
//   2 real overflows, D160-style count 0).

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:pharmadesk/core/data/audit_log.dart';
import 'package:pharmadesk/core/data/auth_repository.dart';
import 'package:pharmadesk/core/data/backup_export.dart';
import 'package:pharmadesk/core/data/firestore_schema.dart';
import 'package:pharmadesk/core/data/inventory_engine.dart';
import 'package:pharmadesk/core/data/permission_service.dart';
import 'package:pharmadesk/core/data/production_data_layer.dart';
import 'package:pharmadesk/core/data/report_counters.dart';
import 'package:pharmadesk/core/data/sync_queue.dart';
import 'package:pharmadesk/core/routing/app_router.dart';
import 'package:pharmadesk/core/services/branch_context.dart';
import 'package:pharmadesk/core/services/repositories.dart';
import 'package:pharmadesk/core/theme/app_theme.dart';
import 'package:pharmadesk/core/theme/white_label.dart';
import 'package:pharmadesk/features/authentication/auth_state.dart';
import 'package:pharmadesk/features/branches/branch_directory.dart';
import 'package:pharmadesk/features/finance/finance_logic.dart';
import 'package:pharmadesk/features/finance/finance_provider.dart';
import 'package:pharmadesk/features/inventory/inventory_provider.dart';
import 'package:pharmadesk/features/inventory/quarantine_outcome_queue.dart';
import 'package:pharmadesk/features/reports/analytics_logic.dart';
import 'package:pharmadesk/features/settings/org_settings.dart';
import 'package:pharmadesk/features/suppliers/supplier_logic.dart';
import 'package:pharmadesk/models/branch.dart';
import 'package:pharmadesk/models/cash_reconciliation.dart';
import 'package:pharmadesk/models/closing_correction.dart';
import 'package:pharmadesk/models/daily_closing.dart';
import 'package:pharmadesk/models/financial_transaction.dart';
import 'package:pharmadesk/models/quarantine_outcome_request.dart';
import 'package:pharmadesk/models/sale.dart';
import 'package:pharmadesk/models/supplier.dart';
import 'package:pharmadesk/models/supplier_payment.dart';

const _dha = 'branch-dha-main';
const _org = demoOrganizationId;
const _phoneSize = Size(390, 844);

DateTime _day(int daysAgo) {
  final now = DateTime.now();
  final day = now.subtract(Duration(days: daysAgo));
  return DateTime(day.year, day.month, day.day);
}

AppUser _userFor(
  String roleKey, {
  List<String> branchIds = const [_dha],
  String? uid,
}) {
  return AppUser(
    uid: uid ?? 'test-$roleKey',
    email: '$roleKey@test.pharmadesk',
    displayName: 'Test $roleKey',
    orgId: _org,
    branchIds: branchIds,
    roleKey: roleKey,
  );
}

class _FixedAuthNotifier extends AuthNotifier {
  _FixedAuthNotifier(this.user);

  final AppUser user;

  @override
  AppUser? build() => user;
}

class _MutableAuthNotifier extends AuthNotifier {
  _MutableAuthNotifier(this._user);

  AppUser? _user;

  set user(AppUser? value) {
    _user = value;
    state = value;
  }

  @override
  AppUser? build() => _user;
}

/// Production layer over fresh mocks, with the branch repo exposed
/// (same helper shape as the Week 6 Day 1 harness).
class _Harness {
  _Harness()
    : branchRepo = MockBranchRepository(),
      audit = InMemoryAuditLogWriter() {
    layer = ProductionDataLayer(
      organizationId: _org,
      inventoryRepo: MockInventoryRepository(),
      saleRepo: MockSaleRepository(),
      orderRepo: MockOrderRepository(),
      customerRepo: MockCustomerRepository(),
      medicineRepo: MockMedicineRepository(),
      supplierRepo: MockSupplierRepository(),
      prescriptionRepo: MockPrescriptionRepository(),
      purchaseOrderRepo: MockPurchaseOrderRepository(),
      riderRepo: MockRiderRepository(),
      branchRepo: branchRepo,
      audit: audit,
      syncQueue: SyncQueue(InMemorySyncStore()),
      engine: InventoryEngine(organizationId: _org, audit: audit),
    );
  }

  final MockBranchRepository branchRepo;
  final InMemoryAuditLogWriter audit;
  late final ProductionDataLayer layer;
}

Future<void> _deactivate(_Harness h, String branchId) async {
  final branch = await h.branchRepo.getById(branchId);
  await h.branchRepo.updateBranch(branch!.copyWith(active: false));
}

/// The seeded MedServe open payable (D92): Rs 48,250 outstanding
/// on `sled-2`. Returns allocations for a payment of [amountMinor].
Future<List<PaymentAllocation>> _medServeAllocations(
  _Harness h,
  int amountMinor,
) async {
  final ledger = await h.layer.supplierRepo.getLedgerEntries('sup-medserve');
  final open = openPayableBalances(supplierLedgerSignedEntries(ledger));
  return allocateSupplierPayment(open: open, paymentMinor: amountMinor);
}

Future<(ProviderContainer, GoRouter)> pumpRouterApp(
  WidgetTester tester, {
  Size size = const Size(1920, 1080),
  ProductionDataLayer? layerOverride,
  AppUser? user,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final container = ProviderContainer(
    overrides: [
      if (layerOverride != null)
        productionDataLayerProvider.overrideWithValue(layerOverride),
      if (user != null)
        authProvider.overrideWith(() => _FixedAuthNotifier(user)),
    ],
  );
  addTearDown(container.dispose);
  final router = createAppRouter(
    isSignedIn: user == null
        ? null
        : () => container.read(authProvider) != null,
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: AppTheme.light(BrandConfig.defaults),
        darkTheme: AppTheme.dark(BrandConfig.defaults),
        themeMode: ThemeMode.light,
        routerConfig: router,
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 1500));
  await tester.pumpAndSettle();
  return (container, router);
}

Future<(ProviderContainer, GoRouter)> pumpRouterAppAsRole(
  WidgetTester tester,
  String roleKey, {
  List<String> branchIds = const [_dha],
  Size size = const Size(1920, 1080),
}) async {
  return pumpRouterApp(
    tester,
    size: size,
    user: _userFor(roleKey, branchIds: branchIds),
  );
}

Future<(ProviderContainer, GoRouter, _MutableAuthNotifier)>
pumpRouterAppWithMutableAuth(
  WidgetTester tester,
  AppUser initialUser, {
  Size size = const Size(1920, 1080),
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final auth = _MutableAuthNotifier(initialUser);
  final container = ProviderContainer(
    overrides: [authProvider.overrideWith(() => auth)],
  );
  addTearDown(container.dispose);
  final router = createAppRouter(
    isSignedIn: () => container.read(authProvider) != null,
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: AppTheme.light(BrandConfig.defaults),
        darkTheme: AppTheme.dark(BrandConfig.defaults),
        themeMode: ThemeMode.light,
        routerConfig: router,
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 1500));
  await tester.pumpAndSettle();
  return (container, router, auth);
}

/// D170 — the overflow trap: counts every RenderFlex overflow the
/// FlutterError handler sees while the test runs.
///
/// The D160 helper (`takeException` + count "RenderFlex overflowed"
/// in the drained strings) UNDERCOUNTS: when two overflows arrive
/// in one pump without an acknowledgement in between, the binding
/// collapses them into a single "Multiple exceptions (2)..." string
/// whose text contains no "RenderFlex overflowed" at all — so the
/// D160 count reads 0 for a screen that really overflowed twice.
/// This trap records each error as the handler sees it (and still
/// forwards to the binding's handler, so `takeException` keeps
/// working and the test does not fail at teardown for an
/// unacknowledged exception).
class _OverflowTrap {
  _OverflowTrap() : _previous = FlutterError.onError {
    FlutterError.onError = (details) {
      _seen.add(details.toString());
      _previous?.call(details);
    };
  }

  // Inferred from `FlutterError.onError` (do not name the typedef:
  // it is not exported through material.dart).
  final dynamic _previous;
  final _seen = <String>[];

  int get overflowCount {
    // Count each DISTINCT overflow once: the framework re-reports
    // the same overflow on every pump that lays it out again, so a
    // raw report count would grow with the number of pump steps
    // (the cashbook dialog read 4 for one overflow). Two different
    // overflows have different RenderFlex identities in their
    // message, so distinct messages are distinct overflows.
    var count = 0;
    final distinct = <String>{
      for (final message in _seen)
        if (message.contains('RenderFlex overflowed')) message,
    };
    for (final message in distinct) {
      var from = 0;
      while (true) {
        final at = message.indexOf('RenderFlex overflowed', from);
        if (at == -1) break;
        count++;
        from = at + 1;
      }
    }
    return count;
  }

  void dispose() {
    FlutterError.onError = _previous;
  }
}

/// The D160 drain, kept only for the harness-proof test below:
/// `takeException` strings, counted the D160 way.
List<String> _drainExceptionsD160(WidgetTester tester) {
  final messages = <String>[];
  Object? error;
  while ((error = tester.takeException()) != null) {
    messages.add(error.toString());
  }
  return messages;
}

int _countOverflowsD160(List<String> drained) {
  var count = 0;
  for (final message in drained) {
    var from = 0;
    while (true) {
      final at = message.indexOf('RenderFlex overflowed', from);
      if (at == -1) break;
      count++;
      from = at + 1;
    }
  }
  return count;
}

/// Pumps the router app at phone width with the overflow trap
/// already installed, so every overflow the pump produces is
/// captured (D170 pattern — install BEFORE pumping).
Future<(ProviderContainer, GoRouter, _OverflowTrap)> _pumpSweepApp(
  WidgetTester tester,
  String roleKey, {
  List<String> branchIds = const [_dha],
}) async {
  final trap = _OverflowTrap();
  addTearDown(trap.dispose);
  final (container, router) = await pumpRouterAppAsRole(
    tester,
    roleKey,
    branchIds: branchIds,
    size: _phoneSize,
  );
  return (container, router, trap);
}

Sale _sale({
  required String id,
  String branchId = _dha,
  required SalePaymentMethod method,
  required int amountMinor,
  required DateTime createdAt,
}) {
  return Sale(
    id: id,
    invoiceNumber: 'INV-TEST-$id',
    branchId: branchId,
    cashierName: 'Test Cashier',
    items: const [],
    subtotalMinor: amountMinor,
    totalMinor: amountMinor,
    paymentMethod: method,
    payments: [SalePayment(method: method, amountMinor: amountMinor)],
    cashReceivedMinor: method == SalePaymentMethod.cash ? amountMinor : 0,
    idempotencyKey: 'sale-test-$id',
    createdAt: createdAt,
  );
}

DailyClosing _closing({String id = 'dc-1'}) {
  return DailyClosing(
    id: id,
    branchId: _dha,
    date: _day(0),
    totalIncomeMinor: 250000,
    totalExpenseMinor: 100000,
    openingBalanceMinor: 0,
    closingBalanceMinor: 150000,
    closedBy: 'test-owner',
    closedAt: DateTime.now(),
  );
}

ClosingCorrection _correction({String originalId = 'dc-1'}) {
  return ClosingCorrection(
    id: '',
    branchId: _dha,
    originalClosingId: originalId,
    date: _day(0),
    correctedIncomeMinor: 200000,
    correctedExpenseMinor: 100000,
    correctedClosingBalanceMinor: 100000,
    reason: 'Income entered twice',
    correctedBy: 'test-owner',
    correctedAt: DateTime.now(),
  );
}

CashReconciliation _reconciliation() {
  return CashReconciliation(
    id: '',
    branchId: _dha,
    date: _day(0),
    expectedMinor: 50000,
    countedMinor: 50000,
    differenceMinor: 0,
    countedBy: 'test-owner',
    countedAt: DateTime.now(),
  );
}

void main() {
  group('D169 — restore semantics: decided, stated plainly', () {
    test('restore does not delete: a record created after the export '
        'survives the restore untouched', () async {
      final h = _Harness();
      final backup = await h.layer.exportBackup();
      // A supplier added AFTER the export is in no backup section.
      final added = await h.layer.supplierRepo.createSupplier(
        const Supplier(
          id: '',
          name: 'Post Export Supplier',
          contactPerson: 'After Export',
          phone: '0300-1112223',
        ),
      );
      expect(added.id, isNotEmpty);
      final report = await h.layer.importBackup(
        backup,
        policy: ImportPolicy.overwrite,
      );
      expect(report.errors, isEmpty);
      // The restore only adds/replaces backup docs — it never
      // deletes live work done after the export.
      final kept = await h.layer.supplierRepo.getById(added.id);
      expect(kept, isNotNull);
      expect(kept!.name, 'Post Export Supplier');
      expect(kept.phone, '0300-1112223');
    });

    test('restore upserts: a record edited after the export reverts '
        'to the backup value', () async {
      final h = _Harness();
      final backup = await h.layer.exportBackup();
      final before = await h.layer.medicineRepo.getById(
        'med-panadol-extra',
      );
      expect(before!.name, 'Panadol Extra');
      await h.layer.medicineRepo.updateMedicine(
        before.copyWith(name: 'Panadol Extra RENAMED'),
      );
      expect(
        (await h.layer.medicineRepo.getById('med-panadol-extra'))!.name,
        'Panadol Extra RENAMED',
      );
      final report = await h.layer.importBackup(
        backup,
        policy: ImportPolicy.overwrite,
      );
      expect(report.errors, isEmpty);
      expect(
        (await h.layer.medicineRepo.getById('med-panadol-extra'))!.name,
        'Panadol Extra',
      );
      expect(report.overwritten, greaterThan(0));
    });

    test('restore recreates a missing doc: a record that was in the '
        'backup comes back even if it was absent live', () async {
      // This corrects the brief §7 parenthetical ("records deleted
      // after export do not come back"): under the D150 upsert-by-id
      // semantics, a doc that IS in the backup is re-created on
      // import — the restore cannot know it was deleted. What the
      // restore never does is DELETE a live record.
      final source = _Harness();
      final sale = await source.layer.saleRepo.createSale(
        Sale(
          id: '',
          invoiceNumber: '',
          branchId: _dha,
          cashierName: 'Test Cashier',
          items: const [],
          subtotalMinor: 1000000,
          totalMinor: 1000000,
          paymentMethod: SalePaymentMethod.cash,
          payments: const [
            SalePayment(
              method: SalePaymentMethod.cash,
              amountMinor: 1000000,
            ),
          ],
          cashReceivedMinor: 1000000,
          idempotencyKey: 'sale-d169-recreate-1',
          createdAt: _day(0).add(const Duration(hours: 10)),
        ),
      );
      final backup = await source.layer.exportBackup();
      // A fresh layer has no such sale (its sale repo starts empty)
      // — importing recreates it from the backup.
      final fresh = _Harness();
      expect(await fresh.layer.saleRepo.getById(sale.id), isNull);
      expect(
        await fresh.layer.saleRepo.getById('sale-d169-recreate-1'),
        isNull,
      );
      final report = await fresh.layer.importBackup(
        backup,
        policy: ImportPolicy.overwrite,
      );
      expect(report.errors, isEmpty);
      expect(report.created, greaterThan(0));
      // D173: the recreated sale comes back under its
      // idempotencyKey, not the mock id it was committed with.
      expect(await fresh.layer.saleRepo.getById(sale.id), isNull);
      final restored =
          await fresh.layer.saleRepo.getById('sale-d169-recreate-1');
      expect(restored, isNotNull);
      expect(restored!.id, 'sale-d169-recreate-1');
      expect(restored.totalMinor, 1000000);
      expect(restored.idempotencyKey, 'sale-d169-recreate-1');
    });

    test('the export has no counters section and no salePayments '
        'section', () async {
      final h = _Harness();
      final backup = await h.layer.exportBackup();
      final sections = backup['sections'] as Map;
      expect(sections.containsKey('counters'), isFalse);
      expect(sections.containsKey('inventoryCounters'), isFalse);
      expect(sections.containsKey('salePayments'), isFalse);
      // The sections that DO exist are the repo sections (+ the
      // sink-only audit/sync sections).
      expect(
        sections.keys,
        containsAll([
          'medicines',
          'suppliers',
          'supplierLedger',
          'orders',
          'sales',
          'inventory',
          'customers',
          'customerLedger',
          'branches',
          'auditLogs',
          'syncQueue',
        ]),
      );
    });

    test('split-payment sale round-trips with both legs; the export '
        'sale id differs from its idempotency key (cross-backend '
        'edge, pinned not fixed)', () async {
      final source = _Harness();
      final saved = await source.layer.saleRepo.createSale(
        Sale(
          id: '',
          invoiceNumber: '',
          branchId: _dha,
          cashierName: 'Test Cashier',
          items: const [],
          subtotalMinor: 1000000,
          totalMinor: 1000000,
          paymentMethod: SalePaymentMethod.cash,
          payments: const [
            SalePayment(method: SalePaymentMethod.cash, amountMinor: 600000),
            SalePayment(method: SalePaymentMethod.card, amountMinor: 400000),
          ],
          cashReceivedMinor: 600000,
          idempotencyKey: 'sale-d169-split-1',
          createdAt: _day(0).add(const Duration(hours: 10)),
        ),
      );
      // The mock assigns its own id (`sale-DHA-…`); the key stays
      // the client key — they differ in the EXPORT. Week 7 Day 3
      // (D173) fixed the restore side: the restore re-keys by
      // idempotencyKey, so a mock export restored into any layer
      // lands under the key, not the mock id (the D53 / rules
      // invariant). The export itself is unchanged — it still
      // carries the mock id — only the restore re-keys.
      expect(saved.id, isNot('sale-d169-split-1'));
      expect(saved.idempotencyKey, 'sale-d169-split-1');
      final backup = await source.layer.exportBackup();
      final sections = backup['sections'] as Map;
      final sales = sections['sales'] as List;
      final exported =
          (sales.firstWhere((doc) => doc['id'] == saved.id)
                  as Map<String, dynamic>);
      expect(exported['id'], isNot(exported['idempotencyKey']));
      // The legs travel INSIDE the sale doc (the mock's `toMap`
      // carries the `payments` list) — that is what survives a
      // restore. The Firestore `payments` subcollection is a
      // separate mirror and is not part of the backup.
      final legs = exported['payments'] as List;
      expect(legs, hasLength(2));
      expect(
        legs.map((leg) => leg['amount']),
        containsAll([600000, 400000]),
      );
      // Round-trip into a fresh layer: both legs intact, under the
      // KEY (D173) — the old mock id no longer lands.
      final fresh = _Harness();
      final report = await fresh.layer.importBackup(
        backup,
        policy: ImportPolicy.overwrite,
      );
      expect(report.errors, isEmpty);
      expect(await fresh.layer.saleRepo.getById(saved.id), isNull);
      final restored =
          await fresh.layer.saleRepo.getById('sale-d169-split-1');
      expect(restored, isNotNull);
      expect(restored!.id, 'sale-d169-split-1');
      expect(restored.payments, hasLength(2));
      expect(
        restored.payments.map((leg) => leg.amountMinor),
        containsAll([600000, 400000]),
      );
      expect(restored.totalMinor, 1000000);
      expect(restored.cashReceivedMinor, 600000);
    });

    test('counters are not restored: a batch row reverts, and the '
        'derived daily counter follows the restored sale', () async {
      final source = _Harness();
      final batch = (await source.layer.inventoryRepo.getInventory(
        branchId: _dha,
      )).firstWhere((item) => item.medicineId == 'med-panadol-extra');
      final saved = await source.layer.saleRepo.createSale(
        Sale(
          id: '',
          invoiceNumber: '',
          branchId: _dha,
          cashierName: 'Test Cashier',
          items: const [],
          subtotalMinor: 1000000,
          totalMinor: 1000000,
          paymentMethod: SalePaymentMethod.cash,
          payments: const [
            SalePayment(
              method: SalePaymentMethod.cash,
              amountMinor: 1000000,
            ),
          ],
          cashReceivedMinor: 1000000,
          idempotencyKey: 'sale-d169-counter-1',
          createdAt: _day(0).add(const Duration(hours: 10)),
        ),
      );
      // D173: the mock id differs from the key in the export; the
      // restore lands the sale under the key.
      expect(saved.id, isNot('sale-d169-counter-1'));
      final backup = await source.layer.exportBackup();
      final fresh = _Harness();
      // Baseline derived counters for the fresh layer (seeded
      // orders only, no sales yet).
      Future<List<DailyCounter>> countersOf(ProductionDataLayer layer) async {
        return computeDailyCounters(
          orders: await layer.orderRepo.getOrders(),
          sales: await layer.saleRepo.getSales(),
          returns: const [],
          inventory: await layer.inventoryRepo.getInventory(),
          branchId: _dha,
          now: DateTime.now(),
        );
      }

      final todayCounterBefore =
          (await countersOf(fresh.layer)).lastWhere(
            (counter) =>
                counter.date.year == DateTime.now().year &&
                counter.date.month == DateTime.now().month &&
                counter.date.day == DateTime.now().day,
          );
      // Move a batch row away from its exported quantity, then
      // restore: the ROW reverts (upsert), because rows are in
      // the backup — but no counter doc is ever written back.
      final moved = await fresh.layer.inventoryRepo.upsertInventoryItem(
        batch.copyWith(quantity: batch.quantity + 50),
      );
      expect(moved.quantity, batch.quantity + 50);
      final report = await fresh.layer.importBackup(
        backup,
        policy: ImportPolicy.overwrite,
      );
      expect(report.errors, isEmpty);
      final reverted = (await fresh.layer.inventoryRepo.getInventory(
        branchId: _dha,
      )).firstWhere((item) => item.id == batch.id);
      expect(reverted.quantity, batch.quantity);
      // The restored sale is in the fresh layer now, and the
      // DERIVED counter follows it — today's counter moves by
      // exactly the restored sale, with no counter restored from
      // the backup (there is no counters section to restore).
      // D173: the restored sale lives under its key now, not its
      // old mock id.
      expect(
        await fresh.layer.saleRepo.getById('sale-d169-counter-1'),
        isNotNull,
      );
      final todayCounterAfter = (await countersOf(fresh.layer)).lastWhere(
        (counter) =>
            counter.date.year == DateTime.now().year &&
            counter.date.month == DateTime.now().month &&
            counter.date.day == DateTime.now().day,
      );
      expect(
        todayCounterAfter.salesTotalMinor -
            todayCounterBefore.salesTotalMinor,
        1000000,
      );
    });

    testWidgets('backup screen states the restore limits in plain '
        'language at 390px', (tester) async {
      final (_, router, trap) = await _pumpSweepApp(tester, 'owner');
      router.go('/backup');
      await tester.pumpAndSettle();
      expect(find.text('Backup & Restore'), findsWidgets);
      expect(find.text('What restore does NOT do'), findsOneWidget);
      expect(
        find.textContaining('Restore never deletes anything.'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Counters are not restored.'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Split-payment legs are not restored.'),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'A record that was in the backup comes back even if it was '
          'deleted after the export.',
        ),
        findsOneWidget,
      );
      expect(trap.overflowCount, 0);
    });

    testWidgets('restore confirm dialog states the limits before '
        'anything is written', (tester) async {
      // A minimal well-formed backup: the dialog only needs valid
      // structure (validation runs before any write, and the test
      // cancels before importing).
      final json = jsonEncode({
        'format': 'pharmadesk-backup',
        'formatVersion': 1,
        'exportedAt': DateTime.now().toIso8601String(),
        'organizationId': _org,
        'sections': {
          'medicines': [],
        },
      });
      final (_, router, trap) = await _pumpSweepApp(tester, 'owner');
      router.go('/backup');
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byType(TextField).first);
      await tester.enterText(find.byType(TextField).first, json);
      await tester.tap(
        find.byKey(const ValueKey('restore-validate-button')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Restore this backup?'), findsOneWidget);
      expect(
        find.textContaining('Records that are not in the backup are '
            'left untouched'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Counters and split-payment legs are not '
            'restored'),
        findsOneWidget,
      );
      // Cancel: nothing is imported.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Restore this backup?'), findsNothing);
      expect(trap.overflowCount, 0);
    });
  });

  group('Phase 8 — route walk: every route resolves (Week 6 re-run)', () {
    testWidgets('Week 6 routes + finance / system hub routes resolve', (
      tester,
    ) async {
      final (_, router) = await pumpRouterApp(
        tester,
        size: const Size(1280, 800),
      );
      const routes = <(String, String)>[
        ('/inventory/adjustments', 'Adjustment Approvals'),
        ('/inventory/quarantine-outcomes', 'Quarantine Outcomes'),
        ('/finance/franchise', 'Franchise Royalties'),
        ('/finance', 'Finance'),
        ('/finance/cashbook', 'Cashbook'),
        ('/finance/aging', 'Payables & Receivables'),
        ('/finance/statements', 'P&L & Statements'),
        ('/branches', 'Branch Management'),
        ('/branches/branch-dha-main', 'Demo Branch — DHA'),
        ('/audit-log', 'Audit Log'),
        ('/backup', 'Backup & Restore'),
      ];
      for (final (route, marker) in routes) {
        router.go(route);
        await tester.pumpAndSettle();
        expect(
          find.textContaining('coming Week 1'),
          findsNothing,
          reason: 'Placeholder left on $route',
        );
        expect(
          find.text('Page not found'),
          findsNothing,
          reason: 'Missing route $route',
        );
        expect(
          find.text(marker),
          findsWidgets,
          reason: '$route should render its screen ($marker)',
        );
      }
    });

    testWidgets('full route walk: every route in the router resolves', (
      tester,
    ) async {
      final (container, router) = await pumpRouterApp(
        tester,
        size: const Size(1280, 800),
      );
      final orders = await container.read(orderRepositoryProvider).getOrders();
      final orderId = orders.first.id;
      final customer = await container
          .read(customerRepositoryProvider)
          .getById('cust-1');
      final supplier = await container
          .read(supplierRepositoryProvider)
          .getById('sup-sami');
      // Week 6 added NO routes (brief §1–§7 are guards, keys,
      // model fields and restore text on existing screens), so the
      // walk is the same 47 shell routes as Day 27 — the count is
      // asserted, not assumed.
      final routes = <(String, String?)>[
        ('/dashboard', 'Top-selling medicines'),
        ('/profile', 'Profile'),
        ('/orders', 'Orders'),
        ('/orders/new', 'New Order'),
        ('/orders/$orderId/edit', 'Edit order $orderId'),
        ('/orders/$orderId', 'Customer'),
        ('/medicines', 'Medicines'),
        ('/medicines/med-panadol-extra', 'Panadol Extra'),
        ('/inventory', 'Inventory'),
        ('/inventory/transfers', 'Stock Transfers'),
        ('/inventory/transfers/new', 'New Transfer'),
        ('/inventory/transfers/tr-demo-1', 'TR-DHA-GLB-1001'),
        ('/inventory/adjustments', 'Adjustment Approvals'),
        ('/inventory/quarantine-outcomes', 'Quarantine Outcomes'),
        ('/riders', 'Riders & Delivery'),
        ('/riders/rider-1', 'Bilal Ahmed'),
        ('/billing', 'Billing & POS'),
        ('/billing/history', 'Sales history'),
        ('/billing/returns', 'Returns & refunds'),
        ('/billing/returns/new', 'New return'),
        ('/billing/receipt/sale-missing', 'Sale not found'),
        ('/customers', 'Customers'),
        ('/customers/cust-1', customer!.name),
        ('/suppliers', 'Suppliers'),
        ('/suppliers/sup-sami', supplier!.name),
        ('/purchases', 'Purchases'),
        ('/purchases/new', 'New purchase order'),
        ('/purchases/auto', 'Auto Purchase List'),
        ('/purchases/po-dha-1001', 'PO-DHA-1001'),
        ('/prescriptions', 'Prescriptions'),
        ('/prescriptions/rx-dha-1', 'rx-dha-1'),
        ('/reports', 'Daily sales'),
        ('/finance', 'Finance'),
        ('/finance/cashbook', 'Cashbook'),
        ('/finance/aging', 'Payables & Receivables'),
        ('/finance/statements', 'P&L & Statements'),
        ('/finance/franchise', 'Franchise Royalties'),
        ('/staff', 'Staff & HR'),
        ('/staff/attendance', 'Attendance'),
        ('/staff/shifts', 'Shifts'),
        ('/staff/salary', 'Monthly total'),
        ('/notifications', 'Notifications'),
        ('/settings', 'Settings'),
        ('/branches', 'Branch Management'),
        ('/branches/branch-dha-main', 'Demo Branch — DHA'),
        ('/audit-log', 'Audit Log'),
        ('/backup', 'Backup & Restore'),
      ];
      expect(routes, hasLength(47));
      for (final (route, marker) in routes) {
        router.go(route);
        await tester.pumpAndSettle();
        expect(
          find.textContaining('coming Week 1'),
          findsNothing,
          reason: 'Placeholder left on $route',
        );
        expect(
          find.text('Page not found'),
          findsNothing,
          reason: 'Missing route $route',
        );
        if (marker != null) {
          expect(
            find.textContaining(marker),
            findsWidgets,
            reason: '$route should render its screen ($marker)',
          );
        }
      }
    });
  });

  group('Phase 8 — 390px sweep: Week 6 new / changed screens (D170)', () {
    testWidgets('supplier detail screen fits at 390px after the fix '
        '(Day 29 follow-up)', (tester) async {
      final (_, router, trap) = await _pumpSweepApp(tester, 'owner');
      router.go('/suppliers/sup-sami');
      await tester.pumpAndSettle();
      expect(find.textContaining('Sami'), findsWidgets);
      expect(find.text('Payable aging'), findsOneWidget);
      expect(find.text('Export statement (CSV)'), findsOneWidget);
      // The two pre-existing overflows are gone: the aging badges
      // (63px — the StatusBadge label now wraps) and the
      // Export-statement row (0.2px — the button is Expanded and
      // its label Flexible).
      expect(trap.overflowCount, 0);
    });

    testWidgets('supplier detail with a large payable fits at 390px',
        (tester) async {
      // MedServe carries the largest seeded payable (Rs 48,250);
      // its 90+ day badge is the widest aging label.
      final (_, router, trap) = await _pumpSweepApp(tester, 'owner');
      router.go('/suppliers/sup-medserve');
      await tester.pumpAndSettle();
      expect(find.text('MedServe Distributors'), findsWidgets);
      expect(find.text('Payable aging'), findsOneWidget);
      expect(trap.overflowCount, 0);
    });

    testWidgets('cashbook entry dialog in income mode fits at 390px '
        '(Day 29 fix re-verified)', (tester) async {
      final (_, router, trap) = await _pumpSweepApp(tester, 'owner');
      router.go('/finance/cashbook');
      await tester.pumpAndSettle();
      expect(find.text('Cashbook'), findsOneWidget);
      await tester.tap(find.text('Add entry'));
      await tester.pumpAndSettle();
      expect(find.text('Add cashbook entry'), findsOneWidget);
      // Income mode: the long first category ('Owner
      // contribution') overflowed 87px before the Day 29
      // `isExpanded` fix.
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Income'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Owner contribution'), findsOneWidget);
      expect(trap.overflowCount, 0);
    });

    testWidgets('Reports expense dialog fits at 390px', (tester) async {
      final (_, router, trap) = await _pumpSweepApp(tester, 'owner');
      router.go('/reports');
      await tester.pumpAndSettle();
      expect(find.text('Daily sales'), findsWidgets);
      await tester.ensureVisible(find.text('Record expense'));
      await tester.tap(find.text('Record expense'));
      await tester.pumpAndSettle();
      expect(find.text('Record expense'), findsWidgets);
      expect(trap.overflowCount, 0);
    });

    testWidgets('supplier payment dialog fits at 390px', (tester) async {
      final (_, router, trap) = await _pumpSweepApp(tester, 'owner');
      router.go('/suppliers/sup-medserve');
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Record payment'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Record payment'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Record payment'),
        ),
        findsOneWidget,
      );
      expect(trap.overflowCount, 0);
    });

    testWidgets('add-branch form with the code field fits at 390px',
        (tester) async {
      final (_, router, trap) = await _pumpSweepApp(tester, 'owner');
      router.go('/branches');
      await tester.pumpAndSettle();
      expect(find.text('Branch Management'), findsWidgets);
      await tester.tap(find.text('Add branch').last);
      await tester.pumpAndSettle();
      expect(find.text('Add branch'), findsWidgets);
      expect(
        find.byKey(const ValueKey('branch-code-field')),
        findsOneWidget,
      );
      // An invalid code shows its error inline (on save) without
      // overflowing.
      await tester.enterText(
        find.byKey(const ValueKey('branch-code-field')),
        'A',
      );
      await tester.tap(
        find
            .descendant(
              of: find.byType(AlertDialog),
              matching: find.text('Add branch'),
            )
            .last,
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Branch code must be 2–8 uppercase'),
        findsOneWidget,
      );
      expect(trap.overflowCount, 0);
    });

    testWidgets('POS tax dropdown fits at 390px, open and picked',
        (tester) async {
      final (_, router, trap) = await _pumpSweepApp(tester, 'cashier');
      router.go('/billing');
      await tester.pumpAndSettle();
      expect(find.text('Billing & POS'), findsWidgets);
      await tester.ensureVisible(find.text('Add').first);
      await tester.tap(find.text('Add').first);
      await tester.pumpAndSettle();
      expect(find.text('Cart (1)'), findsOneWidget);
      final dropdown = find.byKey(const ValueKey('pos-tax-dropdown'));
      await tester.ensureVisible(dropdown);
      await tester.pumpAndSettle();
      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      expect(find.text('5%'), findsWidgets);
      await tester.tap(find.text('5%').last);
      await tester.pumpAndSettle();
      expect(tester.widget<DropdownButton<int>>(dropdown).value, 5);
      expect(find.text('Tax (5%)'), findsOneWidget);
      expect(trap.overflowCount, 0);
    });

    testWidgets('medicine edit with a duplicate barcode shows the '
        'rejection at 390px', (tester) async {
      final (container, router, trap) = await _pumpSweepApp(
        tester,
        'owner',
      );
      final medicines = await container
          .read(medicineRepositoryProvider)
          .getMedicines();
      final first = medicines.firstWhere(
        (m) => m.id == 'med-panadol-extra',
      );
      final other = medicines.firstWhere((m) => m.id != first.id);
      expect(other.barcode, isNotEmpty);
      router.go('/medicines/med-panadol-extra');
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('medicine-edit')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('medicine-edit')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('medicine-barcode-field')),
        other.barcode!,
      );
      await tester.tap(find.byKey(const ValueKey('medicine-edit-save')));
      await tester.pumpAndSettle();
      // The D166 repo rejection surfaces inline; the dialog stays
      // open and nothing is written.
      expect(find.textContaining('already used by'), findsOneWidget);
      expect(find.byKey(const ValueKey('medicine-edit-save')), findsOneWidget);
      expect(
        (await container
                .read(medicineRepositoryProvider)
                .getById(first.id))!
            .barcode,
        first.barcode,
      );
      expect(trap.overflowCount, 0);
    });
  });

  group('Phase 8 — 390px sweep: D160 screens re-run with the '
      'corrected counter (D170)', () {
    testWidgets('branch shelf dialog fits at 390px', (tester) async {
      final (_, router, trap) = await _pumpSweepApp(tester, 'owner');
      router.go('/medicines/med-panadol-extra');
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('medicine-branch-shelf')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('medicine-branch-shelf')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('branch-rack-field')), findsOneWidget);
      expect(trap.overflowCount, 0);
    });

    testWidgets('quarantine outcomes queue (populated) fits at 390px',
        (tester) async {
      final (container, router, trap) = await _pumpSweepApp(
        tester,
        'inventory_manager',
      );
      final batch = (await container
              .read(inventoryRepositoryProvider)
              .getInventory(branchId: _dha))
          .firstWhere((item) => item.medicineId == 'med-panadol-extra');
      final parked = await container
          .read(inventoryProvider.notifier)
          .quarantineBatch(batchId: batch.id, reason: 'Suspected damage');
      expect(parked, isNotNull);
      final request = await container
          .read(quarantineOutcomeQueueProvider.notifier)
          .requestOutcome(
            batch: parked!,
            medicineName: 'Panadol Extra',
            outcome: QuarantineOutcome.dispose,
            reason: 'Damaged beyond use',
          );
      expect(request, isNotNull);
      router.go('/inventory/quarantine-outcomes');
      await tester.pumpAndSettle();
      expect(find.text('Quarantine Outcomes'), findsOneWidget);
      expect(find.textContaining('Panadol Extra'), findsWidgets);
      expect(trap.overflowCount, 0);
    });

    testWidgets('POS with cash disabled fits at 390px', (tester) async {
      final (container, router, trap) = await _pumpSweepApp(
        tester,
        'cashier',
      );
      container
          .read(orgSettingsProvider.notifier)
          .togglePaymentMethod(OrgPaymentMethod.cash, false);
      router.go('/billing');
      await tester.pumpAndSettle();
      expect(find.text('Billing & POS'), findsOneWidget);
      expect(find.text('Cash'), findsNothing);
      expect(find.text('Card'), findsOneWidget);
      expect(find.text('Credit (khata)'), findsOneWidget);
      expect(trap.overflowCount, 0);
    });

    testWidgets('cashbook with correction + reconciliation fits at 390px',
        (tester) async {
      final (container, router, trap) = await _pumpSweepApp(tester, 'owner');
      await container.read(expensesProvider.notifier).recordExpense(
        branchId: _dha,
        category: 'Supplies',
        amountMinor: 10000,
        description: 'Today supplies',
        expenseDate: _day(0),
      );
      await container
          .read(financialTransactionsProvider.notifier)
          .recordIncome(
            branchId: _dha,
            category: 'Other income',
            amountMinor: 25000,
            date: _day(0),
          );
      final closed = await container
          .read(dailyClosingsProvider.notifier)
          .closeDay(branchId: _dha, date: _day(0));
      expect(closed.error, isNull);
      final original = closed.closing!;
      final corrected = await container
          .read(closingCorrectionsProvider.notifier)
          .correctClosing(
            original: original,
            correctedIncomeMinor: 20000,
            correctedExpenseMinor: 10000,
            reason: 'Income was Rs 200, not Rs 250',
          );
      expect(corrected.error, isNull);
      final reconciled = await container
          .read(cashReconciliationsProvider.notifier)
          .reconcileDay(
            branchId: _dha,
            date: _day(0),
            countedMinor: 15000,
            note: 'Counted exact',
          );
      expect(reconciled.error, isNull);
      router.go('/finance/cashbook');
      await tester.pumpAndSettle();
      expect(find.text('Cashbook'), findsOneWidget);
      expect(find.textContaining('Corrected:'), findsOneWidget);
      expect(find.textContaining('Expected'), findsWidgets);
      final correctKey = ValueKey('correct-closing-${original.id}');
      await tester.ensureVisible(find.byKey(correctKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(correctKey));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('correct-income-field')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('correct-reason-field')),
        findsOneWidget,
      );
      expect(trap.overflowCount, 0);
    });

    testWidgets('franchise view with configured rates fits at 390px',
        (tester) async {
      final (container, router, trap) = await _pumpSweepApp(tester, 'owner');
      final errors = await container
          .read(branchDirectoryProvider.notifier)
          .addBranch(
            const Branch(
              id: 'branch-franchise-1',
              name: 'Franchise — Model Town',
              address: 'Model Town, Lahore',
              phone: '0300-3333333',
              type: 'franchise',
              royaltyRateBps: 500,
              franchiseFeeRateBps: 200,
            ),
          );
      expect(errors, isEmpty);
      await container.read(saleRepositoryProvider).upsertSale(
        _sale(
          id: 'sale-fran-1',
          branchId: 'branch-franchise-1',
          method: SalePaymentMethod.cash,
          amountMinor: 1000000,
          createdAt: _day(0).add(const Duration(hours: 10)),
        ),
      );
      router.go('/finance/franchise');
      await tester.pumpAndSettle();
      expect(find.text('Franchise Royalties'), findsOneWidget);
      expect(find.text('Franchise — Model Town'), findsOneWidget);
      expect(find.text('Rs 500.00'), findsWidgets);
      expect(find.text('Rs 700.00'), findsWidgets);
      expect(trap.overflowCount, 0);
    });

    testWidgets('aging screen fits at 390px', (tester) async {
      final (_, router, trap) = await _pumpSweepApp(tester, 'owner');
      router.go('/finance/aging');
      await tester.pumpAndSettle();
      expect(find.text('Payables & Receivables'), findsOneWidget);
      expect(find.text('Supplier payables'), findsOneWidget);
      expect(trap.overflowCount, 0);
    });

    testWidgets('statements screen fits at 390px', (tester) async {
      final (_, router, trap) = await _pumpSweepApp(tester, 'owner');
      router.go('/finance/statements');
      await tester.pumpAndSettle();
      expect(find.text('P&L & Statements'), findsOneWidget);
      expect(trap.overflowCount, 0);
    });
  });

  group('Phase 8 — finance agreement, second pass over the newly '
      'guarded writes (D161/D162)', () {
    Future<ProfitLoss> plFromRepos(
      ProductionDataLayer layer, {
      int days = 30,
    }) async {
      return computeProfitAndLoss(
        orders: await layer.orderRepo.getOrders(),
        sales: await layer.saleRepo.getSales(),
        returns: const [],
        inventory: const [],
        expenses: await layer.expenseRepo.getExpenses(branchId: _dha),
        transactions: await layer.financialTransactionRepo.getTransactions(
          branchId: _dha,
        ),
        branchId: _dha,
        now: DateTime.now(),
        days: days,
      );
    }

    Future<({int incomeMinor, int expenseMinor})> cashbookSums(
      ProductionDataLayer layer,
    ) async {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final start = today.subtract(const Duration(days: 29));
      final entries = cashbookEntries(
        expenses: await layer.expenseRepo.getExpenses(branchId: _dha),
        transactions: await layer.financialTransactionRepo.getTransactions(
          branchId: _dha,
        ),
        branchId: _dha,
      );
      var income = 0;
      var expense = 0;
      for (final entry in entries) {
        final day = DateTime(
          entry.date.year,
          entry.date.month,
          entry.date.day,
        );
        if (day.isBefore(start) || day.isAfter(today)) continue;
        if (entry.kind == CashbookEntryKind.income) {
          income += entry.amountMinor;
        } else {
          expense += entry.amountMinor;
        }
      }
      return (incomeMinor: income, expenseMinor: expense);
    }

    Future<int> mirrorExpenseTxns(
      ProductionDataLayer layer,
      int amountMinor,
    ) async {
      final txns = await layer.financialTransactionRepo.getTransactions(
        branchId: _dha,
      );
      return txns
          .where(
            (txn) =>
                txn.type == FinancialTransactionType.expense &&
                txn.amountMinor == -amountMinor,
          )
          .length;
    }

    test('guarded expense + income move the cashbook and the P&L by '
        'exactly their amounts; an idempotent replay moves nothing',
        () async {
      final h = _Harness();
      final sumsBefore = await cashbookSums(h.layer);
      await h.layer.recordExpense(
        branchId: _dha,
        category: 'Utilities',
        amountMinor: 500000,
        description: 'Electricity bill (guarded)',
        expenseDate: _day(0),
        createdBy: 'test-owner',
        idempotencyKey: 'agreement2-expense-1',
      );
      await h.layer.recordIncome(
        branchId: _dha,
        category: 'Other income',
        amountMinor: 250000,
        date: _day(0),
        createdBy: 'test-owner',
        idempotencyKey: 'agreement2-income-1',
      );
      final sums = await cashbookSums(h.layer);
      expect(sums.incomeMinor - sumsBefore.incomeMinor, 250000);
      expect(sums.expenseMinor - sumsBefore.expenseMinor, 500000);
      final pl = await plFromRepos(h.layer);
      expect(pl.otherIncomeMinor, sums.incomeMinor);
      expect(pl.expensesMinor, sums.expenseMinor);
      expect(
        pl.netProfitMinor,
        pl.grossProfitMinor + pl.otherIncomeMinor - pl.expensesMinor,
      );
      // Exactly one mirror transaction for the expense (type
      // `expense`, −500,000) — the cashbook shows one expense line.
      expect(await mirrorExpenseTxns(h.layer, 500000), 1);
      // Idempotent replay of both keys: the originals come back,
      // and no sum, no P&L field and no mirror moves again.
      await h.layer.recordExpense(
        branchId: _dha,
        category: 'Utilities',
        amountMinor: 500000,
        description: 'Electricity bill (guarded)',
        expenseDate: _day(0),
        createdBy: 'test-owner',
        idempotencyKey: 'agreement2-expense-1',
      );
      await h.layer.recordIncome(
        branchId: _dha,
        category: 'Other income',
        amountMinor: 250000,
        date: _day(0),
        createdBy: 'test-owner',
        idempotencyKey: 'agreement2-income-1',
      );
      final sumsAfterReplay = await cashbookSums(h.layer);
      expect(sumsAfterReplay.incomeMinor, sums.incomeMinor);
      expect(sumsAfterReplay.expenseMinor, sums.expenseMinor);
      final plAfterReplay = await plFromRepos(h.layer);
      expect(plAfterReplay.otherIncomeMinor, pl.otherIncomeMinor);
      expect(plAfterReplay.expensesMinor, pl.expensesMinor);
      expect(plAfterReplay.netProfitMinor, pl.netProfitMinor);
      expect(await mirrorExpenseTxns(h.layer, 500000), 1);
      expect(
        (await h.layer.expenseRepo.getExpenses(branchId: _dha))
            .where((e) => e.description == 'Electricity bill (guarded)')
            .length,
        1,
      );
    });

    test('guarded supplier payment moves the aging by exactly the '
        'payment; an idempotent replay moves nothing and the P&L '
        'never moves', () async {
      final h = _Harness();
      final ledgerBefore = await h.layer.supplierRepo.getLedgerEntries(
        'sup-medserve',
      );
      final agingBefore = computeAging(
        entries: supplierLedgerSignedEntries(ledgerBefore),
        now: DateTime.now(),
      );
      expect(agingBefore.totalMinor, 4825000);
      final plBefore = await plFromRepos(h.layer);
      final first = await h.layer.recordSupplierPayment(
        supplierId: 'sup-medserve',
        branchId: _dha,
        amountMinor: 1000000,
        allocations: await _medServeAllocations(h, 1000000),
        idempotencyKey: 'agreement2-supplier-payment-1',
      );
      expect(first.isDuplicate, isFalse);
      final ledgerAfter = await h.layer.supplierRepo.getLedgerEntries(
        'sup-medserve',
      );
      final agingAfter = computeAging(
        entries: supplierLedgerSignedEntries(ledgerAfter),
        now: DateTime.now(),
      );
      expect(agingAfter.totalMinor, 3825000);
      expect(supplierOutstandingMinor(ledgerAfter), 3825000);
      expect(ledgerAfter.last.balanceAfterMinor, 3825000);
      expect(ledgerAfter.last.amountMinor, -1000000);
      final plAfter = await plFromRepos(h.layer);
      expect(plAfter.revenueMinor, plBefore.revenueMinor);
      expect(plAfter.otherIncomeMinor, plBefore.otherIncomeMinor);
      expect(plAfter.expensesMinor, plBefore.expensesMinor);
      expect(plAfter.netProfitMinor, plBefore.netProfitMinor);
      // Replay with the same key: the original payment, no new
      // ledger entry, no new aging movement, no P&L movement.
      final replay = await h.layer.recordSupplierPayment(
        supplierId: 'sup-medserve',
        branchId: _dha,
        amountMinor: 1000000,
        allocations: await _medServeAllocations(h, 1000000),
        idempotencyKey: 'agreement2-supplier-payment-1',
      );
      expect(replay.isDuplicate, isTrue);
      expect(replay.payment.id, first.payment.id);
      final ledgerReplay = await h.layer.supplierRepo.getLedgerEntries(
        'sup-medserve',
      );
      expect(ledgerReplay.length, ledgerAfter.length);
      expect(
        computeAging(
          entries: supplierLedgerSignedEntries(ledgerReplay),
          now: DateTime.now(),
        ).totalMinor,
        3825000,
      );
      final plReplay = await plFromRepos(h.layer);
      expect(plReplay.netProfitMinor, plAfter.netProfitMinor);
    });

    test('a guarded closing correction moves neither the cashbook '
        'nor the P&L; its replay records nothing twice', () async {
      final h = _Harness();
      await h.layer.recordExpense(
        branchId: _dha,
        category: 'Supplies',
        amountMinor: 10000,
        description: 'Today supplies (guarded)',
        expenseDate: _day(0),
        createdBy: 'test-owner',
        idempotencyKey: 'agreement2-expense-2',
      );
      await h.layer.recordIncome(
        branchId: _dha,
        category: 'Other income',
        amountMinor: 25000,
        date: _day(0),
        createdBy: 'test-owner',
        idempotencyKey: 'agreement2-income-2',
      );
      final sumsBefore = await cashbookSums(h.layer);
      final plBefore = await plFromRepos(h.layer);
      final first = await h.layer.recordClosingCorrection(
        correction: _correction(),
        actorId: 'test-owner',
        actorName: 'Test Owner',
        idempotencyKey: 'agreement2-correction-1',
      );
      expect(first.id, isNotEmpty);
      final sumsAfter = await cashbookSums(h.layer);
      final plAfter = await plFromRepos(h.layer);
      expect(sumsAfter.incomeMinor, sumsBefore.incomeMinor);
      expect(sumsAfter.expenseMinor, sumsBefore.expenseMinor);
      expect(plAfter.otherIncomeMinor, plBefore.otherIncomeMinor);
      expect(plAfter.expensesMinor, plBefore.expensesMinor);
      expect(plAfter.netProfitMinor, plBefore.netProfitMinor);
      final replay = await h.layer.recordClosingCorrection(
        correction: _correction(),
        idempotencyKey: 'agreement2-correction-1',
      );
      expect(replay.id, first.id);
      expect(
        (await h.layer.closingCorrectionRepo.getCorrections(
          branchId: _dha,
        )).length,
        1,
      );
      final sumsReplay = await cashbookSums(h.layer);
      expect(sumsReplay.incomeMinor, sumsBefore.incomeMinor);
    });

    test('a guarded reconciliation moves neither the cashbook nor '
        'the P&L; its replay records nothing twice', () async {
      final h = _Harness();
      final sumsBefore = await cashbookSums(h.layer);
      final plBefore = await plFromRepos(h.layer);
      final first = await h.layer.recordCashReconciliation(
        reconciliation: _reconciliation(),
        actorId: 'test-owner',
        actorName: 'Test Owner',
        idempotencyKey: 'agreement2-recon-1',
      );
      expect(first.id, isNotEmpty);
      final sumsAfter = await cashbookSums(h.layer);
      final plAfter = await plFromRepos(h.layer);
      expect(sumsAfter.incomeMinor, sumsBefore.incomeMinor);
      expect(sumsAfter.expenseMinor, sumsBefore.expenseMinor);
      expect(plAfter.netProfitMinor, plBefore.netProfitMinor);
      final replay = await h.layer.recordCashReconciliation(
        reconciliation: _reconciliation(),
        idempotencyKey: 'agreement2-recon-1',
      );
      expect(replay.id, first.id);
      expect(
        (await h.layer.cashReconciliationRepo.getReconciliations(
          branchId: _dha,
        )).length,
        1,
      );
    });

    test('a refused write on a deactivated branch leaves the '
        'cashbook, the P&L and the aging exactly unchanged',
        () async {
      final h = _Harness();
      final sumsBefore = await cashbookSums(h.layer);
      final plBefore = await plFromRepos(h.layer);
      final ledgerBefore = await h.layer.supplierRepo.getLedgerEntries(
        'sup-medserve',
      );
      await _deactivate(h, _dha);
      await expectLater(
        h.layer.recordExpense(
          branchId: _dha,
          category: 'Supplies',
          amountMinor: 50000,
          expenseDate: _day(0),
          idempotencyKey: 'agreement2-refused-1',
        ),
        throwsArgumentError,
      );
      await expectLater(
        h.layer.recordIncome(
          branchId: _dha,
          category: 'Other income',
          amountMinor: 50000,
          date: _day(0),
          idempotencyKey: 'agreement2-refused-2',
        ),
        throwsArgumentError,
      );
      await expectLater(
        h.layer.recordSupplierPayment(
          supplierId: 'sup-medserve',
          branchId: _dha,
          amountMinor: 100000,
          allocations: await _medServeAllocations(h, 100000),
          idempotencyKey: 'agreement2-refused-3',
        ),
        throwsArgumentError,
      );
      final sumsAfter = await cashbookSums(h.layer);
      final plAfter = await plFromRepos(h.layer);
      final ledgerAfter = await h.layer.supplierRepo.getLedgerEntries(
        'sup-medserve',
      );
      expect(sumsAfter.incomeMinor, sumsBefore.incomeMinor);
      expect(sumsAfter.expenseMinor, sumsBefore.expenseMinor);
      expect(plAfter.netProfitMinor, plBefore.netProfitMinor);
      expect(ledgerAfter.length, ledgerBefore.length);
      expect(
        supplierOutstandingMinor(ledgerAfter),
        supplierOutstandingMinor(ledgerBefore),
      );
    });

    test('a guarded daily closing agrees with the day’s cashbook '
        'entries', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(expensesProvider.notifier).recordExpense(
        branchId: _dha,
        category: 'Supplies',
        amountMinor: 10000,
        description: 'Today supplies (closing)',
        expenseDate: _day(0),
      );
      await container
          .read(financialTransactionsProvider.notifier)
          .recordIncome(
            branchId: _dha,
            category: 'Other income',
            amountMinor: 25000,
            date: _day(0),
          );
      final closed = await container
          .read(dailyClosingsProvider.notifier)
          .closeDay(branchId: _dha, date: _day(0));
      expect(closed.error, isNull);
      final closing = closed.closing!;
      // Independent recomputation from the same repos: the closing
      // the guarded layer wrote IS the day's cashbook entries.
      final entries = cashbookEntries(
        expenses: await container
            .read(expenseRepositoryProvider)
            .getExpenses(branchId: _dha),
        transactions: await container
            .read(financialTransactionRepositoryProvider)
            .getTransactions(branchId: _dha),
        branchId: _dha,
      );
      final totals = computeDailyClosing(
        entries: entries,
        date: _day(0),
        openingBalanceMinor: closing.openingBalanceMinor,
      );
      expect(closing.totalIncomeMinor, totals.incomeMinor);
      expect(closing.totalExpenseMinor, totals.expenseMinor);
      expect(closing.closingBalanceMinor, totals.closingBalanceMinor);
      expect(closing.totalIncomeMinor, 25000);
      expect(closing.totalExpenseMinor, 10000);
      expect(dailyClosingIsStale(closing: closing, entries: entries),
          isFalse);
    });
  });

  group('Phase 8 — offline queue: Week 6 guarded finance writes '
      '(D143 pattern)', () {
    test('guarded expense works offline, flushes once, never twice',
        () async {
      final h = _Harness();
      final created = await h.layer.recordExpense(
        branchId: _dha,
        category: 'Utilities',
        amountMinor: 500000,
        description: 'Electricity bill (offline)',
        expenseDate: _day(0),
        createdBy: 'test-owner',
        idempotencyKey: 'offline2-expense-1',
      );
      expect(created.amountMinor, 500000);
      expect(await h.layer.syncQueue.pendingCount(), 1);
      expect(h.layer.lastSyncAt, isNull);
      final flushed = await h.layer.syncQueue.processAll((_) async => true);
      expect(flushed, 1);
      expect(await h.layer.syncQueue.pendingCount(), 0);
      expect(h.layer.lastSyncAt, isNotNull);
      // Same-key retry: the original expense, no new payload, no
      // second expense and no second mirror transaction.
      final retry = await h.layer.recordExpense(
        branchId: _dha,
        category: 'Utilities',
        amountMinor: 500000,
        description: 'Electricity bill (offline)',
        expenseDate: _day(0),
        createdBy: 'test-owner',
        idempotencyKey: 'offline2-expense-1',
      );
      expect(retry.id, created.id);
      expect(await h.layer.syncQueue.pendingCount(), 0);
      expect(
        (await h.layer.expenseRepo.getExpenses(branchId: _dha))
            .where((e) => e.description == 'Electricity bill (offline)')
            .length,
        1,
      );
      final again = await h.layer.syncQueue.processAll((_) async => true);
      expect(again, 0);
    });

    test('guarded income works offline, flushes once, never twice',
        () async {
      final h = _Harness();
      final created = await h.layer.recordIncome(
        branchId: _dha,
        category: 'Other income',
        amountMinor: 250000,
        date: _day(0),
        createdBy: 'test-owner',
        idempotencyKey: 'offline2-income-1',
      );
      expect(created.amountMinor, 250000);
      expect(await h.layer.syncQueue.pendingCount(), 1);
      final flushed = await h.layer.syncQueue.processAll((_) async => true);
      expect(flushed, 1);
      expect(await h.layer.syncQueue.pendingCount(), 0);
      final retry = await h.layer.recordIncome(
        branchId: _dha,
        category: 'Other income',
        amountMinor: 250000,
        date: _day(0),
        createdBy: 'test-owner',
        idempotencyKey: 'offline2-income-1',
      );
      expect(retry.id, created.id);
      expect(await h.layer.syncQueue.pendingCount(), 0);
      expect(
        (await h.layer.financialTransactionRepo.getTransactions(
          branchId: _dha,
        ))
            .where(
              (txn) =>
                  txn.type == FinancialTransactionType.income &&
                  txn.amountMinor == 250000,
            )
            .length,
        1,
      );
    });

    test('guarded daily closing works offline, flushes once, never '
        'twice', () async {
      final h = _Harness();
      final created = await h.layer.recordDailyClosing(
        closing: _closing(),
        idempotencyKey: 'offline2-closing-1',
      );
      expect(created.totalIncomeMinor, 250000);
      expect(await h.layer.syncQueue.pendingCount(), 1);
      expect(h.layer.lastSyncAt, isNull);
      final flushed = await h.layer.syncQueue.processAll((_) async => true);
      expect(flushed, 1);
      expect(await h.layer.syncQueue.pendingCount(), 0);
      final retry = await h.layer.recordDailyClosing(
        closing: _closing(),
        idempotencyKey: 'offline2-closing-1',
      );
      expect(retry.id, created.id);
      expect(await h.layer.syncQueue.pendingCount(), 0);
      expect(
        (await h.layer.dailyClosingRepo.getClosings(branchId: _dha)).length,
        1,
      );
    });

    test('a refused finance write on a deactivated branch enqueues '
        'nothing', () async {
      final h = _Harness();
      await _deactivate(h, _dha);
      await expectLater(
        h.layer.recordExpense(
          branchId: _dha,
          category: 'Supplies',
          amountMinor: 10000,
          expenseDate: _day(0),
          idempotencyKey: 'offline2-refused-1',
        ),
        throwsArgumentError,
      );
      await expectLater(
        h.layer.recordIncome(
          branchId: _dha,
          category: 'Other income',
          amountMinor: 10000,
          date: _day(0),
          idempotencyKey: 'offline2-refused-2',
        ),
        throwsArgumentError,
      );
      await expectLater(
        h.layer.recordSupplierPayment(
          supplierId: 'sup-medserve',
          branchId: _dha,
          amountMinor: 100000,
          allocations: await _medServeAllocations(h, 100000),
          idempotencyKey: 'offline2-refused-3',
        ),
        throwsArgumentError,
      );
      await expectLater(
        h.layer.recordDailyClosing(
          closing: _closing(),
          idempotencyKey: 'offline2-refused-4',
        ),
        throwsArgumentError,
      );
      await expectLater(
        h.layer.recordClosingCorrection(
          correction: _correction(),
          idempotencyKey: 'offline2-refused-5',
        ),
        throwsArgumentError,
      );
      await expectLater(
        h.layer.recordCashReconciliation(
          reconciliation: _reconciliation(),
          idempotencyKey: 'offline2-refused-6',
        ),
        throwsArgumentError,
      );
      // The guard sits before the first write AND before the
      // enqueue: a refused write leaves no sync payload behind.
      expect(await h.layer.syncQueue.pendingCount(), 0);
      expect(h.layer.lastSyncAt, isNull);
    });
  });

  group('Phase 8 — idempotent payments: dialog-held keys at the '
      'notifier (D162)', () {
    test('same dialog-held expense key twice records one expense',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      const key = 'dialog2-expense-1';
      final first = await container
          .read(expensesProvider.notifier)
          .recordExpense(
            branchId: _dha,
            category: 'Utilities',
            amountMinor: 500000,
            description: 'Double-tap expense',
            expenseDate: _day(0),
            idempotencyKey: key,
          );
      expect(first.error, isNull);
      final second = await container
          .read(expensesProvider.notifier)
          .recordExpense(
            branchId: _dha,
            category: 'Utilities',
            amountMinor: 500000,
            description: 'Double-tap expense',
            expenseDate: _day(0),
            idempotencyKey: key,
          );
      expect(second.error, isNull);
      expect(second.expense!.id, first.expense!.id);
      expect(
        (await container
                .read(expenseRepositoryProvider)
                .getExpenses(branchId: _dha))
            .where((e) => e.description == 'Double-tap expense')
            .length,
        1,
      );
    });

    test('same dialog-held income key twice records one transaction',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      const key = 'dialog2-income-1';
      Future<int> incomeCount() async {
        return (await container
                .read(financialTransactionRepositoryProvider)
                .getTransactions(branchId: _dha))
            .where(
              (txn) =>
                  txn.type == FinancialTransactionType.income &&
                  txn.amountMinor == 300000,
            )
            .length;
      }

      final first = await container
          .read(financialTransactionsProvider.notifier)
          .recordIncome(
            branchId: _dha,
            category: 'Other income',
            amountMinor: 300000,
            date: _day(0),
            idempotencyKey: key,
          );
      expect(first.error, isNull);
      expect(await incomeCount(), 1);
      final second = await container
          .read(financialTransactionsProvider.notifier)
          .recordIncome(
            branchId: _dha,
            category: 'Other income',
            amountMinor: 300000,
            date: _day(0),
            idempotencyKey: key,
          );
      expect(second.error, isNull);
      expect(second.transaction!.id, first.transaction!.id);
      expect(await incomeCount(), 1);
    });

    test('same dialog-held supplier-payment key twice pays once '
        '(full settlement)', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      const key = 'dialog2-supplier-payment-1';
      final first = await container
          .read(supplierPaymentsProvider.notifier)
          .recordPayment(
            supplierId: 'sup-medserve',
            branchId: _dha,
            amountMinor: 4825000,
            method: SupplierPaymentMethod.bankTransfer,
            reference: 'TXN-D32',
            idempotencyKey: key,
          );
      expect(first.error, isNull);
      expect(first.payment, isNotNull);
      expect(
        supplierOutstandingMinor(
          await container
              .read(supplierRepositoryProvider)
              .getLedgerEntries('sup-medserve'),
        ),
        0,
      );
      // The second submit carries the same dialog-held key: the
      // D162 notifier shortcut returns the original instead of
      // re-validating against the now-zero outstanding.
      final second = await container
          .read(supplierPaymentsProvider.notifier)
          .recordPayment(
            supplierId: 'sup-medserve',
            branchId: _dha,
            amountMinor: 4825000,
            method: SupplierPaymentMethod.bankTransfer,
            reference: 'TXN-D32',
            idempotencyKey: key,
          );
      expect(second.error, isNull);
      expect(second.payment!.id, first.payment!.id);
      expect(
        await container.read(supplierPaymentRepositoryProvider).getPayments(),
        hasLength(1),
      );
      expect(
        supplierOutstandingMinor(
          await container
              .read(supplierRepositoryProvider)
              .getLedgerEntries('sup-medserve'),
        ),
        0,
      );
    });
  });

  group('Phase 8 — offline queue + role gates: Week 6 flows', () {
    test('directory branch switching works offline and enqueues '
        'nothing; the switch itself is role-independent', () async {
      final container = ProviderContainer(
        overrides: [
          authProvider.overrideWith(
            () => _FixedAuthNotifier(_userFor('cashier')),
          ),
        ],
      );
      addTearDown(container.dispose);
      final errors = await container
          .read(branchDirectoryProvider.notifier)
          .addBranch(
            const Branch(
              id: 'branch-model-town',
              name: 'Demo Branch — Model Town',
              address: 'Model Town, Lahore',
              phone: '0300-3333333',
            ),
          );
      expect(errors, isEmpty);
      // The branch SAVE enqueued one payload (D148); the switch
      // below must not add another — switching is local state.
      final layer = container.read(productionDataLayerProvider);
      final pendingAfterSave = await layer.syncQueue.pendingCount();
      expect(pendingAfterSave, 1);
      final notifier = container.read(activeBranchProvider.notifier);
      expect(notifier.switchTo('branch-model-town'), isTrue);
      expect(container.read(activeBranchProvider).id, 'branch-model-town');
      expect(await layer.syncQueue.pendingCount(), pendingAfterSave);
      // A deactivated branch can still become active (viewing, not
      // transacting — D163): the switch still enqueues nothing.
      final branchRepo = container.read(branchRepositoryProvider);
      final branch = await branchRepo.getById('branch-model-town');
      await branchRepo.updateBranch(branch!.copyWith(active: false));
      expect(notifier.switchTo(_dha), isTrue);
      expect(notifier.switchTo('branch-model-town'), isTrue);
      expect(await layer.syncQueue.pendingCount(), pendingAfterSave);
      expect(notifier.switchTo('branch-nope'), isFalse);
    });

    test('a duplicate barcode is rejected before the layer: nothing '
        'is written and nothing is enqueued', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final medicines = await container
          .read(medicineRepositoryProvider)
          .getMedicines();
      final first = medicines.firstWhere(
        (m) => m.id == 'med-panadol-extra',
      );
      final other = medicines.firstWhere((m) => m.id != first.id);
      final layer = container.read(productionDataLayerProvider);
      expect(await layer.syncQueue.pendingCount(), 0);
      await expectLater(
        container
            .read(medicineRepositoryProvider)
            .updateMedicine(first.copyWith(barcode: other.barcode)),
        throwsArgumentError,
      );
      expect(
        (await container
                .read(medicineRepositoryProvider)
                .getById(first.id))!
            .barcode,
        first.barcode,
      );
      expect(await layer.syncQueue.pendingCount(), 0);
    });

    testWidgets('a POS tax re-rate enqueues no sync payload',
        (tester) async {
      final (container, router, trap) = await _pumpSweepApp(
        tester,
        'cashier',
      );
      router.go('/billing');
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Add').first);
      await tester.tap(find.text('Add').first);
      await tester.pumpAndSettle();
      expect(find.text('Cart (1)'), findsOneWidget);
      final layer = container.read(productionDataLayerProvider);
      expect(await layer.syncQueue.pendingCount(), 0);
      // The re-rate is UI state over the live settings provider:
      // no layer write, no queue payload.
      expect(
        container.read(orgSettingsProvider.notifier).setTaxRate(10),
        isTrue,
      );
      await tester.pumpAndSettle();
      expect(find.text('Tax (10%)'), findsOneWidget);
      expect(await layer.syncQueue.pendingCount(), 0);
      expect(trap.overflowCount, 0);
    });

    test('finance notifiers refuse a role without financeEntry; an '
        'allowed role writes', () async {
      // Matrix row `financeEntry` (roles_permissions.dart): the
      // Pharmacist is `none`; the Owner is `allowed`.
      final refused = ProviderContainer(
        overrides: [
          authProvider.overrideWith(
            () => _FixedAuthNotifier(_userFor('pharmacist')),
          ),
        ],
      );
      addTearDown(refused.dispose);
      final before = (await refused
              .read(expenseRepositoryProvider)
              .getExpenses(branchId: _dha))
          .length;
      final denied = await refused
          .read(expensesProvider.notifier)
          .recordExpense(
            branchId: _dha,
            category: 'Supplies',
            amountMinor: 10000,
            description: 'Pharmacist expense',
            expenseDate: _day(0),
          );
      expect(denied.expense, isNull);
      expect(denied.error, contains('permission'));
      expect(
        (await refused
                .read(expenseRepositoryProvider)
                .getExpenses(branchId: _dha))
            .length,
        before,
      );
      final allowed = ProviderContainer(
        overrides: [
          authProvider.overrideWith(
            () => _FixedAuthNotifier(_userFor('owner')),
          ),
        ],
      );
      addTearDown(allowed.dispose);
      final written = await allowed
          .read(expensesProvider.notifier)
          .recordExpense(
            branchId: _dha,
            category: 'Supplies',
            amountMinor: 10000,
            description: 'Owner expense',
            expenseDate: _day(0),
          );
      expect(written.error, isNull);
      expect(written.expense, isNotNull);
    });

    test('supplier-payment notifier refuses a Branch Manager; the '
        'Owner pays', () async {
      // Matrix row `supplierPay`: Branch Manager is `none`; Owner,
      // HO Admin and Accountant are `allowed` (D89).
      final refused = ProviderContainer(
        overrides: [
          authProvider.overrideWith(
            () => _FixedAuthNotifier(_userFor('branch_manager')),
          ),
        ],
      );
      addTearDown(refused.dispose);
      final denied = await refused
          .read(supplierPaymentsProvider.notifier)
          .recordPayment(
            supplierId: 'sup-medserve',
            branchId: _dha,
            amountMinor: 100000,
            method: SupplierPaymentMethod.cash,
          );
      expect(denied.payment, isNull);
      expect(denied.error, contains('Only the Owner, HO Admin or '
          'Accountant'));
      expect(
        await refused.read(supplierPaymentRepositoryProvider).getPayments(),
        isEmpty,
      );
      final allowed = ProviderContainer(
        overrides: [
          authProvider.overrideWith(
            () => _FixedAuthNotifier(_userFor('owner')),
          ),
        ],
      );
      addTearDown(allowed.dispose);
      final written = await allowed
          .read(supplierPaymentsProvider.notifier)
          .recordPayment(
            supplierId: 'sup-medserve',
            branchId: _dha,
            amountMinor: 100000,
            method: SupplierPaymentMethod.cash,
          );
      expect(written.error, isNull);
      expect(written.payment, isNotNull);
      expect(
        supplierOutstandingMinor(
          await allowed
              .read(supplierRepositoryProvider)
              .getLedgerEntries('sup-medserve'),
        ),
        4725000,
      );
    });

    for (final roleKey in srsRoleKeys) {
      testWidgets('backup restore gate: role $roleKey sees exactly '
          'its matrix outcome', (tester) async {
        final user = _userFor(roleKey);
        final (_, router) = await pumpRouterAppAsRole(
          tester,
          roleKey,
          size: const Size(1280, 800),
        );
        // The expected outcome comes from the matrix itself via
        // the permission service — the test pins that the ROUTE
        // GATE follows it (D144 pattern), not a second copy of the
        // matrix. `sysSettings` is `allowed` only for Super Admin /
        // Owner / HO Admin; the other seven roles are `none`, so
        // the FeatureGate shows its no-permission screen and the
        // backup screen (with its in-screen restore gate) never
        // renders for them.
        final allowed = routeCapability('/backup') == null ||
            permissionService.canInBranch(user, 'sysSettings', _dha);
        router.go('/backup');
        await tester.pumpAndSettle();
        if (allowed) {
          expect(find.text('Backup & Restore'), findsWidgets);
          expect(
            find.byKey(const ValueKey('restore-validate-button')),
            findsOneWidget,
            reason: '$roleKey may restore (sysSettings write)',
          );
        } else {
          expect(
            find.text('No permission for Backup & Restore'),
            findsOneWidget,
            reason: '$roleKey is route-gated out of /backup',
          );
          expect(
            find.byKey(const ValueKey('restore-validate-button')),
            findsNothing,
          );
        }
      });
    }
  });

  group('D170 — sweep harness: the D160 drain undercounts', () {
    testWidgets('two simultaneous overflows: D160 drain counts 0, '
        'the trap counts 2', (tester) async {
      final trap = _OverflowTrap();
      addTearDown(trap.dispose);
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = _phoneSize;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      // Two Rows that each overflow the 390px line by 10px in the
      // same layout pass — exactly the shape the supplier detail
      // screen had (aging badges 63px + Export row 0.2px).
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                Row(
                  children: [
                    SizedBox(
                      width: 400,
                      height: 20,
                      child: Container(color: Colors.red),
                    ),
                  ],
                ),
                Row(
                  children: [
                    SizedBox(
                      width: 400,
                      height: 20,
                      child: Container(color: Colors.blue),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // The D160 helper drains the binding's pending exception —
      // one "Multiple exceptions (2)..." string with no overflow
      // text in it — and counts ZERO for two real overflows.
      expect(_countOverflowsD160(_drainExceptionsD160(tester)), 0);
      // The trap saw each error as the handler received it.
      expect(trap.overflowCount, 2);
    });
  });
}
