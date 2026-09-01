import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/app_providers.dart';
import '../../../core/constants/fiscal.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/formatters.dart';
import '../../../data/models/client.dart';
import '../../../data/models/license.dart';
import '../../../data/models/profile.dart';
import '../../../shared/utils/responsive.dart';
import '../../../shared/widgets/app_shell.dart';

/// Company / Users / License — every client's own adminuser-gated Settings
/// area (schema/008's profiles_adminuser_manage_own_client and related RLS
/// policies are the real enforcement, same as the rest of this project's
/// admin-only screens; this gate is just the UX).
///
/// Restyled 2026-08-25 to match SeaWyze's actual live Settings screen, same
/// pass as platform_admin_screen.dart (Craig: "I want wyzesales to look and
/// feel the same as seawyze"): a nested left-nav *inside* the screen body
/// (not a TabBar) under a single "Account" section — SeaWyze also groups a
/// "Fleet" section with a Vessels tab, which has no WyzeSales equivalent (a
/// client here is users only) — plus `_card`-wrapped sections, boxed
/// info-rows, stat tiles with progress bars, and badge-driven user rows in
/// place of plain `ListTile`s. Same three tabs, same functional logic
/// underneath (same repository calls, same seat-limit/discount handling) —
/// this is a presentational rebuild only.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  int _selectedNav = 0;

  @override
  Widget build(BuildContext context) {
    final profileAsync = ref.watch(sessionProvider);

    if (profileAsync.isLoading) {
      return const AppShell(
        title: 'Settings',
        currentRoute: '/settings',
        showGlobalFilters: false,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final canManage = profileAsync.value?.canManageUsers ?? false;
    if (!canManage) {
      final isDark = Theme.of(context).brightness == Brightness.dark;
      return AppShell(
        title: 'Settings',
        currentRoute: '/settings',
        showGlobalFilters: false,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.lock_outline, size: 48, color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary),
                const SizedBox(height: 12),
                Text(
                  'Settings are only visible to Admin accounts.',
                  style: TextStyle(fontSize: 14, color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      );
    }

    final clientId = profileAsync.value!.clientId;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final width = MediaQuery.of(context).size.width;
    final isMobile = width < 600;

    if (isMobile) {
      return AppShell(
        title: 'Settings',
        currentRoute: '/settings',
        showGlobalFilters: false,
        body: Column(
          children: [
            Container(
              color: isDark ? AppColors.darkSurface : AppColors.lightSurface,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _mobileNavItem(0, 'Company', isDark),
                    _mobileNavItem(1, 'Users', isDark),
                    _mobileNavItem(2, 'License', isDark),
                  ],
                ),
              ),
            ),
            Expanded(child: _buildContent(clientId, isDark)),
          ],
        ),
      );
    }

    return AppShell(
      title: 'Settings',
      currentRoute: '/settings',
        showGlobalFilters: false,
      body: Row(
        children: [
          Container(
            width: 220,
            decoration: BoxDecoration(
              color: isDark ? AppColors.darkSurface : AppColors.lightSurface,
              border: Border(
                right: BorderSide(color: isDark ? const Color(0x0FFFFFFF) : const Color(0x0F000000)),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 4),
                _navSection('Account', isDark),
                _navItem(0, Icons.business_outlined, 'Company', isDark),
                _navItem(1, Icons.people_outlined, 'Users', isDark),
                _navItem(2, Icons.verified_outlined, 'License', isDark),
              ],
            ),
          ),
          Expanded(child: _buildContent(clientId, isDark)),
        ],
      ),
    );
  }

  Widget _buildContent(String clientId, bool isDark) {
    switch (_selectedNav) {
      case 0:
        return _CompanyTab(clientId: clientId, isDark: isDark);
      case 1:
        return _UsersTab(clientId: clientId, isDark: isDark);
      case 2:
        return _LicenseTab(clientId: clientId, isDark: isDark);
      default:
        return const SizedBox();
    }
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
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 4),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          fontSize: 10,
          color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
          letterSpacing: 0.6,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  Widget _navItem(int index, IconData icon, String label, bool isDark) {
    final isActive = _selectedNav == index;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Material(
        color: isActive ? AppColors.teal.withValues(alpha: 0.08) : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => setState(() => _selectedNav = index),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 16,
                  color: isActive
                      ? AppColors.teal
                      : isDark
                          ? AppColors.darkTextSecondary
                          : AppColors.lightTextSecondary,
                ),
                const SizedBox(width: 10),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: isActive ? FontWeight.w500 : FontWeight.normal,
                    color: isActive
                        ? AppColors.teal
                        : isDark
                            ? AppColors.darkTextSecondary
                            : AppColors.lightTextSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Company tab ─────────────────────────────────────────────────────────

class _CompanyTab extends ConsumerStatefulWidget {
  const _CompanyTab({required this.clientId, required this.isDark});
  final String clientId;
  final bool isDark;

  @override
  ConsumerState<_CompanyTab> createState() => _CompanyTabState();
}

class _CompanyTabState extends ConsumerState<_CompanyTab> {
  late Future<Client?> _future;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _future = ref.read(settingsRepositoryProvider).getClient(widget.clientId);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: FutureBuilder<Client?>(
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
          final client = snapshot.data;
          if (client == null) {
            return const Padding(
              padding: EdgeInsets.all(20),
              child: Text('No client data found.'),
            );
          }
          // fiscal_year_settings is a separate table from `clients`
          // (schema/001 Section 7), read via its own provider rather than
          // folded into the Client model/_future above — see
          // fiscalYearStartMonthProvider's own doc comment.
          final startMonthAsync = ref.watch(fiscalYearStartMonthProvider);
          final historyYearsAsync = ref.watch(fiscalYearHistoryYearsProvider);
          return _card(
            title: 'Company information',
            isDark: isDark,
            action: _primaryBtn(Icons.edit_outlined, 'Edit', () => _showEdit(context, client)),
            child: _twoCol([
              _infoRow('Client name', client.name, isDark),
              _infoRow('Client code', client.code, isDark),
              _infoRow('Contact name', client.contactName ?? '—', isDark),
              _infoRow('Contact number', client.contactNumber ?? '—', isDark),
              _infoRow('Contact email', client.contactEmail ?? '—', isDark),
              _infoRow('Address line 1', client.address1 ?? '—', isDark),
              _infoRow('Address line 2', client.address2 ?? '—', isDark),
              _infoRow('Address line 3', client.address3 ?? '—', isDark),
              _infoRow('City', client.city ?? '—', isDark),
              _infoRow('Country', client.country ?? '—', isDark),
              _infoRow('Postal code', client.postalCode ?? '—', isDark),
              _infoRow('Fiscal year starts', startMonthAsync.when(
                data: (m) => fiscalStartMonthName(m),
                loading: () => '…',
                error: (_, __) => '—',
              ), isDark),
              _infoRow('Data history window', historyYearsAsync.when(
                data: (y) => '$y years',
                loading: () => '…',
                error: (_, __) => '—',
              ), isDark),
            ]),
          );
        },
      ),
    );
  }

  Future<void> _showEdit(BuildContext context, Client client) async {
    await showDialog<bool>(context: context, builder: (_) => _EditCompanyDialog(client: client, isDark: widget.isDark));
    if (mounted) setState(_reload);
  }
}

/// Settings > Company's edit dialog — the full SeaWyze-equivalent field set
/// Craig asked for ("all of the fields as per Seawyze but without the
/// Company Documents function"), reached by the client's own adminuser via
/// `updateCompanyProfile` (RLS: clients_adminuser_update, schema/008). This
/// intentionally includes address2/address3/postalCode even though SeaWyze's
/// own Settings dialog doesn't expose those either — "all of the fields as
/// per Seawyze" is read here as full CompanyModel field parity, not as
/// "replicate SeaWyze's dialog's own gaps." No Documents URL field and no
/// Company Documents card: that function was explicitly excluded. Compare
/// with Platform Admin's `_EditClientDialog`, the deliberately smaller
/// 3-field version an operator uses from the admin console.
class _EditCompanyDialog extends ConsumerStatefulWidget {
  const _EditCompanyDialog({required this.client, required this.isDark});
  final Client client;
  final bool isDark;

  @override
  ConsumerState<_EditCompanyDialog> createState() => _EditCompanyDialogState();
}

class _EditCompanyDialogState extends ConsumerState<_EditCompanyDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _contactNameController;
  late final TextEditingController _contactNumberController;
  late final TextEditingController _contactEmailController;
  late final TextEditingController _address1Controller;
  late final TextEditingController _address2Controller;
  late final TextEditingController _address3Controller;
  late final TextEditingController _cityController;
  late final TextEditingController _countryController;
  late final TextEditingController _postalCodeController;
  bool _isLoading = false;

  // fiscal_year_settings lives in its own table (schema/001 Section 7), not
  // on `clients` — so unlike every field above, this can't be seeded
  // synchronously from `widget.client`. Starts at 3 (March, today's
  // pre-feature default) and gets overwritten once the async read below
  // resolves — same fallback fiscalYearFor/fiscalMonthOrderFor use elsewhere
  // while the value is still loading, so this dialog never shows something
  // inconsistent with the rest of the app mid-load.
  int _startMonth = 3;
  // Same "external async source, not just this dialog's own initialValue"
  // situation as _startMonth right above — same fallback default (3) too,
  // matching fiscal_year_settings.history_years' own column default.
  int _historyYears = 3;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.client.name);
    _contactNameController = TextEditingController(text: widget.client.contactName ?? '');
    _contactNumberController = TextEditingController(text: widget.client.contactNumber ?? '');
    _contactEmailController = TextEditingController(text: widget.client.contactEmail ?? '');
    _address1Controller = TextEditingController(text: widget.client.address1 ?? '');
    _address2Controller = TextEditingController(text: widget.client.address2 ?? '');
    _address3Controller = TextEditingController(text: widget.client.address3 ?? '');
    _cityController = TextEditingController(text: widget.client.city ?? '');
    _countryController = TextEditingController(text: widget.client.country ?? '');
    _postalCodeController = TextEditingController(text: widget.client.postalCode ?? '');
    ref.read(fiscalYearStartMonthProvider.future).then((value) {
      if (mounted) setState(() => _startMonth = value);
    });
    ref.read(fiscalYearHistoryYearsProvider.future).then((value) {
      if (mounted) setState(() => _historyYears = value);
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    _contactNameController.dispose();
    _contactNumberController.dispose();
    _contactEmailController.dispose();
    _address1Controller.dispose();
    _address2Controller.dispose();
    _address3Controller.dispose();
    _cityController.dispose();
    _countryController.dispose();
    _postalCodeController.dispose();
    super.dispose();
  }

  String? _orNull(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();

  Future<void> _save() async {
    if (_nameController.text.trim().isEmpty) return;
    setState(() => _isLoading = true);
    try {
      await ref.read(settingsRepositoryProvider).updateCompanyProfile(widget.client.id, {
        'name': _nameController.text.trim(),
        'contact_name': _orNull(_contactNameController),
        'contact_number': _orNull(_contactNumberController),
        'contact_email': _orNull(_contactEmailController),
        'address1': _orNull(_address1Controller),
        'address2': _orNull(_address2Controller),
        'address3': _orNull(_address3Controller),
        'city': _orNull(_cityController),
        'country': _orNull(_countryController),
        'postal_code': _orNull(_postalCodeController),
      });
      // Separate table/policy from the update above (fiscal_year_settings,
      // not clients — see updateFiscalYearStartMonth's own doc comment), so
      // a separate call rather than folded into the map above.
      await ref.read(settingsRepositoryProvider).updateFiscalYearStartMonth(widget.client.id, _startMonth);
      await ref.read(settingsRepositoryProvider).updateDataHistoryYears(widget.client.id, _historyYears);
      // Every screen reading fiscalYearStartMonthProvider/
      // fiscalYearHistoryYearsProvider (fiscal.dart's
      // fiscalMonthOrderFor/fiscalYearFor/fiscalYearWindow call sites) picks
      // up the new values on its next rebuild, app-wide, rather than only
      // after a full reload.
      ref.invalidate(fiscalYearStartMonthProvider);
      ref.invalidate(fiscalYearHistoryYearsProvider);
      // Bare `mounted`, not `context.mounted` — this `context` is
      // `State.context` (no local `context` parameter shadowing it here).
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: AppColors.negative),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
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
        constraints: BoxConstraints(maxWidth: 480, maxHeight: dialogMaxHeight(context, 640)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _dialogHeader('Edit company', isDark),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    _tf('Client name *', _nameController, isDark),
                    const SizedBox(height: 10),
                    _tf('Contact name', _contactNameController, isDark),
                    const SizedBox(height: 10),
                    _tf('Contact number', _contactNumberController, isDark, keyboardType: TextInputType.phone),
                    const SizedBox(height: 10),
                    _tf('Contact email', _contactEmailController, isDark, keyboardType: TextInputType.emailAddress),
                    const SizedBox(height: 10),
                    _tf('Address line 1', _address1Controller, isDark),
                    const SizedBox(height: 10),
                    _tf('Address line 2', _address2Controller, isDark),
                    const SizedBox(height: 10),
                    _tf('Address line 3', _address3Controller, isDark),
                    const SizedBox(height: 10),
                    _tf('City', _cityController, isDark),
                    const SizedBox(height: 10),
                    _tf('Country', _countryController, isDark),
                    const SizedBox(height: 10),
                    _tf('Postal code', _postalCodeController, isDark),
                    const SizedBox(height: 10),
                    _fiscalStartMonthDropdown(isDark),
                    const SizedBox(height: 10),
                    _dataHistoryWindowDropdown(isDark),
                  ],
                ),
              ),
            ),
            _dialogFooterWithLoading(isDark, _isLoading, _save),
          ],
        ),
      ),
    );
  }

  // schema/001's fiscal_year() defaults an unset start month to March (3),
  // so 3 is always a real, valid choice here too — not just this dialog's
  // own loading-state fallback.
  Widget _fiscalStartMonthDropdown(bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Fiscal year starts',
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary),
        ),
        const SizedBox(height: 4),
        // key: ValueKey(_startMonth) — unlike _levelDropdown above,
        // _startMonth can change from an EXTERNAL source (the async load in
        // initState resolving after this widget has already built once, not
        // just from the user's own selection), and DropdownButtonFormField's
        // `initialValue` is only read the first time its internal FormField
        // state is created — a later rebuild passing a new `initialValue`
        // does NOT by itself update what's displayed. Keying on the value
        // forces a fresh internal state (and therefore a fresh read of
        // `initialValue`) every time `_startMonth` changes for any reason,
        // including the user's own pick — which is a no-op visually there,
        // since by the time it rebuilds `initialValue` already equals what
        // they just chose.
        DropdownButtonFormField<int>(
          key: ValueKey(_startMonth),
          initialValue: _startMonth,
          decoration: const InputDecoration(
            contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            isDense: true,
          ),
          style: TextStyle(fontSize: 13, color: isDark ? AppColors.darkText : AppColors.lightText),
          items: [
            for (var m = 1; m <= 12; m++) DropdownMenuItem(value: m, child: Text(fiscalStartMonthName(m))),
          ],
          onChanged: (v) => setState(() => _startMonth = v ?? 3),
        ),
      ],
    );
  }

  // schema/020's own check constraint limits this to exactly 3 or 5 — not
  // an arbitrary 1-N range like the start month above — so this offers only
  // those two choices, matching Craig's own ask ("either 3 or 5 years").
  Widget _dataHistoryWindowDropdown(bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Data history window',
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary),
        ),
        const SizedBox(height: 4),
        // key: ValueKey(_historyYears) — same DropdownButtonFormField
        // external-update quirk as the fiscal start month dropdown above,
        // see that widget's own doc comment for the full explanation.
        DropdownButtonFormField<int>(
          key: ValueKey(_historyYears),
          initialValue: _historyYears,
          decoration: const InputDecoration(
            contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            isDense: true,
          ),
          style: TextStyle(fontSize: 13, color: isDark ? AppColors.darkText : AppColors.lightText),
          items: const [
            DropdownMenuItem(value: 3, child: Text('3 years')),
            DropdownMenuItem(value: 5, child: Text('5 years')),
          ],
          onChanged: (v) => setState(() => _historyYears = v ?? 3),
        ),
      ],
    );
  }
}

// ── Users tab ────────────────────────────────────────────────────────────

class _UsersTab extends ConsumerStatefulWidget {
  const _UsersTab({required this.clientId, required this.isDark});
  final String clientId;
  final bool isDark;

  @override
  ConsumerState<_UsersTab> createState() => _UsersTabState();
}

class _UsersTabState extends ConsumerState<_UsersTab> {
  late Future<List<Profile>> _usersFuture;
  late Future<License?> _licenseFuture;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _usersFuture = ref.read(settingsRepositoryProvider).getUsers(widget.clientId);
    _licenseFuture = ref.read(settingsRepositoryProvider).getLicense(widget.clientId);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final myId = ref.watch(sessionProvider).value?.id;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: FutureBuilder<List<Profile>>(
        future: _usersFuture,
        builder: (context, usersSnapshot) {
          if (usersSnapshot.connectionState == ConnectionState.waiting) {
            return const Padding(
              padding: EdgeInsets.all(40),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          if (usersSnapshot.hasError) {
            return Center(child: Text('Error: ${usersSnapshot.error}'));
          }
          final users = usersSnapshot.data ?? const [];
          return FutureBuilder<License?>(
            future: _licenseFuture,
            builder: (context, licenseSnapshot) {
              final license = licenseSnapshot.data;
              final usedSeats = users.where((u) => u.isActive && !u.isPlatformAdmin).length;
              final atLimit = license != null && usedSeats >= license.maxUsers;
              return _card(
                title: 'Users',
                isDark: isDark,
                subtitle: license != null ? '$usedSeats of ${license.maxUsers} used' : null,
                action: _primaryBtn(
                  Icons.add,
                  'Add user',
                  atLimit
                      ? null
                      : () async {
                          await showDialog<bool>(context: context, builder: (_) => _AddUserDialog(isDark: isDark));
                          if (mounted) setState(_reload);
                        },
                ),
                child: Column(
                  children: [
                    if (atLimit)
                      _warningBanner(
                        'You have reached your user limit (${license.maxUsers} of ${license.maxUsers}). '
                        'Request a license upgrade on the License tab to add more.',
                        isDark,
                      ),
                    if (users.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(20),
                        child: Text(
                          'No users yet.',
                          style: TextStyle(color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary),
                        ),
                      )
                    else
                      Column(children: users.map((u) => _UserRow(user: u, isDark: isDark, isMe: u.id == myId, onChanged: () {
                        if (mounted) setState(_reload);
                      })).toList()),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _UserRow extends ConsumerWidget {
  const _UserRow({required this.user, required this.isDark, required this.isMe, required this.onChanged});
  final Profile user;
  final bool isDark;
  final bool isMe;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: isDark ? const Color(0x0AFFFFFF) : const Color(0x0A000000)),
        ),
      ),
      child: Row(
        children: [
          _avatar(_initialsFor(user.name), user.level, isDark),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        user.name,
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: isDark ? AppColors.darkText : AppColors.lightText,
                        ),
                      ),
                    ),
                    if (user.isPlatformAdmin) ...[
                      const SizedBox(width: 8),
                      const _Badge(label: 'Support', color: AppColors.accentPurple),
                    ],
                    if (!user.isActive) ...[
                      const SizedBox(width: 8),
                      _Badge(label: 'Inactive', color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary),
                    ],
                  ],
                ),
                Text(
                  user.email,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
                  ),
                ),
              ],
            ),
          ),
          _levelBadge(user.level),
          const SizedBox(width: 10),
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: user.isActive ? AppColors.positive : AppColors.lightTextSecondary,
              shape: BoxShape.circle,
            ),
          ),
          // Edit is available on every row, including a platform-admin/
          // "Support" account — matching SeaWyze, whose own _EditUserDialog
          // isn't row-gated at all (Craig, 2026-08-28, chose this over
          // leaving Edit hidden here too, once told SeaWyze only excludes
          // Delete for a support row, not Edit). Pause/resume and Delete
          // stay gated below: a support login needs to keep working, so
          // deactivating or removing it isn't offered from this screen.
          const SizedBox(width: 10),
          _outlineBtn(
            Icons.edit_outlined,
            '',
            isDark,
            () async {
              await showDialog<bool>(context: context, builder: (_) => _EditUserDialog(user: user, isDark: isDark));
              onChanged();
            },
          ),
          if (!user.isPlatformAdmin) ...[
            // "Send password reset" — 2026-08-31, the other half of the gap
            // flagged alongside the export buttons: "admin can't reset a
            // user's password either." Deliberately just re-sends the same
            // self-service reset email a user's own "Forgot password?" link
            // would (AuthRepository.sendPasswordResetEmail's own doc comment
            // explains why this doesn't set a password directly) — an admin
            // saves a user the trouble of finding that link themselves, but
            // never gets to see or choose their password. Hidden for a
            // platform-admin/Support row for the same reason pause/resume
            // and Delete already are: that login isn't this client's to
            // manage.
            const SizedBox(width: 6),
            Tooltip(
              message: 'Send password reset email',
              child: _outlineBtn(Icons.lock_reset, '', isDark, () => _sendPasswordReset(context, ref)),
            ),
            const SizedBox(width: 6),
            _outlineBtn(
              user.isActive ? Icons.pause_circle_outline : Icons.play_circle_outline,
              '',
              isDark,
              () async {
                final repo = ref.read(settingsRepositoryProvider);
                if (user.isActive) {
                  await repo.deactivateUser(user.id);
                } else {
                  await repo.reactivateUser(user.id);
                }
                onChanged();
              },
            ),
            if (!isMe) ...[
              const SizedBox(width: 6),
              GestureDetector(
                onTap: () => _confirmDelete(context, ref),
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: AppColors.negative.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: AppColors.negative.withValues(alpha: 0.2)),
                  ),
                  child: const Icon(Icons.delete_outline, size: 14, color: AppColors.negative),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Future<void> _sendPasswordReset(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('Send password reset', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        content: Text(
          'Send ${user.name} a password reset email at ${user.email}? Their current password keeps working until they follow the link.',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Send')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref.read(authRepositoryProvider).sendPasswordResetEmail(user.email);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Password reset email sent to ${user.email}.')),
        );
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not send the reset email. Please try again.')),
        );
      }
    }
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('Delete user', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        content: Text('Permanently delete ${user.name}? This cannot be undone.', style: const TextStyle(fontSize: 13)),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete', style: TextStyle(color: AppColors.negative, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      try {
        await ref.read(settingsRepositoryProvider).deleteUser(user.id);
        onChanged();
      } catch (e) {
        // context.mounted specifically, not the bare `mounted` (State.mounted)
        // — this is a stateless ConsumerWidget with no `mounted` of its own,
        // and flutter analyze wants the BuildContext-flavoured check tied to
        // the exact context used right after the await regardless.
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
        }
      }
    }
  }

  Widget _avatar(String initials, UserLevel level, bool isDark) {
    final isAdmin = level == UserLevel.adminuser;
    final bg = isAdmin ? AppColors.teal.withValues(alpha: 0.15) : AppColors.lightBackground;
    final fg = isAdmin ? AppColors.teal : AppColors.lightTextSecondary;
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
      child: Center(child: Text(initials, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: fg))),
    );
  }

  Widget _levelBadge(UserLevel level) {
    final isAdmin = level == UserLevel.adminuser;
    final color = isAdmin ? AppColors.teal : AppColors.lightTextSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(6)),
      child: Text(_levelLabel(level), style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w500)),
    );
  }
}

String _initialsFor(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return '?';
  final parts = trimmed.split(RegExp(r'\s+'));
  if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
  return (parts.first.substring(0, 1) + parts.last.substring(0, 1)).toUpperCase();
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(4)),
      child: Text(label, style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w600)),
    );
  }
}

String _levelLabel(UserLevel level) {
  switch (level) {
    case UserLevel.adminuser:
      return 'Admin';
    case UserLevel.reguser:
      return 'RegUser';
    case UserLevel.user:
      return 'User';
    case UserLevel.superuser:
      return 'SuperUser (legacy)';
  }
}

class _AddUserDialog extends ConsumerStatefulWidget {
  const _AddUserDialog({required this.isDark});
  final bool isDark;

  @override
  ConsumerState<_AddUserDialog> createState() => _AddUserDialogState();
}

class _AddUserDialogState extends ConsumerState<_AddUserDialog> {
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _repCodeController = TextEditingController();
  final _branchCodeController = TextEditingController();
  UserLevel _level = UserLevel.user;
  bool _isLoading = false;
  String? _error;

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _repCodeController.dispose();
    _branchCodeController.dispose();
    super.dispose();
  }

  // 2026-09-01, Craig: "If a User level is set to User and/or RegUser the
  // Rep code and Branch code fields are not optional but mandatory... Save
  // cannot happen without this in place." Both fields now drive row-level
  // security directly (schema/018) — a User/RegUser login with either left
  // blank would match nothing under the new scoped RLS policies, so this
  // isn't just a data-quality nicety, an unset code would silently make
  // every screen look empty for that person.
  bool get _repBranchRequired => _level == UserLevel.user || _level == UserLevel.reguser;

  Future<void> _save() async {
    if (_nameController.text.trim().isEmpty || _emailController.text.trim().isEmpty || _passwordController.text.trim().isEmpty) {
      setState(() => _error = 'Please fill in all required fields.');
      return;
    }
    if (_repBranchRequired && (_repCodeController.text.trim().isEmpty || _branchCodeController.text.trim().isEmpty)) {
      setState(() => _error = 'Rep code and Branch code are required for User and RegUser levels.');
      return;
    }
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      await ref.read(settingsRepositoryProvider).createUser(
            email: _emailController.text.trim(),
            password: _passwordController.text.trim(),
            name: _nameController.text.trim(),
            level: _level,
            repCode: _repCodeController.text.trim().isEmpty ? null : _repCodeController.text.trim(),
            branchCode: _branchCodeController.text.trim().isEmpty ? null : _branchCodeController.text.trim(),
          );
      // Bare `mounted`, not `context.mounted` — State.context, no shadowing.
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      // Includes the schema/008 seat-limit trigger's own message
      // ("Seat limit reached: ...") when that's what blocked it — see
      // create-user's own comment on why that's surfaced as-is.
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _isLoading = false);
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
        constraints: BoxConstraints(maxWidth: 460, maxHeight: dialogMaxHeight(context, 560)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _dialogHeader('Add user', isDark),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _tf('Full name *', _nameController, isDark),
                    const SizedBox(height: 12),
                    _tf('Email address *', _emailController, isDark, keyboardType: TextInputType.emailAddress),
                    const SizedBox(height: 12),
                    _tf('Password *', _passwordController, isDark, obscure: true),
                    const SizedBox(height: 12),
                    _levelDropdown(isDark),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(child: _tf(_repBranchRequired ? 'Rep code *' : 'Rep code (optional)', _repCodeController, isDark)),
                        const SizedBox(width: 12),
                        Expanded(child: _tf(_repBranchRequired ? 'Branch code *' : 'Branch code (optional)', _branchCodeController, isDark)),
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
            _dialogFooterWithLoading(isDark, _isLoading, _save),
          ],
        ),
      ),
    );
  }

  Widget _levelDropdown(bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Level',
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary),
        ),
        const SizedBox(height: 4),
        DropdownButtonFormField<UserLevel>(
          initialValue: _level,
          decoration: const InputDecoration(
            contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            isDense: true,
          ),
          style: TextStyle(fontSize: 13, color: isDark ? AppColors.darkText : AppColors.lightText),
          items: const [
            DropdownMenuItem(value: UserLevel.user, child: Text('User')),
            DropdownMenuItem(value: UserLevel.reguser, child: Text('RegUser')),
            DropdownMenuItem(value: UserLevel.adminuser, child: Text('Admin')),
          ],
          // setState alone is enough to flip the Rep/Branch code labels'
          // required asterisk live as Level changes — see _repBranchRequired.
          onChanged: (v) => setState(() => _level = v ?? UserLevel.user),
        ),
      ],
    );
  }
}

/// Settings > Users' edit dialog (Craig, 2026-08-28: "Requirement to Add,
/// Edit and Delete Users. Same as Seawyze" — Add and Delete already existed,
/// this is the missing Edit leg). Deliberately does NOT include an Active
/// toggle the way SeaWyze's own `_EditUserDialog` does: `_UserRow` already
/// has a dedicated pause/resume button for that (line ~628 above), so
/// duplicating it here would just be two controls doing the same thing.
/// Email and password are also left out — neither is editable in SeaWyze's
/// dialog either, and WyzeSales has no change-email/reset-password flow to
/// wire it to.
class _EditUserDialog extends ConsumerStatefulWidget {
  const _EditUserDialog({required this.user, required this.isDark});
  final Profile user;
  final bool isDark;

  @override
  ConsumerState<_EditUserDialog> createState() => _EditUserDialogState();
}

class _EditUserDialogState extends ConsumerState<_EditUserDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _contactNumberController;
  late final TextEditingController _repCodeController;
  late final TextEditingController _branchCodeController;
  late UserLevel _level;
  bool _isLoading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.user.name);
    _contactNumberController = TextEditingController(text: widget.user.contactNumber ?? '');
    _repCodeController = TextEditingController(text: widget.user.repCode ?? '');
    _branchCodeController = TextEditingController(text: widget.user.branchCode ?? '');
    _level = widget.user.level;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _contactNumberController.dispose();
    _repCodeController.dispose();
    _branchCodeController.dispose();
    super.dispose();
  }

  // See _AddUserDialogState's own copy of this getter/comment for why
  // (2026-09-01, Craig — Rep/Branch code now drive row-level security,
  // schema/018).
  bool get _repBranchRequired => _level == UserLevel.user || _level == UserLevel.reguser;

  Future<void> _save() async {
    if (_nameController.text.trim().isEmpty) {
      setState(() => _error = 'Full name is required.');
      return;
    }
    if (_repBranchRequired && (_repCodeController.text.trim().isEmpty || _branchCodeController.text.trim().isEmpty)) {
      setState(() => _error = 'Rep code and Branch code are required for User and RegUser levels.');
      return;
    }
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      await ref.read(settingsRepositoryProvider).updateUser(widget.user.id, {
        'name': _nameController.text.trim(),
        'contact_number': _contactNumberController.text.trim().isEmpty ? null : _contactNumberController.text.trim(),
        'level': _level.name,
        'rep_code': _repCodeController.text.trim().isEmpty ? null : _repCodeController.text.trim(),
        'branch_code': _branchCodeController.text.trim().isEmpty ? null : _branchCodeController.text.trim(),
      });
      // Bare `mounted`, not `context.mounted` — State.context, no shadowing.
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _isLoading = false);
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
        constraints: BoxConstraints(maxWidth: 460, maxHeight: dialogMaxHeight(context, 500)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _dialogHeader('Edit user', isDark),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _tf('Full name *', _nameController, isDark),
                    const SizedBox(height: 12),
                    _tf('Contact number', _contactNumberController, isDark, keyboardType: TextInputType.phone),
                    const SizedBox(height: 12),
                    _levelDropdown(isDark),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(child: _tf(_repBranchRequired ? 'Rep code *' : 'Rep code (optional)', _repCodeController, isDark)),
                        const SizedBox(width: 12),
                        Expanded(child: _tf(_repBranchRequired ? 'Branch code *' : 'Branch code (optional)', _branchCodeController, isDark)),
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
            _dialogFooterWithLoading(isDark, _isLoading, _save),
          ],
        ),
      ),
    );
  }

  Widget _levelDropdown(bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Level',
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary),
        ),
        const SizedBox(height: 4),
        DropdownButtonFormField<UserLevel>(
          initialValue: _level,
          decoration: const InputDecoration(
            contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            isDense: true,
          ),
          style: TextStyle(fontSize: 13, color: isDark ? AppColors.darkText : AppColors.lightText),
          items: const [
            DropdownMenuItem(value: UserLevel.user, child: Text('User')),
            DropdownMenuItem(value: UserLevel.reguser, child: Text('RegUser')),
            DropdownMenuItem(value: UserLevel.adminuser, child: Text('Admin')),
          ],
          // setState alone is enough to flip the Rep/Branch code labels'
          // required asterisk live as Level changes — see _repBranchRequired.
          onChanged: (v) => setState(() => _level = v ?? UserLevel.user),
        ),
      ],
    );
  }
}

// ── License tab ──────────────────────────────────────────────────────────

class _LicenseTab extends ConsumerStatefulWidget {
  const _LicenseTab({required this.clientId, required this.isDark});
  final String clientId;
  final bool isDark;

  @override
  ConsumerState<_LicenseTab> createState() => _LicenseTabState();
}

class _LicenseTabState extends ConsumerState<_LicenseTab> {
  late Future<License?> _licenseFuture;
  late Future<List<Profile>> _usersFuture;
  bool _requesting = false;

  @override
  void initState() {
    super.initState();
    _licenseFuture = ref.read(settingsRepositoryProvider).getLicense(widget.clientId);
    _usersFuture = ref.read(settingsRepositoryProvider).getUsers(widget.clientId);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: FutureBuilder<License?>(
        future: _licenseFuture,
        builder: (context, licSnapshot) {
          if (licSnapshot.connectionState == ConnectionState.waiting) {
            return const Padding(
              padding: EdgeInsets.all(40),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          if (licSnapshot.hasError) {
            return Center(child: Text('Error: ${licSnapshot.error}'));
          }
          final license = licSnapshot.data;
          if (license == null) {
            return const Padding(
              padding: EdgeInsets.all(20),
              child: Text('No license found for this client — contact support@wyzesales.com.'),
            );
          }
          return FutureBuilder<List<Profile>>(
            future: _usersFuture,
            builder: (context, userSnapshot) {
              final usedSeats = (userSnapshot.data ?? const <Profile>[]).where((u) => u.isActive && !u.isPlatformAdmin).length;
              return _card(
                title: 'License',
                isDark: isDark,
                badge: license.isActive ? 'Active' : 'Expired',
                badgeColor: license.isActive ? AppColors.positive : AppColors.negative,
                child: Column(
                  children: [
                    _licenseStats(license, usedSeats, isDark),
                    const SizedBox(height: 14),
                    _licenseDetails(license, isDark),
                    const SizedBox(height: 14),
                    _upgradeBox(isDark),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _licenseStats(License license, int usedSeats, bool isDark) {
    final userPct = license.maxUsers == 0 ? 0.0 : (usedSeats / license.maxUsers).clamp(0.0, 1.0);
    final daysPct = (license.daysRemaining / 365).clamp(0.0, 1.0);
    return Row(
      children: [
        Expanded(
          child: _statCard(
            '$usedSeats',
            'Users used',
            'of ${license.maxUsers} licensed',
            userPct,
            userPct >= 1.0 ? AppColors.caution : AppColors.teal,
            isDark,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _statCard(
            '${license.daysRemaining}',
            'Days remaining',
            'Expires ${_formatDate(license.endDate)}',
            daysPct,
            license.isExpiringSoon ? AppColors.negative : AppColors.positive,
            isDark,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _statCard(
            formatRand(license.annualPrice),
            'Annual price',
            license.plan?.name ?? 'Base license',
            null,
            AppColors.teal,
            isDark,
          ),
        ),
      ],
    );
  }

  Widget _licenseDetails(License license, bool isDark) {
    final plan = license.plan;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _detailRow('License start', _formatDate(license.startDate), isDark),
        _detailRow('License expiry', _formatDate(license.endDate), isDark),
        _detailRow(
          'Status',
          license.isActive ? 'Active' : 'Expired',
          isDark,
          valueColor: license.isActive ? AppColors.positive : AppColors.negative,
        ),
        if (license.discountPercent > 0) _detailRow('Discount', '${license.discountPercent}%', isDark),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isDark ? AppColors.navyMid : const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: isDark ? const Color(0x1FFFFFFF) : const Color(0x1F000000)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Pricing breakdown',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
                  letterSpacing: 0.4,
                ),
              ),
              const SizedBox(height: 10),
              if (plan != null) ...[
                _priceRow('${plan.name} base plan (${plan.baseUsers} users)', plan.basePrice * 12, isDark),
                if (license.additionalUsers > 0)
                  _priceRow(
                    '${license.additionalUsers} additional user${license.additionalUsers > 1 ? 's' : ''} × ${formatRand(plan.pricePerAdditionalUser)}/mo',
                    license.additionalUsers * plan.pricePerAdditionalUser * 12,
                    isDark,
                  ),
                const Padding(padding: EdgeInsets.symmetric(vertical: 6), child: Divider(height: 1)),
              ],
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Monthly total',
                    style: TextStyle(fontSize: 12, color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary),
                  ),
                  Text(
                    formatRand(license.discountedMonthly),
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: isDark ? AppColors.darkText : AppColors.lightText),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Annual total',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: isDark ? AppColors.darkText : AppColors.lightText),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      formatRand(license.annualPrice),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                      textAlign: TextAlign.right,
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: isDark ? AppColors.darkText : AppColors.lightText),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _upgradeBox(bool isDark) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.teal.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.teal.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(color: AppColors.teal.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
            child: const Icon(Icons.rocket_launch_outlined, size: 18, color: AppColors.teal),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Need more users?',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: isDark ? AppColors.darkText : AppColors.lightText),
                ),
                Text(
                  'Request an upgrade and we\'ll get back to you within 1 business day.',
                  style: TextStyle(fontSize: 11, color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          GestureDetector(
            onTap: _requesting ? null : _sendUpgradeRequest,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: AppColors.positive.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(7),
                border: Border.all(color: AppColors.positive.withValues(alpha: 0.3)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.arrow_outward, size: 13, color: AppColors.positive),
                  const SizedBox(width: 4),
                  Text(
                    _requesting ? 'Sending...' : 'Request upgrade',
                    style: const TextStyle(fontSize: 12, color: AppColors.positive, fontWeight: FontWeight.w500),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _sendUpgradeRequest() async {
    setState(() => _requesting = true);
    try {
      await ref.read(settingsRepositoryProvider).requestUpgrade();
      // Bare `mounted` (State's own getter), not `context.mounted` — this
      // `context` resolves to `State.context` (no local `context` parameter
      // shadowing it in this method), and flutter analyze specifically
      // wants a `State.context` use guarded by the State's `mounted`, not
      // the BuildContext-flavoured check. That BuildContext-flavoured check
      // is for a `context` that's a local variable/parameter instead (e.g.
      // a builder callback's `context`) — see the Users tab's row delete
      // flow below for that case.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Upgrade request sent to support@wyzesales.com.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _requesting = false);
    }
  }

  Widget _statCard(String value, String label, String sub, double? progress, Color color, bool isDark) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? AppColors.navyMid : const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: isDark ? AppColors.darkText : AppColors.lightText, height: 1),
          ),
          const SizedBox(height: 3),
          Text(label, style: TextStyle(fontSize: 10, color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary)),
          if (progress != null) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: progress,
                backgroundColor: isDark ? const Color(0x1FFFFFFF) : const Color(0x1F000000),
                valueColor: AlwaysStoppedAnimation<Color>(color),
                minHeight: 5,
              ),
            ),
          ],
          const SizedBox(height: 4),
          Text(sub, style: TextStyle(fontSize: 10, color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary)),
        ],
      ),
    );
  }

  Widget _priceRow(String label, num amount, bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(label, style: TextStyle(fontSize: 11, color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary)),
          ),
          Text(formatRand(amount), style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: isDark ? AppColors.darkText : AppColors.lightText)),
        ],
      ),
    );
  }

  Widget _detailRow(String label, String value, bool isDark, {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(fontSize: 12, color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary)),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              value,
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: valueColor ?? (isDark ? AppColors.darkText : AppColors.lightText),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime date) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${date.day} ${months[date.month - 1]} ${date.year}';
  }
}

// ── Shared widgets ───────────────────────────────────────────────────────

Widget _card({
  required String title,
  required bool isDark,
  required Widget child,
  Widget? action,
  String? subtitle,
  String? badge,
  Color? badgeColor,
}) {
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
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: isDark ? const Color(0x0AFFFFFF) : const Color(0x0A000000)),
            ),
          ),
          child: Row(
            children: [
              Flexible(
                child: Text(
                  title,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: isDark ? AppColors.darkText : AppColors.lightText),
                ),
              ),
              if (subtitle != null) ...[
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    subtitle,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                    style: TextStyle(fontSize: 11, color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary),
                  ),
                ),
              ],
              if (badge != null && badgeColor != null) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(color: badgeColor.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(6)),
                  child: Text(badge, style: TextStyle(fontSize: 10, color: badgeColor, fontWeight: FontWeight.w500)),
                ),
              ],
              const Spacer(),
              if (action != null) action,
            ],
          ),
        ),
        Padding(padding: const EdgeInsets.all(16), child: child),
      ],
    ),
  );
}

Widget _twoCol(List<Widget> children) {
  return LayoutBuilder(builder: (context, constraints) {
    final cols = constraints.maxWidth < 400 ? 1 : 2;
    return GridView.count(
      crossAxisCount: cols,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisSpacing: 12,
      mainAxisSpacing: 12,
      childAspectRatio: cols == 1 ? 5 : 3,
      children: children,
    );
  });
}

Widget _infoRow(String label, String value, bool isDark) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        label,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary),
      ),
      const SizedBox(height: 4),
      Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: isDark ? AppColors.navyMid : const Color(0xFFF8FAFC),
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: isDark ? const Color(0x1FFFFFFF) : const Color(0x1F000000)),
        ),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            value,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: isDark ? AppColors.darkText : AppColors.lightText),
          ),
        ),
      ),
    ],
  );
}

Widget _warningBanner(String message, bool isDark) {
  return Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(
      color: AppColors.caution.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: AppColors.caution.withValues(alpha: 0.2)),
    ),
    child: Row(
      children: [
        const Icon(Icons.warning_amber_outlined, size: 16, color: AppColors.caution),
        const SizedBox(width: 8),
        Expanded(child: Text(message, style: const TextStyle(fontSize: 11, color: AppColors.caution))),
      ],
    ),
  );
}

Widget _primaryBtn(IconData icon, String label, VoidCallback? onTap) {
  // onAccent only while the button is actually amber-filled — the disabled
  // state's grey fill is unchanged, so its text stays white as before
  // (SAMTRA palette rebrand, 2026-08-26).
  final fg = onTap != null ? AppColors.onAccent : Colors.white;
  return GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: onTap != null ? AppColors.teal : AppColors.lightTextSecondary.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: fg),
          if (label.isNotEmpty) ...[
            const SizedBox(width: 4),
            Text(label, style: TextStyle(fontSize: 12, color: fg)),
          ],
        ],
      ),
    ),
  );
}

Widget _outlineBtn(IconData icon, String label, bool isDark, VoidCallback onTap) {
  return GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: isDark ? AppColors.navyMid : AppColors.lightBackground,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: isDark ? const Color(0x1FFFFFFF) : const Color(0x1F000000)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: isDark ? AppColors.darkText : AppColors.lightText),
          if (label.isNotEmpty) ...[
            const SizedBox(width: 4),
            Text(label, style: TextStyle(fontSize: 11, color: isDark ? AppColors.darkText : AppColors.lightText)),
          ],
        ],
      ),
    ),
  );
}

Widget _dialogHeader(String title, bool isDark) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
    decoration: BoxDecoration(
      border: Border(
        bottom: BorderSide(color: isDark ? const Color(0x0FFFFFFF) : const Color(0x0F000000)),
      ),
    ),
    child: Row(
      children: [
        Expanded(
          child: Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: isDark ? AppColors.darkText : AppColors.lightText)),
        ),
        Builder(
          builder: (context) => IconButton(
            icon: Icon(Icons.close, size: 18, color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ),
      ],
    ),
  );
}

Widget _dialogFooterWithLoading(bool isDark, bool isLoading, Future<void> Function() onSave) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
    decoration: BoxDecoration(
      border: Border(
        top: BorderSide(color: isDark ? const Color(0x0FFFFFFF) : const Color(0x0F000000)),
      ),
    ),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('Cancel', style: TextStyle(color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary)),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          height: 36,
          child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: isLoading ? null : onSave,
            icon: isLoading
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.check, size: 16),
            label: const Text('Save'),
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
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary),
      ),
      const SizedBox(height: 4),
      TextFormField(
        controller: controller,
        keyboardType: keyboardType,
        obscureText: obscure,
        style: TextStyle(fontSize: 13, color: isDark ? AppColors.darkText : AppColors.lightText),
        decoration: const InputDecoration(
          contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          isDense: true,
        ),
      ),
    ],
  );
}
