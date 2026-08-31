-- ============================================================================
-- WyzeSales — server-side pagination + totals for the line-level Document
-- Analysis view (Supabase / Postgres)
-- ============================================================================
-- Twelfth migration. Craig, 2026-08-27, after seeing Sales Analysis' Table
-- tab load 448 lines at once: "What happens when there 4000 lines? What is
-- considered the norm in apps like this?" The honest answer was that the
-- Flutter app's own `fetchSalesDocuments` capped itself at 1000 rows with no
-- pagination and no indication anything was cut off, and its DataTable built
-- every row's widgets eagerly rather than lazily. Craig confirmed the fix:
-- real server-side pagination, plus (separately) a Totals row computed over
-- the ENTIRE filtered result set rather than whatever page happens to be
-- loaded, pinned to the top of the table rather than the bottom.
--
-- Two new functions, not a change to v_sales_documents itself:
--  - fn_sales_documents_page: one page of rows (LIMIT/OFFSET, newest first),
--    matching v_sales_documents' own row shape exactly (SalesDocument.fromMap
--    needs no changes).
--  - fn_sales_documents_totals: COUNT/SUM over every row matching the same
--    filters, ignoring LIMIT/OFFSET entirely — this is what makes the Totals
--    row and the "Showing X-Y of Z" indicator correct regardless of which
--    page is currently on screen.
--
-- Both take the exact same filter parameters SalesRepository.fetchSalesDocuments
-- already builds from GlobalFilters, plus the new `p_document` substring
-- filter — previously applied client-side in document_analysis_view.dart's
-- own `_filterByDocument` against whatever page happened to already be in
-- memory, which only worked because every row used to be fetched at once.
-- With real pagination, filtering has to happen on the same server-side pass
-- that produces the page and the totals, or a Document filter would only
-- ever narrow the current page instead of the true result set.
--
-- Deliberately `language sql`, no `security definer` — same reasoning as
-- schema/011's fn_*_filtered functions: this runs as the calling role, so
-- RLS on sales_document_facts still applies per-caller through
-- v_sales_documents exactly as it does for a plain view query today. No
-- RLS/grants change needed on any existing table or view.
--
-- Sorting: NOT included here on purpose. document_analysis_view.dart's table
-- previously let a column-header click re-sort whatever page's rows were
-- already in memory — correct only because every row used to be in memory
-- at once. Once a page is a real slice of a larger result set, sorting has
-- to happen in this same query (ORDER BY the requested column) to mean
-- anything across pages; sorting just the current page would quietly go
-- back to being wrong the same way the old Totals/row-cap was. That's a
-- real, separate follow-up (safely parameterizing which column to sort by
-- in a SQL function needs either a fixed CASE-per-column expression or
-- validated dynamic SQL) — not bundled into this migration. Until it lands,
-- the Flutter side fixes the sort order to doc_date descending (newest
-- first, matching this function's own ORDER BY) and the column-header sort
-- affordance is removed from this one table rather than left in a state
-- that quietly only sorts the visible page.
--
-- FIX (same day, before this was ever successfully applied): `document_kind`
-- on sales_document_facts/v_sales_documents is a Postgres ENUM type
-- (schema/001: `create type document_kind as enum (...)`), not `text` — the
-- first version of both functions below compared it directly against
-- `p_document_kinds text[]` via `= any(...)`, which Postgres rejects with
-- "operator does not exist: document_kind = text" (no implicit cast between
-- an enum and text[] the way there is between an enum and an untyped string
-- literal, which is why `where document_kind in ('invoice', 'credit_note')`
-- elsewhere in this codebase — schema/002, schema/011 — never hit this).
-- Fixed by casting the column: `v.document_kind::text = any (p_document_kinds)`.
-- ============================================================================


-- ============================================================================
-- 1. fn_sales_documents_page — one page of line-level rows
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
language sql stable as $$
  select
    v.document_kind, v.document, v.doc_date, v.fiscal_year, v.account_code, v.customer_name,
    v.resolved_rep_code, v.resolved_rep_name, v.branch_code, v.branch_display_code, v.branch_name,
    v.item_code, v.item_name, v.department_code, v.category_name,
    v.quantity, v.value, v.cost, v.profit, v.profit_percent
  from v_sales_documents v
  where v.document_kind::text = any (p_document_kinds)
    and (p_fiscal_year  is null or v.fiscal_year = p_fiscal_year)
    and (p_fiscal_month is null or fiscal_month_label(v.doc_date) = p_fiscal_month)
    and (p_category is null or v.department_code    = p_category)
    and (p_item     is null or v.item_code           = p_item)
    and (p_rep      is null or v.resolved_rep_code   = p_rep)
    and (p_branch   is null or v.branch_code         = p_branch)
    and (p_customer is null or v.account_code        = p_customer)
    and (p_document is null or v.document ilike '%' || p_document || '%')
  order by v.doc_date desc
  limit p_limit offset p_offset;
$$;


-- ============================================================================
-- 2. fn_sales_documents_totals — COUNT/SUM over every matching row
-- ============================================================================
-- Same filters as fn_sales_documents_page above, minus LIMIT/OFFSET — this
-- is the whole point: it aggregates the full filtered result set regardless
-- of page size or which page is currently displayed. GP% is deliberately
-- NOT returned here — the Flutter side recomputes it client-side as
-- total_profit / total_value * 100, matching every other totals row in the
-- app (Wyzesales_Rebuild_Decisions.md Section 19e: recompute derived ratios
-- from the summed base figures, don't average per-row ratios).

create or replace function fn_sales_documents_totals(
  p_document_kinds text[],
  p_fiscal_year int default null,
  p_fiscal_month text default null,
  p_category text default null,
  p_item text default null,
  p_rep text default null,
  p_branch text default null,
  p_customer text default null,
  p_document text default null
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
    and (p_category is null or v.department_code    = p_category)
    and (p_item     is null or v.item_code           = p_item)
    and (p_rep      is null or v.resolved_rep_code   = p_rep)
    and (p_branch   is null or v.branch_code         = p_branch)
    and (p_customer is null or v.account_code        = p_customer)
    and (p_document is null or v.document ilike '%' || p_document || '%');
$$;


-- ============================================================================
-- 3. GRANTS
-- ============================================================================

grant execute on function fn_sales_documents_page(
  text[], int, text, text, text, text, text, text, text, int, int
) to authenticated;

grant execute on function fn_sales_documents_totals(
  text[], int, text, text, text, text, text, text, text
) to authenticated;
