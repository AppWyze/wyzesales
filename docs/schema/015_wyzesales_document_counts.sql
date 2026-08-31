-- ============================================================================
-- WyzeSales — distinct document counts per document_kind (Supabase / Postgres)
-- ============================================================================
-- Fifteenth migration. Needed for the Dashboard's new Quote → Order
-- Conversion KPI tile (2026-08-27, Craig: "What do you think are the 5 kpi's
-- that need to be on a sales analysis dashboard" -> mockup review -> "Go
-- ahead and build this please").
--
-- Why this can't reuse fn_sales_documents_totals (schema/012): that
-- function's `total_count` is `count(*)` over v_sales_documents, which is a
-- LINE-level view (one row per item on a document) — a single quote with 3
-- line items would count as 3, not 1. Quote → Order Conversion needs the
-- number of distinct QUOTE DOCUMENTS vs distinct SALES ORDER DOCUMENTS
-- raised in a period, so this is a `count(distinct document)` grouped by
-- document_kind — a genuinely different aggregate, not a filter variation on
-- the existing function.
--
-- Same conventions as schema/012/013/014: `language sql stable`, no
-- `security definer` — runs as the calling role, so RLS on
-- sales_document_facts still applies per-caller through v_sales_documents
-- exactly as every other query in this app does. `document_kind::text` is
-- cast explicitly in both the WHERE clause and the SELECT list — schema/014
-- is the reminder of why: Postgres doesn't check a SQL function's actual
-- result-column types against its declared RETURNS TABLE shape until it
-- actually runs, so an uncast enum column silently compiles and only fails
-- (or in the SELECT-list case, appears to work but doesn't) at call time.
--
-- Filter parameters are deliberately the same shape as
-- fn_sales_documents_totals (p_fiscal_year/p_fiscal_month/p_category/p_item/
-- p_rep/p_branch/p_customer) minus p_document (a free-text document-number
-- search has no meaning for a distinct-count aggregate) — so
-- SalesRepository.fetchDocumentCounts can build its params the exact same
-- way _salesDocumentsFilterParams already does for the other two functions.
-- ============================================================================

create or replace function fn_document_counts(
  p_document_kinds text[],
  p_fiscal_year int default null,
  p_fiscal_month text default null,
  p_category text default null,
  p_item text default null,
  p_rep text default null,
  p_branch text default null,
  p_customer text default null
)
returns table (
  document_kind text,
  doc_count bigint
)
language sql stable as $$
  select
    v.document_kind::text,
    count(distinct v.document) as doc_count
  from v_sales_documents v
  where v.document_kind::text = any (p_document_kinds)
    and (p_fiscal_year  is null or v.fiscal_year = p_fiscal_year)
    and (p_fiscal_month is null or fiscal_month_label(v.doc_date) = p_fiscal_month)
    and (p_category is null or v.department_code    = p_category)
    and (p_item     is null or v.item_code           = p_item)
    and (p_rep      is null or v.resolved_rep_code   = p_rep)
    and (p_branch   is null or v.branch_code         = p_branch)
    and (p_customer is null or v.account_code        = p_customer)
  group by v.document_kind;
$$;


-- ============================================================================
-- GRANTS
-- ============================================================================

grant execute on function fn_document_counts(
  text[], int, text, text, text, text, text, text
) to authenticated;
