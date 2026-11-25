// Week 3 Day 1 tests — Firestore implementations for the six Day 5
// repos (Staff, Attendance, Shift, Expense, FinancialTransaction,
// SupplierPayment).
//
// The repositories run against an in-memory fake transport (copied
// from the Day 3 test — there is still no Firebase project, D13),
// so every test runs offline: mapper round-trips, schema-contract
// extensions (D99), idempotency-key doc ids (D100), validation
// failures, and the factory wiring (D101: mock default, Firestore
// kind behind the same providers).

import 'package:cloud_firestore/cloud_firestore.dart' hide Order;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmadesk/core/data/firestore_mappers.dart';
import 'package:pharmadesk/core/data/firestore_repositories.dart';
import 'package:pharmadesk/core/data/firestore_schema.dart';
import 'package:pharmadesk/core/data/firestore_transport.dart';
import 'package:pharmadesk/core/data/inventory_engine.dart'
    show WriteOperation, WriteOperationKind;
import 'package:pharmadesk/core/data/repository_factory.dart';
import 'package:pharmadesk/core/services/repositories.dart';
import 'package:pharmadesk/models/attendance.dart';
import 'package:pharmadesk/models/expense.dart';
import 'package:pharmadesk/models/financial_transaction.dart';
import 'package:pharmadesk/models/shift.dart';
import 'package:pharmadesk/models/staff.dart';
import 'package:pharmadesk/models/supplier_payment.dart';

/// In-memory [FirestoreTransport]: documents live in a map keyed by
/// full path. Same behaviour as the Day 3 fake (get / query with
/// equality filter + document-id ordering + startAfter / limit /
/// batch chunking at 500 / transactions that apply writes
/// immediately, no rollback).
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
    final id = newDocumentId(collectionPath);
    docs['$collectionPath/$id'] = Map<String, dynamic>.from(data);
    return id;
  }

  @override
  Future<void> runBatchedWrites(List<WriteOperation> operations) async {
    for (var i = 0; i < operations.length; i += maxFirestoreBatchWrites) {
      final end = (i + maxFirestoreBatchWrites).clamp(0, operations.length);
      final chunk = operations.sublist(i, end);
      for (final operation in chunk) {
        switch (operation.kind) {
          case WriteOperationKind.set:
            docs[operation.path] = Map<String, dynamic>.from(
              operation.data ?? const {},
            );
          case WriteOperationKind.update:
            final existing = docs[operation.path];
            if (existing == null) {
              throw StateError('No document at ${operation.path} to update.');
            }
            docs[operation.path] = {...existing, ...?operation.data};
          case WriteOperationKind.delete:
            docs.remove(operation.path);
        }
      }
    }
  }

  @override
  Future<T> runTransaction<T>(
    Future<T> Function(FirestoreTransaction tx) action,
  ) async {
    return action(_FakeTransaction(docs));
  }

  @override
  String newDocumentId(String collectionPath) {
    _autoId += 1;
    return 'auto-$_autoId';
  }

  /// Counts documents directly under [collectionPath].
  int countIn(String collectionPath) {
    return docs.keys.where((path) {
      if (!path.startsWith('$collectionPath/')) return false;
      return !path.substring(collectionPath.length + 1).contains('/');
    }).length;
  }
}

class _FakeTransaction implements FirestoreTransaction {
  _FakeTransaction(this.docs);

  final Map<String, Map<String, dynamic>> docs;

  @override
  Future<Map<String, dynamic>?> get(String path) async {
    final data = docs[path];
    return data == null ? null : Map<String, dynamic>.from(data);
  }

  @override
  void set(String path, Map<String, dynamic> data, {bool merge = false}) {
    if (merge && docs.containsKey(path)) {
      docs[path] = {...docs[path]!, ...data};
    } else {
      docs[path] = Map<String, dynamic>.from(data);
    }
  }

  @override
  void update(String path, Map<String, dynamic> data) {
    final existing = docs[path];
    if (existing == null) {
      throw StateError('No document at $path to update.');
    }
    docs[path] = {...existing, ...data};
  }
}

/// Seeds the two demo branch docs (the repositories enumerate
/// `branches` for branch-less reads).
Future<void> seedBranches(FakeFirestoreTransport transport) async {
  await transport.setDocument('branches/branch-dha-main', {
    'organizationId': demoOrganizationId,
    'name': 'Demo Branch — DHA',
    'code': 'DHA',
    'type': 'own',
    'status': 'active',
  });
  await transport.setDocument('branches/branch-demo-gulberg', {
    'organizationId': demoOrganizationId,
    'name': 'Demo Branch — Gulberg',
    'code': 'GLB',
    'type': 'own',
    'status': 'active',
  });
}

// -- Sample builders ------------------------------------------------------

Staff sampleStaff({
  String id = '',
  String branchId = 'branch-dha-main',
  String name = 'Ayesha Khan',
  String phone = '03001234567',
  String? roleKey = 'pharmacist',
  bool active = true,
}) {
  return Staff(
    id: id,
    name: name,
    email: 'ayesha@fazaldin.example',
    role: StaffRole.pharmacist,
    branchId: branchId,
    active: active,
    phone: phone,
    jobTitle: 'Senior Pharmacist',
    roleKey: roleKey,
  );
}

Attendance sampleAttendance({
  String id = '',
  String branchId = 'branch-dha-main',
  String employeeId = 'staff-1',
  DateTime? date,
  DateTime? checkIn,
  DateTime? checkOut,
  AttendanceStatus status = AttendanceStatus.present,
  String? note,
}) {
  final day = date ?? DateTime(2026, 11, 25);
  return Attendance(
    id: id,
    employeeId: employeeId,
    branchId: branchId,
    date: day,
    checkIn: checkIn ?? DateTime(2026, 11, 25, 9, 2),
    checkOut: checkOut,
    status: status,
    note: note,
  );
}

Shift sampleShift({
  String id = '',
  String branchId = 'branch-dha-main',
  String name = 'Morning',
  List<String> employeeIds = const ['staff-1'],
}) {
  return Shift(
    id: id,
    branchId: branchId,
    name: name,
    startTime: '09:00',
    endTime: '17:00',
    employeeIds: employeeIds,
  );
}

Expense sampleExpense({
  String id = '',
  String branchId = 'branch-dha-main',
  String category = 'Rent',
  int amountMinor = 15000000,
}) {
  return Expense(
    id: id,
    branchId: branchId,
    category: category,
    amountMinor: amountMinor,
    description: 'November shop rent',
    expenseDate: DateTime(2026, 11, 1),
    createdBy: 'user-owner',
  );
}

FinancialTransaction sampleTransaction({
  String id = '',
  String branchId = 'branch-dha-main',
  FinancialTransactionType type = FinancialTransactionType.expense,
  int amountMinor = -15000000,
  String category = 'Rent',
  String? referenceType = 'expense',
  String? referenceId,
}) {
  return FinancialTransaction(
    id: id,
    branchId: branchId,
    type: type,
    amountMinor: amountMinor,
    category: category,
    referenceType: referenceType,
    referenceId: referenceId,
    createdBy: 'user-owner',
  );
}

SupplierPayment samplePayment({
  String id = '',
  String branchId = 'branch-dha-main',
  String supplierId = 'sup-1',
  int amountMinor = 500000,
  String reference = 'TXN-12345',
  List<PaymentAllocation> allocations = const [
    PaymentAllocation(ledgerEntryId: 'ledger-1', amountMinor: 500000),
  ],
}) {
  return SupplierPayment(
    id: id,
    branchId: branchId,
    supplierId: supplierId,
    amountMinor: amountMinor,
    method: SupplierPaymentMethod.bankTransfer,
    reference: reference,
    paidBy: 'user-owner',
    paidAt: DateTime(2026, 11, 25, 14, 30),
    allocations: allocations,
  );
}

void main() {
  group('Schema contracts — D99 extensions', () {
    test('supplierPayments contract lists paidAt + allocations', () {
      final fields =
          FirestoreSchema.fieldsByCollection['branches/{branchId}/supplierPayments']!;
      final names = fields.map((f) => f.name).toSet();
      expect(names, contains('paidAt'));
      expect(names, contains('allocations'));
      expect(
        fields.firstWhere((f) => f.name == 'paidAt').required,
        isTrue,
      );
    });

    test('employees contract lists the local-model extras', () {
      final fields =
          FirestoreSchema.fieldsByCollection['branches/{branchId}/employees']!;
      final names = fields.map((f) => f.name).toSet();
      expect(names, containsAll(['email', 'role', 'roleKey']));
      // salary / joiningDate stay in the contract but are never
      // written by the mapper (D99) — they are optional.
      expect(
        fields.firstWhere((f) => f.name == 'salary').required,
        isFalse,
      );
    });

    test('attendances contract lists note; expenses list category', () {
      final attendanceFields =
          FirestoreSchema.fieldsByCollection['branches/{branchId}/attendances']!;
      expect(
        attendanceFields.map((f) => f.name),
        contains('note'),
      );
      final expenseFields =
          FirestoreSchema.fieldsByCollection['branches/{branchId}/expenses']!;
      expect(expenseFields.map((f) => f.name), contains('category'));
    });

    test('validateDocument passes on every new mapper output', () {
      expect(
        FirestoreSchema.validateDocument(
          'branches/{branchId}/employees',
          staffToFirestore(sampleStaff(), orgId: demoOrganizationId),
        ),
        isEmpty,
      );
      expect(
        FirestoreSchema.validateDocument(
          'branches/{branchId}/attendances',
          attendanceToFirestore(sampleAttendance(), orgId: demoOrganizationId),
        ),
        isEmpty,
      );
      expect(
        FirestoreSchema.validateDocument(
          'branches/{branchId}/shifts',
          shiftToFirestore(sampleShift(), orgId: demoOrganizationId),
        ),
        isEmpty,
      );
      expect(
        FirestoreSchema.validateDocument(
          'branches/{branchId}/expenses',
          expenseToFirestore(sampleExpense(), orgId: demoOrganizationId),
        ),
        isEmpty,
      );
      expect(
        FirestoreSchema.validateDocument(
          'branches/{branchId}/financialTransactions',
          financialTransactionToFirestore(
            sampleTransaction(),
            orgId: demoOrganizationId,
          ),
        ),
        isEmpty,
      );
      expect(
        FirestoreSchema.validateDocument(
          'branches/{branchId}/supplierPayments',
          supplierPaymentToFirestore(
            samplePayment(),
            orgId: demoOrganizationId,
          ),
        ),
        isEmpty,
      );
    });
  });

  group('Mappers — round-trips', () {
    test('staff round-trips incl. role, roleKey, active flag', () {
      final staff = sampleStaff();
      final doc = staffToFirestore(staff, orgId: demoOrganizationId);
      expect(doc['name'], 'Ayesha Khan');
      expect(doc['phone'], '03001234567');
      expect(doc['jobTitle'], 'Senior Pharmacist');
      expect(doc['status'], 'active');
      expect(doc['email'], 'ayesha@fazaldin.example');
      expect(doc['role'], 'pharmacist');
      expect(doc['roleKey'], 'pharmacist');
      expect(doc['branchId'], 'branch-dha-main');
      expect(doc['organizationId'], demoOrganizationId);
      // Salary / joiningDate are never invented (D99).
      expect(doc.containsKey('salary'), isFalse);
      expect(doc.containsKey('joiningDate'), isFalse);

      final back = staffFromFirestore('staff-9', doc);
      expect(back.id, 'staff-9');
      expect(back.name, staff.name);
      expect(back.email, staff.email);
      expect(back.role, StaffRole.pharmacist);
      expect(back.roleKey, 'pharmacist');
      expect(back.jobTitle, 'Senior Pharmacist');
      expect(back.phone, '03001234567');
      expect(back.active, isTrue);
      expect(back.effectiveRoleKey, 'pharmacist');
    });

    test('staff inactive maps to disabled and back; null roleKey stays null', () {
      final staff = sampleStaff(active: false, roleKey: null);
      final doc = staffToFirestore(staff, orgId: demoOrganizationId);
      expect(doc['status'], 'disabled');
      expect(doc['roleKey'], isNull);
      final back = staffFromFirestore('staff-10', doc);
      expect(back.active, isFalse);
      expect(back.roleKey, isNull);
      // Legacy role falls back to the Day 0 role mapping.
      expect(back.effectiveRoleKey, 'pharmacist');
    });

    test('staff reads a legacy doc with a bool active field', () {
      final back = staffFromFirestore('staff-11', {
        'name': 'Legacy',
        'role': 'counter',
        'active': false,
        'branchId': 'branch-dha-main',
      });
      expect(back.active, isFalse);
      expect(back.role, StaffRole.counter);
    });

    test('attendance round-trips incl. day, times, status, note', () {
      final record = sampleAttendance(
        checkOut: DateTime(2026, 11, 25, 17, 5),
        status: AttendanceStatus.late,
        note: 'Traffic delay',
      );
      final doc = attendanceToFirestore(record, orgId: demoOrganizationId);
      expect(doc['employeeId'], 'staff-1');
      expect(doc['date'], isA<Timestamp>());
      expect(doc['status'], 'late');
      expect(doc['note'], 'Traffic delay');
      expect(doc['checkIn'], isA<Timestamp>());

      final back = attendanceFromFirestore('att-1', doc);
      expect(back.employeeId, 'staff-1');
      expect(back.date, DateTime(2026, 11, 25));
      expect(back.checkIn, DateTime(2026, 11, 25, 9, 2));
      expect(back.checkOut, DateTime(2026, 11, 25, 17, 5));
      expect(back.status, AttendanceStatus.late);
      expect(back.note, 'Traffic delay');
      expect(back.isOpen, isFalse);
      expect(back.workedDuration, const Duration(hours: 8, minutes: 3));
    });

    test('attendance open record round-trips with null check-out', () {
      final record = sampleAttendance(checkOut: null);
      final doc = attendanceToFirestore(record, orgId: demoOrganizationId);
      expect(doc['checkOut'], isNull);
      final back = attendanceFromFirestore('att-2', doc);
      expect(back.isOpen, isTrue);
      expect(back.workedDuration, isNull);
    });

    test('attendance half-day status survives the round-trip', () {
      final record = sampleAttendance(status: AttendanceStatus.halfDay);
      final back = attendanceFromFirestore(
        'att-3',
        attendanceToFirestore(record, orgId: demoOrganizationId),
      );
      expect(back.status, AttendanceStatus.halfDay);
    });

    test('shift round-trips incl. HH:MM times and employee ids', () {
      final shift = sampleShift(employeeIds: ['staff-1', 'staff-2']);
      final doc = shiftToFirestore(shift, orgId: demoOrganizationId);
      expect(doc['name'], 'Morning');
      expect(doc['startTime'], '09:00');
      expect(doc['endTime'], '17:00');
      expect(doc['employeeIds'], ['staff-1', 'staff-2']);

      final back = shiftFromFirestore('shift-1', doc);
      expect(back.name, 'Morning');
      expect(back.startMinutes, 540);
      expect(back.endMinutes, 1020);
      expect(back.duration, const Duration(hours: 8));
      expect(back.employeeIds, ['staff-1', 'staff-2']);
    });

    test('expense round-trips incl. category id + name and date', () {
      final expense = sampleExpense();
      final doc = expenseToFirestore(expense, orgId: demoOrganizationId);
      expect(doc['categoryId'], 'Rent');
      expect(doc['category'], 'Rent');
      expect(doc['amount'], 15000000);
      expect(doc['description'], 'November shop rent');
      expect(doc['expenseDate'], isA<Timestamp>());
      expect(doc['createdBy'], 'user-owner');

      final back = expenseFromFirestore('exp-1', doc);
      expect(back.category, 'Rent');
      expect(back.amountMinor, 15000000);
      expect(back.description, 'November shop rent');
      expect(back.expenseDate, DateTime(2026, 11, 1));
      expect(back.createdBy, 'user-owner');
    });

    test('expense reads a doc that only carries categoryId', () {
      final back = expenseFromFirestore('exp-2', {
        'categoryId': 'Utilities',
        'amount': 450000,
        'expenseDate': Timestamp.fromDate(DateTime(2026, 11, 2)),
        'branchId': 'branch-dha-main',
      });
      expect(back.category, 'Utilities');
      expect(back.amountMinor, 450000);
    });

    test('financial transaction round-trips all five types (snake_case)', () {
      const cases = {
        FinancialTransactionType.income: 'income',
        FinancialTransactionType.expense: 'expense',
        FinancialTransactionType.supplierPayment: 'supplier_payment',
        FinancialTransactionType.customerPayment: 'customer_payment',
        FinancialTransactionType.adjustment: 'adjustment',
      };
      for (final entry in cases.entries) {
        final txn = sampleTransaction(type: entry.key, amountMinor: 12345);
        final doc = financialTransactionToFirestore(
          txn,
          orgId: demoOrganizationId,
        );
        expect(doc['type'], entry.value);
        expect(doc['amount'], 12345);
        final back = financialTransactionFromFirestore('ftx-1', doc);
        expect(back.type, entry.key);
        expect(back.amountMinor, 12345);
        expect(back.category, 'Rent');
      }
    });

    test('financial transaction keeps a negative (money-out) amount', () {
      final txn = sampleTransaction(amountMinor: -750000);
      final back = financialTransactionFromFirestore(
        'ftx-2',
        financialTransactionToFirestore(txn, orgId: demoOrganizationId),
      );
      expect(back.amountMinor, -750000);
      expect(back.type, FinancialTransactionType.expense);
    });

    test('supplier payment round-trips incl. method, paidAt, allocations', () {
      final payment = samplePayment();
      final doc = supplierPaymentToFirestore(
        payment,
        orgId: demoOrganizationId,
      );
      expect(doc['supplierId'], 'sup-1');
      expect(doc['amount'], 500000);
      expect(doc['method'], 'bankTransfer');
      expect(doc['reference'], 'TXN-12345');
      expect(doc['paidBy'], 'user-owner');
      expect(doc['paidAt'], isA<Timestamp>());
      expect(doc['allocations'], [
        {'ledgerEntryId': 'ledger-1', 'amount': 500000},
      ]);

      final back = supplierPaymentFromFirestore('spay-1', doc);
      expect(back.supplierId, 'sup-1');
      expect(back.amountMinor, 500000);
      expect(back.method, SupplierPaymentMethod.bankTransfer);
      expect(back.reference, 'TXN-12345');
      expect(back.paidAt, DateTime(2026, 11, 25, 14, 30));
      expect(back.allocations.length, 1);
      expect(back.allocations.first.ledgerEntryId, 'ledger-1');
      expect(back.allocations.first.amountMinor, 500000);
      expect(back.unallocatedMinor, 0);
    });

    test('supplier payment reads snake_case bank_transfer + split allocations', () {
      final back = supplierPaymentFromFirestore('spay-2', {
        'supplierId': 'sup-1',
        'amount': 900000,
        'method': 'bank_transfer',
        'paidAt': Timestamp.fromDate(DateTime(2026, 11, 24, 10, 0)),
        'allocations': [
          {'ledgerEntryId': 'ledger-1', 'amount': 500000},
          {'ledgerEntryId': 'ledger-2', 'amount': 400000},
        ],
        'branchId': 'branch-dha-main',
      });
      expect(back.method, SupplierPaymentMethod.bankTransfer);
      expect(back.allocations.length, 2);
      expect(back.unallocatedMinor, 0);
    });
  });

  group('Mappers — validation failures (validateOrThrow)', () {
    test('staff doc without a name is rejected', () {
      expect(
        () => validateOrThrow('branches/{branchId}/employees', {
          'organizationId': demoOrganizationId,
          'createdAt': Timestamp.now(),
          'updatedAt': Timestamp.now(),
          'branchId': 'branch-dha-main',
        }),
        throwsArgumentError,
      );
    });

    test('attendance doc without employeeId / date is rejected', () {
      expect(
        () => validateOrThrow('branches/{branchId}/attendances', {
          'organizationId': demoOrganizationId,
          'createdAt': Timestamp.now(),
          'updatedAt': Timestamp.now(),
          'branchId': 'branch-dha-main',
          'date': Timestamp.now(),
        }),
        throwsArgumentError,
      );
    });

    test('shift doc without a name is rejected', () {
      expect(
        () => validateOrThrow('branches/{branchId}/shifts', {
          'organizationId': demoOrganizationId,
          'createdAt': Timestamp.now(),
          'updatedAt': Timestamp.now(),
          'branchId': 'branch-dha-main',
        }),
        throwsArgumentError,
      );
    });

    test('expense doc without an amount is rejected', () {
      expect(
        () => validateOrThrow('branches/{branchId}/expenses', {
          'organizationId': demoOrganizationId,
          'createdAt': Timestamp.now(),
          'updatedAt': Timestamp.now(),
          'branchId': 'branch-dha-main',
        }),
        throwsArgumentError,
      );
    });

    test('transaction doc without a type / amount is rejected', () {
      expect(
        () => validateOrThrow('branches/{branchId}/financialTransactions', {
          'organizationId': demoOrganizationId,
          'createdAt': Timestamp.now(),
          'updatedAt': Timestamp.now(),
          'branchId': 'branch-dha-main',
        }),
        throwsArgumentError,
      );
    });

    test('supplier payment doc without supplierId / amount / paidAt is rejected', () {
      expect(
        () => validateOrThrow('branches/{branchId}/supplierPayments', {
          'organizationId': demoOrganizationId,
          'createdAt': Timestamp.now(),
          'updatedAt': Timestamp.now(),
          'branchId': 'branch-dha-main',
          'amount': 1000,
        }),
        throwsArgumentError,
      );
    });
  });

  group('Firestore repositories — staff', () {
    late FakeFirestoreTransport transport;
    late FirestoreStaffRepository repo;

    setUp(() async {
      transport = FakeFirestoreTransport();
      await seedBranches(transport);
      repo = FirestoreStaffRepository(
        transport: transport,
        organizationId: demoOrganizationId,
      );
    });

    test('create + get + list, branch-scoped and org-wide', () async {
      final dha = await repo.createStaff(sampleStaff());
      final glb = await repo.createStaff(
        sampleStaff(
          branchId: 'branch-demo-gulberg',
          name: 'Bilal Ahmed',
          phone: '03009876543',
          roleKey: 'cashier',
        ),
      );
      expect(dha.id, isNotEmpty);
      expect(dha.name, 'Ayesha Khan');
      expect(dha.createdAt, isNotNull);

      expect((await repo.getStaff(branchId: 'branch-dha-main')).length, 1);
      expect(
        (await repo.getStaff(branchId: 'branch-demo-gulberg')).length,
        1,
      );
      expect((await repo.getStaff()).length, 2);
      expect((await repo.getById(dha.id))?.name, 'Ayesha Khan');
      expect((await repo.getById(glb.id))?.branchId, 'branch-demo-gulberg');
      expect(await repo.getById('missing'), isNull);
    });

    test('create with a caller id is idempotent (retry returns the original)', () async {
      final first = await repo.createStaff(sampleStaff(id: 'staff-client-1'));
      final second = await repo.createStaff(
        sampleStaff(id: 'staff-client-1', name: 'Different Name'),
      );
      expect(second.id, first.id);
      expect(second.name, 'Ayesha Khan');
      expect(
        transport.countIn('branches/branch-dha-main/employees'),
        1,
      );
    });

    test('duplicate phone is refused (digits compared, formatting ignored)', () async {
      await repo.createStaff(sampleStaff(phone: '0300-1234567'));
      expect(
        () => repo.createStaff(
          sampleStaff(name: 'Someone Else', phone: '03001234567'),
        ),
        throwsArgumentError,
      );
      // Same phone in the other branch is refused too (org-wide).
      expect(
        () => repo.createStaff(
          sampleStaff(
            branchId: 'branch-demo-gulberg',
            name: 'Someone Else',
            phone: '03001234567',
          ),
        ),
        throwsArgumentError,
      );
    });

    test('empty name / missing branch are refused', () async {
      expect(
        () => repo.createStaff(sampleStaff(name: '   ')),
        throwsArgumentError,
      );
      expect(
        () => repo.createStaff(sampleStaff(branchId: '')),
        throwsArgumentError,
      );
    });

    test('update edits + preserves createdAt; phone conflict refused; missing is a no-op', () async {
      final created = await repo.createStaff(sampleStaff());
      final other = await repo.createStaff(
        sampleStaff(name: 'Bilal Ahmed', phone: '03009876543'),
      );
      final before = await transport.getDocument(
        'branches/branch-dha-main/employees/${created.id}',
      );
      await repo.updateStaff(
        created.copyWith(jobTitle: 'Chief Pharmacist'),
      );
      final updated = await repo.getById(created.id);
      expect(updated?.jobTitle, 'Chief Pharmacist');
      final after = await transport.getDocument(
        'branches/branch-dha-main/employees/${created.id}',
      );
      expect(after?['createdAt'], before?['createdAt']);

      expect(
        () => repo.updateStaff(created.copyWith(phone: other.phone)),
        throwsArgumentError,
      );
      // Updating a missing member does nothing (same as the mock).
      await repo.updateStaff(
        sampleStaff(id: 'no-such-id', name: 'Ghost'),
      );
      expect((await repo.getStaff()).length, 2);
    });
  });

  group('Firestore repositories — attendance', () {
    late FakeFirestoreTransport transport;
    late FirestoreAttendanceRepository repo;

    setUp(() async {
      transport = FakeFirestoreTransport();
      await seedBranches(transport);
      repo = FirestoreAttendanceRepository(
        transport: transport,
        organizationId: demoOrganizationId,
      );
    });

    test('upsert creates on check-in, overwrites on check-out (no duplicate)', () async {
      final checkedIn = await repo.upsertAttendance(sampleAttendance());
      expect(checkedIn.id, isNotEmpty);
      final checkedOut = await repo.upsertAttendance(
        checkedIn.copyWith(
          checkOut: DateTime(2026, 11, 25, 17, 5),
          status: AttendanceStatus.present,
        ),
      );
      expect(checkedOut.id, checkedIn.id);
      expect(
        transport.countIn('branches/branch-dha-main/attendances'),
        1,
      );
      final stored = await repo.getAttendances(
        employeeId: 'staff-1',
        date: DateTime(2026, 11, 25),
      );
      expect(stored.length, 1);
      expect(stored.first.checkOut, DateTime(2026, 11, 25, 17, 5));
      expect(stored.first.isOpen, isFalse);
    });

    test('upsert with a caller id is idempotent across retries', () async {
      final first = await repo.upsertAttendance(
        sampleAttendance(id: 'att-client-1'),
      );
      final second = await repo.upsertAttendance(
        sampleAttendance(id: 'att-client-1', note: 'retry'),
      );
      expect(second.id, first.id);
      expect(
        transport.countIn('branches/branch-dha-main/attendances'),
        1,
      );
    });

    test('list filters by branch, day and employee', () async {
      await repo.upsertAttendance(sampleAttendance());
      await repo.upsertAttendance(
        sampleAttendance(
          employeeId: 'staff-2',
          date: DateTime(2026, 11, 24),
          checkIn: DateTime(2026, 11, 24, 9, 0),
        ),
      );
      await repo.upsertAttendance(
        sampleAttendance(
          branchId: 'branch-demo-gulberg',
          employeeId: 'staff-9',
          date: DateTime(2026, 11, 25),
          checkIn: DateTime(2026, 11, 25, 9, 10),
        ),
      );
      expect((await repo.getAttendances()).length, 3);
      expect(
        (await repo.getAttendances(branchId: 'branch-dha-main')).length,
        2,
      );
      expect(
        (await repo.getAttendances(date: DateTime(2026, 11, 25))).length,
        2,
      );
      expect(
        (await repo.getAttendances(employeeId: 'staff-2')).length,
        1,
      );
      expect(
        (await repo.getAttendances(
          branchId: 'branch-dha-main',
          date: DateTime(2026, 11, 25),
          employeeId: 'staff-1',
        )).length,
        1,
      );
    });

    test('upsert without employeeId / branchId is refused', () async {
      expect(
        () => repo.upsertAttendance(sampleAttendance(employeeId: '')),
        throwsArgumentError,
      );
      expect(
        () => repo.upsertAttendance(sampleAttendance(branchId: '')),
        throwsArgumentError,
      );
    });
  });

  group('Firestore repositories — shifts', () {
    late FakeFirestoreTransport transport;
    late FirestoreShiftRepository repo;

    setUp(() async {
      transport = FakeFirestoreTransport();
      await seedBranches(transport);
      repo = FirestoreShiftRepository(
        transport: transport,
        organizationId: demoOrganizationId,
      );
    });

    test('create + get + list, branch-scoped and org-wide', () async {
      final shift = await repo.createShift(sampleShift());
      expect(shift.id, isNotEmpty);
      expect(shift.startMinutes, 540);
      await repo.createShift(
        sampleShift(
          branchId: 'branch-demo-gulberg',
          name: 'Evening',
          employeeIds: const ['staff-9'],
        ),
      );
      expect((await repo.getShifts(branchId: 'branch-dha-main')).length, 1);
      expect((await repo.getShifts()).length, 2);
      expect((await repo.getById(shift.id))?.name, 'Morning');
      expect(await repo.getById('missing'), isNull);
    });

    test('create with a caller id is idempotent (retry returns the original)', () async {
      final first = await repo.createShift(sampleShift(id: 'shift-client-1'));
      final second = await repo.createShift(
        sampleShift(id: 'shift-client-1', name: 'Renamed'),
      );
      expect(second.id, first.id);
      expect(second.name, 'Morning');
      expect(transport.countIn('branches/branch-dha-main/shifts'), 1);
    });

    test('empty name is refused on create and update; missing update is a no-op', () async {
      expect(() => repo.createShift(sampleShift(name: '  ')), throwsArgumentError);
      final shift = await repo.createShift(sampleShift());
      expect(
        () => repo.updateShift(shift.copyWith(name: '')),
        throwsArgumentError,
      );
      await repo.updateShift(sampleShift(id: 'no-such-id'));
      expect((await repo.getShifts()).length, 1);
    });

    test('update edits + preserves createdAt', () async {
      final shift = await repo.createShift(sampleShift());
      final before = await transport.getDocument(
        'branches/branch-dha-main/shifts/${shift.id}',
      );
      await repo.updateShift(
        shift.copyWith(endTime: '18:00', employeeIds: ['staff-1', 'staff-2']),
      );
      final updated = await repo.getById(shift.id);
      expect(updated?.endTime, '18:00');
      expect(updated?.employeeIds, ['staff-1', 'staff-2']);
      final after = await transport.getDocument(
        'branches/branch-dha-main/shifts/${shift.id}',
      );
      expect(after?['createdAt'], before?['createdAt']);
    });
  });

  group('Firestore repositories — expenses', () {
    late FakeFirestoreTransport transport;
    late FirestoreExpenseRepository repo;

    setUp(() async {
      transport = FakeFirestoreTransport();
      await seedBranches(transport);
      repo = FirestoreExpenseRepository(
        transport: transport,
        organizationId: demoOrganizationId,
      );
    });

    test('create + list, branch-scoped and org-wide', () async {
      final expense = await repo.createExpense(sampleExpense());
      expect(expense.id, isNotEmpty);
      await repo.createExpense(
        sampleExpense(
          branchId: 'branch-demo-gulberg',
          category: 'Utilities',
          amountMinor: 450000,
        ),
      );
      expect((await repo.getExpenses(branchId: 'branch-dha-main')).length, 1);
      expect((await repo.getExpenses()).length, 2);
    });

    test('create with a caller id is idempotent (retry returns the original)', () async {
      final first = await repo.createExpense(sampleExpense(id: 'exp-client-1'));
      final second = await repo.createExpense(
        sampleExpense(id: 'exp-client-1', amountMinor: 999),
      );
      expect(second.id, first.id);
      expect(second.amountMinor, 15000000);
      expect(transport.countIn('branches/branch-dha-main/expenses'), 1);
    });

    test('zero / negative amount and unknown category are refused', () async {
      expect(
        () => repo.createExpense(sampleExpense(amountMinor: 0)),
        throwsArgumentError,
      );
      expect(
        () => repo.createExpense(sampleExpense(amountMinor: -100)),
        throwsArgumentError,
      );
      expect(
        () => repo.createExpense(sampleExpense(category: 'Yacht')),
        throwsArgumentError,
      );
    });
  });

  group('Firestore repositories — financial transactions', () {
    late FakeFirestoreTransport transport;
    late FirestoreFinancialTransactionRepository repo;

    setUp(() async {
      transport = FakeFirestoreTransport();
      await seedBranches(transport);
      repo = FirestoreFinancialTransactionRepository(
        transport: transport,
        organizationId: demoOrganizationId,
      );
    });

    test('append + list, branch-scoped and org-wide; signed amounts kept', () async {
      final expense = await repo.addTransaction(sampleTransaction());
      expect(expense.id, isNotEmpty);
      await repo.addTransaction(
        sampleTransaction(
          branchId: 'branch-demo-gulberg',
          type: FinancialTransactionType.income,
          amountMinor: 2500000,
          category: 'Other income',
          referenceType: 'sale',
        ),
      );
      final dha = await repo.getTransactions(branchId: 'branch-dha-main');
      expect(dha.length, 1);
      expect(dha.first.amountMinor, -15000000);
      expect((await repo.getTransactions()).length, 2);
    });

    test('append with a caller id never double-appends (retry returns the original)', () async {
      final first = await repo.addTransaction(
        sampleTransaction(id: 'ftx-client-1'),
      );
      final second = await repo.addTransaction(
        sampleTransaction(id: 'ftx-client-1', amountMinor: -1),
      );
      expect(second.id, first.id);
      expect(second.amountMinor, -15000000);
      expect(
        transport.countIn('branches/branch-dha-main/financialTransactions'),
        1,
      );
    });

    test('zero-amount transaction is refused; negative (money-out) is fine', () async {
      expect(
        () => repo.addTransaction(sampleTransaction(amountMinor: 0)),
        throwsArgumentError,
      );
      final out = await repo.addTransaction(
        sampleTransaction(amountMinor: -5000),
      );
      expect(out.amountMinor, -5000);
    });
  });

  group('Firestore repositories — supplier payments', () {
    late FakeFirestoreTransport transport;
    late FirestoreSupplierPaymentRepository repo;

    setUp(() async {
      transport = FakeFirestoreTransport();
      await seedBranches(transport);
      repo = FirestoreSupplierPaymentRepository(
        transport: transport,
        organizationId: demoOrganizationId,
      );
    });

    test('create + list by branch and supplier; allocations preserved', () async {
      final payment = await repo.createPayment(samplePayment());
      expect(payment.id, isNotEmpty);
      await repo.createPayment(
        samplePayment(
          branchId: 'branch-demo-gulberg',
          supplierId: 'sup-2',
          amountMinor: 300000,
          allocations: const [
            PaymentAllocation(ledgerEntryId: 'ledger-9', amountMinor: 300000),
          ],
        ),
      );
      expect((await repo.getPayments(branchId: 'branch-dha-main')).length, 1);
      expect((await repo.getPayments(supplierId: 'sup-2')).length, 1);
      expect((await repo.getPayments(supplierId: 'sup-1')).length, 1);
      expect((await repo.getPayments()).length, 2);
      final stored = (await repo.getPayments(supplierId: 'sup-1')).first;
      expect(stored.allocations.first.ledgerEntryId, 'ledger-1');
      expect(stored.unallocatedMinor, 0);
    });

    test('create with a caller id is idempotent (retry returns the original)', () async {
      final first = await repo.createPayment(
        samplePayment(id: 'spay-client-1'),
      );
      // Retry with the same id and amount but a different reference:
      // the original (with its reference) comes back, no second doc.
      final second = await repo.createPayment(
        samplePayment(id: 'spay-client-1', reference: 'TXN-OTHER'),
      );
      expect(second.id, first.id);
      expect(second.amountMinor, 500000);
      expect(second.reference, 'TXN-12345');
      expect(
        transport.countIn('branches/branch-dha-main/supplierPayments'),
        1,
      );
    });

    test('validation: empty supplier, zero amount, allocation shortfall refused', () async {
      expect(
        () => repo.createPayment(samplePayment(supplierId: '')),
        throwsArgumentError,
      );
      expect(
        () => repo.createPayment(samplePayment(amountMinor: 0)),
        throwsArgumentError,
      );
      expect(
        () => repo.createPayment(
          samplePayment(
            amountMinor: 500000,
            allocations: const [
              PaymentAllocation(ledgerEntryId: 'ledger-1', amountMinor: 300000),
            ],
          ),
        ),
        throwsArgumentError,
      );
      expect(
        () => repo.createPayment(
          samplePayment(
            amountMinor: 500000,
            allocations: const [
              PaymentAllocation(ledgerEntryId: 'ledger-1', amountMinor: 600000),
            ],
          ),
        ),
        throwsArgumentError,
      );
    });

    test('empty allocation list is accepted (caller may allocate later)', () async {
      final payment = await repo.createPayment(
        samplePayment(allocations: const []),
      );
      expect(payment.allocations, isEmpty);
      expect(payment.unallocatedMinor, 500000);
    });
  });

  group('Factory wiring — D101', () {
    test('createRepositoryBundle() defaults to the mock bundle with mock Day 5 repos', () {
      final bundle = createRepositoryBundle();
      expect(bundle.kind, BackendKind.mock);
      expect(bundle.staff, isA<MockStaffRepository>());
      expect(bundle.attendance, isA<MockAttendanceRepository>());
      expect(bundle.shifts, isA<MockShiftRepository>());
      expect(bundle.expenses, isA<MockExpenseRepository>());
      expect(bundle.financialTransactions, isA<MockFinancialTransactionRepository>());
      expect(bundle.supplierPayments, isA<MockSupplierPaymentRepository>());
    });

    test('Firestore kind without a transport throws StateError', () {
      expect(
        () => createRepositoryBundle(kind: BackendKind.firestore),
        throwsStateError,
      );
    });

    test('Firestore kind with a transport serves Firestore Day 5 repos', () {
      final transport = FakeFirestoreTransport();
      final bundle = createRepositoryBundle(
        kind: BackendKind.firestore,
        transport: transport,
      );
      expect(bundle.kind, BackendKind.firestore);
      expect(bundle.staff, isA<FirestoreStaffRepository>());
      expect(bundle.attendance, isA<FirestoreAttendanceRepository>());
      expect(bundle.shifts, isA<FirestoreShiftRepository>());
      expect(bundle.expenses, isA<FirestoreExpenseRepository>());
      expect(bundle.financialTransactions, isA<FirestoreFinancialTransactionRepository>());
      expect(bundle.supplierPayments, isA<FirestoreSupplierPaymentRepository>());
      // The Day 3 repos are Firestore too (bundle is all-or-nothing).
      expect(bundle.medicines, isA<FirestoreMedicineRepository>());
    });

    test('providers read the bundle: default container serves mocks', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(staffRepositoryProvider), isA<MockStaffRepository>());
      expect(container.read(attendanceRepositoryProvider), isA<MockAttendanceRepository>());
      expect(container.read(shiftRepositoryProvider), isA<MockShiftRepository>());
      expect(container.read(expenseRepositoryProvider), isA<MockExpenseRepository>());
      expect(
        container.read(financialTransactionRepositoryProvider),
        isA<MockFinancialTransactionRepository>(),
      );
      expect(
        container.read(supplierPaymentRepositoryProvider),
        isA<MockSupplierPaymentRepository>(),
      );
    });

    test('providers read the bundle: Firestore override serves Firestore repos end-to-end', () async {
      final transport = FakeFirestoreTransport();
      await seedBranches(transport);
      final firestoreBundle = createRepositoryBundle(
        kind: BackendKind.firestore,
        transport: transport,
      );
      final container = ProviderContainer(
        overrides: [
          repositoryBundleProvider.overrideWithValue(firestoreBundle),
        ],
      );
      addTearDown(container.dispose);
      expect(container.read(staffRepositoryProvider), isA<FirestoreStaffRepository>());
      expect(container.read(expenseRepositoryProvider), isA<FirestoreExpenseRepository>());

      // End-to-end through the provider: write via the Firestore repo,
      // read back through the same provider.
      final created = await container
          .read(staffRepositoryProvider)
          .createStaff(sampleStaff());
      expect(created.id, isNotEmpty);
      final listed = await container
          .read(staffRepositoryProvider)
          .getStaff(branchId: 'branch-dha-main');
      expect(listed.map((s) => s.id), contains(created.id));
      final expense = await container
          .read(expenseRepositoryProvider)
          .createExpense(sampleExpense());
      expect(
        (await container.read(expenseRepositoryProvider).getExpenses()).length,
        1,
      );
      expect(expense.amountMinor, 15000000);
    });
  });
}
