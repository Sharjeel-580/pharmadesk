import 'package:flutter/material.dart';

import '../core/constants/app_colors.dart';
import '../core/theme/app_theme.dart';
import '../core/theme/white_label.dart';

/// ⚠️ FLAGGED FOR CONVERSION — do not build customer features on this file.
///
/// This was the Day 0 **customer mobile app** shell. PharmaDesk is NOT a
/// customer-facing shopping application (Week 1 master prompt §1): the
/// software is for pharmacy owners, administrators, branch managers,
/// pharmacists, cashiers and other authorized staff only.
///
/// Phase 1 converts this entry point into the **staff phone app**
/// (order entry, billing, stock check, barcode scan, alerts, customers,
/// riders, reports). The file is kept — not deleted — so the conversion
/// reuses its shell instead of starting from zero.
class CustomerApp extends StatelessWidget {
  const CustomerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PharmaDesk — Staff (legacy shell)',
      theme: AppTheme.light(BrandConfig.defaults),
      darkTheme: AppTheme.dark(BrandConfig.defaults),
      home: const _CustomerHome(),
    );
  }
}

class _CustomerHome extends StatelessWidget {
  const _CustomerHome();

  static const _staffFeatures = [
    'Order entry — WhatsApp/phone orders recorded by staff',
    'Billing — bill, receipt, cash on delivery record',
    'Stock check — search by name/brand/generic, price, expiry',
    'Barcode scan — scan to add to bill or stock',
    'Alerts — low stock and expiry alerts on the phone',
    'Customers — record, order history, udhaar/khata ledger',
    'Riders — assign rider, delivery status',
    'Reports — today\'s sales and profit at a glance',
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('PharmaDesk — Staff')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'FLAGGED FOR CONVERSION',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: AppColors.danger,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Legacy customer-app shell — becomes the staff phone app in Phase 1.',
          ),
          const SizedBox(height: 16),
          ..._staffFeatures.map(
            (item) => Card(
              child: ListTile(
                leading: const Icon(Icons.medication_outlined),
                title: Text(item),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
