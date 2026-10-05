-- ============================================================================
-- WyzeSales — stop the Sales Analysis "Table" tab timing out on large clients
-- ============================================================================
-- Fifty-eighth migration. 2026-10-05, Morgenster: Sales Analysis > Table
-- failed with "canceling statement due to statement timeout (57014)".
--
-- Cause: fn_sales_documents_totals / _page read v_sales_documents, whose base
-- table (sales_document_facts) is filtered by row-level security using
-- InitPlans the planner cannot see through. It therefore estimates ~5 matching
-- rows (actual: ~259,000 for Morgenster) and picks a nested loop for the
-- LEFT JOIN to items - ~281 million comparisons. Measured as the app user
-- (authenticated role, 8s statement_timeout):
--     nested loop (before)   totals 22-26s   page 30s   (timeout)
--     hash join   (after)    totals 0.3s     page 1.0s
-- The plan shape is independent of table statistics (ANALYZE made no
-- difference), so the fix is to forbid the nested loop for these functions
-- only, rather than touching any role-wide or database-wide setting.
--
-- IMPORTANT: ALTER FUNCTION ... SET is stored on the function and is LOST if
-- the function is later re-created with CREATE OR REPLACE FUNCTION unless the
-- new definition repeats `set enable_nestloop = off`. Re-run these three
-- statements (or add the SET clause to the definition) after any rebuild.
--
-- Already applied to production (project vnzflygyqslvlvndyhql) via
-- apply_migration "sales_documents_fns_disable_nestloop". Safe to re-run.
-- Undo: alter function ... reset enable_nestloop;
-- ============================================================================

alter function public.fn_sales_documents_totals(text[], integer, text, jsonb, text, text[], date, date)
  set enable_nestloop = off;

alter function public.fn_sales_documents_page(text[], integer, text, jsonb, text, text, boolean, integer, integer, text[], date, date)
  set enable_nestloop = off;

alter function public.fn_sales_documents_monthly_totals(text[], date, date, jsonb)
  set enable_nestloop = off;
