-- wyzesales_fn_revenue_document_kinds.sql
--
-- Craig, 2026-09-29, right after the document-kind scoping mismatch was
-- fixed (see wyzesales_widen_consolidated_sales_document_kinds.sql, same
-- day, earlier): "nothing can ever be hard coded anywhere. If ... we add a
-- new client and that client does not align with hard coded code then
-- it's broken." A full audit (every Dart `documentKinds:` call site, every
-- SQL view/matview/function on both Supabase projects) found this exact
-- shape of problem in exactly one other place worth structurally fixing:
-- "which document kinds count as revenue" was typed out independently in
-- four places (two Dart widget params, two SQL views). Today's earlier fix
-- made all four AGREE; this migration makes it impossible for them to
-- silently disagree again by replacing the four independent copies with
-- one canonical function everything calls.
--
-- Separately, same day, Craig on the document_kind vocabulary itself:
-- "Wyzesales now needs to cater for Invoice, Credit and Adjustment.
-- That's it... Journals etc. are all just adjustments." Quote Analysis and
-- Sales Order Analysis (document kinds 'quote'/'sales_order') were already
-- removed from the app on 2026-09-02 (task #93, Wyzesales_Rebuild_
-- Decisions.md Section 55) -- confirmed via sales_repository.dart's own
-- doc comment and confirmed no client has any 'quote'/'sales_order' rows
-- in sales_document_facts on production. 'journal' is being retired too --
-- Craig is running his own SQL (docs/schema/wyzesales_relabel_journal_to_
-- adjustment.sql, NOT applied automatically -- his own script, his own
-- pace) to relabel every existing 'journal' row to 'adjustment'.
--
-- fn_revenue_document_kinds() is created returning FOUR kinds (invoice,
-- credit_note, adjustment, journal) -- identical, zero-behaviour-change,
-- to what was live a few minutes earlier -- deliberately NOT narrowed to
-- three yet, so revenue totals don't dip for Edgetec (the only client with
-- real, as-of-this-migration not-yet-relabelled 'journal' rows: 1,911 rows,
-- R467,908.65) while Craig's relabel script is still pending. Once that
-- relabel is confirmed complete, dropping 'journal' from this function's
-- returned array is a ONE-LINE `CREATE OR REPLACE FUNCTION` -- no view or
-- matview rebuild needed at all, because a materialized view's stored
-- query calls the function fresh on every REFRESH rather than inlining its
-- body at CREATE time. That one-line-change property is the entire point
-- of this migration: the next time "what counts as revenue" needs to
-- change, it no longer costs a multi-object cascade rebuild the way today
-- twice did.
--
-- Mirrored on the Dart side by `kRevenueDocumentKinds`
-- (lib/core/constants/document_kinds.dart) -- both sales_analysis_screen.
-- dart call sites that used to independently type out the same array now
-- import that one constant. The two MUST be changed together (drop
-- 'journal' from both, same commit) -- changing only one re-creates
-- exactly today's Table/Chart mismatch in reverse.
--
-- Applied to BOTH Supabase projects (production vnzflygyqslvlvndyhql,
-- staging uxyqthscnlznrjpyogwg) via mcp__Supabase__apply_migration, names
-- wyzesales_fn_revenue_document_kinds and (production only, since only
-- production has a materialized cube to rebuild)
-- wyzesales_route_cube_through_fn_revenue_document_kinds. Verified
-- (production, Morgenster, FY2022-2026): v_consolidated_sales and
-- mv_sales_cube_monthly both still return R153,420,997.21, unchanged from
-- before this migration.

create or replace function public.fn_revenue_document_kinds()
returns public.document_kind[]
language sql
immutable
set search_path to 'public'
as $function$
  select array['invoice'::document_kind, 'credit_note'::document_kind, 'adjustment'::document_kind, 'journal'::document_kind];
$function$;

comment on function public.fn_revenue_document_kinds() is
  'Single source of truth for "which document kinds count as revenue" -- every view/matview that used to hardcode this array now calls this function instead.';

-- PRODUCTION ONLY: mv_sales_cube_monthly is materialized, so pointing its
-- WHERE clause at the function above (instead of an inlined literal array)
-- required the same drop-and-rebuild-the-whole-dependent-chain dance as
-- the earlier migration today (v_active_alerts -> v_dimension_performance
-- -> v_dimension_monthly_sales -> v_sales_cube_monthly -> mv_sales_cube_
-- monthly, plus fn_cube_dimension_value/fn_row_matches_filters which take
-- the matview's row type as a parameter type). Every recreated object's
-- definition is unchanged except the one WHERE clause -- see
-- wyzesales_widen_consolidated_sales_document_kinds.sql for the full
-- rebuild SQL (identical structure, just s/ARRAY[...]/fn_revenue_document_
-- kinds()/ in mv_sales_cube_monthly's own WHERE clause) and v_consolidated_
-- sales' plain CREATE OR REPLACE (same swap, no rebuild needed there).
--
-- STAGING: three plain CREATE OR REPLACE VIEW statements (v_consolidated_
-- sales, v_sales_cube_monthly, v_dimension_monthly_sales), same swap, no
-- rebuild needed since nothing there is materialized.
