import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../constants/app_colors.dart';

/// White-label branding configuration.
///
/// Every pharmacy organization can customize: application name, logo,
/// primary color, secondary color, organization details and receipt
/// branding. The app reads its brand from [brandConfigProvider] and the
/// theme follows the brand's primary color — no code changes per client.
///
/// Stored per organization in Firestore (`organizations/{id}/settings`,
/// `branding` field) once the Firebase backend is wired; until then the
/// default (or Fazal Din) config below is used.
class BrandConfig {
  final String organizationName;
  final String appName;
  final String? logoAssetPath;
  final Color primaryColor;
  final Color secondaryColor;
  final String receiptHeader;

  const BrandConfig({
    required this.organizationName,
    required this.appName,
    this.logoAssetPath,
    required this.primaryColor,
    required this.secondaryColor,
    required this.receiptHeader,
  });

  /// Generic PharmaDesk product branding (default).
  static const BrandConfig defaults = BrandConfig(
    organizationName: 'PharmaDesk',
    appName: 'PharmaDesk',
    primaryColor: AppColors.primary,
    secondaryColor: AppColors.deepBlue,
    receiptHeader: 'PharmaDesk',
  );

  /// First client: Fazal Din's Pharma Plus (DHA Lahore).
  /// Shown under their own brand; the product name never appears to them.
  static const BrandConfig fazalDin = BrandConfig(
    organizationName: "Fazal Din's Pharma Plus",
    appName: "Fazal Din's Pharma Plus",
    primaryColor: AppColors.primary,
    secondaryColor: AppColors.deepBlue,
    receiptHeader: "Fazal Din's Pharma Plus — DHA Lahore",
  );

  factory BrandConfig.fromMap(Map<String, dynamic> map) {
    return BrandConfig(
      organizationName: map['organizationName'] as String? ?? 'PharmaDesk',
      appName: map['appName'] as String? ?? 'PharmaDesk',
      logoAssetPath: map['logoAssetPath'] as String?,
      primaryColor: Color(
        (map['primaryColor'] as num?)?.toInt() ?? AppColors.primary.toARGB32(),
      ),
      secondaryColor: Color(
        (map['secondaryColor'] as num?)?.toInt() ??
            AppColors.deepBlue.toARGB32(),
      ),
      receiptHeader: map['receiptHeader'] as String? ?? 'PharmaDesk',
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'organizationName': organizationName,
      'appName': appName,
      'logoAssetPath': logoAssetPath,
      'primaryColor': primaryColor.toARGB32(),
      'secondaryColor': secondaryColor.toARGB32(),
      'receiptHeader': receiptHeader,
    };
  }
}

/// Holds the active brand for the running app. Screens and the theme read
/// this provider; applying a different organization's config rebrands the
/// whole app at runtime.
class BrandConfigNotifier extends Notifier<BrandConfig> {
  @override
  BrandConfig build() => BrandConfig.defaults;

  void apply(BrandConfig config) => state = config;

  void applyFazalDin() => state = BrandConfig.fazalDin;

  void reset() => state = BrandConfig.defaults;
}

final brandConfigProvider =
    NotifierProvider<BrandConfigNotifier, BrandConfig>(
      BrandConfigNotifier.new,
    );
