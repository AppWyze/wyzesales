-- ============================================================================
-- WyzeSales — Performance target falls back to Seasonal Forecast (Supabase / Postgres)
-- ============================================================================
-- Twenty-first migration. Craig, 2026-09-01, looking at the Budgets — Sales
-- Person screen: "If there is no inputted value for Budget then the
-- Seasonal Forecast value must be used in these calculations." "These
-- calculations" = Performance Analysis's R Target/%Target, the feature this
-- session was already mid-redesign on (the multi-year merge for a bare
-- Month filter — see Wyzesales_Rebuild_Decisions.md Sections 51-52).
--
-- budget_figures.budget_value is `not null default 0` (schema/001) and the
-- Budgets screen itself already collapses "no row on record" to a displayed
-- 0 (`widget.data.budget[month] ?? 0`) — there is no way anywhere in this
-- app to distinguish "adminuser explicitly typed 0" from "never entered
-- anything," so "not populated" is defined the only way it CAN be here:
-- budget_value is null (no row at all) or budget_value = 0.
--
-- THE FIX: both v_dimension_performance (schema/002 Section 3, the plain
-- view path SalesRepository.fetchDimensionPerformance uses whenever none of
-- the 5 cross-dimension filters are active — i.e. the common case, Month-
-- only or Year+Month with no other filter) and fn_dimension_performance_
-- filtered (schema/011, used the moment any of those 5 filters is also
-- active) need the identical change, since Performance Analysis routes
-- between the two silently depending on which filters happen to be set —
-- fixing only one would leave the other still budget-only, and Craig's own
-- testing this session has been almost entirely against the plain-view path
-- (no dimension filter active, just Month).
--
-- Both objects already LEFT JOIN sales_forecast (`f`) — it was already being
-- fetched and carried all the way to the Dart model's forecastValue field,
-- just never substituted in for a missing target anywhere. `target_value`
-- becomes `coalesce(nullif(b.budget_value, 0), f.forecast_value)`;
-- `target_percent` is recomputed from that same resolved figure instead of
-- `b.budget_value` directly, restructured through a subquery/CTE so the
-- coalesce expression isn't repeated three times over. `forecast_value` and
-- `forecast_confidence` stay in the output unchanged (still separately
-- readable, e.g. if a future pass wants to show "target sourced from
-- forecast" in the UI) — this migration only changes what target_value/
-- target_percent resolve TO, not what raw columns are returned.
-- ============================================================================


-- ============================================================================
-- 1. v_dimension_performance — plain view path (no cross-dimension filter)
-- ============================================================================

create or replace view v_dimension_performance
with (security_invoker = true) as
select
  base.client_id,
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
from (
  select
    s.client_id,
    s.dimension,
    s.entity_code,
    s.fiscal_year,
    s.fiscal_month,
    s.value as actual_value,
    s.quantity as actual_quantity,
    s.profit as actual_profit,
    case when s.value = 0 then 0
         else round(s.profit / s.value * 100, 2)
    end as gp_percent,
    coalesce(nullif(b.budget_value, 0), f.forecast_value) as target_value,
    round(
      100.0 * s.value / nullif(
        sum(s.value) over (partition by s.client_id, s.dimension, s.fiscal_year, s.fiscal_month),
        0),
      2
    ) as contribution_percent,
    f.forecast_value,
    f.confidence as forecast_confidence
  from v_dimension_monthly_sales s
  left join budget_figures b
    on  b.client_id    = s.client_id
    and b.dimension    = s.dimension
    and b.entity_code  = s.entity_code
    and b.fiscal_month = s.fiscal_month
  left join sales_forecast f
    on  f.client_id    = s.client_id
    and f.dimension    = s.dimension
    and f.entity_code  = s.entity_code
    and f.fiscal_month = s.fiscal_month
) base;

grant select on v_dimension_performance to authenticated;


-- ============================================================================
-- 2. fn_dimension_performance_filtered — RPC path (any cross-dimension filter active)
-- ============================================================================

create or replace function fn_dimension_performance_filtered(
  p_dimension text,
  p_entity_code text default null,
  p_fiscal_year int default null,
  p_fiscal_month text default null,
  p_filter_sales_person text default null,
  p_filter_customer text default null,
  p_filter_item text default null,
  p_filter_category text default null,
  p_filter_branch text default null
)
returns table (
  dimension text,
  entity_code text,
  fiscal_year int,
  fiscal_month text,
  actual_value numeric,
  actual_quantity numeric,
  actual_profit numeric,
  gp_percent numeric,
  target_value numeric,
  target_percent numeric,
  contribution_percent numeric,
  forecast_value numeric,
  forecast_confidence text
)
language sql stable as $$
  with s as (
    select *
    from fn_dimension_monthly_sales_filtered(
      p_dimension,
      p_entity_code,
      case when p_fiscal_year is null then null else array[p_fiscal_year] end,
      p_fiscal_month,
      p_filter_sales_person, p_filter_customer, p_filter_item, p_filter_category, p_filter_branch
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
$$;

grant execute on function fn_dimension_performance_filtered(
  text, text, int, text, text, text, text, text, text
) to authenticated;
