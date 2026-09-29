-- wyzesales_dimension_performance_fiscal_years_window.sql
--
-- Context: Performance Analysis' bare-landing-view default (no Year/Month/
-- Quarter picked) used to secretly narrow to the current fiscal year only —
-- fixed earlier today (Dart-only change, performance_screen.dart's
-- _effectiveFiscalYear/_effectiveFiscalMonth) per Craig's "default to all
-- data" decision. That made fn_dimension_performance_filtered's existing
-- p_fiscal_year=null path (already "every fiscal year on record", no
-- restriction at all) reachable from a bare landing view for the first
-- time.
--
-- Craig then noticed Sales Analysis' Table total no longer matched its
-- Chart tab, and (after comparing real numbers) asked to cap the "no Year
-- filter" default to the client's configured Data History Window (Settings
-- > Company, fiscal_year_settings.history_years, 3 or 5 years) instead of
-- truly unbounded — the same boundary the Chart tab, Sales By, and the
-- Year-filter picker's own data-availability check already use. Sales
-- Analysis' Table got this via a client-side p_from_date lower bound (no
-- migration needed — fn_sales_documents_page/_totals already accept an
-- optional date range; see document_analysis_view.dart's
-- `_effectiveFromDate`). Performance Analysis has no such date-range
-- parameter, but fn_dimension_performance_filtered already delegates its
-- fiscal-year selection straight through to fn_dimension_monthly_sales_
-- filtered's own p_fiscal_years integer[] parameter (rewritten to accept an
-- array in schema/wyzesales_fix_filtered_sales_cube_timeout) — it just
-- never exposed that array to its own callers, only ever passing through a
-- single optional year wrapped in a one-element array.
--
-- Fix: add a new, optional p_fiscal_years integer[] parameter. When given,
-- it's forwarded to fn_dimension_monthly_sales_filtered as-is (taking
-- priority over the existing single p_fiscal_year, which continues to work
-- unchanged for every existing caller — this is purely additive). Dart's
-- fetchDimensionPerformance/performance_screen.dart now pass the client's
-- fiscalYearWindow(...) here whenever no explicit Year is picked, the same
-- window Sales By/the Chart tab already compute.
--
-- Verified (role-impersonated as support+morg, rolled back before the real
-- apply): for Morgenster (fiscal_year_settings.history_years = 5, 6 fiscal
-- years actually on record, 2021-2026):
--   p_fiscal_year=null, p_fiscal_years=null (old/unbounded) -> sum(actual_value) = 187,511,789.66
--     = direct SQL sum of v_sales_documents (invoice+credit_note) across ALL years on record
--   p_fiscal_years=array[2022,2023,2024,2025,2026] (new, windowed)  -> sum(actual_value) = 153,030,385.77
--     = direct SQL sum of v_sales_documents (invoice+credit_note) for exactly that 5-year window
--     = also exactly what Sales Analysis' Chart tab already totals for the same window
-- No changes to fn_dimension_monthly_sales_filtered itself, no RLS/security
-- changes, no changes to any other caller's behavior (every existing call
-- omits p_fiscal_years, so gets the identical single-year/unbounded
-- behavior it always has).
--
-- NOTE: as of this migration, this repo's docs/schema/ convention had
-- drifted out of sync with what was actually applied live for a few prior
-- migrations (the two 2026-09-29 timeout fixes among them) — those were
-- applied directly via the Supabase migration tool but never got a
-- matching doc file committed here. Worth a follow-up cleanup pass; not
-- done as part of this change to keep it focused.

CREATE OR REPLACE FUNCTION public.fn_dimension_performance_filtered(
  p_dimension text,
  p_entity_code text DEFAULT NULL::text,
  p_fiscal_year integer DEFAULT NULL::integer,
  p_fiscal_month text DEFAULT NULL::text,
  p_filters jsonb DEFAULT '{}'::jsonb,
  p_fiscal_quarter_months text[] DEFAULT NULL::text[],
  p_fiscal_years integer[] DEFAULT NULL::integer[]
)
 RETURNS TABLE(dimension text, entity_code text, fiscal_year integer, fiscal_month text, actual_value numeric, actual_quantity numeric, actual_profit numeric, gp_percent numeric, target_value numeric, target_percent numeric, contribution_percent numeric, forecast_value numeric, forecast_confidence text)
 LANGUAGE sql
 STABLE
AS $function$
  with s as (
    select *
    from fn_dimension_monthly_sales_filtered(
      p_dimension,
      p_entity_code,
      case
        when p_fiscal_years is not null then p_fiscal_years
        when p_fiscal_year is not null then array[p_fiscal_year]
        else null
      end,
      p_fiscal_month,
      p_filters,
      p_fiscal_quarter_months
    )
  ),
  monthly as (
    select entity_code, fiscal_year, fiscal_month,
           sum(quantity) as quantity, sum(value) as value, sum(profit) as profit
    from s
    group by entity_code, fiscal_year, fiscal_month
  ),
  base as (
    select
      p_dimension as dimension,
      m.entity_code,
      m.fiscal_year,
      m.fiscal_month,
      m.value as actual_value,
      m.quantity as actual_quantity,
      m.profit as actual_profit,
      case when m.value = 0 then 0 else round(m.profit / m.value * 100, 2) end as gp_percent,
      coalesce(nullif(b.budget_value, 0), f.forecast_value) as target_value,
      round(100.0 * m.value / nullif(sum(m.value) over (partition by m.fiscal_year, m.fiscal_month), 0), 2) as contribution_percent,
      f.forecast_value,
      f.confidence as forecast_confidence
    from monthly m
    left join budget_figures b
      on  b.dimension    = p_dimension
      and b.entity_code  = m.entity_code
      and b.fiscal_month = m.fiscal_month
    left join sales_forecast f
      on  f.dimension    = p_dimension
      and f.entity_code  = m.entity_code
      and f.fiscal_month = m.fiscal_month
  )
  select
    base.dimension,
    base.entity_code,
    base.fiscal_year,
    base.fiscal_month,
    base.actual_value,
    base.actual_quantity,
    base.actual_profit,
    base.gp_percent,
    base.target_value,
    case when base.target_value is null or base.target_value = 0 then null
         else round(base.actual_value / base.target_value * 100, 2)
    end as target_percent,
    base.contribution_percent,
    base.forecast_value,
    base.forecast_confidence
  from base;
$function$;
