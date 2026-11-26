import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Organization settings (Week 4 Day 4, D134 — SRS D-34, FR-SYS-07
/// settings + §3.1 `organizations/{orgId}/settings`).
///
/// Session-only in the demo (same posture as brand settings and
/// feature config); production persists them per organization in
/// Firestore. Every default is the behaviour the app already has
/// today — nothing here invents a client fact:
///
/// - **Tax:** the POS charges 0% today (`_taxRatePercent = 0` in
///   `pos_screen.dart`), and the SRS names no tax rate anywhere
///   (only `taxRateBps` per medicine in §3.2 and a `taxNumber` per
///   supplier). So the configurable default is 0%, shown as such.
/// - **Payment methods:** SRS FR-POS-04 names cash, card, bank
///   transfer, JazzCash/Easypaisa as configurable recorded methods.
///   The POS today offers cash / card / credit (khata) only, so
///   those three start enabled and the other three start off — the
///   setting is the config; wiring the POS method picker to it is a
///   follow-up (D134).
/// - **Receipt format:** paper width (80mm thermal is the default —
///   the standard counter width; 58mm is the small-printer option)
///   plus a footer line. The receipt header already lives in Brand
///   Settings; this is the format, not the header.
/// - **Discount limits:** the SRS names role-based discount limits
///   (FR-POS-03, §5.1) but gives no numbers, and the POS enforces
///   no cap today — so both limits default to "no cap" (`null`),
///   shown as "No limit", never as an invented percentage. Wiring
///   the POS to enforce them is a follow-up (D134).

/// Payment methods an organization accepts (recorded, never
/// processed — FR-POS-06).
enum OrgPaymentMethod { cash, card, bankTransfer, jazzCash, easypaisa, credit }

String orgPaymentMethodLabel(OrgPaymentMethod method) => switch (method) {
  OrgPaymentMethod.cash => 'Cash',
  OrgPaymentMethod.card => 'Card',
  OrgPaymentMethod.bankTransfer => 'Bank transfer',
  OrgPaymentMethod.jazzCash => 'JazzCash',
  OrgPaymentMethod.easypaisa => 'Easypaisa',
  OrgPaymentMethod.credit => 'Credit (khata)',
};

/// Receipt paper widths offered (millimetres).
const receiptPaperWidthsMm = <int>[80, 58];

class OrgSettings {
  const OrgSettings({
    this.taxRatePercent = 0,
    this.paymentMethods = const {
      OrgPaymentMethod.cash,
      OrgPaymentMethod.card,
      OrgPaymentMethod.credit,
    },
    this.receiptPaperWidthMm = 80,
    this.receiptFooter = '',
    this.maxLineDiscountPercent,
    this.maxBillDiscountPercent,
  });

  /// Default tax rate applied to taxable sales, in whole percent.
  final int taxRatePercent;

  /// Payment methods the organization accepts.
  final Set<OrgPaymentMethod> paymentMethods;

  /// Thermal receipt paper width in millimetres (80 or 58).
  final int receiptPaperWidthMm;

  /// Extra line printed at the foot of every receipt.
  final String receiptFooter;

  /// Maximum line discount, in whole percent — `null` = no cap.
  final int? maxLineDiscountPercent;

  /// Maximum bill discount, in whole percent — `null` = no cap.
  final int? maxBillDiscountPercent;

  OrgSettings copyWith({
    int? taxRatePercent,
    Set<OrgPaymentMethod>? paymentMethods,
    int? receiptPaperWidthMm,
    String? receiptFooter,
    int? maxLineDiscountPercent,
    bool clearMaxLineDiscountPercent = false,
    int? maxBillDiscountPercent,
    bool clearMaxBillDiscountPercent = false,
  }) {
    return OrgSettings(
      taxRatePercent: taxRatePercent ?? this.taxRatePercent,
      paymentMethods: paymentMethods ?? this.paymentMethods,
      receiptPaperWidthMm: receiptPaperWidthMm ?? this.receiptPaperWidthMm,
      receiptFooter: receiptFooter ?? this.receiptFooter,
      maxLineDiscountPercent: clearMaxLineDiscountPercent
          ? null
          : (maxLineDiscountPercent ?? this.maxLineDiscountPercent),
      maxBillDiscountPercent: clearMaxBillDiscountPercent
          ? null
          : (maxBillDiscountPercent ?? this.maxBillDiscountPercent),
    );
  }
}

/// Validation for the organization settings form. Returns the
/// problems found; empty = valid. Rates and caps are whole
/// percentages, 0–100; the paper width must be one of the offered
/// widths.
List<String> validateOrgSettings({
  required int taxRatePercent,
  required int receiptPaperWidthMm,
  int? maxLineDiscountPercent,
  int? maxBillDiscountPercent,
}) {
  final errors = <String>[];
  if (taxRatePercent < 0 || taxRatePercent > 100) {
    errors.add('Tax rate must be between 0% and 100%.');
  }
  if (!receiptPaperWidthsMm.contains(receiptPaperWidthMm)) {
    errors.add('Receipt paper width must be 80mm or 58mm.');
  }
  for (final (label, value) in [
    ('Maximum line discount', maxLineDiscountPercent),
    ('Maximum bill discount', maxBillDiscountPercent),
  ]) {
    if (value != null && (value < 0 || value > 100)) {
      errors.add('$label must be between 0% and 100%.');
    }
  }
  return errors;
}

class OrgSettingsNotifier extends Notifier<OrgSettings> {
  @override
  OrgSettings build() => const OrgSettings();

  /// Sets the tax rate. Out-of-range values are refused.
  bool setTaxRate(int percent) {
    if (percent < 0 || percent > 100) return false;
    state = state.copyWith(taxRatePercent: percent);
    return true;
  }

  void togglePaymentMethod(OrgPaymentMethod method, bool enabled) {
    final next = Set<OrgPaymentMethod>.of(state.paymentMethods);
    if (enabled) {
      next.add(method);
    } else {
      next.remove(method);
    }
    state = state.copyWith(paymentMethods: next);
  }

  /// Sets the receipt paper width. Unknown widths are refused.
  bool setReceiptPaperWidth(int widthMm) {
    if (!receiptPaperWidthsMm.contains(widthMm)) return false;
    state = state.copyWith(receiptPaperWidthMm: widthMm);
    return true;
  }

  void setReceiptFooter(String footer) {
    state = state.copyWith(receiptFooter: footer);
  }

  /// Sets a discount cap; `null` clears it (no cap). Out-of-range
  /// values are refused.
  bool setMaxLineDiscountPercent(int? percent) {
    if (percent != null && (percent < 0 || percent > 100)) return false;
    state = state.copyWith(
      maxLineDiscountPercent: percent,
      clearMaxLineDiscountPercent: percent == null,
    );
    return true;
  }

  bool setMaxBillDiscountPercent(int? percent) {
    if (percent != null && (percent < 0 || percent > 100)) return false;
    state = state.copyWith(
      maxBillDiscountPercent: percent,
      clearMaxBillDiscountPercent: percent == null,
    );
    return true;
  }

  void reset() => state = const OrgSettings();
}

final orgSettingsProvider =
    NotifierProvider<OrgSettingsNotifier, OrgSettings>(
      OrgSettingsNotifier.new,
    );
