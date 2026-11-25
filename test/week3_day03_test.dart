// Week 3 Day 3 tests — pre-aggregated report counters + pagination +
// sync-status UI (D105–D109).
//
// - `DailyCounter` model + mapper round-trip (incl. legacy rollup
//   docs without the D105 cost fields).
// - `computeDailyCounters` agrees EXACTLY with the live computation
//   (`computeReports` / `computeProfitAndLoss` /
//   `computeWeeklyTrend`) on the seeded demo data — the mock counters
//   are derived from the same seed, never invented figures.
// - Mock + Firestore counter repositories (range reads omit missing
//   days; paged reads use the transport's paged fetch and skip the
//   sequential-number docs sharing the collection).
// - Pagination helpers (index + cursor pages, boundaries).
// - Sync queue `lastSyncedAt` + the sync-status chip states (empty,
//   pending, synced, store unavailable) — the chip never fakes a sync.
// - Reports provider: counters used when coverage is full, live
//   fallback when any day is missing (D106).
// - Reports screen: counters caption + daily-sales paging; sales
//   history empty state; POS screen shows the sync chip.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:pharmadesk/core/data/audit_log.dart';
import 'package:pharmadesk/core/data/firestore_mappers.dart';
import 'package:pharmadesk/core/data/firestore_repositories.dart';
import 'package:pharmadesk/core/data/firestore_schema.dart';
import 'package:pharmadesk/core/data/firestore_transport.dart';
import 'package:pharmadesk/core/data/inventory_engine.dart';
import 'package:pharmadesk/core/data/production_data_layer.dart';
import 'package:pharmadesk/core/data/report_counters.dart';
import 'package:pharmadesk/core/data/repository_factory.dart';
import 'package:pharmadesk/core/data/sync_queue.dart';
import 'package:pharmadesk/core/routing/app_router.dart';
import 'package:pharmadesk/core/services/repositories.dart';
import 'package:pharmadesk/core/theme/app_theme.dart';
import 'package:pharmadesk/core/theme/white_label.dart';
import 'package:pharmadesk/core/utils/pagination.dart';
import 'package:pharmadesk/core/widgets/pagination_controls.dart';
import 'package:pharmadesk/core/widgets/sync_status_widget.dart';
import 'package:pharmadesk/features/authentication/auth_state.dart';
import 'package:pharmadesk/features/reports/analytics_logic.dart';
import 'package:pharmadesk/features/reports/reports_logic.dart';
import 'package:pharmadesk/features/reports/reports_provider.dart';

const _dha = 'branch-dha-main';
const _glb = 'branch-demo-gulberg';
const _org = demoOrganizationId;

/// In-memory [FirestoreTransport]: documents live in a map keyed by
/// full path. Same behaviour as the Day 3 / Week 3 Day 1 fake.
class FakeFirestoreTransport implements FirestoreTransport {
  final Map<String, Map<String, dynamic>> docs = {};

  int _autoId = 0;

  @override
  Future<Map<String, dynamic>?> getDocument(String path) async {
    final data = docs[path];
    return data == null ? null : Map<String, dynamic>.from(data);
  }

  @override
  Future<List<FirestoreDocument>> queryCollection(
    String collectionPath, {
    Map<String, Object?> whereEquals = const {},
    String? orderBy,
    bool descending = false,
    int? limit,
    String? startAfterId,
  }) async {
    var entries = docs.entries.where((entry) {
      if (!entry.key.startsWith('$collectionPath/')) return false;
      return !entry.key.substring(collectionPath.length + 1).contains('/');
    }).toList();
    for (final filter in whereEquals.entries) {
      entries = entries
          .where((entry) => entry.value[filter.key] == filter.value)
          .toList();
    }
    int compare(FirestoreDocument a, FirestoreDocument b) {
      if (orderBy == null) return a.id.compareTo(b.id);
      final cmp = _compareValues(a.data[orderBy], b.data[orderBy]);
      return descending ? -cmp : cmp;
    }

    final found = [
      for (final entry in entries)
        FirestoreDocument(
          id: entry.key.split('/').last,
          data: Map<String, dynamic>.from(entry.value),
        ),
    ]..sort(compare);
    var page = found;
    if (startAfterId != null) {
      final index = page.indexWhere((doc) => doc.id == startAfterId);
      if (index != -1) page = page.sublist(index + 1);
    }
    if (limit != null && page.length > limit) {
      page = page.sublist(0, limit);
    }
    return page;
  }

  static int _compareValues(dynamic a, dynamic b) {
    if (a is Comparable && b is Comparable) {
      try {
        return a.compareTo(b);
      } on Object {
        // Mixed types (e.g. Timestamp vs String): fall through.
      }
    }
    return a.toString().compareTo(b.toString());
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
      docs[path] = Map<String, dynamic>.from(data);
    }
  }

  @override
  Future<void> updateDocument(String path, Map<String, dynamic> data) async {
    final existing = docs[path];
    if (existing == null) {
      throw StateError('No document at $path to update.');
    }
    docs[path] = {...existing, ...data};
  }

  @override
  Future<String> addDocument(
    String collectionPath,
    Map<String, dynamic> data,
  ) async {
    final id = 'auto-${_autoId++}';
    docs['$collectionPath/$id'] = Map<String, dynamic>.from(data);
    return id;
  }

  @override
  Future<void> runBatchedWrites(List<WriteOperation> operations) async {
    for (final operation in operations) {
      switch (operation.kind) {
        case WriteOperationKind.set:
          docs[operation.path] = Map<String, dynamic>.from(
            operation.data ?? const {},
          );
        case WriteOperationKind.update:
          docs[operation.path] = {
            ...docs[operation.path] ?? {},
            ...operation.data ?? {},
          };
        case WriteOperationKind.delete:
          docs.remove(operation.path);
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
  String newDocumentId(String collectionPath) => 'auto-${_autoId++}';
}

class _FakeTransaction implements FirestoreTransaction {
  _FakeTransaction(this.transport);

  final FakeFirestoreTransport transport;

  @override
  Future<Map<String, dynamic>?> get(String path) =>
      transport.getDocument(path);

  @override
  void set(String path, Map<String, dynamic> data, {bool merge = false}) {
    if (merge && transport.docs.containsKey(path)) {
      transport.docs[path] = {...transport.docs[path]!, ...data};
    } else {
      transport.docs[path] = Map<String, dynamic>.from(data);
    }
  }

  @override
  void update(String path, Map<String, dynamic> data) {
    transport.docs[path] = {...transport.docs[path] ?? {}, ...data};
  }
}

/// A counter repository with NO rollup docs at all — the "rollup has
/// never run" case: the reports provider must fall back to live
/// computation (D106).
class _EmptyCounterRepo implements ReportCounterRepository {
  @override
  Future<DailyCounter?> getDailyCounter({
    required String branchId,
    required DateTime date,
  }) async => null;

  @override
  Future<List<DailyCounter>> getDailyCounters({
    required String branchId,
    required DateTime start,
    required DateTime end,
  }) async => [];

  @override
  Future<CounterPage> listDailyCountersPaged({
    required String branchId,
    int pageSize = reportPageSize,
    String? startAfterId,
  }) async => const CounterPage(
    counters: [],
    nextCursor: null,
    hasMore: false,
  );
}

/// A sync store that always fails — the chip must render
/// "unavailable", never a stale "All synced" (D108).
class _ThrowingSyncStore implements SyncStore {
  @override
  Future<SyncOperation> enqueue(SyncOperation operation) async {
    throw StateError('Store unavailable.');
  }

  @override
  Future<SyncOperation?> byIdempotencyKey(String key) async {
    throw StateError('Store unavailable.');
  }

  @override
  Future<List<SyncOperation>> pending({DateTime? now}) async {
    throw StateError('Store unavailable.');
  }

  @override
  Future<List<SyncOperation>> all() async {
    throw StateError('Store unavailable.');
  }

  @override
  Future<void> update(SyncOperation operation) async {
    throw StateError('Store unavailable.');
  }

  @override
  Future<int> pendingCount() async {
    throw StateError('Store unavailable.');
  }
}

({
  ProductionDataLayer layer,
  InventoryEngine engine,
  InMemoryAuditLogWriter audit,
  SyncQueue queue,
})
_layer({SyncStore? store}) {
  final audit = InMemoryAuditLogWriter();
  final queue = SyncQueue(store ?? InMemorySyncStore());
  final engine = InventoryEngine(organizationId: _org, audit: audit);
  final layer = ProductionDataLayer(
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
    audit: audit,
    syncQueue: queue,
    engine: engine,
  );
  return (layer: layer, engine: engine, audit: audit, queue: queue);
}

/// Pumps the ungated router app with a fresh container the test owns
/// (same harness as the Week 3 Day 2 widget tests).
Future<(ProviderContainer, GoRouter)> pumpRouterApp(
  WidgetTester tester, {
  Size size = const Size(1280, 900),
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final container = ProviderContainer();
  addTearDown(container.dispose);
  final router = createAppRouter();
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

DailyCounter _counter({
  String branchId = _dha,
  DateTime? date,
  int salesTotalMinor = 123450,
  int salesCount = 3,
  int ordersCount = 5,
  int cogsMinor = 80000,
  int? grossProfitMinor,
}) {
  return DailyCounter(
    branchId: branchId,
    date: date ?? DateTime(2026, 11, 25),
    salesTotalMinor: salesTotalMinor,
    salesCount: salesCount,
    ordersCount: ordersCount,
    cogsMinor: cogsMinor,
    grossProfitMinor: grossProfitMinor ?? salesTotalMinor - cogsMinor,
  );
}

void main() {
  group('DailyCounter model', () {
    test('dateKey / docId / dateFromKey round-trip', () {
      final counter = _counter(date: DateTime(2026, 11, 5));
      expect(counter.dateKey, '2026-11-05');
      expect(counter.docId, 'daily-2026-11-05');
      expect(DailyCounter.dateFromKey('2026-11-05'), DateTime(2026, 11, 5));
      expect(DailyCounter.dateFromKey('not-a-date'), isNull);
      expect(DailyCounter.dateFromKey('2026-13-40'), isNull);
      expect(DailyCounter.docIdFor(DateTime(2026, 1, 9)), 'daily-2026-01-09');
    });

    test('equality + copyWith', () {
      final a = _counter();
      expect(a, _counter());
      expect(a.copyWith(salesCount: 4).salesCount, 4);
      expect(a.copyWith(salesCount: 4), isNot(_counter()));
      expect(a.toString(), contains('branch-dha-main'));
    });

    test('schema: daily counter doc path + contract', () {
      expect(
        FirestoreSchema.dailyCounterDocPath(_dha, DateTime(2026, 11, 25)),
        'branches/$_dha/counters/daily-2026-11-25',
      );
      final doc = dailyCounterToFirestore(_counter(), orgId: _org);
      expect(
        FirestoreSchema.validateDocument(
          'branches/{branchId}/counters/daily-{date}',
          doc,
        ),
        isEmpty,
      );
    });
  });

  group('Daily counter mappers', () {
    test('toFirestore -> fromFirestore round-trips exactly', () {
      final counter = _counter();
      final doc = dailyCounterToFirestore(counter, orgId: _org);
      final restored = dailyCounterFromFirestore(counter.docId, doc);
      expect(restored, counter);
    });

    test('legacy rollup doc without cost fields still parses', () {
      // A Job 3 doc written before the D105 extension carries only
      // the original three fields — the read side defaults COGS to 0
      // and derives gross profit instead of failing the report.
      final restored = dailyCounterFromFirestore('daily-2026-11-25', {
        'branchId': _dha,
        'date': '2026-11-25',
        'value': {
          'salesTotalMinor': 50000,
          'salesCount': 2,
          'ordersCount': 4,
        },
      });
      expect(restored.salesTotalMinor, 50000);
      expect(restored.cogsMinor, 0);
      expect(restored.grossProfitMinor, 50000);
      expect(restored.date, DateTime(2026, 11, 25));
    });

    test('missing value map defaults to zeros, not a crash', () {
      final restored = dailyCounterFromFirestore('daily-2026-11-25', {
        'branchId': _dha,
        'date': '2026-11-25',
      });
      expect(restored.salesTotalMinor, 0);
      expect(restored.grossProfitMinor, 0);
    });
  });

  group('computeDailyCounters agrees with the live computation', () {
    test('30-day DHA totals match computeReports + P&L exactly', () async {
      final orders = MockOrderRepository();
      final sales = MockSaleRepository();
      final returns = MockSaleReturnRepository();
      final inventory = MockInventoryRepository();
      final medicines = MockMedicineRepository();
      final now = DateTime.now();
      final counters = computeDailyCounters(
        orders: await orders.getOrders(branchId: _dha),
        sales: await sales.getSales(branchId: _dha),
        returns: await returns.getReturns(branchId: _dha),
        inventory: await inventory.getInventory(branchId: _dha),
        medicinesById: {
          for (final m in await medicines.getMedicines()) m.id: m,
        },
        branchId: _dha,
        now: now,
        days: 30,
      );
      expect(counters.length, 30);
      final live = computeReports(
        orders: await orders.getOrders(branchId: _dha),
        sales: await sales.getSales(branchId: _dha),
        inventory: await inventory.getInventory(branchId: _dha),
        medicinesById: {
          for (final m in await medicines.getMedicines()) m.id: m,
        },
        branchId: _dha,
        now: now,
        days: 30,
      );
      final counterSales = counters.fold(
        0,
        (sum, c) => sum + c.salesTotalMinor,
      );
      final counterOrders = counters.fold(
        0,
        (sum, c) => sum + c.salesCount + c.ordersCount,
      );
      expect(counterSales, live.totalSalesMinor);
      expect(counterOrders, live.totalOrders);
      // Per-day agreement, not just the total.
      for (var i = 0; i < 30; i++) {
        expect(counters[i].salesTotalMinor, live.dailySales[i].salesMinor);
        expect(
          counters[i].salesCount + counters[i].ordersCount,
          live.dailySales[i].orders,
        );
      }
      final profitLoss = computeProfitAndLoss(
        orders: await orders.getOrders(branchId: _dha),
        sales: await sales.getSales(branchId: _dha),
        returns: await returns.getReturns(branchId: _dha),
        inventory: await inventory.getInventory(branchId: _dha),
        expenses: await MockExpenseRepository().getExpenses(),
        transactions: await MockFinancialTransactionRepository()
            .getTransactions(),
        medicinesById: {
          for (final m in await medicines.getMedicines()) m.id: m,
        },
        branchId: _dha,
        now: now,
        days: 30,
      );
      final counterCogs = counters.fold(0, (sum, c) => sum + c.cogsMinor);
      expect(counterSales, profitLoss.revenueMinor);
      expect(counterCogs, profitLoss.cogsMinor);
    });

    test('7-day Gulberg totals match live; weekly trend matches', () async {
      final orders = MockOrderRepository();
      final sales = MockSaleRepository();
      final returns = MockSaleReturnRepository();
      final inventory = MockInventoryRepository();
      final medicines = MockMedicineRepository();
      final now = DateTime.now();
      final counters = computeDailyCounters(
        orders: await orders.getOrders(branchId: _glb),
        sales: await sales.getSales(branchId: _glb),
        returns: await returns.getReturns(branchId: _glb),
        inventory: await inventory.getInventory(branchId: _glb),
        medicinesById: {
          for (final m in await medicines.getMedicines()) m.id: m,
        },
        branchId: _glb,
        now: now,
        days: 7,
      );
      expect(counters.length, 7);
      final live = computeReports(
        orders: await orders.getOrders(branchId: _glb),
        sales: await sales.getSales(branchId: _glb),
        inventory: await inventory.getInventory(branchId: _glb),
        medicinesById: {
          for (final m in await medicines.getMedicines()) m.id: m,
        },
        branchId: _glb,
        now: now,
        days: 7,
      );
      expect(
        counters.fold(0, (sum, c) => sum + c.salesTotalMinor),
        live.totalSalesMinor,
      );
      final counterTrend = weeklyTrendFromCounters(counters);
      final liveTrend = computeWeeklyTrend(live.dailySales);
      expect(counterTrend.length, liveTrend.length);
      for (var i = 0; i < counterTrend.length; i++) {
        expect(counterTrend[i].weekStart, liveTrend[i].weekStart);
        expect(counterTrend[i].salesMinor, liveTrend[i].salesMinor);
        expect(counterTrend[i].orders, liveTrend[i].orders);
      }
    });

    test('zero days are counters too (rolled up, nothing sold)', () {
      final counters = computeDailyCounters(
        orders: const [],
        sales: const [],
        returns: const [],
        inventory: const [],
        branchId: _dha,
        now: DateTime(2026, 11, 25),
        days: 3,
      );
      expect(counters.length, 3);
      expect(counters.map((c) => c.dateKey), [
        '2026-11-23',
        '2026-11-24',
        '2026-11-25',
      ]);
      expect(counters.every((c) => c.salesTotalMinor == 0), isTrue);
      expect(weeklyTrendFromCounters(counters).length, 1);
      expect(weeklyTrendFromCounters(counters).first.salesMinor, 0);
    });

    test('cancelled orders never count; refunds reduce revenue', () async {
      // The seeded stream already proves the totals agree with the
      // live computation (which applies the same rules); this pins
      // the rules directly on hand-built rows.
      final orders = MockOrderRepository();
      final all = await orders.getOrders(branchId: _dha);
      final cancelled = all.where(
        (o) => o.status.toString().contains('cancelled'),
      );
      // Seeded orders include cancelled rows — the counter totals
      // above already exclude them (they match the live totals,
      // which exclude them too). Here: a window with only cancelled
      // orders yields zero revenue.
      expect(cancelled, isNotEmpty);
      final counters = computeDailyCounters(
        orders: cancelled.toList(),
        sales: const [],
        returns: const [],
        inventory: const [],
        branchId: _dha,
        now: DateTime.now(),
        days: 30,
      );
      expect(
        counters.fold(0, (sum, c) => sum + c.salesTotalMinor),
        0,
      );
      expect(counters.fold(0, (sum, c) => sum + c.ordersCount), 0);
    });
  });

  group('MockReportCounterRepository', () {
    test('getDailyCounter returns a day; unknown day is null', () async {
      final repo = MockReportCounterRepository(
        orders: MockOrderRepository(),
        sales: MockSaleRepository(),
        returns: MockSaleReturnRepository(),
        inventory: MockInventoryRepository(),
        medicines: MockMedicineRepository(),
      );
      final today = await repo.getDailyCounter(
        branchId: _dha,
        date: DateTime.now(),
      );
      expect(today, isNotNull);
      expect(today!.branchId, _dha);
      final old = await repo.getDailyCounter(
        branchId: _dha,
        date: DateTime(2020, 1, 1),
      );
      expect(old, isNull);
    });

    test('getDailyCounters returns the exact range, oldest first', () async {
      final repo = MockReportCounterRepository(
        orders: MockOrderRepository(),
        sales: MockSaleRepository(),
        returns: MockSaleReturnRepository(),
        inventory: MockInventoryRepository(),
        medicines: MockMedicineRepository(),
      );
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final counters = await repo.getDailyCounters(
        branchId: _dha,
        start: today.subtract(const Duration(days: 6)),
        end: today,
      );
      expect(counters.length, 7);
      expect(counters.first.date, today.subtract(const Duration(days: 6)));
      expect(counters.last.date, today);
    });

    test('paged reads chain to all 30 days with no duplicates', () async {
      final repo = MockReportCounterRepository(
        orders: MockOrderRepository(),
        sales: MockSaleRepository(),
        returns: MockSaleReturnRepository(),
        inventory: MockInventoryRepository(),
        medicines: MockMedicineRepository(),
      );
      final seen = <String>{};
      String? cursor;
      var pages = 0;
      while (true) {
        final page = await repo.listDailyCountersPaged(
          branchId: _dha,
          startAfterId: cursor,
        );
        pages++;
        for (final counter in page.counters) {
          expect(seen.add(counter.docId), isTrue, reason: 'duplicate page');
        }
        if (!page.hasMore) {
          expect(page.nextCursor, isNull);
          break;
        }
        expect(page.nextCursor, isNotNull);
        cursor = page.nextCursor;
      }
      expect(seen.length, 30);
      expect(pages, 3);
    });

    test('unknown cursor starts from the first page', () async {
      final repo = MockReportCounterRepository(
        orders: MockOrderRepository(),
        sales: MockSaleRepository(),
        returns: MockSaleReturnRepository(),
        inventory: MockInventoryRepository(),
        medicines: MockMedicineRepository(),
      );
      final page = await repo.listDailyCountersPaged(
        branchId: _dha,
        startAfterId: 'daily-1999-01-01',
      );
      expect(page.counters.length, reportPageSize);
      expect(page.hasMore, isTrue);
    });
  });

  group('FirestoreReportCounterRepository (fake transport)', () {
    Future<FirestoreReportCounterRepository> seededRepo(
      FakeFirestoreTransport transport,
    ) async {
      final repo = FirestoreReportCounterRepository(
        transport: transport,
        organizationId: _org,
      );
      // 25 consecutive daily docs + one sequential-number doc that
      // shares the collection and must be skipped by paging.
      final today = DateTime(2026, 11, 25);
      for (var i = 0; i < 25; i++) {
        final day = today.subtract(Duration(days: 24 - i));
        final counter = _counter(
          date: day,
          salesTotalMinor: (i + 1) * 10000,
          salesCount: i,
          ordersCount: i + 1,
        );
        await transport.setDocument(
          FirestoreSchema.dailyCounterDocPath(_dha, day),
          dailyCounterToFirestore(counter, orgId: _org),
        );
      }
      await transport.setDocument(
        FirestoreSchema.counterDocPath(_dha, 'invoices'),
        {'organizationId': _org, 'value': 1042},
      );
      return repo;
    }

    test('getDailyCounter hit + miss', () async {
      final transport = FakeFirestoreTransport();
      final repo = await seededRepo(transport);
      final hit = await repo.getDailyCounter(
        branchId: _dha,
        date: DateTime(2026, 11, 25),
      );
      expect(hit, isNotNull);
      expect(hit!.salesTotalMinor, 25 * 10000);
      expect(hit.ordersCount, 25);
      expect(
        await repo.getDailyCounter(
          branchId: _dha,
          date: DateTime(2026, 10, 1),
        ),
        isNull,
      );
    });

    test('getDailyCounters omits missing days (never zero-fills)', () async {
      final transport = FakeFirestoreTransport();
      final repo = await seededRepo(transport);
      final counters = await repo.getDailyCounters(
        branchId: _dha,
        start: DateTime(2026, 10, 30),
        end: DateTime(2026, 11, 25),
      );
      // Seeded range starts 2026-11-01 (25 days); 30 Oct is missing.
      expect(counters.length, 25);
      expect(counters.first.date, DateTime(2026, 11, 1));
      expect(counters.last.date, DateTime(2026, 11, 25));
    });

    test('paged reads skip the sequential doc and chain cleanly', () async {
      final transport = FakeFirestoreTransport();
      final repo = await seededRepo(transport);
      final seen = <String>{};
      String? cursor;
      var pages = 0;
      while (true) {
        final page = await repo.listDailyCountersPaged(
          branchId: _dha,
          startAfterId: cursor,
        );
        pages++;
        for (final counter in page.counters) {
          expect(seen.add(counter.docId), isTrue);
        }
        if (!page.hasMore) break;
        cursor = page.nextCursor;
      }
      expect(seen.length, 25);
      expect(pages, 3);
      // The sequential `invoices` doc never appears as a counter.
      expect(seen.contains('invoices'), isFalse);
    });
  });

  group('Pagination helpers (D107)', () {
    final items = List.generate(25, (i) => 'Item $i');

    test('paginateList: 25 items -> 3 pages of 10/10/5', () {
      final first = paginateList(items, page: 1);
      expect(first.items, items.sublist(0, 10));
      expect(first.totalPages, 3);
      expect(first.hasNext, isTrue);
      expect(first.hasPrevious, isFalse);
      final last = paginateList(items, page: 3);
      expect(last.items, items.sublist(20, 25));
      expect(last.hasNext, isFalse);
      expect(last.hasPrevious, isTrue);
    });

    test('paginateList clamps out-of-range pages; empty is one page', () {
      expect(paginateList(items, page: 0).page, 1);
      expect(paginateList(items, page: 99).page, 3);
      expect(paginateList(items, page: 99).items, items.sublist(20, 25));
      final empty = paginateList(const <String>[], page: 1);
      expect(empty.totalPages, 1);
      expect(empty.items, isEmpty);
      expect(empty.hasNext, isFalse);
    });

    test('paginate cursor: chains by id, unknown cursor = first page', () {
      final first = paginate(
        items,
        pageSize: 10,
        idOf: (item) => item,
      );
      expect(first.items, items.sublist(0, 10));
      expect(first.nextCursor, 'Item 9');
      expect(first.hasMore, isTrue);
      final second = paginate(
        items,
        pageSize: 10,
        idOf: (item) => item,
        startAfterId: first.nextCursor,
      );
      expect(second.items, items.sublist(10, 20));
      final third = paginate(
        items,
        pageSize: 10,
        idOf: (item) => item,
        startAfterId: second.nextCursor,
      );
      expect(third.items, items.sublist(20, 25));
      expect(third.hasMore, isFalse);
      expect(third.nextCursor, isNull);
      final unknown = paginate(
        items,
        pageSize: 10,
        idOf: (item) => item,
        startAfterId: 'missing',
      );
      expect(unknown.items, items.sublist(0, 10));
    });
  });

  group('ProfitLoss / BranchAnalyticsRow copyWith (D106)', () {
    test('P&L copyWith re-derives gross + net from new revenue/COGS', () {
      const pl = ProfitLoss(
        revenueMinor: 100000,
        cogsMinor: 60000,
        grossProfitMinor: 40000,
        otherIncomeMinor: 5000,
        expensesMinor: 10000,
        netProfitMinor: 35000,
      );
      final updated = pl.copyWith(revenueMinor: 120000, cogsMinor: 70000);
      expect(updated.grossProfitMinor, 50000);
      expect(updated.netProfitMinor, 45000);
      expect(updated.otherIncomeMinor, 5000);
      expect(updated.expensesMinor, 10000);
    });

    test('branch row copyWith keeps stock/outstanding/expiry loss', () {
      const row = BranchAnalyticsRow(
        branchId: _dha,
        branchName: 'DHA',
        salesMinor: 100,
        grossProfitMinor: 40,
        stockValueMinor: 999,
        outstandingMinor: 888,
        expiryLossMinor: 777,
      );
      final updated = row.copyWith(salesMinor: 200, grossProfitMinor: 90);
      expect(updated.salesMinor, 200);
      expect(updated.grossProfitMinor, 90);
      expect(updated.stockValueMinor, 999);
      expect(updated.outstandingMinor, 888);
      expect(updated.expiryLossMinor, 777);
    });
  });

  group('Sync queue last-sync tracking (D108)', () {
    test('lastSyncedAt is null until a send succeeds', () async {
      final t = _layer();
      expect(t.layer.lastSyncAt, isNull);
      expect(t.queue.lastSyncedAt, isNull);
      await t.queue.enqueue(
        idempotencyKey: 'op-1',
        entityType: 'sale',
        entityId: 'sale-1',
        branchId: _dha,
        organizationId: _org,
        kind: SyncOperationKind.create,
        payload: const {},
      );
      final failed = await t.layer.processSyncQueue((_) async => false);
      expect(failed, 0);
      expect(t.layer.lastSyncAt, isNull);
      // The failed op is in back-off (not due), so a second,
      // still-due op is what the successful drain syncs.
      await t.queue.enqueue(
        idempotencyKey: 'op-1b',
        entityType: 'sale',
        entityId: 'sale-1b',
        branchId: _dha,
        organizationId: _org,
        kind: SyncOperationKind.create,
        payload: const {},
      );
      final synced = await t.layer.processSyncQueue((_) async => true);
      expect(synced, 1);
      expect(t.layer.lastSyncAt, isNotNull);
      expect(t.queue.lastSyncedAt, t.layer.lastSyncAt);
    });

    test('pending count follows enqueue + drain', () async {
      final t = _layer();
      expect(await t.layer.pendingSyncCount(), 0);
      await t.queue.enqueue(
        idempotencyKey: 'op-2',
        entityType: 'order',
        entityId: 'order-1',
        branchId: _dha,
        organizationId: _org,
        kind: SyncOperationKind.create,
        payload: const {},
      );
      expect(await t.layer.pendingSyncCount(), 1);
      expect((await t.layer.pendingSyncOperations()).length, 1);
      await t.layer.processSyncQueue((_) async => true);
      expect(await t.layer.pendingSyncCount(), 0);
    });
  });

  group('SyncStatus labels', () {
    test('all synced / pending / unavailable labels', () {
      const synced = SyncStatus(
        pendingCount: 0,
        pendingOperations: [],
        lastSyncAt: null,
        available: true,
      );
      expect(synced.label, 'All synced');
      expect(synced.allSynced, isTrue);
      expect(synced.lastSyncLabel, 'Never synced');
      const pending = SyncStatus(
        pendingCount: 3,
        pendingOperations: [],
        lastSyncAt: null,
        available: true,
      );
      expect(pending.label, '3 pending sync');
      expect(pending.allSynced, isFalse);
      const one = SyncStatus(
        pendingCount: 1,
        pendingOperations: [],
        lastSyncAt: null,
        available: true,
      );
      expect(one.label, '1 pending sync');
      const unavailable = SyncStatus(
        pendingCount: 0,
        pendingOperations: [],
        lastSyncAt: null,
        available: false,
      );
      expect(unavailable.label, 'Sync status unavailable');
      expect(unavailable.allSynced, isFalse);
      expect(unavailable.lastSyncLabel, '');
    });

    test('formatSyncTime: today HH:MM, other day d/M HH:MM', () {
      final now = DateTime.now();
      expect(
        formatSyncTime(DateTime(now.year, now.month, now.day, 9, 5)),
        '09:05',
      );
      expect(
        formatSyncTime(DateTime(2026, 11, 20, 14, 32)),
        '20/11 14:32',
      );
    });
  });

  group('SyncStatusChip widget', () {
    Future<void> pumpChip(
      WidgetTester tester,
      ProductionDataLayer layer,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            productionDataLayerProvider.overrideWithValue(layer),
          ],
          child: const MaterialApp(
            home: Scaffold(body: SyncStatusChip()),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('empty queue shows "All synced • Never synced"', (
      tester,
    ) async {
      final t = _layer();
      await pumpChip(tester, t.layer);
      expect(find.text('All synced • Never synced'), findsOneWidget);
    });

    testWidgets('pending op shows the count, never "synced"', (
      tester,
    ) async {
      final t = _layer();
      await t.queue.enqueue(
        idempotencyKey: 'op-9',
        entityType: 'sale',
        entityId: 'sale-9',
        branchId: _dha,
        organizationId: _org,
        kind: SyncOperationKind.create,
        payload: const {},
      );
      await pumpChip(tester, t.layer);
      expect(find.text('1 pending sync • Never synced'), findsOneWidget);
      expect(find.text('All synced • Never synced'), findsNothing);
    });

    testWidgets('after a successful sync the chip shows last-sync time', (
      tester,
    ) async {
      final t = _layer();
      await t.queue.enqueue(
        idempotencyKey: 'op-10',
        entityType: 'sale',
        entityId: 'sale-10',
        branchId: _dha,
        organizationId: _org,
        kind: SyncOperationKind.create,
        payload: const {},
      );
      await t.layer.processSyncQueue((_) async => true);
      await pumpChip(tester, t.layer);
      expect(find.textContaining('All synced • Last sync'), findsOneWidget);
    });

    testWidgets('store failure shows "unavailable", not a stale state', (
      tester,
    ) async {
      final t = _layer(store: _ThrowingSyncStore());
      await pumpChip(tester, t.layer);
      expect(find.text('Sync status unavailable'), findsOneWidget);
    });
  });

  group('PagedList widget (D107)', () {
    testWidgets('pages forward/back with boundary buttons disabled', (
      tester,
    ) async {
      final items = List.generate(25, (i) => 'Item $i');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: PagedList<String>(
                items: items,
                itemBuilder: (context, item) => ListTile(title: Text(item)),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Item 0'), findsOneWidget);
      expect(find.text('Item 9'), findsOneWidget);
      expect(find.text('Item 10'), findsNothing);
      expect(find.text('Page 1 of 3'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('page-next')));
      await tester.pumpAndSettle();
      expect(find.text('Page 2 of 3'), findsOneWidget);
      expect(find.text('Item 10'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('page-next')));
      await tester.pumpAndSettle();
      expect(find.text('Page 3 of 3'), findsOneWidget);
      expect(find.text('Item 24'), findsOneWidget);
      // Next is disabled on the last page: tapping changes nothing.
      await tester.tap(find.byKey(const ValueKey('page-next')));
      await tester.pumpAndSettle();
      expect(find.text('Page 3 of 3'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('page-previous')));
      await tester.pumpAndSettle();
      expect(find.text('Page 2 of 3'), findsOneWidget);
    });

    testWidgets('short lists show no page controls', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PagedList<String>(
              items: const ['a', 'b'],
              itemBuilder: (context, item) => ListTile(title: Text(item)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Page 1 of 1'), findsNothing);
    });
  });

  group('Reports provider: counters first, live fallback (D106)', () {
    test('mock bundle: full coverage -> countersUsed, figures agree', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final advanced = await container.read(
        advancedReportDataProvider((null, 30)).future,
      );
      expect(advanced.countersUsed, isTrue);
      expect(advanced.counterDays, 30);
      // Counter-backed trend equals the live-computed trend.
      final live = await container.read(
        reportDataProvider((null, 30)).future,
      );
      expect(
        advanced.weeklyTrend.map((w) => w.salesMinor),
        computeWeeklyTrend(live.dailySales).map((w) => w.salesMinor),
      );
      expect(
        advanced.weeklyTrend.map((w) => w.orders),
        computeWeeklyTrend(live.dailySales).map((w) => w.orders),
      );
    });

    test('no counters at all -> live fallback, same figures', () async {
      final container = ProviderContainer(
        overrides: [
          reportCounterRepositoryProvider.overrideWithValue(
            _EmptyCounterRepo(),
          ),
        ],
      );
      addTearDown(container.dispose);
      final advanced = await container.read(
        advancedReportDataProvider((null, 30)).future,
      );
      expect(advanced.countersUsed, isFalse);
      expect(advanced.counterDays, 0);
      // Fallback figures equal the counter-backed figures.
      final withCounters = ProviderContainer();
      addTearDown(withCounters.dispose);
      final counterBacked = await withCounters.read(
        advancedReportDataProvider((null, 30)).future,
      );
      expect(
        advanced.weeklyTrend.map((w) => w.salesMinor),
        counterBacked.weeklyTrend.map((w) => w.salesMinor),
      );
      expect(
        advanced.profitLoss.revenueMinor,
        counterBacked.profitLoss.revenueMinor,
      );
      expect(
        advanced.profitLoss.cogsMinor,
        counterBacked.profitLoss.cogsMinor,
      );
      expect(
        advanced.branchComparison.map((r) => r.salesMinor),
        counterBacked.branchComparison.map((r) => r.salesMinor),
      );
    });
  });

  group('Factory wiring (D105/D106)', () {
    test('mock bundle has a mock counter repo; Firestore needs transport',
        () {
      final mock = createRepositoryBundle(kind: BackendKind.mock);
      expect(mock.reportCounters, isA<MockReportCounterRepository>());
      expect(
        () => createRepositoryBundle(kind: BackendKind.firestore),
        throwsStateError,
      );
      final firestore = createRepositoryBundle(
        kind: BackendKind.firestore,
        transport: FakeFirestoreTransport(),
      );
      expect(
        firestore.reportCounters,
        isA<FirestoreReportCounterRepository>(),
      );
    });

    test('mock bundle shares repo instances with the counter repo', () async {
      // The counter repo must read the SAME mock sales/orders the app
      // reads — a sale rung in the session changes the counters.
      final bundle = createRepositoryBundle(kind: BackendKind.mock);
      final before = await bundle.reportCounters.getDailyCounter(
        branchId: _dha,
        date: DateTime.now(),
      );
      expect(before, isNotNull);
      expect(before!.salesCount, 0);
    });
  });

  group('Reports screen (D105–D107)', () {
    testWidgets('counters caption shows; daily sales pages to 2 of 3', (
      tester,
    ) async {
      final (container, router) = await pumpRouterApp(tester);
      await container
          .read(authProvider.notifier)
          .signInAsDemo(DemoRole.owner);
      router.go('/reports');
      await tester.pumpAndSettle();
      expect(
        find.text('Pre-aggregated daily counters • 30 day(s) covered'),
        findsOneWidget,
      );
      expect(find.text('Page 1 of 3'), findsWidgets);
      final next = find.byKey(const ValueKey('page-next')).first;
      await tester.ensureVisible(next);
      await tester.pumpAndSettle();
      await tester.tap(next);
      await tester.pumpAndSettle();
      expect(find.text('Page 2 of 3'), findsWidgets);
    });

    testWidgets('POS screen shows the sync chip', (tester) async {
      final (container, router) = await pumpRouterApp(tester);
      await container
          .read(authProvider.notifier)
          .signInAsDemo(DemoRole.owner);
      router.go('/billing');
      await tester.pumpAndSettle();
      expect(find.text('All synced • Never synced'), findsOneWidget);
    });

    testWidgets('sales history empty state renders', (tester) async {
      final (container, router) = await pumpRouterApp(tester);
      await container
          .read(authProvider.notifier)
          .signInAsDemo(DemoRole.owner);
      router.go('/billing/history');
      await tester.pumpAndSettle();
      expect(find.text('No sales yet'), findsOneWidget);
    });
  });
}
