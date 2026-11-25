import 'package:flutter/material.dart';

import 'badges.dart';

/// Error box listing validation problems above a form's save button
/// (Day 6 — shared by the POS and customer screens; the Day 4 order
/// form has its own local copy).
class PharmaErrorBox extends StatelessWidget {
  const PharmaErrorBox({super.key, required this.errors});

  final List<String> errors;

  @override
  Widget build(BuildContext context) {
    final color = StatusKind.danger.color;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Please fix the following:',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
          const SizedBox(height: 4),
          for (final error in errors)
            Text('• $error', style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}
