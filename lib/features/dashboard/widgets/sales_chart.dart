import 'dart:math';

import 'package:flutter/material.dart';

import '../../../core/utils/money.dart';
import '../dashboard_data.dart';

/// Simple bar chart of daily sales (no chart package — plain Flutter
/// widgets, so the web build stays light and the chart renders in both
/// themes).
///
/// One bar per day (oldest → newest); the newest bar (today) is full
/// primary colour, earlier bars are the same colour at lower opacity.
/// Day-of-month labels appear under every 5th bar and under today.
class SalesChart extends StatelessWidget {
  const SalesChart({super.key, required this.series});

  final List<DailySales> series;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (series.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
        child: Center(child: Text('No sales in this period.')),
      );
    }
    final maxSales = series.fold<int>(
      0,
      (max, day) => max > day.salesMinor ? max : day.salesMinor,
    );
    if (maxSales == 0) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
        child: Center(child: Text('No sales in this period.')),
      );
    }
    final total = series.fold<int>(0, (sum, day) => sum + day.salesMinor);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Sales — last ${series.length} days',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Text(
              'Total ${formatPkr(total)}',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.primary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Peak day: ${formatPkr(maxSales)}',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        SizedBox(
          height: 180,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var i = 0; i < series.length; i++)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 1.5),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Expanded(
                          child: Align(
                            alignment: Alignment.bottomCenter,
                            child: FractionallySizedBox(
                              heightFactor: series[i].salesMinor == 0
                                  ? 0
                                  : max(
                                      series[i].salesMinor / maxSales,
                                      0.02,
                                    ),
                              child: Container(
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.primary.withValues(
                                    alpha: i == series.length - 1
                                        ? 1.0
                                        : 0.55,
                                  ),
                                  borderRadius: const BorderRadius.vertical(
                                    top: Radius.circular(3),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _dayLabel(series[i].date, i, series.length),
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// Day-of-month label under every 5th bar and under the last bar.
  String _dayLabel(DateTime date, int index, int length) {
    if (index == length - 1) return '${date.day}';
    if (index % 5 == 0) return '${date.day}';
    return '';
  }
}
