-- ============================================================================
-- WyzeSales — Sales Coverage: historical revenue-per-period raw inputs
-- (Supabase / Postgres)
-- ============================================================================
-- Twenty-third migration. Task #93's final shape, after a long pivot away
-- from its original scope — see Wyzesales_Rebuild_Decisions.md Section 55
-- for the full reasoning trail (quotes/sales orders were never reliably
-- captured anywhere, not even in WCSA's own daily-use IQRetail application,
-- so lifecycle-status tracking was dropped entirely in favour of a purely
-- actual-sales-vs-target measure of "gap in sales cover").
--
-- WHAT THIS FEEDS: Performance Analysis's new "R Gap" and "% Coverage
-- Needed" columns, and the Dashboard's company-wide Coverage % tile
-- (replacing the old Quote -> Order Conversion tile, which depended on the
-- same non-existent data this migration's design deliberately avoids).
--
-- R Gap itself needs no new data at all — it's R Target minus R Value,
-- both already on DimensionPerformance (v_dimension_performance /
-- fn_dimension_performance_filtered, schema/002 + schema/021), computed
-- purely at display time in Dart.
--
-- % Coverage Needed is R Gap (for whichever period is currently filtered)
-- divided by that entity's HISTORICAL AVERAGE REVENUE PER PERIOD, i.e.
-- total revenue over its trailing history window divided by how many of
-- those months it actually has sales in ("active months" — months WITH
-- recorded sales, not calendar tenure, since nothing here tracks hire
-- dates). A brand-new entity with under 3 active months falls back to the
-- company-wide equivalent instead (Craig, 2026-09-02: "I like 2. the fall
-- back option and my guess is less than 3 months of history activates the
-- fall back") — the same "target falls back to forecast" shape schema/021
-- already established for Performance Analysis's R Target.
--
-- THIS MIGRATION ONLY RETURNS THE RAW INPUTS (active_months, total_value)
-- — the average, the ratio, the <3-months fallback decision, and the
-- "On Target" / "using team average" display logic all live in Dart
-- (lib/core/utils/sales_coverage.dart, task #101), same as mergeAcrossYears
-- (task #92, performance_rollup.dart) — auditable and unit-testable there,
-- rather than buried in SQL. This mirrors how little SQL surface the final
-- design needs, compared to the 5-view/function chain the original
-- (abandoned) quote/order-lifecycle design would have touched.
--
-- WHY v_dimension_monthly_sales AND NOT THE CROSS-FILTERED CUBE: this is a
-- per-entity's OWN historical average, not a "whatever the user currently
-- has filtered" figure — an entity's coverage baseline shouldn't shift just
-- because someone filtered Performance Analysis down to one branch or item.
-- Deliberately uses the plain (unfiltered-by-the-5-cross-dimension-filters)
-- rollup, same simplification schema/002's view already makes for the
-- "no active filter" common case. A future pass could thread the 5 cross-
-- filters through here the way fn_dimension_monthly_sales_filtered does, if
-- Craig ever wants "coverage within this filtered slice" instead — flagging
-- as an option, not assumed needed now.
--
-- Calling p_dimension = 'company' returns exactly one row, entity_code
-- 'ALL' — v_dimension_monthly_sales already has a 'company' branch (schema/
-- 002 Section 2) for this — which is exactly the fallback row the <3-active-
-- months rule needs. Callers fetch this function twice: once for the
-- screen's actual dimension (every entity's own figures) and once for
-- 'company' (the one fallback row), rather than needing a second function.
-- ============================================================================

create or replace function fn_dimension_sales_history(
  p_dimension text,
  p_fiscal_years int[]
)
returns table (
  entity_code text,
  active_months int,
  total_value numeric
)
language sql stable as $$
  select
    entity_code,
    count(*)::int as active_months,
    sum(value) as total_value
  from v_dimension_monthly_sales
  where dimension = p_dimension
    and (p_fiscal_years is null or fiscal_year = any (p_fiscal_years))
  group by entity_code;
$$;

grant execute on function fn_dimension_sales_history(text, int[]) to authenticated;
