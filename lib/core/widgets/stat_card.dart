import 'package:flutter/material.dart';

import '../utils/money.dart';
import 'cards.dart';

/// KPI stat card: label, big value, icon and an optional change line.
///
/// Pass [moneyMinorUnits] (int paisa) to render money with [formatPkr];
/// otherwise pass [value] as plain text. Tapping the card is optional
/// ([onTap]) — e.g. a sales card opening the reports module.
class StatCard extends StatelessWidget {
  const StatCard({
    super.key,
    required this.label,
    this.value,
    this.moneyMinorUnits,
    this.icon,
    this.deltaLabel,
    this.deltaPositive,
    this.onTap,
  }) : assert(
         value != null || moneyMinorUnits != null,
         'StatCard needs value or moneyMinorUnits',
       );

  final String label;
  final String? value;
  final int? moneyMinorUnits;
  final IconData? icon;
  final String? deltaLabel;
  final bool? deltaPositive;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final displayValue = moneyMinorUnits != null
        ? formatPkr(moneyMinorUnits!)
        : value!;
    return PharmaCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (icon != null)
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(
                      alpha: 0.1,
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    icon,
                    size: 20,
                    color: theme.colorScheme.primary,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          // Money values can be long ("Rs 1,234,567.00"): scale the
          // value down instead of wrapping to a second line, so the
          // card keeps its fixed height in KPI grids.
          SizedBox(
            width: double.infinity,
            child: FittedBox(
              alignment: Alignment.centerLeft,
              fit: BoxFit.scaleDown,
              child: Text(
                displayValue,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          if (deltaLabel != null) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                if (deltaPositive != null)
                  Icon(
                    deltaPositive!
                        ? Icons.trending_up
                        : Icons.trending_down,
                    size: 14,
                    color: deltaPositive!
                        ? theme.colorScheme.primary
                        : Theme.of(context).colorScheme.error,
                  ),
                if (deltaPositive != null) const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    deltaLabel!,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
