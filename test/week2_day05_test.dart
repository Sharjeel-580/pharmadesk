// Week 2 Day 5 tests — staff & HR, ledgers, prescriptions, analytics.
//
// Staff directory validation + role assignment (SRS §5.1 `users`),
// attendance check-in/out rules + shifts, supplier-payment
// allocation + payable/khata aging, prescription validity +
// re-review transitions + dispatch-guard expiry, P&L / trend /
// slow movers / expiry loss / branch comparison, CSV exports, and
// the widget flows (staff CRUD, attendance, supplier payment,
// prescription re-review, new report sections).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:pharmadesk/core/data/auth_repository.dart';
import 'package:pharmadesk/core/data/firestore_mappers.dart';
import 'package:pharmadesk/core/data/firestore_schema.dart';
import 'package:pharmadesk/core/data/permission_service.dart';
import 'package:pharmadesk/core/routing/app_router.dart';
import 'package:pharmadesk/core/services/demo_seed_data.dart';
import 'package:pharmadesk/core/theme/app_theme.dart';
import 'package:pharmadesk/core/theme/white_label.dart';
import 'package:pharmadesk/features/authentication/auth_state.dart';
import 'package:pharmadesk/features/finance/finance_logic.dart';
import 'package:pharmadesk/features/finance/finance_provider.dart';
import 'package:pharmadesk/features/orders/order_logic.dart';
import 'package:pharmadesk/features/prescriptions/prescriptions_logic.dart';
import 'package:pharmadesk/features/prescriptions/prescriptions_provider.dart';
import 'package:pharmadesk/features/reports/analytics_logic.dart';
import 'package:pharmadesk/features/reports/reports_logic.dart';
import 'package:pharmadesk/features/settings/roles_permissions.dart';
import 'package:pharmadesk/features/staff/hr_logic.dart';
import 'package:pharmadesk/features/staff/staff_provider.dart';
import 'package:pharmadesk/features/suppliers/supplier_detail_screen.dart';
import 'package:pharmadesk/features/suppliers/suppliers_provider.dart';
import 'package:pharmadesk/models/attendance.dart';
import 'package:pharmadesk/models/customer_ledger.dart';
import 'package:pharmadesk/models/expense.dart';
import 'package:pharmadesk/models/financial_transaction.dart';
import 'package:pharmadesk/models/inventory_item.dart';
import 'package:pharmadesk/models/medicine.dart';
import 'package:pharmadesk/models/order.dart';
import 'package:pharmadesk/models/prescription.dart';
import 'package:pharmadesk/models/sale.dart';
import 'package:pharmadesk/models/sale_return.dart';
import 'package:pharmadesk/models/shift.dart';
import 'package:pharmadesk/models/staff.dart';
import 'package:pharmadesk/models/supplier_payment.dart';


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

Staff _staff({
  String id = 'staff-x',
  String name = 'Test Person',
  String phone = '0300-1234567',
  String jobTitle = 'Cashier',
  String branchId = _dha,
  String? roleKey = 'cashier',
  StaffRole role = StaffRole.counter,
  bool active = true,
}) => Staff(
  id: id,
  name: name,
  email: 'test@fazaldin-demo.pk',
  role: role,
  roleKey: roleKey,
  jobTitle: jobTitle,
  phone: phone,
  branchId: branchId,
  active: active,
);

SignedEntry _signed(String id, DateTime date, int amountMinor) => (
  id: id,
  date: date,
  amountMinor: amountMinor,
);

/// Pumps the ungated router app with a fresh container the test owns.
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

void main() {
  group('Staff validation + roles', () {
    test('validateStaff: name, job title, phone and role are required', () {
      expect(
        validateStaff(name: '', phone: '', jobTitle: ''),
        contains('Staff name is required.'),
      );
      expect(
        validateStaff(name: 'A', phone: '03001234567', jobTitle: ''),
        contains('Job title is required.'),
      );
      expect(
        validateStaff(name: 'A', phone: '0300', jobTitle: 'Cashier'),
        contains('Phone number looks too short (need at least 10 digits).'),
      );
    });

    test('validateStaff: duplicate phone (digits compared) rejected', () {
      final errors = validateStaff(
        name: 'New Person',
        phone: '0300 123 4567',
        jobTitle: 'Cashier',
        existingPhones: ['0300-1234567'],
      );
      expect(
        errors,
        contains('A staff member with this phone number already exists.'),
      );
    });

    test('validateStaff: unknown SRS role rejected, all 10 accepted', () {
      expect(
        validateStaff(
          name: 'A',
          phone: '03001234567',
          jobTitle: 'X',
          roleKey: 'superhero',
        ),
        contains('Unknown role "superhero". Pick one of the 10 SRS roles.'),
      );
      for (final key in srsRoleKeys) {
        expect(
          validateStaff(
            name: 'A',
            phone: '03001234567',
            jobTitle: 'X',
            roleKey: key,
          ),
          isEmpty,
        );
      }
    });

    test('staffRoleForRoleKey maps legacy roles, rider has no matrix role',
        () {
      expect(staffRoleForRoleKey('pharmacist'), StaffRole.pharmacist);
      expect(staffRoleForRoleKey('owner'), StaffRole.owner);
      expect(staffRoleForRoleKey('cashier'), StaffRole.counter);
      expect(
        _staff(role: StaffRole.rider, roleKey: null).effectiveRoleKey,
        'rider',
      );
      expect(
        permissionService.permissionFor(
          _userFor('rider', [_dha]),
          'posSell',
        ),
        RolePermission.none,
      );
    });

    test('seeded directory: 10 staff, both branches, roles assigned', () {
      expect(demoStaff.length, 10);
      expect(
        demoStaff.where((s) => s.branchId == _dha).length,
        7,
      );
      expect(
        demoStaff.where((s) => s.branchId == _glb).length,
        3,
      );
      expect(
        demoStaff.every((s) => s.roleKey != null && s.phone.isNotEmpty),
        true,
      );
      expect(
        demoStaff.map((s) => s.roleKey).toSet(),
        containsAll(['owner', 'branch_manager', 'pharmacist', 'cashier']),
      );
    });

    test('searchStaff matches name, job title, phone and role', () {
      final found = searchStaff(demoStaff, query: 'pharmacist');
      expect(found.length, 2);
      expect(
        searchStaff(demoStaff, query: '0302-3334455').length,
        1,
      );
      expect(searchStaff(demoStaff, query: '').length, 10);
    });
  });

  group('HR permissions (SRS §5.1 matrix)', () {
    test('users: owner/HO allowed, branch mgr own, pharmacist none', () {
      expect(canManageStaff(_userFor('owner', []), _dha), true);
      expect(canManageStaff(_userFor('ho_admin', []), _dha), true);
      expect(canManageStaff(_userFor('branch_manager'), _dha), true);
      expect(
        canManageStaff(_userFor('branch_manager'), _glb),
        false,
      );
      expect(canManageStaff(_userFor('pharmacist'), _dha), false);
      expect(canManageStaff(_userFor('auditor', []), _dha), false);
    });

    test('hrAttendance: owner/HO allowed, branch mgr own, others none', () {
      expect(canManageHr(_userFor('owner', []), _dha), true);
      expect(canManageHr(_userFor('ho_admin', []), _dha), true);
      expect(canManageHr(_userFor('branch_manager'), _dha), true);
      expect(canManageHr(_userFor('branch_manager'), _glb), false);
      expect(canManageHr(_userFor('cashier'), _dha), false);
      expect(canManageHr(_userFor('auditor', []), _dha), false);
      expect(
        permissionService.permissionFor(
          _userFor('auditor', []),
          'hrAttendance',
        ),
        RolePermission.readOnly,
      );
    });

    test('hrSalary: only owner, HO admin and accountant', () {
      expect(
        permissionService.permissionFor(_userFor('owner', []), 'hrSalary'),
        RolePermission.allowed,
      );
      expect(
        permissionService.permissionFor(_userFor('accountant', []), 'hrSalary'),
        RolePermission.allowed,
      );
      expect(
        permissionService.permissionFor(
          _userFor('branch_manager'),
          'hrSalary',
        ),
        RolePermission.none,
      );
    });

    test('supplierPay: branch manager may NOT pay a supplier', () {
      expect(
        permissionService.canWrite(
          _userFor('branch_manager'),
          'supplierPay',
          _dha,
        ),
        false,
      );
      expect(
        permissionService.canWrite(_userFor('owner', []), 'supplierPay', _dha),
        true,
      );
      expect(
        permissionService.canWrite(
          _userFor('accountant', []),
          'supplierPay',
          _dha,
        ),
        true,
      );
      expect(
        permissionService.canWrite(_userFor('cashier'), 'supplierPay', _dha),
        false,
      );
    });

    test('financeEntry: cashier own allowed, pharmacist none', () {
      expect(
        permissionService.canWrite(_userFor('cashier'), 'financeEntry', _dha),
        true,
      );
      expect(
        permissionService.canWrite(_userFor('cashier'), 'financeEntry', _glb),
        false,
      );
      expect(
        permissionService.canWrite(
          _userFor('pharmacist'),
          'financeEntry',
          _dha,
        ),
        false,
      );
    });

    test('canResubmitFor: counter/pharmacist/manager/owner yes, others no',
        () {
      expect(canResubmitFor(_userFor('cashier'), _dha), true);
      expect(canResubmitFor(_userFor('pharmacist'), _dha), true);
      expect(canResubmitFor(_userFor('branch_manager'), _dha), true);
      expect(canResubmitFor(_userFor('owner', []), _dha), true);
      expect(canResubmitFor(_userFor('inventory_manager'), _dha), false);
      expect(canResubmitFor(_userFor('accountant', []), _dha), false);
      expect(canResubmitFor(_userFor('auditor', []), _dha), false);
      expect(canResubmitFor(_userFor('cashier'), _glb), false);
    });
    test('auditor: read-only on supplierPay — may view, may not pay', () {
      final auditor = _userFor('auditor', [_dha]);
      expect(
        permissionService.canInBranch(auditor, 'supplierPay', _dha),
        true,
      );
      expect(
        permissionService.canWrite(auditor, 'supplierPay', _dha),
        false,
      );
      // And a Branch Manager is `none` — the route gate stops them
      // before the supplier screens (see the widget test).
      final manager = _userFor('branch_manager', [_dha]);
      expect(
        permissionService.canInBranch(manager, 'supplierPay', _dha),
        false,
      );
    });
  });

  group('Shifts + attendance rules', () {
    test('validateShift: bad times, overnight, no employees', () {
      expect(
        validateShift(name: '', startTime: '9', endTime: '17:00'),
        contains('Shift name is required.'),
      );
      expect(
        validateShift(name: 'M', startTime: '09:00', endTime: '09:00'),
        contains(
          'End time must be after the start time on the same day — '
          'overnight shifts are not supported yet.',
        ),
      );
      expect(
        validateShift(
          name: 'M',
          startTime: '09:00',
          endTime: '17:00',
          employeeIds: [],
        ),
        contains('Assign at least one staff member to the shift.'),
      );
      expect(
        validateShift(
          name: 'M',
          startTime: '09:00',
          endTime: '17:00',
          employeeIds: ['staff-1'],
        ),
        isEmpty,
      );
    });

    test('shiftTimeToMinutes parses HH:MM and rejects junk', () {
      expect(shiftTimeToMinutes('09:00'), 540);
      expect(shiftTimeToMinutes('23:59'), 1439);
      expect(shiftTimeToMinutes('24:00'), isNull);
      expect(shiftTimeToMinutes('9am'), isNull);
      expect(shiftMinutesToLabel(540), '09:00');
    });

    test('attendanceStatusFor: on time, late after grace, half day', () {
      final day = DateTime(2026, 11, 25);
      // On time: 09:00 check-in against a 09:00 shift.
      expect(
        attendanceStatusFor(
          checkIn: DateTime(2026, 11, 25, 9, 0),
          checkOut: DateTime(2026, 11, 25, 17, 0),
          shiftStartMinutes: 540,
        ),
        AttendanceStatus.present,
      );
      // 15 minutes grace: 09:15 is still present, 09:16 is late.
      expect(
        attendanceStatusFor(
          checkIn: DateTime(2026, 11, 25, 9, 15),
          checkOut: DateTime(2026, 11, 25, 17, 0),
          shiftStartMinutes: 540,
        ),
        AttendanceStatus.present,
      );
      expect(
        attendanceStatusFor(
          checkIn: DateTime(2026, 11, 25, 9, 16),
          checkOut: DateTime(2026, 11, 25, 17, 0),
          shiftStartMinutes: 540,
        ),
        AttendanceStatus.late,
      );
      // Under 4 hours worked = half day; late wins over half day.
      expect(
        attendanceStatusFor(
          checkIn: DateTime(2026, 11, 25, 9, 0),
          checkOut: DateTime(2026, 11, 25, 12, 0),
          shiftStartMinutes: 540,
        ),
        AttendanceStatus.halfDay,
      );
      expect(
        attendanceStatusFor(
          checkIn: DateTime(2026, 11, 25, 10, 0),
          checkOut: DateTime(2026, 11, 25, 12, 0),
          shiftStartMinutes: 540,
        ),
        AttendanceStatus.late,
      );
      // No shift assigned: any check-in is present.
      expect(
        attendanceStatusFor(
          checkIn: DateTime(2026, 11, 25, 11, 0),
          checkOut: DateTime(2026, 11, 25, 17, 0),
          shiftStartMinutes: null,
        ),
        AttendanceStatus.present,
      );
      expect(day.day, 25);
    });

    test('validateCheckIn: one check-in per day, inactive refused', () {
      final now = DateTime(2026, 11, 25, 9, 0);
      final employee = _staff();
      expect(
        validateCheckIn(employee: employee, todaysRecords: [], now: now),
        isEmpty,
      );
      expect(
        validateCheckIn(
          employee: employee,
          todaysRecords: [
            Attendance(
              id: 'att-1',
              employeeId: employee.id,
              branchId: _dha,
              date: DateTime(2026, 11, 25),
              checkIn: now,
            ),
          ],
          now: now,
        ),
        contains('${employee.name} has already checked in today.'),
      );
      expect(
        validateCheckIn(
          employee: _staff(active: false),
          todaysRecords: [],
          now: now,
        ),
        contains('${employee.name} is inactive and cannot check in.'),
      );
    });

    test('validateCheckOut: needs an open record, after check-in', () {
      final now = DateTime(2026, 11, 25, 17, 0);
      expect(
        validateCheckOut(openRecord: null, now: now),
        contains('No check-in found for today — check in first.'),
      );
      expect(
        validateCheckOut(
          openRecord: Attendance(
            id: 'att-1',
            employeeId: 'staff-x',
            branchId: _dha,
            date: DateTime(2026, 11, 25),
            checkIn: DateTime(2026, 11, 25, 18, 0),
          ),
          now: now,
        ),
        contains('Check-out must be after check-in.'),
      );
    });

    test('todaysAttendance: one row per active staff, shift + record', () {
      final now = DateTime(2026, 11, 25, 10, 0);
      final rows = todaysAttendance(
        staff: demoStaff,
        records: [
          Attendance(
            id: 'att-1',
            employeeId: 'staff-3',
            branchId: _dha,
            date: DateTime(2026, 11, 25),
            checkIn: DateTime(2026, 11, 25, 9, 5),
            status: AttendanceStatus.present,
          ),
        ],
        shifts: generateDemoShifts(),
        now: now,
        branchId: _dha,
      );
      expect(rows.length, 7);
      final fatima = rows.firstWhere((r) => r.employee.id == 'staff-3');
      expect(fatima.record, isNotNull);
      expect(fatima.shift?.id, 'shift-dha-morning');
      expect(fatima.displayStatus, 'Present');
      final bilal = rows.firstWhere((r) => r.employee.id == 'staff-4');
      expect(bilal.record, isNull);
      expect(bilal.displayStatus, 'Not checked in');
      final counts = todayAttendanceCounts(rows);
      expect(counts['Present'], 1);
      expect(counts['Not checked in'], 6);
    });
  });

  group('Aging buckets + payment allocation', () {
    test('agingBucketForAge boundaries: 30/60/90', () {
      expect(agingBucketForAge(0), AgingBucket.current);
      expect(agingBucketForAge(30), AgingBucket.current);
      expect(agingBucketForAge(31), AgingBucket.days30);
      expect(agingBucketForAge(60), AgingBucket.days30);
      expect(agingBucketForAge(61), AgingBucket.days60);
      expect(agingBucketForAge(90), AgingBucket.days60);
      expect(agingBucketForAge(91), AgingBucket.days90plus);
    });

    test('computeAging: seeded supplier payables land in Current', () {
      final now = DateTime(2026, 11, 25);
      final entries = generateDemoSupplierLedgerEntries(now: now);
      final sami = computeAging(
        entries: supplierLedgerSignedEntries(
          entries.where((e) => e.supplierId == 'sup-sami').toList(),
        ),
        now: now,
      );
      // Rs 125,000 purchase 28 days ago, no payments: all Current.
      expect(sami.totalMinor, 12500000);
      expect(sami.bucket(AgingBucket.current), 12500000);
      expect(sami.bucket(AgingBucket.days90plus), 0);
      final medserve = computeAging(
        entries: supplierLedgerSignedEntries(
          entries.where((e) => e.supplierId == 'sup-medserve').toList(),
        ),
        now: now,
      );
      expect(medserve.totalMinor, 4825000);
      expect(medserve.bucket(AgingBucket.current), 4825000);
    });

    test('computeAging: old charge lands in 90+, payment settles oldest',
        () {
      final now = DateTime(2026, 11, 25);
      final summary = computeAging(
        entries: [
          _signed('c-old', DateTime(2026, 8, 1), 10000000), // 116 days
          _signed('c-new', DateTime(2026, 11, 15), 5000000), // 10 days
          _signed('p-1', DateTime(2026, 11, 20), -12000000),
        ],
        now: now,
      );
      // Payment settles the old charge fully (10,000,000) + 2,000,000
      // of the new one: 3,000,000 left, all Current.
      expect(summary.totalMinor, 3000000);
      expect(summary.bucket(AgingBucket.days90plus), 0);
      expect(summary.bucket(AgingBucket.current), 3000000);
    });

    test('computeAging: unpaid old charge stays in 90+', () {
      final now = DateTime(2026, 11, 25);
      final summary = computeAging(
        entries: [
          _signed('c-old', DateTime(2026, 8, 1), 10000000),
          _signed('c-mid', DateTime(2026, 9, 20), 4000000), // 66 days
          _signed('c-new', DateTime(2026, 11, 15), 5000000),
        ],
        now: now,
      );
      expect(summary.totalMinor, 19000000);
      expect(summary.bucket(AgingBucket.days90plus), 10000000);
      expect(summary.bucket(AgingBucket.days60), 4000000);
      expect(summary.bucket(AgingBucket.current), 5000000);
    });

    test('openPayableBalances + allocateSupplierPayment: oldest first', () {
      final open = openPayableBalances([
        _signed('c-new', DateTime(2026, 11, 15), 5000000),
        _signed('c-old', DateTime(2026, 8, 1), 10000000),
        _signed('p-1', DateTime(2026, 11, 20), -4000000),
      ]);
      expect(open.length, 2);
      expect(open.first.id, 'c-old');
      expect(open.first.remainingMinor, 6000000);
      expect(open.last.remainingMinor, 5000000);
      final allocations = allocateSupplierPayment(
        open: open,
        paymentMinor: 8000000,
      );
      expect(allocations.length, 2);
      expect(allocations.first.ledgerEntryId, 'c-old');
      expect(allocations.first.amountMinor, 6000000);
      expect(allocations.last.amountMinor, 2000000);
      expect(
        allocations.fold(0, (sum, a) => sum + a.amountMinor),
        8000000,
      );
    });

    test('validateSupplierPayment: overpayment + shortfall rejected', () {
      expect(
        validateSupplierPayment(
          amountMinor: 0,
          outstandingMinor: 1000000,
          allocations: [],
        ),
        contains('Payment amount must be more than zero.'),
      );
      expect(
        validateSupplierPayment(
          amountMinor: 2000000,
          outstandingMinor: 1000000,
          allocations: [
            const PaymentAllocation(ledgerEntryId: 'c-1', amountMinor: 1000000),
          ],
        ),
        anyElement(contains('cannot exceed the outstanding payable')),
      );
      expect(
        validateSupplierPayment(
          amountMinor: 1000000,
          outstandingMinor: 1000000,
          allocations: [
            const PaymentAllocation(ledgerEntryId: 'c-1', amountMinor: 500000),
          ],
        ),
        contains(
          'Payment could not be fully allocated against open payables — '
          'please refresh and try again.',
        ),
      );
      expect(
        validateSupplierPayment(
          amountMinor: 1000000,
          outstandingMinor: 1000000,
          allocations: [
            const PaymentAllocation(ledgerEntryId: 'c-1', amountMinor: 1000000),
          ],
        ),
        isEmpty,
      );
    });

    test('supplierStatementCsv: running balances in order', () {
      final csv = supplierStatementCsv(
        generateDemoSupplierLedgerEntries(now: DateTime(2026, 11, 25))
            .where((e) => e.supplierId == 'sup-medserve')
            .toList(),
      );
      expect(csv, startsWith('Date,Type,Reason,Amount (Rs),Balance after (Rs)'));
      expect(csv, contains('60000.00,60000.00'));
      expect(csv, contains('-11750.00,48250.00'));
    });
  });

  group('Prescription validity + re-review', () {
    Prescription rx({
      PrescriptionStatus status = PrescriptionStatus.approved,
      DateTime? validUntil,
      int resubmissionCount = 0,
    }) => Prescription(
      id: 'rx-test-1',
      customerId: 'cust-1',
      imageUrl: 'assets/images/prescriptions/sample-prescription-1.png',
      status: status,
      validUntil: validUntil,
      resubmissionCount: resubmissionCount,
    );

    test('isPrescriptionExpired: yesterday expired, today valid', () {
      final now = DateTime(2026, 11, 25, 10, 0);
      expect(
        isPrescriptionExpired(rx(validUntil: DateTime(2026, 11, 24)), now),
        true,
      );
      expect(
        isPrescriptionExpired(rx(validUntil: DateTime(2026, 11, 25)), now),
        false,
      );
      expect(
        isPrescriptionExpired(rx(validUntil: DateTime(2026, 11, 26)), now),
        false,
      );
      // Legacy record with no validity date is treated as valid.
      expect(isPrescriptionExpired(rx(validUntil: null), now), false);
    });

    test('canUnblockOrder: approved + valid only', () {
      final now = DateTime(2026, 11, 25);
      expect(
        canUnblockOrder(
          rx(
            status: PrescriptionStatus.approved,
            validUntil: DateTime(2026, 12, 25),
          ),
          now,
        ),
        true,
      );
      expect(
        canUnblockOrder(
          rx(
            status: PrescriptionStatus.approved,
            validUntil: DateTime(2026, 11, 24),
          ),
          now,
        ),
        false,
      );
      expect(
        canUnblockOrder(
          rx(
            status: PrescriptionStatus.pending,
            validUntil: DateTime(2026, 12, 25),
          ),
          now,
        ),
        false,
      );
    });

    test('canResubmit: only rejected / needs-clearer-photo', () {
      expect(canResubmit(PrescriptionStatus.rejected), true);
      expect(canResubmit(PrescriptionStatus.needsClearerPhoto), true);
      expect(canResubmit(PrescriptionStatus.pending), false);
      expect(canResubmit(PrescriptionStatus.approved), false);
    });

    test('validateResubmit: needs a live validity date', () {
      final now = DateTime(2026, 11, 25);
      expect(
        validateResubmit(
          current: PrescriptionStatus.pending,
          validUntil: DateTime(2026, 12, 25),
          now: now,
        ),
        contains(
          'Only a rejected prescription (or one needing a clearer photo) can be re-submitted.',
        ),
      );
      expect(
        validateResubmit(
          current: PrescriptionStatus.rejected,
          validUntil: null,
          now: now,
        ),
        contains('Set a validity date for the re-submitted prescription.'),
      );
      expect(
        validateResubmit(
          current: PrescriptionStatus.rejected,
          validUntil: DateTime(2026, 11, 24),
          now: now,
        ),
        contains('The validity date is already past — pick a future date.'),
      );
      expect(
        validateResubmit(
          current: PrescriptionStatus.rejected,
          validUntil: DateTime(2026, 12, 25),
          now: now,
        ),
        isEmpty,
      );
    });

    test('seeded prescriptions carry validity; one per branch expired', () {
      final seeded = generateDemoPrescriptions(now: DateTime(2026, 11, 25));
      expect(seeded.length, 20);
      expect(seeded.every((p) => p.validUntil != null), true);
      final expired = seeded.where(
        (p) => isPrescriptionExpired(p, DateTime(2026, 11, 25)),
      );
      expect(expired.length, 2);
      // The expired ones are never the forced-Pending linked records.
      expect(expired.map((p) => p.id), isNot(contains('rx-dha-1')));
      expect(expired.map((p) => p.id), isNot(contains('rx-glb-11')));
    });

    test('dispatch guard: approved-but-expired blocks dispatch', () {
      final order = Order(
        id: 'ord-1',
        customerId: 'cust-1',
        branchId: _dha,
        items: const [],
        deliveryAddress: 'Test',
        totalAmount: 100,
        prescriptionId: 'rx-test-1',
        status: OrderStatus.ready,
      );
      final now = DateTime(2026, 11, 25);
      expect(
        advanceBlockedReason(
          order: order,
          next: OrderStatus.dispatched,
          linkedPrescriptionStatus: PrescriptionStatus.approved,
          linkedPrescriptionValidUntil: DateTime(2026, 11, 24),
          now: now,
        ),
        contains('validity expired'),
      );
      expect(
        advanceBlockedReason(
          order: order,
          next: OrderStatus.dispatched,
          linkedPrescriptionStatus: PrescriptionStatus.approved,
          linkedPrescriptionValidUntil: DateTime(2026, 12, 24),
          now: now,
        ),
        isNull,
      );
      expect(
        advanceBlockedReason(
          order: order,
          next: OrderStatus.dispatched,
          linkedPrescriptionStatus: PrescriptionStatus.pending,
          now: now,
        ),
        contains('still pending'),
      );
    });

    test('resubmit via provider: rejected → pending, count + 1', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final list = await container.read(prescriptionsProvider.future);
      final rejected = list.firstWhere(
        (p) => p.status == PrescriptionStatus.rejected,
      );
      final result = await container
          .read(prescriptionsProvider.notifier)
          .resubmit(
            id: rejected.id,
            validUntil: DateTime.now().add(const Duration(days: 30)),
          );
      expect(result.error, isNull);
      expect(result.prescription?.status, PrescriptionStatus.pending);
      expect(result.prescription?.resubmissionCount, 1);
      expect(result.prescription?.reviewedBy, isNull);
      // A second re-submit of the now-Pending record is refused.
      final again = await container
          .read(prescriptionsProvider.notifier)
          .resubmit(
            id: rejected.id,
            validUntil: DateTime.now().add(const Duration(days: 30)),
          );
      expect(again.error, isNotNull);
    });
  });

  group('Advanced analytics', () {
    final now = DateTime(2026, 11, 25, 12, 0);

    Order order({
      String id = 'ord-1',
      String branchId = _dha,
      double total = 1000,
      int qty = 2,
      String medicineId = 'med-panadol-extra',
      DateTime? createdAt,
      OrderStatus status = OrderStatus.delivered,
    }) => Order(
      id: id,
      customerId: 'cust-1',
      branchId: branchId,
      items: [
        OrderItem(
          medicineId: medicineId,
          medicineName: 'Panadol Extra',
          quantity: qty,
          unitPrice: total / qty,
        ),
      ],
      deliveryAddress: 'Test',
      totalAmount: total,
      status: status,
      createdAt: createdAt ?? now,
    );

    Sale sale({
      String id = 'sale-1',
      String branchId = _dha,
      int totalMinor = 500000,
      String? batchId,
      DateTime? createdAt,
    }) => Sale(
      id: id,
      invoiceNumber: 'INV-DHA-1001',
      branchId: branchId,
      cashierName: 'Test',
      items: [
        SaleItem(
          medicineId: 'med-panadol-extra',
          medicineName: 'Panadol Extra',
          quantity: 5,
          unitPriceMinor: 100000,
          batchId: batchId,
        ),
      ],
      subtotalMinor: totalMinor,
      totalMinor: totalMinor,
      paymentMethod: SalePaymentMethod.cash,
      idempotencyKey: 'key-$id',
      createdAt: createdAt ?? now,
    );

    final panadol = Medicine(
      id: 'med-panadol-extra',
      name: 'Panadol Extra',
      brand: 'GSK',
      categoryId: 'cat-1',
      strength: '500mg',
      packSize: '20 tablets',
      price: 1000,
      purchasePriceMinor: 80000,
    );

    test('computeProfitAndLoss: revenue − COGS − expenses', () {
      final result = computeProfitAndLoss(
        orders: [order(total: 2000, qty: 2)],
        sales: [sale(totalMinor: 500000)],
        returns: const [],
        inventory: const [],
        expenses: [
          Expense(
            id: 'exp-1',
            branchId: _dha,
            category: 'Rent',
            amountMinor: 8500000,
            expenseDate: now,
          ),
        ],
        transactions: [
          FinancialTransaction(
            id: 'ftx-1',
            branchId: _dha,
            type: FinancialTransactionType.income,
            amountMinor: 200000,
            category: 'Other income',
            createdAt: now,
          ),
        ],
        medicinesById: {'med-panadol-extra': panadol},
        now: now,
        days: 30,
      );
      // Revenue: order Rs 2,000 + sale Rs 5,000 = Rs 7,000.
      expect(result.revenueMinor, 700000);
      // COGS: order 2 × Rs 800 + sale 5 × Rs 800 = Rs 5,600.
      expect(result.cogsMinor, 560000);
      expect(result.grossProfitMinor, 140000);
      expect(result.otherIncomeMinor, 200000);
      expect(result.expensesMinor, 8500000);
      expect(result.netProfitMinor, 140000 + 200000 - 8500000);
    });

    test('computeProfitAndLoss: refunds reduce revenue, old data excluded',
        () {
      final result = computeProfitAndLoss(
        orders: [
          order(total: 1000, qty: 1),
          order(
            id: 'ord-old',
            total: 99999,
            qty: 1,
            createdAt: DateTime(2026, 9, 1),
          ),
          order(
            id: 'ord-cancelled',
            total: 5000,
            qty: 1,
            status: OrderStatus.cancelled,
          ),
        ],
        sales: const [],
        returns: [
          SaleReturn(
            id: 'ret-1',
            branchId: _dha,
            saleId: 'sale-1',
            invoiceNumber: 'INV-DHA-1001',
            items: const [],
            reason: 'Damaged',
            refundedAmountMinor: 20000,
            approvedBy: 'u-1',
            approvedByName: 'Owner',
            createdAt: now,
          ),
        ],
        inventory: const [],
        expenses: const [],
        transactions: const [],
        medicinesById: {'med-panadol-extra': panadol},
        now: now,
        days: 30,
      );
      // Revenue: Rs 1,000 − Rs 200 refund = Rs 800; old + cancelled excluded.
      expect(result.revenueMinor, 80000);
      expect(result.cogsMinor, 80000);
      expect(result.grossProfitMinor, 0);
    });

    test('computeProfitAndLoss: POS cost comes from the sold batch', () {
      final batch = InventoryItem(
        id: 'inv-1',
        medicineId: 'med-panadol-extra',
        branchId: _dha,
        quantity: 10,
        batchNo: 'B-1',
        costMinor: 60000,
      );
      final result = computeProfitAndLoss(
        orders: const [],
        sales: [sale(batchId: 'inv-1')],
        returns: const [],
        inventory: [batch],
        expenses: const [],
        transactions: const [],
        medicinesById: {'med-panadol-extra': panadol},
        now: now,
        days: 30,
      );
      // 5 units × Rs 600 batch cost (not the Rs 800 purchase price).
      expect(result.cogsMinor, 300000);
      expect(result.grossProfitMinor, 200000);
    });

    test('computeWeeklyTrend groups 14 days into 2 weeks', () {
      final daily = [
        for (var i = 0; i < 14; i++)
          ReportDay(
            date: DateTime(2026, 11, 12).add(Duration(days: i)),
            salesMinor: 100000,
            orders: 2,
          ),
      ];
      final weeks = computeWeeklyTrend(daily);
      expect(weeks.length, 2);
      expect(weeks.first.salesMinor, 700000);
      expect(weeks.first.orders, 14);
      expect(weeks.first.weekStart, DateTime(2026, 11, 12));
      expect(weeks.last.salesMinor, 700000);
    });

    test('computeSlowMovers: stocked + unsold only', () {
      final movers = computeSlowMovers(
        orders: [order(medicineId: 'med-sold')],
        sales: const [],
        inventory: [
          InventoryItem(
            id: 'inv-1',
            medicineId: 'med-sold',
            branchId: _dha,
            quantity: 50,
            batchNo: 'B-1',
            costMinor: 10000,
          ),
          InventoryItem(
            id: 'inv-2',
            medicineId: 'med-slow',
            branchId: _dha,
            quantity: 40,
            batchNo: 'B-2',
            costMinor: 20000,
          ),
          InventoryItem(
            id: 'inv-3',
            medicineId: 'med-empty',
            branchId: _dha,
            quantity: 0,
            batchNo: 'B-3',
            costMinor: 50000,
          ),
        ],
        medicinesById: {
          'med-sold': panadol,
          'med-slow': const Medicine(
            id: 'med-slow',
            name: 'Slow Medicine',
            brand: 'X',
            categoryId: 'cat-1',
            strength: '250mg',
            packSize: '10 tablets',
            price: 500,
          ),
        },
        now: now,
        days: 30,
      );
      expect(movers.length, 1);
      expect(movers.first.medicineId, 'med-slow');
      expect(movers.first.quantityOnHand, 40);
      expect(movers.first.stockValueMinor, 800000);
    });

    test('computeExpiryLoss: only expired batches with stock', () {
      final loss = computeExpiryLoss(
        inventory: [
          InventoryItem(
            id: 'inv-1',
            medicineId: 'med-a',
            branchId: _dha,
            quantity: 10,
            batchNo: 'B-1',
            expiryDate: DateTime(2026, 11, 20),
            costMinor: 50000,
          ),
          InventoryItem(
            id: 'inv-2',
            medicineId: 'med-b',
            branchId: _dha,
            quantity: 5,
            batchNo: 'B-2',
            expiryDate: DateTime(2026, 12, 20),
            costMinor: 50000,
          ),
          InventoryItem(
            id: 'inv-3',
            medicineId: 'med-c',
            branchId: _dha,
            quantity: 0,
            batchNo: 'B-3',
            expiryDate: DateTime(2026, 10, 1),
            costMinor: 50000,
          ),
        ],
        now: now,
      );
      expect(loss.lossMinor, 500000);
      expect(loss.batches, 1);
      expect(loss.units, 10);
    });

    test('computeBranchAnalytics: D79 attribution, per-branch figures', () {
      final rows = computeBranchAnalytics(
        orders: [order(branchId: _dha, total: 2000, qty: 2)],
        sales: [sale(branchId: _glb, totalMinor: 300000)],
        returns: const [],
        inventory: [
          InventoryItem(
            id: 'inv-1',
            medicineId: 'med-panadol-extra',
            branchId: _dha,
            quantity: 10,
            batchNo: 'B-1',
            costMinor: 80000,
          ),
        ],
        ledgers: [
          // Credit sale of the Gulberg sale: attributed to Gulberg.
          const LedgerEntry(
            id: 'led-1',
            customerId: 'cust-1',
            kind: LedgerEntryKind.creditSale,
            amountMinor: 300000,
            reason: 'Credit sale',
            referenceId: 'sale-1',
            balanceAfterMinor: 300000,
          ),
          // Manual entry, no sale ref: unattributed everywhere.
          const LedgerEntry(
            id: 'led-2',
            customerId: 'cust-1',
            kind: LedgerEntryKind.credit,
            amountMinor: 999999,
            reason: 'Manual udhaar',
            balanceAfterMinor: 1299999,
          ),
        ],
        branches: const [
          (id: _dha, name: 'Demo Branch — DHA'),
          (id: _glb, name: 'Demo Branch — Gulberg'),
        ],
        medicinesById: {'med-panadol-extra': panadol},
        now: now,
        days: 30,
      );
      expect(rows.length, 2);
      final dha = rows.firstWhere((r) => r.branchId == _dha);
      expect(dha.salesMinor, 200000);
      expect(dha.grossProfitMinor, 200000 - 160000);
      expect(dha.stockValueMinor, 800000);
      expect(dha.outstandingMinor, 0);
      final glb = rows.firstWhere((r) => r.branchId == _glb);
      expect(glb.salesMinor, 300000);
      expect(glb.outstandingMinor, 300000);
    });
  });

  group('Advanced CSV exports', () {
    test('weeklyTrendCsv + branchComparisonCsv headers and rows', () {
      final trend = weeklyTrendCsv([
        WeeklyTrendPoint(
          weekStart: DateTime(2026, 11, 12),
          salesMinor: 700000,
          orders: 14,
        ),
      ]);
      expect(trend, startsWith('Week starting,Orders,Sales (Rs)'));
      expect(trend, contains('2026-11-12,14,7000.00'));
      final comparison = branchComparisonCsv([
        const BranchAnalyticsRow(
          branchId: _dha,
          branchName: 'Demo Branch — DHA',
          salesMinor: 200000,
          grossProfitMinor: 40000,
          stockValueMinor: 800000,
          outstandingMinor: 0,
          expiryLossMinor: 50000,
        ),
      ]);
      expect(
        comparison,
        startsWith(
          'Branch,Sales (Rs),Gross profit (Rs),Stock value (Rs),'
          'Outstanding khata (Rs),Expiry loss (Rs)',
        ),
      );
      expect(
        comparison,
        contains('Demo Branch — DHA,2000.00,400.00,8000.00,0.00,500.00'),
      );
    });

    test('profitLossCsv + slowMoversCsv + expiryLossCsv', () {
      final pl = profitLossCsv(
        const ProfitLoss(
          revenueMinor: 700000,
          cogsMinor: 560000,
          grossProfitMinor: 140000,
          otherIncomeMinor: 200000,
          expensesMinor: 8500000,
          netProfitMinor: -8160000,
        ),
      );
      expect(pl, contains('Sales revenue,7000.00'));
      expect(pl, contains('Net profit,-81600.00'));
      final slow = slowMoversCsv([
        const SlowMover(
          medicineId: 'med-slow',
          medicineName: 'Slow Medicine',
          quantitySold: 0,
          quantityOnHand: 40,
          stockValueMinor: 800000,
        ),
      ]);
      expect(slow, contains('Slow Medicine,0,40,8000.00'));
      final loss = expiryLossCsv(
        [
          ReportExpiryRow(
            medicineName: 'Old Medicine',
            batchNo: 'B-9',
            expiryDate: DateTime(2026, 11, 20),
            daysLeft: -5,
            quantity: 10,
          ),
        ],
        totalLossMinor: 500000,
      );
      expect(loss, contains('TOTAL expired stock value (Rs),,,5000.00'));
      expect(loss, contains('Old Medicine,B-9,2026-11-20,10'));
    });
  });

  group('Provider flows', () {
    test('staff add: owner succeeds, pharmacist denied', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container
          .read(authProvider.notifier)
          .signInAsDemo(DemoRole.owner);
      final created = await container.read(staffProvider.notifier).addStaff(
        name: 'New Cashier',
        email: 'new@fazaldin-demo.pk',
        phone: '0300-7771234',
        jobTitle: 'Cashier',
        branchId: _dha,
        roleKey: 'cashier',
      );
      expect(created.error, isNull);
      expect(created.staff?.name, 'New Cashier');
      expect(created.staff?.effectiveRoleKey, 'cashier');
      final staff = await container.read(staffProvider.future);
      expect(staff.any((s) => s.name == 'New Cashier'), true);

      final container2 = ProviderContainer();
      addTearDown(container2.dispose);
      await container2
          .read(authProvider.notifier)
          .signInAsDemo(DemoRole.pharmacist);
      final denied = await container2
          .read(staffProvider.notifier)
          .addStaff(
            name: 'Blocked Person',
            email: 'blocked@fazaldin-demo.pk',
            phone: '0300-7775678',
            jobTitle: 'Cashier',
            branchId: _dha,
            roleKey: 'cashier',
          );
      expect(denied.staff, isNull);
      expect(denied.error, contains('do not have permission'));
    });

    test('staff update: role assignment + deactivate', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container
          .read(authProvider.notifier)
          .signInAsDemo(DemoRole.owner);
      final staff = await container.read(staffProvider.future);
      final fatima = staff.firstWhere((s) => s.id == 'staff-3');
      final updated = await container
          .read(staffProvider.notifier)
          .updateStaff(
            fatima.copyWith(roleKey: 'branch_manager', active: false),
          );
      expect(updated.ok, true);
      final after = await container.read(staffProvider.future);
      final changed = after.firstWhere((s) => s.id == 'staff-3');
      expect(changed.effectiveRoleKey, 'branch_manager');
      expect(changed.active, false);
    });

    test('attendance: check-in then check-out, second check-in refused',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container
          .read(authProvider.notifier)
          .signInAsDemo(DemoRole.branchManager);
      final staff = await container.read(staffProvider.future);
      final fatima = staff.firstWhere((s) => s.id == 'staff-3');
      final inResult = await container
          .read(attendanceProvider.notifier)
          .checkIn(
            employee: fatima,
            at: DateTime(
              DateTime.now().year,
              DateTime.now().month,
              DateTime.now().day,
              9,
              5,
            ),
          );
      expect(inResult.error, isNull);
      expect(inResult.record?.status, AttendanceStatus.present);
      final again = await container
          .read(attendanceProvider.notifier)
          .checkIn(employee: fatima);
      expect(again.error, contains('already checked in'));
      final outResult = await container
          .read(attendanceProvider.notifier)
          .checkOut(
            employee: fatima,
            at: DateTime(
              DateTime.now().year,
              DateTime.now().month,
              DateTime.now().day,
              17,
              0,
            ),
          );
      expect(outResult.error, isNull);
      expect(outResult.record?.status, AttendanceStatus.present);
      expect(outResult.record?.workedDuration?.inHours, 7);
    });

    test('attendance: pharmacist may not record attendance', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container
          .read(authProvider.notifier)
          .signInAsDemo(DemoRole.pharmacist);
      final staff = await container.read(staffProvider.future);
      final fatima = staff.firstWhere((s) => s.id == 'staff-3');
      final result = await container
          .read(attendanceProvider.notifier)
          .checkIn(employee: fatima);
      expect(result.record, isNull);
      expect(result.error, contains('do not have permission'));
    });

    test('shifts: create + assign, validation rejects bad times', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container
          .read(authProvider.notifier)
          .signInAsDemo(DemoRole.owner);
      final bad = await container.read(shiftsProvider.notifier).createShift(
        name: 'Night',
        startTime: '23:00',
        endTime: '07:00',
        branchId: _dha,
        employeeIds: ['staff-3'],
      );
      expect(bad.shift, isNull);
      expect(bad.error, contains('overnight'));
      final created = await container
          .read(shiftsProvider.notifier)
          .createShift(
            name: 'Midday',
            startTime: '12:00',
            endTime: '16:00',
            branchId: _dha,
            employeeIds: ['staff-4', 'staff-5'],
          );
      expect(created.error, isNull);
      expect(created.shift?.employeeIds, ['staff-4', 'staff-5']);
    });

    test('expense: record writes expense + transaction mirror', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container
          .read(authProvider.notifier)
          .signInAsDemo(DemoRole.owner);
      final before = await container.read(expensesProvider.future);
      final result = await container
          .read(expensesProvider.notifier)
          .recordExpense(
            branchId: _dha,
            category: 'Utilities',
            amountMinor: 123456,
            description: 'Test bill',
            expenseDate: DateTime.now(),
          );
      expect(result.error, isNull);
      final after = await container.read(expensesProvider.future);
      expect(after.length, before.length + 1);
      final txns = await container.read(financialTransactionsProvider.future);
      final mirror = txns.where(
        (t) =>
            t.referenceId == result.expense!.id &&
            t.type == FinancialTransactionType.expense,
      );
      expect(mirror.length, 1);
      expect(mirror.first.amountMinor, -123456);
    });

    test('expense: pharmacist denied (financeEntry)', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container
          .read(authProvider.notifier)
          .signInAsDemo(DemoRole.pharmacist);
      final result = await container
          .read(expensesProvider.notifier)
          .recordExpense(
            branchId: _dha,
            category: 'Rent',
            amountMinor: 100000,
            expenseDate: DateTime.now(),
          );
      expect(result.expense, isNull);
      expect(result.error, contains('do not have permission'));
    });

    test('supplier payment: allocates oldest first, writes 3 records',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container
          .read(authProvider.notifier)
          .signInAsDemo(DemoRole.owner);
      // MedServe owes Rs 48,250 (Rs 60,000 purchase − Rs 11,750 paid).
      final result = await container
          .read(supplierPaymentsProvider.notifier)
          .recordPayment(
            supplierId: 'sup-medserve',
            branchId: _dha,
            amountMinor: 4825000,
            method: SupplierPaymentMethod.bankTransfer,
            reference: 'TXN-TEST-1',
          );
      expect(result.error, isNull);
      expect(result.payment?.unallocatedMinor, 0);
      expect(result.payment?.allocations.length, 1);
      expect(
        result.payment?.allocations.first.ledgerEntryId,
        'sled-2',
      );
      expect(result.payment?.allocations.first.amountMinor, 4825000);
      // Wait for the ledger to load, then read the computed value
      // (a plain provider has no `.future` of its own).
      await container.read(supplierLedgerProvider('sup-medserve').future);
      final outstanding = container.read(
        supplierOutstandingProvider('sup-medserve'),
      );
      expect(outstanding, 0);
      final txns = await container.read(financialTransactionsProvider.future);
      expect(
        txns.any(
          (t) =>
              t.referenceId == result.payment!.id &&
              t.type == FinancialTransactionType.supplierPayment &&
              t.amountMinor == -4825000,
        ),
        true,
      );
    });

    test('supplier payment: overpayment refused, branch mgr denied',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container
          .read(authProvider.notifier)
          .signInAsDemo(DemoRole.owner);
      final over = await container
          .read(supplierPaymentsProvider.notifier)
          .recordPayment(
            supplierId: 'sup-sami',
            branchId: _dha,
            amountMinor: 999999999,
          );
      expect(over.payment, isNull);
      expect(over.error, contains('cannot exceed the outstanding payable'));

      final container2 = ProviderContainer();
      addTearDown(container2.dispose);
      await container2
          .read(authProvider.notifier)
          .signInAsDemo(DemoRole.branchManager);
      final denied = await container2
          .read(supplierPaymentsProvider.notifier)
          .recordPayment(
            supplierId: 'sup-sami',
            branchId: _dha,
            amountMinor: 100000,
          );
      expect(denied.payment, isNull);
      expect(denied.error, contains('Only the Owner, HO Admin or Accountant'));
    });

    test('Firestore prescription mapper round-trips validity fields', () {
      // Mapper-level check only (no project): the schema contract
      // accepts validUntil + resubmissionCount and the mapper
      // carries them both ways.
      final rx = Prescription(
        id: 'rx-test-9',
        customerId: 'cust-1',
        imageUrl: 'assets/images/prescriptions/sample-prescription-1.png',
        status: PrescriptionStatus.rejected,
        validUntil: DateTime(2026, 12, 25),
        resubmissionCount: 2,
      );
      final doc = prescriptionToFirestore(
        rx,
        orgId: demoOrganizationId,
        branchId: _dha,
      );
      expect(doc['validUntil'], isNotNull);
      expect(doc['resubmissionCount'], 2);
      final back = prescriptionFromFirestore('rx-test-9', doc);
      expect(back.validUntil?.day, 25);
      expect(back.resubmissionCount, 2);
      expect(back.status, PrescriptionStatus.rejected);
    });
  });

  group('Widget flows', () {
    testWidgets('staff directory: search + add staff flow', (
      WidgetTester tester,
    ) async {
      final (container, router) = await pumpRouterApp(
        tester,
        size: const Size(800, 1600),
      );
      // The router harness starts unsigned; sign in through the
      // container (the login-screen tap helper belongs to the real
      // app widget, not this harness).
      await container.read(authProvider.notifier).signInAsDemo(DemoRole.owner);
      await tester.pumpAndSettle();
      router.go('/staff');
      await tester.pumpAndSettle();
      expect(find.text('Staff & HR'), findsWidgets);
      expect(find.text('Fatima Noor'), findsOneWidget);
      // Search narrows the list.
      await tester.enterText(find.byType(TextField), 'Fatima');
      await tester.pumpAndSettle();
      expect(find.text('Fatima Noor'), findsOneWidget);
      expect(find.text('Bilal Aslam'), findsNothing);
      await tester.enterText(find.byType(TextField), '');
      await tester.pumpAndSettle();
      // Add a staff member through the dialog.
      await tester.tap(find.text('Add staff'));
      await tester.pumpAndSettle();
      final dialogFields = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );
      expect(dialogFields, findsNWidgets(4));
      await tester.enterText(dialogFields.at(0), 'New Test Cashier');
      await tester.enterText(dialogFields.at(1), 'Cashier');
      await tester.enterText(dialogFields.at(2), '0300-8881234');
      await tester.enterText(dialogFields.at(3), 'test@fazaldin-demo.pk');
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      expect(find.text('New Test Cashier'), findsOneWidget);
    });

    testWidgets('attendance: check-in then check-out from the list', (
      WidgetTester tester,
    ) async {
      final (container, router) = await pumpRouterApp(
        tester,
        size: const Size(800, 1600),
      );
      await container
          .read(authProvider.notifier)
          .signInAsDemo(DemoRole.branchManager);
      await tester.pumpAndSettle();
      router.go('/staff/attendance');
      await tester.pumpAndSettle();
      expect(find.textContaining('Attendance —'), findsOneWidget);
      expect(find.text('Check in'), findsWidgets);
      await tester.tap(find.text('Check in').first);
      await tester.pumpAndSettle();
      expect(find.text('Check out'), findsWidgets);
      await tester.tap(find.text('Check out').first);
      await tester.pumpAndSettle();
      expect(find.text('Done for today'), findsWidgets);
    });

    testWidgets('shifts: seeded shifts listed', (WidgetTester tester) async {
      final (_, router) = await pumpRouterApp(
        tester,
        size: const Size(800, 1600),
      );
      router.go('/staff/shifts');
      await tester.pumpAndSettle();
      expect(find.textContaining('Shifts —'), findsOneWidget);
      expect(find.text('Morning — DHA'), findsOneWidget);
      expect(find.text('Evening — DHA'), findsOneWidget);
      // The list is branch-scoped to the active branch (DHA here);
      // Gulberg's shift is not shown.
      expect(find.text('Morning — Gulberg'), findsNothing);
    });

    testWidgets('supplier detail: aging chips + payment flow + payments list',
        (WidgetTester tester) async {
      final (_, router) = await pumpRouterApp(
        tester,
        size: const Size(800, 1600),
      );
      router.go('/suppliers/sup-medserve');
      await tester.pumpAndSettle();
      expect(find.text('MedServe Distributors'), findsWidgets);
      expect(find.text('Payable aging'), findsOneWidget);
      expect(find.text('Current (0–30 days): Rs 48,250.00'), findsOneWidget);
      await tester.tap(find.text('Record payment'));
      await tester.pumpAndSettle();
      final dialogFields = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );
      expect(dialogFields, findsNWidgets(3));
      await tester.enterText(dialogFields.at(0), '10000');
      await tester.enterText(dialogFields.at(1), 'Day 5 test payment');
      await tester.tap(find.text('Record'));
      await tester.pumpAndSettle();
      expect(find.text('Current (0–30 days): Rs 38,250.00'), findsOneWidget);
      expect(find.text('Payments'), findsOneWidget);
      expect(find.textContaining('allocated to 1 open payable'), findsOneWidget);
    });

  testWidgets('supplier detail: branch manager is stopped by the route gate',
        (WidgetTester tester) async {
      final (container, router) = await pumpRouterApp(
        tester,
        size: const Size(800, 1600),
      );
      await container
          .read(authProvider.notifier)
          .signInAsDemo(DemoRole.branchManager);
      await tester.pumpAndSettle();
      router.go('/suppliers/sup-sami');
      await tester.pumpAndSettle();
      // The Day 3 FeatureGate maps /suppliers to `supplierPay`, on
      // which a Branch Manager is `none` in the SRS §5.1 matrix — so
      // the gate stops them before the detail screen (and its
      // disabled Record payment button) is ever reached.
      expect(find.text('No permission for Suppliers'), findsOneWidget);
      expect(find.textContaining('supplierPay'), findsOneWidget);
    });

    testWidgets('supplier detail: auditor sees payment disabled, not hidden',
        (WidgetTester tester) async {
      // An Auditor is read-only on supplierPay: the gate lets them
      // view the module, but the Record payment button is disabled
      // with the reason. Pumped directly (no demo Auditor account
      // exists) with the auth state set on the container.
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(authProvider.notifier).state = _userFor(
        'auditor',
        [_dha],
      );
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(800, 1600);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.light(BrandConfig.defaults),
            home: const SupplierDetailScreen(supplierId: 'sup-sami'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Sami Pharmaceuticals'), findsWidgets);
      final button = find.text('Record payment');
      expect(button, findsOneWidget);
      await tester.tap(button);
      await tester.pumpAndSettle();
      // Disabled: no dialog opens.
      expect(find.byType(AlertDialog), findsNothing);
      expect(
        find.textContaining('Owner, HO Admin or Accountant'),
        findsOneWidget,
      );
    });

    testWidgets('prescription detail: rejected record re-submits to Pending',
        (WidgetTester tester) async {
      final (container, router) = await pumpRouterApp(
        tester,
        size: const Size(800, 1600),
      );
      final list = await container.read(prescriptionsProvider.future);
      final rejected = list.firstWhere(
        (p) => p.status == PrescriptionStatus.rejected,
      );
      router.go('/prescriptions/${rejected.id}');
      await tester.pumpAndSettle();
      expect(find.text('Rejected'), findsWidgets);
      expect(find.text('Re-submit for review'), findsOneWidget);
      await tester.tap(find.text('Re-submit for review'));
      await tester.pumpAndSettle();
      // The validity date picker opens; accept the default date.
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.text('Pending review'), findsWidgets);
      expect(find.text('Re-submit for review'), findsNothing);
    });

    testWidgets('reports: advanced sections render with seeded data', (
      WidgetTester tester,
    ) async {
      final (_, router) = await pumpRouterApp(
        tester,
        size: const Size(800, 1600),
      );
      router.go('/reports');
      await tester.pumpAndSettle();
      expect(find.text('Sales trend — weekly'), findsOneWidget);
      expect(find.text('Branch comparison'), findsOneWidget);
      expect(find.textContaining('Slow movers'), findsOneWidget);
      // The em-dash form is only the section title — the branch
      // comparison rows also mention expiry loss in their summaries.
      expect(find.textContaining('Expiry loss —'), findsOneWidget);
      expect(find.text('Profit & loss'), findsOneWidget);
      expect(find.textContaining('Expenses —'), findsOneWidget);
      expect(find.text('Monthly shop rent — DHA branch'), findsOneWidget);
      expect(find.text('Record expense'), findsOneWidget);
    });
  });
}
