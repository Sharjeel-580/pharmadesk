// Week 4 Day 4 tests — system hub: branch management (D-28) +
// audit log (D-33) + backup & restore (D-35) + settings completion
// (D-34) (D130–D136).
//
// - Branch model: SRS §3.1 fields round-trip; defaults are own /
//   no rates; `branchRateLabel` never shows a missing rate as 0%.
// - Branch directory: seeded from the demo branches, add / update /
//   activate / deactivate (last active protected), validation.
// - Audit filter: branch, actor, action family, date range,
//   newest-first, branch scope (Branch Mgr own / Auditor all /
//   Cashier none); distinct families + actors.
// - Backup: export → validate → import round-trip into the layer's
//   restore sink (second import adds nothing, overwrite replaces),
//   validation failures, section counts, size formatting, status
//   notifier.
// - Org settings: defaults are today's behaviour (tax 0%, POS
//   methods on, 80mm, no caps); bounds enforced.
// - Routes + gates (widget): all four new routes resolve, role
//   gates (Cashier blocked everywhere, Auditor read-only on
//   branches + audit log, blocked on backup), sidebar entries,
//   branch add end to end, audit entries render, backup create +
//   restore end to end, Settings Organization + Sync tabs.
//
// What is NOT tested here (and why): the web download itself
// (the download util is a no-op off-web — export content is what
// is verified); restore into the live repositories (no upsert-by-id
// exists — D133 follow-up); the POS reading the payment-method /
// discount-limit settings (not wired yet — D134 follow-up).

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
import 'package:pharmadesk/core/data/sync_queue.dart';
import 'package:pharmadesk/core/routing/app_router.dart';
import 'package:pharmadesk/core/services/repositories.dart';
import 'package:pharmadesk/core/theme/app_theme.dart';
import 'package:pharmadesk/core/theme/white_label.dart';
import 'package:pharmadesk/features/audit/audit_logic.dart';
import 'package:pharmadesk/features/authentication/auth_state.dart';
import 'package:pharmadesk/features/backup/backup_logic.dart';
import 'package:pharmadesk/features/backup/backup_provider.dart';
import 'package:pharmadesk/features/branches/branch_directory.dart';
import 'package:pharmadesk/features/settings/org_settings.dart';
import 'package:pharmadesk/models/branch.dart';

const _dha = 'branch-dha-main';
const _glb = 'branch-demo-gulberg';
const _org = demoOrganizationId;

/// Production layer over fresh mocks (same helper shape as the
/// Week 4 Day 2 layer tests).
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

AppUser _userFor(String roleKey, {List<String> branchIds = const [_dha]}) {
  return AppUser(
    uid: 'test-$roleKey',
    email: '$roleKey@test.pharmadesk',
    displayName: 'Test $roleKey',
    orgId: _org,
    branchIds: branchIds,
    roleKey: roleKey,
  );
}

AuditLogEntry _entry({
  String branchId = _dha,
  String actorName = 'Test Owner',
  String action = 'sale.committed',
  int daysAgo = 0,
}) {
  final now = DateTime.now();
  return AuditLogEntry.create(
    organizationId: _org,
    branchId: branchId,
    userId: 'test-owner',
    actorName: actorName,
    action: action,
    entityType: 'sale',
    entityId: 'sale-1',
    summary: 'Test entry $action',
    createdAt: DateTime(now.year, now.month, now.day).subtract(
      Duration(days: daysAgo),
    ),
  );
}

void main() {
  group('Branch model — SRS §3.1 fields (D130)', () {
    test('fromMap/toMap round-trips type, manager and rates', () {
      const branch = Branch(
        id: 'branch-test',
        name: 'Test Franchise',
        address: 'Somewhere, Lahore',
        phone: '0300-9999999',
        type: 'franchise',
        managerId: 'staff-1',
        franchiseFeeRateBps: 500,
        royaltyRateBps: 250,
      );
      final restored = Branch.fromMap(branch.id, branch.toMap());
      expect(restored.type, 'franchise');
      expect(restored.isFranchise, true);
      expect(restored.managerId, 'staff-1');
      expect(restored.franchiseFeeRateBps, 500);
      expect(restored.royaltyRateBps, 250);
    });

    test('defaults are own branch with no rates set', () {
      const branch = Branch(
        id: 'branch-x',
        name: 'X',
        address: 'Y',
        phone: 'Z',
      );
      expect(branch.type, 'own');
      expect(branch.isFranchise, false);
      expect(branch.managerId, isNull);
      expect(branch.franchiseFeeRateBps, isNull);
      expect(branch.royaltyRateBps, isNull);
      final restored = Branch.fromMap(branch.id, branch.toMap());
      expect(restored.type, 'own');
      expect(restored.franchiseFeeRateBps, isNull);
    });

    test('branchRateLabel never shows a missing rate as 0%', () {
      expect(branchRateLabel(null), 'Not set');
      expect(branchRateLabel(0), '0%');
      expect(branchRateLabel(500), '5%');
      expect(branchRateLabel(250), '2.50%');
    });

    test('copyWith clears rates only when asked', () {
      const branch = Branch(
        id: 'branch-x',
        name: 'X',
        address: 'Y',
        phone: 'Z',
        franchiseFeeRateBps: 500,
      );
      expect(branch.copyWith(name: 'X2').franchiseFeeRateBps, 500);
      expect(
        branch.copyWith(clearFranchiseFeeRateBps: true).franchiseFeeRateBps,
        isNull,
      );
    });
  });

  group('Branch directory (D131)', () {
    test('seeds from the two demo branches', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final branches = container.read(branchDirectoryProvider);
      expect(branches.length, 2);
      expect(branches.map((b) => b.id), containsAll([_dha, _glb]));
    });

    test('addBranch adds; empty name refused', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(branchDirectoryProvider.notifier);
      // Week 5 Day 2 (D148): add / update / setActive persist
      // through the layer first, so they are async now.
      final errors = await notifier.addBranch(
        const Branch(
          id: 'branch-model-town',
          name: 'Demo Branch — Model Town',
          address: 'Model Town, Lahore',
          phone: '0300-3333333',
        ),
      );
      expect(errors, isEmpty);
      expect(container.read(branchDirectoryProvider).length, 3);
      final bad = await notifier.addBranch(
        const Branch(id: 'branch-x', name: '  ', address: '', phone: ''),
      );
      expect(bad, contains('Branch name is required.'));
      expect(container.read(branchDirectoryProvider).length, 3);
    });

    test('addBranch refuses a duplicate id', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(branchDirectoryProvider.notifier);
      final errors = await notifier.addBranch(
        const Branch(id: _dha, name: 'Copy', address: '', phone: ''),
      );
      expect(errors, isNotEmpty);
      expect(container.read(branchDirectoryProvider).length, 2);
    });

    test('updateBranch changes address and phone', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(branchDirectoryProvider.notifier);
      final branch = container.read(branchDirectoryProvider).first;
      final errors = await notifier.updateBranch(
        branch.id,
        branch.copyWith(address: 'New address', phone: '0300-0000000'),
      );
      expect(errors, isEmpty);
      final updated = notifier.byId(branch.id)!;
      expect(updated.address, 'New address');
      expect(updated.phone, '0300-0000000');
      expect(updated.id, branch.id);
    });

    test('setActive deactivates; the last active branch is protected',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(branchDirectoryProvider.notifier);
      expect(await notifier.setActive(_glb, false), isEmpty);
      expect(notifier.byId(_glb)!.active, false);
      final errors = await notifier.setActive(_dha, false);
      expect(errors, contains('The last active branch cannot be deactivated.'));
      expect(notifier.byId(_dha)!.active, true);
      expect(await notifier.setActive(_glb, true), isEmpty);
    });

    test('validateBranchForm refuses rates over 100%', () {
      expect(
        validateBranchForm(name: 'X', franchiseFeeRateBps: 10001),
        contains('Franchise fee rate must be between 0% and 100%.'),
      );
      expect(
        validateBranchForm(name: 'X', royaltyRateBps: 10000),
        isEmpty,
      );
    });
  });

  group('Branch gates — SRS §5.1 `branches`', () {
    test('owner and HO admin write; auditor reads only; others none', () {
      expect(canViewBranches(_userFor('owner'), _dha), true);
      expect(canWriteBranches(_userFor('owner'), _dha), true);
      expect(canViewBranches(_userFor('ho_admin'), _dha), true);
      expect(canWriteBranches(_userFor('ho_admin'), _dha), true);
      expect(canViewBranches(_userFor('auditor'), _dha), true);
      expect(canWriteBranches(_userFor('auditor'), _dha), false);
      expect(canViewBranches(_userFor('branch_manager'), _dha), false);
      expect(canWriteBranches(_userFor('branch_manager'), _dha), false);
      expect(canViewBranches(_userFor('cashier'), _dha), false);
    });
  });

  group('Audit filter (D132)', () {
    final entries = [
      _entry(branchId: _dha, actorName: 'Owner', action: 'sale.committed'),
      _entry(
        branchId: _dha,
        actorName: 'Owner',
        action: 'sale.duplicate_skipped',
        daysAgo: 2,
      ),
      _entry(
        branchId: _glb,
        actorName: 'Manager',
        action: 'ledger.credit_sale',
        daysAgo: 5,
      ),
      _entry(
        branchId: _dha,
        actorName: 'Manager',
        action: 'stock.receive',
        daysAgo: 40,
      ),
    ];

    test('branch filter', () {
      expect(filterAuditEntries(entries, branchId: _glb).length, 1);
      expect(filterAuditEntries(entries, branchId: _dha).length, 3);
    });

    test('actor filter', () {
      expect(filterAuditEntries(entries, actorName: 'Manager').length, 2);
      expect(filterAuditEntries(entries, actorName: 'Nobody').length, 0);
    });

    test('action family prefix matches the whole family only', () {
      final sales = filterAuditEntries(entries, actionPrefix: 'sale');
      expect(sales.length, 2);
      expect(
        filterAuditEntries(entries, actionPrefix: 'ledger').length,
        1,
      );
      expect(
        filterAuditEntries(entries, actionPrefix: 'sale.committed').length,
        1,
      );
    });

    test('date range is inclusive; undated entries need no bounds', () {
      final now = DateTime.now();
      final from = DateTime(now.year, now.month, now.day).subtract(
        const Duration(days: 6),
      );
      final recent = filterAuditEntries(entries, from: from);
      expect(recent.length, 3);
      final to = DateTime(now.year, now.month, now.day).subtract(
        const Duration(days: 1),
      );
      expect(filterAuditEntries(entries, to: to).length, 3);
      final undated = [
        const AuditLogEntry(
          id: 'audit-x',
          organizationId: _org,
          branchId: _dha,
          userId: 'u',
          actorName: 'Owner',
          action: 'sale.committed',
          entityType: 'sale',
          entityId: 's',
        ),
      ];
      expect(filterAuditEntries(undated).length, 1);
      expect(filterAuditEntries(undated, from: from).length, 0);
    });

    test('results are newest first', () {
      final filtered = filterAuditEntries(entries);
      expect(filtered.first.action, 'sale.committed');
      expect(filtered.last.action, 'stock.receive');
    });

    test('scope: branch manager own branch, auditor all, cashier none', () {
      final manager = _userFor('branch_manager', branchIds: [_glb]);
      final scoped = auditVisibleEntries(entries, manager);
      expect(scoped.length, 1);
      expect(scoped.first.branchId, _glb);
      expect(auditVisibleEntries(entries, _userFor('auditor')).length, 4);
      expect(auditVisibleEntries(entries, _userFor('owner')).length, 4);
      expect(auditVisibleEntries(entries, _userFor('cashier')), isEmpty);
    });

    test('distinct families and actors', () {
      expect(auditActionFamilies(entries), ['sale', 'ledger', 'stock']);
      expect(auditActors(entries), ['Owner', 'Manager']);
    });
  });

  group('Backup round-trip (D133)', () {
    test('export → validate → import: same docs, second import adds nothing',
        () async {
      final layer = _layer();
      final doc = await layer.exportBackup();
      expect(DataImporter.validateBackup(doc), isEmpty);
      // Week 5 Day 2 (D150): the restore now targets the LIVE repos,
      // so importing an export of the live data itself creates
      // nothing under skip policy — every doc already exists.
      final first = await layer.importBackup(doc);
      expect(first.success, true);
      expect(first.created, 0);
      expect(first.skipped, backupTotalDocs(doc));
      final second = await layer.importBackup(doc);
      expect(second.created, 0);
      expect(second.skipped, backupTotalDocs(doc));
      expect(layer.restoredData.count('medicines'), greaterThan(0));
    });

    test('overwrite policy replaces instead of duplicating', () async {
      final layer = _layer();
      final doc = await layer.exportBackup();
      final first = await layer.importBackup(doc);
      expect(first.skipped, backupTotalDocs(doc));
      final again = await layer.importBackup(
        doc,
        policy: ImportPolicy.overwrite,
      );
      expect(again.created, 0);
      expect(again.overwritten, backupTotalDocs(doc));
      expect(again.skipped, 0);
    });

    test('validateBackup rejects bad format, version and sections', () {
      expect(
        DataImporter.validateBackup({'format': 'other'}),
        isNotEmpty,
      );
      expect(
        DataImporter.validateBackup({
          'format': 'pharmadesk-backup',
          'formatVersion': 99,
          'organizationId': _org,
          'sections': {},
        }),
        isNotEmpty,
      );
      expect(
        DataImporter.validateBackup({
          'format': 'pharmadesk-backup',
          'formatVersion': 1,
          'organizationId': _org,
        }),
        isNotEmpty,
      );
    });

    test('a malformed doc aborts the whole import', () async {
      final layer = _layer();
      final report = await layer.importBackup({
        'format': 'pharmadesk-backup',
        'formatVersion': 1,
        'organizationId': _org,
        'sections': {
          'medicines': [
            {'name': 'No id here'},
          ],
        },
      });
      expect(report.success, false);
      expect(report.created, 0);
      expect(layer.restoredData.count('medicines'), 0);
    });

    test('section counts, totals and size formatting', () {
      const doc = {
        'sections': {
          'medicines': [
            {'id': 'm1'},
            {'id': 'm2'},
          ],
          'sales': [
            {'id': 's1'},
          ],
          'auditLogs': <Map<String, dynamic>>[],
        },
      };
      expect(backupSectionCounts(doc), {
        'medicines': 2,
        'sales': 1,
        'auditLogs': 0,
      });
      expect(backupTotalDocs(doc), 3);
      expect(backupSectionNames(doc), ['medicines', 'sales', 'auditLogs']);
      expect(backupJsonSizeBytes(doc), greaterThan(0));
      expect(formatBackupSize(512), '512 B');
      expect(formatBackupSize(2048), '2.0 KB');
      expect(formatBackupSize(3 * 1024 * 1024), '3.0 MB');
    });

    test('backup status notifier records backup then restore', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(backupStatusProvider.notifier);
      expect(container.read(backupStatusProvider).hasBackup, false);
      notifier.recordBackup(
        at: DateTime(2026, 11, 26, 10, 30),
        sizeBytes: 12345,
        totalDocs: 42,
        sections: const {'medicines': 10, 'sales': 32},
      );
      final afterBackup = container.read(backupStatusProvider);
      expect(afterBackup.hasBackup, true);
      expect(afterBackup.lastBackupTotalDocs, 42);
      expect(afterBackup.lastBackupSections['medicines'], 10);
      notifier.recordRestore(applied: 40, skipped: 2);
      final afterRestore = container.read(backupStatusProvider);
      expect(afterRestore.hasRestore, true);
      expect(afterRestore.lastRestoreApplied, 40);
      expect(afterRestore.lastRestoreSkipped, 2);
      expect(afterRestore.hasBackup, true);
    });
  });

  group('Org settings defaults + validation (D134)', () {
    test('defaults are today\'s behaviour', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final settings = container.read(orgSettingsProvider);
      expect(settings.taxRatePercent, 0);
      expect(settings.paymentMethods, {
        OrgPaymentMethod.cash,
        OrgPaymentMethod.card,
        OrgPaymentMethod.credit,
      });
      expect(settings.receiptPaperWidthMm, 80);
      expect(settings.receiptFooter, '');
      expect(settings.maxLineDiscountPercent, isNull);
      expect(settings.maxBillDiscountPercent, isNull);
    });

    test('tax rate bounds enforced', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(orgSettingsProvider.notifier);
      expect(notifier.setTaxRate(101), false);
      expect(container.read(orgSettingsProvider).taxRatePercent, 0);
      expect(notifier.setTaxRate(5), true);
      expect(container.read(orgSettingsProvider).taxRatePercent, 5);
    });

    test('payment methods toggle', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(orgSettingsProvider.notifier);
      notifier.togglePaymentMethod(OrgPaymentMethod.jazzCash, true);
      expect(
        container.read(orgSettingsProvider).paymentMethods,
        contains(OrgPaymentMethod.jazzCash),
      );
      notifier.togglePaymentMethod(OrgPaymentMethod.cash, false);
      expect(
        container.read(orgSettingsProvider).paymentMethods,
        isNot(contains(OrgPaymentMethod.cash)),
      );
    });

    test('receipt format: width bounds, footer stored', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(orgSettingsProvider.notifier);
      expect(notifier.setReceiptPaperWidth(100), false);
      expect(notifier.setReceiptPaperWidth(58), true);
      expect(
        container.read(orgSettingsProvider).receiptPaperWidthMm,
        58,
      );
      notifier.setReceiptFooter('Thank you');
      expect(container.read(orgSettingsProvider).receiptFooter, 'Thank you');
    });

    test('discount caps set, clear and refuse out-of-range', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(orgSettingsProvider.notifier);
      expect(notifier.setMaxLineDiscountPercent(150), false);
      expect(notifier.setMaxLineDiscountPercent(10), true);
      expect(
        container.read(orgSettingsProvider).maxLineDiscountPercent,
        10,
      );
      expect(notifier.setMaxBillDiscountPercent(null), true);
      expect(
        container.read(orgSettingsProvider).maxBillDiscountPercent,
        isNull,
      );
      expect(
        validateOrgSettings(
          taxRatePercent: 0,
          receiptPaperWidthMm: 80,
          maxLineDiscountPercent: 101,
        ),
        isNotEmpty,
      );
    });
  });

  group('Route capabilities (D135)', () {
    test('system-hub routes map to their §5.1 rows', () {
      expect(routeCapability('/branches'), 'branches');
      expect(routeCapability('/branches/branch-dha-main'), 'branches');
      expect(routeCapability('/audit-log'), 'auditLog');
      expect(routeCapability('/backup'), 'sysSettings');
      expect(routeCapability('/settings'), isNull);
    });
  });

  group('Widget: routes, gates, screens', () {
    testWidgets('route walk: all four system-hub routes render',
        (WidgetTester tester) async {
      final (_, router) = await pumpRouterApp(tester);
      const routes = <(String, String)>[
        ('/branches', 'Branch Management'),
        ('/branches/branch-dha-main', 'Franchise settings'),
        ('/audit-log', 'Audit Log'),
        ('/backup', 'Backup & Restore'),
      ];
      for (final (route, marker) in routes) {
        router.go(route);
        await tester.pumpAndSettle();
        expect(
          find.textContaining(marker),
          findsWidgets,
          reason: '$route should render ($marker)',
        );
        expect(find.text('Page not found'), findsNothing);
      }
    });

    testWidgets('settings shows the Organization and Sync tabs',
        (WidgetTester tester) async {
      final (_, router) = await pumpRouterApp(tester);
      router.go('/settings');
      await tester.pumpAndSettle();
      expect(find.text('Organization'), findsOneWidget);
      expect(find.text('Sync'), findsOneWidget);
      await tester.tap(find.text('Organization'));
      await tester.pumpAndSettle();
      expect(find.text('Tax config'), findsOneWidget);
      expect(find.text('Payment methods'), findsOneWidget);
      expect(find.text('Receipt format'), findsOneWidget);
      expect(find.text('Discount limits'), findsOneWidget);
      await tester.tap(find.text('Sync'));
      await tester.pumpAndSettle();
      expect(find.text('Sync status'), findsOneWidget);
      expect(find.text('Never synced'), findsWidgets);
    });

    testWidgets('branch list shows both demo branches; add works end to end',
        (WidgetTester tester) async {
      final (_, router) = await pumpRouterApp(tester);
      router.go('/branches');
      await tester.pumpAndSettle();
      // Each name also appears once in the top-bar branch switcher,
      // so the list assertions use findsWidgets.
      expect(find.text('Demo Branch — DHA'), findsWidgets);
      expect(find.text('Demo Branch — Gulberg'), findsWidgets);
      await tester.tap(find.text('Add branch'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Franchise settings'), findsWidgets);
      await tester.enterText(
        find.byType(TextField).first,
        'Demo Branch — Model Town',
      );
      await tester.tap(find.text('Add branch').last);
      await tester.pumpAndSettle();
      expect(find.text('Demo Branch — Model Town'), findsOneWidget);
    });

    testWidgets('branch detail shows fields and unset franchise rates',
        (WidgetTester tester) async {
      final (_, router) = await pumpRouterApp(tester);
      router.go('/branches/branch-dha-main');
      await tester.pumpAndSettle();
      // The name also appears in the top-bar branch switcher.
      expect(find.text('Demo Branch — DHA'), findsWidgets);
      expect(find.text('DHA Phase 2, Lahore'), findsOneWidget);
      expect(find.text('Franchise settings'), findsOneWidget);
      expect(find.text('Not set'), findsNWidgets(2));
      expect(find.text('Edit branch'), findsOneWidget);
    });

    testWidgets('cashier is stopped at every system-hub route',
        (WidgetTester tester) async {
      final (_, router) = await pumpRouterAppAsRole(tester, 'cashier');
      for (final route in ['/branches', '/audit-log', '/backup']) {
        router.go(route);
        await tester.pumpAndSettle();
        expect(
          find.textContaining('No permission'),
          findsOneWidget,
          reason: 'cashier must be stopped at $route',
        );
      }
    });

    testWidgets('auditor reads branches + audit log, not backup',
        (WidgetTester tester) async {
      final (_, router) = await pumpRouterAppAsRole(tester, 'auditor');
      router.go('/branches');
      await tester.pumpAndSettle();
      expect(find.text('Branch Management'), findsWidgets);
      expect(find.text('Add branch'), findsNothing);
      router.go('/audit-log');
      await tester.pumpAndSettle();
      expect(find.text('Audit Log'), findsWidgets);
      router.go('/backup');
      await tester.pumpAndSettle();
      expect(find.textContaining('No permission'), findsOneWidget);
    });

    testWidgets('sidebar lists the system-hub entries (owner)',
        (WidgetTester tester) async {
      final (_, router) = await pumpRouterApp(
        tester,
        size: const Size(1920, 3000),
      );
      router.go('/dashboard');
      await tester.pumpAndSettle();
      expect(find.text('Branch Management'), findsOneWidget);
      expect(find.text('Audit Log'), findsOneWidget);
      expect(find.text('Backup & Restore'), findsOneWidget);
    });

    testWidgets('audit log renders seeded entries from the writer store',
        (WidgetTester tester) async {
      final audit = InMemoryAuditLogWriter();
      await audit.write(_entry(action: 'sale.committed'));
      await audit.write(
        _entry(
          branchId: _glb,
          actorName: 'Manager',
          action: 'stock.receive',
          daysAgo: 3,
        ),
      );
      final layer = _layer(audit: audit);
      final (_, router) = await pumpRouterApp(
        tester,
        layerOverride: layer,
      );
      router.go('/audit-log');
      await tester.pumpAndSettle();
      expect(find.text('sale.committed'), findsOneWidget);
      expect(find.text('stock.receive'), findsOneWidget);
      expect(find.text('2 entries'), findsOneWidget);
    });

    testWidgets('backup: create records status; bad restore JSON errors',
        (WidgetTester tester) async {
      final (_, router) = await pumpRouterApp(tester);
      router.go('/backup');
      await tester.pumpAndSettle();
      expect(find.text('Backup status'), findsOneWidget);
      expect(
        find.text('No backup created yet in this session.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Create backup'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Last backup'), findsOneWidget);
      await tester.enterText(
        find.byType(TextField).first,
        '{not json',
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('restore-validate-button')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('restore-validate-button')));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('The pasted text is not valid JSON.'),
        findsOneWidget,
      );
    });

    testWidgets('backup: restore round-trips through confirm dialog',
        (WidgetTester tester) async {
      final layer = _layer();
      // A small hand-built backup (not the full export — the
      // export of the seeded catalogue is far too long to paste
      // through a text field in a widget test).
      final backup = {
        'format': 'pharmadesk-backup',
        'formatVersion': 1,
        'organizationId': _org,
        'exportedAt': DateTime.now().toIso8601String(),
        'sections': {
          'medicines': [
            {'id': 'm1', 'name': 'Test Medicine'},
          ],
          'sales': <Map<String, dynamic>>[],
        },
      };
      final json = jsonEncode(backup);
      final (_, router) = await pumpRouterApp(
        tester,
        layerOverride: layer,
      );
      router.go('/backup');
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, json);
      await tester.ensureVisible(
        find.byKey(const ValueKey('restore-validate-button')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('restore-validate-button')));
      await tester.pumpAndSettle();
      expect(find.text('Restore this backup?'), findsOneWidget);
      expect(
        find.textContaining('will replace the current live data'),
        findsOneWidget,
      );
      await tester.tap(find.text('Restore backup'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Restore complete:'), findsOneWidget);
      expect(layer.restoredData.count('medicines'), 1);
    });
  });
}

class _FixedAuthNotifier extends AuthNotifier {
  _FixedAuthNotifier(this.user);

  final AppUser user;

  @override
  AppUser? build() => user;
}

/// Pumps the ungated router app with a fresh container the test owns
/// (same harness as the Week 4 Day 3 widget tests), at a desktop
/// viewport. [layerOverride] swaps the production data layer (so
/// tests can seed the audit writer / backup sink the screens read).
Future<(ProviderContainer, GoRouter)> pumpRouterApp(
  WidgetTester tester, {
  Size size = const Size(1920, 1080),
  ProductionDataLayer? layerOverride,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final container = ProviderContainer(
    overrides: [
      if (layerOverride != null)
        productionDataLayerProvider.overrideWithValue(layerOverride),
    ],
  );
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

/// Pumps the router app signed in as [roleKey] (see [_userFor]).
Future<(ProviderContainer, GoRouter)> pumpRouterAppAsRole(
  WidgetTester tester,
  String roleKey, {
  List<String> branchIds = const [_dha],
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1920, 1080);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final user = _userFor(roleKey, branchIds: branchIds);
  final container = ProviderContainer(
    overrides: [
      authProvider.overrideWith(() => _FixedAuthNotifier(user)),
    ],
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
  return (container, router);
}
