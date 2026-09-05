-- ============================================================================
-- WyzeSales — generalize the 5-dimension cube + filter RPCs to any client_dimensions
-- dimension (Supabase / Postgres)
-- ============================================================================
-- Forty-second migration. Design doc's Step 3: migration 041 generalized RLS
-- so a brand-new client's own dimensions can scope row visibility; this does
-- the equivalent for cross-dimension filtering. Today v_sales_cube_monthly
-- and the four functions built on it (fn_dimension_monthly_sales_filtered,
-- fn_consolidated_sales_filtered, fn_dimension_performance_filtered,
-- fn_dimension_filter_options — all schema/011 + schema/017, with schema/021
-- also touching fn_dimension_performance_filtered's target-value logic) take
-- five hardcoded named parameters (p_filter_sales_person, p_filter_customer,
-- p_filter_item, p_filter_category, p_filter_branch) — a future client's own
-- new dim_N/attr_N dimension (migration 038/039) could already be DISPLAYED
-- on Sales By/Performance via v_dimension_monthly_sales' generic UNION ALL
-- branches, but could never be used to CROSS-FILTER the other four, and
-- could never itself be narrowed by one of the five hardcoded filters. Same
-- gap Craig described for RLS in migration 041, just one layer up.
--
-- THE FIX: all five hardcoded p_filter_* parameters collapse into one
-- `p_filters jsonb` map, keyed by dimension_key ('sales_person', 'branch',
-- 'dim_7', ...) with the filter's active entity_code as the value — this is
-- the exact same shape GlobalFilters' own dimension map already holds
-- (lib/core/filters/global_filters.dart, Step 2), so the Dart repository
-- layer's job becomes "pass the map through," not "build five named
-- arguments." A dimension key simply absent from the map means "no filter on
-- that dimension" (never send a JSON null for an inactive filter — see
-- fn_row_matches_filters below for why a stray null is still handled safely
-- rather than assumed impossible).
--
-- Resolving an arbitrary dimension_key to its physical value on a cube row
-- reuses migration 041's own trick (`to_jsonb(row) ->> column_name`) via one
-- new helper, fn_cube_dimension_value:
--   - WCSA's five existing dimensions' cube columns are already named exactly
--     dimension_key || '_code' (sales_person_code, customer_code, item_code,
--     category_code, branch_code) — this convention was already true before
--     this migration, just never exploited generically.
--   - A 'fact_column' dimension's generic column is literally dim_N_code,
--     and its dimension_key is literally 'dim_N' — same convention, no
--     special-casing needed.
--   - A 'customer_attribute' dimension's column is attr_N_code but its
--     dimension_key is still 'dim_N' — the one real translation needed,
--     mirroring migration 041's identical dim_/attr_ substitution.
--   - 'company' is the one true special case, exactly as it was in the old
--     hardcoded `case ... else 'ALL' end` — it's a whole-company pseudo-
--     dimension with no physical column at all, on every client, so it's
--     matched by dimension_key rather than resolution_kind.
--
-- A second helper, fn_row_matches_filters, applies an entire p_filters map to
-- one cube row at once (every key must match, same AND-of-equalities the old
-- five `p_filter_x is null or c.x = p_filter_x` lines expressed) — one place
-- for that logic instead of repeating it in all four functions.
--
-- v_sales_cube_monthly itself gains the same 24 generic columns
-- v_sales_documents already exposes (migration 039), appended after `profit`
-- since `create or replace view` only allows appending, never inserting or
-- reordering. Appending more GROUP BY columns makes the cube's own grain
-- finer (a client's dim_7/attr_3/etc. can now split what used to be one
-- grouped row into several), but every caller re-aggregates with SUM after
-- filtering, and SUM over a finer partition equals SUM over the coarser one
-- it's part of — so this changes nothing about any total any screen shows.
-- WCSA has no data in any dim_N_code/attr_N_code column (migration 039's own
-- comment: "all new columns are nullable and additive... changes nothing
-- about how WCSA behaves"), so this migration keeps that same guarantee.
--
-- Every one of the four functions gets an explicit `drop function if exists`
-- for its OLD five-named-parameter signature before its `create or replace`
-- with the new p_filters-jsonb signature — changing a function's parameter
-- list without dropping the old signature first leaves Postgres with two
-- overloads instead of one replacement, which is exactly the stale-overload
-- trap this project's own schema/041 write-up already flagged as a risk to
-- avoid.
--
-- fn_dimension_performance_filtered keeps schema/021's later target-value
-- logic (coalesce budget with seasonal forecast when budget is absent/zero)
-- untouched beyond the parameter swap — this migration is pure signature
-- generalization, not a second behaviour change layered on top.
--
-- OUT OF SCOPE, DEFERRED (flagged, not silently touched here):
--   - fn_sales_documents_page / fn_sales_documents_totals (schema/012, the
--     line-level Sales Analysis Table tab) query v_sales_documents directly
--     using ITS OWN native column names for the five existing dimensions
--     (account_code, resolved_rep_code, department_code — not the cube's
--     renamed customer_code/sales_person_code/category_code), a different
--     enough convention that generalizing them needs its own follow-up
--     rather than reusing fn_cube_dimension_value as-is.
--   - A pre-existing, unrelated gap noticed while reading through dependency
--     history for this migration: migration 039's own `create or replace
--     view v_sales_documents` (Section 3) reproduced schema/001's original
--     column list rather than migration 024's later one, so the three
--     `coalesce(..., 'UNASSIGNED')` guards migration 024 added (for
--     resolved_rep_code/branch_code/department_code, to stop a genuinely
--     unattributed line from crashing DimensionMonthlySales.fromMap's
--     non-nullable cast) are currently NOT present in v_sales_documents.
--     WCSA's own seed data (schema/010) never produces a row with a null
--     rep/branch/department in the first place, so this hasn't shown up as a
--     visible bug — but it means migration 024's fix has quietly regressed.
--     Not fixed here (touching v_sales_documents again is a separate
--     concern, unrelated to generalizing filters, and would be its own
--     zero-behaviour-change exercise to verify) — flagged for a follow-up
--     migration instead.
-- ============================================================================


-- ============================================================================
-- 1. v_sales_cube_monthly — append the 24 generic dimension columns
-- ============================================================================

create or replace view v_sales_cube_monthly
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
  sum(profit) as profit,
  dim_1_code, dim_2_code, dim_3_code, dim_4_code, dim_5_code, dim_6_code,
  dim_7_code, dim_8_code, dim_9_code, dim_10_code, dim_11_code, dim_12_code,
  attr_1_code, attr_2_code, attr_3_code, attr_4_code, attr_5_code, attr_6_code,
  attr_7_code, attr_8_code, attr_9_code, attr_10_code, attr_11_code, attr_12_code
from v_sales_documents
where document_kind in ('invoice', 'credit_note')
group by
  client_id, date_trunc('month', doc_date)::date, fiscal_year, fiscal_month_label(doc_date),
  resolved_rep_code, account_code, item_code, department_code, branch_code,
  dim_1_code, dim_2_code, dim_3_code, dim_4_code, dim_5_code, dim_6_code,
  dim_7_code, dim_8_code, dim_9_code, dim_10_code, dim_11_code, dim_12_code,
  attr_1_code, attr_2_code, attr_3_code, attr_4_code, attr_5_code, attr_6_code,
  attr_7_code, attr_8_code, attr_9_code, attr_10_code, attr_11_code, attr_12_code;


-- ============================================================================
-- 2. Drop the four functions' OLD five-named-parameter signatures
-- ============================================================================
-- Dependency order matters: fn_dimension_performance_filtered calls
-- fn_dimension_monthly_sales_filtered internally, so it must be dropped
-- first (nothing here still needs to call the old signature after this
-- point in the migration).

drop function if exists fn_dimension_performance_filtered(
  text, text, int, text, text, text, text, text, text
);

drop function if exists fn_dimension_monthly_sales_filtered(
  text, text, int[], text, text, text, text, text, text
);

drop function if exists fn_consolidated_sales_filtered(
  int[], text, text, text, text, text, text
);

drop function if exists fn_dimension_filter_options(
  text, int, text, text, text, text, text, text
);


-- ============================================================================
-- 3. fn_cube_dimension_value — resolve any dimension_key to its value on one
--    cube row
-- ============================================================================

create or replace function fn_cube_dimension_value(
  c v_sales_cube_monthly,
  p_dimension_key text,
  p_resolution_kind text
)
returns text
language sql immutable as $$
  select case
    when p_dimension_key = 'company' then 'ALL'
    when p_resolution_kind = 'customer_attribute'
      then to_jsonb(c) ->> (replace(p_dimension_key, 'dim_', 'attr_') || '_code')
    else to_jsonb(c) ->> (p_dimension_key || '_code')
  end;
$$;

grant execute on function fn_cube_dimension_value(v_sales_cube_monthly, text, text) to authenticated;


-- ============================================================================
-- 4. fn_row_matches_filters — does one cube row satisfy an entire p_filters map
-- ============================================================================
-- `jsonb_strip_nulls` defends against a stray JSON null slipping into the map
-- for an inactive filter (which would otherwise mean "match only rows where
-- this dimension's value is itself null," not "no filter") — the intended
-- convention is that an inactive dimension is simply absent from the map
-- entirely, matching how GlobalFilters' own dimension map already only ever
-- holds active filters. An unrecognized dimension_key (no matching
-- client_dimensions row for this row's own client_id) is silently ignored
-- rather than treated as a non-match, the same "don't blow up on an unknown
-- key" posture as every `p_filter_x is null or ...` check it replaces.

create or replace function fn_row_matches_filters(
  c v_sales_cube_monthly,
  p_filters jsonb
)
returns boolean
language sql stable as $$
  select not exists (
    select 1
    from jsonb_each_text(coalesce(jsonb_strip_nulls(p_filters), '{}'::jsonb)) as f(dimension_key, filter_value)
    join client_dimensions cd
      on cd.client_id = c.client_id and cd.dimension_key = f.dimension_key
    where fn_cube_dimension_value(c, f.dimension_key, cd.resolution_kind) is distinct from f.filter_value
  );
$$;

grant execute on function fn_row_matches_filters(v_sales_cube_monthly, jsonb) to authenticated;


-- ============================================================================
-- 5. fn_dimension_monthly_sales_filtered — p_filters jsonb replaces the five
--    named p_filter_* parameters
-- ============================================================================
-- Same output shape as before (and as v_dimension_monthly_sales), so
-- DimensionMonthlySales.fromMap needs no changes. p_entity_code is still its
-- own explicit parameter (the existing "single entity" narrowing, e.g. Sales
-- Analysis' Graph tab / YTD Comparative's own entity) — deliberately kept
-- separate from p_filters, matching how it was always independent of the
-- other dimensions' own filter values. A p_filters entry for p_dimension
-- itself is still allowed and still applied, exactly as before ("Deliberately
-- not blocked from filtering p_dimension by its own matching p_filter_*
-- value" — schema/011's own comment; same unsurprising behaviour, now keyed
-- through the map instead of a same-named parameter).

create or replace function fn_dimension_monthly_sales_filtered(
  p_dimension text,
  p_entity_code text default null,
  p_fiscal_years int[] default null,
  p_fiscal_month text default null,
  p_filters jsonb default '{}'::jsonb
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
    fn_cube_dimension_value(c, p_dimension, cd.resolution_kind) as entity_code,
    c.month, c.fiscal_year, c.fiscal_month,
    sum(c.quantity) as quantity, sum(c.value) as value, sum(c.profit) as profit
  from v_sales_cube_monthly c
  join client_dimensions cd
    on cd.client_id = c.client_id and cd.dimension_key = p_dimension
  where (p_fiscal_years is null or c.fiscal_year = any (p_fiscal_years))
    and (p_fiscal_month is null or c.fiscal_month = p_fiscal_month)
    and (p_entity_code is null or fn_cube_dimension_value(c, p_dimension, cd.resolution_kind) = p_entity_code)
    and fn_row_matches_filters(c, p_filters)
  group by 1, entity_code, c.month, c.fiscal_year, c.fiscal_month;
$$;

grant execute on function fn_dimension_monthly_sales_filtered(
  text, text, int[], text, jsonb
) to authenticated;


-- ============================================================================
-- 6. fn_consolidated_sales_filtered — p_filters jsonb replaces the five
--    named p_filter_* parameters
-- ============================================================================

create or replace function fn_consolidated_sales_filtered(
  p_fiscal_years int[] default null,
  p_fiscal_month text default null,
  p_filters jsonb default '{}'::jsonb
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
    and fn_row_matches_filters(c, p_filters)
  group by c.fiscal_year, c.month;
$$;

grant execute on function fn_consolidated_sales_filtered(
  int[], text, jsonb
) to authenticated;


-- ============================================================================
-- 7. fn_dimension_performance_filtered — p_filters jsonb replaces the five
--    named p_filter_* parameters; target-value logic unchanged from schema/021
-- ============================================================================

create or replace function fn_dimension_performance_filtered(
  p_dimension text,
  p_entity_code text default null,
  p_fiscal_year int default null,
  p_fiscal_month text default null,
  p_filters jsonb default '{}'::jsonb
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
      p_filters
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
  text, text, int, text, jsonb
) to authenticated;


-- ============================================================================
-- 8. fn_dimension_filter_options — p_filters jsonb replaces the five named
--    p_filter_* parameters
-- ============================================================================
-- p_dimension's own current filter value is still deliberately not one of
-- this function's parameters at all (unchanged from schema/017) — the Dart
-- caller omits p_dimension's own key from p_filters when asking which OTHER
-- values remain available for it, so picking a new value for a dimension is
-- never constrained by whichever value is already active for that same
-- dimension.

create or replace function fn_dimension_filter_options(
  p_dimension text,
  p_fiscal_year int default null,
  p_fiscal_month text default null,
  p_filters jsonb default '{}'::jsonb
)
returns table (entity_code text)
language sql stable as $$
  select distinct fn_cube_dimension_value(c, p_dimension, cd.resolution_kind) as entity_code
  from v_sales_cube_monthly c
  join client_dimensions cd
    on cd.client_id = c.client_id and cd.dimension_key = p_dimension
  where (p_fiscal_year  is null or c.fiscal_year  = p_fiscal_year)
    and (p_fiscal_month is null or c.fiscal_month = p_fiscal_month)
    and fn_row_matches_filters(c, p_filters)
$$;

grant execute on function fn_dimension_filter_options(
  text, int, text, jsonb
) to authenticated;
