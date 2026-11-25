import 'package:flutter/material.dart';

import 'buttons.dart';

/// Confirmation dialog.
///
/// Returns `true` when the user confirms, `false` on cancel, `null` when
/// dismissed by tapping outside / back. Use [danger] for destructive
/// actions (delete, cancel order) — the confirm button turns red.
Future<bool?> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Confirm',
  String cancelLabel = 'Cancel',
  bool danger = false,
}) {
  return showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        PharmaButton(
          label: cancelLabel,
          variant: PharmaButtonVariant.text,
          size: PharmaButtonSize.small,
          onPressed: () => Navigator.of(dialogContext).pop(false),
        ),
        PharmaButton(
          label: confirmLabel,
          variant: danger
              ? PharmaButtonVariant.danger
              : PharmaButtonVariant.primary,
          size: PharmaButtonSize.small,
          onPressed: () => Navigator.of(dialogContext).pop(true),
        ),
      ],
    ),
  );
}

/// Form dialog: a titled dialog with custom [child] content and
/// [actions]. Returns whatever the action buttons pop with (or null).
Future<T?> showPharmaFormDialog<T>(
  BuildContext context, {
  required String title,
  required Widget child,
  List<Widget> actions = const [],
}) {
  return showDialog<T>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(child: child),
      actions: actions,
    ),
  );
}
