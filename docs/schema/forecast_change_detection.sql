-- forecast_change_detection.sql  (2026-10-09)  -- ALREADY APPLIED to production by Claude; this is the repo copy.
-- Goal: the nightly forecast only recomputes a client when its CLOSED-month history has
-- changed (new month closed, late/backdated load, credit note, reclassification, new
-- customer/item combination), plus a weekly safety-net run. Unchanged clients are skipped.
--
-- Fingerprint (per client) = md5 over, for every closed month in the cube:
--   row count, sum(value), and a mix term sum(value * hash(all entity codes))
-- plus the current month's row count (catches new entities appearing mid-month, which
-- affects dormancy) plus the current month key and the client's dimension list.
-- The mix term makes a reclassification between entities (same total, different
-- customer/item/category) change the fingerprint.
--
-- Lifecycle:  enqueue  -> writes queued_fingerprint, queues the client's chunks
--             reconcile_ready (client fully ok) -> copies queued_fingerprint to ok_fingerprint
--             next enqueue -> skips a client if fingerprint = ok_fingerprint AND ok_at < 7 days old
-- A failed or incomplete run never updates ok_fingerprint, so it is retried next night.

create table if not exists public.forecast_client_fingerprint (
  client_id          uuid primary key,
  queued_fingerprint text,
  queued_at          timestamptz,
  ok_fingerprint     text,
  ok_at              timestamptz
);
alter table public.forecast_client_fingerprint enable row level security;
revoke all on public.forecast_client_fingerprint from public, anon, authenticated;
grant all on public.forecast_client_fingerprint to service_role;

-- Fingerprint of one client's forecast inputs. Must run as service_role (cube is RLS-gated).
create or replace function public.fn_forecast_fingerprint(p_client_id uuid)
returns text
language sql
stable
set search_path to 'public'
as $f$
  with cm as (select date_trunc('month', current_date)::date as m0),
  closed as (
    select c.month,
           count(*) as n,
           round(sum(c.value), 2) as s,
           round(sum(c.value * (hashtext(concat_ws('|',
             c.customer_code, c.item_code, c.sales_person_code, c.category_code, c.branch_code,
             c.dim_1_code, c.dim_2_code, c.dim_3_code, c.dim_4_code, c.dim_5_code, c.dim_6_code,
             c.dim_7_code, c.dim_8_code, c.dim_9_code, c.dim_10_code, c.dim_11_code, c.dim_12_code
           )) % 100003)), 2) as mix
    from mv_sales_cube_monthly c, cm
    where c.client_id = p_client_id and c.month < cm.m0
    group by c.month
  ),
  cur as (
    select count(*) as n from mv_sales_cube_monthly c, cm
    where c.client_id = p_client_id and c.month >= cm.m0
  ),
  dims as (
    select string_agg(dimension_key, ',' order by dimension_key) as d
    from client_dimensions where client_id = p_client_id
  )
  select md5(
    (select m0::text from cm) || '#' ||
    coalesce((select string_agg(month::text || ':' || n || ':' || s || ':' || mix, ';' order by month) from closed), '') || '#' ||
    (select n::text from cur) || '#' ||
    coalesce((select d from dims), '')
  );
$f$;

revoke all on function public.fn_forecast_fingerprint(uuid) from public, anon, authenticated;
grant execute on function public.fn_forecast_fingerprint(uuid) to service_role;

-- Enqueue that skips unchanged clients.
-- p_force => true queues every client (manual full refresh): select fn_forecast_enqueue(true);
-- (The old zero-arg fn_forecast_enqueue() is kept as a thin wrapper that calls (false);
--  the nightly cron job 5 now calls fn_forecast_enqueue(false) explicitly. The wrapper can be
--  dropped later:  drop function public.fn_forecast_enqueue();  -- then no-arg calls use the default.)

create or replace function public.fn_forecast_enqueue(p_force boolean default false)
returns integer
language plpgsql
set search_path to 'public'
as $function$
declare
  cd record; cl record; n int; v_total int := 0; plan jsonb := '[]'::jsonb;
  fp text; ok_fp text; ok_ts timestamptz; due boolean;
begin
  delete from forecast_dispatch_queue where enqueued_at < now() - interval '30 days';
  update forecast_dispatch_queue set status = 'skipped' where status in ('pending');

  -- the cube view only answers to service_role, so read it as that role
  set local role service_role;
  for cl in select distinct client_id from client_dimensions order by client_id loop
    fp := fn_forecast_fingerprint(cl.client_id);
    select f.ok_fingerprint, f.ok_at into ok_fp, ok_ts
    from forecast_client_fingerprint f where f.client_id = cl.client_id;

    due := p_force
           or ok_fp is distinct from fp
           or ok_ts is null
           or ok_ts < now() - interval '7 days';

    if due then
      insert into forecast_client_fingerprint (client_id, queued_fingerprint, queued_at)
      values (cl.client_id, fp, now())
      on conflict (client_id) do update
        set queued_fingerprint = excluded.queued_fingerprint, queued_at = excluded.queued_at;

      for cd in select client_id, dimension_key from client_dimensions
                where client_id = cl.client_id order by dimension_key loop
        select count(distinct s.entity_code) into n from forecast_input_series(cd.client_id, cd.dimension_key) s;
        plan := plan || jsonb_build_object('c', cd.client_id, 'd', cd.dimension_key,
                                           'chunks', greatest(1, ceil(n / 500.0)::int));
      end loop;
    end if;
  end loop;
  reset role;

  insert into forecast_dispatch_queue (client_id, dimension, chunk, chunks)
  select (p->>'c')::uuid, p->>'d', g, (p->>'chunks')::int
  from jsonb_array_elements(plan) p, lateral generate_series(0, (p->>'chunks')::int - 1) g
  order by (p->>'c'), (p->>'d'), g;
  get diagnostics v_total = row_count;
  return v_total;
end $function$;

revoke all on function public.fn_forecast_enqueue(boolean) from public, anon, authenticated;
grant execute on function public.fn_forecast_enqueue(boolean) to service_role;

create or replace function public.fn_forecast_enqueue()
returns integer
language sql
set search_path to 'public'
as $f$ select public.fn_forecast_enqueue(false); $f$;

-- ALREADY APPLIED to production 2026-10-09 (cron job 5 altered):
select cron.alter_job(5, command := 'select fn_forecast_enqueue(false)');

-- Reconcile hook: once a client's batch is fully ok and reconciled, record its fingerprint as done.
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
    update forecast_client_fingerprint f
       set ok_fingerprint = f.queued_fingerprint, ok_at = now()
     where f.client_id = c
       and f.queued_fingerprint is not null
       and (f.ok_fingerprint is distinct from f.queued_fingerprint or f.ok_at < f.queued_at);
    n := n + 1;
  end loop;
  return n;
end $f$;

revoke all on function public.fn_forecast_reconcile_ready() from public, anon, authenticated;
grant execute on function public.fn_forecast_reconcile_ready() to service_role;
