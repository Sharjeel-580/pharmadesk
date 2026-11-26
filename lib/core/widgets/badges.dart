import 'package:flutter/material.dart';

import '../constants/app_colors.dart';

/// Status colour kinds used across badges and chips.
///
/// Maps to the Kalora palette: success green, warning amber, danger red,
/// info primary blue, neutral slate.
enum StatusKind { success, warning, danger, info, neutral }

extension StatusKindColors on StatusKind {
  Color get color => switch (this) {
    StatusKind.success => AppColors.success,
    StatusKind.warning => AppColors.warning,
    StatusKind.danger => AppColors.danger,
    StatusKind.info => AppColors.primary,
    StatusKind.neutral => AppColors.secondaryText,
  };
}

/// Small pill badge for statuses (In Stock, Low Stock, Delivered,
/// Cancelled, …). Coloured dot + label on a tinted background; readable
/// in light and dark themes.
class StatusBadge extends StatelessWidget {
  const StatusBadge({
    super.key,
    required this.label,
    required this.kind,
    this.icon,
  });

  final String label;
  final StatusKind kind;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final color = kind.color;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: color),
            const SizedBox(width: 4),
          ] else ...[
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
          ],
          // Week 6 Day 5 (D170): the label is Flexible so a badge
          // whose text is wider than its line WRAPS instead of
          // overflowing — a money figure must stay complete, so no
          // ellipsis here (the supplier aging badges overflowed by
          // 63px at 390px in the test font before this).
          Flexible(
            child: Text(
              label,
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Selectable filter chip (categories, status filters). Built on
/// [ChoiceChip] with the theme's chip styling.
class PharmaChip extends StatelessWidget {
  const PharmaChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final bool selected;
  final ValueChanged<bool> onSelected;

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: onSelected,
    );
  }
}
