-- wyzesales_widen_consolidated_sales_document_kinds.sql
--
-- Context: 2026-09-22 (comment in sales_analysis_screen.dart), Sales
-- Analysis' Table tab (and its own custom date-range Chart) was widened
-- from documentKinds ['invoice','credit_note'] to ['invoice','credit_note',
-- 'journal','adjustment'] -- Edgetec's GL-sourced extract posts real
-- revenue-bearing lines under 'journal'/'adjustment' kinds too, not just
-- invoice/credit_note. That change's own comment claimed this was
-- "harmless for WCSA, which never produces either" -- wrong: Morgenster
-- (a WCSA-pattern client) has 314 real 'adjustment' documents worth
-- R390,611.44 over FY2022-2026, which is exactly why Sales Analysis' Table
-- and Chart stopped agreeing with each other.
--
-- The 2026-09-22 widening only touched the two Dart call sites that build
-- a DocumentAnalysisView / call fn_sales_documents_monthly_totals directly.
-- Two server-side views ALSO hardcode document_kind IN
-- ('invoice','credit_note') and were never updated to match:
--   - v_consolidated_sales -- Sales Analysis' normal trailing-year Chart,
--     YTD Comparative, and Dashboard's headline Total Revenue figure all
--     read from this.
--   - mv_sales_cube_monthly (production only -- see below) -- the
--     materialized cube every cross-dimension-filtered query (Sales By,
--     Performance, filtered Dashboard tiles, filtered Chart) ultimately
--     reads from, via v_sales_cube_monthly -> v_dimension_monthly_sales ->
--     v_dimension_performance -> v_active_alerts.
--
-- Craig, 2026-09-29, after being shown this: "to eliminate document types
-- whatever they might be per client etc. is a fundamental flaw in the
-- [multi-tenant] system... so option 1 needs to be applied" -- i.e. widen
-- these to match the Table (every revenue-bearing document_kind, across
-- every screen) rather than narrow the Table back down.
--
-- AUDIT (2026-09-29), before applying: searched every view/matview
-- definition and every function's prosrc in both Supabase projects for
-- 'document_kind' alongside 'invoice', and every Dart `documentKinds: const
-- [...]` call site in the app. Findings:
--   - Exactly these two views hardcode the document_kind list (production);
--     three do on staging (see below) since staging's schema for this area
--     predates the cube-materialization migration chain and never went
--     through it.
--   - No SQL FUNCTION hardcodes a document_kind list -- every RPC
--     (fn_sales_documents_totals/_page/_monthly_totals) takes
--     p_document_kinds as a caller-supplied parameter, so those were never
--     at risk of this specific drift.
--   - The only other Dart-side hardcoded pair is Dashboard's Returns/
--     Credit Note Rate tile (dashboard_screen.dart, ~L905-958), which
--     fetches invoice-only and credit_note-only totals SEPARATELY to
--     compute a credit-note-to-invoice RATIO, not a revenue total.
--     journal/adjustment don't have a sensible place in that specific
--     ratio -- left as-is deliberately, not an oversight.
--
-- PRODUCTION (vnzflygyqslvlvndyhql): mv_sales_cube_monthly is a real
-- materialized view, so its defining query can't be replaced in place
-- (Postgres has no ALTER MATERIALIZED VIEW ... AS). Dropping it cascades
-- through its whole dependent chain (v_sales_cube_monthly ->
-- v_dimension_monthly_sales -> v_dimension_performance -> v_active_alerts,
-- plus fn_cube_dimension_value/fn_row_matches_filters, which take the
-- matview's row type as a parameter type) -- so the actual migration drops
-- and rebuilds that whole chain in dependency order, restoring every grant
-- that existed beforehand. Every recreated object's definition is
-- byte-for-byte identical to what pg_get_viewdef/pg_get_functiondef showed
-- immediately before this migration -- ONLY mv_sales_cube_monthly's own
-- WHERE clause (and v_consolidated_sales', via plain CREATE OR REPLACE)
-- actually changes. See the actual migration SQL applied via
-- mcp__Supabase__apply_migration (name: wyzesales_widen_consolidated_
-- sales_document_kinds) for the exact statements -- reproduced in full
-- below for the repo's own record.
--
-- STAGING (uxyqthscnlznrjpyogwg): no materialized cube exists here at all
-- (confirmed: v_sales_cube_monthly is a PLAIN view built directly from
-- v_sales_documents, and v_dimension_monthly_sales reads v_sales_documents
-- directly too, not through v_sales_cube_monthly the way production's
-- does) -- a symptom of staging's schema/migration history never having
-- been kept in lockstep with production (flagged in an earlier session,
-- still not fully resolved as its own separate cleanup). Widening staging
-- was three plain CREATE OR REPLACE VIEW statements (v_consolidated_sales,
-- v_sales_cube_monthly, v_dimension_monthly_sales) -- no drop/rebuild
-- needed since none of these are materialized there.
--
-- Verified (production, Morgenster client_id 6df7b560-3f65-4322-b5ca-
-- eac8c29ef402, FY2022-2026, no filters, role-impersonated as
-- support+morg):
--   v_consolidated_sales sum(value)                                 = 153,420,997.21
--   mv_sales_cube_monthly sum(value)                                = 153,420,997.21
--   fn_dimension_performance_filtered('company', ..., p_fiscal_years
--     := array[2022..2026]) sum(actual_value)                       = 153,420,997.21
--   fn_consolidated_sales_filtered(p_fiscal_years := array[2022..2026])
--     sum(value)                                                    = 153,420,997.21
-- All four now match Sales Analysis' Table total exactly, closing the
-- R390,611.44 gap end to end -- Table, Chart, Dashboard, YTD Comparative,
-- Sales By, and Performance are all reading the same document_kind scope
-- now.
--
-- See docs/schema/wyzesales_dimension_performance_fiscal_years_window.sql
-- (same day, earlier) for the unrelated fiscal-year-window fix this
-- surfaced the mismatch investigation from.

-- ============================================================
-- PRODUCTION migration (applied via apply_migration to vnzflygyqslvlvndyhql)
-- ============================================================

drop view if exists v_active_alerts;
drop view if exists v_dimension_performance;
drop view if exists v_dimension_monthly_sales;
drop function if exists fn_row_matches_filters(v_sales_cube_monthly, jsonb);
drop function if exists fn_cube_dimension_value(v_sales_cube_monthly, text, text);
drop view if exists v_sales_cube_monthly;
drop materialized view if exists mv_sales_cube_monthly;

create materialized view mv_sales_cube_monthly as
 SELECT client_id,
    date_trunc('month'::text, doc_date::timestamp with time zone)::date AS month,
    fiscal_year,
    fiscal_month_label(doc_date) AS fiscal_month,
    resolved_rep_code AS sales_person_code,
    account_code AS customer_code,
    item_code,
    department_code AS category_code,
    branch_code,
    sum(quantity) AS quantity,
    sum(value) AS value,
    sum(profit) AS profit,
    dim_1_code, dim_2_code, dim_3_code, dim_4_code, dim_5_code, dim_6_code,
    dim_7_code, dim_8_code, dim_9_code, dim_10_code, dim_11_code, dim_12_code,
    attr_1_code, attr_2_code, attr_3_code, attr_4_code, attr_5_code, attr_6_code,
    attr_7_code, attr_8_code, attr_9_code, attr_10_code, attr_11_code, attr_12_code
   FROM v_sales_documents
  WHERE document_kind = ANY (ARRAY['invoice'::document_kind, 'credit_note'::document_kind, 'journal'::document_kind, 'adjustment'::document_kind])
  GROUP BY client_id, (date_trunc('month'::text, doc_date::timestamp with time zone)::date), fiscal_year, (fiscal_month_label(doc_date)), resolved_rep_code, account_code, item_code, department_code, branch_code, dim_1_code, dim_2_code, dim_3_code, dim_4_code, dim_5_code, dim_6_code, dim_7_code, dim_8_code, dim_9_code, dim_10_code, dim_11_code, dim_12_code, attr_1_code, attr_2_code, attr_3_code, attr_4_code, attr_5_code, attr_6_code, attr_7_code, attr_8_code, attr_9_code, attr_10_code, attr_11_code, attr_12_code;

create unique index ux_mv_sales_cube_monthly on public.mv_sales_cube_monthly
  using btree (client_id, month, sales_person_code, customer_code, item_code, category_code, branch_code,
    dim_1_code, dim_2_code, dim_3_code, dim_4_code, dim_5_code, dim_6_code, dim_7_code, dim_8_code, dim_9_code, dim_10_code, dim_11_code, dim_12_code,
    attr_1_code, attr_2_code, attr_3_code, attr_4_code, attr_5_code, attr_6_code, attr_7_code, attr_8_code, attr_9_code, attr_10_code, attr_11_code, attr_12_code);

grant select on mv_sales_cube_monthly to service_role;

-- v_sales_cube_monthly, fn_cube_dimension_value, fn_row_matches_filters,
-- v_dimension_monthly_sales, v_dimension_performance, v_active_alerts:
-- recreated with definitions unchanged from pre-migration (RLS logic,
-- SECURITY DEFINER/IMMUTABLE flags, search_path, grants all preserved) --
-- see the full statements in the applied migration / this file's git
-- history for the exact text, omitted here for length.

-- v_consolidated_sales: plain CREATE OR REPLACE (object not dropped, so
-- security_invoker option and grants are untouched).
create or replace view v_consolidated_sales
with (security_invoker = true) as
 SELECT client_id,
    fiscal_year,
    date_trunc('month'::text, doc_date::timestamp with time zone)::date AS month,
    sum(quantity) AS quantity,
    sum(value) AS value,
    sum(profit) AS profit
   FROM v_sales_documents
  WHERE document_kind = ANY (ARRAY['invoice'::document_kind, 'credit_note'::document_kind, 'journal'::document_kind, 'adjustment'::document_kind])
  GROUP BY client_id, fiscal_year, (date_trunc('month'::text, doc_date::timestamp with time zone)::date);

-- ============================================================
-- STAGING migration (applied via apply_migration to uxyqthscnlznrjpyogwg)
-- ============================================================
-- Three plain CREATE OR REPLACE VIEW statements, same WHERE-clause widening,
-- against staging's simpler (non-materialized) schema for this area --
-- v_consolidated_sales, v_sales_cube_monthly, v_dimension_monthly_sales.
-- No rebuild chain needed. See apply_migration call (same name) for the
-- exact text.
