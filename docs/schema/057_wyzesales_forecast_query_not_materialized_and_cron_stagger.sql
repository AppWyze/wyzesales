-- ============================================================================
-- WyzeSales — fix compute-forecast "canceling statement due to statement
-- timeout" errors: un-hinted CTE materialization + a wider cron stagger
-- ============================================================================
-- Fifty-seventh migration. Craig, 2026-10-01, pasted a compute-forecast Edge
-- Function log showing three "forecast_input_series failed: canceling
-- statement due to statement timeout" errors in one night's run (dim_2,
-- dim_3, dim_6, all for Morgenster 1711 (Pty) Ltd, client_id
-- 6df7b560-3f65-4322-b5ca-eac8c29ef402 — by far the heaviest client,
-- ~259k of ~272k total sales_document_facts rows at the time).
--
-- ROOT CAUSE — v_dimension_monthly_sales' `with base as (...)` CTE had no
-- NOT MATERIALIZED hint, so Postgres always fully computes it as a standalone
-- step before any outer filter can reach it. Two compounding costs follow:
--
--   1. forecast_input_series() (schema/003) queries this view TWICE in one
--      call (once to find each entity's min/max active month, once to pull
--      the actual values via a LEFT JOIN) — two separate textual expansions
--      of the view, so the CTE gets recomputed from scratch each time, not
--      shared.
--   2. Within a single expansion, `base` underlies ALL 18 of the view's
--      UNION ALL branches (6 fixed dimensions + 12 generic dim_1..dim_12),
--      but because it's materialized, the per-dimension JOIN/filter that
--      only needs ONE of those 18 branches can't push `client_id = ...` (or
--      the dimension-constant pruning that would eliminate the other 17
--      branches outright) down into the scan that feeds `base`.
--
-- Confirmed live via EXPLAIN (ANALYZE, BUFFERS), run as service_role (the
-- role compute-forecast's calls actually use — `set local role
-- service_role` inside a rolled-back transaction) against Morgenster's
-- dim_2, the production client_dimensions row that appears in the log:
--
--   BEFORE: v_sales_cube_monthly's underlying `Seq Scan on
--   mv_sales_cube_monthly` carries NO client filter at all and runs TWICE
--   (once per forecast_input_series reference to the view) — 784ms, with an
--   external DISK-based sort (6.3MB) for the per-dimension GroupAggregate.
--   Table-size growth and/or concurrent cron dispatches (see below) turn
--   this into the production timeouts in the log.
--
--   AFTER (`with base as not materialized (...)`): the Seq Scan on
--   mv_sales_cube_monthly now carries `Filter: (client_id = ...)` and runs
--   only ONCE per forecast_input_series call; the GroupAggregate now fits in
--   memory (no disk sort) — 239ms, a ~3.3x improvement, same 1288 output
--   rows both before and after (verified byte-identical row count — this is
--   purely a planner/execution-strategy change, not a semantic one).
--
-- Applied for real via CREATE OR REPLACE VIEW (view bodies are otherwise
-- byte-identical to schema/052's version — the only change is the one
-- `not materialized` keyword) to BOTH Supabase projects: production
-- (vnzflygyqslvlvndyhql) and staging (uxyqthscnlznrjpyogwg, which also has
-- this view even though its own pg_cron compute-forecast job — jobid 1 — is
-- still the older single-invocation-for-everything shape and has never been
-- updated to the per-client+dimension dispatch documented in
-- wyzesales_compute_forecast_daily_one_invocation_per_client.sql; left as-is
-- today, out of scope for this fix, staging's data volume has never been
-- large enough to trip it).
--
-- SECONDARY FIX — wider cron dispatch stagger. compute_forecast_reapply_
-- and_flaky_zero_rows.sql already added a `perform pg_sleep(0.2)` between
-- each of the 38 per-client+dimension net.http_post dispatches on
-- production's cron.job id 3, on a "reduce concurrent load" theory — its own
-- header notes that 0.2s "did NOT reliably fix" that day's separate
-- zero-rows issue. net.http_post is fire-and-forget (queued to pg_net's own
-- background workers), so the gap between ISSUING dispatches was never a
-- hard guarantee of gaps between the resulting Edge Function invocations,
-- or their downstream queries, actually landing on Postgres — at 0.2s
-- apart, much of the 38-invocation batch can still be in flight
-- simultaneously. Widened to `pg_sleep(1.5)` (cron.alter_job, job_id 3) —
-- 38 x 1.5s ~= 57s total dispatch-loop time, still comfortably inside one
-- cron tick, but enough real separation between dispatches that far fewer
-- of the 38 invocations' queries are ever contending for the database at
-- once. This is a mitigation on top of the NOT MATERIALIZED fix above, not
-- a substitute for it — the query itself being ~3x cheaper and no longer
-- doing a double full-table pass is what actually lowers the odds of any
-- one dimension blowing the 2-minute statement_timeout; the wider stagger
-- just reduces how many of the 38 are competing for CPU/IO at the same
-- instant. Staging's cron job (id 1) is not on the per-dimension dispatch
-- shape at all, so there is nothing to stagger there today.
--
-- Not changed here (documented as follow-up ideas only): avoiding
-- forecast_input_series()'s double query of the view entirely (e.g. a
-- single CTE computing both the entity/month range and the values in one
-- pass) — a real further improvement, but the NOT MATERIALIZED fix alone
-- already took the representative Morgenster dim_2 case from "doing 2 full,
-- unfiltered table scans with a disk sort" to "doing 1 filtered, in-memory
-- one", which is the dominant cost by a wide margin.

create or replace view public.v_dimension_monthly_sales as
with base as not materialized (
  select
    v_sales_cube_monthly.client_id,
    v_sales_cube_monthly.month,
    v_sales_cube_monthly.fiscal_year,
    v_sales_cube_monthly.fiscal_month,
    v_sales_cube_monthly.sales_person_code,
    v_sales_cube_monthly.customer_code,
    v_sales_cube_monthly.item_code,
    v_sales_cube_monthly.category_code,
    v_sales_cube_monthly.branch_code,
    v_sales_cube_monthly.dim_1_code,
    v_sales_cube_monthly.dim_2_code,
    v_sales_cube_monthly.dim_3_code,
    v_sales_cube_monthly.dim_4_code,
    v_sales_cube_monthly.dim_5_code,
    v_sales_cube_monthly.dim_6_code,
    v_sales_cube_monthly.dim_7_code,
    v_sales_cube_monthly.dim_8_code,
    v_sales_cube_monthly.dim_9_code,
    v_sales_cube_monthly.dim_10_code,
    v_sales_cube_monthly.dim_11_code,
    v_sales_cube_monthly.dim_12_code,
    v_sales_cube_monthly.attr_1_code,
    v_sales_cube_monthly.attr_2_code,
    v_sales_cube_monthly.attr_3_code,
    v_sales_cube_monthly.attr_4_code,
    v_sales_cube_monthly.attr_5_code,
    v_sales_cube_monthly.attr_6_code,
    v_sales_cube_monthly.attr_7_code,
    v_sales_cube_monthly.attr_8_code,
    v_sales_cube_monthly.attr_9_code,
    v_sales_cube_monthly.attr_10_code,
    v_sales_cube_monthly.attr_11_code,
    v_sales_cube_monthly.attr_12_code,
    v_sales_cube_monthly.quantity,
    v_sales_cube_monthly.value,
    v_sales_cube_monthly.profit
  from v_sales_cube_monthly
)
select base.client_id, 'sales_person'::text as dimension, base.sales_person_code as entity_code, base.month, base.fiscal_year, base.fiscal_month, sum(base.quantity) as quantity, sum(base.value) as value, sum(base.profit) as profit
from base group by base.client_id, base.sales_person_code, base.month, base.fiscal_year, base.fiscal_month
union all
select base.client_id, 'customer'::text, base.customer_code, base.month, base.fiscal_year, base.fiscal_month, sum(base.quantity), sum(base.value), sum(base.profit)
from base group by base.client_id, base.customer_code, base.month, base.fiscal_year, base.fiscal_month
union all
select base.client_id, 'item'::text, base.item_code, base.month, base.fiscal_year, base.fiscal_month, sum(base.quantity), sum(base.value), sum(base.profit)
from base group by base.client_id, base.item_code, base.month, base.fiscal_year, base.fiscal_month
union all
select base.client_id, 'category'::text, base.category_code, base.month, base.fiscal_year, base.fiscal_month, sum(base.quantity), sum(base.value), sum(base.profit)
from base group by base.client_id, base.category_code, base.month, base.fiscal_year, base.fiscal_month
union all
select base.client_id, 'branch'::text, base.branch_code, base.month, base.fiscal_year, base.fiscal_month, sum(base.quantity), sum(base.value), sum(base.profit)
from base group by base.client_id, base.branch_code, base.month, base.fiscal_year, base.fiscal_month
union all
select base.client_id, 'company'::text, 'ALL'::text, base.month, base.fiscal_year, base.fiscal_month, sum(base.quantity), sum(base.value), sum(base.profit)
from base group by base.client_id, base.month, base.fiscal_year, base.fiscal_month
union all
select base.client_id, 'dim_1'::text, coalesce(case cd.resolution_kind when 'fact_column'::text then base.dim_1_code when 'customer_attribute'::text then base.attr_1_code else null::text end, 'UNASSIGNED'::text), base.month, base.fiscal_year, base.fiscal_month, sum(base.quantity), sum(base.value), sum(base.profit)
from base join client_dimensions cd on cd.client_id = base.client_id and cd.dimension_key = 'dim_1'::text
group by base.client_id, cd.resolution_kind, base.dim_1_code, base.attr_1_code, base.month, base.fiscal_year, base.fiscal_month
union all
select base.client_id, 'dim_2'::text, coalesce(case cd.resolution_kind when 'fact_column'::text then base.dim_2_code when 'customer_attribute'::text then base.attr_2_code else null::text end, 'UNASSIGNED'::text), base.month, base.fiscal_year, base.fiscal_month, sum(base.quantity), sum(base.value), sum(base.profit)
from base join client_dimensions cd on cd.client_id = base.client_id and cd.dimension_key = 'dim_2'::text
group by base.client_id, cd.resolution_kind, base.dim_2_code, base.attr_2_code, base.month, base.fiscal_year, base.fiscal_month
union all
select base.client_id, 'dim_3'::text, coalesce(case cd.resolution_kind when 'fact_column'::text then base.dim_3_code when 'customer_attribute'::text then base.attr_3_code else null::text end, 'UNASSIGNED'::text), base.month, base.fiscal_year, base.fiscal_month, sum(base.quantity), sum(base.value), sum(base.profit)
from base join client_dimensions cd on cd.client_id = base.client_id and cd.dimension_key = 'dim_3'::text
group by base.client_id, cd.resolution_kind, base.dim_3_code, base.attr_3_code, base.month, base.fiscal_year, base.fiscal_month
union all
select base.client_id, 'dim_4'::text, coalesce(case cd.resolution_kind when 'fact_column'::text then base.dim_4_code when 'customer_attribute'::text then base.attr_4_code else null::text end, 'UNASSIGNED'::text), base.month, base.fiscal_year, base.fiscal_month, sum(base.quantity), sum(base.value), sum(base.profit)
from base join client_dimensions cd on cd.client_id = base.client_id and cd.dimension_key = 'dim_4'::text
group by base.client_id, cd.resolution_kind, base.dim_4_code, base.attr_4_code, base.month, base.fiscal_year, base.fiscal_month
union all
select base.client_id, 'dim_5'::text, coalesce(case cd.resolution_kind when 'fact_column'::text then base.dim_5_code when 'customer_attribute'::text then base.attr_5_code else null::text end, 'UNASSIGNED'::text), base.month, base.fiscal_year, base.fiscal_month, sum(base.quantity), sum(base.value), sum(base.profit)
from base join client_dimensions cd on cd.client_id = base.client_id and cd.dimension_key = 'dim_5'::text
group by base.client_id, cd.resolution_kind, base.dim_5_code, base.attr_5_code, base.month, base.fiscal_year, base.fiscal_month
union all
select base.client_id, 'dim_6'::text, coalesce(case cd.resolution_kind when 'fact_column'::text then base.dim_6_code when 'customer_attribute'::text then base.attr_6_code else null::text end, 'UNASSIGNED'::text), base.month, base.fiscal_year, base.fiscal_month, sum(base.quantity), sum(base.value), sum(base.profit)
from base join client_dimensions cd on cd.client_id = base.client_id and cd.dimension_key = 'dim_6'::text
group by base.client_id, cd.resolution_kind, base.dim_6_code, base.attr_6_code, base.month, base.fiscal_year, base.fiscal_month
union all
select base.client_id, 'dim_7'::text, coalesce(case cd.resolution_kind when 'fact_column'::text then base.dim_7_code when 'customer_attribute'::text then base.attr_7_code else null::text end, 'UNASSIGNED'::text), base.month, base.fiscal_year, base.fiscal_month, sum(base.quantity), sum(base.value), sum(base.profit)
from base join client_dimensions cd on cd.client_id = base.client_id and cd.dimension_key = 'dim_7'::text
group by base.client_id, cd.resolution_kind, base.dim_7_code, base.attr_7_code, base.month, base.fiscal_year, base.fiscal_month
union all
select base.client_id, 'dim_8'::text, coalesce(case cd.resolution_kind when 'fact_column'::text then base.dim_8_code when 'customer_attribute'::text then base.attr_8_code else null::text end, 'UNASSIGNED'::text), base.month, base.fiscal_year, base.fiscal_month, sum(base.quantity), sum(base.value), sum(base.profit)
from base join client_dimensions cd on cd.client_id = base.client_id and cd.dimension_key = 'dim_8'::text
group by base.client_id, cd.resolution_kind, base.dim_8_code, base.attr_8_code, base.month, base.fiscal_year, base.fiscal_month
union all
select base.client_id, 'dim_9'::text, coalesce(case cd.resolution_kind when 'fact_column'::text then base.dim_9_code when 'customer_attribute'::text then base.attr_9_code else null::text end, 'UNASSIGNED'::text), base.month, base.fiscal_year, base.fiscal_month, sum(base.quantity), sum(base.value), sum(base.profit)
from base join client_dimensions cd on cd.client_id = base.client_id and cd.dimension_key = 'dim_9'::text
group by base.client_id, cd.resolution_kind, base.dim_9_code, base.attr_9_code, base.month, base.fiscal_year, base.fiscal_month
union all
select base.client_id, 'dim_10'::text, coalesce(case cd.resolution_kind when 'fact_column'::text then base.dim_10_code when 'customer_attribute'::text then base.attr_10_code else null::text end, 'UNASSIGNED'::text), base.month, base.fiscal_year, base.fiscal_month, sum(base.quantity), sum(base.value), sum(base.profit)
from base join client_dimensions cd on cd.client_id = base.client_id and cd.dimension_key = 'dim_10'::text
group by base.client_id, cd.resolution_kind, base.dim_10_code, base.attr_10_code, base.month, base.fiscal_year, base.fiscal_month
union all
select base.client_id, 'dim_11'::text, coalesce(case cd.resolution_kind when 'fact_column'::text then base.dim_11_code when 'customer_attribute'::text then base.attr_11_code else null::text end, 'UNASSIGNED'::text), base.month, base.fiscal_year, base.fiscal_month, sum(base.quantity), sum(base.value), sum(base.profit)
from base join client_dimensions cd on cd.client_id = base.client_id and cd.dimension_key = 'dim_11'::text
group by base.client_id, cd.resolution_kind, base.dim_11_code, base.attr_11_code, base.month, base.fiscal_year, base.fiscal_month
union all
select base.client_id, 'dim_12'::text, coalesce(case cd.resolution_kind when 'fact_column'::text then base.dim_12_code when 'customer_attribute'::text then base.attr_12_code else null::text end, 'UNASSIGNED'::text), base.month, base.fiscal_year, base.fiscal_month, sum(base.quantity), sum(base.value), sum(base.profit)
from base join client_dimensions cd on cd.client_id = base.client_id and cd.dimension_key = 'dim_12'::text
group by base.client_id, cd.resolution_kind, base.dim_12_code, base.attr_12_code, base.month, base.fiscal_year, base.fiscal_month;

-- Production-only: widen the compute-forecast-daily dispatch stagger from
-- 0.2s to 1.5s (cron.job id 3). See header notes above. Not run against
-- staging — its cron job (id 1) isn't on the per-dimension dispatch shape
-- this stagger applies to.
--
-- select cron.alter_job(
--   job_id := 3,
--   command := $cron$
--   do $$
--   declare
--     cd record;
--   begin
--     for cd in select client_id, dimension_key from client_dimensions loop
--       perform net.http_post(
--         url := (select decrypted_secret from vault.decrypted_secrets where name = 'wyzesales_project_url') || '/functions/v1/compute-forecast',
--         headers := jsonb_build_object(
--           'Content-type', 'application/json',
--           'apikey', (select decrypted_secret from vault.decrypted_secrets where name = 'wyzesales_anon_key'),
--           'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'wyzesales_anon_key')
--         ),
--         body := jsonb_build_object('client_id', cd.client_id, 'dimension', cd.dimension_key),
--         timeout_milliseconds := 60000
--       );
--       perform pg_sleep(1.5);
--     end loop;
--   end;
--   $$;
--   $cron$
-- );

-- VERIFIED (both vnzflygyqslvlvndyhql and uxyqthscnlznrjpyogwg): view fix
-- applied via CREATE OR REPLACE VIEW, confirmed live via
-- `pg_get_viewdef(...) ilike '%not materialized%'`. Production cron.job id
-- 3 confirmed on the 1.5s stagger via `command ilike '%pg_sleep(1.5)%'`.
-- EXPLAIN ANALYZE re-run (same Morgenster dim_2 case, as service_role) in
-- the same rolled-back test transaction that validated the fix BEFORE
-- applying it for real: 784ms -> 239ms, double unfiltered Seq Scan + disk
-- sort -> single filtered Seq Scan + in-memory HashAggregate, identical
-- 1288-row output both times.
