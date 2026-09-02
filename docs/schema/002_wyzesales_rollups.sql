-- ============================================================================
-- WyzeSales — Rollup Views (Supabase / Postgres)
-- ============================================================================
-- Second migration. Builds the per-dimension aggregates that the Sales
-- Analysis (Graph tab), YTD Comparative, Sales by [Dimension] (x5), and
-- Performance (x5) screens need — on top of the foundation laid in
-- 001_wyzesales_foundation.sql (clients, reference tables, sales_document_
-- facts, budget_figures, sales_forecast, v_sales_documents).
--
-- Design choice up front: the old system stored these as WIDE tables — one
-- row per entity with fixed columns TotalValYear1/2/3, TotalValMonth1/2/3,
-- TotalPftYear1/2/3, TotalPftMonth1/2/3 (SalesAnalysis.txt). This migration
-- instead builds one TIDY (long-format) view — one row per entity per fiscal
-- year/month — and leaves the "3 years + 3 months side by side, with
-- variance %" pivoting to the Flutter app. Reasons:
--   1. The wide shape hardcodes "3 years, 3 months" into the schema itself.
--      A tidy view has no such ceiling — matches the "configurable comparison
--      window" idea already flagged as a value-add in the screens review.
--   2. It's what let a real bug happen (see note in Section 2 below) — a
--      wide, hand-assembled row makes a copy/paste column swap possible in a
--      way a GROUP BY simply can't reproduce.
--   3. One shared view now serves Sales Analysis, YTD Comparative, and Sales
--      by [Dimension] — those three screens are really three different
--      pivots/filters over the same underlying numbers, not three different
--      data sources.
-- ============================================================================


-- ============================================================================
-- 1. HELPER — fiscal month label
-- ============================================================================
-- Explicit mapping rather than to_char(date,'Mon'), so the output is never at
-- the mercy of the database's locale setting. Matches the fiscal_month
-- check-constraint values already used on budget_figures/sales_forecast.

create or replace function fiscal_month_label(p_doc_date date)
returns text language sql immutable as $$
  select (array['Jan','Feb','Mar','Apr','May','Jun',
                'Jul','Aug','Sep','Oct','Nov','Dec'])[extract(month from p_doc_date)::int];
$$;


-- ============================================================================
-- 2. CORE ROLLUP — one row per dimension / entity / fiscal year / month
-- ============================================================================
-- Replaces SalesAnalysis.txt's customer x item x rep x category x location
-- grid. Restricted to actual sales (invoice/credit_note) — matches the old
-- ConsolidatedSales/SalesAnalysis scope; quotes and sales orders are served
-- directly by v_sales_documents (filtered by document_kind), not by this view.
--
-- NOTE — a bug found while building this migration, not previously flagged:
-- SalesAnalysisBuilder.cs deliberately preserves a copy/paste swap from the
-- original QlikView script — TotalPftYear1/TotalPftYear2 are assigned the
-- OPPOSITE fiscal-year offsets to TotalValYear1/TotalValYear2, so the profit
-- figure shown next to "Year 1" on screen actually belongs to "Year 2"'s
-- period, and vice versa (Year 3 is unaffected; quantity/value columns are
-- unaffected). It was preserved on purpose in the extract, per the standing
-- instruction to do a faithful port there. This view does NOT reproduce it —
-- there's no way to, structurally, since profit and value are summed by the
-- same fiscal_year group here rather than assembled into separate hand-
-- offset columns. Treating this the same as the branch and seasonal-forecast
-- bugs already confirmed: fixed, not preserved. Flagging here in case you
-- want to sanity-check historical Year 1/Year 2 profit figures against this
-- before fully trusting the comparison.
--
-- "Sub Category" is not included as a separate dimension: in the current
-- system it's mapped from the exact same lookup as Category (confirmed in
-- TransactionSalesBuilder.cs), so it's always identical to Category, not a
-- real second grouping level. The Category dimension below covers it.

create view v_dimension_monthly_sales
with (security_invoker = true) as
with base as (
  select
    client_id,
    date_trunc('month', doc_date)::date as month,
    fiscal_year,
    fiscal_month_label(doc_date) as fiscal_month,
    resolved_rep_code,
    account_code,
    item_code,
    department_code,
    branch_code,
    quantity, value, profit
  from v_sales_documents
  where document_kind in ('invoice', 'credit_note')
)
select client_id, 'sales_person'::text as dimension, resolved_rep_code as entity_code,
       month, fiscal_year, fiscal_month,
       sum(quantity) as quantity, sum(value) as value, sum(profit) as profit
from base
group by client_id, resolved_rep_code, month, fiscal_year, fiscal_month

union all

select client_id, 'customer', account_code,
       month, fiscal_year, fiscal_month,
       sum(quantity), sum(value), sum(profit)
from base
group by client_id, account_code, month, fiscal_year, fiscal_month

union all

select client_id, 'item', item_code,
       month, fiscal_year, fiscal_month,
       sum(quantity), sum(value), sum(profit)
from base
group by client_id, item_code, month, fiscal_year, fiscal_month

union all

select client_id, 'category', department_code,
       month, fiscal_year, fiscal_month,
       sum(quantity), sum(value), sum(profit)
from base
group by client_id, department_code, month, fiscal_year, fiscal_month

union all

select client_id, 'branch', branch_code,
       month, fiscal_year, fiscal_month,
       sum(quantity), sum(value), sum(profit)
from base
group by client_id, branch_code, month, fiscal_year, fiscal_month

union all

select client_id, 'company', 'ALL',
       month, fiscal_year, fiscal_month,
       sum(quantity), sum(value), sum(profit)
from base
group by client_id, month, fiscal_year, fiscal_month;

-- Usage:
--  - Sales Analysis (Graph tab): filter to one dimension+entity, order by
--    month, across as many fiscal years as the user selects.
--  - YTD Comparative: filter to one dimension+entity, pivot fiscal_month
--    against fiscal_year in the app, compute variance % between year pairs.
--  - Sales by [Dimension]: no entity filter (all entities for the chosen
--    dimension), pivot the trailing N fiscal years (group by fiscal_year)
--    and the trailing N individual months (filter/group by `month`) side by
--    side in the app.


-- ============================================================================
-- 3. PERFORMANCE — actuals vs. budget target vs. forecast, one row per
--    dimension / entity / fiscal month
-- ============================================================================
-- Serves the Performance screen (%Contribution, R Value, R Target, %Target,
-- R Profit, %GP, Quantity) directly. budget_figures and sales_forecast are
-- both one-row-per-month (no fiscal_year column) — same as the old *Budget
-- tables, where a month's target/forecast isn't year-scoped, so the join
-- below is on (dimension, entity_code, fiscal_month) only.
--
-- Worth a product decision later, not assumed here: today a budget target
-- for "March" applies every fiscal year with no history kept of past years'
-- targets. If you'd ever want to look back at what last year's target was
-- (vs. just this year's live number), budget_figures would need a
-- fiscal_year column added — a small, additive change, not a rebuild, so
-- flagging it as an option rather than doing it speculatively now.

create view v_dimension_performance
with (security_invoker = true) as
select
  s.client_id,
  s.dimension,
  s.entity_code,
  s.fiscal_year,
  s.fiscal_month,
  s.value as actual_value,
  s.quantity as actual_quantity,
  s.profit as actual_profit,
  case when s.value = 0 then 0
       else round(s.profit / s.value * 100, 2)
  end as gp_percent,
  b.budget_value as target_value,
  case when b.budget_value is null or b.budget_value = 0 then null
       else round(s.value / b.budget_value * 100, 2)
  end as target_percent,
  round(
    100.0 * s.value / nullif(
      sum(s.value) over (partition by s.client_id, s.dimension, s.fiscal_year, s.fiscal_month),
      0),
    2
  ) as contribution_percent,
  f.forecast_value,
  f.confidence as forecast_confidence
from v_dimension_monthly_sales s
left join budget_figures b
  on  b.client_id    = s.client_id
  and b.dimension    = s.dimension
  and b.entity_code  = s.entity_code
  and b.fiscal_month = s.fiscal_month
left join sales_forecast f
  on  f.client_id    = s.client_id
  and f.dimension    = s.dimension
  and f.entity_code  = s.entity_code
  and f.fiscal_month = s.fiscal_month;
