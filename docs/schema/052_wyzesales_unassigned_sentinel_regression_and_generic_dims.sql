-- ============================================================================
-- WyzeSales — fix the UNASSIGNED-sentinel regression (migration 039) and
-- extend it to the twelve generic dimensions
-- ============================================================================
-- Fifty-second migration. Root cause of "compute-forecast reports success
-- but Budgets shows nothing for Edgetec" (Craig, 2026-09-07): traced through
-- the curl response (rowsWritten: 3084 for Edgetec) to sales_forecast
-- actually holding ZERO rows for Edgetec, for ANY dimension — not just the
-- Market (dim_2) one Craig happened to check.
--
-- WHY: sales_forecast.entity_code is `text not null` (schema/001). compute-
-- forecast accumulates every dimension's forecast rows for a client into one
-- array, then issues a SINGLE upsert for the whole client at the end. A
-- Postgres multi-row INSERT is all-or-nothing — one row with a NULL
-- entity_code fails the entire statement, for every dimension in that batch,
-- not just the offending one. compute-forecast only logs the resulting
-- upsertError to console (never surfaced in the JSON response — see the
-- companion Edge Function fix below), so this looked like success from the
-- curl output alone.
--
-- Verified against the scratch DB (mirrors Edgetec's real shape):
--   select dimension, count(*) filter (where entity_code is null), count(*)
--   from v_dimension_monthly_sales where client_id = '<edgetec>' group by dimension;
-- returned null entity_code rows on sales_person (8 of 355 — unattributed
-- invoice lines), branch (36 of 36 — Edgetec never used branch at all), and
-- dim_1/dim_2/dim_3/dim_4/dim_5 (1/36/1/1/32 — unmapped fact-column or
-- customer-attribute values). Any ONE of these is enough to sink the whole
-- upsert; Edgetec had six.
--
-- THE REGRESSION: migration 024 already solved exactly this for the
-- original 3 nullable columns — `coalesce(resolved_rep_code(...),
-- 'UNASSIGNED')`, `coalesce(f.warehouse_code, 'UNASSIGNED')`,
-- `coalesce(it.department_code, 'UNASSIGNED')` on v_sales_documents, with a
-- detailed header explaining exactly this failure mode (there: a bad cast
-- crashing a screen; here: a bad NOT NULL crashing an upsert — same disease).
-- Migration 039's `create or replace view v_sales_documents`, written to
-- append the 24 new dim_N_code/attr_N_code columns, was built by extending
-- schema/001's ORIGINAL column list rather than schema/024's already-patched
-- one — silently reverting all three coalesces back to raw nullable values.
-- Nothing caught this at the time because nothing before compute-forecast's
-- single-batch upsert ever needed a hard NOT NULL guarantee on entity_code;
-- every screen either tolerates a null row (blank cell) or, per the earlier
-- fix this session (sales_coverage.dart's EntitySalesHistory.fromMap), was
-- separately hardened against it in Dart. This migration restores the
-- original SQL-level fix at its actual source instead of leaving it to
-- accumulate more one-off Dart patches.
--
-- THE EXTENSION: schema/039's own 12 generic dim_N/attr_N branches never had
-- an UNASSIGNED treatment to regress FROM — they didn't exist yet in
-- migration 024. Same principle, same sentinel, applied for the first time:
-- a sale with no Group/Market/Revenue Split/Category Type/Business Unit
-- (or any future client's own generic dimension) classified should show up
-- as "Unassigned," not silently vanish from that dimension's rollup or, as
-- of today, take down that client's entire forecast run.
--
-- Both fixes verified together against the scratch DB after applying this
-- migration: the same null-entity-code query above now returns 0 for every
-- dimension for Edgetec, and a full forecast_input_series() call for
-- dim_2/sales_person/branch no longer contains a null entity_code row.
-- ============================================================================


-- ============================================================================
-- 1. v_sales_documents — restore migration 024's three coalesces
-- ============================================================================
-- Identical to migration 039's rebuild, with the exact same three
-- coalesce(...) wrappers migration 024 originally added (and 039 dropped)
-- reapplied, plus the 24 dim_N_code/attr_N_code passthrough columns kept
-- exactly as 039 defined them (unaffected by this bug, not touched here).

create or replace view v_sales_documents
with (security_invoker = true) as
select
  f.client_id,
  f.document_kind,
  f.document,
  f.doc_date,
  fiscal_year(f.doc_date, coalesce(fys.start_month, 3)) as fiscal_year,
  f.account_code,
  cu.name as customer_name,
  f.invoice_rep_code,
  cu.assigned_rep_code as customer_assigned_rep_code,
  coalesce(resolved_rep_code(f.client_id, f.account_code, f.invoice_rep_code), 'UNASSIGNED') as resolved_rep_code,
  sr.name as resolved_rep_name,
  coalesce(f.warehouse_code, 'UNASSIGNED') as branch_code,
  coalesce(br.display_code, f.warehouse_code, 'UNASSIGNED') as branch_display_code,
  br.name as branch_name,
  f.item_code,
  it.name as item_name,
  coalesce(it.department_code, 'UNASSIGNED') as department_code,
  cat.name as category_name,
  f.quantity,
  f.value,
  f.cost,
  (f.value - f.cost) as profit,
  case when f.value = 0 then 0
       else round((f.value - f.cost) / f.value * 100, 2)
  end as profit_percent,
  f.dim_1_code, f.dim_2_code, f.dim_3_code, f.dim_4_code, f.dim_5_code, f.dim_6_code,
  f.dim_7_code, f.dim_8_code, f.dim_9_code, f.dim_10_code, f.dim_11_code, f.dim_12_code,
  cu.attr_1_code, cu.attr_2_code, cu.attr_3_code, cu.attr_4_code, cu.attr_5_code, cu.attr_6_code,
  cu.attr_7_code, cu.attr_8_code, cu.attr_9_code, cu.attr_10_code, cu.attr_11_code, cu.attr_12_code
from sales_document_facts f
left join fiscal_year_settings fys on fys.client_id = f.client_id
left join customers cu  on cu.client_id = f.client_id and cu.code = f.account_code
left join sales_reps sr on sr.client_id = f.client_id
                        and sr.rep_code = resolved_rep_code(f.client_id, f.account_code, f.invoice_rep_code)
left join branches br   on br.client_id = f.client_id and br.code = f.warehouse_code
left join items it      on it.client_id = f.client_id and it.code = f.item_code
left join categories cat on cat.client_id = f.client_id and cat.department_code = it.department_code;


-- ============================================================================
-- 2. v_dimension_monthly_sales — coalesce the 12 generic branches too
-- ============================================================================
-- Same view migration 039 created, unchanged except each dim_N branch's
-- entity_code expression is now wrapped in coalesce(..., 'UNASSIGNED') —
-- the sales_person/branch/category branches need no change here since they
-- inherit Section 1's fix automatically (they select v_sales_documents'
-- already-coalesced columns directly).

create or replace view v_dimension_monthly_sales
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
    dim_1_code, dim_2_code, dim_3_code, dim_4_code, dim_5_code, dim_6_code,
    dim_7_code, dim_8_code, dim_9_code, dim_10_code, dim_11_code, dim_12_code,
    attr_1_code, attr_2_code, attr_3_code, attr_4_code, attr_5_code, attr_6_code,
    attr_7_code, attr_8_code, attr_9_code, attr_10_code, attr_11_code, attr_12_code,
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
group by client_id, month, fiscal_year, fiscal_month

union all

select base.client_id, 'dim_1', coalesce(case cd.resolution_kind when 'fact_column' then base.dim_1_code when 'customer_attribute' then base.attr_1_code end, 'UNASSIGNED'),
       base.month, base.fiscal_year, base.fiscal_month,
       sum(base.quantity), sum(base.value), sum(base.profit)
from base join client_dimensions cd on cd.client_id = base.client_id and cd.dimension_key = 'dim_1'
group by base.client_id, cd.resolution_kind, base.dim_1_code, base.attr_1_code, base.month, base.fiscal_year, base.fiscal_month

union all

select base.client_id, 'dim_2', coalesce(case cd.resolution_kind when 'fact_column' then base.dim_2_code when 'customer_attribute' then base.attr_2_code end, 'UNASSIGNED'),
       base.month, base.fiscal_year, base.fiscal_month,
       sum(base.quantity), sum(base.value), sum(base.profit)
from base join client_dimensions cd on cd.client_id = base.client_id and cd.dimension_key = 'dim_2'
group by base.client_id, cd.resolution_kind, base.dim_2_code, base.attr_2_code, base.month, base.fiscal_year, base.fiscal_month

union all

select base.client_id, 'dim_3', coalesce(case cd.resolution_kind when 'fact_column' then base.dim_3_code when 'customer_attribute' then base.attr_3_code end, 'UNASSIGNED'),
       base.month, base.fiscal_year, base.fiscal_month,
       sum(base.quantity), sum(base.value), sum(base.profit)
from base join client_dimensions cd on cd.client_id = base.client_id and cd.dimension_key = 'dim_3'
group by base.client_id, cd.resolution_kind, base.dim_3_code, base.attr_3_code, base.month, base.fiscal_year, base.fiscal_month

union all

select base.client_id, 'dim_4', coalesce(case cd.resolution_kind when 'fact_column' then base.dim_4_code when 'customer_attribute' then base.attr_4_code end, 'UNASSIGNED'),
       base.month, base.fiscal_year, base.fiscal_month,
       sum(base.quantity), sum(base.value), sum(base.profit)
from base join client_dimensions cd on cd.client_id = base.client_id and cd.dimension_key = 'dim_4'
group by base.client_id, cd.resolution_kind, base.dim_4_code, base.attr_4_code, base.month, base.fiscal_year, base.fiscal_month

union all

select base.client_id, 'dim_5', coalesce(case cd.resolution_kind when 'fact_column' then base.dim_5_code when 'customer_attribute' then base.attr_5_code end, 'UNASSIGNED'),
       base.month, base.fiscal_year, base.fiscal_month,
       sum(base.quantity), sum(base.value), sum(base.profit)
from base join client_dimensions cd on cd.client_id = base.client_id and cd.dimension_key = 'dim_5'
group by base.client_id, cd.resolution_kind, base.dim_5_code, base.attr_5_code, base.month, base.fiscal_year, base.fiscal_month

union all

select base.client_id, 'dim_6', coalesce(case cd.resolution_kind when 'fact_column' then base.dim_6_code when 'customer_attribute' then base.attr_6_code end, 'UNASSIGNED'),
       base.month, base.fiscal_year, base.fiscal_month,
       sum(base.quantity), sum(base.value), sum(base.profit)
from base join client_dimensions cd on cd.client_id = base.client_id and cd.dimension_key = 'dim_6'
group by base.client_id, cd.resolution_kind, base.dim_6_code, base.attr_6_code, base.month, base.fiscal_year, base.fiscal_month

union all

select base.client_id, 'dim_7', coalesce(case cd.resolution_kind when 'fact_column' then base.dim_7_code when 'customer_attribute' then base.attr_7_code end, 'UNASSIGNED'),
       base.month, base.fiscal_year, base.fiscal_month,
       sum(base.quantity), sum(base.value), sum(base.profit)
from base join client_dimensions cd on cd.client_id = base.client_id and cd.dimension_key = 'dim_7'
group by base.client_id, cd.resolution_kind, base.dim_7_code, base.attr_7_code, base.month, base.fiscal_year, base.fiscal_month

union all

select base.client_id, 'dim_8', coalesce(case cd.resolution_kind when 'fact_column' then base.dim_8_code when 'customer_attribute' then base.attr_8_code end, 'UNASSIGNED'),
       base.month, base.fiscal_year, base.fiscal_month,
       sum(base.quantity), sum(base.value), sum(base.profit)
from base join client_dimensions cd on cd.client_id = base.client_id and cd.dimension_key = 'dim_8'
group by base.client_id, cd.resolution_kind, base.dim_8_code, base.attr_8_code, base.month, base.fiscal_year, base.fiscal_month

union all

select base.client_id, 'dim_9', coalesce(case cd.resolution_kind when 'fact_column' then base.dim_9_code when 'customer_attribute' then base.attr_9_code end, 'UNASSIGNED'),
       base.month, base.fiscal_year, base.fiscal_month,
       sum(base.quantity), sum(base.value), sum(base.profit)
from base join client_dimensions cd on cd.client_id = base.client_id and cd.dimension_key = 'dim_9'
group by base.client_id, cd.resolution_kind, base.dim_9_code, base.attr_9_code, base.month, base.fiscal_year, base.fiscal_month

union all

select base.client_id, 'dim_10', coalesce(case cd.resolution_kind when 'fact_column' then base.dim_10_code when 'customer_attribute' then base.attr_10_code end, 'UNASSIGNED'),
       base.month, base.fiscal_year, base.fiscal_month,
       sum(base.quantity), sum(base.value), sum(base.profit)
from base join client_dimensions cd on cd.client_id = base.client_id and cd.dimension_key = 'dim_10'
group by base.client_id, cd.resolution_kind, base.dim_10_code, base.attr_10_code, base.month, base.fiscal_year, base.fiscal_month

union all

select base.client_id, 'dim_11', coalesce(case cd.resolution_kind when 'fact_column' then base.dim_11_code when 'customer_attribute' then base.attr_11_code end, 'UNASSIGNED'),
       base.month, base.fiscal_year, base.fiscal_month,
       sum(base.quantity), sum(base.value), sum(base.profit)
from base join client_dimensions cd on cd.client_id = base.client_id and cd.dimension_key = 'dim_11'
group by base.client_id, cd.resolution_kind, base.dim_11_code, base.attr_11_code, base.month, base.fiscal_year, base.fiscal_month

union all

select base.client_id, 'dim_12', coalesce(case cd.resolution_kind when 'fact_column' then base.dim_12_code when 'customer_attribute' then base.attr_12_code end, 'UNASSIGNED'),
       base.month, base.fiscal_year, base.fiscal_month,
       sum(base.quantity), sum(base.value), sum(base.profit)
from base join client_dimensions cd on cd.client_id = base.client_id and cd.dimension_key = 'dim_12'
group by base.client_id, cd.resolution_kind, base.dim_12_code, base.attr_12_code, base.month, base.fiscal_year, base.fiscal_month;

-- Nothing downstream needs a separate change: v_dimension_performance,
-- fn_dimension_sales_history, forecast_input_series, and every generalized
-- RPC from migrations 042/050 all read entity_code from this view (or from
-- v_sales_documents) rather than re-deriving it, so this is the one place
-- that needed fixing for the null-entity-code class of bug to disappear
-- everywhere at once — same reasoning migration 024's own header gives.
