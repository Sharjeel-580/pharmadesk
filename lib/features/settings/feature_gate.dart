import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/widgets/design_system.dart';
import 'feature_config.dart';

/// Guards a module route behind its feature flag (SRS FR-SYS-05).
///
/// When the module for [route] is enabled the [child] renders
/// unchanged; when it is disabled a clear "module disabled" state is
/// shown instead of the module, with working actions to re-enable it
/// (Settings) or go back (Dashboard). Routes that are not toggleable
/// modules (dashboard, settings, profile, auth, unknown) always
/// render their child.
class FeatureGate extends ConsumerWidget {
  const FeatureGate({super.key, required this.route, required this.child});

  final String route;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final module = featureModuleForRoute(route);
    if (module == null) return child;
    final enabled = ref.watch(featureConfigProvider).contains(module.key);
    if (enabled) return child;
    return _ModuleDisabledScreen(module: module);
  }
}

class _ModuleDisabledScreen extends StatelessWidget {
  const _ModuleDisabledScreen({required this.module});

  final FeatureModuleConfig module;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            title: module.title,
            subtitle: module.description,
            actionLabel: 'Back to Dashboard',
            actionIcon: Icons.dashboard_outlined,
            onAction: () => context.go('/dashboard'),
          ),
          const SizedBox(height: 16),
          PharmaEmptyState(
            icon: Icons.extension_off_outlined,
            title: '${module.title} is disabled',
            message:
                'This module is turned off for this organization in '
                'Feature Settings (SRS FR-SYS-05). Turn it back on in '
                'Settings → Features to use it again. Nothing about '
                'this module was deleted — its data is untouched.',
            actionLabel: 'Open Feature Settings',
            onAction: () => context.go('/settings'),
          ),
          const SizedBox(height: 16),
          PharmaButton(
            label: 'Back to Dashboard',
            variant: PharmaButtonVariant.secondary,
            icon: Icons.dashboard_outlined,
            onPressed: () => context.go('/dashboard'),
          ),
        ],
      ),
    );
  }
}
