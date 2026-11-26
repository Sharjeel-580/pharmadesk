/// Data models for the PharmaDesk system, one file per Firestore collection
/// (roadmap §4). Import this barrel instead of individual model files.
///
/// Collections: medicines, categories (see [Medicine.categoryId]),
/// orders, prescriptions, customers, staff, riders, branches, inventory.
library;

export 'attendance.dart';
export 'branch.dart';
export 'customer.dart';
export 'customer_ledger.dart';
export 'daily_closing.dart';
export 'expense.dart';
export 'financial_transaction.dart';
export 'inventory_item.dart';
export 'medicine.dart';
export 'model_utils.dart';
export 'order.dart';
export 'prescription.dart';
export 'purchase_order.dart';
export 'rider.dart';
export 'sale.dart';
export 'sale_return.dart';
export 'shift.dart';
export 'staff.dart';
export 'stock_transfer.dart';
export 'supplier.dart';
export 'supplier_ledger.dart';
export 'supplier_payment.dart';
