-- ============================================================================
-- WyzeSales — GRANTs for the compute-forecast Edge Function (Supabase / Postgres)
-- ============================================================================
-- Thirty-second migration. compute-forecast (supabase/functions/compute-
-- forecast) was just switched onto getServiceKey() (_shared/service_key.ts)
-- — the same "wyzesales_edge" secret key the other 4 full-access Edge
-- Functions already use — instead of the legacy SUPABASE_SERVICE_ROLE_KEY,
-- which no longer exists at all (fully deleted, Section 59 of the Decisions
-- doc, once all 4 of those functions were confirmed working on the new key).
--
-- Section 59 also found, the hard way, that the new secret key's underlying
-- Postgres role does NOT automatically inherit the same standing table-level
-- GRANTs the old service_role key always had by default in this project —
-- it still bypasses RLS (BYPASSRLS), but a missing GRANT fails with a flat
-- "permission denied" before RLS is ever evaluated, same two-gate ordering
-- schema/007's own header explains for `authenticated`. That migration's fix
-- granted exactly the tables the other 4 functions touch (profiles, clients,
-- license, pricing_plan); this one is the same fix for what compute-forecast
-- itself touches: `clients` (to loop every client), `forecast_settings`
-- (per-client Holt-Winters tuning), `sales_forecast` (the table it fully
-- replaces via upsert on every run), and EXECUTE on `forecast_input_series()`
-- (schema/003), which it calls via `supabase.rpc(...)`.
--
-- Written and reasoned through against the documented Supabase behaviour
-- that both the legacy service_role key and the new secret-key format
-- authenticate as the `service_role` Postgres role. Unlike Section 59's own
-- fix (found live, from Postgres's own error hint), this one WAS actually
-- reproduced and fixed against a scratch Postgres before being sent — with
-- `service_role` given the BYPASSRLS attribute it genuinely has in a real
-- Supabase project (the stand-in used for every other RLS test in this repo
-- deliberately doesn't set that, since it's normally testing `authenticated`
-- impersonation instead), calling `forecast_input_series()` as `service_role`
-- with only clients/forecast_settings/sales_forecast granted still failed:
-- `permission denied for view v_dimension_monthly_sales`. That view (and
-- `v_sales_documents`, schema/001) are `security_invoker` — same reasoning
-- schema/007's own header gives for why the calling role needs grants on the
-- underlying base tables too, not just the view — and `service_role` had
-- never needed those before (the other 4 functions never read sales/rollup
-- data, only profiles/clients/license/pricing_plan). Confirmed fixed by
-- additionally granting the view plus every base table it and
-- `v_sales_documents` actually read: `sales_document_facts`,
-- `fiscal_year_settings`, `customers`, `sales_reps`, `branches`, `items`,
-- `categories`. Re-ran `forecast_input_series()` for all 6 dimensions plus a
-- `sales_forecast` upsert after this and got real computed rows back with no
-- further permission errors.
--
-- If deploying compute-forecast still 42501s on something not listed here,
-- the fix is the same as Section 59's: read the exact table/role name out of
-- Postgres's own error hint and GRANT to that role.
-- ============================================================================

grant select on
  clients,
  forecast_settings,
  sales_forecast,
  v_dimension_monthly_sales,
  v_sales_documents,
  sales_document_facts,
  fiscal_year_settings,
  customers,
  sales_reps,
  branches,
  items,
  categories
to service_role;

grant insert, update on sales_forecast to service_role;
grant execute on function forecast_input_series(uuid, text) to service_role;
