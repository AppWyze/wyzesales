-- ============================================================================
-- WyzeSales — Customer Segments (RFM)
-- ============================================================================
-- Sixtieth migration. Craig, 2026-10-07: "Customer Segments" screen — every
-- customer with activity in a period, scored 1-5 on Recency (how recently they
-- bought), Frequency (number of invoices) and Monetary (net sales value), then
-- placed on a fixed 5 x 5 grid and given one of ten segment names.
--
-- Three functions, all read-only, all `language sql stable` (SECURITY INVOKER,
-- so row-level security on the underlying facts applies exactly as it does for
-- fn_sales_documents_page/_totals, which read the same view):
--
--   1. fn_customer_rfm(p_from_date, p_to_date, p_filters)
--        Helper. One row per customer who has at least one invoice in the
--        period and a positive net value (invoices less credit notes), with
--        their R/F/M numbers, 1-5 scores and segment_key. Not called by the
--        app directly (it can return thousands of rows, and the API caps a
--        response at 1000) - the two functions below read it.
--   2. fn_customer_segments_summary(...)   - <= 10 rows, one per segment.
--   3. fn_customer_segment_customers(...)  - the customers in ONE segment,
--        biggest first, capped at p_limit (default 500).
--
-- SCORING
--   Quintiles (ntile 5) ranked within THIS client's own active customers for
--   the period, so the segments always describe how a customer compares with
--   the rest of the same book. Ties (e.g. many customers with exactly one
--   invoice) are broken by net value, otherwise the many customers sharing
--   "1 invoice" would all land in the same quintile and leave the lowest
--   segments empty (found while building the mock-up).
--     r_score : 5 = bought most recently, 1 = least recently
--     f_score : 5 = most invoices
--     m_score : 5 = highest net value
--     fm_score = round((f_score + m_score) / 2)   -- the grid's vertical axis
--
-- SEGMENTS (r_score across, fm_score up) - keys are what the app maps to names:
--     cant   r1 fm5               champ  r5 fm4-5
--     risk   r1 fm3-4             loyal  r2-4 fm4-5
--     hib    r1 fm1-2             sleep  r2-3 fm3
--     attn   r2-3 fm1-2           pot    r4-5 fm2-3
--     prom   r4 fm1               recent r5 fm1
--
-- Invoices and credit notes only (matching Sales Analysis' revenue figures);
-- p_filters is the same dimension_key -> code map every other function takes,
-- applied through fn_document_row_matches_filters. Like the Sales Analysis
-- Table functions these set enable_nestloop = off (see migration 058 - the
-- planner badly misjudges the RLS-filtered facts and picks a nested loop).
-- ============================================================================

create or replace function fn_customer_rfm(
  p_from_date date,
  p_to_date date,
  p_filters jsonb default '{}'::jsonb
)
returns table (
  account_code text,
  customer_name text,
  rec_days int,
  frequency bigint,
  monetary numeric,
  r_score int,
  fm_score int,
  segment_key text
)
language sql stable
set enable_nestloop = off
as $$
  with base as (
    select
      v.account_code,
      max(v.customer_name) as customer_name,
      max(v.doc_date) filter (where v.document_kind::text = 'invoice') as last_invoice,
      count(distinct v.document) filter (where v.document_kind::text = 'invoice') as frequency,
      sum(v.value) as monetary
    from v_sales_documents v
    where v.document_kind::text in ('invoice', 'credit_note')
      and v.doc_date >= p_from_date
      and v.doc_date <= p_to_date
      and v.account_code is not null
      and fn_document_row_matches_filters(v, p_filters)
    group by v.account_code
    having count(*) filter (where v.document_kind::text = 'invoice') > 0
       and sum(v.value) > 0
  ),
  scored as (
    select
      b.*,
      (p_to_date - b.last_invoice) as rec_days,
      ntile(5) over (order by (p_to_date - b.last_invoice) desc, b.monetary) as r_score,
      ntile(5) over (order by b.frequency, b.monetary) as f_score,
      ntile(5) over (order by b.monetary) as m_score
    from base b
  ),
  graded as (
    select s.*, round((s.f_score + s.m_score) / 2.0)::int as fm_score from scored s
  )
  select
    g.account_code,
    g.customer_name,
    g.rec_days::int,
    g.frequency,
    g.monetary,
    g.r_score::int,
    g.fm_score,
    case
      when g.r_score = 1 and g.fm_score = 5 then 'cant'
      when g.r_score = 1 and g.fm_score in (3, 4) then 'risk'
      when g.r_score = 1 then 'hib'
      when g.r_score in (2, 3) and g.fm_score in (4, 5) then 'loyal'
      when g.r_score in (2, 3) and g.fm_score = 3 then 'sleep'
      when g.r_score in (2, 3) then 'attn'
      when g.r_score = 4 and g.fm_score in (4, 5) then 'loyal'
      when g.r_score = 4 and g.fm_score in (2, 3) then 'pot'
      when g.r_score = 4 then 'prom'
      when g.fm_score in (4, 5) then 'champ'
      when g.fm_score in (2, 3) then 'pot'
      else 'recent'
    end as segment_key
  from graded g;
$$;

grant execute on function fn_customer_rfm(date, date, jsonb) to authenticated;


create or replace function fn_customer_segments_summary(
  p_from_date date,
  p_to_date date,
  p_filters jsonb default '{}'::jsonb
)
returns table (
  segment_key text,
  customers bigint,
  total_value numeric,
  avg_value numeric,
  rec_min int,
  rec_max int,
  freq_min bigint,
  freq_max bigint,
  value_min numeric,
  value_max numeric,
  top_customers jsonb
)
language sql stable
set enable_nestloop = off
as $$
  with s as (select * from fn_customer_rfm(p_from_date, p_to_date, p_filters))
  select
    s.segment_key,
    count(*)::bigint,
    sum(s.monetary),
    round(avg(s.monetary), 2),
    min(s.rec_days),
    max(s.rec_days),
    min(s.frequency),
    max(s.frequency),
    min(s.monetary),
    max(s.monetary),
    (
      select coalesce(jsonb_agg(jsonb_build_object(
               'code', t.account_code, 'name', t.customer_name, 'value', t.monetary) order by t.monetary desc), '[]'::jsonb)
      from (
        select s2.account_code, s2.customer_name, s2.monetary
        from s s2
        where s2.segment_key = s.segment_key
        order by s2.monetary desc
        limit 3
      ) t
    )
  from s
  group by s.segment_key;
$$;

grant execute on function fn_customer_segments_summary(date, date, jsonb) to authenticated;


create or replace function fn_customer_segment_customers(
  p_from_date date,
  p_to_date date,
  p_segment_key text,
  p_filters jsonb default '{}'::jsonb,
  p_limit int default 500
)
returns table (
  account_code text,
  customer_name text,
  rec_days int,
  frequency bigint,
  monetary numeric
)
language sql stable
set enable_nestloop = off
as $$
  select r.account_code, r.customer_name, r.rec_days, r.frequency, r.monetary
  from fn_customer_rfm(p_from_date, p_to_date, p_filters) r
  where r.segment_key = p_segment_key
  order by r.monetary desc
  limit least(greatest(coalesce(p_limit, 500), 1), 1000);
$$;

grant execute on function fn_customer_segment_customers(date, date, text, jsonb, int) to authenticated;
