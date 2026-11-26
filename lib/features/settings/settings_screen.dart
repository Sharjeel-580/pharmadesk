import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/branch_context.dart';
import '../../core/theme/theme_mode_provider.dart';
import '../../core/theme/white_label.dart';
import '../../core/widgets/design_system.dart';
import '../../core/widgets/sync_status_widget.dart';
import '../../features/billing/receipt_printer.dart';
import 'feature_config.dart';
import 'org_settings.dart';
import 'roles_permissions.dart';

/// Settings (Day 7, SRS FR-SYS-05/06, D-29/30/31/34).
///
/// Route `/settings`.
///
/// Six tabs:
/// - **General** — theme (light / dark / system), default branch,
///   demo-mode notes.
/// - **Organization** (Week 4 Day 4, D134 — SRS D-34) — tax config,
///   payment methods, receipt format, discount limits.
/// - **Sync** (Week 4 Day 4, D134 — SRS D-34) — live sync status
///   from the layer (pending queue + last sync), never a faked
///   status.
/// - **Branding** — white-label Brand Settings: organization name,
///   app name, receipt header, primary/secondary colours. Applying
///   rebrands the shell immediately (the theme follows the brand).
/// - **Roles & Permissions** — the SRS §5.1 matrix (read-only) plus a
///   mock demo role picker (highlight a role's column; assignment is
///   mock — production enforcement is Firestore rules + custom
///   claims, FR-SYS-02).
/// - **Features** — enable/disable modules per organization
///   (FR-SYS-05). Disabled modules leave navigation and show a clear
///   disabled state when opened directly.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  String _highlightRole = 'Pharmacist';

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 6,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SectionHeader(
              title: 'Settings',
              subtitle:
                  'Organization branding, roles, permissions and features',
            ),
            const SizedBox(height: 16),
            const TabBar(
              isScrollable: true,
              tabs: [
                Tab(text: 'General'),
                Tab(text: 'Organization'),
                Tab(text: 'Sync'),
                Tab(text: 'Branding'),
                Tab(text: 'Roles & Permissions'),
                Tab(text: 'Features'),
              ],
            ),
            const SizedBox(height: 16),
            Expanded(
              child: TabBarView(
                children: [
                  _GeneralTab(),
                  const _OrganizationTab(),
                  const _SyncTab(),
                  const _BrandingTab(),
                  _RolesTab(highlightRole: _highlightRole,
                    onRoleChanged: (role) =>
                        setState(() => _highlightRole = role),
                  ),
                  const _FeaturesTab(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// --- General ------------------------------------------------------------

class _GeneralTab extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    final branch = ref.watch(activeBranchProvider);
    final theme = Theme.of(context);
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PharmaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Theme',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                RadioGroup<ThemeMode>(
                  groupValue: mode,
                  onChanged: (selected) {
                    if (selected != null) {
                      ref.read(themeModeProvider.notifier).setMode(selected);
                    }
                  },
                  child: Column(
                    children: [
                      for (final entry in [
                        (ThemeMode.light, 'Light'),
                        (ThemeMode.dark, 'Dark'),
                        (ThemeMode.system, 'System'),
                      ])
                        RadioListTile<ThemeMode>(
                          title: Text(entry.$2),
                          value: entry.$1,
                          contentPadding: EdgeInsets.zero,
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          PharmaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Default branch',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'The branch the app opens on. You can still switch '
                  'branches from the top bar at any time.',
                ),
                const SizedBox(height: 8),
                // Week 8 Day 2 (D177): isExpanded (the D153/D162
                // trap) — the branch name is wider than the 390px
                // card line without it.
                DropdownButton<String>(
                  isExpanded: true,
                  value: branch.id,
                  items: [
                    for (final b in demoBranches)
                      DropdownMenuItem<String>(
                        value: b.id,
                        child: Text(b.name),
                      ),
                  ],
                  onChanged: (selected) {
                    if (selected != null) {
                      ref
                          .read(activeBranchProvider.notifier)
                          .switchTo(selected);
                    }
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const _PrinterCard(),
          const SizedBox(height: 16),
          PharmaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Demo mode',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'This build runs on fictional sample data with a mock '
                  'backend. Data resets when the app restarts; nothing '
                  'syncs between devices. Settings on this screen apply '
                  'for the session only — production persists them in '
                  'Firestore per organization.',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// --- Organization (D-34) ----------------------------------------------

/// Organization settings (Week 4 Day 4, D134 — SRS D-34): tax
/// config, payment methods, receipt format, discount limits.
/// Defaults are the behaviour the app already has (see
/// `org_settings.dart`); nothing here invents a client rate.
class _OrganizationTab extends ConsumerStatefulWidget {
  const _OrganizationTab();

  @override
  ConsumerState<_OrganizationTab> createState() => _OrganizationTabState();
}

class _OrganizationTabState extends ConsumerState<_OrganizationTab> {
  late final TextEditingController _taxController;
  late final TextEditingController _footerController;
  late final TextEditingController _lineCapController;
  late final TextEditingController _billCapController;
  String? _error;

  @override
  void initState() {
    super.initState();
    final settings = ref.read(orgSettingsProvider);
    _taxController = TextEditingController(
      text: '${settings.taxRatePercent}',
    );
    _footerController = TextEditingController(text: settings.receiptFooter);
    _lineCapController = TextEditingController(
      text: settings.maxLineDiscountPercent?.toString() ?? '',
    );
    _billCapController = TextEditingController(
      text: settings.maxBillDiscountPercent?.toString() ?? '',
    );
  }

  @override
  void dispose() {
    _taxController.dispose();
    _footerController.dispose();
    _lineCapController.dispose();
    _billCapController.dispose();
    super.dispose();
  }

  int? _parsePercent(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    return int.tryParse(trimmed);
  }

  void _applyTax() {
    final value = _parsePercent(_taxController.text);
    if (value == null) {
      setState(() => _error = 'Tax rate must be a whole number.');
      return;
    }
    if (!ref.read(orgSettingsProvider.notifier).setTaxRate(value)) {
      setState(() => _error = 'Tax rate must be between 0% and 100%.');
      return;
    }
    setState(() => _error = null);
  }

  void _applyCap({
    required TextEditingController controller,
    required bool Function(int?) setter,
    required String label,
  }) {
    final text = controller.text.trim();
    if (text.isEmpty) {
      setter(null);
      setState(() => _error = null);
      return;
    }
    final value = int.tryParse(text);
    if (value == null) {
      setState(() => _error = '$label must be a whole number.');
      return;
    }
    if (!setter(value)) {
      setState(() => _error = '$label must be between 0% and 100%.');
      return;
    }
    setState(() => _error = null);
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(orgSettingsProvider);
    final notifier = ref.read(orgSettingsProvider.notifier);
    final theme = Theme.of(context);
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_error != null) ...[
            PharmaErrorBox(errors: [_error!]),
            const SizedBox(height: 16),
          ],
          PharmaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Tax config',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Default tax rate applied to taxable sales. The '
                  'SRS names no tax rate, and the POS charges 0% '
                  'today — so the default is 0%. The POS reads this '
                  'rate for new bills (D136).',
                ),
                const SizedBox(height: 12),
                PharmaTextField(
                  controller: _taxController,
                  label: 'Tax rate (%)',
                  hintText: '0',
                  keyboardType: TextInputType.number,
                  onChanged: (_) => _applyTax(),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          PharmaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Payment methods',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Which recorded payment methods the organization '
                  'accepts (FR-POS-04 — payments are recorded, never '
                  'processed, FR-POS-06). Cash, card and credit '
                  '(khata) are what the POS offers today; bank '
                  'transfer, JazzCash and Easypaisa start off.',
                ),
                const SizedBox(height: 8),
                for (final method in OrgPaymentMethod.values)
                  SwitchListTile(
                    title: Text(orgPaymentMethodLabel(method)),
                    value: settings.paymentMethods.contains(method),
                    onChanged: (enabled) =>
                        notifier.togglePaymentMethod(method, enabled),
                    contentPadding: EdgeInsets.zero,
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          PharmaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Receipt format',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Paper width and footer line for printed receipts. '
                  'The receipt header lives in Branding.',
                ),
                const SizedBox(height: 12),
                DropdownButton<int>(
                  key: const ValueKey('receipt-paper-width'),
                  value: settings.receiptPaperWidthMm,
                  items: [
                    for (final width in receiptPaperWidthsMm)
                      DropdownMenuItem(
                        value: width,
                        child: Text('$width mm thermal paper'),
                      ),
                  ],
                  onChanged: (width) {
                    if (width != null) {
                      notifier.setReceiptPaperWidth(width);
                    }
                  },
                ),
                const SizedBox(height: 12),
                PharmaTextField(
                  controller: _footerController,
                  label: 'Receipt footer',
                  hintText: 'e.g. Thank you for shopping with us',
                  onChanged: (value) => notifier.setReceiptFooter(value),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          PharmaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Discount limits',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Maximum discounts in whole percent. Blank means '
                  'no cap — the SRS names role-based limits '
                  '(FR-POS-03) but gives no numbers, and the POS '
                  'enforces no cap today, so no number is invented '
                  'here. Wiring the POS to enforce these caps is a '
                  'follow-up (D134).',
                ),
                const SizedBox(height: 12),
                PharmaTextField(
                  controller: _lineCapController,
                  label: 'Maximum line discount (%) — blank = no limit',
                  hintText: 'Leave blank for no limit',
                  keyboardType: TextInputType.number,
                  onChanged: (_) => _applyCap(
                    controller: _lineCapController,
                    setter: (value) => notifier.setMaxLineDiscountPercent(
                      value,
                    ),
                    label: 'Maximum line discount',
                  ),
                ),
                const SizedBox(height: 12),
                PharmaTextField(
                  controller: _billCapController,
                  label: 'Maximum bill discount (%) — blank = no limit',
                  hintText: 'Leave blank for no limit',
                  keyboardType: TextInputType.number,
                  onChanged: (_) => _applyCap(
                    controller: _billCapController,
                    setter: (value) => notifier.setMaxBillDiscountPercent(
                      value,
                    ),
                    label: 'Maximum bill discount',
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// --- Sync (D-34) ---------------------------------------------------------

/// Sync status (Week 4 Day 4, D134 — SRS D-34): the live sync state
/// from the layer — the same `syncStatusProvider` the sync chip on
/// the POS / inventory / orders screens reads (D108). Pending count
/// and last-sync time are real layer values; when nothing has synced
/// yet the screen says "Never synced" instead of inventing a time.
class _SyncTab extends ConsumerWidget {
  const _SyncTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final statusAsync = ref.watch(syncStatusProvider);
    final theme = Theme.of(context);
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PharmaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Sync status',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Live from the sync queue (D108). Offline POS and '
                  'stock operations queue locally and sync when '
                  'connectivity returns (§2.5); nothing here is a '
                  'stored or faked status.',
                ),
                const SizedBox(height: 12),
                const SyncStatusChip(),
                const SizedBox(height: 12),
                statusAsync.when(
                  loading: () => const Text('Reading sync queue…'),
                  error: (error, _) =>
                      Text('Sync status unavailable: $error'),
                  data: (status) => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        status.available
                            ? '${status.pendingCount} operation(s) pending sync'
                            : 'Sync status unavailable',
                      ),
                      Text(status.lastSyncLabel),
                      if (status.pendingOperations.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        const Text(
                          'Pending operations',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                        for (final op in status.pendingOperations)
                          Text(
                            '• ${op.kind.name} ${op.entityType} '
                            '${op.entityId} (${op.status.name})',
                          ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// --- Printer ------------------------------------------------------------

/// Receipt printer settings (Week 2 Day 4): printer name + type,
/// with a test print that actually prints and a cash-drawer test.
/// The browser type prints through the web print dialog today;
/// network / USB report their (not yet implemented) status honestly
/// instead of pretending to print (see `receipt_printer.dart`).
class _PrinterCard extends ConsumerStatefulWidget {
  const _PrinterCard();

  @override
  ConsumerState<_PrinterCard> createState() => _PrinterCardState();
}

class _PrinterCardState extends ConsumerState<_PrinterCard> {
  late final TextEditingController _nameController;
  late final TextEditingController _hostController;
  late final TextEditingController _portController;
  bool _printing = false;

  @override
  void initState() {
    super.initState();
    final settings = ref.read(printerSettingsProvider);
    _nameController = TextEditingController(text: settings.name);
    _hostController = TextEditingController(text: settings.networkHost);
    _portController = TextEditingController(text: '${settings.networkPort}');
  }

  @override
  void dispose() {
    _nameController.dispose();
    _hostController.dispose();
    _portController.dispose();
    super.dispose();
  }

  Future<void> _runPrinterAction(
    Future<PrinterResult> Function(ReceiptPrinter printer) action,
  ) async {
    setState(() => _printing = true);
    final printer = ref.read(receiptPrinterProvider);
    final result = await action(printer);
    if (!mounted) return;
    setState(() => _printing = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(result.message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(printerSettingsProvider);
    final printer = ref.watch(receiptPrinterProvider);
    final theme = Theme.of(context);
    final notifier = ref.read(printerSettingsProvider.notifier);
    return PharmaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Receipt printer',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(printer.status.message),
          const SizedBox(height: 12),
          PharmaTextField(
            controller: _nameController,
            label: 'Printer name',
            hintText: 'e.g. Counter printer',
            onChanged: (value) => notifier.setName(value),
          ),
          const SizedBox(height: 12),
          const Text(
            'Printer type',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          DropdownButton<PrinterType>(
            key: const ValueKey('printer-type-dropdown'),
            value: settings.type,
            isExpanded: true,
            items: [
              for (final type in PrinterType.values)
                DropdownMenuItem(
                  value: type,
                  child: Text(printerTypeLabel(type)),
                ),
            ],
            onChanged: (type) {
              if (type != null) notifier.setType(type);
            },
          ),
          if (settings.type == PrinterType.network) ...[
            const SizedBox(height: 12),
            PharmaTextField(
              controller: _hostController,
              label: 'Printer IP / hostname',
              hintText: 'e.g. 192.168.1.50',
              onChanged: (value) => notifier.setNetworkHost(value),
            ),
            const SizedBox(height: 12),
            PharmaTextField(
              controller: _portController,
              label: 'Port',
              hintText: '9100',
              keyboardType: TextInputType.number,
              onChanged: (value) {
                final port = int.tryParse(value.trim());
                if (port != null && port > 0) notifier.setNetworkPort(port);
              },
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              PharmaButton(
                key: const ValueKey('printer-test-print'),
                label: _printing ? 'Printing…' : 'Test print',
                icon: Icons.print_outlined,
                loading: _printing,
                onPressed: _printing
                    ? null
                    : () => _runPrinterAction(
                        (p) => p.printText(
                          testReceiptText(ref.read(printerSettingsProvider)),
                        ),
                      ),
              ),
              PharmaButton(
                label: 'Open cash drawer',
                icon: Icons.point_of_sale_outlined,
                variant: PharmaButtonVariant.secondary,
                onPressed: _printing
                    ? null
                    : () => _runPrinterAction((p) => p.openCashDrawer()),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// --- Branding -----------------------------------------------------------

const _brandPalette = <(String, Color)>[
  ('Kalora blue', Color(0xFF164AAB)),
  ('Deep blue', Color(0xFF073477)),
  ('Teal', Color(0xFF0E7C6B)),
  ('Green', Color(0xFF20A779)),
  ('Amber', Color(0xFFE9A23B)),
  ('Red', Color(0xFFDC4545)),
  ('Purple', Color(0xFF6C4BD8)),
  ('Slate', Color(0xFF475569)),
];

class _BrandingTab extends ConsumerStatefulWidget {
  const _BrandingTab();

  @override
  ConsumerState<_BrandingTab> createState() => _BrandingTabState();
}

class _BrandingTabState extends ConsumerState<_BrandingTab> {
  late final _orgName = TextEditingController();
  late final _appName = TextEditingController();
  late final _receiptHeader = TextEditingController();
  late Color _primary;
  late Color _secondary;
  String? _error;
  bool _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    final brand = ref.read(brandConfigProvider);
    _orgName.text = brand.organizationName;
    _appName.text = brand.appName;
    _receiptHeader.text = brand.receiptHeader;
    _primary = brand.primaryColor;
    _secondary = brand.secondaryColor;
    _initialized = true;
  }

  @override
  void dispose() {
    _orgName.dispose();
    _appName.dispose();
    _receiptHeader.dispose();
    super.dispose();
  }

  void _applyPreset(BrandConfig preset) {
    setState(() {
      _orgName.text = preset.organizationName;
      _appName.text = preset.appName;
      _receiptHeader.text = preset.receiptHeader;
      _primary = preset.primaryColor;
      _secondary = preset.secondaryColor;
      _error = null;
    });
  }

  void _apply() {
    if (_orgName.text.trim().isEmpty || _appName.text.trim().isEmpty) {
      setState(
        () => _error = 'Organization name and app name are required.',
      );
      return;
    }
    setState(() => _error = null);
    ref
        .read(brandConfigProvider.notifier)
        .apply(
          BrandConfig(
            organizationName: _orgName.text.trim(),
            appName: _appName.text.trim(),
            primaryColor: _primary,
            secondaryColor: _secondary,
            receiptHeader: _receiptHeader.text.trim().isEmpty
                ? _appName.text.trim()
                : _receiptHeader.text.trim(),
          ),
        );
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Branding applied — the shell rebranded immediately.'),
      ),
    );
  }

  Widget _colorPicker({
    required String label,
    required Color selected,
    required ValueChanged<Color> onSelected,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (name, color) in _brandPalette)
              GestureDetector(
                onTap: () => onSelected(color),
                child: Tooltip(
                  message: name,
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: selected == color
                            ? Colors.white
                            : Colors.transparent,
                        width: 2,
                      ),
                      boxShadow: selected == color
                          ? [
                              BoxShadow(
                                color: color.withValues(alpha: 0.5),
                                blurRadius: 6,
                              ),
                            ]
                          : null,
                    ),
                    child: selected == color
                        ? const Icon(
                            Icons.check,
                            size: 18,
                            color: Colors.white,
                          )
                        : null,
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final brand = ref.watch(brandConfigProvider);
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PharmaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'White-label branding (FR-SYS-06)',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Each organization sets its own name and colours. '
                  'Applying rebrands the whole app at once — sidebar, '
                  'top bar and theme.',
                ),
                const SizedBox(height: 16),
                if (_error != null) ...[
                  PharmaErrorBox(errors: [_error!]),
                  const SizedBox(height: 12),
                ],
                PharmaTextField(
                  controller: _orgName,
                  label: 'Organization name',
                ),
                const SizedBox(height: 12),
                PharmaTextField(controller: _appName, label: 'App name'),
                const SizedBox(height: 12),
                PharmaTextField(
                  controller: _receiptHeader,
                  label: 'Receipt header',
                ),
                const SizedBox(height: 16),
                _colorPicker(
                  label: 'Primary colour',
                  selected: _primary,
                  onSelected: (color) => setState(() => _primary = color),
                ),
                const SizedBox(height: 16),
                _colorPicker(
                  label: 'Secondary colour (sidebar)',
                  selected: _secondary,
                  onSelected: (color) => setState(() => _secondary = color),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    PharmaButton(
                      label: 'Apply branding',
                      icon: Icons.palette_outlined,
                      onPressed: _apply,
                    ),
                    PharmaButton(
                      label: "Use Fazal Din's Pharma Plus",
                      variant: PharmaButtonVariant.secondary,
                      size: PharmaButtonSize.small,
                      onPressed: () => _applyPreset(BrandConfig.fazalDin),
                    ),
                    PharmaButton(
                      label: 'Reset to PharmaDesk',
                      variant: PharmaButtonVariant.secondary,
                      size: PharmaButtonSize.small,
                      onPressed: () => _applyPreset(BrandConfig.defaults),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  'Currently active: ${brand.organizationName} '
                  '(app name "${brand.appName}").',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// --- Roles & permissions ------------------------------------------------

class _RolesTab extends StatelessWidget {
  const _RolesTab({required this.highlightRole, required this.onRoleChanged});

  final String highlightRole;
  final ValueChanged<String> onRoleChanged;

  @override
  Widget build(BuildContext context) {
    final highlightIndex = demoRoles.indexOf(highlightRole);
    final theme = Theme.of(context);
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PharmaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Roles & permissions (SRS §5.1)',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Read-only matrix. In production these permissions are '
                  'enforced by Firestore security rules + custom claims '
                  '(FR-SYS-02) — the app only hides UI, it never grants '
                  'access. The role picker below is a demo view: it '
                  'highlights one role\'s column, it does not change '
                  'what the signed-in user can do.',
                ),
                const SizedBox(height: 12),
                DropdownButton<String>(
                  value: highlightRole,
                  items: [
                    for (final role in demoRoles)
                      DropdownMenuItem<String>(
                        value: role,
                        child: Text('View as: $role'),
                      ),
                  ],
                  onChanged: (selected) {
                    if (selected != null) onRoleChanged(selected);
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          PharmaCard(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columns: [
                  const DataColumn(label: Text('Capability')),
                  for (var i = 0; i < demoRoles.length; i++)
                    DataColumn(
                      label: Text(
                        demoRoles[i],
                        style: TextStyle(
                          fontWeight: i == highlightIndex
                              ? FontWeight.w800
                              : FontWeight.w600,
                          color: i == highlightIndex
                              ? theme.colorScheme.primary
                              : null,
                        ),
                      ),
                    ),
                ],
                rows: [
                  for (final capability in roleCapabilities)
                    DataRow(
                      cells: [
                        DataCell(
                          SizedBox(
                            width: 240,
                            child: Text(capability.label),
                          ),
                        ),
                        for (var i = 0; i < demoRoles.length; i++)
                          DataCell(
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: i == highlightIndex
                                  ? BoxDecoration(
                                      color: theme.colorScheme.primary
                                          .withValues(alpha: 0.12),
                                      borderRadius: BorderRadius.circular(6),
                                    )
                                  : null,
                              child: Text(
                                rolePermissionMatrix[capability.key]?[i]
                                        .label ??
                                    '—',
                                style: TextStyle(
                                  fontWeight: i == highlightIndex
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '✓ = allowed • Own = own branch only • RO = read-only • — = not allowed',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

// --- Features -----------------------------------------------------------

class _FeaturesTab extends ConsumerWidget {
  const _FeaturesTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(featureConfigProvider);
    final theme = Theme.of(context);
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PharmaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Feature modules (FR-SYS-05)',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Turn modules on or off for this organization. A '
                  'disabled module disappears from navigation and shows '
                  'a clear disabled state if opened directly. Dashboard, '
                  'Settings and Profile are always on.',
                ),
                const SizedBox(height: 12),
                PharmaButton(
                  label: 'Enable all modules',
                  variant: PharmaButtonVariant.secondary,
                  size: PharmaButtonSize.small,
                  icon: Icons.extension_outlined,
                  onPressed: () => ref
                      .read(featureConfigProvider.notifier)
                      .enableAll(),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          PharmaCard(
            child: Column(
              children: [
                for (var i = 0; i < featureModules.length; i++) ...[
                  if (i > 0) const Divider(height: 1),
                  SwitchListTile(
                    title: Text(featureModules[i].title),
                    subtitle: Text(featureModules[i].description),
                    secondary: Icon(
                      featureModuleIcon(featureModules[i].key),
                      color: theme.colorScheme.primary,
                    ),
                    value: enabled.contains(featureModules[i].key),
                    onChanged: (value) => ref
                        .read(featureConfigProvider.notifier)
                        .setEnabled(featureModules[i].key, value),
                    contentPadding: EdgeInsets.zero,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
