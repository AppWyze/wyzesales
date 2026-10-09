-- ============================================================================
-- WyzeSales — Item Segments
-- ============================================================================
-- Sixty-first migration. ALREADY APPLIED to production 2026-10-09 (additive only: two columns,
-- five read-only functions); this file is the repo copy. Also run once, per client:
--   update clients set item_segments_enabled = false where code = 'EDGE';
--   update clients set item_segments_excluded_codes = <Gratuity, Freight, Tasting lines, MEAL> where code = 'MORG';
-- (already done). Craig, 2026-10-09, after reviewing a mock-up built
-- from real Morgenster and Edgetec numbers: an "Item Segments" screen next to
-- Customer Segments. Every item with sales in the last 12 months is placed by
-- what its sales are doing (across) and how much it matters (down), plus the
-- items that have gone quiet.
--
--   LIFECYCLE (seg), decided in this order, per item:
--     dormant     last sale (any month, incl. the current one) is 12+ months ago
--     stopped     sold in the last 12 months, but nothing in the last 4 calendar
--                 months (the 3 closed months plus the current one)
--     new         first ever sale is inside the last 12 months
--     occasional  sold in 5 or fewer of the last 12 closed months
--     growing     last-12-month sales >= 115% of the prior 12 months
--     declining   last-12-month sales <= 85% of the prior 12 months
--     steady      anything else
--   "Last 12 months" = the 12 closed calendar months before the month of
--   p_as_of. Items first sold less than 24 months ago are compared on the
--   months they existed in the prior window, scaled to 12.
--
--   ABC CLASS (abc), over items that sold in the last 12 months (not dormant,
--   positive value): A = items making up the first 80% of sales, B = next 15%,
--   C = the last 5%. Dormant items have no class.
--
--   CONCENTRATION: an A or B item whose last-12-month buyers number two or
--   fewer, or where one customer is 60% or more of the item.
--
-- PER-CLIENT CONTROLS (two new columns on clients; Platform Admin > Edit client)
--   item_segments_enabled         false hides the screen; every function below
--                                 then returns no rows for that client.
--   item_segments_excluded_codes  item codes left out entirely (service and
--                                 non-stock lines such as Gratuity, Freight).
--
-- Like Customer Segments: read-only, language sql stable, SECURITY INVOKER (row
-- level security on v_sales_documents applies), invoices and credit notes only,
-- p_filters is the same dimension_key -> code map every other function takes,
-- enable_nestloop = off (see migration 058). Value is invoices less credit
-- notes. Year / Quarter / Month filters do not apply (the screen has its own
-- rolling 12 months). Dormant items are items whose last sale is 12 or more months ago.
-- ============================================================================

alter table public.clients add column if not exists item_segments_enabled boolean not null default true;
alter table public.clients add column if not exists item_segments_excluded_codes text[] not null default '{}';


-- Helper: the invoice / credit-note lines the other functions read, one row per
-- document line, already narrowed by the client switches and the filters. The
-- five built-in dimensions (Sales Person, Customer, Item, Category, Branch) are
-- matched straight on their columns, which is fast. Configurable dimension
-- filters (dim_N / customer attributes) go through fn_document_row_matches_filters,
-- which is slow per row (about 30 s over Morgenster's full history), so that path
-- only looks at the last 36 months.
create or replace function public.fn_item_segment_lines(
  p_as_of date,
  p_filters jsonb default '{}'::jsonb
)
returns table (item_code text, item_name text, account_code text, m date, value numeric)
language plpgsql stable
set enable_nestloop = off
as $$
declare
  f jsonb := coalesce(jsonb_strip_nulls(p_filters), '{}'::jsonb);
  rest jsonb := coalesce(jsonb_strip_nulls(p_filters), '{}'::jsonb) - array['sales_person', 'customer', 'item', 'category', 'branch'];
begin
  if rest = '{}'::jsonb then
    return query
      select v.item_code, v.item_name, v.account_code, date_trunc('month', v.doc_date)::date, v.value
      from v_sales_documents v
      join clients c on c.id = v.client_id and c.item_segments_enabled
      where v.document_kind::text in ('invoice', 'credit_note')
        and v.item_code is not null and v.item_code <> ''
        and v.doc_date <= p_as_of
        and not (v.item_code = any (c.item_segments_excluded_codes))
        and (not (f ? 'sales_person') or v.resolved_rep_code = f ->> 'sales_person')
        and (not (f ? 'customer') or v.account_code = f ->> 'customer')
        and (not (f ? 'item') or v.item_code = f ->> 'item')
        and (not (f ? 'category') or v.department_code = f ->> 'category')
        and (not (f ? 'branch') or v.branch_code = f ->> 'branch');
  else
    return query
      select v.item_code, v.item_name, v.account_code, date_trunc('month', v.doc_date)::date, v.value
      from v_sales_documents v
      join clients c on c.id = v.client_id and c.item_segments_enabled
      where v.document_kind::text in ('invoice', 'credit_note')
        and v.item_code is not null and v.item_code <> ''
        and v.doc_date <= p_as_of
        and v.doc_date >= (date_trunc('month', p_as_of) - interval '36 months')::date
        and not (v.item_code = any (c.item_segments_excluded_codes))
        and (not (f ? 'sales_person') or v.resolved_rep_code = f ->> 'sales_person')
        and (not (f ? 'customer') or v.account_code = f ->> 'customer')
        and (not (f ? 'item') or v.item_code = f ->> 'item')
        and (not (f ? 'category') or v.department_code = f ->> 'category')
        and (not (f ? 'branch') or v.branch_code = f ->> 'branch')
        and fn_document_row_matches_filters(v, rest);
  end if;
end;
$$;

revoke all on function public.fn_item_segment_lines(date, jsonb) from public, anon;
grant execute on function public.fn_item_segment_lines(date, jsonb) to authenticated;


create or replace function public.fn_item_segments_base(
  p_as_of date,
  p_filters jsonb default '{}'::jsonb
)
returns table (
  item_code text,
  item_name text,
  first_m date,
  last_m date,
  t12 numeric,
  p12 numeric,
  act12 int,
  custs int,
  top_share numeric,
  seg text,
  abc text
)
language sql stable
set enable_nestloop = off
as $$
  with w as (select date_trunc('month', p_as_of)::date as m0),
  lines as materialized (
    select * from fn_item_segment_lines(p_as_of, p_filters)
  ),
  im as (
    select l.item_code, max(l.item_name) as item_name, l.m, sum(l.value) as v
    from lines l group by l.item_code, l.m
  ),
  it as (
    select i.item_code,
      coalesce(nullif(trim(max(i.item_name)), ''), i.item_code) as item_name,
      min(i.m) filter (where i.v > 0) as first_m,
      max(i.m) filter (where i.v > 0) as last_m,
      coalesce(sum(i.v) filter (where i.m >= w.m0 - interval '12 months' and i.m < w.m0), 0) as t12,
      coalesce(sum(i.v) filter (where i.m >= w.m0 - interval '24 months' and i.m < w.m0 - interval '12 months'), 0) as p12,
      (count(*) filter (where i.m >= w.m0 - interval '12 months' and i.m < w.m0 and i.v > 0))::int as act12
    from im i, w
    group by i.item_code, w.m0
    having max(i.m) filter (where i.v > 0) is not null
  ),
  cu as (
    select l.item_code, l.account_code, sum(l.value) as v
    from lines l, w
    where l.m >= w.m0 - interval '12 months' and l.m < w.m0
    group by l.item_code, l.account_code
  ),
  cb as (
    select cu.item_code,
           (count(*) filter (where cu.v > 0))::int as custs,
           coalesce(max(cu.v) / nullif(sum(cu.v) filter (where cu.v > 0), 0), 0) as top_share
    from cu group by cu.item_code
  ),
  cls as (
    select it.*,
      -- prior-window sales scaled to 12 months for items younger than 24 months
      case when it.first_m >= w.m0 - interval '24 months'
           then it.p12 * 12.0 / greatest(1, least(12,
                  ((extract(year from w.m0 - interval '12 months') - extract(year from it.first_m)) * 12
                   + extract(month from w.m0 - interval '12 months') - extract(month from it.first_m))::int))
           else it.p12 end as p12_scaled,
      case
        when it.last_m < w.m0 - interval '12 months' then 'dormant'
        when it.last_m <= w.m0 - interval '4 months' then 'stopped'
        when it.first_m >= w.m0 - interval '12 months' then 'new'
        when it.act12 <= 5 then 'occasional'
        else 'trend'
      end as seg0
    from it, w
  ),
  graded as (
    select c.*,
      case
        when c.seg0 <> 'trend' then c.seg0
        when c.p12 <= 0 then 'growing'
        when c.t12 >= 1.15 * c.p12_scaled then 'growing'
        when c.t12 <= 0.85 * c.p12_scaled then 'declining'
        else 'steady'
      end as seg
    from cls c
  ),
  act as (select g.* from graded g where g.seg <> 'dormant' and g.t12 > 0),
  ranked as (
    select a.item_code,
           sum(a.t12) over (order by a.t12 desc, a.item_code) / sum(a.t12) over () as cum,
           a.t12 / sum(a.t12) over () as share
    from act a
  ),
  abcd as (
    select r.item_code,
           case when r.cum - r.share < 0.80 then 'A'
                when r.cum - r.share < 0.95 then 'B'
                else 'C' end as abc
    from ranked r
  )
  select g.item_code, g.item_name, g.first_m, g.last_m, g.t12, g.p12,
         g.act12, coalesce(cb.custs, 0), coalesce(cb.top_share, 0), g.seg, a.abc
  from graded g
  left join abcd a on a.item_code = g.item_code
  left join cb on cb.item_code = g.item_code;
$$;

revoke all on function public.fn_item_segments_base(date, jsonb) from public, anon;
grant execute on function public.fn_item_segments_base(date, jsonb) to authenticated;


-- One row per (segment, ABC class) that has at least one item, plus one row for
-- dormant items (abc = '-'). total_value = last-12-month sales; for dormant it
-- is 0 and prior_value carries what they sold in the 12 months before that.
create or replace function public.fn_item_segments_summary(
  p_as_of date,
  p_filters jsonb default '{}'::jsonb
)
returns table (
  segment_key text,
  abc text,
  items bigint,
  total_value numeric,
  prior_value numeric,
  top_items jsonb
)
language sql stable
set enable_nestloop = off
as $$
  with b as (
    select x.*, coalesce(x.abc, '-') as abc_key
    from fn_item_segments_base(p_as_of, p_filters) x
    where x.seg = 'dormant' or x.abc is not null
  ),
  g as (
    select b.seg, b.abc_key,
           count(*) as items,
           sum(case when b.seg = 'dormant' then 0 else b.t12 end) as total_value,
           sum(case when b.seg = 'dormant' then greatest(b.p12, 0) else 0 end) as prior_value
    from b group by b.seg, b.abc_key
  )
  select g.seg, g.abc_key, g.items, g.total_value, g.prior_value,
    (
      select coalesce(jsonb_agg(jsonb_build_object(
               'code', t.item_code, 'name', t.item_name,
               'value', case when t.seg = 'dormant' then t.p12 else t.t12 end,
               'customers', t.custs,
               'last_month', to_char(t.last_m, 'YYYY-MM')
             ) order by case when t.seg = 'dormant' then t.p12 else t.t12 end desc), '[]'::jsonb)
      from (
        select b2.* from b b2
        where b2.seg = g.seg and b2.abc_key = g.abc_key
        order by case when b2.seg = 'dormant' then b2.p12 else b2.t12 end desc
        limit 4
      ) t
    )
  from g;
$$;

revoke all on function public.fn_item_segments_summary(date, jsonb) from public, anon;
grant execute on function public.fn_item_segments_summary(date, jsonb) to authenticated;


-- The items in ONE cell (segment + class), or all dormant items ('dormant', '-'),
-- biggest first, capped at p_limit (never more than 1000).
create or replace function public.fn_item_segment_items(
  p_as_of date,
  p_segment_key text,
  p_abc text,
  p_filters jsonb default '{}'::jsonb,
  p_limit int default 500
)
returns table (
  item_code text,
  item_name text,
  value numeric,
  prior_value numeric,
  customers int,
  first_month text,
  last_month text
)
language sql stable
set enable_nestloop = off
as $$
  select b.item_code, b.item_name,
         case when b.seg = 'dormant' then 0 else b.t12 end,
         greatest(b.p12, 0),
         b.custs,
         to_char(b.first_m, 'YYYY-MM'),
         to_char(b.last_m, 'YYYY-MM')
  from fn_item_segments_base(p_as_of, p_filters) b
  where b.seg = p_segment_key
    and coalesce(b.abc, '-') = p_abc
  order by case when b.seg = 'dormant' then b.p12 else b.t12 end desc, b.item_code
  limit least(greatest(coalesce(p_limit, 500), 1), 1000);
$$;

revoke all on function public.fn_item_segment_items(date, text, text, jsonb, int) from public, anon;
grant execute on function public.fn_item_segment_items(date, text, text, jsonb, int) to authenticated;


-- A and B items that depend on one or two customers. One row (zeros when the
-- screen is switched off or there are no items).
create or replace function public.fn_item_concentration(
  p_as_of date,
  p_filters jsonb default '{}'::jsonb
)
returns table (
  ab_items bigint,
  risky_items bigint,
  risky_a_items bigint,
  risky_a_value numeric,
  top_items jsonb
)
language sql stable
set enable_nestloop = off
as $$
  with b as (
    select x.* from fn_item_segments_base(p_as_of, p_filters) x where x.abc in ('A', 'B')
  ),
  r as (select b.* from b where b.custs <= 2 or b.top_share >= 0.6)
  select
    (select count(*) from b),
    (select count(*) from r),
    (select count(*) from r where r.abc = 'A'),
    (select coalesce(sum(r.t12), 0) from r where r.abc = 'A'),
    (
      select coalesce(jsonb_agg(jsonb_build_object(
               'code', t.item_code, 'name', t.item_name, 'value', t.t12,
               'customers', t.custs, 'top_share', round(t.top_share * 100)
             ) order by t.t12 desc), '[]'::jsonb)
      from (select r2.* from r r2 order by r2.t12 desc limit 5) t
    );
$$;

revoke all on function public.fn_item_concentration(date, jsonb) from public, anon;
grant execute on function public.fn_item_concentration(date, jsonb) to authenticated;
