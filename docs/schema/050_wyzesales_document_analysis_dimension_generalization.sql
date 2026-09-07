-- ============================================================================
-- WyzeSales — generalize Document Analysis (Sales/Quote/Sales Order Analysis'
-- Table tab) to any client's own configured dimensions
-- ============================================================================
-- Fiftieth migration. Craig, 2026-09-07, after the RLS performance fix
-- (migration 049) let Edgetec's Dashboard load for the first time: "Sales
-- Analysis screen needs to look at Edgetec's dimensions and not WCSA" and,
-- once that root cause was traced, "The Sales Analysis and Budgets all need
-- to be aligned with the companies specific dimensions."
--
-- Budgets (and Sales By, and Performance) already read each client's own
-- client_dimensions config directly — migration 042's own header explicitly
-- flagged this exact gap as OUT OF SCOPE, DEFERRED at the time: "fn_sales_
-- documents_page / fn_sales_documents_totals (schema/012, the line-level
-- Sales Analysis Table tab) query v_sales_documents directly using ITS OWN
-- native column names for the five existing dimensions (account_code,
-- resolved_rep_code, department_code — not the cube's renamed customer_code/
-- sales_person_code/category_code), a different enough convention that
-- generalizing them needs its own follow-up rather than reusing
-- fn_cube_dimension_value as-is." This migration is that follow-up.
--
-- THE FIX, same shape as migration 042/047's own generalization:
--   1. fn_document_dimension_value(v v_sales_documents, dimension_key,
--      resolution_kind) — v_sales_documents' own equivalent of migration
--      042's fn_cube_dimension_value, translating a dimension_key to its
--      value on ONE ROW of v_sales_documents specifically. The five
--      'existing' dimensions get their own real column names here
--      (resolved_rep_code, account_code, item_code, department_code,
--      branch_code) rather than the cube's renamed convention — this is
--      exactly the "different enough convention" migration 042 flagged.
--   2. fn_document_row_matches_filters(v, p_filters) — v_sales_documents'
--      own equivalent of fn_row_matches_filters, same jsonb-map-of-active-
--      filters shape GlobalFilters.toFilterParams() already produces and
--      every other generalized RPC (042/047) already consumes.
--   3. fn_sales_documents_page / fn_sales_documents_totals: the five named
--      p_category/p_item/p_rep/p_branch/p_customer parameters collapse into
--      one p_filters jsonb, exactly mirroring 042's own collapse of the same
--      five named parameters on the OTHER four functions. p_document (a raw
--      substring filter, never a dimension — schema/038's own header
--      comment) and p_fiscal_year/p_fiscal_month/p_fiscal_quarter_months are
--      untouched.
--   4. fn_sales_documents_page's RETURN TABLE gains the same 24 generic
--      dim_1_code..dim_12_code / attr_1_code..attr_12_code columns
--      v_sales_documents itself already carries (migration 039) — appended
--      at the end, same "append, never reorder" convention `create or
--      replace view`/function already forces everywhere else in this
--      schema. This is a plain passthrough of the raw per-row value; NO
--      display-name resolution happens here — the Flutter side already has
--      an established, working pattern for that (ReferenceDataRepository.
--      namesForConfig, built for Sales By/Performance/Budgets in the
--      multi-tenant dimension model's Step 4) that this migration's Dart
--      counterpart reuses rather than duplicating name-lookup logic in SQL.
--   5. fn_sales_documents_page's dynamic sort CASE gains 'dim_1'..'dim_12'
--      entries, coalescing whichever of dim_N_code/attr_N_code actually
--      carries that client's value (a client only ever populates one of the
--      two for a given generic slot — migration 039's own resolution_kind
--      split — so coalescing both is safe and needs no extra join to
--      client_dimensions just to pick the right one).
--
-- WCSA IMPACT: none. Its five dimensions are all 'existing' and route
-- through the exact same column names/CASE branches as before; its
-- dim_N_code/attr_N_code columns are all null (migration 039's own
-- guarantee), so the 24 appended output columns are simply null for every
-- WCSA row — Quote/Sales Order Analysis (the other two screens sharing this
-- same table/RPC) are WCSA-only today and see zero behaviour change.
--
-- Both functions are DROPPED before CREATE, not a plain `create or replace`
-- — changing a function's parameter list changes its identity for Postgres'
-- overload-resolution purposes (the exact trap schema/013's and schema/047's
-- own header comments already flagged), so a bare `create or replace` here
-- would leave the OLD 5-named-parameter signature sitting alongside this
-- new one as a second overload rather than replacing it.
-- ============================================================================


-- ============================================================================
-- 1. fn_document_dimension_value — resolve any dimension_key to its value on
--    one row of v_sales_documents (NOT v_sales_cube_monthly — see this
--    migration's header comment on why the five 'existing' dimensions need
--    their own column-name mapping here).
-- ============================================================================

create or replace function fn_document_dimension_value(
  v v_sales_documents,
  p_dimension_key text,
  p_resolution_kind text
)
returns text
language sql immutable as $$
  select case
    when p_dimension_key = 'company'      then 'ALL'
    when p_dimension_key = 'sales_person'  then v.resolved_rep_code
    when p_dimension_key = 'customer'      then v.account_code
    when p_dimension_key = 'item'          then v.item_code
    when p_dimension_key = 'category'      then v.department_code
    when p_dimension_key = 'branch'        then v.branch_code
    when p_resolution_kind = 'customer_attribute'
      then to_jsonb(v) ->> (replace(p_dimension_key, 'dim_', 'attr_') || '_code')
    else to_jsonb(v) ->> (p_dimension_key || '_code')
  end;
$$;

grant execute on function fn_document_dimension_value(v_sales_documents, text, text) to authenticated;


-- ============================================================================
-- 2. fn_document_row_matches_filters — does one v_sales_documents row satisfy
--    an entire p_filters map. Same shape/defensiveness as
--    fn_row_matches_filters (migration 042): a stray JSON null is stripped
--    (an inactive filter is meant to be simply absent from the map, matching
--    GlobalFilters.toFilterParams()' own convention), and an unrecognized
--    dimension_key (no matching client_dimensions row for this row's own
--    client_id) is silently ignored rather than treated as a non-match.
-- ============================================================================

create or replace function fn_document_row_matches_filters(
  v v_sales_documents,
  p_filters jsonb
)
returns boolean
language sql stable as $$
  select not exists (
    select 1
    from jsonb_each_text(coalesce(jsonb_strip_nulls(p_filters), '{}'::jsonb)) as f(dimension_key, filter_value)
    join client_dimensions cd
      on cd.client_id = v.client_id and cd.dimension_key = f.dimension_key
    where fn_document_dimension_value(v, f.dimension_key, cd.resolution_kind) is distinct from f.filter_value
  );
$$;

grant execute on function fn_document_row_matches_filters(v_sales_documents, jsonb) to authenticated;


-- ============================================================================
-- 3. fn_sales_documents_page — p_filters jsonb replaces the five named
--    p_category/p_item/p_rep/p_branch/p_customer parameters; RETURN TABLE
--    gains the 24 generic dim_N_code/attr_N_code passthrough columns; sort
--    CASE gains 'dim_1'..'dim_12'.
-- ============================================================================

drop function if exists fn_sales_documents_page(text[], int, text, text, text, text, text, text, text, text, boolean, int, int, text[]);

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
        and fn_document_row_matches_filters(v, $4)
      order by %s %s nulls last
      limit $6 offset $7
    $q$,
    v_sort_expr, v_direction
  )
  using p_document_kinds, p_fiscal_year, p_fiscal_month, p_filters, p_document,
        p_limit, p_offset, p_fiscal_quarter_months;
end;
$$;

grant execute on function fn_sales_documents_page(
  text[], int, text, jsonb, text, text, boolean, int, int, text[]
) to authenticated;


-- ============================================================================
-- 4. fn_sales_documents_totals — same p_filters jsonb collapse, no output
--    shape change (it's an aggregate, not a per-row passthrough).
-- ============================================================================

drop function if exists fn_sales_documents_totals(text[], int, text, text, text, text, text, text, text, text[]);

create or replace function fn_sales_documents_totals(
  p_document_kinds text[],
  p_fiscal_year int default null,
  p_fiscal_month text default null,
  p_filters jsonb default '{}'::jsonb,
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
    and (p_document is null or v.document ilike '%' || p_document || '%')
    and fn_document_row_matches_filters(v, p_filters);
$$;

grant execute on function fn_sales_documents_totals(
  text[], int, text, jsonb, text, text[]
) to authenticated;
