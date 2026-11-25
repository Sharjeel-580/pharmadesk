import 'package:flutter/material.dart';

/// Card container for the PharmaDesk design system.
///
/// Thin wrapper over [Card] with the theme's card style (12px radius,
/// soft border, low elevation) so every card in the app looks the same
/// in light and dark themes. Tap handling is optional.
class PharmaCard extends StatelessWidget {
  const PharmaCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.margin,
    this.onTap,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final card = Card(
      margin: margin,
      child: Padding(padding: padding, child: child),
    );
    if (onTap == null) return card;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: card,
    );
  }
}
