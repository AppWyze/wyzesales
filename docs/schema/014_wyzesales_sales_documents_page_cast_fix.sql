-- ============================================================================
-- WyzeSales — fix fn_sales_documents_page's SELECT list: document_kind must
-- be cast to text, not just compared as text
-- ============================================================================
-- Fourteenth migration. Craig, 2026-08-27, right after applying schema/013:
-- Sales Analysis' Table tab failed with
--   PostgrestException(message: structure of query does not match function
--   result type, code: 42804, details: Returned type document_kind does not
--   match expected type text in column 1., hint: null)
--
-- Root cause: the SAME enum-vs-text issue schema/012's own header comment
-- already flagged and fixed once — `document_kind` on
-- sales_document_facts/v_sales_documents is a Postgres ENUM
-- (`create type document_kind as enum (...)`, schema/001), not `text` — but
-- that first fix only ever touched the WHERE clause
-- (`v.document_kind::text = any (p_document_kinds)`). The function's SELECT
-- list itself was never fixed: it has selected the bare, uncast
-- `v.document_kind` (an enum value) as column 1 since schema/012, while
-- `returns table (document_kind text, ...)` declares that column `text`.
--
-- Postgres does not check a SQL/plpgsql function's actual result-column
-- types against its declared `RETURNS TABLE` shape at CREATE time — only
-- when the function is actually called and starts emitting rows. That's why
-- this went unnoticed through both schema/012 and schema/013: schema/012's
-- WHERE-clause bug was a parse/plan-time error, so calling the function
-- always failed before it ever got far enough to emit a row and hit this
-- second, separate bug. Once schema/013 fixed the WHERE clause (as part of
-- adding sorting) and the function could finally run for real, this
-- previously-hidden SELECT-list bug surfaced for the first time.
--
-- Fix: cast the SELECT list's document_kind the same way the WHERE clause
-- and the sort CASE expression already do: `v.document_kind::text`. Nothing
-- else in schema/013's function changes — same 13-parameter signature, same
-- WHERE clause, same dynamic sort — so this is a plain `create or replace`,
-- not a drop+create; Postgres treats an unchanged parameter list as the same
-- function identity, so there's no risk of a duplicate overload here the
-- way schema/013 itself had to guard against relative to schema/012.
--
-- fn_sales_documents_totals is unaffected — it never selects document_kind
-- in its result columns, only filters by it.
-- ============================================================================

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
  -- Unchanged from schema/013 — see that migration's own header comment for
  -- why this is a fixed CASE/WHEN list of hardcoded expressions rather than
  -- interpolating p_sort_column directly.
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
-- GRANTS
-- ============================================================================
-- Unchanged signature, so the existing grant from schema/013 already covers
-- this — re-stated here only for idempotency (harmless to re-run, and keeps
-- this migration runnable on its own without silently depending on 013
-- having granted it first).

grant execute on function fn_sales_documents_page(
  text[], int, text, text, text, text, text, text, text, text, boolean, int, int
) to authenticated;
