-- wyzesales_fix_service_key_cube_access.sql
--
-- Craig, 2026-09-29: "Now can you tell me why the Seasonal Forecast Edge
-- function did not run this morning against Morgenster and calculate the
-- various seasonal forecasts?" -- the compute-forecast Edge Function DID
-- run this morning (pg_cron job compute-forecast-daily, 03:00 UTC, HTTP
-- 200, {"ok":true,"errors":{}}) but wrote ZERO forecast rows for every
-- single client, Morgenster included -- not a crash, a silent no-op.
--
-- ROOT CAUSE: v_sales_cube_monthly (introduced the day before by
-- wyzesales_materialize_sales_cube_monthly + _lockdown_fixes, 2026-09-28
-- 13:41 UTC) only returns rows to a "full access" caller when
-- auth.role() = 'service_role'. auth.role() (confirmed via
-- pg_get_functiondef) reads ONLY the request.jwt.claim.role /
-- request.jwt.claims PostgREST session GUCs -- i.e. it only knows about a
-- caller authenticated via a legacy service_role JWT.
--
-- compute-forecast (and WyzeSales' other 4 full-access-key Edge Functions)
-- stopped using that legacy JWT on 2026-09-02 (Section 59, after a key
-- leak) and authenticate with a new-style Supabase secret key instead
-- ("wyzesales_edge", via getServiceKey()/_shared/service_key.ts). Per
-- Supabase's own docs, that secret key genuinely executes as the real
-- service_role Postgres role and still bypasses actual RLS policies via
-- BYPASSRLS -- but it evidently does not populate the same JWT-claim
-- session variables a JWT-based request does, so auth.role() itself comes
-- back null for these calls even though the caller truly is service_role.
-- v_sales_cube_monthly's access check is hand-rolled (a UNION ALL branch,
-- not a real Postgres RLS POLICY), so BYPASSRLS was never able to help it
-- -- it was solely relying on auth.role() correctly reporting
-- 'service_role', which silently fails for this key type.
--
-- Confirmed against sales_forecast.computed_at: Edgetec's and Fynbos's
-- last REAL forecast rows were timestamped 2026-09-28 03:00 UTC -- the run
-- immediately BEFORE that migration landed. Every run since, including
-- 2026-09-29's, wrote zero for everyone. Morgenster never had a single
-- successful run at all, purely because its own client_dimensions rows
-- were only configured at 2026-09-28 12:31 UTC, about an hour before the
-- same migration -- so its first-ever eligible run was the one this
-- migration fixes. (WCSA's permanent zero rows are unrelated and expected
-- -- it's a template client with zero rows in sales_document_facts,
-- nothing to forecast.)
--
-- AUDIT before applying: searched every view/matview in public on both
-- Supabase projects for this same auth.role()='service_role' pattern.
-- v_sales_cube_monthly is the ONLY one that has it (staging never went
-- through the materialize migration, so nothing to fix there) -- this is a
-- scoped, one-view fix, not a symptom of a wider pattern.
--
-- FIX: also accept current_user = 'service_role' directly -- the actual
-- Postgres role the query executes as, which Supabase's docs confirm the
-- secret-key path genuinely switches to, rather than depending on JWT-claim
-- GUCs a non-JWT key doesn't set.
--
-- VERIFIED LIVE (production vnzflygyqslvlvndyhql): manually re-triggered
-- compute-forecast via the same net.http_post the cron job uses,
-- immediately after this migration -- Edgetec's forecast rows genuinely
-- refreshed (13:19:49 UTC), proving the access fix works. See
-- wyzesales_compute_forecast_daily_one_invocation_per_client.sql for what
-- happened next (fixing this uncovered a second, previously-hidden
-- problem) and the final, fully verified end state for Morgenster.

create or replace view v_sales_cube_monthly as
 SELECT mv.client_id,
    mv.month,
    mv.fiscal_year,
    mv.fiscal_month,
    mv.sales_person_code,
    mv.customer_code,
    mv.item_code,
    mv.category_code,
    mv.branch_code,
    mv.quantity,
    mv.value,
    mv.profit,
    mv.dim_1_code, mv.dim_2_code, mv.dim_3_code, mv.dim_4_code, mv.dim_5_code, mv.dim_6_code,
    mv.dim_7_code, mv.dim_8_code, mv.dim_9_code, mv.dim_10_code, mv.dim_11_code, mv.dim_12_code,
    mv.attr_1_code, mv.attr_2_code, mv.attr_3_code, mv.attr_4_code, mv.attr_5_code, mv.attr_6_code,
    mv.attr_7_code, mv.attr_8_code, mv.attr_9_code, mv.attr_10_code, mv.attr_11_code, mv.attr_12_code
   FROM mv_sales_cube_monthly mv
  WHERE current_user = 'service_role' OR (( SELECT auth.role() AS role)) = 'service_role'::text
UNION ALL
 SELECT mv.client_id,
    mv.month,
    mv.fiscal_year,
    mv.fiscal_month,
    mv.sales_person_code,
    mv.customer_code,
    mv.item_code,
    mv.category_code,
    mv.branch_code,
    mv.quantity,
    mv.value,
    mv.profit,
    mv.dim_1_code, mv.dim_2_code, mv.dim_3_code, mv.dim_4_code, mv.dim_5_code, mv.dim_6_code,
    mv.dim_7_code, mv.dim_8_code, mv.dim_9_code, mv.dim_10_code, mv.dim_11_code, mv.dim_12_code,
    mv.attr_1_code, mv.attr_2_code, mv.attr_3_code, mv.attr_4_code, mv.attr_5_code, mv.attr_6_code,
    mv.attr_7_code, mv.attr_8_code, mv.attr_9_code, mv.attr_10_code, mv.attr_11_code, mv.attr_12_code
   FROM profiles me
     JOIN mv_sales_cube_monthly mv ON mv.client_id = me.client_id
     LEFT JOIN client_dimensions cd ON cd.client_id = me.client_id AND cd.is_rls_scope
  WHERE me.id = (( SELECT auth.uid() AS uid))
    AND current_user <> 'service_role'
    AND (( SELECT auth.role() AS role)) IS DISTINCT FROM 'service_role'::text
    AND (me.level = 'adminuser'::user_level OR me.level = 'reguser'::user_level AND cd.dimension_key IS NOT NULL AND fn_reguser_rls_scope_value(me.client_id, me.*) IS NOT NULL AND fn_reguser_rls_scope_value(me.client_id, me.*) =
        CASE
            WHEN cd.resolution_kind = 'existing'::text THEN
            CASE
                WHEN cd.dimension_key = 'branch'::text THEN mv.branch_code
                ELSE NULL::text
            END
            WHEN cd.resolution_kind = 'fact_column'::text THEN to_jsonb(mv.*) ->> (cd.dimension_key || '_code'::text)
            WHEN cd.resolution_kind = 'customer_attribute'::text THEN to_jsonb(mv.*) ->> (replace(cd.dimension_key, 'dim_'::text, 'attr_'::text) || '_code'::text)
            ELSE NULL::text
        END OR me.level = 'user'::user_level AND me.rep_code = mv.sales_person_code);

grant select on v_sales_cube_monthly to anon, authenticated, service_role;
