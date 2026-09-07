-- ============================================================================
-- WyzeSales — Quarter as a global filter, offered the same way as Year/Month
-- ============================================================================
-- Forty-seventh migration. Craig, 2026-09-07: "We need to talk about
-- Quarter? This needs to be built in an offered to all clients the same way
-- as Year and Month work." Confirmed FISCAL quarter (Q1 = each client's own
-- first 3 fiscal months, from fiscal_year_settings.start_month), matching
-- how Year/Month are already fiscal-anchored, not calendar quarters.
--
-- DESIGN: every RPC function that already takes a `p_fiscal_month text`
-- exact-match parameter (Sales By/Dashboard's fn_dimension_monthly_sales_
-- filtered, fn_consolidated_sales_filtered; Performance's fn_dimension_
-- performance_filtered; the "which filter values remain available" greying
-- logic's fn_dimension_filter_options; Document Analysis/Quote/Sales Order
-- Analysis's fn_sales_documents_page/fn_sales_documents_totals) gains ONE
-- new, purely ADDITIVE parameter: `p_fiscal_quarter_months text[] default
-- null`. A caller wanting Quarter filtering resolves the quarter to its 3
-- fiscal month labels client-side (fiscalMonthsInQuarter, fiscal.dart —
-- GlobalFilters.fiscalQuarterMonths already carries this, resolved once at
-- selection time) and passes that list; the function matches with
-- `fiscal_month = any(p_fiscal_quarter_months)` alongside the existing
-- `fiscal_month = p_fiscal_month` exact-match check, ANDed together (both
-- default null/no-op, so passing only one of the two behaves exactly as
-- before this migration — Month and Quarter are also kept mutually
-- exclusive at the point of selection app-side, so in practice at most one
-- of the two is ever actually active on a given call).
--
-- WHY ADDITIVE, NOT WIDENING p_fiscal_month ITSELF: p_fiscal_month text
-- (single exact-match) appears on a dozen-plus functions across schema/011
-- through schema/042; widening every one of them to accept an array instead
-- (`p_fiscal_month text[]`, `= any(...)`) would touch far more surface than
-- Quarter actually needs, when only the six functions actually exercised by
-- the app today (confirmed by grepping every live `.rpc(...)` call site in
-- lib/) need it at all.
--
-- IMPORTANT CORRECTION, caught while verifying this migration against the
-- local shadow DB before delivering it: appending a new, defaulted trailing
-- parameter is NOT something `CREATE OR REPLACE FUNCTION` can do in place —
-- an earlier draft of this migration's own comment claimed it could,
-- confidently and wrongly. Postgres identifies a function by name + the
-- FULL LIST of its parameter TYPES; adding one more parameter changes that
-- identity, so `CREATE OR REPLACE FUNCTION` with one more parameter than the
-- existing function creates a SECOND, overloaded function sitting alongside
-- the original rather than replacing it — confirmed empirically (`\df
-- fn_consolidated_sales_filtered` showed two rows after a naive `create or
-- replace`). With both the old (5-parameter, say) and new (6-parameter)
-- overloads present and every added parameter defaulted, ANY call that omits
-- naming the new parameter becomes genuinely ambiguous between the two —
-- `fn_consolidated_sales_filtered(p_fiscal_years => array[2026])` errored
-- with "is not unique" against exactly this shape in testing. Every one of
-- this app's own Dart call sites is updated (this same commit) to always
-- name the new parameter explicitly, even when passing null — but leaving
-- BOTH overloads on the server rather than replacing outright is a fragile,
-- easy-to-mistrigger footgun for zero benefit, and not something to leave
-- lying around for a future migration to rediscover the hard way.
--
-- Fix: each function below is explicitly `drop function if exists
-- <old signature>` immediately before its `create or replace function`, so
-- only the new, single signature survives — a real drop+create, not the
-- in-place replace the original draft assumed. This is exactly the kind of
-- "duplicate overload" risk schema/013's own header comment already flagged
-- awareness of for a same-name signature change; the fix here is the same
-- one that comment describes avoiding by NOT changing shape when it isn't
-- necessary — this migration needs the shape to change, so it pays that cost
-- explicitly instead of stumbling into it silently.
--
-- Two RPC functions Year/Month also apply to, `fn_dimension_monthly_sales`/
-- `fn_consolidated_sales` (schema/011, unfiltered variants), are NOT touched
-- here — grepping every `.rpc('fn_dimension_monthly_sales'...)`/
-- `.rpc('fn_consolidated_sales'...)` call site in lib/ confirms only the
-- `_filtered` variants (schema/042) are actually called from the app today;
-- the older unfiltered ones are already-dead code this migration doesn't
-- need to touch. Likewise `fn_document_counts` (schema/015) — its own
-- SalesRepository caller was removed 2026-09-02 (task #93/#103); left alone
-- here for the same reason.
-- ============================================================================


-- ============================================================================
-- 1. fn_dimension_monthly_sales_filtered (schema/042) — Sales By, the
--    Dashboard's per-dimension breakdown, and (via #3 below) Performance.
-- ============================================================================

drop function if exists fn_dimension_monthly_sales_filtered(text, text, int[], text, jsonb);

create or replace function fn_dimension_monthly_sales_filtered(
  p_dimension text,
  p_entity_code text default null,
  p_fiscal_years int[] default null,
  p_fiscal_month text default null,
  p_filters jsonb default '{}'::jsonb,
  p_fiscal_quarter_months text[] default null
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
    and (p_fiscal_quarter_months is null or c.fiscal_month = any (p_fiscal_quarter_months))
    and (p_entity_code is null or fn_cube_dimension_value(c, p_dimension, cd.resolution_kind) = p_entity_code)
    and fn_row_matches_filters(c, p_filters)
  group by 1, entity_code, c.month, c.fiscal_year, c.fiscal_month;
$$;

grant execute on function fn_dimension_monthly_sales_filtered(
  text, text, int[], text, jsonb, text[]
) to authenticated;


-- ============================================================================
-- 2. fn_consolidated_sales_filtered (schema/042) — Sales Analysis' Graph
--    tab, YTD Comparative, the Dashboard's whole-company trend.
-- ============================================================================

drop function if exists fn_consolidated_sales_filtered(int[], text, jsonb);

create or replace function fn_consolidated_sales_filtered(
  p_fiscal_years int[] default null,
  p_fiscal_month text default null,
  p_filters jsonb default '{}'::jsonb,
  p_fiscal_quarter_months text[] default null
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
    and (p_fiscal_quarter_months is null or c.fiscal_month = any (p_fiscal_quarter_months))
    and fn_row_matches_filters(c, p_filters)
  group by c.fiscal_year, c.month;
$$;

grant execute on function fn_consolidated_sales_filtered(
  int[], text, jsonb, text[]
) to authenticated;


-- ============================================================================
-- 3. fn_dimension_performance_filtered (schema/042) — Performance Analysis.
--    Delegates to #1 above, so its own new parameter just passes straight
--    through, same as p_fiscal_month already does.
-- ============================================================================

drop function if exists fn_dimension_performance_filtered(text, text, int, text, jsonb);

create or replace function fn_dimension_performance_filtered(
  p_dimension text,
  p_entity_code text default null,
  p_fiscal_year int default null,
  p_fiscal_month text default null,
  p_filters jsonb default '{}'::jsonb,
  p_fiscal_quarter_months text[] default null
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
$$;

grant execute on function fn_dimension_performance_filtered(
  text, text, int, text, jsonb, text[]
) to authenticated;


-- ============================================================================
-- 4. fn_dimension_filter_options (schema/017/042) — "which values remain
--    available" greying for every OTHER dimension's own picker.
-- ============================================================================

drop function if exists fn_dimension_filter_options(text, int, text, jsonb);

create or replace function fn_dimension_filter_options(
  p_dimension text,
  p_fiscal_year int default null,
  p_fiscal_month text default null,
  p_filters jsonb default '{}'::jsonb,
  p_fiscal_quarter_months text[] default null
)
returns table (entity_code text)
language sql stable as $$
  select distinct fn_cube_dimension_value(c, p_dimension, cd.resolution_kind) as entity_code
  from v_sales_cube_monthly c
  join client_dimensions cd
    on cd.client_id = c.client_id and cd.dimension_key = p_dimension
  where (p_fiscal_year  is null or c.fiscal_year  = p_fiscal_year)
    and (p_fiscal_month is null or c.fiscal_month = p_fiscal_month)
    and (p_fiscal_quarter_months is null or c.fiscal_month = any (p_fiscal_quarter_months))
    and fn_row_matches_filters(c, p_filters)
$$;

grant execute on function fn_dimension_filter_options(
  text, int, text, jsonb, text[]
) to authenticated;


-- ============================================================================
-- 5. fn_sales_documents_page (schema/012/013/014) — Sales/Quote/Sales Order
--    Analysis' Table tab, one page at a time. `language plpgsql` with a
--    dynamic `format()`/`using` query — the new parameter is appended to
--    BOTH the declared parameter list and the `using` list (becoming a new,
--    12th `$` placeholder the existing $1-$11 don't need to renumber for),
--    same "add at the end" approach as everywhere else in this migration.
-- ============================================================================

drop function if exists fn_sales_documents_page(text[], int, text, text, text, text, text, text, text, text, boolean, int, int);

create or replace function fn_sales_documents_page(
  p_document_kinds text[],
  p_fiscal_year int default null,
  p_fiscal_month text default null,
  p_category text default null,
  p_item text default null,
  p_rep text default null,
  p_branch text default null,
  p_customer text default null,
  p_document text default null,
  p_sort_column text default 'doc_date',
  p_sort_ascending boolean default false,
  p_limit int default 100,
  p_offset int default 0,
  p_fiscal_quarter_months text[] default null
)
returns table (
  document_kind text,
  document text,
  doc_date date,
  fiscal_year int,
  account_code text,
  customer_name text,
  resolved_rep_code text,
  resolved_rep_name text,
  branch_code text,
  branch_display_code text,
  branch_name text,
  item_code text,
  item_name text,
  department_code text,
  category_name text,
  quantity numeric,
  value numeric,
  cost numeric,
  profit numeric,
  profit_percent numeric
)
language plpgsql stable as $$
declare
  v_sort_expr text;
  v_direction text := case when p_sort_ascending then 'asc' else 'desc' end;
begin
  v_sort_expr := case p_sort_column
    when 'document'       then 'v.document'
    when 'document_kind'  then 'v.document_kind::text'
    when 'doc_date'       then 'v.doc_date'
    when 'sales_person'   then 'coalesce(v.resolved_rep_name, v.resolved_rep_code, '''')'
    when 'branch'         then 'coalesce(v.branch_display_code, v.branch_code, '''')'
    when 'category'       then 'coalesce(v.category_name, v.department_code, '''')'
    when 'item'           then 'coalesce(v.item_name, v.item_code)'
    when 'customer'       then 'coalesce(v.customer_name, v.account_code)'
    when 'quantity'       then 'v.quantity'
    when 'value'          then 'v.value'
    when 'profit'         then 'v.profit'
    when 'profit_percent' then 'v.profit_percent'
    else 'v.doc_date'
  end;

  return query execute format(
    $q$
      select
        v.document_kind::text, v.document, v.doc_date, v.fiscal_year, v.account_code, v.customer_name,
        v.resolved_rep_code, v.resolved_rep_name, v.branch_code, v.branch_display_code, v.branch_name,
        v.item_code, v.item_name, v.department_code, v.category_name,
        v.quantity, v.value, v.cost, v.profit, v.profit_percent
      from v_sales_documents v
      where v.document_kind::text = any ($1)
        and ($2  is null or v.fiscal_year = $2)
        and ($3  is null or fiscal_month_label(v.doc_date) = $3)
        and ($4  is null or v.department_code  = $4)
        and ($5  is null or v.item_code         = $5)
        and ($6  is null or v.resolved_rep_code = $6)
        and ($7  is null or v.branch_code       = $7)
        and ($8  is null or v.account_code      = $8)
        and ($9  is null or v.document ilike '%%' || $9 || '%%')
        and ($12 is null or fiscal_month_label(v.doc_date) = any ($12))
      order by %s %s nulls last
      limit $10 offset $11
    $q$,
    v_sort_expr, v_direction
  )
  using p_document_kinds, p_fiscal_year, p_fiscal_month, p_category, p_item,
        p_rep, p_branch, p_customer, p_document, p_limit, p_offset, p_fiscal_quarter_months;
end;
$$;

grant execute on function fn_sales_documents_page(
  text[], int, text, text, text, text, text, text, text, text, boolean, int, int, text[]
) to authenticated;


-- ============================================================================
-- 6. fn_sales_documents_totals (schema/012) — the same screens' Totals row
--    and "Showing X-Y of Z" indicator. Plain `language sql`, so the new
--    parameter is referenced by name, no `$N`/`using` bookkeeping needed.
-- ============================================================================

drop function if exists fn_sales_documents_totals(text[], int, text, text, text, text, text, text, text);

create or replace function fn_sales_documents_totals(
  p_document_kinds text[],
  p_fiscal_year int default null,
  p_fiscal_month text default null,
  p_category text default null,
  p_item text default null,
  p_rep text default null,
  p_branch text default null,
  p_customer text default null,
  p_document text default null,
  p_fiscal_quarter_months text[] default null
)
returns table (
  total_count bigint,
  total_quantity numeric,
  total_value numeric,
  total_profit numeric
)
language sql stable as $$
  select
    count(*) as total_count,
    coalesce(sum(v.quantity), 0) as total_quantity,
    coalesce(sum(v.value), 0)    as total_value,
    coalesce(sum(v.profit), 0)   as total_profit
  from v_sales_documents v
  where v.document_kind::text = any (p_document_kinds)
    and (p_fiscal_year  is null or v.fiscal_year = p_fiscal_year)
    and (p_fiscal_month is null or fiscal_month_label(v.doc_date) = p_fiscal_month)
    and (p_fiscal_quarter_months is null or fiscal_month_label(v.doc_date) = any (p_fiscal_quarter_months))
    and (p_category is null or v.department_code    = p_category)
    and (p_item     is null or v.item_code           = p_item)
    and (p_rep      is null or v.resolved_rep_code   = p_rep)
    and (p_branch   is null or v.branch_code         = p_branch)
    and (p_customer is null or v.account_code        = p_customer)
    and (p_document is null or v.document ilike '%' || p_document || '%');
$$;

grant execute on function fn_sales_documents_totals(
  text[], int, text, text, text, text, text, text, text, text[]
) to authenticated;
