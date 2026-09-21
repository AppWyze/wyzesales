-- ============================================================================
-- WyzeSales — custom date-range filter for Sales Analysis (Table + Chart)
-- ============================================================================
-- Fifty-fifth migration. Craig, 2026-09-21, relaying feedback from Edgetec
-- after presenting the new app: alongside Month/Year/Quarter, they want a
-- genuine "from date to date" filter. Scoped to Sales Analysis only (Table
-- and Chart tabs) — confirmed with Craig that Dashboard/Budgets/Performance/
-- Sales By/YTD Comparative don't need this, and for good reason: those all
-- read from the monthly-pre-aggregated rollup views (v_dimension_monthly_
-- sales, v_consolidated_sales, v_dimension_performance — schema/002), which
-- carry no day-level detail to filter by at all. Only v_sales_documents (the
-- line-item view Sales Analysis' Table already reads via fn_sales_documents_
-- page/_totals, schema/012, generalized by migration 050) has a real per-row
-- doc_date, so this migration touches only that pair of functions plus one
-- new one for the Chart tab's monthly-bucketed range view.
--
-- THE FIX:
--   1. fn_sales_documents_page / fn_sales_documents_totals: gain
--      p_from_date/p_to_date (both `date default null`, appended at the very
--      end — same "append, never reorder" convention every prior migration
--      here follows), each independently optional so a caller can filter by
--      just one bound if it ever needs to. When both are null (every
--      existing caller, today), behaviour is byte-for-byte unchanged — the
--      added WHERE clause is a no-op. Dropped before CREATE, not a plain
--      `create or replace` — adding a parameter changes the function's
--      identity for Postgres' overload resolution, the exact trap migration
--      050's own header flagged.
--   2. fn_sales_documents_monthly_totals — new. The Chart tab, under a date
--      range, doesn't compare fiscal years the way its normal trailing-3-
--      year view does (there's no sensible year-over-year reading of an
--      arbitrary date span) — instead it shows ONE line, bucketed by
--      calendar month, correctly PARTIAL at the two ends: Craig, 2026-09-21,
--      "if the range is mar 15 2026 to june 12 2026 then show the partial
--      data for March and the partial data for june and the full data for
--      the in between." A plain `date_trunc('month', doc_date)` GROUP BY
--      does exactly that automatically, since the WHERE clause already
--      restricts doc_date to the picked range — March's bucket only ever
--      sums the rows that exist from the 15th onward, June's only up to the
--      12th, nothing extra needed to special-case the boundary months.
--      Returns one row per calendar month touched by the range (sparse — a
--      month with zero matching rows simply has no row, same convention
--      v_dimension_monthly_sales/v_consolidated_sales already use, per that
--      view's own header comment), so it's built as an aggregate query of
--      its own rather than trying to force the range through the existing
--      fiscal-year-shaped fn_consolidated_sales_filtered.
-- ============================================================================


-- ============================================================================
-- 1. fn_sales_documents_page — p_from_date/p_to_date appended.
-- ============================================================================

drop function if exists fn_sales_documents_page(text[], int, text, jsonb, text, text, boolean, int, int, text[]);

create or replace function fn_sales_documents_page(
  p_document_kinds text[],
  p_fiscal_year int default null,
  p_fiscal_month text default null,
  p_filters jsonb default '{}'::jsonb,
  p_document text default null,
  p_sort_column text default 'doc_date',
  p_sort_ascending boolean default false,
  p_limit int default 100,
  p_offset int default 0,
  p_fiscal_quarter_months text[] default null,
  p_from_date date default null,
  p_to_date date default null
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
  profit_percent numeric,
  dim_1_code text, dim_2_code text, dim_3_code text, dim_4_code text, dim_5_code text, dim_6_code text,
  dim_7_code text, dim_8_code text, dim_9_code text, dim_10_code text, dim_11_code text, dim_12_code text,
  attr_1_code text, attr_2_code text, attr_3_code text, attr_4_code text, attr_5_code text, attr_6_code text,
  attr_7_code text, attr_8_code text, attr_9_code text, attr_10_code text, attr_11_code text, attr_12_code text
)
language plpgsql stable as $$
declare
  -- One of these fixed, hardcoded expressions — NEVER p_sort_column itself —
  -- is what actually reaches the query via format()'s %s. Same safe pattern
  -- schema/013 established: p_sort_column can only ever select one of the
  -- strings below; every real filter VALUE still goes through the
  -- parameterized USING clause.
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
    when 'dim_1'  then 'coalesce(v.dim_1_code, v.attr_1_code, '''')'
    when 'dim_2'  then 'coalesce(v.dim_2_code, v.attr_2_code, '''')'
    when 'dim_3'  then 'coalesce(v.dim_3_code, v.attr_3_code, '''')'
    when 'dim_4'  then 'coalesce(v.dim_4_code, v.attr_4_code, '''')'
    when 'dim_5'  then 'coalesce(v.dim_5_code, v.attr_5_code, '''')'
    when 'dim_6'  then 'coalesce(v.dim_6_code, v.attr_6_code, '''')'
    when 'dim_7'  then 'coalesce(v.dim_7_code, v.attr_7_code, '''')'
    when 'dim_8'  then 'coalesce(v.dim_8_code, v.attr_8_code, '''')'
    when 'dim_9'  then 'coalesce(v.dim_9_code, v.attr_9_code, '''')'
    when 'dim_10' then 'coalesce(v.dim_10_code, v.attr_10_code, '''')'
    when 'dim_11' then 'coalesce(v.dim_11_code, v.attr_11_code, '''')'
    when 'dim_12' then 'coalesce(v.dim_12_code, v.attr_12_code, '''')'
    else 'v.doc_date'
  end;

  return query execute format(
    $q$
      select
        v.document_kind::text, v.document, v.doc_date, v.fiscal_year, v.account_code, v.customer_name,
        v.resolved_rep_code, v.resolved_rep_name, v.branch_code, v.branch_display_code, v.branch_name,
        v.item_code, v.item_name, v.department_code, v.category_name,
        v.quantity, v.value, v.cost, v.profit, v.profit_percent,
        v.dim_1_code, v.dim_2_code, v.dim_3_code, v.dim_4_code, v.dim_5_code, v.dim_6_code,
        v.dim_7_code, v.dim_8_code, v.dim_9_code, v.dim_10_code, v.dim_11_code, v.dim_12_code,
        v.attr_1_code, v.attr_2_code, v.attr_3_code, v.attr_4_code, v.attr_5_code, v.attr_6_code,
        v.attr_7_code, v.attr_8_code, v.attr_9_code, v.attr_10_code, v.attr_11_code, v.attr_12_code
      from v_sales_documents v
      where v.document_kind::text = any ($1)
        and ($2 is null or v.fiscal_year = $2)
        and ($3 is null or fiscal_month_label(v.doc_date) = $3)
        and ($8 is null or fiscal_month_label(v.doc_date) = any ($8))
        and ($5 is null or v.document ilike '%%' || $5 || '%%')
        and ($9 is null or v.doc_date >= $9)
        and ($10 is null or v.doc_date <= $10)
        and fn_document_row_matches_filters(v, $4)
      order by %s %s nulls last
      limit $6 offset $7
    $q$,
    v_sort_expr, v_direction
  )
  using p_document_kinds, p_fiscal_year, p_fiscal_month, p_filters, p_document,
        p_limit, p_offset, p_fiscal_quarter_months, p_from_date, p_to_date;
end;
$$;

grant execute on function fn_sales_documents_page(
  text[], int, text, jsonb, text, text, boolean, int, int, text[], date, date
) to authenticated;


-- ============================================================================
-- 2. fn_sales_documents_totals — same p_from_date/p_to_date appended.
-- ============================================================================

drop function if exists fn_sales_documents_totals(text[], int, text, jsonb, text, text[]);

create or replace function fn_sales_documents_totals(
  p_document_kinds text[],
  p_fiscal_year int default null,
  p_fiscal_month text default null,
  p_filters jsonb default '{}'::jsonb,
  p_document text default null,
  p_fiscal_quarter_months text[] default null,
  p_from_date date default null,
  p_to_date date default null
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
    and (p_document is null or v.document ilike '%' || p_document || '%')
    and (p_from_date is null or v.doc_date >= p_from_date)
    and (p_to_date is null or v.doc_date <= p_to_date)
    and fn_document_row_matches_filters(v, p_filters);
$$;

grant execute on function fn_sales_documents_totals(
  text[], int, text, jsonb, text, text[], date, date
) to authenticated;


-- ============================================================================
-- 3. fn_sales_documents_monthly_totals — new. Sales Analysis' Chart tab,
--    under a custom date range: one row per calendar month touched by
--    [p_from_date, p_to_date], summed from whatever rows actually fall
--    inside the range — the boundary months come out partial automatically,
--    nothing beyond the WHERE clause needed for that (see this migration's
--    header comment). p_from_date/p_to_date are NOT optional here (unlike
--    the two functions above) — this function has no meaning without a real
--    range; the Dart side only ever calls it once a user has picked both.
-- ============================================================================

create or replace function fn_sales_documents_monthly_totals(
  p_document_kinds text[],
  p_from_date date,
  p_to_date date,
  p_filters jsonb default '{}'::jsonb
)
returns table (
  month_start date,
  total_quantity numeric,
  total_value numeric,
  total_profit numeric
)
language sql stable as $$
  select
    date_trunc('month', v.doc_date)::date as month_start,
    coalesce(sum(v.quantity), 0) as total_quantity,
    coalesce(sum(v.value), 0)    as total_value,
    coalesce(sum(v.profit), 0)   as total_profit
  from v_sales_documents v
  where v.document_kind::text = any (p_document_kinds)
    and v.doc_date >= p_from_date
    and v.doc_date <= p_to_date
    and fn_document_row_matches_filters(v, p_filters)
  group by date_trunc('month', v.doc_date)
  order by month_start;
$$;

grant execute on function fn_sales_documents_monthly_totals(
  text[], date, date, jsonb
) to authenticated;
