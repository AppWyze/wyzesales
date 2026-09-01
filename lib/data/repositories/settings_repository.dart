import '../../core/supabase/supabase_config.dart';
import '../models/client.dart';
import '../models/license.dart';
import '../models/profile.dart';

/// Own-client-scoped settings: the client's own profile, its license
/// (read-only here — only a platform admin can change it, see
/// PlatformAdminRepository), and its users. Mirrors the shape of SeaWyze's
/// settings_repository.dart, adapted to WyzeSales' clients/license/profiles
/// tables and users-only license model (schema/008_wyzesales_multitenancy.sql).
/// Every read here relies on RLS to scope to the caller's own client_id —
/// none of these methods take a clientId parameter for that reason, the same
/// convention BudgetRepository/SalesRepository already use.
class SettingsRepository {
  Future<Client?> getClient(String clientId) async {
    final row = await supabase.from('clients').select().eq('id', clientId).maybeSingle();
    if (row == null) return null;
    return Client.fromMap(row);
  }

  /// Powers Settings > Company's edit dialog — a client's own adminuser
  /// updating their own client row (RLS: `clients_adminuser_update`,
  /// schema/008). Replaced the old name-only `updateClientName` 2026-08-28
  /// once Craig asked for the fuller SeaWyze-equivalent edit ("all of the
  /// fields as per Seawyze but without the Company Documents function") —
  /// `data` is whichever of name/contact_name/contact_number/contact_email/
  /// address1/address2/address3/city/country/postal_code the dialog
  /// actually changed, same generic-map shape PlatformAdminRepository's
  /// `updateClient` already uses for the platform-admin-side edit.
  Future<Client> updateCompanyProfile(String clientId, Map<String, dynamic> data) async {
    final row = await supabase.from('clients').update(data).eq('id', clientId).select().single();
    return Client.fromMap(row);
  }

  /// The signed-in user's client's fiscal year start month
  /// (fiscal_year_settings.start_month) — a separate table from `clients`
  /// (schema/001 Section 7), one row per client, primary-keyed on client_id.
  /// No clientId parameter, same convention as BudgetRepository/
  /// SalesRepository: RLS (`fiscal_year_settings_select`, schema/006)
  /// already scopes any read to the caller's own client, and the primary key
  /// guarantees at most one row comes back either way. Defaults to 3 (March)
  /// client-side when no row exists yet for this client — mirrors the exact
  /// same `coalesce(fys.start_month, 3)` schema/001's own v_sales_documents
  /// already does server-side, so a client that's never touched this setting
  /// behaves identically to how every client behaved before this feature
  /// existed.
  Future<int> getFiscalYearStartMonth() async {
    final row = await supabase.from('fiscal_year_settings').select('start_month').maybeSingle();
    return (row?['start_month'] as int?) ?? 3;
  }

  /// Powers Settings > Company's "Fiscal year starts" field (2026-09-01,
  /// Craig: "We are assuming that a Client's Financial Year runs from March
  /// to February but this will not always be the case"). Upserts rather than
  /// a plain update — a client created before this feature has no
  /// fiscal_year_settings row at all (schema/001's own join already defaults
  /// that missing row to March via `coalesce`), so the very first save here
  /// has to INSERT, not UPDATE a row that doesn't exist; `onConflict:
  /// 'client_id'` targets that table's own primary key (schema/001), so
  /// every later save just updates the same row. RLS:
  /// `fiscal_year_settings_adminuser_upsert`/`_update` (schema/019) — the
  /// same `is_adminuser()` + `get_my_client_id()` gate `clients_adminuser_
  /// update` already uses.
  Future<void> updateFiscalYearStartMonth(String clientId, int startMonth) async {
    await supabase.from('fiscal_year_settings').upsert(
      {'client_id': clientId, 'start_month': startMonth},
      onConflict: 'client_id',
    );
  }

  /// The signed-in user's client's data history window in fiscal years — 3
  /// or 5 (fiscal_year_settings.history_years, schema/020). Same table, same
  /// "no clientId parameter, RLS + primary key already narrow it to one row"
  /// convention as getFiscalYearStartMonth right above; defaults to 3 for a
  /// client that's never touched this setting, matching that column's own
  /// database default exactly.
  Future<int> getDataHistoryYears() async {
    final row = await supabase.from('fiscal_year_settings').select('history_years').maybeSingle();
    return (row?['history_years'] as int?) ?? 3;
  }

  /// Powers Settings > Company's "Data history window" field (2026-09-01,
  /// Craig: "either 3 or 5 years of data that we can Add and Edit"). Upserts
  /// for the same "might be this client's very first save to this table"
  /// reason updateFiscalYearStartMonth does — see that method's own doc
  /// comment; the two are independent upserts against the same row rather
  /// than one combined call so saving one field here never depends on the
  /// caller also knowing the other's current value (Postgres upsert only
  /// touches the columns actually present in the payload, on either the
  /// insert or the update path).
  Future<void> updateDataHistoryYears(String clientId, int historyYears) async {
    await supabase.from('fiscal_year_settings').upsert(
      {'client_id': clientId, 'history_years': historyYears},
      onConflict: 'client_id',
    );
  }

  /// Joins pricing_plan so License.plan is populated — needed for the
  /// License tab's pricing breakdown (License.discountedMonthly) without a
  /// second round trip.
  Future<License?> getLicense(String clientId) async {
    final row = await supabase
        .from('license')
        .select('*, pricing_plan(*)')
        .eq('client_id', clientId)
        .maybeSingle();
    if (row == null) return null;
    return License.fromMap(row);
  }

  Future<List<Profile>> getUsers(String clientId) async {
    final rows = await supabase.from('profiles').select().eq('client_id', clientId).order('name');
    return rows.map<Profile>((r) => Profile.fromMap(r)).toList();
  }

  /// Creates both the Supabase Auth login and the profiles row via the
  /// create-user Edge Function (needs the Admin API / service-role key,
  /// which the client app never holds directly — see that function's own
  /// comment). The function itself re-derives clientId from the caller's
  /// own profile rather than trusting anything passed here, and the
  /// schema/008 seat-limit trigger enforces max_users regardless of which
  /// path inserts the row.
  Future<void> createUser({
    required String email,
    required String password,
    required String name,
    required UserLevel level,
    String? contactNumber,
    String? repCode,
    String? branchCode,
  }) async {
    final response = await supabase.functions.invoke('create-user', body: {
      'email': email,
      'password': password,
      'name': name,
      'level': level.name,
      'contactNumber': contactNumber,
      'repCode': repCode,
      'branchCode': branchCode,
    });
    if (response.status != 200) {
      throw Exception((response.data as Map?)?['error'] ?? 'Failed to create user');
    }
  }

  Future<void> updateUser(String id, Map<String, dynamic> data) async {
    await supabase.from('profiles').update(data).eq('id', id);
  }

  Future<void> deactivateUser(String id) async {
    await supabase.from('profiles').update({'is_active': false}).eq('id', id);
  }

  Future<void> reactivateUser(String id) async {
    await supabase.from('profiles').update({'is_active': true}).eq('id', id);
  }

  /// Hard-deletes both the profiles row and the Auth login via the
  /// delete-user Edge Function — same defensive checks (no self-delete, no
  /// cross-client delete, no deleting a platform-admin account) as SeaWyze's
  /// equivalent function, see its own comment.
  Future<void> deleteUser(String userId) async {
    final response = await supabase.functions.invoke('delete-user', body: {'userId': userId});
    if (response.status != 200) {
      throw Exception((response.data as Map?)?['error'] ?? 'Failed to delete user');
    }
  }

  /// Emails support@wyzesales.com — see send-upgrade-request's own comment
  /// for why the domain caveat exists. No parameters: the function derives
  /// everything (client, current license, requester) server-side from the
  /// caller's own JWT.
  Future<void> requestUpgrade() async {
    final response = await supabase.functions.invoke('send-upgrade-request');
    if (response.status != 200) {
      throw Exception((response.data as Map?)?['error'] ?? 'Failed to send upgrade request');
    }
  }
}
