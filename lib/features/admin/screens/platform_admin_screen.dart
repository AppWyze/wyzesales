import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/app_providers.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/formatters.dart';
import '../../../data/models/pricing_plan.dart';
import '../../../shared/utils/responsive.dart';
import '../../../shared/widgets/app_shell.dart';

/// Clients / Licenses / Pricing — the cross-tenant screen only an
/// is_platform_admin account can reach (schema/008's RLS policies enforce
/// this at the database regardless of what this gate shows; see this
/// project's usual pattern of the screen-level check being the UX and the
/// RLS policy being the real enforcement, same as BudgetsScreen).
///
/// Restyled 2026-08-25 to match SeaWyze's actual live Platform Admin screen
/// (Craig's screenshots — "I want wyzesales to look and feel the same as
/// seawyze"): a nested left-nav *inside* the screen body (not a TabBar),
/// grouped OVERVIEW/CONFIGURATION section labels, a small identity pill, a
/// stat-card row, `_Card`-wrapped sections with an uppercase title and a
/// top-right action button, and custom `Container`-built table rows with
/// coloured status badges in place of DataTable. Same three tabs as before
/// (Clients/Licenses/Pricing) and the same functional logic underneath —
/// this is a presentational rebuild only. WyzeSales has no Notifications
/// tab (a separate SeaWyze-only feature) and no vessel-shaped fields
/// anywhere, since a WyzeSales client is users only.
class PlatformAdminScreen extends ConsumerStatefulWidget {
  const PlatformAdminScreen({super.key});

  @override
  ConsumerState<PlatformAdminScreen> createState() => _PlatformAdminScreenState();
}

class _PlatformAdminScreenState extends ConsumerState<PlatformAdminScreen> {
  int _selectedNav = 0;

  final _navItems = const [
    _AdminNavItem(icon: Icons.business_outlined, label: 'Clients'),
    _AdminNavItem(icon: Icons.verified_outlined, label: 'Licenses'),
    _AdminNavItem(icon: Icons.sell_outlined, label: 'Pricing'),
  ];

  @override
  Widget build(BuildContext context) {
    final profileAsync = ref.watch(sessionProvider);

    if (profileAsync.isLoading) {
      return const AppShell(
        title: 'Platform Admin',
        currentRoute: '/admin',
        showGlobalFilters: false,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final isPlatformAdmin = profileAsync.value?.isPlatformAdmin ?? false;
    if (!isPlatformAdmin) {
      final isDark = Theme.of(context).brightness == Brightness.dark;
      return AppShell(
        title: 'Platform Admin',
        currentRoute: '/admin',
        showGlobalFilters: false,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.lock_outline,
                  size: 48,
                  color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
                ),
                const SizedBox(height: 12),
                Text(
                  "You don't have access to this page.",
                  style: TextStyle(
                    fontSize: 14,
                    color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      );
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final width = MediaQuery.of(context).size.width;
    final isMobile = width < 600;

    if (isMobile) {
      return AppShell(
        title: 'Platform Admin',
        currentRoute: '/admin',
        showGlobalFilters: false,
        body: Column(
          children: [
            Container(
              color: isDark ? AppColors.darkSurface : AppColors.lightSurface,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _mobileNavItem(0, 'Clients', isDark),
                    _mobileNavItem(1, 'Licenses', isDark),
                    _mobileNavItem(2, 'Pricing', isDark),
                  ],
                ),
              ),
            ),
            Expanded(child: _buildContent(isDark)),
          ],
        ),
      );
    }

    return AppShell(
      title: 'Platform Admin',
      currentRoute: '/admin',
        showGlobalFilters: false,
      body: Row(
        children: [
          // Nested left nav — this is separate from AppShell's own
          // app-level sidebar; it only governs the three tabs within this
          // screen, same relationship SeaWyze's inner nav has to its own
          // outer sidebar.
          Container(
            width: 200,
            color: isDark ? AppColors.darkSurface : AppColors.lightSurface,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        color: isDark ? const Color(0x0FFFFFFF) : const Color(0x0F000000),
                      ),
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: AppColors.negative.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: const Text(
                          'Platform admin only',
                          style: TextStyle(fontSize: 10, color: AppColors.negative, fontWeight: FontWeight.w500),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                _navSection('Overview', isDark),
                _navItem(0, isDark),
                _navItem(1, isDark),
                _navSection('Configuration', isDark),
                _navItem(2, isDark),
              ],
            ),
          ),
          Expanded(child: _buildContent(isDark)),
        ],
      ),
    );
  }

  Widget _mobileNavItem(int index, String label, bool isDark) {
    final isActive = _selectedNav == index;
    return GestureDetector(
      onTap: () => setState(() => _selectedNav = index),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: isActive ? AppColors.teal : Colors.transparent, width: 2),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
            color: isActive
                ? AppColors.teal
                : isDark
                    ? AppColors.darkTextSecondary
                    : AppColors.lightTextSecondary,
          ),
        ),
      ),
    );
  }

  Widget _navSection(String label, bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w500,
          color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
          letterSpacing: 0.6,
        ),
      ),
    );
  }

  Widget _navItem(int index, bool isDark) {
    final isActive = _selectedNav == index;
    final item = _navItems[index];
    return GestureDetector(
      onTap: () => setState(() => _selectedNav = index),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: isActive ? AppColors.teal.withValues(alpha: 0.08) : Colors.transparent,
          borderRadius: BorderRadius.circular(7),
          border: isActive ? Border.all(color: AppColors.teal.withValues(alpha: 0.2)) : null,
        ),
        child: Row(
          children: [
            Icon(
              item.icon,
              size: 15,
              color: isActive
                  ? AppColors.teal
                  : isDark
                      ? AppColors.darkTextSecondary
                      : AppColors.lightTextSecondary,
            ),
            const SizedBox(width: 8),
            Text(
              item.label,
              style: TextStyle(
                fontSize: 12,
                color: isActive
                    ? AppColors.teal
                    : isDark
                        ? AppColors.darkText
                        : AppColors.lightText,
                fontWeight: isActive ? FontWeight.w500 : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(bool isDark) {
    switch (_selectedNav) {
      case 0:
        return _ClientsTab(isDark: isDark);
      case 1:
        return _LicensesTab(isDark: isDark);
      case 2:
        return _PricingTab(isDark: isDark);
      default:
        return const SizedBox();
    }
  }
}

// ── Clients tab ─────────────────────────────────────────────────────────

class _ClientsTab extends ConsumerStatefulWidget {
  final bool isDark;
  const _ClientsTab({required this.isDark});

  @override
  ConsumerState<_ClientsTab> createState() => _ClientsTabState();
}

class _ClientsTabState extends ConsumerState<_ClientsTab> {
  late Future<List<Map<String, dynamic>>> _future;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _future = ref.read(platformAdminRepositoryProvider).fetchClientsWithLicense();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: FutureBuilder<List<Map<String, dynamic>>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Padding(
              padding: EdgeInsets.all(40),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          }
          final clients = snapshot.data ?? const [];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildStats(clients, isDark),
              const SizedBox(height: 16),
              _Card(
                title: 'Clients',
                isDark: isDark,
                action: _PrimaryBtn(
                  label: 'Add client',
                  icon: Icons.add,
                  onTap: () async {
                    await showDialog(context: context, builder: (_) => _AddClientDialog(isDark: isDark));
                    if (mounted) setState(_reload);
                  },
                ),
                child: clients.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(20),
                        child: Center(child: Text('No clients yet')),
                      )
                    : SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: SizedBox(
                          width: 600,
                          child: Column(
                            children: [
                              _tableHeader(isDark),
                              ...clients.map((c) => _ClientRow(
                                    client: c,
                                    isDark: isDark,
                                    onSaved: () {
                                      if (mounted) setState(_reload);
                                    },
                                  )),
                            ],
                          ),
                        ),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildStats(List<Map<String, dynamic>> clients, bool isDark) {
    final active = clients.where((c) {
      final license = (c['license'] as List?)?.firstOrNull as Map<String, dynamic>?;
      if (license == null) return false;
      if (license['status'] == 'suspended') return false;
      final endDateStr = license['end_date'] as String?;
      if (endDateStr == null) return true;
      return DateTime.parse(endDateStr).isAfter(DateTime.now());
    }).length;

    final expiring = clients.where((c) {
      final license = (c['license'] as List?)?.firstOrNull as Map<String, dynamic>?;
      if (license == null) return false;
      final endDateStr = license['end_date'] as String?;
      if (endDateStr == null) return false;
      final endDate = DateTime.parse(endDateStr);
      final now = DateTime.now();
      return endDate.isAfter(now) && endDate.isBefore(now.add(const Duration(days: 30)));
    }).length;

    final annualRecurring = clients.fold<num>(0, (total, c) {
      final license = (c['license'] as List?)?.firstOrNull as Map<String, dynamic>?;
      return total + ((license?['annual_price'] as num?) ?? 0);
    });

    return Row(
      children: [
        _StatCard(value: '${clients.length}', label: 'Total clients', isDark: isDark),
        const SizedBox(width: 12),
        _StatCard(value: '$active', label: 'Active licenses', isDark: isDark, color: AppColors.positive),
        const SizedBox(width: 12),
        _StatCard(
          value: '$expiring',
          label: 'Expiring in 30 days',
          isDark: isDark,
          color: expiring > 0 ? AppColors.caution : null,
        ),
        const SizedBox(width: 12),
        _StatCard(value: formatRand(annualRecurring), label: 'Annual recurring', isDark: isDark, color: AppColors.teal),
      ],
    );
  }

  Widget _tableHeader(bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: isDark ? AppColors.navyMid : const Color(0xFFF8FAFC),
        border: Border(
          bottom: BorderSide(color: isDark ? const Color(0x0AFFFFFF) : const Color(0x0A000000)),
        ),
      ),
      child: const Row(
        children: [
          Expanded(child: _HeaderCell('Client')),
          SizedBox(width: 100, child: _HeaderCell('Plan')),
          SizedBox(width: 80, child: _HeaderCell('Users')),
          SizedBox(width: 100, child: _HeaderCell('License')),
          SizedBox(width: 40, child: _HeaderCell('')),
        ],
      ),
    );
  }
}

class _ClientRow extends StatelessWidget {
  final Map<String, dynamic> client;
  final bool isDark;
  final VoidCallback onSaved;
  const _ClientRow({required this.client, required this.isDark, required this.onSaved});

  @override
  Widget build(BuildContext context) {
    final license = (client['license'] as List?)?.firstOrNull as Map<String, dynamic>?;
    final plan = license?['pricing_plan'] as Map<String, dynamic>?;
    final maxUsers = license?['max_users'] ?? 5;
    final status = license?['status'] as String? ?? 'active';
    final endDateStr = license?['end_date'] as String?;
    final endDate = endDateStr != null ? DateTime.parse(endDateStr) : null;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: isDark ? const Color(0x0AFFFFFF) : const Color(0x0A000000)),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  client['name'] as String? ?? '',
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: isDark ? AppColors.darkText : AppColors.lightText,
                  ),
                ),
                Text(
                  client['code'] as String? ?? '',
                  style: TextStyle(
                    fontSize: 10,
                    color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            width: 100,
            child: Text(
              plan?['name'] as String? ?? '—',
              style: TextStyle(
                fontSize: 11,
                color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
              ),
            ),
          ),
          SizedBox(
            width: 80,
            child: Text(
              '$maxUsers',
              style: TextStyle(
                fontSize: 11,
                color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
              ),
            ),
          ),
          SizedBox(
            width: 100,
            child: license == null
                ? Text(
                    'No license',
                    style: TextStyle(
                      fontSize: 11,
                      color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
                    ),
                  )
                : _LicenseBadge(status: status, endDate: endDate),
          ),
          SizedBox(
            width: 40,
            child: _IconBtn(
              icon: Icons.edit_outlined,
              isDark: isDark,
              onTap: () async {
                await showDialog(
                  context: context,
                  builder: (_) => _EditClientDialog(client: client, isDark: isDark),
                );
                onSaved();
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Platform Admin's client edit dialog — deliberately small (3 fields), same
/// scope as SeaWyze's own Platform Admin `_EditCompanyDialog`
/// (platform_admin_screen.dart:1766-1869 in that codebase): name, contact
/// email, contact number, updated with a direct `updateClient` call. This is
/// NOT the place for the full address/contact field set Craig also asked
/// for — that's Settings > Company's `_EditCompanyDialog`, which a client's
/// own adminuser reaches, and which exposes every column schema/016 added.
/// Platform Admin keeps the quick 3-field version because that's what an
/// operator provisioning/adjusting a client from the admin console actually
/// needs day to day; the full profile belongs to the client themselves.
class _EditClientDialog extends ConsumerStatefulWidget {
  const _EditClientDialog({required this.client, required this.isDark});

  final Map<String, dynamic> client;
  final bool isDark;

  @override
  ConsumerState<_EditClientDialog> createState() => _EditClientDialogState();
}

class _EditClientDialogState extends ConsumerState<_EditClientDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _emailController;
  late final TextEditingController _phoneController;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.client['name'] as String? ?? '');
    _emailController = TextEditingController(text: widget.client['contact_email'] as String? ?? '');
    _phoneController = TextEditingController(text: widget.client['contact_number'] as String? ?? '');
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Client name is required.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(platformAdminRepositoryProvider).updateClient(widget.client['id'] as String, {
        'name': name,
        'contact_email': _emailController.text.trim().isEmpty ? null : _emailController.text.trim(),
        'contact_number': _phoneController.text.trim().isEmpty ? null : _phoneController.text.trim(),
      });
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    return Dialog(
      backgroundColor: isDark ? AppColors.darkSurface : AppColors.lightSurface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      insetPadding: dialogInsetPadding,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 420, maxHeight: dialogMaxHeight(context, 420)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _dialogHeader('Edit client', isDark),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    _tf('Client name', _nameController, isDark),
                    const SizedBox(height: 10),
                    _tf('Contact email', _emailController, isDark, keyboardType: TextInputType.emailAddress),
                    const SizedBox(height: 10),
                    _tf('Contact number', _phoneController, isDark, keyboardType: TextInputType.phone),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(_error!, style: const TextStyle(fontSize: 12, color: AppColors.negative)),
                    ],
                  ],
                ),
              ),
            ),
            _dialogFooter(isDark, _saving, _save),
          ],
        ),
      ),
    );
  }
}

// ── Licenses tab ─────────────────────────────────────────────────────────

class _LicensesTab extends ConsumerStatefulWidget {
  final bool isDark;
  const _LicensesTab({required this.isDark});

  @override
  ConsumerState<_LicensesTab> createState() => _LicensesTabState();
}

class _LicensesTabState extends ConsumerState<_LicensesTab> {
  late Future<List<Map<String, dynamic>>> _future;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _future = ref.read(platformAdminRepositoryProvider).fetchClientsWithLicense();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: _Card(
        title: 'Licenses',
        isDark: isDark,
        child: FutureBuilder<List<Map<String, dynamic>>>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Padding(
                padding: EdgeInsets.all(40),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snapshot.hasError) {
              return Center(child: Text('Error: ${snapshot.error}'));
            }
            final clients = snapshot.data ?? const [];
            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: 660,
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: isDark ? AppColors.navyMid : const Color(0xFFF8FAFC),
                        border: Border(
                          bottom: BorderSide(color: isDark ? const Color(0x0AFFFFFF) : const Color(0x0A000000)),
                        ),
                      ),
                      child: const Row(
                        children: [
                          Expanded(child: _HeaderCell('Client')),
                          SizedBox(width: 70, child: _HeaderCell('Users')),
                          SizedBox(width: 80, child: _HeaderCell('Discount')),
                          SizedBox(width: 110, child: _HeaderCell('Annual price')),
                          SizedBox(width: 100, child: _HeaderCell('Expiry')),
                          SizedBox(width: 90, child: _HeaderCell('Status')),
                          SizedBox(width: 40, child: _HeaderCell('')),
                        ],
                      ),
                    ),
                    for (final c in clients)
                      if ((c['license'] as List?)?.firstOrNull != null)
                        _LicenseRow(
                          clientName: c['name'] as String? ?? '',
                          license: (c['license'] as List).first as Map<String, dynamic>,
                          isDark: isDark,
                          onSaved: () {
                            if (mounted) setState(_reload);
                          },
                        ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _LicenseRow extends StatelessWidget {
  final String clientName;
  final Map<String, dynamic> license;
  final bool isDark;
  final VoidCallback onSaved;
  const _LicenseRow({required this.clientName, required this.license, required this.isDark, required this.onSaved});

  @override
  Widget build(BuildContext context) {
    final endDateStr = license['end_date'] as String?;
    final endDate = endDateStr != null ? DateTime.parse(endDateStr) : null;
    final status = license['status'] as String? ?? 'active';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: isDark ? const Color(0x0AFFFFFF) : const Color(0x0A000000)),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              clientName,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: isDark ? AppColors.darkText : AppColors.lightText,
              ),
            ),
          ),
          SizedBox(width: 70, child: Text('${license['max_users'] ?? 5}', style: _bodyStyle(isDark))),
          SizedBox(width: 80, child: Text('${license['discount_percent'] ?? 0}%', style: _bodyStyle(isDark))),
          SizedBox(width: 110, child: Text(formatRand(license['annual_price'] as num?), style: _bodyStyle(isDark))),
          SizedBox(width: 100, child: Text(endDate != null ? _formatDate(endDate) : '—', style: _bodyStyle(isDark))),
          SizedBox(width: 90, child: _LicenseBadge(status: status, endDate: endDate)),
          SizedBox(
            width: 40,
            child: _IconBtn(
              icon: Icons.edit_outlined,
              isDark: isDark,
              onTap: () async {
                await showDialog(
                  context: context,
                  builder: (_) => _EditLicenseDialog(clientName: clientName, license: license, isDark: isDark),
                );
                onSaved();
              },
            ),
          ),
        ],
      ),
    );
  }

  TextStyle _bodyStyle(bool isDark) {
    return TextStyle(fontSize: 11, color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary);
  }

  String _formatDate(DateTime date) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${date.day} ${months[date.month - 1]} ${date.year}';
  }
}

class _EditLicenseDialog extends ConsumerStatefulWidget {
  const _EditLicenseDialog({required this.clientName, required this.license, required this.isDark});

  final String clientName;
  final Map<String, dynamic> license;
  final bool isDark;

  @override
  ConsumerState<_EditLicenseDialog> createState() => _EditLicenseDialogState();
}

class _EditLicenseDialogState extends ConsumerState<_EditLicenseDialog> {
  late final TextEditingController _maxUsersController;
  late final TextEditingController _discountController;
  late String _status;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _maxUsersController = TextEditingController(text: '${widget.license['max_users']}');
    _discountController = TextEditingController(text: '${widget.license['discount_percent'] ?? 0}');
    _status = widget.license['status'] as String? ?? 'active';
  }

  @override
  void dispose() {
    _maxUsersController.dispose();
    _discountController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final maxUsers = int.tryParse(_maxUsersController.text) ?? widget.license['max_users'] as int;
      final discountPercent = num.tryParse(_discountController.text) ?? 0;
      final data = <String, dynamic>{
        'max_users': maxUsers,
        'discount_percent': discountPercent,
        'status': _status,
      };
      // Recalculate annual_price on every save (Craig, 2026-08-28: "Licenses:
      // Annual price needs to be recalculated on SAVE") — this dialog never
      // showed/edited annual_price as its own field, so the stored column
      // was previously left untouched by every save, going stale the moment
      // max_users or the discount changed. `pricing_plan` comes pre-joined
      // on `widget.license` (see fetchClientsWithLicense); a license with no
      // plan linked has nothing to recompute from, so its stored
      // annual_price is left as-is rather than guessed at.
      final planMap = widget.license['pricing_plan'] as Map<String, dynamic>?;
      if (planMap != null) {
        data['annual_price'] = PricingPlan.fromMap(planMap).annualPriceForSeats(maxUsers, discountPercent);
      }
      await ref.read(platformAdminRepositoryProvider).updateLicense(widget.license['id'] as String, data);
      // Bare `mounted`, not `context.mounted` — State.context, no shadowing.
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    return Dialog(
      backgroundColor: isDark ? AppColors.darkSurface : AppColors.lightSurface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      insetPadding: dialogInsetPadding,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 420, maxHeight: dialogMaxHeight(context, 420)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _dialogHeader('Edit license — ${widget.clientName}', isDark),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: _PriceField(
                            label: 'Max users',
                            controller: _maxUsersController,
                            isDark: isDark,
                            isNumber: true,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _PriceField(
                            label: 'Discount %',
                            controller: _discountController,
                            isDark: isDark,
                            isNumber: true,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    _statusDropdown(isDark),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(_error!, style: const TextStyle(fontSize: 12, color: AppColors.negative)),
                    ],
                  ],
                ),
              ),
            ),
            _dialogFooter(isDark, _saving, _save),
          ],
        ),
      ),
    );
  }

  Widget _statusDropdown(bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Status',
          style: TextStyle(fontSize: 11, color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary),
        ),
        const SizedBox(height: 4),
        DropdownButtonFormField<String>(
          initialValue: _status,
          style: TextStyle(fontSize: 13, color: isDark ? AppColors.darkText : AppColors.lightText),
          decoration: InputDecoration(
            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            isDense: true,
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: BorderSide(color: isDark ? const Color(0x1FFFFFFF) : const Color(0x1F000000)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: const BorderSide(color: AppColors.teal),
            ),
          ),
          items: const [
            DropdownMenuItem(value: 'active', child: Text('Active')),
            DropdownMenuItem(value: 'expired', child: Text('Expired')),
            DropdownMenuItem(value: 'suspended', child: Text('Suspended')),
          ],
          onChanged: (v) => setState(() => _status = v ?? 'active'),
        ),
      ],
    );
  }
}

// ── Pricing tab ──────────────────────────────────────────────────────────

class _PricingTab extends ConsumerStatefulWidget {
  final bool isDark;
  const _PricingTab({required this.isDark});

  @override
  ConsumerState<_PricingTab> createState() => _PricingTabState();
}

class _PricingTabState extends ConsumerState<_PricingTab> {
  late Future<List<PricingPlan>> _future;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _future = ref.read(platformAdminRepositoryProvider).fetchPricingPlans();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: _Card(
        title: 'Pricing plans',
        isDark: isDark,
        action: _PrimaryBtn(
          label: 'Add plan',
          icon: Icons.add,
          onTap: () async {
            await showDialog(context: context, builder: (_) => _EditPlanDialog(plan: null, isDark: isDark));
            if (mounted) setState(_reload);
          },
        ),
        child: FutureBuilder<List<PricingPlan>>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Padding(
                padding: EdgeInsets.all(40),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snapshot.hasError) {
              return Center(child: Text('Error: ${snapshot.error}'));
            }
            final plans = snapshot.data ?? const [];
            if (plans.isEmpty) {
              return const Padding(
                padding: EdgeInsets.all(20),
                child: Center(child: Text('No pricing plans yet')),
              );
            }
            return Column(
              children: [
                for (final plan in plans)
                  _PlanRow(
                    plan: plan,
                    isDark: isDark,
                    onSaved: () {
                      if (mounted) setState(_reload);
                    },
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _PlanRow extends StatelessWidget {
  final PricingPlan plan;
  final bool isDark;
  final VoidCallback onSaved;
  const _PlanRow({required this.plan, required this.isDark, required this.onSaved});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: isDark ? const Color(0x0AFFFFFF) : const Color(0x0A000000)),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  plan.name,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: isDark ? AppColors.darkText : AppColors.lightText,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${formatRand(plan.basePrice)}/mo base (${plan.baseUsers} users included) · '
                  '${formatRand(plan.pricePerAdditionalUser)}/mo per additional user',
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
                  ),
                ),
              ],
            ),
          ),
          if (!plan.isActive) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: AppColors.caution.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(5),
              ),
              child: const Text(
                'Inactive',
                style: TextStyle(fontSize: 10, color: AppColors.caution, fontWeight: FontWeight.w500),
              ),
            ),
            const SizedBox(width: 8),
          ],
          _IconBtn(
            icon: Icons.edit_outlined,
            isDark: isDark,
            onTap: () async {
              await showDialog(context: context, builder: (_) => _EditPlanDialog(plan: plan, isDark: isDark));
              onSaved();
            },
          ),
        ],
      ),
    );
  }
}

class _EditPlanDialog extends ConsumerStatefulWidget {
  const _EditPlanDialog({required this.plan, required this.isDark});
  final PricingPlan? plan;
  final bool isDark;

  @override
  ConsumerState<_EditPlanDialog> createState() => _EditPlanDialogState();
}

class _EditPlanDialogState extends ConsumerState<_EditPlanDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _basePriceController;
  late final TextEditingController _pricePerUserController;
  late final TextEditingController _baseUsersController;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final plan = widget.plan;
    _nameController = TextEditingController(text: plan?.name ?? '');
    _basePriceController = TextEditingController(text: (plan?.basePrice ?? 0).toString());
    _pricePerUserController = TextEditingController(text: (plan?.pricePerAdditionalUser ?? 0).toString());
    _baseUsersController = TextEditingController(text: (plan?.baseUsers ?? 5).toString());
  }

  @override
  void dispose() {
    _nameController.dispose();
    _basePriceController.dispose();
    _pricePerUserController.dispose();
    _baseUsersController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_nameController.text.trim().isEmpty) {
      setState(() => _error = 'Plan name is required.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final data = {
      'name': _nameController.text.trim(),
      'base_price': num.tryParse(_basePriceController.text) ?? 0,
      'price_per_additional_user': num.tryParse(_pricePerUserController.text) ?? 0,
      'base_users': int.tryParse(_baseUsersController.text) ?? 5,
    };
    try {
      final repo = ref.read(platformAdminRepositoryProvider);
      if (widget.plan == null) {
        // A brand-new plan starts with zero licenses on it — nothing to
        // cascade to yet.
        await repo.createPricingPlan(data);
      } else {
        // Recalculate every license currently on this plan (Craig,
        // 2026-08-28: "Pricing: Annual price needs to be recalculated on
        // SAVE") — a rate change here otherwise leaves every affected
        // license's stored annual_price stale until someone happens to
        // open and re-save that license individually. See
        // recalculateLicensesForPlan's own doc comment for why this is
        // unconditional (custom-discounted licenses included, not skipped).
        final updatedPlan = await repo.updatePricingPlan(widget.plan!.id, data);
        await repo.recalculateLicensesForPlan(updatedPlan);
      }
      // Bare `mounted`, not `context.mounted` — State.context, no shadowing.
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    return Dialog(
      backgroundColor: isDark ? AppColors.darkSurface : AppColors.lightSurface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      insetPadding: dialogInsetPadding,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 420, maxHeight: dialogMaxHeight(context, 440)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _dialogHeader(widget.plan == null ? 'Add pricing plan' : 'Edit pricing plan', isDark),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    _tf('Plan name', _nameController, isDark),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: _PriceField(
                            label: 'Base price (R/month)',
                            controller: _basePriceController,
                            isDark: isDark,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _PriceField(
                            label: 'Base users included',
                            controller: _baseUsersController,
                            isDark: isDark,
                            isNumber: true,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    _PriceField(
                      label: 'Price per additional user (R/month)',
                      controller: _pricePerUserController,
                      isDark: isDark,
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(_error!, style: const TextStyle(fontSize: 12, color: AppColors.negative)),
                    ],
                  ],
                ),
              ),
            ),
            _dialogFooter(isDark, _saving, _save),
          ],
        ),
      ),
    );
  }
}

// ── Add client dialog ────────────────────────────────────────────────────

class _AddClientDialog extends ConsumerStatefulWidget {
  final bool isDark;
  const _AddClientDialog({required this.isDark});

  @override
  ConsumerState<_AddClientDialog> createState() => _AddClientDialogState();
}

class _AddClientDialogState extends ConsumerState<_AddClientDialog> {
  final _codeController = TextEditingController();
  final _nameController = TextEditingController();
  final _adminNameController = TextEditingController();
  final _adminEmailController = TextEditingController();
  final _adminPasswordController = TextEditingController();
  final _supportPasswordController = TextEditingController();
  final _maxUsersController = TextEditingController(text: '5');
  final _discountController = TextEditingController(text: '0');
  String? _planId;
  bool _saving = false;
  String? _error;
  late final Future<List<PricingPlan>> _plansFuture;

  @override
  void initState() {
    super.initState();
    // Loaded once here, not via ref.watch(...) in build() — this dialog
    // calls setState() on every save attempt (_saving/_error), and a
    // ref.watch call sitting in build() would kick off a brand new
    // fetchPricingPlans() request (and flash the dropdown back to
    // "loading") on every one of those rebuilds.
    _plansFuture = ref.read(platformAdminRepositoryProvider).fetchPricingPlans();
  }

  @override
  void dispose() {
    _codeController.dispose();
    _nameController.dispose();
    _adminNameController.dispose();
    _adminEmailController.dispose();
    _adminPasswordController.dispose();
    _supportPasswordController.dispose();
    _maxUsersController.dispose();
    _discountController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_codeController.text.trim().isEmpty ||
        _nameController.text.trim().isEmpty ||
        _adminNameController.text.trim().isEmpty ||
        _adminEmailController.text.trim().isEmpty ||
        _adminPasswordController.text.trim().isEmpty ||
        _supportPasswordController.text.trim().isEmpty ||
        _planId == null) {
      setState(() => _error = 'Please fill in all required fields.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(platformAdminRepositoryProvider).createClient(
            clientCode: _codeController.text.trim(),
            clientName: _nameController.text.trim(),
            adminName: _adminNameController.text.trim(),
            adminEmail: _adminEmailController.text.trim(),
            adminPassword: _adminPasswordController.text.trim(),
            supportPassword: _supportPasswordController.text.trim(),
            planId: _planId!,
            maxUsers: int.tryParse(_maxUsersController.text) ?? 5,
            discountPercent: num.tryParse(_discountController.text) ?? 0,
          );
      // Bare `mounted`, not `context.mounted` — State.context, no shadowing.
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    return Dialog(
      backgroundColor: isDark ? AppColors.darkSurface : AppColors.lightSurface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      insetPadding: dialogInsetPadding,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 520, maxHeight: dialogMaxHeight(context, 660)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _dialogHeader('Add client', isDark),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _sectionLabel('Client details', isDark),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(child: _tf('Client code (e.g. WCSA) *', _codeController, isDark)),
                        const SizedBox(width: 10),
                        Expanded(child: _tf('Client name *', _nameController, isDark)),
                      ],
                    ),
                    const SizedBox(height: 16),
                    _sectionLabel('First adminuser', isDark),
                    const SizedBox(height: 8),
                    _tf('Full name *', _adminNameController, isDark),
                    const SizedBox(height: 10),
                    _tf('Email address *', _adminEmailController, isDark, keyboardType: TextInputType.emailAddress),
                    const SizedBox(height: 10),
                    _tf('Password *', _adminPasswordController, isDark, obscure: true),
                    const SizedBox(height: 16),
                    _sectionLabel('WyzeSales support login', isDark),
                    const SizedBox(height: 4),
                    Text(
                      'A support+<code>@wyzesales.com platform admin account will be '
                      'created automatically for this client. It does not consume a '
                      'licensed user seat.',
                      style: TextStyle(
                        fontSize: 11,
                        color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    _tf('Support account password *', _supportPasswordController, isDark, obscure: true),
                    const SizedBox(height: 16),
                    _sectionLabel('License', isDark),
                    const SizedBox(height: 8),
                    _planDropdown(isDark),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: _PriceField(
                            label: 'Max users',
                            controller: _maxUsersController,
                            isDark: isDark,
                            isNumber: true,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _PriceField(
                            label: 'Discount %',
                            controller: _discountController,
                            isDark: isDark,
                            isNumber: true,
                          ),
                        ),
                      ],
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(_error!, style: const TextStyle(fontSize: 12, color: AppColors.negative)),
                    ],
                  ],
                ),
              ),
            ),
            _dialogFooter(isDark, _saving, _save),
          ],
        ),
      ),
    );
  }

  Widget _planDropdown(bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Pricing plan *',
          style: TextStyle(fontSize: 11, color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary),
        ),
        const SizedBox(height: 4),
        FutureBuilder<List<PricingPlan>>(
          future: _plansFuture,
          builder: (context, snapshot) {
            final plans = snapshot.data ?? const <PricingPlan>[];
            return DropdownButtonFormField<String>(
              initialValue: _planId,
              style: TextStyle(fontSize: 13, color: isDark ? AppColors.darkText : AppColors.lightText),
              decoration: InputDecoration(
                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                isDense: true,
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: BorderSide(color: isDark ? const Color(0x1FFFFFFF) : const Color(0x1F000000)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: const BorderSide(color: AppColors.teal),
                ),
              ),
              items: plans.map((p) => DropdownMenuItem(value: p.id, child: Text(p.name))).toList(),
              onChanged: (v) => setState(() => _planId = v),
            );
          },
        ),
      ],
    );
  }

  Widget _sectionLabel(String label, bool isDark) {
    return Text(
      label,
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w500,
        color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
        letterSpacing: 0.3,
      ),
    );
  }
}

// ── Shared widgets ───────────────────────────────────────────────────────

class _Card extends StatelessWidget {
  final String title;
  final bool isDark;
  final Widget child;
  final Widget? action;

  const _Card({required this.title, required this.isDark, required this.child, this.action});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkSurface : AppColors.lightSurface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: isDark ? const Color(0x0FFFFFFF) : const Color(0x0F000000)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: isDark ? const Color(0x0FFFFFFF) : const Color(0x0F000000)),
              ),
            ),
            child: Row(
              children: [
                Text(
                  title.toUpperCase(),
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                    color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
                    letterSpacing: 0.4,
                  ),
                ),
                const Spacer(),
                if (action case final Widget a) a,
              ],
            ),
          ),
          child,
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String value;
  final String label;
  final bool isDark;
  final Color? color;

  const _StatCard({required this.value, required this.label, required this.isDark, this.color});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: isDark ? AppColors.darkSurface : AppColors.lightSurface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: isDark ? const Color(0x0FFFFFFF) : const Color(0x0F000000)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              value,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w600,
                color: color ?? (isDark ? AppColors.darkText : AppColors.lightText),
              ),
            ),
            const SizedBox(height: 3),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LicenseBadge extends StatelessWidget {
  final String status;
  final DateTime? endDate;

  const _LicenseBadge({required this.status, required this.endDate});

  @override
  Widget build(BuildContext context) {
    Color color;
    String label;
    final now = DateTime.now();
    if (status == 'suspended') {
      color = AppColors.caution;
      label = 'Suspended';
    } else if (endDate != null && endDate!.isBefore(now)) {
      color = AppColors.negative;
      label = 'Expired';
    } else if (endDate != null && endDate!.isBefore(now.add(const Duration(days: 30)))) {
      color = AppColors.caution;
      label = 'Expiring';
    } else {
      color = AppColors.positive;
      label = 'Active';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(5)),
      child: Text(label, style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w500)),
    );
  }
}

class _HeaderCell extends StatelessWidget {
  final String text;
  const _HeaderCell(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w500, color: AppColors.lightTextSecondary, letterSpacing: 0.4),
    );
  }
}

class _PriceField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final bool isDark;
  final bool isNumber;

  const _PriceField({required this.label, required this.controller, required this.isDark, this.isNumber = false});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w500,
            color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
          ),
        ),
        const SizedBox(height: 4),
        TextFormField(
          controller: controller,
          keyboardType: isNumber ? TextInputType.number : const TextInputType.numberWithOptions(decimal: true),
          style: TextStyle(fontSize: 13, color: isDark ? AppColors.darkText : AppColors.lightText),
          decoration: InputDecoration(
            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            isDense: true,
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: BorderSide(color: isDark ? const Color(0x1FFFFFFF) : const Color(0x1F000000)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: const BorderSide(color: AppColors.teal),
            ),
          ),
        ),
      ],
    );
  }
}

class _PrimaryBtn extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onTap;

  const _PrimaryBtn({required this.label, required this.icon, this.onTap});

  @override
  Widget build(BuildContext context) {
    // onAccent only while amber-filled — the disabled fill (navyMid) is dark,
    // so white still reads fine there (SAMTRA palette rebrand, 2026-08-26).
    final fg = onTap != null ? AppColors.onAccent : Colors.white;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: onTap != null ? AppColors.teal : AppColors.navyMid,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: fg),
            const SizedBox(width: 5),
            Text(label, style: TextStyle(fontSize: 11, color: fg)),
          ],
        ),
      ),
    );
  }
}

class _IconBtn extends StatelessWidget {
  final IconData icon;
  final bool isDark;
  final VoidCallback onTap;

  const _IconBtn({required this.icon, required this.isDark, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: isDark ? AppColors.navyMid : AppColors.lightBackground,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: isDark ? const Color(0x1FFFFFFF) : const Color(0x1F000000)),
        ),
        child: Icon(icon, size: 13, color: isDark ? AppColors.darkText : AppColors.lightText),
      ),
    );
  }
}

class _AdminNavItem {
  final IconData icon;
  final String label;
  const _AdminNavItem({required this.icon, required this.label});
}

// ── Dialog helpers ───────────────────────────────────────────────────────

Widget _dialogHeader(String title, bool isDark) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
    decoration: BoxDecoration(
      border: Border(
        bottom: BorderSide(color: isDark ? const Color(0x0FFFFFFF) : const Color(0x0F000000)),
      ),
    ),
    child: Row(
      children: [
        Text(
          title,
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: isDark ? AppColors.darkText : AppColors.lightText),
        ),
      ],
    ),
  );
}

Widget _dialogFooter(bool isDark, bool isLoading, VoidCallback onSave) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
    decoration: BoxDecoration(
      border: Border(
        top: BorderSide(color: isDark ? const Color(0x0FFFFFFF) : const Color(0x0F000000)),
      ),
    ),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        SizedBox(
          height: 34,
          child: ElevatedButton(
            onPressed: isLoading ? null : onSave,
            child: isLoading
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Text('Save'),
          ),
        ),
      ],
    ),
  );
}

Widget _tf(
  String label,
  TextEditingController controller,
  bool isDark, {
  TextInputType? keyboardType,
  bool obscure = false,
}) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: TextStyle(fontSize: 11, color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary),
      ),
      const SizedBox(height: 4),
      TextFormField(
        controller: controller,
        keyboardType: keyboardType,
        obscureText: obscure,
        style: TextStyle(fontSize: 13, color: isDark ? AppColors.darkText : AppColors.lightText),
        decoration: InputDecoration(
          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          isDense: true,
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: BorderSide(color: isDark ? const Color(0x1FFFFFFF) : const Color(0x1F000000)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(color: AppColors.teal),
          ),
        ),
      ),
    ],
  );
}
