-- ============================================================================
-- WyzeSales — real server-side sorting for fn_sales_documents_page
-- ============================================================================
-- Thirteenth migration. Craig, 2026-08-27, immediately after 012 shipped:
-- "The column sorting is a real issue we need to be able to sort on all
-- columns." Expected — 012's own header comment already flagged this as a
-- deliberate follow-up rather than an oversight: sorting a single page in
-- memory (the old client-side behaviour) only ever worked because every row
-- used to be fetched at once. This migration is that follow-up.
--
-- fn_sales_documents_page is rebuilt as `language plpgsql` with validated
-- dynamic SQL (`format()` + `EXECUTE ... USING`), not `language sql` with a
-- CASE-per-column expression — a plain SQL function can't parameterize which
-- column to ORDER BY (there's no way to make ORDER BY's target itself a bind
-- parameter), and casting every sortable column to a common text key so a
-- CASE expression could pick between them would break numeric ordering
-- (text-sorting "9" after "10" the way lexical comparison does). The safe,
-- standard pattern instead: p_sort_column is matched against a fixed
-- CASE/WHEN list of HARDCODED column expressions (never the raw parameter
-- itself) to produce v_sort_expr, which is the only thing substituted via
-- format()'s %s — every actual FILTER VALUE still goes through a genuine
-- parameterized USING clause ($1..$11), not string interpolation. There is
-- no path from user input to a raw SQL fragment here: p_sort_column can only
-- ever select one of the fixed strings below, same as p_sort_ascending can
-- only ever produce the literal 'asc' or 'desc'.
--
-- fn_sales_documents_page's parameter list gains p_sort_column (text,
-- default 'doc_date') and p_sort_ascending (boolean, default false) — a
-- DROP + CREATE, not a plain `create or replace`, because Postgres treats a
-- changed parameter list as a different function identity for
-- `create or replace` purposes; leaving the old 11-parameter version in
-- place alongside a new 13-parameter one would create two overloads of the
-- same name, which risks PostgREST's RPC endpoint being unable to pick one
-- unambiguously. Dropping the old signature first guarantees exactly one
-- version of this function exists either way, regardless of whether 012 was
-- ever actually applied before this migration runs.
--
-- fn_sales_documents_totals is untouched — an aggregate over the whole
-- filtered set has no meaningful "sort order" to parameterize.
-- ============================================================================


-- ============================================================================
-- 1. fn_sales_documents_page — now sortable by any of the 12 columns the
--    Document Analysis table exposes
-- ============================================================================

drop function if exists fn_sales_documents_page(
  text[], int, text, text, text, text, text, text, text, int, int
);

create function fn_sales_documents_page(
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
  p_offset int default 0
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
  -- One of these fixed, hardcoded expressions — NEVER p_sort_column itself —
  -- is what actually reaches the query via format()'s %s. `document_kind`
  -- needs the same ::text cast the WHERE clause below needs, for the same
  -- enum-vs-text reason (see 012's own header comment). "sales_person",
  -- "branch", "category", "item", "customer" match exactly what the Flutter
  -- table already displays in those columns (coalesce'd display name over
  -- raw code), so "sort by Customer" sorts by the same text the user is
  -- actually looking at, not the underlying account_code.
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
        v.document_kind, v.document, v.doc_date, v.fiscal_year, v.account_code, v.customer_name,
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
      order by %s %s nulls last
      limit $10 offset $11
    $q$,
    v_sort_expr, v_direction
  )
  using p_document_kinds, p_fiscal_year, p_fiscal_month, p_category, p_item,
        p_rep, p_branch, p_customer, p_document, p_limit, p_offset;
end;
$$;


-- ============================================================================
-- 2. GRANTS
-- ============================================================================
-- The old 11-parameter grant (012) is moot once the function above is
-- dropped and recreated with a new signature — nothing to revoke, there is
-- simply no function left matching that old signature to hold a grant on.

grant execute on function fn_sales_documents_page(
  text[], int, text, text, text, text, text, text, text, text, boolean, int, int
) to authenticated;
