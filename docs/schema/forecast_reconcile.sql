-- forecast_reconcile.sql  (2026-10-08)
-- Goal: every dimension's entity forecasts sum to the company forecast, month by month,
-- and entities that the latest complete nightly batch did not refresh stop inflating the totals.
--
-- ALREADY APPLIED to production by Claude on 2026-10-08 (functions only). This file is the repo copy.
-- NOT yet scheduled: run the cron line at the bottom once.

create or replace function public.fn_forecast_reconcile(p_client_id uuid)
returns table(out_dimension text, rows_scaled bigint)
language plpgsql
set search_path to 'public'
as $f$
declare v_start timestamptz; v_zeroed bigint := 0;
begin
  -- Stale rows: entities that the latest COMPLETE nightly batch did not refresh
  -- (renamed/removed categories, customers whose only sales are this month, ...)
  -- keep their old forecast forever because compute-forecast only upserts. They
  -- would inflate the dimension totals, so they are set to 0 (not deleted).
  select min(q.dispatched_at) into v_start
  from forecast_dispatch_queue q
  where q.client_id = p_client_id and q.enqueued_at > now() - interval '12 hours'
  having count(*) > 0 and count(*) filter (where q.status <> 'ok') = 0;

  if v_start is not null then
    update sales_forecast f set forecast_value = 0
    where f.client_id = p_client_id and f.computed_at < v_start and f.forecast_value <> 0;
    get diagnostics v_zeroed = row_count;
  end if;

  return query
  with tot as (
    select sf.dimension as d, sf.fiscal_month as m, sum(sf.forecast_value) as s
    from sales_forecast sf
    where sf.client_id = p_client_id and sf.dimension <> 'company'
    group by 1, 2
  ), comp as (
    select sc.fiscal_month as m, sum(sc.forecast_value) as c
    from sales_forecast sc
    where sc.client_id = p_client_id and sc.dimension = 'company'
    group by 1
  ), ratio as (
    select t.d, t.m, comp.c / t.s as r
    from tot t join comp on comp.m = t.m
    where t.s > 0 and comp.c > 0 and abs(comp.c / t.s - 1) > 0.000001
  ), upd as (
    update sales_forecast f
    set forecast_value = round((f.forecast_value * ratio.r)::numeric, 2)
    from ratio
    where f.client_id = p_client_id and f.dimension = ratio.d and f.fiscal_month = ratio.m
      and f.forecast_value <> 0
    returning f.dimension as d
  )
  select u.d, count(*) from upd u group by 1
  union all
  select '_stale_zeroed'::text, v_zeroed;
end $f$;

revoke all on function public.fn_forecast_reconcile(uuid) from public, anon, authenticated;
grant execute on function public.fn_forecast_reconcile(uuid) to service_role;

-- Reconciles every client whose most recent forecast batch (last 12 hours) has fully
-- completed with no failures. Idempotent (already-reconciled months are skipped), so
-- it is safe to run every few minutes while the nightly queue drains.
create or replace function public.fn_forecast_reconcile_ready()
returns integer
language plpgsql
set search_path to 'public'
as $f$
declare c uuid; n int := 0;
begin
  for c in
    select q.client_id
    from forecast_dispatch_queue q
    where q.enqueued_at > now() - interval '12 hours'
    group by q.client_id
    having count(*) filter (where q.status in ('pending','dispatched','failed')) = 0
       and count(*) filter (where q.status = 'ok') > 0
  loop
    perform * from fn_forecast_reconcile(c);
    n := n + 1;
  end loop;
  return n;
end $f$;

revoke all on function public.fn_forecast_reconcile_ready() from public, anon, authenticated;
grant execute on function public.fn_forecast_reconcile_ready() to service_role;

-- ONE-TIME: schedule it (every 5 minutes, 03:00-07:59 UTC, right after each client's chunks finish).
select cron.schedule('forecast-reconcile', '*/5 3-7 * * *', $$select fn_forecast_reconcile_ready()$$);
