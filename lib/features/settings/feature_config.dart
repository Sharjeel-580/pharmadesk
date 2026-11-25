import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Day 7 feature configuration (SRS FR-SYS-05).
///
/// The owner can enable/disable modules per organization. In the demo
/// the config lives in memory for the session; in production it is
/// stored per organization (`organizations/{orgId}/featureModules`)
/// and disabled modules expose no API functionality (rules-enforced).
///
/// Disabled modules disappear from navigation (sidebar + mobile More
/// sheet) and show a clear "disabled" state when opened directly
/// (see [FeatureGate]). Settings itself can never be disabled — it is
/// the screen that re-enables modules.

/// One toggleable module.
class FeatureModuleConfig {
  const FeatureModuleConfig({
    required this.key,
    required this.title,
    required this.description,
    required this.route,
  });

  final String key;
  final String title;
  final String description;

  /// Route the module lives at (used by the router gate + shell).
  final String route;
}

/// Toggleable modules, in navigation order. Dashboard, Settings and
/// Profile are always on and are not listed here.
const featureModules = <FeatureModuleConfig>[
  FeatureModuleConfig(
    key: 'orders',
    title: 'Orders',
    description: 'WhatsApp/phone order queue, status flow, rider assignment.',
    route: '/orders',
  ),
  FeatureModuleConfig(
    key: 'medicines',
    title: 'Medicines',
    description: 'Medicine catalogue — search, categories, prices, barcodes.',
    route: '/medicines',
  ),
  FeatureModuleConfig(
    key: 'inventory',
    title: 'Inventory',
    description: 'Stock, batches, expiry radar, stock movements.',
    route: '/inventory',
  ),
  FeatureModuleConfig(
    key: 'billing',
    title: 'Billing & POS',
    description: 'Counter billing — cart, discount, tax, receipt, payment.',
    route: '/billing',
  ),
  FeatureModuleConfig(
    key: 'customers',
    title: 'Customers',
    description: 'Customer directory, purchase history, credit ledger.',
    route: '/customers',
  ),
  FeatureModuleConfig(
    key: 'suppliers',
    title: 'Suppliers',
    description: 'Supplier profiles, contacts, purchase history, balances.',
    route: '/suppliers',
  ),
  FeatureModuleConfig(
    key: 'purchases',
    title: 'Purchases',
    description: 'Purchase orders, goods receiving, supplier payments.',
    route: '/purchases',
  ),
  FeatureModuleConfig(
    key: 'prescriptions',
    title: 'Prescriptions',
    description: 'Prescription review — pharmacist check before dispatch.',
    route: '/prescriptions',
  ),
  FeatureModuleConfig(
    key: 'reports',
    title: 'Reports',
    description: 'Sales, profit, stock valuation and expiry reports.',
    route: '/reports',
  ),
  FeatureModuleConfig(
    key: 'notifications',
    title: 'Notifications',
    description: 'Low-stock, expiry and order alerts.',
    route: '/notifications',
  ),
];

/// The module config for a route, or `null` when the route is not a
/// toggleable module (dashboard, settings, profile, auth, detail
/// pages — detail pages follow their parent module).
FeatureModuleConfig? featureModuleForRoute(String route) {
  for (final module in featureModules) {
    if (route == module.route || route.startsWith('${module.route}/')) {
      return module;
    }
  }
  return null;
}

/// Holds the enabled module keys for the session. All modules start
/// enabled.
class FeatureConfigNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() =>
      {for (final module in featureModules) module.key};

  bool isEnabled(String key) => state.contains(key);

  void setEnabled(String key, bool enabled) {
    final next = Set<String>.of(state);
    if (enabled) {
      next.add(key);
    } else {
      next.remove(key);
    }
    state = next;
  }

  void enableAll() {
    state = {for (final module in featureModules) module.key};
  }
}

final featureConfigProvider =
    NotifierProvider<FeatureConfigNotifier, Set<String>>(
      FeatureConfigNotifier.new,
    );
