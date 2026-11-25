import '../core/utils/money.dart';
import 'model_utils.dart';

/// Stock availability shown on the customer app.
enum StockStatus { inStock, lowStock, outOfStock }

StockStatus stockStatusFromString(String? value) {
  switch (value) {
    case 'lowStock':
      return StockStatus.lowStock;
    case 'outOfStock':
      return StockStatus.outOfStock;
    case 'inStock':
    default:
      return StockStatus.inStock;
  }
}

/// One medicine in the catalogue.
///
/// Firestore collection: `medicines`.
/// A medicine belongs to a category (`categories` collection) and is stocked
/// per branch through the `inventory` collection.
class Medicine {
  final String id;
  final String name;
  final String brand;
  final String categoryId;
  final String strength; // e.g. "500mg"
  final String packSize; // e.g. "20 tablets"
  final double price;
  final double? mrp;

  /// Purchase (cost) price in int minor units (paisa). D76: the SRS §3
  /// `medicines` doc requires `purchasePrice`, and the Day 0 model had
  /// no cost field — the mapper writes this, defaulting to 0 (unknown)
  /// for demo seed rows until a purchase price is recorded.
  final int purchasePriceMinor;
  final StockStatus stockStatus;
  final bool requiresPrescription;
  final String? genericAlternativeId;
  final String? imageUrl;
  final String? description;

  /// Sample EAN-13 barcode (Day 5): the catalogue search and the Day 6
  /// POS scan by barcode. Fictional demo values, never real GTINs.
  final String? barcode;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const Medicine({
    required this.id,
    required this.name,
    required this.brand,
    required this.categoryId,
    required this.strength,
    required this.packSize,
    required this.price,
    this.mrp,
    this.purchasePriceMinor = 0,
    this.stockStatus = StockStatus.inStock,
    this.requiresPrescription = false,
    this.genericAlternativeId,
    this.imageUrl,
    this.description,
    this.barcode,
    this.createdAt,
    this.updatedAt,
  });

  /// Sale price in minor units (paisa) — int math at the boundary (D6:
  /// the Day 0 model still stores `price` as double rupees).
  int get priceMinor => rupeesToMinorUnits(price);

  factory Medicine.fromMap(String id, Map<String, dynamic> map) {
    return Medicine(
      id: id,
      name: map['name'] as String? ?? '',
      brand: map['brand'] as String? ?? '',
      categoryId: map['categoryId'] as String? ?? '',
      strength: map['strength'] as String? ?? '',
      packSize: map['packSize'] as String? ?? '',
      price: (map['price'] as num?)?.toDouble() ?? 0,
      mrp: (map['mrp'] as num?)?.toDouble(),
      purchasePriceMinor: (map['purchasePriceMinor'] as num?)?.toInt() ?? 0,
      stockStatus: stockStatusFromString(map['stockStatus'] as String?),
      requiresPrescription: map['requiresPrescription'] as bool? ?? false,
      genericAlternativeId: map['genericAlternativeId'] as String?,
      imageUrl: map['imageUrl'] as String?,
      description: map['description'] as String?,
      barcode: map['barcode'] as String?,
      createdAt: parseDate(map['createdAt']),
      updatedAt: parseDate(map['updatedAt']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'brand': brand,
      'categoryId': categoryId,
      'strength': strength,
      'packSize': packSize,
      'price': price,
      'mrp': mrp,
      'purchasePriceMinor': purchasePriceMinor,
      'stockStatus': stockStatus.name,
      'requiresPrescription': requiresPrescription,
      'genericAlternativeId': genericAlternativeId,
      'imageUrl': imageUrl,
      'description': description,
      'barcode': barcode,
      'createdAt': dateToMap(createdAt),
      'updatedAt': dateToMap(updatedAt),
    };
  }
}
