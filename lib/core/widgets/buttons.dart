import 'package:flutter/material.dart';

import '../constants/app_colors.dart';

/// Button variants in the PharmaDesk design system.
enum PharmaButtonVariant { primary, secondary, danger, text }

/// Button sizes.
enum PharmaButtonSize { small, medium }

/// Primary / secondary / danger / text button built on the Kalora theme.
///
/// - Primary: filled brand primary.
/// - Secondary: outlined, brand primary text/border.
/// - Danger: filled danger red (destructive actions).
/// - Text: borderless, brand primary text.
///
/// Shows a spinner and ignores taps while [loading] is true; disabled
/// when [onPressed] is null. Renders in light and dark themes.
class PharmaButton extends StatelessWidget {
  const PharmaButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.variant = PharmaButtonVariant.primary,
    this.icon,
    this.loading = false,
    this.size = PharmaButtonSize.medium,
    this.expand = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final PharmaButtonVariant variant;
  final IconData? icon;
  final bool loading;
  final PharmaButtonSize size;
  final bool expand;

  bool get _disabled => onPressed == null || loading;

  EdgeInsets get _padding => size == PharmaButtonSize.small
      ? const EdgeInsets.symmetric(horizontal: 14, vertical: 8)
      : const EdgeInsets.symmetric(horizontal: 20, vertical: 14);

  TextStyle get _textStyle => TextStyle(
    fontFamily: 'Inter',
    fontSize: size == PharmaButtonSize.small ? 13 : 15,
    fontWeight: FontWeight.w600,
  );

  Widget _labelWithIcon(Color spinnerColor) {
    final labelWidget = Text(label, style: _textStyle);
    if (loading) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: spinnerColor,
            ),
          ),
          const SizedBox(width: 8),
          labelWidget,
        ],
      );
    }
    if (icon == null) return labelWidget;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18),
        const SizedBox(width: 8),
        labelWidget,
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
    );
    final onTap = _disabled ? null : onPressed;

    final Widget button = switch (variant) {
      PharmaButtonVariant.primary => ElevatedButton(
        onPressed: onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: theme.colorScheme.primary,
          foregroundColor: Colors.white,
          disabledBackgroundColor: theme.colorScheme.primary.withValues(
            alpha: 0.4,
          ),
          shape: shape,
          padding: _padding,
        ),
        child: _labelWithIcon(Colors.white),
      ),
      PharmaButtonVariant.secondary => OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          foregroundColor: theme.colorScheme.primary,
          side: BorderSide(color: theme.colorScheme.primary),
          shape: shape,
          padding: _padding,
        ),
        child: _labelWithIcon(theme.colorScheme.primary),
      ),
      PharmaButtonVariant.danger => ElevatedButton(
        onPressed: onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.danger,
          foregroundColor: Colors.white,
          disabledBackgroundColor: AppColors.danger.withValues(alpha: 0.4),
          shape: shape,
          padding: _padding,
        ),
        child: _labelWithIcon(Colors.white),
      ),
      PharmaButtonVariant.text => TextButton(
        onPressed: onTap,
        style: TextButton.styleFrom(
          foregroundColor: theme.colorScheme.primary,
          shape: shape,
          padding: _padding,
        ),
        child: _labelWithIcon(theme.colorScheme.primary),
      ),
    };

    if (!expand) return button;
    return SizedBox(width: double.infinity, child: button);
  }
}
