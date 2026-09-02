-- ============================================================================
-- WyzeSales — Forecast Input Series Helper (Supabase / Postgres)
-- ============================================================================
-- Third migration. One function, used by the compute-forecast Edge Function
-- (supabase/functions/compute-forecast) to fetch a clean, gap-free monthly
-- series per entity for a given client + dimension.
--
-- Why this needs to exist rather than just querying v_dimension_monthly_sales
-- directly: that view has one row per month *that had any sales activity* —
-- a month with zero sales for an entity that was otherwise active produces no
-- row at all, same as a month before the entity existed. Forecasting needs to
-- tell those two apart (see Wyzesales_Forecast_Redesign.md Section 3): a
-- genuine zero month is real data the smoothing should see; a month before
-- the entity's first-ever sale should be excluded from the series entirely,
-- not treated as a zero. This function draws that line by generating the
-- full calendar-month series from each entity's first activity month to its
-- OWN last activity month, filling only the genuine in-between gaps with
-- zero.
--
-- Deliberately NOT extended to the current calendar month: caught while
-- testing this migration against seeded data. Ending the series at now()
-- instead of at the entity's actual last sale means that if the daily
-- extract ever stalls, or a slower-moving entity (e.g. a seasonal item) just
-- hasn't sold recently, every month since its last real sale would be
-- fabricated as a zero — which would train the forecast to believe demand
-- had collapsed, when really the data simply hasn't caught up yet or the
-- entity is between orders. Ending at max(month) means h=1 in the Edge
-- Function is always "the month after this entity's last known sale," which
-- in a healthy, current pipeline is the same thing as "next calendar month"
-- anyway — but degrades safely if the pipeline or an entity ever goes quiet.
-- ============================================================================

create or replace function forecast_input_series(p_client_id uuid, p_dimension text)
returns table(entity_code text, month date, value numeric)
language sql stable as $$
  with entities as (
    select
      v.entity_code,
      min(v.month) as start_month,
      max(v.month) as end_month
    from v_dimension_monthly_sales v
    where v.client_id = p_client_id
      and v.dimension = p_dimension
    group by v.entity_code
  ),
  full_series as (
    select
      e.entity_code,
      gs.month::date as month
    from entities e
    cross join lateral generate_series(
      e.start_month,
      e.end_month,
      interval '1 month'
    ) as gs(month)
  )
  select
    fs.entity_code,
    fs.month,
    coalesce(v.value, 0) as value
  from full_series fs
  left join v_dimension_monthly_sales v
    on  v.client_id    = p_client_id
    and v.dimension    = p_dimension
    and v.entity_code  = fs.entity_code
    and v.month        = fs.month
  order by fs.entity_code, fs.month;
$$;

-- Used as: select * from forecast_input_series('<client-uuid>', 'customer');
-- Returns oldest -> newest per entity, so the Edge Function can feed it
-- straight into the Holt-Winters recursion without any further sorting or
-- gap-filling on the JS side.
