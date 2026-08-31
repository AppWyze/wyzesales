import '../../core/supabase/supabase_config.dart';
import '../models/client.dart';
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
      throw Exception((response.data as Map?)?['error'] ?? 'Failed to create client');
    }
    return (response.data as Map)['supportEmail'] as String? ?? '';
  }
}
