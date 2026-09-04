-- ============================================================================
-- WyzeSales — proactive alerting: budget variance + negative GP% (Item 3)
-- ============================================================================
-- Thirty-fourth migration. Item 3 of the post-forecast-deploy roadmap
-- (Decisions doc Section 74): "budget variance, negative GP%" per the
-- original functionality audit (Section 46). Craig chose a top-bar
-- notification bell as the surface (AskUserQuestion) and 15% under budget
-- as the starting variance threshold, exposed as a real Settings > Company
-- field (his own follow-up question: "where are these set and how would we
-- maintain them") rather than a database-only value the way forecast_settings
-- still is today.
--
-- Two alert types, both computed live from the CURRENT fiscal month's
-- month-to-date figures — nothing is persisted or scheduled (unlike
-- sales_forecast/compute-forecast), since both are simple derivations of
-- data that already exists and changes at most once a day when the extract
-- runs. No new Edge Function, no cron job.
--
-- 1. budget_variance: month-to-date actual is <threshold>% or more below a
--    PRORATED slice of the month's budget (budget * day-of-month /
--    days-in-month) — not the full month's budget, which would always look
--    "behind" for the first 29 days of a 30-day month regardless of real
--    pacing. Deliberately uses plain calendar day-of-month arithmetic, not
--    the fiscal_year()/fiscal_month_label() machinery those functions
--    encapsulate — this doesn't touch fiscal-year wraparound logic at all
--    (the exact area with the most past bugs in this project — Sections 22,
--    62-66), it only needs "what day of the month is it," which is the same
--    regardless of fiscal year start month.
-- 2. negative_gp: month-to-date GP% is negative (selling at a net loss on
--    what's been sold so far this period) — no threshold, any negative
--    value fires, matching Craig's original ask verbatim (Section 46). Worth
--    revisiting if this turns out noisy in practice (a single heavily-
--    discounted return early in the month could trip it briefly) — no
--    evidence either way yet since this hasn't run against real data.
--
-- A REAL BUG FOUND WHILE BUILDING THIS, not guessed: item/category budgets
-- are deliberately visible to EVERY level with no rep/branch scoping at all
-- (migration 031 — "no owner, visible to all"), but the ACTUAL figure
-- normally used to compare against that budget (v_dimension_monthly_sales,
-- built on v_sales_documents, built on sales_document_facts) is scoped by
-- sales_document_facts_select the SAME way it is for every other dimension —
-- meaning a plain 'user' querying the item/category actual for something
-- they didn't personally sell only sees THEIR OWN partial contribution, not
-- the true company-wide total, while still being shown the full company-wide
-- budget target. Confirmed empirically against a scratch Postgres: a rep
-- with R2,000 of a R5,000-company-wide-total item saw actual_value=2000
-- against target_value=10000 (a wildly worse-looking 20% vs the true 50%) —
-- this ALREADY happens today on the Performance screen's %Target column for
-- item/category rows viewed by anyone below adminuser, not something new
-- introduced here. Worth flagging to Craig as a separate, optional fix for
-- that existing screen; NOT fixed here since it's out of this migration's
-- scope, but it absolutely could NOT be allowed to propagate into an
-- actively-pushed alert, so fn_dimension_actuals_unrestricted below computes
-- the TRUE company-wide actual for item/category specifically — safe
-- specifically because migration 031 already decided those two dimensions
-- carry no privacy boundary for any level, so nothing is exposed here that
-- policy doesn't already intend every signed-in user to see. sales_person/
-- customer/branch/company are NOT run through this bypass — their actual and
-- target already share the same rep/branch boundary for every level that can
-- see them at all (verified: a 'user' level's budget_figures_select only
-- ever grants their OWN rep_code for sales_person, and fn_customer_
-- allocated_to_rep for customer — both of which the UNION visibility rule in
-- sales_document_facts_select's own 'user' branch already fully covers).
-- ============================================================================


-- ============================================================================
-- 1. SETTINGS — Settings > Company's new "Alert threshold" field
-- ============================================================================

create table alert_settings (
  client_id                      uuid primary key references clients(id) on delete cascade,
  budget_variance_threshold_pct  numeric not null default 15
    check (budget_variance_threshold_pct > 0 and budget_variance_threshold_pct <= 100)
);

alter table alert_settings enable row level security;

-- Same "you have a profile for this client" read scope as every other
-- settings/reference table (schema/006) — every level can see the threshold
-- that's currently in effect, not just admins.
create policy alert_settings_select on alert_settings
for select using (
  exists (select 1 from profiles p where p.id = auth.uid() and p.client_id = alert_settings.client_id)
);

-- Write access mirrors fiscal_year_settings_adminuser_insert/_update exactly
-- (schema/019) — same "a client's own adminuser can edit one Settings >
-- Company field, nobody else can" shape, same is_adminuser()/
-- get_my_client_id() helpers (schema/008), same INSERT+UPDATE split for the
-- same reason: a client created before this feature has no alert_settings
-- row yet, so the very first save has to INSERT, not UPDATE.
create policy alert_settings_adminuser_insert on alert_settings
for insert with check (is_adminuser() and client_id = get_my_client_id());

create policy alert_settings_adminuser_update on alert_settings
for update using (is_adminuser() and client_id = get_my_client_id())
with check (is_adminuser() and client_id = get_my_client_id());

grant select, insert, update on alert_settings to authenticated;


-- ============================================================================
-- 2. HELPER — true company-wide actual for item/category only (see header)
-- ============================================================================
-- security definer: v_dimension_monthly_sales is security_invoker, so
-- querying it from inside a security definer function runs it as this
-- function's OWNER (a superuser in Supabase), which bypasses
-- sales_document_facts_select entirely - confirmed empirically against a
-- scratch Postgres before relying on it (called as a plain 'user' role,
-- returned the true 5000 company total, not that user's own 2000).
-- Deliberately only ever CALLED for dimension in ('item','category') from
-- v_active_alerts below - this function itself doesn't restrict its own
-- `p_dimension` argument, so it must never be exposed or called for
-- sales_person/customer/branch/company, which DO have a real privacy
-- boundary this would bypass incorrectly.
create or replace function fn_dimension_actuals_unrestricted(p_client_id uuid, p_fiscal_year int, p_fiscal_month text)
returns table(dimension text, entity_code text, actual_value numeric, actual_profit numeric)
language sql security definer stable
set search_path = public
as $$
  select dimension, entity_code, sum(value), sum(profit)
  from v_dimension_monthly_sales
  where client_id = p_client_id and dimension in ('item', 'category')
    and fiscal_year = p_fiscal_year and fiscal_month = p_fiscal_month
  group by dimension, entity_code;
$$;

grant execute on function fn_dimension_actuals_unrestricted(uuid, int, text) to authenticated;


-- ============================================================================
-- 3. v_active_alerts — the view the app actually queries
-- ============================================================================

create view v_active_alerts
with (security_invoker = true) as
with current_period as (
  select
    c.id as client_id,
    fiscal_year(current_date, coalesce(fys.start_month, 3)) as fiscal_year,
    fiscal_month_label(current_date) as fiscal_month,
    extract(day from current_date)::int as day_of_month,
    extract(day from (date_trunc('month', current_date) + interval '1 month - 1 day'))::int as days_in_month,
    coalesce(als.budget_variance_threshold_pct, 15) as variance_threshold_pct
  from clients c
  left join fiscal_year_settings fys on fys.client_id = c.id
  left join alert_settings als on als.client_id = c.id
),
-- One call per CLIENT (cross join lateral against current_period, which has
-- exactly one row per client) - not per alert row - so this stays cheap
-- regardless of how many items/categories end up in the final result.
item_category_actuals as (
  select cp.client_id, a.dimension, a.entity_code, a.actual_value, a.actual_profit
  from current_period cp
  cross join lateral fn_dimension_actuals_unrestricted(cp.client_id, cp.fiscal_year, cp.fiscal_month) a
),
combined as (
  -- sales_person / customer / branch / company: v_dimension_performance
  -- already correctly scopes actual vs target to the same boundary for
  -- every level that can see them (see this migration's header).
  select
    p.client_id, p.dimension, p.entity_code, cp.fiscal_year, cp.fiscal_month,
    p.actual_value, p.gp_percent, p.target_value,
    cp.day_of_month, cp.days_in_month, cp.variance_threshold_pct
  from v_dimension_performance p
  join current_period cp
    on cp.client_id = p.client_id and cp.fiscal_year = p.fiscal_year and cp.fiscal_month = p.fiscal_month
  where p.dimension in ('sales_person', 'customer', 'branch', 'company')

  union all

  -- item / category: true company-wide actual (see fn_dimension_actuals_
  -- unrestricted above), budget read through the normal RLS-protected table
  -- reference (already open to every level for these two dimensions, so no
  -- practical difference, but no more bypassed than necessary either).
  select
    ica.client_id, ica.dimension, ica.entity_code, cp.fiscal_year, cp.fiscal_month,
    ica.actual_value,
    case when ica.actual_value = 0 then 0 else round(ica.actual_profit / ica.actual_value * 100, 2) end as gp_percent,
    b.budget_value as target_value,
    cp.day_of_month, cp.days_in_month, cp.variance_threshold_pct
  from item_category_actuals ica
  join current_period cp on cp.client_id = ica.client_id
  left join budget_figures b
    on b.client_id = ica.client_id and b.dimension = ica.dimension and b.entity_code = ica.entity_code
    and b.fiscal_month = cp.fiscal_month
)
select
  client_id, dimension, entity_code, fiscal_year, fiscal_month,
  'budget_variance'::text as alert_type,
  actual_value,
  target_value as budget_value,
  round(target_value * day_of_month::numeric / days_in_month, 2) as expected_to_date,
  round(
    (actual_value - (target_value * day_of_month::numeric / days_in_month))
    / nullif(target_value * day_of_month::numeric / days_in_month, 0) * 100,
    2
  ) as metric_percent
from combined
where target_value is not null and target_value > 0
  and (actual_value - (target_value * day_of_month::numeric / days_in_month))
      / nullif(target_value * day_of_month::numeric / days_in_month, 0) * 100 <= -variance_threshold_pct

union all

select
  client_id, dimension, entity_code, fiscal_year, fiscal_month,
  'negative_gp'::text as alert_type,
  actual_value,
  null::numeric as budget_value,
  null::numeric as expected_to_date,
  gp_percent as metric_percent
from combined
where actual_value <> 0 and gp_percent < 0;

grant select on v_active_alerts to authenticated;
