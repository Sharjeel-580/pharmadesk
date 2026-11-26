import '../../models/medicine.dart';

/// Day 5 catalogue logic — pure functions over the medicine list, so
/// they are unit-testable without pumping anything.
///
/// Search matches name, brand or barcode; the category filter narrows
/// to one category; sorting is by name, price (int paisa) or sellable
/// stock. Stock figures always come from the caller (the branch
/// inventory), never from the catalogue — the catalogue has no stock.

/// Catalogue categories: id → display label. The 9 Day 1–4 categories
/// plus the 7 Day 5 additions. Every seeded medicine's `categoryId`
/// must be a key here (enforced by a Day 5 test).
const medicineCategoryLabels = <String, String>{
  'cat-analgesic': 'Analgesic',
  'cat-antibiotic': 'Antibiotic',
  'cat-gastric': 'Gastric',
  'cat-cardiac': 'Cardiac',
  'cat-diabetic': 'Diabetic',
  'cat-antihistamine': 'Antihistamine',
  'cat-throat': 'Throat',
  'cat-rehydration': 'Rehydration',
  'cat-supplement': 'Supplement',
  'cat-dermatology': 'Dermatology',
  'cat-eye': 'Eye Care',
  'cat-respiratory': 'Respiratory',
  'cat-vitamin': 'Vitamins',
  'cat-antifungal': 'Antifungal',
  'cat-neurology': 'Neurology',
  'cat-paediatric': 'Paediatric',
};

/// Category label for a medicine, falling back to the raw id when a
/// category is unknown (never crashes the list on a bad seed row).
String medicineCategoryLabel(Medicine medicine) =>
    medicineCategoryLabels[medicine.categoryId] ?? medicine.categoryId;

/// Sort orders for the catalogue screen.
enum MedicineSort { nameAsc, priceAsc, priceDesc, stockAsc, stockDesc }

String medicineSortLabel(MedicineSort sort) => switch (sort) {
  MedicineSort.nameAsc => 'Name (A–Z)',
  MedicineSort.priceAsc => 'Price: low to high',
  MedicineSort.priceDesc => 'Price: high to low',
  MedicineSort.stockAsc => 'Stock: low to high',
  MedicineSort.stockDesc => 'Stock: high to low',
};

/// Filters the catalogue by search text and category.
///
/// - [query] matches name, brand or barcode (case-insensitive,
///   substring; a barcode fragment matches too, so a scanner's partial
///   read still finds the medicine).
/// - [categoryId] `'all'` (or null) means every category.
List<Medicine> filterMedicines(
  List<Medicine> medicines, {
  String query = '',
  String? categoryId,
}) {
  final needle = query.trim().toLowerCase();
  return medicines.where((medicine) {
    if (categoryId != null &&
        categoryId != 'all' &&
        medicine.categoryId != categoryId) {
      return false;
    }
    if (needle.isEmpty) return true;
    return medicine.name.toLowerCase().contains(needle) ||
        medicine.brand.toLowerCase().contains(needle) ||
        (medicine.barcode?.toLowerCase().contains(needle) ?? false);
  }).toList();
}

/// Sorts a filtered catalogue. [sellableStockByMedicine] maps medicine
/// id → sellable units on the active branch; medicines missing from the
/// map count as 0 stock. Price sorts on int paisa ([Medicine.priceMinor],
/// D6 — never double arithmetic).
List<Medicine> sortMedicines(
  List<Medicine> medicines,
  MedicineSort sort, {
  Map<String, int> sellableStockByMedicine = const {},
}) {
  final sorted = medicines.toList();
  int stockOf(Medicine medicine) =>
      sellableStockByMedicine[medicine.id] ?? 0;
  switch (sort) {
    case MedicineSort.nameAsc:
      sorted.sort(
        (a, b) =>
            a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      );
    case MedicineSort.priceAsc:
      sorted.sort((a, b) => a.priceMinor.compareTo(b.priceMinor));
    case MedicineSort.priceDesc:
      sorted.sort((a, b) => b.priceMinor.compareTo(a.priceMinor));
    case MedicineSort.stockAsc:
      sorted.sort((a, b) => stockOf(a).compareTo(stockOf(b)));
    case MedicineSort.stockDesc:
      sorted.sort((a, b) => stockOf(b).compareTo(stockOf(a)));
  }
  return sorted;
}

/// Barcode uniqueness (Week 6 Day 4, D166 — the Day 25 follow-up:
/// uniqueness belongs in the repository, not the form, D151).
///
/// Returns the OTHER medicine already using [barcode], or `null`
/// when the barcode is free. An empty / absent barcode is never a
/// conflict (not every medicine has one); the medicine with id
/// [excludeId] keeping its own barcode is never a conflict either.
/// Comparison is on the trimmed barcode, so surrounding whitespace
/// cannot smuggle a duplicate past the check.
Medicine? findBarcodeConflict(
  Iterable<Medicine> medicines, {
  required String? barcode,
  required String excludeId,
}) {
  final needle = barcode?.trim() ?? '';
  if (needle.isEmpty) return null;
  for (final medicine in medicines) {
    if (medicine.id == excludeId) continue;
    if ((medicine.barcode?.trim() ?? '') == needle) return medicine;
  }
  return null;
}

/// The rejection message for a barcode already in use — the same
/// wording in the mock and Firestore repositories, so the edit form
/// (which surfaces the repo's `ArgumentError` verbatim, D153) shows
/// one message everywhere.
String barcodeConflictMessage(String barcode, String otherMedicineName) =>
    'Barcode "$barcode" is already used by "$otherMedicineName". '
    'Give this medicine a different barcode or leave it empty.';

