import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/models/profile.dart';
import '../data/repositories/auth_repository.dart';
import '../data/repositories/budget_repository.dart';
import '../data/repositories/platform_admin_repository.dart';
import '../data/repositories/reference_data_repository.dart';
import '../data/repositories/sales_repository.dart';
import '../data/repositories/settings_repository.dart';
import 'constants/fiscal.dart';
import 'supabase/supabase_config.dart';

final authRepositoryProvider = Provider<AuthRepository>((ref) => AuthRepository());
final referenceDataRepositoryProvider = Provider<ReferenceDataRepository>((ref) => ReferenceDataRepository());
final salesRepositoryProvider = Provider<SalesRepository>((ref) => SalesRepository());
final budgetRepositoryProvider = Provider<BudgetRepository>((ref) => BudgetRepository());
final settingsRepositoryProvider = Provider<SettingsRepository>((ref) => SettingsRepository());
final platformAdminRepositoryProvider = Provider<PlatformAdminRepository>((ref) => PlatformAdminRepository());

/// Holds the signed-in user's own profile row (name, level, rep_code,
/// branch_code, client_id) — loaded once on sign-in, cleared on sign-out.
/// Screens read `ref.watch(currentProfileProvider)` to decide what to show
/// (e.g. hide the Budgets edit controls for a plain 'user' level) and to get
/// clientId for writes (see BudgetRepository.setBudgetValue).
class SessionNotifier extends StateNotifier<AsyncValue<Profile?>> {
  SessionNotifier(this._authRepository) : super(const AsyncValue.data(null)) {
    _refresh();
    _authRepository.onAuthStateChange.listen((_) => _refresh());
  }

  final AuthRepository _authRepository;

  Future<void> _refresh() async {
    if (_authRepository.currentSession == null) {
      state = const AsyncValue.data(null);
      return;
    }
    state = const AsyncValue.loading();
    try {
      final profile = await _authRepository.loadCurrentProfile();
      // schema/008 added profiles.is_active (mirrors SeaWyze's app_user.
      // is_active / company.is_dormant) — Supabase Auth itself has no idea
      // this column exists, so a deactivated login would otherwise sail
      // straight past sign-in and land on the Dashboard with a valid
      // session. Signing out here, the first time that profile is loaded
      // after auth succeeds, is the actual enforcement point.
      if (profile != null && !profile.isActive) {
        await _authRepository.signOut();
        state = const AsyncValue.data(null);
        return;
      }
      state = AsyncValue.data(profile);
    } catch (error, stackTrace) {
      state = AsyncValue.error(error, stackTrace);
    }
  }
}

final sessionProvider = StateNotifierProvider<SessionNotifier, AsyncValue<Profile?>>(
  (ref) => SessionNotifier(ref.watch(authRepositoryProvider)),
);

/// Data freshness indicator shown in AppShell's top bar (Craig, 2026-08-26:
/// moved out of the Dashboard's own "Last Updated" KPI tile so it's visible
/// on every screen, not just the Dashboard) — the most recent
/// sales_document_facts.extracted_at, i.e. when WyzeSalesExtract's daily
/// load last ran. Plain (non-autoDispose) FutureProvider: this changes at
/// most once a day, so every screen's AppShell sharing one cached read
/// (rather than each screen refetching it independently, which is what the
/// Dashboard used to do on its own) is the right default. Nothing in this
/// app writes sales_document_facts — only the extract does — so there's
/// currently no action that needs to `ref.invalidate` this; a manual pull-
/// to-refresh could, if that's ever wanted.
final lastDataUpdateProvider = FutureProvider<DateTime?>((ref) async {
  final rows = await supabase.from('sales_document_facts').select('extracted_at').order('extracted_at', ascending: false).limit(1);
  if (rows.isEmpty) return null;
  return DateTime.parse(rows.first['extracted_at'] as String);
});

/// The signed-in user's client's fiscal year start month
/// (fiscal_year_settings.start_month, Settings > Company, 2026-09-01) — every
/// screen that used to assume "fiscal year always starts in March" now reads
/// this instead of fiscal.dart's old hardcoded default (see fiscalMonthOrderFor's
/// own doc comment). Plain (non-autoDispose) FutureProvider, same convention
/// as lastDataUpdateProvider above: this changes rarely (an admin editing one
/// Settings field), so one shared cached read across every screen is right
/// rather than each screen refetching independently. Explicitly
/// `ref.invalidate`d by `_EditCompanyDialog`'s save handler
/// (settings_screen.dart) so a changed start month takes effect app-wide
/// immediately, not just on next reload.
final fiscalYearStartMonthProvider = FutureProvider<int>((ref) {
  return ref.watch(settingsRepositoryProvider).getFiscalYearStartMonth();
});

/// The signed-in user's client's data history window in fiscal years — 3 or
/// 5 (fiscal_year_settings.history_years, Settings > Company, 2026-09-01,
/// schema/020) — every "trailing N fiscal years" screen that used to assume
/// exactly 3 now reads this instead of a hardcoded literal (see
/// fiscalYearWindow's own doc comment, fiscal.dart). Same plain
/// (non-autoDispose) FutureProvider convention as fiscalYearStartMonthProvider
/// right above, for the same reason: this changes rarely, so one shared
/// cached read across every screen is right. Explicitly `ref.invalidate`d by
/// `_EditCompanyDialog`'s save handler (settings_screen.dart) alongside
/// fiscalYearStartMonthProvider, so a changed window takes effect app-wide
/// immediately.
final fiscalYearHistoryYearsProvider = FutureProvider<int>((ref) {
  return ref.watch(settingsRepositoryProvider).getDataHistoryYears();
});

/// Which fiscal years (within the client's own history window) actually have
/// any sales data on record, and — per fiscal year — which calendar months
/// do — 2026-09-01, Craig: "Year and Month filters. Can we apply the no data
/// rule shaded grey. E.g. 2027 has no data for Sept forward therefore these
/// should be greyed out and there is no data for 2023 and 2024." Backs the
/// global filter bar's Year/Month "Add filter" pickers
/// (global_filter_bar.dart), which grey out and disable any option this
/// doesn't list.
///
/// Derived from the same `fetchConsolidatedSales` company-wide monthly
/// rollup YTD Comparative already reads, over the client's actual configured
/// window (fiscalYearWindow(currentFy, historyYears)) — not a new query or
/// SQL function, since that view already carries exactly the (fiscal_year,
/// month) pairs needed and RLS already scopes it to what the signed-in user
/// can see, same as everywhere else in the app. A fiscal year with zero rows
/// in the window (2023/2024 in Craig's example — this client's data simply
/// doesn't go back that far) never appears in `yearsWithData`.
///
/// 2026-09-01 correction: the Month picker's greying originally checked ONLY
/// the current fiscal year's months (`currentYearMonthsWithData`, since
/// removed) regardless of whether a Year filter was active — Craig caught
/// that this meant a month like September stayed greyed even with Year 2025
/// selected (which has real September data), because the check never
/// actually looked at 2025. `monthsWithDataByYear` fixes this by keying
/// month-availability per fiscal year; global_filter_bar.dart now checks the
/// currently-selected Year filter's own months when one is active, falling
/// back to `currentFiscalYear`'s months only when no Year filter is set —
/// which is when "hasn't happened yet" is the only sensible reading of
/// picking a bare month with no year attached.
///
/// Plain (non-autoDispose) FutureProvider, same convention as
/// lastDataUpdateProvider/fiscalYearStartMonthProvider above — this changes
/// at most once a day (when the extract runs), so one shared cached read is
/// right rather than every screen or filter-bar open refetching it.
class FiscalDataAvailability {
  const FiscalDataAvailability({
    required this.yearsWithData,
    required this.currentFiscalYear,
    required this.monthsWithDataByYear,
  });
  final Set<int> yearsWithData;
  final int currentFiscalYear;
  final Map<int, Set<String>> monthsWithDataByYear;
}

final fiscalYearDataAvailabilityProvider = FutureProvider<FiscalDataAvailability>((ref) async {
  final startMonth = await ref.watch(fiscalYearStartMonthProvider.future);
  final historyYears = await ref.watch(fiscalYearHistoryYearsProvider.future);
  final currentFy = fiscalYearFor(DateTime.now(), startMonth: startMonth);
  final window = fiscalYearWindow(currentFy, historyYears);

  final rows = await ref.watch(salesRepositoryProvider).fetchConsolidatedSales(fiscalYears: window);

  final years = <int>{};
  final monthsByYear = <int, Set<String>>{};
  for (final row in rows) {
    years.add(row.fiscalYear);
    monthsByYear.putIfAbsent(row.fiscalYear, () => {}).add(fiscalMonthLabelFor(row.month));
  }
  return FiscalDataAvailability(yearsWithData: years, currentFiscalYear: currentFy, monthsWithDataByYear: monthsByYear);
});
