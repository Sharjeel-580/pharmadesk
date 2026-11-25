import 'package:flutter/material.dart';

import 'badges.dart';

/// "DEMO MODE" indicator (SRS §8.2: obvious demo indicator on every
/// screen).
///
/// A small warning-amber pill used in the app-shell top bar (so every
/// module screen carries it) and on the auth screens (splash, login,
/// forgot password), which sit outside the shell.
class DemoModeBadge extends StatelessWidget {
  const DemoModeBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return const StatusBadge(
      label: 'DEMO MODE',
      kind: StatusKind.warning,
      icon: Icons.science_outlined,
    );
  }
}
