import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../core/app_providers.dart';
import '../../core/constants/fiscal.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/theme_provider.dart';
import '../../data/models/data_load_run.dart';
import '../../data/models/profile.dart';
import 'app_logo.dart';
import 'global_filter_bar.dart';
import 'top_bar_search.dart';

/// Below this width the permanent sidebar collapses into a slide-out drawer
/// instead — matches Wyzesales_Rebuild_Decisions.md Section 6's "adapted
/// navigation pattern on mobile... same colours/components, different
/// structure". Chosen to match the breakpoint the Dashboard already used for
/// its own 1-vs-2-column grid, so the whole layout reflows at the same point.
const double _sidebarBreakpoint = 900;

/// Common scaffold (sidebar navigation + top bar) every authenticated screen
/// wraps itself in. Restyled 2026-08-21 to match SeaWyze's own look (see
/// Craig's reference screenshots) — a permanent dark sidebar with the nav
/// list and a bottom user-profile row, instead of the earlier slide-out
/// hamburger drawer. Narrow screens still get a drawer (see
/// _sidebarBreakpoint above); the sidebar's contents are identical either
/// way, just hosted differently.
class AppShell extends ConsumerWidget {
  const AppShell({
    super.key,
    required this.title,
    required this.body,
    this.actions,
    this.currentRoute,
    this.showGlobalFilters = true,
  });

  final String title;
  final Widget body;
  final List<Widget>? actions;

  /// Hides the global filter strip (2026-08-26, Craig: "Selection filters
  /// need to be iterative throughout the application") on screens that
  /// aren't sales-data screens at all — Settings and Platform Admin are the
  /// two call sites that pass false today. Defaults to true since every
  /// other screen in the app reads/displays sales figures the filter bar's
  /// dimension/Year/Month selections can narrow.
  final bool showGlobalFilters;

  /// The route this screen renders at (e.g. '/', '/sales-analysis'), used
  /// only to highlight the matching sidebar entry. Optional, defaulting to
  /// "no highlight" rather than trying to read the active route back out of
  /// go_router's context state — every screen already knows its own route
  /// directly from app_router.dart, so passing it explicitly here is the
  /// safe option in a project that can't run a real compiler to check an
  /// unfamiliar API surface (see the design notes on tree-sitter-only
  /// verification). Not yet wired up on every screen — this first pass only
  /// updates the Dashboard; see Wyzesales_Rebuild_Decisions.md.
  final String? currentRoute;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profileAsync = ref.watch(sessionProvider);
    final themeMode = ref.watch(themeModeProvider);
    final isWide = MediaQuery.of(context).size.width >= _sidebarBreakpoint;

    final sidebar = _Sidebar(profileAsync: profileAsync, currentRoute: currentRoute, isDrawer: !isWide);

    return Scaffold(
      drawer: isWide ? null : Drawer(width: 280, child: sidebar),
      body: SafeArea(
        child: Row(
          children: [
            if (isWide) SizedBox(width: 260, child: sidebar),
            Expanded(
              child: Column(
                children: [
                  _TopBar(title: title, actions: actions, showMenuButton: !isWide, themeMode: themeMode),
                  const Divider(height: 1),
                  if (showGlobalFilters) ...[
                    const GlobalFilterBar(),
                    const Divider(height: 1),
                  ],
                  Expanded(child: body),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Plain light header strip above the content area — title, today's date,
/// and the light/dark toggle. Deliberately light (matches the screenshot:
/// only the sidebar is dark, the dashboard's own top strip is not) rather
/// than reusing the app's old navy AppBar styling.
class _TopBar extends ConsumerWidget {
  const _TopBar({required this.title, required this.actions, required this.showMenuButton, required this.themeMode});

  final String title;
  final List<Widget>? actions;
  final bool showMenuButton;
  final ThemeMode themeMode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textTheme = Theme.of(context).textTheme;
    // A faint neutral tint derived from the theme's own text colour, rather
    // than a hardcoded gray — reads as a light chip on the light theme and
    // a subtle lighter-than-background chip on dark, without needing two
    // separate hand-picked colours. Matches SeaWyze's rounded gray chips
    // around its top-bar icons/date (Craig's reference screenshot,
    // 2026-08-21) — the plain unstyled icon/text this bar used before.
    final chipColor = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.06);
    return Container(
      // White (colorScheme.surface), not the scaffold's gray-blue — matches
      // SeaWyze's own top strip, which is white while the content area
      // below it (and the sidebar) carry the tinted backgrounds. Adapts to
      // dark mode automatically since colorScheme.surface already resolves
      // to darkSurface there.
      color: Theme.of(context).colorScheme.surface,
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
      child: Row(
        children: [
          if (showMenuButton) ...[
            _TopBarIconChip(icon: Icons.menu, tooltip: 'Menu', color: chipColor, onPressed: () => Scaffold.of(context).openDrawer()),
            const SizedBox(width: 8),
          ],
          Text(title, style: textTheme.headlineSmall, overflow: TextOverflow.ellipsis),
          const SizedBox(width: 16),
          // Expanded, not the title above — SeaWyze's own top bar gives the
          // search field the stretchy slot (title + date/actions/toggle
          // keep their natural size either side of it), matching Craig's
          // "insert a search function as per seawyze in the top bar"
          // (2026-08-26).
          const Expanded(child: TopBarSearch()),
          const SizedBox(width: 12),
          // Date/data-freshness chips dropped on narrow (drawer) widths —
          // same reasoning as everywhere else this session: better to show
          // fewer things cleanly than risk this Row overflowing sideways
          // once a long screen title and a narrow window compete for the
          // same space the search field can't fully give up.
          if (!showMenuButton) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(color: chipColor, borderRadius: BorderRadius.circular(8)),
              child: Text(DateFormat('EEE d MMM yyyy').format(DateTime.now()), style: textTheme.bodyMedium),
            ),
            const SizedBox(width: 8),
            _LastDataUpdateChip(chipColor: chipColor),
            const SizedBox(width: 8),
          ],
          ...?actions,
          _TopBarIconChip(
            icon: themeMode == ThemeMode.dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
            tooltip: 'Toggle theme',
            color: chipColor,
            onPressed: () => ref.read(themeModeProvider.notifier).toggle(),
          ),
        ],
      ),
    );
  }
}

class _TopBarIconChip extends StatelessWidget {
  const _TopBarIconChip({required this.icon, required this.tooltip, required this.color, required this.onPressed});

  final IconData icon;
  final String tooltip;
  final Color color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: color,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onPressed,
          // Container+alignment, not SizedBox — Container's alignment
          // guarantees the icon is centred regardless of how Icon sizes
          // itself internally at a smaller size (20) than the box (36),
          // a detail not worth relying on without a real renderer to check.
          child: Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            child: Icon(icon, size: 20),
          ),
        ),
      ),
    );
  }
}

/// Data-freshness indicator — replaces the Dashboard's old "Last Updated"
/// KPI tile (Craig, 2026-08-26: "Remove last update tile and insert last
/// update text in the top bar"). Lives here rather than on the Dashboard
/// screen so it shows on every screen, not just the Dashboard.
///
/// 2026-09-04: reads latestDataLoadRunProvider (data_load_runs, schema/033)
/// first — Craig's "real run tracking from the start" choice — so a failed
/// or stuck WyzeSalesExtract run shows up as an actual red "Load failed"/
/// "Load stuck" chip instead of a plain neutral timestamp that could mean
/// anything. Falls back to the old lastDataUpdateProvider (a plain
/// extracted_at timestamp, neutral-coloured, same as before this change) for
/// a client with no data_load_runs rows yet — WyzeSalesExtract not yet
/// redeployed with the update — so nothing regresses mid-rollout.
class _LastDataUpdateChip extends ConsumerWidget {
  const _LastDataUpdateChip({required this.chipColor});

  final Color chipColor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final runAsync = ref.watch(latestDataLoadRunProvider);

    return runAsync.when(
      data: (run) {
        if (run == null) return _fallbackChip(context, ref);
        final label = _labelFor(run);
        final color = _colorFor(run);
        return _chip(context, label, color.withValues(alpha: 0.14), color);
      },
      loading: () => _plainChip(context, 'Updated —'),
      // A query failure here (RLS not yet applied, transient network blip)
      // shouldn't read as "load failed" — that's a specific, meaningful
      // claim about WyzeSalesExtract this chip has no basis to make just
      // because ITS OWN read didn't come back. Falls back same as "no rows
      // yet" rather than fabricating a red state from an unrelated error.
      error: (_, __) => _fallbackChip(context, ref),
    );
  }

  String _labelFor(DataLoadRun run) {
    final timeLabel = DateFormat('d MMM, HH:mm').format(run.startedAt.toLocal());
    if (run.effectiveStatus == 'success') return 'Updated $timeLabel';
    if (run.effectiveStatus == 'running') return 'Loading… (since $timeLabel)';
    return run.isStuck ? 'Load stuck since $timeLabel' : 'Load failed $timeLabel';
  }

  Color _colorFor(DataLoadRun run) {
    if (run.effectiveStatus == 'success') return AppColors.positive;
    if (run.effectiveStatus == 'running') return AppColors.info;
    return AppColors.negative;
  }

  Widget _fallbackChip(BuildContext context, WidgetRef ref) {
    final lastUpdate = ref.watch(lastDataUpdateProvider);
    final label = lastUpdate.when(
      data: (value) => value == null ? 'No extract yet' : 'Updated ${DateFormat('d MMM, HH:mm').format(value.toLocal())}',
      loading: () => 'Updated —',
      error: (_, __) => 'Updated —',
    );
    return _plainChip(context, label);
  }

  Widget _plainChip(BuildContext context, String label) => _chip(context, label, chipColor, null);

  Widget _chip(BuildContext context, String label, Color background, Color? textColor) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(8)),
      child: Text(
        label,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: textColor, fontWeight: textColor == null ? null : FontWeight.w600),
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.profileAsync, required this.currentRoute, required this.isDrawer});

  final AsyncValue<Profile?> profileAsync;
  final String? currentRoute;
  final bool isDrawer;

  @override
  Widget build(BuildContext context) {
    final canManageUsers = profileAsync.value?.canManageUsers == true;
    final isPlatformAdmin = profileAsync.value?.isPlatformAdmin == true;

    return Container(
      color: AppColors.navyDeep,
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 24, 20, 16),
            child: Align(alignment: Alignment.centerLeft, child: AppLogo(iconSize: 32, fontSize: 19, onDark: true)),
          ),
          const Divider(color: Colors.white12, height: 1),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                _NavTile(icon: Icons.dashboard_outlined, label: 'Dashboard', route: '/', currentRoute: currentRoute, isDrawer: isDrawer),
                const _NavSectionLabel('Analysis'),
                _NavTile(icon: Icons.show_chart, label: 'Sales Analysis', route: '/sales-analysis', currentRoute: currentRoute, isDrawer: isDrawer),
                _NavTile(icon: Icons.calendar_view_month, label: 'YTD Comparative', route: '/ytd-comparative', currentRoute: currentRoute, isDrawer: isDrawer),
                // Quote Analysis / Sales Order Analysis tiles removed
                // 2026-09-02 — task #93, see Wyzesales_Rebuild_Decisions.md
                // Section 55 (no reliable quote/order data source; WCSA's
                // own daily-use app has never had any either).
                // Sales By / Performance / Budgets used to list one nav tile
                // per dimension (5 apiece) that all opened the same
                // parameterized screen — Craig pointed out that's pointless
                // busywork in the nav since the screen itself already has a
                // dimension switcher dropdown (see BoxedDropdown in
                // sales_by_screen.dart / performance_screen.dart /
                // budgets_screen.dart). Collapsed to one tile per screen,
                // each opening on the first dimension (Sales Person); no
                // section header needed for a single destination, same as
                // Dashboard above (2026-08-22).
                _NavTile(
                  icon: Icons.bar_chart,
                  label: 'Sales By',
                  route: '/sales-by/${SalesDimension.values.first.dbValue}',
                  activePrefix: '/sales-by/',
                  currentRoute: currentRoute,
                  isDrawer: isDrawer,
                ),
                _NavTile(
                  icon: Icons.speed,
                  label: 'Performance',
                  route: '/performance/${SalesDimension.values.first.dbValue}',
                  activePrefix: '/performance/',
                  currentRoute: currentRoute,
                  isDrawer: isDrawer,
                ),
                // Budgets — previously Admin/SuperUser only and tucked
                // under "Settings" ("Budgets screens — Admin/SuperUser
                // only"). Wyzesales_Rebuild_Decisions.md Section 70
                // (2026-09-03, Craig: "A User must be able to see their own
                // Budget... Users and RegUsers only have view access")
                // opened VIEWING up to every level, so this tile moved out
                // of the admin-only Settings section and in next to Sales
                // By/Performance — same shape (one tile, opens the
                // dimension switcher, no per-dimension entries), rendered
                // for every authenticated level unconditionally, same as
                // those two. Who can actually EDIT a figure is still
                // `canEditBudgets` (adminuser only), threaded into
                // `_MonthTable` inside budgets_screen.dart; who can see a
                // given DIMENSION's rows at all is still migration 031's
                // RLS — this tile no longer gates anything by itself.
                // `SalesDimension.values.first` (Sales Person) is a valid
                // landing dimension for every level, so no per-level
                // redirect is needed just to pick the opening route.
                _NavTile(
                  icon: Icons.edit_note,
                  label: 'Budgets',
                  route: '/budgets/${SalesDimension.values.first.dbValue}',
                  activePrefix: '/budgets/',
                  currentRoute: currentRoute,
                  isDrawer: isDrawer,
                ),
                if (canManageUsers) ...[
                  const _NavSectionLabel('Settings'),
                  // Company/Users/License — schema/008_wyzesales_
                  // multitenancy.sql. This just hides the entry,
                  // SettingsScreen itself is the real enforcement
                  // (canManageUsers == adminuser, see its own comment).
                  _NavTile(
                    icon: Icons.settings_outlined,
                    label: 'Settings',
                    route: '/settings',
                    currentRoute: currentRoute,
                    isDrawer: isDrawer,
                  ),
                ],
                // Platform Admin — separate from the client-scoped Settings
                // section above since it's cross-tenant, not "this client's
                // own settings" (only Craig's account and each client's
                // support+<code>@wyzesales.com login carry is_platform_admin
                // — see design doc Section 5).
                if (isPlatformAdmin) ...[
                  const _NavSectionLabel('Platform'),
                  _NavTile(
                    icon: Icons.admin_panel_settings_outlined,
                    label: 'Platform Admin',
                    route: '/admin',
                    currentRoute: currentRoute,
                    isDrawer: isDrawer,
                  ),
                ],
              ],
            ),
          ),
          const Divider(color: Colors.white12, height: 1),
          _ProfileFooter(profileAsync: profileAsync),
        ],
      ),
    );
  }
}

class _NavSectionLabel extends StatelessWidget {
  const _NavSectionLabel(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
      child: Text(
        label.toUpperCase(),
        style: const TextStyle(color: Colors.white38, fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.6),
      ),
    );
  }
}

class _NavTile extends StatelessWidget {
  const _NavTile({
    required this.icon,
    required this.label,
    required this.route,
    required this.currentRoute,
    required this.isDrawer,
    this.activePrefix,
  });

  final IconData icon;
  final String label;
  final String route;
  final String? currentRoute;
  final bool isDrawer;

  /// When set, active-highlighting matches any currentRoute starting with
  /// this prefix rather than requiring an exact match against `route` —
  /// used by the now-collapsed Sales By/Performance/Budgets tiles, whose
  /// `route` only points at the first dimension but should still show
  /// active while viewing any dimension under that screen (e.g.
  /// '/sales-by/category' should highlight the single 'Sales By' tile,
  /// not just '/sales-by/sales_person').
  final String? activePrefix;

  @override
  Widget build(BuildContext context) {
    final active = currentRoute != null &&
        (activePrefix != null ? currentRoute!.startsWith(activePrefix!) : currentRoute == route);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Material(
        color: active ? AppColors.teal.withValues(alpha: 0.18) : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () {
            if (isDrawer) Navigator.of(context).pop();
            context.go(route);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(icon, size: 20, color: active ? AppColors.teal : Colors.white70),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: active ? Colors.white : Colors.white70,
                      fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                      // Was 14 — hardcoded and never tied to the app's
                      // textTheme, so it slipped through both earlier
                      // font-shrink passes. Dropped to 13 to match the
                      // scale used everywhere else (titleMedium/bodyLarge
                      // are both 13) since these screenshots put the
                      // sidebar side-by-side with SeaWyze's own, smaller
                      // nav text (Craig, 2026-08-21).
                      fontSize: 13,
                    ),
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

class _ProfileFooter extends ConsumerWidget {
  const _ProfileFooter({required this.profileAsync});
  final AsyncValue<Profile?> profileAsync;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = profileAsync.value;
    // Written as two explicit steps rather than a chained
    // `profile?.name.isNotEmpty` — that chain is valid Dart (a `?.` short-
    // circuits the rest of the selector chain, not just the next property),
    // but this project has no real Dart compiler to double-check precedence
    // against, so the unambiguous version is worth the extra line.
    final rawName = profile?.name;
    final name = (rawName != null && rawName.isNotEmpty) ? rawName : 'WyzeSales';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Column(
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: AppColors.teal,
                // onAccent, not white — the brand accent behind this avatar
                // is now a pale amber (SAMTRA palette, 2026-08-26), and white
                // initials read poorly against a light fill the same way
                // they would on any pale colour.
                child: Text(_initialsFor(profile?.name), style: const TextStyle(color: AppColors.onAccent, fontWeight: FontWeight.w600, fontSize: 13)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      name,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      _levelLabel(profile?.level),
                      style: const TextStyle(color: Colors.white54, fontSize: 11),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Sign out',
                icon: const Icon(Icons.logout, color: Colors.white70, size: 20),
                onPressed: () => ref.read(authRepositoryProvider).signOut(),
              ),
            ],
          ),
          // Version/copyright line beneath the profile row, matching
          // SeaWyze's own sidebar-bottom pattern (Craig's screenshot,
          // 2026-08-21) and the wording already used on the Login screen's
          // footer (login_screen.dart) so the two stay consistent.
          const SizedBox(height: 10),
          const Text(
            'WyzeSales v0.1 · © 2026 WyzeSales',
            style: TextStyle(color: Colors.white38, fontSize: 10),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

String _initialsFor(String? name) {
  if (name == null || name.trim().isEmpty) return 'W';
  final parts = name.trim().split(RegExp(r'\s+'));
  if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
  return (parts.first.substring(0, 1) + parts.last.substring(0, 1)).toUpperCase();
}

String _levelLabel(UserLevel? level) {
  switch (level) {
    case UserLevel.superuser:
      return 'SuperUser';
    case UserLevel.adminuser:
      return 'Admin';
    case UserLevel.reguser:
      return 'RegUser';
    case UserLevel.user:
      return 'User';
    case null:
      return '';
  }
}
