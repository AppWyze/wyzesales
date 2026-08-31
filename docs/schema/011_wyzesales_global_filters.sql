-- ============================================================================
-- WyzeSales — global cross-dimension filters (Supabase / Postgres)
-- ============================================================================
-- Eleventh migration. Craig, 2026-08-26: "Selection filters need to be
-- iterative throughout the application. i.e. If I select a sales person on
-- any screen and I navigate to another screen that filtered salesperson
-- must stay filtered and the data accordingly... Multiple filters can be
-- applied at once." Follow-up decision (same day): filter scope is all 5
-- dimensions plus Year and Month "where applicable", and the rollup screens
-- (Dashboard, Sales by [Dimension], Performance, YTD Comparative) should get
-- real cross-dimension filtering support here, not just the 3 line-level
-- screens that already had it via v_sales_documents.
--
-- THE GAP THIS CLOSES: v_dimension_monthly_sales (schema/002 Section 2) is
-- built as a UNION ALL of 5 separately-grouped SELECTs — each branch groups
-- by exactly one dimension's entity_code, so none of them carry any OTHER
-- dimension's code as a queryable column. There was structurally no way to
-- ask that view for "item sales, filtered to one customer" — the customer
-- code isn't a column on the 'item' branch's rows at all. Same story for
-- v_consolidated_sales (no dimension columns whatsoever) and
-- v_dimension_performance (built on top of v_dimension_monthly_sales, so it
-- inherits the same gap).
--
-- THE FIX: v_sales_cube_monthly below is the SAME underlying `base` CTE
-- schema/002 already computes (one row per client/month/fiscal period, with
-- ALL FIVE dimension codes attached at once — resolved_rep_code,
-- account_code, item_code, department_code, branch_code — not just one),
-- turned into its own view instead of being a UNION ALL's throwaway
-- ingredient. Everything else here is three SQL functions that query this
-- one cube with whatever combination of the 5 dimension codes + fiscal
-- year(s) + fiscal month the caller supplies, and group down to whichever
-- single dimension that screen displays (or no dimension at all, for the
-- whole-company case) — mirroring v_dimension_monthly_sales /
-- v_consolidated_sales / v_dimension_performance's existing output shapes
-- exactly, so the existing Dart model classes (DimensionMonthlySales,
-- ConsolidatedSales, DimensionPerformance) read RPC results with no changes
-- needed there.
--
-- Functions, not new views, because a view's GROUP BY is fixed at creation
-- time — there's no way to parameterize "group by whichever dimension the
-- caller asks for" in a plain SQL view the way SalesRepository's existing
-- .eq()-chained queries expect. A `language sql` function with no `security
-- definer` runs as the CALLING role by default (same as this project's
-- existing security_invoker views), so RLS on sales_document_facts still
-- applies per-caller through v_sales_documents -> v_sales_cube_monthly ->
-- these functions, exactly as it does today. No RLS/grants change needed on
-- any existing table.
-- ============================================================================


-- ============================================================================
-- 1. THE CUBE — one row per client / EVERY dimension code / month
-- ============================================================================
-- Restricted to actual sales (invoice/credit_note), matching
-- v_dimension_monthly_sales and v_consolidated_sales. This still collapses
-- real duplicate lines (same rep+customer+item+category+branch+month
-- appearing more than once) via the GROUP BY/sum below — it is NOT the same
-- size as sales_document_facts itself, just finer-grained than the old
-- single-dimension rollup.

create view v_sales_cube_monthly
with (security_invoker = true) as
select
  client_id,
  date_trunc('month', doc_date)::date as month,
  fiscal_year,
  fiscal_month_label(doc_date) as fiscal_month,
  resolved_rep_code as sales_person_code,
  account_code as customer_code,
  item_code,
  department_code as category_code,
  branch_code,
  sum(quantity) as quantity,
  sum(value) as value,
  sum(profit) as profit
from v_sales_documents
where document_kind in ('invoice', 'credit_note')
group by
  client_id, date_trunc('month', doc_date)::date, fiscal_year, fiscal_month_label(doc_date),
  resolved_rep_code, account_code, item_code, department_code, branch_code;


-- ============================================================================
-- 2. fn_dimension_monthly_sales_filtered — replaces a
--    v_dimension_monthly_sales query when any cross-dimension/Month filter
--    is active
-- ============================================================================
-- Same output shape as v_dimension_monthly_sales (dimension, entity_code,
-- month, fiscal_year, fiscal_month, quantity, value, profit) so
-- DimensionMonthlySales.fromMap needs no changes. p_entity_code is the
-- existing "single entity" narrowing SalesRepository.fetchDimensionMonthlySales
-- already supported (Sales Analysis' Graph tab, YTD Comparative's own
-- entity); the five p_filter_* params are new — the OTHER dimensions' global
-- filter values, applied as plain equality filters before the GROUP BY.
--
-- Deliberately not blocked from filtering p_dimension by its own matching
-- p_filter_* value (e.g. p_dimension = 'customer' and p_filter_customer set
-- to the same code) — that just narrows the result to that one entity's row,
-- which is the correct, unsurprising behaviour if a screen's own display
-- dimension happens to also carry an active global filter.

create or replace function fn_dimension_monthly_sales_filtered(
  p_dimension text,
  p_entity_code text default null,
  p_fiscal_years int[] default null,
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
  month date,
  fiscal_year int,
  fiscal_month text,
  quantity numeric,
  value numeric,
  profit numeric
)
language sql stable as $$
  select
    p_dimension as dimension,
    case p_dimension
      when 'sales_person' then sales_person_code
      when 'customer'     then customer_code
      when 'item'         then item_code
      when 'category'     then category_code
      when 'branch'       then branch_code
      else 'ALL'
    end as entity_code,
    c.month, c.fiscal_year, c.fiscal_month,
    sum(c.quantity) as quantity, sum(c.value) as value, sum(c.profit) as profit
  from v_sales_cube_monthly c
  where (p_fiscal_years is null or c.fiscal_year = any (p_fiscal_years))
    and (p_fiscal_month is null or c.fiscal_month = p_fiscal_month)
    and (p_entity_code is null or (
      case p_dimension
        when 'sales_person' then c.sales_person_code
        when 'customer'     then c.customer_code
        when 'item'         then c.item_code
        when 'category'     then c.category_code
        when 'branch'       then c.branch_code
        else 'ALL'
      end) = p_entity_code)
    and (p_filter_sales_person is null or c.sales_person_code = p_filter_sales_person)
    and (p_filter_customer     is null or c.customer_code     = p_filter_customer)
    and (p_filter_item         is null or c.item_code         = p_filter_item)
    and (p_filter_category     is null or c.category_code     = p_filter_category)
    and (p_filter_branch       is null or c.branch_code       = p_filter_branch)
  group by 1, entity_code, c.month, c.fiscal_year, c.fiscal_month;
$$;


-- ============================================================================
-- 3. fn_consolidated_sales_filtered — replaces a v_consolidated_sales query
--    when any dimension/Month filter is active
-- ============================================================================
-- Same output shape as v_consolidated_sales (fiscal_year, month, quantity,
-- value, profit) — no dimension column, since this is the whole-company
-- (or whole-filtered-slice) total. Used by the Dashboard KPI row today;
-- available to Sales Analysis' Graph tab / YTD Comparative too, if a future
-- pass wires filters into those (see Wyzesales_Rebuild_Decisions.md Section
-- 18 for which screens this migration actually wires up in Flutter).

create or replace function fn_consolidated_sales_filtered(
  p_fiscal_years int[] default null,
  p_fiscal_month text default null,
  p_filter_sales_person text default null,
  p_filter_customer text default null,
  p_filter_item text default null,
  p_filter_category text default null,
  p_filter_branch text default null
)
returns table (
  fiscal_year int,
  month date,
  quantity numeric,
  value numeric,
  profit numeric
)
language sql stable as $$
  select c.fiscal_year, c.month, sum(c.quantity) as quantity, sum(c.value) as value, sum(c.profit) as profit
  from v_sales_cube_monthly c
  where (p_fiscal_years is null or c.fiscal_year = any (p_fiscal_years))
    and (p_fiscal_month is null or c.fiscal_month = p_fiscal_month)
    and (p_filter_sales_person is null or c.sales_person_code = p_filter_sales_person)
    and (p_filter_customer     is null or c.customer_code     = p_filter_customer)
    and (p_filter_item         is null or c.item_code         = p_filter_item)
    and (p_filter_category     is null or c.category_code     = p_filter_category)
    and (p_filter_branch       is null or c.branch_code       = p_filter_branch)
  group by c.fiscal_year, c.month;
$$;


-- ============================================================================
-- 4. fn_dimension_performance_filtered — replaces a v_dimension_performance
--    query when any cross-dimension filter is active
-- ============================================================================
-- Reproduces v_dimension_performance's own logic (schema/002 Section 3) —
-- contribution %, target %, GP % — on top of
-- fn_dimension_monthly_sales_filtered's output instead of
-- v_dimension_monthly_sales directly, via the same left joins to
-- budget_figures/sales_forecast. contribution_percent is still computed as
-- a share of THIS filtered slice's total for the period (not the whole
-- company) — consistent with what "% Contribution" should mean once you've
-- already filtered down to (say) one branch: contribution within that
-- branch's own filtered entities, not diluted against company-wide sales
-- the filter deliberately excluded.

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
    -- fn_dimension_monthly_sales_filtered still groups by calendar month —
    -- collapse to one row per entity/fiscal_year/fiscal_month, matching
    -- v_dimension_monthly_sales' own grain before v_dimension_performance
    -- joins against budget_figures/sales_forecast (both one-row-per-
    -- fiscal-month, no calendar-month column at all).
    select entity_code, fiscal_year, fiscal_month,
           sum(quantity) as quantity, sum(value) as value, sum(profit) as profit
    from s
    group by entity_code, fiscal_year, fiscal_month
  )
  select
    p_dimension as dimension,
    m.entity_code,
    m.fiscal_year,
    m.fiscal_month,
    m.value as actual_value,
    m.quantity as actual_quantity,
    m.profit as actual_profit,
    case when m.value = 0 then 0 else round(m.profit / m.value * 100, 2) end as gp_percent,
    b.budget_value as target_value,
    case when b.budget_value is null or b.budget_value = 0 then null
         else round(m.value / b.budget_value * 100, 2)
    end as target_percent,
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
    and f.fiscal_month = m.fiscal_month;
$$;


-- ============================================================================
-- 5. GRANTS
-- ============================================================================
-- Postgres grants EXECUTE on new functions to PUBLIC by default, which would
-- already cover `authenticated` — granted explicitly anyway to match this
-- project's established belt-and-braces convention (schema/007's whole
-- point was "don't rely on an ambient default that happens to work today").
-- v_sales_cube_monthly needs the same explicit SELECT grant schema/007 gives
-- every other security_invoker view, for the same reason documented there.

grant select on v_sales_cube_monthly to authenticated;

grant execute on function fn_dimension_monthly_sales_filtered(
  text, text, int[], text, text, text, text, text, text
) to authenticated;

grant execute on function fn_consolidated_sales_filtered(
  int[], text, text, text, text, text, text
) to authenticated;

grant execute on function fn_dimension_performance_filtered(
  text, text, int, text, text, text, text, text, text
) to authenticated;
