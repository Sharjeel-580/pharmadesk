// Week 5 Day 4 tests — feature completion, part 2 (D154–D157).
//
// - D154: quarantine return / disposal approval (FR-INV-07) —
//   request → approve by a different approver, reject path,
//   disposed batch unsellable / excluded from saleable stock,
//   returned batch leaves stock, audit entries.
// - D155: POS wiring for org Settings config — disabled payment
//   method not offered, discount caps enforced, receipt width /
//   footer from settings, defaults = today's behaviour.
// - D156: closing corrections (FR-FIN-06) — reversing entry linked
//   to the original, audited, original totals adjusted.
// - D157: cash reconciliation — expected vs actual drawer count,
//   difference recorded.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:pharmadesk/core/data/audit_log.dart';
import 'package:pharmadesk/core/data/auth_repository.dart';
import 'package:pharmadesk/core/data/firestore_mappers.dart';
import 'package:pharmadesk/core/data/firestore_schema.dart';
import 'package:pharmadesk/core/data/inventory_engine.dart';
import 'package:pharmadesk/core/data/production_data_layer.dart';
import 'package:pharmadesk/core/data/sync_queue.dart';
import 'package:pharmadesk/core/routing/app_router.dart';
import 'package:pharmadesk/core/services/repositories.dart';
import 'package:pharmadesk/core/theme/app_theme.dart';
import 'package:pharmadesk/core/theme/white_label.dart';
import 'package:pharmadesk/features/authentication/auth_state.dart';
import 'package:pharmadesk/features/billing/billing_logic.dart';
import 'package:pharmadesk/features/billing/billing_provider.dart';
import 'package:pharmadesk/features/finance/finance_logic.dart';
import 'package:pharmadesk/features/finance/finance_provider.dart';
import 'package:pharmadesk/features/inventory/inventory_logic.dart';
import 'package:pharmadesk/features/inventory/inventory_provider.dart';
import 'package:pharmadesk/features/inventory/quarantine_outcome_logic.dart';
import 'package:pharmadesk/features/inventory/quarantine_outcome_queue.dart';
import 'package:pharmadesk/features/settings/org_settings.dart';
import 'package:pharmadesk/models/cash_reconciliation.dart';
import 'package:pharmadesk/models/closing_correction.dart';
import 'package:pharmadesk/models/daily_closing.dart';
import 'package:pharmadesk/models/inventory_item.dart';
import 'package:pharmadesk/models/quarantine_outcome_request.dart';
import 'package:pharmadesk/models/sale.dart';

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

/// An auth notifier whose user can be swapped mid-test — the
/// approval queue needs two different users in one container (the
/// requester, then a different approver).
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

/// Production layer over fresh mocks (same helper shape as the
/// Week 4 Day 5 layer tests). The [audit] writer is exposed so
/// tests can read the audit trail the layer writes.
ProductionDataLayer _layer({InMemoryAuditLogWriter? audit}) {
  final writer = audit ?? InMemoryAuditLogWriter();
  final queue = SyncQueue(InMemorySyncStore());
  final engine = InventoryEngine(organizationId: _org, audit: writer);
  return ProductionDataLayer(
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
    stockTransferRepo: MockStockTransferRepository(),
    audit: writer,
    syncQueue: queue,
    engine: engine,
  );
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

/// Drains exceptions the binding recorded during pumping (e.g.
/// RenderFlex overflows) and returns their full texts.
List<String> drainExceptions(WidgetTester tester) {
  final messages = <String>[];
  Object? error;
  while ((error = tester.takeException()) != null) {
    messages.add(error.toString());
  }
  return messages;
}

int countOverflows(List<String> drained) {
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

QuarantineOutcomeRequest _outcomeRequest({
  String requesterId = 'test-inventory_manager',
  String requesterName = 'Test inventory_manager',
}) {
  return QuarantineOutcomeRequest(
    id: 'qo-1',
    batchId: 'inv-test-1',
    batchNo: 'B-TEST-1',
    medicineId: 'med-panadol-extra',
    medicineName: 'Panadol Extra',
    branchId: _dha,
    outcome: QuarantineOutcome.dispose,
    reason: 'Damaged beyond use',
    quantityAtRequest: 12,
    requesterId: requesterId,
    requesterName: requesterName,
    requestedAt: DateTime.now(),
  );
}

DailyClosing _closing({
  String id = 'dc-1',
  int income = 250000,
  int expense = 100000,
  int opening = 0,
}) {
  return DailyClosing(
    id: id,
    branchId: _dha,
    date: _day(0),
    totalIncomeMinor: income,
    totalExpenseMinor: expense,
    openingBalanceMinor: opening,
    closingBalanceMinor: opening + income - expense,
    closedBy: 'test-owner',
    closedAt: DateTime.now(),
  );
}

Sale _sale({
  required String id,
  required SalePaymentMethod method,
  required int amountMinor,
  required DateTime createdAt,
}) {
  return Sale(
    id: id,
    invoiceNumber: 'INV-TEST-$id',
    branchId: _dha,
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

void main() {
  group('D154 — quarantine return / disposal: approval rules', () {
    test('a reason is required to file a request', () {
      expect(validateQuarantineOutcomeRequest(reason: ''), isNotNull);
      expect(validateQuarantineOutcomeRequest(reason: '   '), isNotNull);
      expect(
        validateQuarantineOutcomeRequest(reason: 'Damaged beyond use'),
        isNull,
      );
    });

    test('the requester cannot approve their own request (§5.2.4)', () {
      final request = _outcomeRequest();
      expect(
        canApproveQuarantineOutcome(
          approver: _userFor(
            'inventory_manager',
            uid: 'test-inventory_manager',
          ),
          request: request,
        ),
        isFalse,
      );
      // The requester is an Inventory Mgr — who holds no approve
      // capability at all — so even a different Inventory Mgr
      // cannot approve either.
      expect(
        canApproveQuarantineOutcome(
          approver: _userFor('inventory_manager', uid: 'test-other-im'),
          request: request,
        ),
        isFalse,
      );
    });

    test('an Owner other than the requester can approve', () {
      final request = _outcomeRequest();
      expect(
        canApproveQuarantineOutcome(
          approver: _userFor('owner', uid: 'test-owner'),
          request: request,
        ),
        isTrue,
      );
      // …but not when the Owner filed the request themself.
      final ownRequest = _outcomeRequest(
        requesterId: 'test-owner',
        requesterName: 'Test Owner',
      );
      expect(
        canApproveQuarantineOutcome(
          approver: _userFor('owner', uid: 'test-owner'),
          request: ownRequest,
        ),
        isFalse,
      );
    });

    test('a Cashier cannot approve, and nobody signed out can', () {
      final request = _outcomeRequest();
      expect(
        canApproveQuarantineOutcome(
          approver: _userFor('cashier'),
          request: request,
        ),
        isFalse,
      );
      expect(
        canApproveQuarantineOutcome(approver: null, request: request),
        isFalse,
      );
    });

    test('outcome model round-trips through toMap / fromMap', () {
      final request = _outcomeRequest().copyWith(
        status: QuarantineOutcomeStatus.approved,
        decidedById: 'test-owner',
        decidedByName: 'Test Owner',
        decidedAt: DateTime(2026, 11, 26, 10, 30),
        decisionNote: 'Agreed',
      );
      final restored = QuarantineOutcomeRequest.fromMap(
        'qo-1',
        request.toMap(),
      );
      expect(restored.outcome, QuarantineOutcome.dispose);
      expect(restored.status, QuarantineOutcomeStatus.approved);
      expect(restored.reason, 'Damaged beyond use');
      expect(restored.quantityAtRequest, 12);
      expect(restored.decidedByName, 'Test Owner');
      expect(restored.decisionNote, 'Agreed');
      expect(
        quarantineOutcomeStatus(QuarantineOutcome.returnToSupplier),
        BatchStatus.returned,
      );
      expect(
        quarantineOutcomeStatus(QuarantineOutcome.dispose),
        BatchStatus.disposed,
      );
    });
  });

  group('D154 — layer applyQuarantineOutcome', () {
    Future<InventoryItem> quarantinedBatch(ProductionDataLayer layer) async {
      final batch = (await layer.inventoryRepo.getInventory(branchId: _dha))
          .firstWhere((item) => item.medicineId == 'med-panadol-extra');
      return layer.quarantineBatch(
        batchId: batch.id,
        reason: 'Suspected damage',
        idempotencyKey: 'quarantine-outcome-setup-${batch.id}',
      );
    }

    test(
      'dispose: unsellable, excluded from saleable stock, audited',
      () async {
        final audit = InMemoryAuditLogWriter();
        final layer = _layer(audit: audit);
        final parked = await quarantinedBatch(layer);
        final disposed = await layer.applyQuarantineOutcome(
          batchId: parked.id,
          outcome: QuarantineOutcome.dispose,
          reason: 'Damaged beyond use',
          actorId: 'test-owner',
          actorName: 'Test Owner',
          idempotencyKey: 'outcome-dispose-1',
        );
        expect(disposed.status, BatchStatus.disposed);
        expect(disposed.isDisposed, isTrue);
        // The quantity stays as the destroyed count (like an expired
        // batch) — but the batch is out of the saleable pool.
        expect(disposed.quantity, parked.quantity);
        expect(isBatchSellable(disposed), isFalse);
        expect(sellableStockFor([disposed]), 0);
        expect(fefoBatchFor([disposed]), isNull);
        final entries = await audit.entries(
          entityType: 'batch',
          entityId: parked.id,
          action: 'batch.disposed',
        );
        expect(entries, hasLength(1));
        expect(entries.first.summary, contains('Damaged beyond use'));
        expect(entries.first.before, 'quarantined');
        expect(entries.first.after, 'disposed');
        expect(entries.first.actorName, 'Test Owner');
        expect(await layer.syncQueue.pendingCount(), 2);
        // A retry with the same key returns the original batch and
        // enqueues nothing more.
        final retry = await layer.applyQuarantineOutcome(
          batchId: parked.id,
          outcome: QuarantineOutcome.dispose,
          reason: 'Damaged beyond use',
          idempotencyKey: 'outcome-dispose-1',
        );
        expect(retry.id, disposed.id);
        expect(retry.status, BatchStatus.disposed);
        expect(await layer.syncQueue.pendingCount(), 2);
        expect(
          await audit.entries(
            entityType: 'batch',
            entityId: parked.id,
            action: 'batch.disposed',
          ),
          hasLength(1),
        );
      },
    );

    test('return: the batch leaves stock (quantity 0), audited', () async {
      final audit = InMemoryAuditLogWriter();
      final layer = _layer(audit: audit);
      final parked = await quarantinedBatch(layer);
      final qtyBefore = parked.quantity;
      expect(qtyBefore, greaterThan(0));
      final returned = await layer.applyQuarantineOutcome(
        batchId: parked.id,
        outcome: QuarantineOutcome.returnToSupplier,
        reason: 'Supplier agreed to take it back',
        actorId: 'test-owner',
        actorName: 'Test Owner',
        idempotencyKey: 'outcome-return-1',
      );
      expect(returned.status, BatchStatus.returned);
      expect(returned.isReturned, isTrue);
      expect(returned.quantity, 0);
      expect(isBatchSellable(returned), isFalse);
      expect(sellableStockFor([returned]), 0);
      expect(totalStockFor([returned]), 0);
      final entries = await audit.entries(
        entityType: 'batch',
        entityId: parked.id,
        action: 'batch.returned',
      );
      expect(entries, hasLength(1));
      expect(entries.first.summary, contains('Supplier agreed'));
      expect(entries.first.before, 'quarantined');
      expect(entries.first.after, 'returned');
    });

    test('an outcome on a non-quarantined batch throws', () async {
      final layer = _layer();
      final batch = (await layer.inventoryRepo.getInventory(branchId: _dha))
          .firstWhere((item) => item.medicineId == 'med-panadol-extra');
      expect(batch.status, BatchStatus.available);
      expect(
        () => layer.applyQuarantineOutcome(
          batchId: batch.id,
          outcome: QuarantineOutcome.dispose,
          reason: 'Nope',
          idempotencyKey: 'outcome-bad-1',
        ),
        throwsArgumentError,
      );
      // And a second outcome on an already-decided batch throws
      // with a new key (the first decision stands).
      final parked = await quarantinedBatch(layer);
      await layer.applyQuarantineOutcome(
        batchId: parked.id,
        outcome: QuarantineOutcome.dispose,
        reason: 'Damaged beyond use',
        idempotencyKey: 'outcome-bad-2',
      );
      expect(
        () => layer.applyQuarantineOutcome(
          batchId: parked.id,
          outcome: QuarantineOutcome.returnToSupplier,
          reason: 'Too late',
          idempotencyKey: 'outcome-bad-3',
        ),
        throwsArgumentError,
      );
    });
  });

  group('D154 — quarantine outcome queue notifier', () {
    Future<ProviderContainer> containerAs(
      AppUser user, {
      _MutableAuthNotifier? auth,
    }) async {
      final container = ProviderContainer(
        overrides: [
          authProvider.overrideWith(() => auth ?? _FixedAuthNotifier(user)),
        ],
      );
      addTearDown(container.dispose);
      await container.read(inventoryProvider.future);
      return container;
    }

    Future<InventoryItem> quarantinePanadol(ProviderContainer c) async {
      final batch =
          (await c
                  .read(inventoryRepositoryProvider)
                  .getInventory(branchId: _dha))
              .firstWhere((item) => item.medicineId == 'med-panadol-extra');
      final updated = await c
          .read(inventoryProvider.notifier)
          .quarantineBatch(batchId: batch.id, reason: 'Suspected damage');
      return updated!;
    }

    test(
      'request → approve by a different approver returns the batch',
      () async {
        final auth = _MutableAuthNotifier(_userFor('inventory_manager'));
        final container = await containerAs(
          _userFor('inventory_manager'),
          auth: auth,
        );
        final parked = await quarantinePanadol(container);
        final request = container
            .read(quarantineOutcomeQueueProvider.notifier)
            .requestOutcome(
              batch: parked,
              medicineName: 'Panadol Extra',
              outcome: QuarantineOutcome.returnToSupplier,
              reason: 'Supplier agreed to take it back',
            );
        expect(request, isNotNull);
        expect(request!.isPending, isTrue);
        expect(request.outcome, QuarantineOutcome.returnToSupplier);
        // The batch has not moved yet — approval is what moves it.
        final stillParked =
            (await container
                    .read(inventoryRepositoryProvider)
                    .getInventory(branchId: _dha))
                .firstWhere((item) => item.id == parked.id);
        expect(stillParked.status, BatchStatus.quarantined);
        // The requester cannot approve their own request.
        final selfApprove = await container
            .read(quarantineOutcomeQueueProvider.notifier)
            .approveOutcome(requestId: request.id);
        expect(selfApprove, isNull);
        expect(
          container.read(quarantineOutcomeQueueProvider).first.isPending,
          isTrue,
        );
        // A different approver (Owner) approves — the batch leaves
        // stock.
        auth.user = _userFor('owner', uid: 'test-owner');
        final approved = await container
            .read(quarantineOutcomeQueueProvider.notifier)
            .approveOutcome(requestId: request.id);
        expect(approved, isNotNull);
        expect(approved!.status, QuarantineOutcomeStatus.approved);
        expect(approved.decidedByName, 'Test owner');
        final moved =
            (await container
                    .read(inventoryRepositoryProvider)
                    .getInventory(branchId: _dha))
                .firstWhere((item) => item.id == parked.id);
        expect(moved.status, BatchStatus.returned);
        expect(moved.quantity, 0);
        // Approving again is a no-op (not pending any more).
        final again = await container
            .read(quarantineOutcomeQueueProvider.notifier)
            .approveOutcome(requestId: request.id);
        expect(again, isNull);
      },
    );

    test('reject leaves the batch quarantined', () async {
      final auth = _MutableAuthNotifier(_userFor('inventory_manager'));
      final container = await containerAs(
        _userFor('inventory_manager'),
        auth: auth,
      );
      final parked = await quarantinePanadol(container);
      final request = container
          .read(quarantineOutcomeQueueProvider.notifier)
          .requestOutcome(
            batch: parked,
            medicineName: 'Panadol Extra',
            outcome: QuarantineOutcome.dispose,
            reason: 'Damaged beyond use',
          );
      expect(request, isNotNull);
      auth.user = _userFor('owner', uid: 'test-owner');
      final rejected = container
          .read(quarantineOutcomeQueueProvider.notifier)
          .rejectOutcome(requestId: request!.id, note: 'Restore it instead');
      expect(rejected, isNotNull);
      expect(rejected!.status, QuarantineOutcomeStatus.rejected);
      expect(rejected.decisionNote, 'Restore it instead');
      final stillParked =
          (await container
                  .read(inventoryRepositoryProvider)
                  .getInventory(branchId: _dha))
              .firstWhere((item) => item.id == parked.id);
      expect(stillParked.status, BatchStatus.quarantined);
      expect(stillParked.quantity, parked.quantity);
    });

    test('a request with no reason is refused', () async {
      final container = await containerAs(_userFor('inventory_manager'));
      final parked = await quarantinePanadol(container);
      final request = container
          .read(quarantineOutcomeQueueProvider.notifier)
          .requestOutcome(
            batch: parked,
            medicineName: 'Panadol Extra',
            outcome: QuarantineOutcome.dispose,
            reason: '   ',
          );
      expect(request, isNull);
      expect(container.read(quarantineOutcomeQueueProvider), isEmpty);
    });
  });

  group('D154 — quarantine outcome widgets (390px)', () {
    testWidgets('inventory row files a return request; queue approves it', (
      tester,
    ) async {
      final (container, router, auth) = await pumpRouterAppWithMutableAuth(
        tester,
        _userFor('inventory_manager'),
        size: const Size(1024, 768),
      );
      router.go('/inventory');
      await tester.pump(const Duration(milliseconds: 1500));
      await tester.pumpAndSettle();
      final inventory = await container
          .read(inventoryRepositoryProvider)
          .getInventory(branchId: _dha);
      final batch = inventory.firstWhere(
        (item) => item.medicineId == 'med-panadol-extra',
      );
      final quarantineKey = ValueKey('inv-quarantine-${batch.id}');
      await tester.ensureVisible(find.byKey(quarantineKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(quarantineKey));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('quarantine-reason-field')),
        'Suspected damage',
      );
      await tester.tap(find.byKey(const ValueKey('quarantine-confirm')));
      await tester.pumpAndSettle();
      expect(find.text('Quarantined'), findsWidgets);
      // Return + Dispose appear on the quarantined row.
      final returnKey = ValueKey('inv-return-${batch.id}');
      final disposeKey = ValueKey('inv-dispose-${batch.id}');
      await tester.ensureVisible(find.byKey(returnKey));
      await tester.pumpAndSettle();
      expect(find.byKey(returnKey), findsOneWidget);
      expect(find.byKey(disposeKey), findsOneWidget);
      await tester.tap(find.byKey(returnKey));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('quarantine-outcome-reason-field')),
        'Supplier agreed to take it back',
      );
      await tester.tap(
        find.byKey(const ValueKey('quarantine-outcome-confirm')),
      );
      await tester.pumpAndSettle();
      // The request is filed (the snackbar is transient and queues
      // behind the quarantine snackbar, so assert the queue state).
      expect(container.read(quarantineOutcomeQueueProvider), hasLength(1));
      expect(
        container.read(quarantineOutcomeQueueProvider).first.status,
        QuarantineOutcomeStatus.pending,
      );
      // The queue shows the pending request; the requester sees the
      // waiting note, not Approve buttons.
      router.go('/inventory/quarantine-outcomes');
      await tester.pumpAndSettle();
      // The title also appears in the desktop sidebar at this width.
      expect(find.text('Quarantine Outcomes'), findsWidgets);
      expect(find.textContaining('Return to supplier'), findsWidgets);
      expect(
        find.text('Waiting for an approver (not the requester).'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('quarantine-outcome-approve-qo-1')),
        findsNothing,
      );
      // A different approver (Owner) approves — the batch returns.
      auth.user = _userFor('owner', uid: 'test-owner');
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('quarantine-outcome-approve-qo-1')),
      );
      await tester.pumpAndSettle();
      // The request leaves the pending state — the waiting note and
      // the approve button are gone, and the queue records it
      // approved (the approve snackbar is transient, so assert state).
      expect(
        find.text('Waiting for an approver (not the requester).'),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('quarantine-outcome-approve-qo-1')),
        findsNothing,
      );
      expect(
        container.read(quarantineOutcomeQueueProvider).first.status,
        QuarantineOutcomeStatus.approved,
      );
      final moved =
          (await container
                  .read(inventoryRepositoryProvider)
                  .getInventory(branchId: _dha))
              .firstWhere((item) => item.id == batch.id);
      expect(moved.status, BatchStatus.returned);
      expect(moved.quantity, 0);
      expect(countOverflows(drainExceptions(tester)), 0);
    });

    testWidgets('quarantine outcomes screen is clean at 390px', (tester) async {
      final (_, router) = await pumpRouterAppAsRole(
        tester,
        'owner',
        size: _phoneSize,
      );
      router.go('/inventory/quarantine-outcomes');
      await tester.pumpAndSettle();
      expect(find.text('Quarantine Outcomes'), findsOneWidget);
      expect(
        find.textContaining('No return / disposal requests yet'),
        findsOneWidget,
      );
      expect(countOverflows(drainExceptions(tester)), 0);
    });
  });

  group('D155 — POS Settings wiring: pure functions', () {
    test('defaults offer cash, card and credit — today\'s behaviour', () {
      expect(posPaymentMethods(const OrgSettings()), [
        SalePaymentMethod.cash,
        SalePaymentMethod.card,
        SalePaymentMethod.credit,
      ]);
    });

    test('a disabled method is not offered', () {
      final noCash = const OrgSettings().copyWith(
        paymentMethods: {OrgPaymentMethod.card, OrgPaymentMethod.credit},
      );
      expect(posPaymentMethods(noCash), [
        SalePaymentMethod.card,
        SalePaymentMethod.credit,
      ]);
      final cardOnly = const OrgSettings().copyWith(
        paymentMethods: {OrgPaymentMethod.card},
      );
      expect(posPaymentMethods(cardOnly), [SalePaymentMethod.card]);
    });

    test('recorded-only methods never appear in the POS picker', () {
      // Bank transfer / JazzCash / Easypaisa are recorded methods
      // (FR-POS-04) with no POS settlement flow — enabling them
      // does not invent a checkout path.
      final recordedOnly = const OrgSettings().copyWith(
        paymentMethods: {
          OrgPaymentMethod.bankTransfer,
          OrgPaymentMethod.jazzCash,
          OrgPaymentMethod.easypaisa,
        },
      );
      expect(posPaymentMethods(recordedOnly), isEmpty);
    });

    test('line discount cap clamps; no cap leaves it unchanged', () {
      expect(
        cappedLineDiscountMinor(lineGrossMinor: 100000, discountMinor: 5000),
        5000,
      );
      expect(
        cappedLineDiscountMinor(
          lineGrossMinor: 100000,
          discountMinor: 20000,
          maxPercent: 10,
        ),
        10000,
      );
      expect(
        cappedLineDiscountMinor(
          lineGrossMinor: 100000,
          discountMinor: 8000,
          maxPercent: 10,
        ),
        8000,
      );
      // Never above the line gross, cap or no cap.
      expect(
        cappedLineDiscountMinor(
          lineGrossMinor: 100000,
          discountMinor: 150000,
          maxPercent: 90,
        ),
        90000,
      );
    });

    test('bill discount cap clamps; no cap leaves it unchanged', () {
      expect(
        cappedBillDiscountMinor(subtotalMinor: 200000, discountMinor: 30000),
        30000,
      );
      expect(
        cappedBillDiscountMinor(
          subtotalMinor: 200000,
          discountMinor: 30000,
          maxPercent: 10,
        ),
        20000,
      );
      expect(
        cappedBillDiscountMinor(
          subtotalMinor: 200000,
          discountMinor: 15000,
          maxPercent: 10,
        ),
        15000,
      );
    });

    test('validateSale refuses discounts above the caps', () {
      final line = CartLine(
        medicineId: 'med-panadol-extra',
        medicineName: 'Panadol Extra',
        unitPriceMinor: 100000,
        quantity: 1,
        lineDiscountMinor: 20000,
      );
      final overCap = validateSale(
        lines: [line],
        paymentMethod: SalePaymentMethod.card,
        maxLineDiscountPercent: 10,
      );
      expect(overCap, isNotEmpty);
      expect(overCap.first, contains('maximum 10%'));
      final withinCap = validateSale(
        lines: [line.copyWith(lineDiscountMinor: 10000)],
        paymentMethod: SalePaymentMethod.card,
        maxLineDiscountPercent: 10,
      );
      expect(withinCap, isEmpty);
      final billOver = validateSale(
        lines: [line.copyWith(lineDiscountMinor: 0)],
        billDiscountMinor: 20000,
        paymentMethod: SalePaymentMethod.card,
        maxBillDiscountPercent: 10,
      );
      expect(billOver, isNotEmpty);
      expect(billOver.first, contains('maximum 10%'));
      // No caps configured = today's behaviour (no cap errors).
      final noCaps = validateSale(
        lines: [line],
        billDiscountMinor: 50000,
        paymentMethod: SalePaymentMethod.card,
      );
      expect(noCaps, isEmpty);
    });

    test('receiptText: footer and 58mm width from settings', () {
      final sale = _sale(
        id: 's1',
        method: SalePaymentMethod.cash,
        amountMinor: 50000,
        createdAt: DateTime(2026, 11, 26, 10, 0),
      );
      final plain = receiptText(
        sale: sale,
        branchName: 'DHA Main',
        branchAddress: 'DHA Lahore',
        brandHeader: 'PharmaDesk',
      );
      expect(plain, contains('Thank you for shopping with us!'));
      expect(plain, contains('--------------------------------'));
      expect(plain, isNot(contains('No exchange')));
      final withFooter = receiptText(
        sale: sale,
        branchName: 'DHA Main',
        branchAddress: 'DHA Lahore',
        brandHeader: 'PharmaDesk',
        receiptFooter: 'No exchange without a bill.',
        receiptPaperWidthMm: 58,
      );
      expect(withFooter, contains('No exchange without a bill.'));
      expect(withFooter, contains('------------------------'));
      expect(withFooter, isNot(contains('--------------------------------')));
    });
  });

  group('D155 — POS Settings wiring: provider + widgets', () {
    test('completeSale refuses a bill discount above the cap', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final medicines = await container
          .read(medicineRepositoryProvider)
          .getMedicines();
      final medicine = medicines.firstWhere((m) => m.id == 'med-panadol-extra');
      final inventory = await container
          .read(inventoryRepositoryProvider)
          .getInventory(branchId: _dha);
      final sellable = sellableStockFor(
        inventory.where((item) => item.medicineId == medicine.id),
      );
      expect(sellable, greaterThan(0));
      final before =
          (await container
                  .read(saleRepositoryProvider)
                  .getSales(branchId: _dha))
              .length;
      final line = CartLine(
        medicineId: medicine.id,
        medicineName: medicine.name,
        unitPriceMinor: medicine.priceMinor,
        quantity: 1,
      );
      final refused = await container
          .read(salesProvider.notifier)
          .completeSale(
            branchId: _dha,
            cashierName: 'Test Cashier',
            lines: [line],
            billDiscountMinor: line.grossMinor * 20 ~/ 100,
            paymentMethod: SalePaymentMethod.card,
            maxBillDiscountPercent: 10,
          );
      expect(refused.sale, isNull);
      expect(refused.error, contains('maximum 10%'));
      final after =
          (await container
                  .read(saleRepositoryProvider)
                  .getSales(branchId: _dha))
              .length;
      expect(after, before);
      // The same discount completes fine with no cap configured.
      final allowed = await container
          .read(salesProvider.notifier)
          .completeSale(
            branchId: _dha,
            cashierName: 'Test Cashier',
            lines: [line],
            billDiscountMinor: line.grossMinor * 20 ~/ 100,
            paymentMethod: SalePaymentMethod.card,
          );
      expect(allowed.error, isNull);
      expect(allowed.sale, isNotNull);
    });

    testWidgets('disabled cash is not offered on the POS (390px)', (
      tester,
    ) async {
      final (container, router) = await pumpRouterAppAsRole(
        tester,
        'cashier',
        size: _phoneSize,
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
      expect(countOverflows(drainExceptions(tester)), 0);
    });

    testWidgets('defaults offer all three methods (390px)', (tester) async {
      final (_, router) = await pumpRouterAppAsRole(
        tester,
        'cashier',
        size: _phoneSize,
      );
      router.go('/billing');
      await tester.pumpAndSettle();
      expect(find.text('Cash'), findsOneWidget);
      expect(find.text('Card'), findsOneWidget);
      expect(find.text('Credit (khata)'), findsOneWidget);
      expect(countOverflows(drainExceptions(tester)), 0);
    });

    testWidgets('receipt preview uses the configured width and footer', (
      tester,
    ) async {
      final (container, router) = await pumpRouterAppAsRole(
        tester,
        'cashier',
        size: _phoneSize,
      );
      // The mock sale repo starts empty (no seeded sales) — save one
      // first, then open its receipt.
      final savedSale = await container
          .read(saleRepositoryProvider)
          .upsertSale(
            _sale(
              id: 'sale-receipt-1',
              method: SalePaymentMethod.cash,
              amountMinor: 125000,
              createdAt: DateTime(2026, 11, 26, 12, 0),
            ),
          );
      final settings = container.read(orgSettingsProvider.notifier);
      settings.setReceiptPaperWidth(58);
      settings.setReceiptFooter('No exchange without a bill.');
      router.go('/billing/receipt/${savedSale.id}');
      await tester.pumpAndSettle();
      expect(find.text('No exchange without a bill.'), findsWidgets);
      expect(find.text('Receipt paper: 58mm'), findsOneWidget);
      expect(countOverflows(drainExceptions(tester)), 0);
    });
  });

  group('D156 — closing corrections: pure logic', () {
    test('validation needs an original, non-negative totals, a reason', () {
      final original = _closing();
      expect(
        validateClosingCorrection(
          original: null,
          correctedIncomeMinor: 100,
          correctedExpenseMinor: 100,
          reason: 'x',
        ),
        isNotEmpty,
      );
      expect(
        validateClosingCorrection(
          original: original,
          correctedIncomeMinor: -1,
          correctedExpenseMinor: 0,
          reason: 'x',
        ),
        isNotEmpty,
      );
      expect(
        validateClosingCorrection(
          original: original,
          correctedIncomeMinor: 100,
          correctedExpenseMinor: 0,
          reason: '   ',
        ),
        isNotEmpty,
      );
      expect(
        validateClosingCorrection(
          original: original,
          correctedIncomeMinor: 100,
          correctedExpenseMinor: 0,
          reason: 'Income was entered twice',
        ),
        isEmpty,
      );
    });

    test('adjusted totals: original until corrected, latest wins', () {
      final original = _closing();
      final none = adjustedClosingTotals(
        original: original,
        corrections: const [],
      );
      expect(none.corrected, isFalse);
      expect(none.incomeMinor, 250000);
      expect(none.closingBalanceMinor, 150000);
      final first = ClosingCorrection(
        id: 'cc-1',
        branchId: _dha,
        originalClosingId: 'dc-1',
        date: _day(0),
        correctedIncomeMinor: 200000,
        correctedExpenseMinor: 100000,
        correctedClosingBalanceMinor: 100000,
        reason: 'Rs 500 income entered twice',
        correctedAt: DateTime(2026, 11, 26, 10, 0),
      );
      final one = adjustedClosingTotals(
        original: original,
        corrections: [first],
      );
      expect(one.corrected, isTrue);
      expect(one.incomeMinor, 200000);
      expect(one.closingBalanceMinor, 100000);
      expect(one.correctionId, 'cc-1');
      final second = first.copyWith(
        id: 'cc-2',
        correctedIncomeMinor: 210000,
        correctedExpenseMinor: 90000,
        correctedClosingBalanceMinor: 120000,
        reason: 'Second look',
        correctedAt: DateTime(2026, 11, 26, 11, 0),
      );
      final two = adjustedClosingTotals(
        original: original,
        corrections: [first, second],
      );
      expect(two.incomeMinor, 210000);
      expect(two.expenseMinor, 90000);
      expect(two.closingBalanceMinor, 120000);
      expect(two.correctionId, 'cc-2');
      // A correction for a different closing is ignored.
      final other = first.copyWith(
        id: 'cc-3',
        originalClosingId: 'dc-9',
        correctedIncomeMinor: 1,
      );
      final ignored = adjustedClosingTotals(
        original: original,
        corrections: [other],
      );
      expect(ignored.corrected, isFalse);
      expect(ignored.incomeMinor, 250000);
    });
  });

  group('D156 — closing corrections: layer + notifier', () {
    test('layer records a correction with audit + sync, idempotent', () async {
      final audit = InMemoryAuditLogWriter();
      final layer = _layer(audit: audit);
      final correction = ClosingCorrection(
        id: '',
        branchId: _dha,
        originalClosingId: 'dc-1',
        date: _day(0),
        correctedIncomeMinor: 200000,
        correctedExpenseMinor: 100000,
        correctedClosingBalanceMinor: 100000,
        reason: 'Rs 500 income entered twice',
        correctedBy: 'test-owner',
        correctedAt: DateTime.now(),
      );
      final created = await layer.recordClosingCorrection(
        correction: correction,
        actorId: 'test-owner',
        actorName: 'Test Owner',
        idempotencyKey: 'correction-test-1',
      );
      expect(created.id, isNotEmpty);
      expect(created.originalClosingId, 'dc-1');
      final entries = await audit.entries(
        entityType: 'dailyClosing',
        entityId: 'dc-1',
        action: 'closing.corrected',
      );
      expect(entries, hasLength(1));
      expect(entries.first.summary, contains('Rs 500 income entered twice'));
      expect(await layer.syncQueue.pendingCount(), 1);
      final retry = await layer.recordClosingCorrection(
        correction: correction,
        idempotencyKey: 'correction-test-1',
      );
      expect(retry.id, created.id);
      expect(await layer.syncQueue.pendingCount(), 1);
      expect(
        await audit.entries(
          entityType: 'dailyClosing',
          entityId: 'dc-1',
          action: 'closing.corrected',
        ),
        hasLength(1),
      );
    });

    test('notifier corrects a closing; the original is unchanged', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final closed = await container
          .read(dailyClosingsProvider.notifier)
          .closeDay(branchId: _dha, date: _day(0));
      expect(closed.error, isNull);
      final original = closed.closing!;
      // Today's close is empty (no entries recorded) — correct it
      // to Rs 500 income / Rs 100 expense.
      final result = await container
          .read(closingCorrectionsProvider.notifier)
          .correctClosing(
            original: original,
            correctedIncomeMinor: 50000,
            correctedExpenseMinor: 10000,
            reason: 'Missed a Rs 500 cash sale',
          );
      expect(result.error, isNull);
      expect(result.correction, isNotNull);
      expect(result.correction!.originalClosingId, original.id);
      // The derived balance is opening + income − expense.
      expect(result.correction!.correctedClosingBalanceMinor, 40000);
      // The original record is untouched in the repo.
      final reread = await container
          .read(dailyClosingRepositoryProvider)
          .getClosing(branchId: _dha, date: _day(0));
      expect(reread!.totalIncomeMinor, 0);
      expect(reread.closingBalanceMinor, 0);
      // …but the adjusted view shows the corrected figures.
      final corrections = await container
          .read(closingCorrectionRepositoryProvider)
          .getCorrections(branchId: _dha);
      final adjusted = adjustedClosingTotals(
        original: original,
        corrections: corrections,
      );
      expect(adjusted.corrected, isTrue);
      expect(adjusted.incomeMinor, 50000);
      expect(adjusted.closingBalanceMinor, 40000);
    });

    test('a Pharmacist cannot correct a closing', () async {
      final container = ProviderContainer(
        overrides: [
          authProvider.overrideWith(
            () => _FixedAuthNotifier(_userFor('pharmacist')),
          ),
        ],
      );
      addTearDown(container.dispose);
      final result = await container
          .read(closingCorrectionsProvider.notifier)
          .correctClosing(
            original: _closing(),
            correctedIncomeMinor: 100,
            correctedExpenseMinor: 0,
            reason: 'x',
          );
      expect(result.correction, isNull);
      expect(result.error, isNotNull);
    });

    test('mock repos assign ids and filter by closing', () async {
      final repo = MockClosingCorrectionRepository();
      final first = await repo.createCorrection(
        ClosingCorrection(
          id: '',
          branchId: _dha,
          originalClosingId: 'dc-1',
          date: _day(0),
          correctedIncomeMinor: 100,
          correctedExpenseMinor: 0,
          correctedClosingBalanceMinor: 100,
          reason: 'a',
        ),
      );
      await repo.createCorrection(
        ClosingCorrection(
          id: '',
          branchId: _dha,
          originalClosingId: 'dc-2',
          date: _day(0),
          correctedIncomeMinor: 200,
          correctedExpenseMinor: 0,
          correctedClosingBalanceMinor: 200,
          reason: 'b',
        ),
      );
      expect(first.id, isNotEmpty);
      final forDc1 = await repo.getCorrectionsForClosing('dc-1');
      expect(forDc1, hasLength(1));
      expect(forDc1.first.reason, 'a');
      expect((await repo.getCorrections(branchId: _dha)), hasLength(2));
    });

    test('correction mapper round-trips and validates', () {
      final correction = ClosingCorrection(
        id: 'cc-9',
        branchId: _dha,
        originalClosingId: 'dc-1',
        date: _day(0),
        correctedIncomeMinor: 200000,
        correctedExpenseMinor: 100000,
        correctedClosingBalanceMinor: 100000,
        reason: 'Rs 500 income entered twice',
        correctedBy: 'test-owner',
        correctedAt: DateTime(2026, 11, 26, 10, 0),
      );
      final doc = closingCorrectionToFirestore(correction, orgId: _org);
      final restored = closingCorrectionFromFirestore('cc-9', doc);
      expect(restored.originalClosingId, 'dc-1');
      expect(restored.correctedIncomeMinor, 200000);
      expect(restored.reason, 'Rs 500 income entered twice');
    });
  });

  group('D157 — cash reconciliation: pure logic', () {
    test('expected drawer: opening + cash sales + income − expenses', () {
      final day = _day(0);
      final sales = [
        _sale(
          id: 's1',
          method: SalePaymentMethod.cash,
          amountMinor: 500000,
          createdAt: day.add(const Duration(hours: 10)),
        ),
        _sale(
          id: 's2',
          method: SalePaymentMethod.card,
          amountMinor: 300000,
          createdAt: day.add(const Duration(hours: 11)),
        ),
        _sale(
          id: 's3',
          method: SalePaymentMethod.credit,
          amountMinor: 200000,
          createdAt: day.add(const Duration(hours: 12)),
        ),
        // Yesterday's cash sale does not count for today.
        _sale(
          id: 's4',
          method: SalePaymentMethod.cash,
          amountMinor: 999999,
          createdAt: _day(1).add(const Duration(hours: 10)),
        ),
      ];
      final entries = cashbookEntries(
        expenses: [],
        transactions: [],
        branchId: _dha,
      );
      expect(
        expectedDrawerMinor(
          sales: sales,
          entries: entries,
          openingBalanceMinor: 100000,
          date: day,
        ),
        // Opening 100,000 + cash sale 500,000. Card + credit never
        // touch the drawer; yesterday's sale is another day.
        600000,
      );
    });

    test('expected drawer counts cashbook income and expenses', () {
      final day = _day(0);
      final entries = <CashbookEntry>[
        (
          id: 'e1',
          date: day.add(const Duration(hours: 9)),
          kind: CashbookEntryKind.income,
          category: 'Other income',
          amountMinor: 50000,
          note: '',
          referenceId: null,
        ),
        (
          id: 'e2',
          date: day.add(const Duration(hours: 10)),
          kind: CashbookEntryKind.expense,
          category: 'Supplies',
          amountMinor: 20000,
          note: '',
          referenceId: null,
        ),
        (
          id: 'e3',
          date: _day(1),
          kind: CashbookEntryKind.expense,
          category: 'Supplies',
          amountMinor: 77700,
          note: '',
          referenceId: null,
        ),
      ];
      expect(
        expectedDrawerMinor(
          sales: const [],
          entries: entries,
          openingBalanceMinor: 0,
          date: day,
        ),
        30000,
      );
    });

    test('difference: over, short, exact; validation', () {
      expect(
        cashReconciliationDifference(
          expectedMinor: 100000,
          countedMinor: 105000,
        ),
        5000,
      );
      expect(
        cashReconciliationDifference(
          expectedMinor: 100000,
          countedMinor: 95000,
        ),
        -5000,
      );
      expect(
        cashReconciliationDifference(
          expectedMinor: 100000,
          countedMinor: 100000,
        ),
        0,
      );
      expect(
        validateCashReconciliation(countedMinor: -1, date: _day(0)),
        isNotEmpty,
      );
      expect(
        validateCashReconciliation(
          countedMinor: 0,
          date: DateTime.now().add(const Duration(days: 1)),
        ),
        isNotEmpty,
      );
      expect(
        validateCashReconciliation(countedMinor: 0, date: _day(0)),
        isEmpty,
      );
    });
  });

  group('D157 — cash reconciliation: layer + notifier', () {
    test('layer records a count with audit + sync, idempotent', () async {
      final audit = InMemoryAuditLogWriter();
      final layer = _layer(audit: audit);
      final recon = CashReconciliation(
        id: '',
        branchId: _dha,
        date: _day(0),
        expectedMinor: 600000,
        countedMinor: 595000,
        differenceMinor: -5000,
        note: 'Rs 50 short',
        countedBy: 'test-owner',
        countedAt: DateTime.now(),
      );
      final created = await layer.recordCashReconciliation(
        reconciliation: recon,
        actorId: 'test-owner',
        actorName: 'Test Owner',
        idempotencyKey: 'recon-test-1',
      );
      expect(created.id, isNotNull);
      expect(created.differenceMinor, -5000);
      expect(created.isShort, isTrue);
      final entries = await audit.entries(
        entityType: 'cashReconciliation',
        entityId: created.id,
        action: 'cash.reconciled',
      );
      expect(entries, hasLength(1));
      expect(entries.first.summary, contains('595000'));
      expect(await layer.syncQueue.pendingCount(), 1);
      final retry = await layer.recordCashReconciliation(
        reconciliation: recon,
        idempotencyKey: 'recon-test-1',
      );
      expect(retry.id, created.id);
      expect(await layer.syncQueue.pendingCount(), 1);
    });

    test('notifier reconciles today against live figures', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      // Today: Rs 250 income, Rs 100 expense — no closing yet, so
      // the opening is 0.
      await container
          .read(expensesProvider.notifier)
          .recordExpense(
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
      // The expected drawer, computed the same way the notifier
      // computes it, from the live repos.
      final sales = await container
          .read(saleRepositoryProvider)
          .getSales(branchId: _dha);
      final expenses = await container
          .read(expenseRepositoryProvider)
          .getExpenses(branchId: _dha);
      final transactions = await container
          .read(financialTransactionRepositoryProvider)
          .getTransactions(branchId: _dha);
      final expected = expectedDrawerMinor(
        sales: sales,
        entries: cashbookEntries(
          expenses: expenses,
          transactions: transactions,
          branchId: _dha,
        ),
        openingBalanceMinor: 0,
        date: _day(0),
      );
      final result = await container
          .read(cashReconciliationsProvider.notifier)
          .reconcileDay(
            branchId: _dha,
            date: _day(0),
            countedMinor: expected + 500,
            note: 'Counted twice',
          );
      expect(result.error, isNull);
      expect(result.reconciliation, isNotNull);
      expect(result.reconciliation!.expectedMinor, expected);
      expect(result.reconciliation!.countedMinor, expected + 500);
      expect(result.reconciliation!.differenceMinor, 500);
      expect(result.reconciliation!.isOver, isTrue);
    });

    test('a Pharmacist cannot reconcile cash', () async {
      final container = ProviderContainer(
        overrides: [
          authProvider.overrideWith(
            () => _FixedAuthNotifier(_userFor('pharmacist')),
          ),
        ],
      );
      addTearDown(container.dispose);
      final result = await container
          .read(cashReconciliationsProvider.notifier)
          .reconcileDay(branchId: _dha, date: _day(0), countedMinor: 1000);
      expect(result.reconciliation, isNull);
      expect(result.error, isNotNull);
    });

    test('mock repo assigns ids and filters by day', () async {
      final repo = MockCashReconciliationRepository();
      final first = await repo.createReconciliation(
        CashReconciliation(
          id: '',
          branchId: _dha,
          date: _day(0),
          expectedMinor: 100,
          countedMinor: 100,
          differenceMinor: 0,
        ),
      );
      await repo.createReconciliation(
        CashReconciliation(
          id: '',
          branchId: _dha,
          date: _day(1),
          expectedMinor: 200,
          countedMinor: 150,
          differenceMinor: -50,
        ),
      );
      expect(first.id, isNotEmpty);
      final today = await repo.getReconciliationsForDay(
        branchId: _dha,
        date: _day(0),
      );
      expect(today, hasLength(1));
      expect(today.first.differenceMinor, 0);
      expect((await repo.getReconciliations(branchId: _dha)), hasLength(2));
    });

    test('reconciliation mapper round-trips and validates', () {
      final recon = CashReconciliation(
        id: 'cr-9',
        branchId: _dha,
        date: _day(0),
        expectedMinor: 600000,
        countedMinor: 595000,
        differenceMinor: -5000,
        note: 'Rs 50 short',
        countedBy: 'test-owner',
        countedAt: DateTime(2026, 11, 26, 18, 0),
      );
      final doc = cashReconciliationToFirestore(recon, orgId: _org);
      final restored = cashReconciliationFromFirestore('cr-9', doc);
      expect(restored.expectedMinor, 600000);
      expect(restored.differenceMinor, -5000);
      expect(restored.isShort, isTrue);
      expect(restored.note, 'Rs 50 short');
    });
  });

  group('D156 + D157 — cashbook widgets (390px)', () {
    testWidgets('close a day, correct it, reconcile the drawer', (
      tester,
    ) async {
      final (container, router) = await pumpRouterAppAsRole(
        tester,
        'owner',
        size: _phoneSize,
      );
      router.go('/finance/cashbook');
      await tester.pumpAndSettle();
      expect(find.text('Cashbook'), findsOneWidget);
      // Record today's entries first so the closing has figures:
      // Rs 250 income, Rs 100 expense.
      await container
          .read(expensesProvider.notifier)
          .recordExpense(
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
      await tester.pumpAndSettle();
      // Close the day.
      await tester.tap(find.text('Close this day'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Close day'));
      await tester.pumpAndSettle();
      expect(find.textContaining('closed.'), findsOneWidget);
      // Correct the closing: income was really Rs 200, not Rs 250.
      final closings =
          container.read(dailyClosingsProvider).asData?.value ?? const [];
      expect(closings, hasLength(1));
      final correctKey = ValueKey('correct-closing-${closings.first.id}');
      await tester.ensureVisible(find.byKey(correctKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(correctKey));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('correct-income-field')),
        '200',
      );
      await tester.enterText(
        find.byKey(const ValueKey('correct-reason-field')),
        'Rs 50 income entered twice',
      );
      await tester.tap(find.byKey(const ValueKey('correct-closing-confirm')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Corrected:'), findsOneWidget);
      expect(find.textContaining('Rs 50 income entered twice'), findsOneWidget);
      // The original figures are still shown above the correction.
      expect(find.textContaining('In Rs 250.00'), findsOneWidget);
      // Reconcile the drawer: expected is computed live; count
      // Rs 5 over it.
      final sales = await container
          .read(saleRepositoryProvider)
          .getSales(branchId: _dha);
      final expenses = await container
          .read(expenseRepositoryProvider)
          .getExpenses(branchId: _dha);
      final transactions = await container
          .read(financialTransactionRepositoryProvider)
          .getTransactions(branchId: _dha);
      final expected = expectedDrawerMinor(
        sales: sales,
        entries: cashbookEntries(
          expenses: expenses,
          transactions: transactions,
          branchId: _dha,
        ),
        openingBalanceMinor: 0,
        date: _day(0),
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('recon-counted-field')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('recon-counted-field')),
        (expected ~/ 100 + 5).toString(),
      );
      await tester.ensureVisible(find.byKey(const ValueKey('recon-record')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('recon-record')));
      await tester.pumpAndSettle();
      // The recorded row is the persistent proof (the reconcile
      // snackbar is transient and queues behind earlier ones).
      expect(find.textContaining('over'), findsWidgets);
      expect(find.textContaining('Expected'), findsWidgets);
      expect(countOverflows(drainExceptions(tester)), 0);
    });
  });
}
