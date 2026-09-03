import '../../core/supabase/supabase_config.dart';
import '../models/budget_figure.dart';

/// Reads and writes budget_figures — the one table in this whole app that's
/// genuinely user-owned data, per schema/001 Section 4. Writing requires
/// schema/004 (the UPDATE policy) and schema/005 (the profiles RLS
/// recursion fix) to be applied — without either, an edit to an
/// already-set month fails; see those migrations' comments for why.
class BudgetRepository {
  Future<List<BudgetFigure>> fetchBudget({required String dimension, String? entityCode}) async {
    var query = supabase.from('budget_figures').select().eq('dimension', dimension);
    if (entityCode != null) query = query.eq('entity_code', entityCode);
    final rows = await query.order('fiscal_month');
    return rows.map<BudgetFigure>((r) => BudgetFigure.fromMap(r)).toList();
  }

  /// sales_forecast's forecast_value, keyed by fiscal_month — the other half
  /// of schema/021's `coalesce(nullif(budget_value, 0), forecast_value)`
  /// target resolution, needed client-side by
  /// core/utils/target_overlay.dart's `resolveTarget` (Sales Analysis's
  /// Target overlay, 2026-09-03). Read directly off sales_forecast — same
  /// RLS (`sales_forecast_select`, schema/001) as fetchBudget above — rather
  /// than through v_dimension_performance/fn_dimension_performance_filtered,
  /// because those views only ever surface a row when there's at least one
  /// ACTUAL sales row for that (dimension, entity, fiscal_year, fiscal_month)
  /// — a customer with zero September sales but a perfectly real September
  /// target/forecast entered would show neither, which is exactly the gap
  /// Craig hit ("if I filter a customer who has no sales transaction for
  /// September... Target does not show"). budget_figures/sales_forecast
  /// themselves carry no fiscal_year column at all (schema/001 — one figure
  /// per fiscal_month label, reused every year), so reading them directly
  /// sidesteps the actual-sales dependency entirely rather than needing a
  /// schema change.
  Future<Map<String, num>> fetchForecastValues({required String dimension, required String entityCode}) async {
    final rows = await supabase
        .from('sales_forecast')
        .select('fiscal_month, forecast_value')
        .eq('dimension', dimension)
        .eq('entity_code', entityCode);
    return {for (final r in rows) r['fiscal_month'] as String: r['forecast_value'] as num};
  }

  /// Upsert one fiscal month's target for one entity. client_id is required
  /// here (unlike the read-only repositories) because RLS's WITH CHECK
  /// clause validates the row being written, not just who's writing it —
  /// the caller must supply their own profile's client_id.
  Future<void> setBudgetValue({
    required String clientId,
    required String dimension,
    required String entityCode,
    required String fiscalMonth,
    required num budgetValue,
  }) async {
    await supabase.from('budget_figures').upsert({
      'client_id': clientId,
      'dimension': dimension,
      'entity_code': entityCode,
      'fiscal_month': fiscalMonth,
      'budget_value': budgetValue,
      'updated_at': DateTime.now().toIso8601String(),
    }, onConflict: 'client_id,dimension,entity_code,fiscal_month');
  }
}
