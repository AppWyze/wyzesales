import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/models/profile.dart';
import '../data/repositories/auth_repository.dart';
import '../data/repositories/budget_repository.dart';
import '../data/repositories/platform_admin_repository.dart';
import '../data/repositories/reference_data_repository.dart';
import '../data/repositories/sales_repository.dart';
import '../data/repositories/settings_repository.dart';
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
