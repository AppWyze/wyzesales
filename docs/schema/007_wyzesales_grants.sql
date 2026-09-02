-- ============================================================================
-- WyzeSales — explicit grants for the `authenticated` role (Supabase / Postgres)
-- ============================================================================
-- Seventh migration. Found from a real error in the running Flutter app
-- against wyzesales-staging: `permission denied for table items` (Postgres
-- error 42501), even though `items_select` (schema/006) is a correct,
-- working RLS policy.
--
-- RLS and GRANT are two separate gates, both of which Postgres checks, in
-- this order: first "does this role have the base SQL privilege (SELECT/
-- INSERT/...) on this object at all", then "does a row-level security
-- policy allow this specific row". A missing GRANT fails with a flat
-- "permission denied" before RLS is ever evaluated — which is exactly what
-- happened here. Every table and security_invoker view this schema created
-- needs an explicit GRANT to `authenticated`; RLS is what actually narrows
-- what any given signed-in user can see, same as before.
--
-- Re-verified locally (2026-08-21) against real `authenticated`/`anon`
-- roles with none of the ambient extra grants a hand-created test role
-- would have — that's what reproduced this exact error locally, and
-- confirms this migration fixes it. Worth being explicit about a gap in
-- the earlier verification passes for 001/004/005/006: those were tested
-- against a role I had manually granted broad table privileges to first
-- (a reasonable way to isolate and test RLS logic in isolation, but it
-- meant grants themselves were never actually exercised) — this migration
-- and its test are the first time grants were verified for real, and won't
-- be the last: from here on, verifying a new table/view against Postgres
-- means testing with a role that has ONLY what a migration explicitly
-- grants it, not a role pre-granted broad access.
--
-- security_invoker views (v_sales_documents, v_consolidated_sales,
-- v_dimension_monthly_sales, v_dimension_performance — schema/001 Section 9,
-- schema/002) run as the CALLING role, not the view's owner — that's the
-- whole point of security_invoker, so RLS applies per-caller. The trade-off:
-- the calling role needs its own grants on the underlying base tables too,
-- not just the view. This migration grants both.
--
-- Nothing is granted to `anon` — this app has no unauthenticated screens,
-- and every table's RLS already keys off `profiles` (unreachable without a
-- real signed-in `auth.uid()`), so there's nothing for an anon grant to
-- usefully unlock. Leaving it out means an unauthenticated request fails
-- immediately and clearly rather than returning an empty-but-technically-
-- successful result.
-- ============================================================================

grant select on
  clients,
  branches,
  sales_reps,
  customers,
  categories,
  suppliers,
  items,
  sales_document_facts,
  stock_movement_facts,
  item_stock_snapshot,
  budget_figures,
  sales_forecast,
  excluded_customer_accounts,
  fiscal_year_settings,
  forecast_settings,
  profiles,
  v_sales_documents,
  v_consolidated_sales,
  v_dimension_monthly_sales,
  v_dimension_performance
to authenticated;

-- budget_figures is the one table the app writes to directly (the Budgets
-- screen) — RLS (schema/001 Section 10, schema/004) already restricts which
-- rows an insert/update actually succeeds on to adminuser/superuser; this
-- just makes the base privilege available for RLS to narrow.
grant insert, update on budget_figures to authenticated;

-- profiles' own "for all" policy (profiles_superuser_all, schema/005) lets
-- a superuser manage other users' rows — needs the base insert/update/
-- delete privileges available for that RLS check to have anything to allow.
grant insert, update, delete on profiles to authenticated;
