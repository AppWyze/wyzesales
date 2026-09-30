import '../../core/supabase/supabase_config.dart';
import '../models/budget_figure.dart';
import '../models/sales_forecast_figure.dart';

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

  /// sales_forecast rows for a dimension, optionally narrowed to one entity
  /// — the other half of schema/021's `coalesce(nullif(budget_value, 0),
  /// forecast_value)` target resolution, needed client-side by
  /// core/utils/target_overlay.dart's `resolveTarget`. Read directly off
  /// sales_forecast — same RLS (`sales_forecast_select`, schema/001) as
  /// fetchBudget above — rather than through
  /// v_dimension_performance/fn_dimension_performance_filtered, because
  /// those views only ever surface a row when there's at least one ACTUAL
  /// sales row for that (dimension, entity, fiscal_year, fiscal_month) — a
  /// customer with zero September sales but a perfectly real September
  /// target/forecast entered would show neither, which is exactly the gap
  /// Craig hit ("if I filter a customer who has no sales transaction for
  /// September... Target does not show"). budget_figures/sales_forecast
  /// themselves carry no fiscal_year column at all (schema/001 — one figure
  /// per fiscal_month label, reused every year), so reading them directly
  /// sidesteps the actual-sales dependency entirely rather than needing a
  /// schema change. Mirrors fetchBudget's own optional-`entityCode` shape
  /// (2026-09-03 — dashboard_screen.dart's Rep Target Attainment needed
  /// every rep's forecast at once, not just one entity's, the same reason
  /// fetchBudget itself takes an optional entityCode).
  Future<List<SalesForecastFigure>> fetchForecast({required String dimension, String? entityCode}) async {
    var query = supabase.from('sales_forecast').select().eq('dimension', dimension);
    if (entityCode != null) query = query.eq('entity_code', entityCode);
    final rows = await query;
    return rows.map<SalesForecastFigure>((r) => SalesForecastFigure.fromMap(r)).toList();
  }

  /// The single-entity case of [fetchForecast] above, flattened to a plain
  /// `fiscal_month -> forecast_value` map — the shape
  /// sales_analysis_screen.dart's `_fetchTargetByMonth` already expects.
  Future<Map<String, num>> fetchForecastValues({required String dimension, required String entityCode}) async {
    final rows = await fetchForecast(dimension: dimension, entityCode: entityCode);
    return {for (final r in rows) r.fiscalMonth: r.forecastValue};
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

  /// 2026-09-30, Craig: "If I enter a Company Sales Budget and press Save
  /// can it come up with a Question... Selecting Yes then takes the Company
  /// Budget and apportions it across the Dimensions and Entities according
  /// to the associated Seasonal Forecast Contribution by entity %." Calls
  /// `fn_apportion_company_budget` (see that migration's own comment for
  /// the full mechanics/edge cases) — a plain RPC, not a table write,
  /// because the actual allocation math has to run server-side against
  /// every dimension's sales_forecast rows at once; doing this client-side
  /// would mean fetching every entity's forecast for every dimension just
  /// to recompute what the database can do in one statement.
  ///
  /// Reads Company's own budget_figures rows (already saved by the normal
  /// `setBudgetValue` calls just before this is invoked — see
  /// `_MonthTableState._saveAll`'s doc comment) rather than taking them as
  /// parameters, so this is safe to call any time and always reflects
  /// whatever Company currently has saved, including a 0 (which is what
  /// makes "Company Budget of 0 reverses everything out" work — it's the
  /// same formula, not a separate code path). Returns the number of
  /// entity-level rows written, purely so the caller can show a meaningful
  /// confirmation ("Apportioned to 187 entities") rather than a bare
  /// "Done."
  Future<int> apportionCompanyBudget() async {
    final result = await supabase.rpc('fn_apportion_company_budget');
    return result as int;
  }
}
