import 'package:flutter/material.dart';

/// PharmaDesk design tokens — Kalora-inspired premium corporate palette.
///
/// Source of truth for every color in the app. Do NOT hardcode hex colors
/// in widgets; use these constants (or the brand-derived theme) instead.
/// The previous emerald/lime direction is retired — see docs/technical-decisions.md.
abstract final class AppColors {
  /// Primary Blue.
  static const Color primary = Color(0xFF164AAB);

  /// Deep Blue — headers, sidebar, secondary actions.
  static const Color deepBlue = Color(0xFF073477);

  /// Pure white — cards, app bars (light theme).
  static const Color white = Color(0xFFFFFFFF);

  /// App background (light theme).
  static const Color background = Color(0xFFF3F6FA);

  /// Soft Blue — chips, highlights, primary containers.
  static const Color softBlue = Color(0xFFDCE7F5);

  /// Dark text — headings, primary content.
  static const Color darkText = Color(0xFF17243A);

  /// Secondary text — captions, hints, metadata.
  static const Color secondaryText = Color(0xFF64748B);

  /// Success — in stock, delivered, paid.
  static const Color success = Color(0xFF20A779);

  /// Warning — low stock, near expiry, pending.
  static const Color warning = Color(0xFFE9A23B);

  /// Danger — expired, out of stock, cancelled, errors.
  static const Color danger = Color(0xFFDC4545);

  // --- Dark theme surfaces (derived from the same blue family) ---

  /// Dark background.
  static const Color darkBackground = Color(0xFF0D1526);

  /// Dark surface (cards, app bars).
  static const Color darkSurface = Color(0xFF16223A);

  /// Dark surface variant (inputs, dividers on dark).
  static const Color darkSurfaceVariant = Color(0xFF1F2E4D);

  /// Dark primary text.
  static const Color darkTextPrimary = Color(0xFFF1F5F9);

  /// Dark secondary text.
  static const Color darkTextSecondary = Color(0xFF94A3B8);
}
