import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/supabase/supabase_config.dart';
import '../../core/utils/edge_function_errors.dart';
import '../models/client.dart';
import '../models/client_dimension_config.dart';
import '../models/license.dart';
import '../models/pricing_plan.dart';

/// Cross-tenant reads/writes for the Platform Admin screen — every method
/// here is only reachable in practice by an is_platform_admin account
/// (schema/008's license_platform_admin_*/pricing_plan_platform_admin_*/
/// clients_platform_admin_* RLS policies enforce that at the database
/// regardless of what the UI shows). Mirrors SeaWyze's
/// allCompaniesProvider/standardPlanProvider queries
/// (platform_admin_screen.dart) minus every vessel-shaped field.
class PlatformAdminRepository {
  /// One row per client with its license and that license's plan nested —
  /// `license` and `pricing_plan` come back as lists even though each is
  /// effectively one-to-one (schema/008's `license_one_per_client` unique
  /// index), because PostgREST embeds based on the FK direction, not on a
  /// separate uniqueness constraint it doesn't inspect. Same shape SeaWyze's
  /// own equivalent query returns and unwraps with `.firstOrNull`.
  Future<List<Map<String, dynamic>>> fetchClientsWithLicense() async {
    final rows = await supabase
        .from('clients')
        .select('*, license(*, pricing_plan(*))')
        .order('name');
    return (rows as List).cast<Map<String, dynamic>>();
  }

  Future<List<PricingPlan>> fetchPricingPlans() async {
    final rows = await supabase.from('pricing_plan').select().order('name');
    return rows.map<PricingPlan>((r) => PricingPlan.fromMap(r)).toList();
  }

  Future<PricingPlan> updatePricingPlan(String id, Map<String, dynamic> data) async {
    final row = await supabase.from('pricing_plan').update(data).eq('id', id).select().single();
    return PricingPlan.fromMap(row);
  }

  /// Refreshes `license.annual_price` for every license on `plan`, using
  /// `plan`'s just-saved rates — called right after `updatePricingPlan` so a
  /// rate change doesn't leave every affected license's stored annual price
  /// stale (Craig, 2026-08-28: "Pricing: Annual price needs to be
  /// recalculated on SAVE"). Deliberately unconditional: a license with its
  /// own `discount_percent` still gets recalculated, at ITS discount against
  /// the plan's NEW rates, not skipped or frozen — `discount_percent` is a
  /// percentage off the plan-derived total specifically so a negotiated
  /// rate keeps tracking the plan (see PricingPlan's own doc comment), and a
  /// stale absolute override is exactly the failure mode SeaWyze's own
  /// equivalent logic has (see Wyzesales_Rebuild_Decisions.md for that
  /// comparison). One `.update()` per license — schema/008's licenses are
  /// never numerous enough per plan for this to need a batch upsert.
  Future<void> recalculateLicensesForPlan(PricingPlan plan) async {
    final rows = await supabase.from('license').select('id, max_users, discount_percent').eq('plan_id', plan.id);
    for (final row in (rows as List).cast<Map<String, dynamic>>()) {
      final maxUsers = row['max_users'] as int? ?? plan.baseUsers;
      final discountPercent = row['discount_percent'] as num? ?? 0;
      await supabase
          .from('license')
          .update({'annual_price': plan.annualPriceForSeats(maxUsers, discountPercent)})
          .eq('id', row['id'] as String);
    }
  }

  Future<PricingPlan> createPricingPlan(Map<String, dynamic> data) async {
    final row = await supabase.from('pricing_plan').insert(data).select().single();
    return PricingPlan.fromMap(row);
  }

  Future<License> updateLicense(String id, Map<String, dynamic> data) async {
    final row = await supabase.from('license').update(data).eq('id', id).select('*, pricing_plan(*)').single();
    return License.fromMap(row);
  }

  Future<Client> updateClient(String id, Map<String, dynamic> data) async {
    final row = await supabase.from('clients').update(data).eq('id', id).select().single();
    return Client.fromMap(row);
  }

  /// Creates a new client + license + first adminuser + support login via
  /// the create-client Edge Function (needs the Admin API to create two
  /// Auth logins — can't be done from the client directly, see that
  /// function's own comment). Returns the support login's email so the
  /// caller can show it to whoever's provisioning the client.
  Future<String> createClient({
    required String clientCode,
    required String clientName,
    required String adminName,
    required String adminEmail,
    required String adminPassword,
    required String supportPassword,
    required String planId,
    required int maxUsers,
    num discountPercent = 0,
  }) async {
    try {
      final response = await supabase.functions.invoke('create-client', body: {
        'clientCode': clientCode,
        'clientName': clientName,
        'adminName': adminName,
        'adminEmail': adminEmail,
        'adminPassword': adminPassword,
        'supportPassword': supportPassword,
        'planId': planId,
        'maxUsers': maxUsers,
        'discountPercent': discountPercent,
      });
      if (response.status != 200) {
        throw EdgeFunctionError((response.data as Map?)?['error'] as String? ?? 'Failed to create client');
      }
      return (response.data as Map)['supportEmail'] as String? ?? '';
    } on FunctionsHttpException catch (e) {
      throw friendlyEdgeFunctionError(e, fallback: 'Failed to create client');
    }
  }

  // ── Dimensions (multi-tenant dimension model, Platform Admin "Dimensions"
  // tab) ────────────────────────────────────────────────────────────────
  //
  // client_dimensions/client_dimension_values (schema/038) are read/written
  // for an ARBITRARY selected client here, unlike
  // ReferenceDataRepository.clientDimensions() (which always reads the
  // SIGNED-IN user's own client via RLS with no client_id filter needed) —
  // this screen is the one place an is_platform_admin account configures a
  // client other than their own, so every method below takes an explicit
  // `clientId`. schema/038's own RLS already lets is_platform_admin read/
  // write across every client; these queries just need to say which one.

  /// This client's configured dimensions, in filter-bar order — same shape
  /// `ReferenceDataRepository.clientDimensions()` returns for the signed-in
  /// user's own client, just explicitly scoped to `clientId` instead.
  Future<List<ClientDimensionConfig>> fetchClientDimensions(String clientId) async {
    final rows = await supabase.from('client_dimensions').select().eq('client_id', clientId).order('sort_order');
    return rows.map<ClientDimensionConfig>((r) => ClientDimensionConfig.fromMap(r)).toList();
  }

  /// `data` must include `dimension_key` and `resolution_kind` — both are
  /// part of this row's identity/shape and, unlike every other field here,
  /// are never editable again once a client's extractor may have started
  /// writing data keyed by them (see `_EditDimensionDialog`'s own doc
  /// comment on why the UI locks them after creation).
  Future<ClientDimensionConfig> createClientDimension(String clientId, Map<String, dynamic> data) async {
    if (data['is_rls_scope'] == true) await _clearOtherRlsScopes(clientId, data['dimension_key'] as String);
    final row = await supabase.from('client_dimensions').insert({...data, 'client_id': clientId}).select().single();
    return ClientDimensionConfig.fromMap(row);
  }

  Future<ClientDimensionConfig> updateClientDimension(String clientId, String dimensionKey, Map<String, dynamic> data) async {
    if (data['is_rls_scope'] == true) await _clearOtherRlsScopes(clientId, dimensionKey);
    final row = await supabase
        .from('client_dimensions')
        .update(data)
        .eq('client_id', clientId)
        .eq('dimension_key', dimensionKey)
        .select()
        .single();
    return ClientDimensionConfig.fromMap(row);
  }

  /// schema/038's `client_dimensions_one_rls_scope` partial unique index
  /// allows at most one `is_rls_scope = true` row per client — turning it on
  /// for one dimension has to mean turning it off everywhere else for the
  /// SAME client first, in the same request, or the insert/update below
  /// would just hit that unique-index violation instead of doing the
  /// "obviously one RLS boundary at a time" thing an admin actually wants
  /// (design doc principle 5: "the one dimension a RegUser is pinned to").
  /// `neq`, not a blanket update, so this never touches another client's
  /// rows even though `dimension_key` alone repeats across clients.
  Future<void> _clearOtherRlsScopes(String clientId, String exceptDimensionKey) async {
    await supabase
        .from('client_dimensions')
        .update({'is_rls_scope': false})
        .eq('client_id', clientId)
        .eq('is_rls_scope', true)
        .neq('dimension_key', exceptDimensionKey);
  }

  /// Fails with a foreign-key error (surfaced to the dialog's `_error` text,
  /// same as every other save/delete failure in this screen) if any
  /// budget_figures/sales_forecast row still carries this dimension
  /// (migration 040's FK) — deliberately not caught/prettied here, so a
  /// platform admin removing a dimension still in active use gets a clear
  /// signal something else needs cleaning up first, rather than a silent
  /// partial delete.
  Future<void> deleteClientDimension(String clientId, String dimensionKey) async {
    await supabase.from('client_dimensions').delete().eq('client_id', clientId).eq('dimension_key', dimensionKey);
  }

  /// One client's lookup values for one `fact_column`/`customer_attribute`
  /// dimension (client_dimension_values, schema/038) — plain Maps rather
  /// than a dedicated model, same as `fetchClientsWithLicense` above: this
  /// is the only place in the app that reads/writes this table (WCSA's own
  /// six dimensions are all `resolution_kind = 'existing'` and never touch
  /// it), so a model class would have exactly one caller.
  Future<List<Map<String, dynamic>>> fetchClientDimensionValues(String clientId, String dimensionKey) async {
    final rows = await supabase
        .from('client_dimension_values')
        .select()
        .eq('client_id', clientId)
        .eq('dimension_key', dimensionKey)
        .order('name');
    return (rows as List).cast<Map<String, dynamic>>();
  }

  Future<void> createClientDimensionValue(String clientId, String dimensionKey, Map<String, dynamic> data) async {
    await supabase.from('client_dimension_values').insert({...data, 'client_id': clientId, 'dimension_key': dimensionKey});
  }

  Future<void> updateClientDimensionValue(String clientId, String dimensionKey, String code, Map<String, dynamic> data) async {
    await supabase
        .from('client_dimension_values')
        .update(data)
        .eq('client_id', clientId)
        .eq('dimension_key', dimensionKey)
        .eq('code', code);
  }

  /// Fails with a foreign-key error if another value's `parent_code` still
  /// points at this one (schema/038's self-referencing FK) — same
  /// deliberately-not-prettied reasoning as `deleteClientDimension` above.
  Future<void> deleteClientDimensionValue(String clientId, String dimensionKey, String code) async {
    await supabase
        .from('client_dimension_values')
        .delete()
        .eq('client_id', clientId)
        .eq('dimension_key', dimensionKey)
        .eq('code', code);
  }
}
