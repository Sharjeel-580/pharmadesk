// Week 6 Day 3 tests — active-branch directory support + branch code
// validation (D163, D164).
//
// Part A (D163): `ActiveBranchNotifier.switchTo` resolves the branch
// directory, so a branch added via Branch Management can become the
// active branch. The lookup is a one-shot `ref.read` inside
// `switchTo` — never a `ref.watch` in `build()` — so a directory
// change neither resets the active branch nor forms a provider
// cycle; an unknown id returns `false` and leaves the active branch
// unchanged instead of crashing. The shell switcher lists the
// directory (not just the demo const).
//
// Part B (D164): the `Branch` model carries the SRS §3 `code` with a
// migration-safe default derived from the branch id; the Firestore
// mapper writes it, validates the doc against the §3 `branches`
// contract, and reads legacy docs without (or with an invalid) code
// back to the derived default — never a crash, never an empty code.
//
// Part C (Super Admin franchise-view gate): SKIPPED — no Dazy
// decision is recorded anywhere in docs/ (week-6-brief §3, D159 and
// the Week 5 tracker all say "pending Dazy's decision"), so per the
// brief nothing is guessed or built here.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharmadesk/core/data/auth_repository.dart';
import 'package:pharmadesk/core/data/firestore_mappers.dart';
import 'package:pharmadesk/core/data/firestore_repositories.dart';
import 'package:pharmadesk/core/data/firestore_schema.dart';
import 'package:pharmadesk/core/data/firestore_transport.dart';
import 'package:pharmadesk/core/data/inventory_engine.dart';
import 'package:pharmadesk/core/routing/app_router.dart';
import 'package:pharmadesk/core/services/branch_context.dart';
import 'package:pharmadesk/core/services/repositories.dart';
import 'package:pharmadesk/core/theme/app_theme.dart';
import 'package:pharmadesk/core/theme/white_label.dart';
import 'package:pharmadesk/features/authentication/auth_state.dart';
import 'package:pharmadesk/features/branches/branch_directory.dart';
import 'package:pharmadesk/models/branch.dart';

const _dha = 'branch-dha-main';
const _glb = 'branch-demo-gulberg';
const _org = demoOrganizationId;

const _modelTown = Branch(
  id: 'branch-model-town',
  name: 'Demo Branch — Model Town',
  address: 'Model Town, Lahore',
  phone: '0300-3333333',
);

/// Adds the Model Town branch to [container]'s directory.
Future<void> _addModelTown(ProviderContainer container) async {
  final errors = await container
      .read(branchDirectoryProvider.notifier)
      .addBranch(_modelTown);
  expect(errors, isEmpty);
}

void main() {
  group('ActiveBranchNotifier — directory resolution (D163)', () {
    test('starts on DHA; switching to demo Gulberg works (unchanged)',
        () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(activeBranchProvider).id, _dha);
      final switched = container
          .read(activeBranchProvider.notifier)
          .switchTo(_glb);
      expect(switched, isTrue);
      expect(container.read(activeBranchProvider).id, _glb);
      expect(container.read(activeBranchProvider).name,
          'Demo Branch — Gulberg');
    });

    test('a directory-added branch becomes the active branch', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await _addModelTown(container);
      final switched = container
          .read(activeBranchProvider.notifier)
          .switchTo('branch-model-town');
      expect(switched, isTrue);
      final active = container.read(activeBranchProvider);
      expect(active.id, 'branch-model-town');
      expect(active.name, 'Demo Branch — Model Town');
    });

    test('unknown branch id returns false; active branch unchanged',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(activeBranchProvider.notifier);
      expect(notifier.switchTo('branch-nope'), isFalse);
      expect(container.read(activeBranchProvider).id, _dha);
      expect(notifier.switchTo(_glb), isTrue);
      expect(notifier.switchTo(''), isFalse);
      expect(notifier.switchTo('branch-nope'), isFalse);
      expect(container.read(activeBranchProvider).id, _glb);
    });

    test('a later directory change never resets the active branch',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await _addModelTown(container);
      final notifier = container.read(activeBranchProvider.notifier);
      expect(notifier.switchTo('branch-model-town'), isTrue);
      // Adding (and then renaming) another branch rebuilds the
      // directory provider — the active branch must survive it.
      // This is the `ref.watch`-in-`build()` trap D163 avoids:
      // watching the directory would rebuild this notifier and
      // reset the state to the first demo branch.
      await container.read(branchDirectoryProvider.notifier).addBranch(
            const Branch(
              id: 'branch-cantt',
              name: 'Demo Branch — Cantt',
              address: 'Cantt, Lahore',
              phone: '0300-4444444',
            ),
          );
      expect(container.read(activeBranchProvider).id, 'branch-model-town');
      await container
          .read(branchDirectoryProvider.notifier)
          .updateBranch(
            'branch-cantt',
            const Branch(
              id: 'branch-cantt',
              name: 'Demo Branch — Cantt Renamed',
              address: 'Cantt, Lahore',
              phone: '0300-4444444',
            ),
          );
      expect(container.read(activeBranchProvider).id, 'branch-model-town');
      expect(container.read(activeBranchProvider).name,
          'Demo Branch — Model Town');
    });

    test('switch resolves the edited directory record, not a stale copy',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await _addModelTown(container);
      await container.read(branchDirectoryProvider.notifier).updateBranch(
            'branch-model-town',
            const Branch(
              id: 'branch-model-town',
              name: 'Demo Branch — Model Town Renamed',
              address: 'Model Town, Lahore',
              phone: '0300-3333333',
            ),
          );
      expect(
        container.read(activeBranchProvider.notifier).switchTo(
              'branch-model-town',
            ),
        isTrue,
      );
      expect(container.read(activeBranchProvider).name,
          'Demo Branch — Model Town Renamed');
    });

    test('a deactivated branch can still become active (viewing, D149)',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await _addModelTown(container);
      expect(
        await container
            .read(branchDirectoryProvider.notifier)
            .setActive('branch-model-town', false),
        isEmpty,
      );
      // FR-HO-08 guards transactions on a deactivated branch, not
      // viewing it — its history stays readable, same as the
      // franchise view (D158).
      expect(
        container
            .read(activeBranchProvider.notifier)
            .switchTo('branch-model-town'),
        isTrue,
      );
      expect(container.read(activeBranchProvider).id, 'branch-model-town');
    });
  });

  group('Shell branch switcher lists directory branches (D163)', () {
    testWidgets('directory-added branch appears and switches', (
      WidgetTester tester,
    ) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1920, 1080);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final container = ProviderContainer(
        overrides: [
          authProvider.overrideWith(
            () => _FixedAuthNotifier(_userFor('owner')),
          ),
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

      await _addModelTown(container);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('branch-switcher-button')));
      await tester.pumpAndSettle();
      // Scoped to the popup menu: the dashboard body lists branch
      // names too, so a bare text finder matches twice.
      final modelTownEntry = find.ancestor(
        of: find.text('Demo Branch — Model Town'),
        matching: find.byType(PopupMenuItem<String>),
      );
      expect(modelTownEntry, findsOneWidget);
      await tester.tap(modelTownEntry);
      await tester.pumpAndSettle();

      expect(container.read(activeBranchProvider).id, 'branch-model-town');
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('branch-switcher-button')),
          matching: find.text('Demo Branch — Model Town'),
        ),
        findsOneWidget,
      );
    });
  });

  group('Branch code — derivation + normalization (D164)', () {
    test('default code derives from the branch id', () {
      expect(defaultBranchCodeForId('branch-dha-main'), 'DHA');
      expect(defaultBranchCodeForId('branch-demo-gulberg'), 'GLB');
      expect(defaultBranchCodeForId('branch-model-town'), 'TOW');
      expect(defaultBranchCodeForId('branch-x'), 'BX');
      expect(defaultBranchCodeForId('islamabad'), 'ISL');
    });

    test('normalize keeps a valid code, fixes case/space, falls back',
        () {
      expect(normalizeBranchCode('LHR', branchId: 'branch-x'), 'LHR');
      expect(normalizeBranchCode('lhr', branchId: 'branch-x'), 'LHR');
      expect(normalizeBranchCode('  ab12  ', branchId: 'branch-x'), 'AB12');
      expect(normalizeBranchCode(null, branchId: 'branch-model-town'),
          'TOW');
      expect(normalizeBranchCode('', branchId: 'branch-model-town'), 'TOW');
      expect(normalizeBranchCode('!!', branchId: 'branch-model-town'),
          'TOW');
      expect(normalizeBranchCode('a', branchId: 'branch-model-town'), 'TOW');
      expect(
        normalizeBranchCode('ABCDEFGHI', branchId: 'branch-model-town'),
        'TOW',
      );
    });

    test('model: missing code migrates to the derived default', () {
      // A branch built without a code (demo const, add-branch form)
      // never carries an empty code where one is needed.
      const unseeded = Branch(
        id: 'branch-model-town',
        name: 'Demo Branch — Model Town',
        address: 'Model Town, Lahore',
        phone: '0300-3333333',
      );
      expect(unseeded.code, '');
      expect(unseeded.effectiveCode, 'TOW');
      // Seeded / legacy maps without a code parse to the default.
      final fromLegacy = Branch.fromMap('branch-model-town', {
        'name': 'Demo Branch — Model Town',
        'address': 'Model Town, Lahore',
        'phone': '0300-3333333',
      });
      expect(fromLegacy.code, 'TOW');
      // Lowercase and invalid stored codes normalize, never crash.
      expect(
        Branch.fromMap('branch-model-town', {
          'name': 'X',
          'code': 'tow',
        }).code,
        'TOW',
      );
      expect(
        Branch.fromMap('branch-model-town', {
          'name': 'X',
          'code': '!!!',
        }).code,
        'TOW',
      );
    });

    test('model: toMap/fromMap round-trips the code; copyWith keeps it',
        () {
      const branch = Branch(
        id: 'branch-lahore',
        name: 'Lahore Branch',
        address: 'Lahore',
        phone: '0300-1',
        code: 'LHR',
      );
      final back = Branch.fromMap(branch.id, branch.toMap());
      expect(back.code, 'LHR');
      expect(back.effectiveCode, 'LHR');
      expect(branch.copyWith(name: 'Renamed').code, 'LHR');
      expect(branch.copyWith(code: 'ISB').code, 'ISB');
      // A branch without a code exports the derived default, so a
      // backup/restore round-trip never loses it.
      expect(_modelTown.toMap()['code'], 'TOW');
    });
  });

  group('Branch mapper — §3 code validation (D164)', () {
    test('round-trips an explicit code and passes §3 validation', () {
      const branch = Branch(
        id: 'branch-lahore',
        name: 'Lahore Branch',
        address: 'Lahore',
        phone: '0300-1',
        code: 'LHR',
      );
      final doc = branchToFirestore(branch, orgId: _org);
      expect(doc['code'], 'LHR');
      expect(FirestoreSchema.validateDocument('branches', doc), isEmpty);
      final back = branchFromFirestore('branch-lahore', doc);
      expect(back.code, 'LHR');
      expect(back.name, 'Lahore Branch');
    });

    test('a branch without a code writes the derived default', () {
      final doc = branchToFirestore(_modelTown, orgId: _org);
      expect(doc['code'], 'TOW');
      expect(FirestoreSchema.validateDocument('branches', doc), isEmpty);
      expect(branchFromFirestore('branch-model-town', doc).code, 'TOW');
      // The demo branches keep their known codes.
      expect(
        branchToFirestore(demoBranches.first, orgId: _org)['code'],
        'DHA',
      );
      expect(
        branchToFirestore(demoBranches.last, orgId: _org)['code'],
        'GLB',
      );
    });

    test('legacy docs without (or with an invalid) code read back safe',
        () {
      final noCode = branchFromFirestore('branch-model-town', {
        'name': 'Legacy',
        'type': 'own',
        'status': 'closed',
      });
      expect(noCode.code, 'TOW');
      expect(noCode.active, isFalse);
      final lowerCode = branchFromFirestore('branch-demo-gulberg', {
        'name': 'Legacy',
        'code': 'glb',
      });
      expect(lowerCode.code, 'GLB');
      final badCode = branchFromFirestore('branch-model-town', {
        'name': 'Legacy',
        'code': '!!!',
      });
      expect(badCode.code, 'TOW');
    });

    test('Firestore repo round-trips the code over the memory transport',
        () async {
      final repo = FirestoreBranchRepository(
        transport: _MemoryTransport(),
        organizationId: _org,
      );
      final created = await repo.createBranch(
        const Branch(
          id: 'branch-rwp',
          name: 'Rawalpindi Branch',
          address: 'Rawalpindi',
          phone: '0300-5',
          code: 'RWP',
        ),
      );
      expect(created.code, 'RWP');
      expect((await repo.getById('branch-rwp'))!.code, 'RWP');
      // No code on create: the stored doc carries the derived one.
      await repo.createBranch(
        const Branch(
          id: 'branch-model-town',
          name: 'Demo Branch — Model Town',
          address: 'Model Town, Lahore',
          phone: '0300-3333333',
        ),
      );
      expect((await repo.getById('branch-model-town'))!.code, 'TOW');
    });
  });

  group('Mock branch repo — code is stored, never dropped (D164)', () {
    test('create keeps an explicit code; minting derives one', () async {
      final repo = MockBranchRepository();
      final created = await repo.createBranch(
        const Branch(
          id: 'branch-isb',
          name: 'Islamabad Branch',
          address: 'Islamabad',
          phone: '0300-6',
          code: 'ISB',
        ),
      );
      expect(created.code, 'ISB');
      expect((await repo.getById('branch-isb'))!.code, 'ISB');
      // Empty id mints `branch-<slug>` and the code derives from
      // the MINTED id, not the empty one.
      final minted = await repo.createBranch(
        const Branch(
          id: '',
          name: 'Model Town',
          address: 'Model Town, Lahore',
          phone: '0300-7',
        ),
      );
      expect(minted.id, 'branch-model-town');
      expect(minted.code, 'TOW');
      expect((await repo.getById('branch-model-town'))!.code, 'TOW');
    });

    test('update never stores an empty code', () async {
      final repo = MockBranchRepository();
      final branch = (await repo.getById(_dha))!;
      expect(branch.code, 'DHA');
      final updated = await repo.updateBranch(branch.copyWith(code: ''));
      expect(updated.code, 'DHA');
      expect((await repo.getById(_dha))!.code, 'DHA');
    });
  });
}

AppUser _userFor(String roleKey) {
  return AppUser(
    uid: 'test-$roleKey',
    email: '$roleKey@test.pharmadesk',
    displayName: 'Test $roleKey',
    orgId: _org,
    branchIds: const [_dha, _glb],
    roleKey: roleKey,
  );
}

class _FixedAuthNotifier extends AuthNotifier {
  _FixedAuthNotifier(this.user);

  final AppUser user;

  @override
  AppUser? build() => user;
}

/// Minimal in-memory Firestore transport (same shape as the Week 5
/// Day 2 one): only the document operations the branch repo uses.
class _MemoryTransport implements FirestoreTransport {
  final Map<String, Map<String, dynamic>> _docs = {};
  var _sequence = 0;

  @override
  Future<Map<String, dynamic>?> getDocument(String path) async =>
      _docs[path] == null
          ? null
          : Map<String, dynamic>.from(_docs[path]!);

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
    final docs = [
      for (final entry in _docs.entries)
        if (entry.key.startsWith(prefix) &&
            !entry.key.substring(prefix.length).contains('/'))
          FirestoreDocument(
            id: entry.key.substring(prefix.length),
            data: Map<String, dynamic>.from(entry.value),
          ),
    ];
    for (final filter in whereEquals.entries) {
      docs.retainWhere((doc) => doc.data[filter.key] == filter.value);
    }
    if (orderBy != null) {
      docs.sort(
        (a, b) => (a.data[orderBy]?.toString() ?? '').compareTo(
          b.data[orderBy]?.toString() ?? '',
        ),
      );
    } else {
      docs.sort((a, b) => a.id.compareTo(b.id));
    }
    if (descending) return docs.reversed.toList();
    var page = docs;
    if (startAfterId != null) {
      final index = page.indexWhere((doc) => doc.id == startAfterId);
      if (index != -1) page = page.sublist(index + 1);
    }
    if (limit != null && page.length > limit) {
      page = page.sublist(0, limit);
    }
    return page;
  }

  @override
  Future<void> setDocument(
    String path,
    Map<String, dynamic> data, {
    bool merge = false,
  }) async {
    _docs[path] = Map<String, dynamic>.from(data);
  }

  @override
  String newDocumentId(String collectionPath) {
    _sequence++;
    return 'auto-$_sequence';
  }

  @override
  Future<void> updateDocument(String path, Map<String, dynamic> data) =>
      throw UnimplementedError();

  @override
  Future<String> addDocument(
    String collectionPath,
    Map<String, dynamic> data,
  ) =>
      throw UnimplementedError();

  @override
  Future<void> runBatchedWrites(List<WriteOperation> operations) =>
      throw UnimplementedError();

  @override
  Future<T> runTransaction<T>(
    Future<T> Function(FirestoreTransaction tx) update,
  ) =>
      throw UnimplementedError();
}
