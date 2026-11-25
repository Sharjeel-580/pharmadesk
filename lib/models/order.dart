import 'model_utils.dart';

/// Lifecycle of a customer order.
///
/// Week 1 vocabulary (Day 4, D10/D25): New → Confirmed → Processing →
/// Ready → Dispatched → Delivered, plus Cancelled.
///
/// The Day 0 enum was `placed / confirmed / preparing / outForDelivery /
/// delivered / cancelled`. Those values are **kept** (stored data
/// compatibility — never silently renamed) and map onto the Week 1
/// vocabulary: `placed` ≈ New, `preparing` ≈ Processing,
/// `outForDelivery` ≈ Dispatched. New orders created by the Day 4 flow
/// use the Week 1 values (`newOrder`, `processing`, `ready`,
/// `dispatched`); see [order_logic.dart] for the canonical flow and the
/// legacy mappings.
enum OrderStatus {
  placed,
  confirmed,
  preparing,
  outForDelivery,
  delivered,
  cancelled,

  /// Week 1 vocabulary (Day 4): a freshly entered order.
  newOrder,

  /// Week 1 vocabulary (Day 4): being packed/prepared.
  processing,

  /// Week 1 vocabulary (Day 4): packed and waiting for the rider.
  ready,

  /// Week 1 vocabulary (Day 4): handed to the rider.
  dispatched,
}

OrderStatus orderStatusFromString(String? value) {
  switch (value) {
    case 'confirmed':
      return OrderStatus.confirmed;
    case 'preparing':
      return OrderStatus.preparing;
    case 'outForDelivery':
      return OrderStatus.outForDelivery;
    case 'delivered':
      return OrderStatus.delivered;
    case 'cancelled':
      return OrderStatus.cancelled;
    case 'newOrder':
    case 'new':
      return OrderStatus.newOrder;
    case 'processing':
      return OrderStatus.processing;
    case 'ready':
      return OrderStatus.ready;
    case 'dispatched':
      return OrderStatus.dispatched;
    case 'placed':
    default:
      return OrderStatus.placed;
  }
}

/// Where a staff-entered order came from (SRS §8 demo scope: orders are
/// entered by staff from a phone call, a WhatsApp message or a walk-in
/// customer — there is NO WhatsApp API integration in the demo).
enum OrderSource { phone, whatsapp, walkIn }

OrderSource orderSourceFromString(String? value) {
  switch (value) {
    case 'whatsapp':
      return OrderSource.whatsapp;
    case 'walkIn':
      return OrderSource.walkIn;
    case 'phone':
    default:
      return OrderSource.phone;
  }
}

/// Delivery to the customer's address, or pickup from the branch.
enum FulfillmentType { delivery, pickup }

FulfillmentType fulfillmentTypeFromString(String? value) {
  switch (value) {
    case 'pickup':
      return FulfillmentType.pickup;
    case 'delivery':
    default:
      return FulfillmentType.delivery;
  }
}

/// MVP payment is cash on delivery only. Online payments (JazzCash /
/// Easypaisa) arrive in Phase 3 — add new values here when they do.
enum PaymentMethod { cashOnDelivery }

PaymentMethod paymentMethodFromString(String? value) {
  switch (value) {
    case 'cashOnDelivery':
    default:
      return PaymentMethod.cashOnDelivery;
  }
}

/// One line item inside an order. A snapshot of the medicine at order time
/// (name + unit price are copied so later price changes don't rewrite history).
class OrderItem {
  final String medicineId;
  final String medicineName;
  final int quantity;
  final double unitPrice;

  const OrderItem({
    required this.medicineId,
    required this.medicineName,
    required this.quantity,
    required this.unitPrice,
  });

  factory OrderItem.fromMap(Map<String, dynamic> map) {
    return OrderItem(
      medicineId: map['medicineId'] as String? ?? '',
      medicineName: map['medicineName'] as String? ?? '',
      quantity: (map['quantity'] as num?)?.toInt() ?? 0,
      unitPrice: (map['unitPrice'] as num?)?.toDouble() ?? 0,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'medicineId': medicineId,
      'medicineName': medicineName,
      'quantity': quantity,
      'unitPrice': unitPrice,
    };
  }

  double get lineTotal => quantity * unitPrice;

  /// Line total in int minor units (paisa) — the only arithmetic the
  /// Day 4 totals code performs (see D6 / order_logic.dart).
  int get lineTotalMinor =>
      (unitPrice * 100).round() * quantity;
}

/// A customer order.
///
/// Firestore collection: `orders`.
class Order {
  final String id;
  final String customerId;
  final String branchId;
  final String? riderId;
  final List<OrderItem> items;
  final String deliveryAddress;
  final PaymentMethod paymentMethod;
  final OrderStatus status;
  final String? orderNotes;
  final String? prescriptionId;
  final double totalAmount;

  /// Discount applied to the order, in int minor units (paisa).
  /// Day 0 orders have no discount (0). Day 4 create/edit sets it.
  final int discountMinor;

  /// Where the order came from (phone / WhatsApp / walk-in). Day 0
  /// orders default to `phone`.
  final OrderSource source;

  /// Delivery to the address, or pickup from the branch. Day 0 orders
  /// default to `delivery`.
  final FulfillmentType fulfillment;

  final DateTime? createdAt;
  final DateTime? updatedAt;

  const Order({
    required this.id,
    required this.customerId,
    required this.branchId,
    this.riderId,
    required this.items,
    required this.deliveryAddress,
    this.paymentMethod = PaymentMethod.cashOnDelivery,
    this.status = OrderStatus.placed,
    this.orderNotes,
    this.prescriptionId,
    required this.totalAmount,
    this.discountMinor = 0,
    this.source = OrderSource.phone,
    this.fulfillment = FulfillmentType.delivery,
    this.createdAt,
    this.updatedAt,
  });

  factory Order.fromMap(String id, Map<String, dynamic> map) {
    final rawItems = map['items'] as List<dynamic>? ?? [];
    return Order(
      id: id,
      customerId: map['customerId'] as String? ?? '',
      branchId: map['branchId'] as String? ?? '',
      riderId: map['riderId'] as String?,
      items: rawItems
          .whereType<Map<String, dynamic>>()
          .map(OrderItem.fromMap)
          .toList(),
      deliveryAddress: map['deliveryAddress'] as String? ?? '',
      paymentMethod: paymentMethodFromString(map['paymentMethod'] as String?),
      status: orderStatusFromString(map['status'] as String?),
      orderNotes: map['orderNotes'] as String?,
      prescriptionId: map['prescriptionId'] as String?,
      totalAmount: (map['totalAmount'] as num?)?.toDouble() ?? 0,
      discountMinor: (map['discountMinor'] as num?)?.toInt() ?? 0,
      source: orderSourceFromString(map['source'] as String?),
      fulfillment: fulfillmentTypeFromString(
        map['fulfillment'] as String?,
      ),
      createdAt: parseDate(map['createdAt']),
      updatedAt: parseDate(map['updatedAt']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'customerId': customerId,
      'branchId': branchId,
      'riderId': riderId,
      'items': items.map((item) => item.toMap()).toList(),
      'deliveryAddress': deliveryAddress,
      'paymentMethod': paymentMethod.name,
      'status': status.name,
      'orderNotes': orderNotes,
      'prescriptionId': prescriptionId,
      'totalAmount': totalAmount,
      'discountMinor': discountMinor,
      'source': source.name,
      'fulfillment': fulfillment.name,
      'createdAt': dateToMap(createdAt),
      'updatedAt': dateToMap(updatedAt),
    };
  }

  double get computedTotal =>
      items.fold(0, (sum, item) => sum + item.lineTotal);

  /// Subtotal in int minor units (paisa), before discount.
  int get subtotalMinor =>
      items.fold(0, (sum, item) => sum + item.lineTotalMinor);

  /// Total payable in int minor units: subtotal minus discount, never
  /// below zero.
  int get totalMinor {
    final total = subtotalMinor - discountMinor;
    return total < 0 ? 0 : total;
  }

  Order copyWith({
    String? id,
    String? customerId,
    String? branchId,
    String? riderId,
    bool clearRiderId = false,
    List<OrderItem>? items,
    String? deliveryAddress,
    PaymentMethod? paymentMethod,
    OrderStatus? status,
    String? orderNotes,
    bool clearOrderNotes = false,
    String? prescriptionId,
    bool clearPrescriptionId = false,
    double? totalAmount,
    int? discountMinor,
    OrderSource? source,
    FulfillmentType? fulfillment,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return Order(
      id: id ?? this.id,
      customerId: customerId ?? this.customerId,
      branchId: branchId ?? this.branchId,
      riderId: clearRiderId ? null : (riderId ?? this.riderId),
      items: items ?? this.items,
      deliveryAddress: deliveryAddress ?? this.deliveryAddress,
      paymentMethod: paymentMethod ?? this.paymentMethod,
      status: status ?? this.status,
      orderNotes: clearOrderNotes ? null : (orderNotes ?? this.orderNotes),
      prescriptionId: clearPrescriptionId
          ? null
          : (prescriptionId ?? this.prescriptionId),
      totalAmount: totalAmount ?? this.totalAmount,
      discountMinor: discountMinor ?? this.discountMinor,
      source: source ?? this.source,
      fulfillment: fulfillment ?? this.fulfillment,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
