import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/services/branch_context.dart';
import '../../core/widgets/design_system.dart';
import 'auth_state.dart';

/// Signed-in staff profile: who is signed in, their role, their branch,
/// and sign-out.
///
/// When nobody is signed in (only reachable when the router runs without
/// auth gating, e.g. in tests) it shows an empty state with a working
/// way back to sign-in — never a blank screen.
class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authProvider);
    final activeBranch = ref.watch(activeBranchProvider);
    final theme = Theme.of(context);

    if (user == null) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SectionHeader(
              title: 'Profile',
              subtitle: 'Signed-in staff profile, branch and role details.',
            ),
            const SizedBox(height: 16),
            PharmaEmptyState(
              icon: Icons.person_outline,
              title: 'Not signed in',
              message:
                  'Sign in with a staff email or a demo account to see your profile.',
              actionLabel: 'Go to sign in',
              onAction: () => context.go('/login'),
            ),
          ],
        ),
      );
    }

    final branchLabel = user.seesAllBranches
        ? 'All branches'
        : activeBranch.name;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionHeader(
              title: 'Profile',
              subtitle: 'Signed in as ${user.name} (${user.roleLabel}).',
            ),
            const SizedBox(height: 16),
            PharmaCard(
              child: Column(
                children: [
                  Row(
                    children: [
                      Container(
                        width: 56,
                        height: 56,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary,
                          borderRadius: BorderRadius.circular(28),
                        ),
                        child: Text(
                          user.name.isEmpty
                              ? '?'
                              : user.name[0].toUpperCase(),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 24,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              user.name,
                              style: theme.textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              user.email,
                              style: theme.textTheme.bodyMedium,
                            ),
                          ],
                        ),
                      ),
                      const DemoModeBadge(),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const Divider(height: 1),
                  const SizedBox(height: 16),
                  _ProfileRow(
                    icon: Icons.admin_panel_settings_outlined,
                    label: 'Role',
                    value: user.roleLabel,
                  ),
                  const SizedBox(height: 12),
                  _ProfileRow(
                    icon: Icons.store_outlined,
                    label: 'Branch',
                    value: branchLabel,
                  ),
                  const SizedBox(height: 12),
                  _ProfileRow(
                    icon: Icons.email_outlined,
                    label: 'Email',
                    value: user.email,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Demo account — fictional staff member. In production this '
              'page shows the real staff record from Firebase Auth.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 24),
            PharmaButton(
              label: 'Sign out',
              icon: Icons.logout_outlined,
              variant: PharmaButtonVariant.danger,
              expand: true,
              onPressed: () {
                ref.read(authProvider.notifier).signOut();
                context.go('/login');
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfileRow extends StatelessWidget {
  const _ProfileRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, size: 20, color: theme.colorScheme.primary),
        const SizedBox(width: 12),
        SizedBox(
          width: 80,
          child: Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Expanded(
          child: Text(value, style: theme.textTheme.bodyMedium),
        ),
      ],
    );
  }
}
