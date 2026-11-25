/// Data models for the PharmaDesk system, one file per Firestore collection
/// (roadmap §4). Import this barrel instead of individual model files.
///
/// Collections: medicines, categories (see [Medicine.categoryId]),
/// orders, prescriptions, customers, staff, riders, branches, inventory.
library;

export 'branch.dart';
export 'customer.dart';
export 'customer_ledger.dart';
export 'inventory_item.dart';
export 'medicine.dart';
export 'model_utils.dart';
export 'order.dart';
export 'prescription.dart';
export 'purchase_order.dart';
export 'rider.dart';
export 'sale.dart';
export 'staff.dart';
export 'supplier.dart';
export 'supplier_ledger.dart';
