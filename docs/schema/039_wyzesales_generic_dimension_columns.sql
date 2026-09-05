-- ============================================================================
-- WyzeSales — generic dimension columns (multi-tenant dimension model)
-- ============================================================================
-- Thirty-ninth migration. Adds the twelve generic slots client_dimensions
-- (migration 038) can point a new dimension at, on both places a value can
-- live per the design doc's two resolution kinds (Section 2): a fact-row
-- attribute (sales_document_facts.dim_N_code — e.g. EdgeTec's Group, Category
-- Type, Revenue Split; Morgenster's Range, Group, Type) or a customer
-- attribute (customers.attr_N_code — e.g. EdgeTec's Market; Morgenster's
-- Area, Region, Country, Customer Category).
--
-- Also adds profiles.rls_scope_code — a RegUser's own scope value for
-- whichever dimension a client flags is_rls_scope, WHEN that dimension is one
-- of the new generic ones (not 'branch'). WCSA keeps using profiles.
-- branch_code exactly as it does today (see migration 041's RLS
-- generalization) — this new column stays null and unused for WCSA. It's
-- deliberately a single generic text column rather than one column per
-- possible dim_N, since exactly one dimension is ever is_rls_scope for a
-- given client at a time (migration 038's partial unique index enforces
-- that), so there's only ever one value to hold. No FK here: unlike
-- branch_code's real FK to branches(client_id, code), a generic value's valid
-- set lives in client_dimension_values and depends on the dynamic
-- is_rls_scope dimension_key at any point in time, which isn't something a
-- static foreign key can express — validating a reguser's assigned value
-- against the currently-configured scope dimension is an app-layer /
-- Platform Admin screen concern (built alongside the rest of the app-side
-- work, design doc Section 4).
--
-- All new columns are nullable and additive — WCSA's own rows never populate
-- any of them, so this migration changes nothing about how WCSA behaves or
-- what it displays. This is what makes "prove the generalization against
-- WCSA first, zero behaviour change" (design doc Section 6, step 2) possible.
--
-- v_sales_documents and v_dimension_monthly_sales are rebuilt at the end of
-- this migration to carry the new columns through — see Section 3/4 below for
-- why both need it, not just the base tables.
-- ============================================================================


-- ============================================================================
-- 1. sales_document_facts — twelve generic fact-row columns
-- ============================================================================

alter table sales_document_facts
  add column dim_1_code  text, add column dim_2_code  text, add column dim_3_code  text,
  add column dim_4_code  text, add column dim_5_code  text, add column dim_6_code  text,
  add column dim_7_code  text, add column dim_8_code  text, add column dim_9_code  text,
  add column dim_10_code text, add column dim_11_code text, add column dim_12_code text;


-- ============================================================================
-- 2. customers — twelve generic customer-attribute columns; profiles — RLS scope
-- ============================================================================

alter table customers
  add column attr_1_code  text, add column attr_2_code  text, add column attr_3_code  text,
  add column attr_4_code  text, add column attr_5_code  text, add column attr_6_code  text,
  add column attr_7_code  text, add column attr_8_code  text, add column attr_9_code  text,
  add column attr_10_code text, add column attr_11_code text, add column attr_12_code text;

alter table profiles add column rls_scope_code text;


-- ============================================================================
-- 3. v_sales_documents — carry the new columns through
-- ============================================================================
-- Identical to schema/001 Section 9's view, with the twelve dim_N_code
-- columns (straight off the fact row) and twelve attr_N_code columns (off
-- the customer join already present in this view) appended at the end.
-- Appending rather than interleaving keeps every existing column in its
-- original position — `create or replace view` only allows that, not
-- reordering or removing columns.

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
  resolved_rep_code(f.client_id, f.account_code, f.invoice_rep_code) as resolved_rep_code,
  sr.name as resolved_rep_name,
  f.warehouse_code as branch_code,
  coalesce(br.display_code, f.warehouse_code) as branch_display_code,
  br.name as branch_name,
  f.item_code,
  it.name as item_name,
  it.department_code,
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
-- 4. v_dimension_monthly_sales — twelve new generic UNION ALL branches
-- ============================================================================
-- Same shape as schema/002 Section 2's six hardcoded branches, plus one more
-- per generic slot. Each new branch INNER JOINs client_dimensions on that
-- exact dimension_key — a client with no 'dim_N' row configured contributes
-- no rows to that branch at all, rather than a spurious null-entity row — and
-- picks whichever of dim_N_code/attr_N_code actually applies for that
-- client's own resolution_kind, since the same 'dim_5' label can mean a
-- fact-row column for one client and a customer-attribute column for
-- another (design doc Section 2 slot-count note).
--
-- Written now, against zero real EdgeTec/Morgenster data, so that entering
-- their client_dimensions config rows later (design doc Section 6, step 5)
-- makes their rollups appear immediately — no further change to this view
-- needed at that point.

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

select base.client_id, 'dim_1', case cd.resolution_kind when 'fact_column' then base.dim_1_code when 'customer_attribute' then base.attr_1_code end,
       base.month, base.fiscal_year, base.fiscal_month,
       sum(base.quantity), sum(base.value), sum(base.profit)
from base join client_dimensions cd on cd.client_id = base.client_id and cd.dimension_key = 'dim_1'
group by base.client_id, cd.resolution_kind, base.dim_1_code, base.attr_1_code, base.month, base.fiscal_year, base.fiscal_month

union all

select base.client_id, 'dim_2', case cd.resolution_kind when 'fact_column' then base.dim_2_code when 'customer_attribute' then base.attr_2_code end,
       base.month, base.fiscal_year, base.fiscal_month,
       sum(base.quantity), sum(base.value), sum(base.profit)
from base join client_dimensions cd on cd.client_id = base.client_id and cd.dimension_key = 'dim_2'
group by base.client_id, cd.resolution_kind, base.dim_2_code, base.attr_2_code, base.month, base.fiscal_year, base.fiscal_month

union all

select base.client_id, 'dim_3', case cd.resolution_kind when 'fact_column' then base.dim_3_code when 'customer_attribute' then base.attr_3_code end,
       base.month, base.fiscal_year, base.fiscal_month,
       sum(base.quantity), sum(base.value), sum(base.profit)
from base join client_dimensions cd on cd.client_id = base.client_id and cd.dimension_key = 'dim_3'
group by base.client_id, cd.resolution_kind, base.dim_3_code, base.attr_3_code, base.month, base.fiscal_year, base.fiscal_month

union all

select base.client_id, 'dim_4', case cd.resolution_kind when 'fact_column' then base.dim_4_code when 'customer_attribute' then base.attr_4_code end,
       base.month, base.fiscal_year, base.fiscal_month,
       sum(base.quantity), sum(base.value), sum(base.profit)
from base join client_dimensions cd on cd.client_id = base.client_id and cd.dimension_key = 'dim_4'
group by base.client_id, cd.resolution_kind, base.dim_4_code, base.attr_4_code, base.month, base.fiscal_year, base.fiscal_month

union all

select base.client_id, 'dim_5', case cd.resolution_kind when 'fact_column' then base.dim_5_code when 'customer_attribute' then base.attr_5_code end,
       base.month, base.fiscal_year, base.fiscal_month,
       sum(base.quantity), sum(base.value), sum(base.profit)
from base join client_dimensions cd on cd.client_id = base.client_id and cd.dimension_key = 'dim_5'
group by base.client_id, cd.resolution_kind, base.dim_5_code, base.attr_5_code, base.month, base.fiscal_year, base.fiscal_month

union all

select base.client_id, 'dim_6', case cd.resolution_kind when 'fact_column' then base.dim_6_code when 'customer_attribute' then base.attr_6_code end,
       base.month, base.fiscal_year, base.fiscal_month,
       sum(base.quantity), sum(base.value), sum(base.profit)
from base join client_dimensions cd on cd.client_id = base.client_id and cd.dimension_key = 'dim_6'
group by base.client_id, cd.resolution_kind, base.dim_6_code, base.attr_6_code, base.month, base.fiscal_year, base.fiscal_month

union all

select base.client_id, 'dim_7', case cd.resolution_kind when 'fact_column' then base.dim_7_code when 'customer_attribute' then base.attr_7_code end,
       base.month, base.fiscal_year, base.fiscal_month,
       sum(base.quantity), sum(base.value), sum(base.profit)
from base join client_dimensions cd on cd.client_id = base.client_id and cd.dimension_key = 'dim_7'
group by base.client_id, cd.resolution_kind, base.dim_7_code, base.attr_7_code, base.month, base.fiscal_year, base.fiscal_month

union all

select base.client_id, 'dim_8', case cd.resolution_kind when 'fact_column' then base.dim_8_code when 'customer_attribute' then base.attr_8_code end,
       base.month, base.fiscal_year, base.fiscal_month,
       sum(base.quantity), sum(base.value), sum(base.profit)
from base join client_dimensions cd on cd.client_id = base.client_id and cd.dimension_key = 'dim_8'
group by base.client_id, cd.resolution_kind, base.dim_8_code, base.attr_8_code, base.month, base.fiscal_year, base.fiscal_month

union all

select base.client_id, 'dim_9', case cd.resolution_kind when 'fact_column' then base.dim_9_code when 'customer_attribute' then base.attr_9_code end,
       base.month, base.fiscal_year, base.fiscal_month,
       sum(base.quantity), sum(base.value), sum(base.profit)
from base join client_dimensions cd on cd.client_id = base.client_id and cd.dimension_key = 'dim_9'
group by base.client_id, cd.resolution_kind, base.dim_9_code, base.attr_9_code, base.month, base.fiscal_year, base.fiscal_month

union all

select base.client_id, 'dim_10', case cd.resolution_kind when 'fact_column' then base.dim_10_code when 'customer_attribute' then base.attr_10_code end,
       base.month, base.fiscal_year, base.fiscal_month,
       sum(base.quantity), sum(base.value), sum(base.profit)
from base join client_dimensions cd on cd.client_id = base.client_id and cd.dimension_key = 'dim_10'
group by base.client_id, cd.resolution_kind, base.dim_10_code, base.attr_10_code, base.month, base.fiscal_year, base.fiscal_month

union all

select base.client_id, 'dim_11', case cd.resolution_kind when 'fact_column' then base.dim_11_code when 'customer_attribute' then base.attr_11_code end,
       base.month, base.fiscal_year, base.fiscal_month,
       sum(base.quantity), sum(base.value), sum(base.profit)
from base join client_dimensions cd on cd.client_id = base.client_id and cd.dimension_key = 'dim_11'
group by base.client_id, cd.resolution_kind, base.dim_11_code, base.attr_11_code, base.month, base.fiscal_year, base.fiscal_month

union all

select base.client_id, 'dim_12', case cd.resolution_kind when 'fact_column' then base.dim_12_code when 'customer_attribute' then base.attr_12_code end,
       base.month, base.fiscal_year, base.fiscal_month,
       sum(base.quantity), sum(base.value), sum(base.profit)
from base join client_dimensions cd on cd.client_id = base.client_id and cd.dimension_key = 'dim_12'
group by base.client_id, cd.resolution_kind, base.dim_12_code, base.attr_12_code, base.month, base.fiscal_year, base.fiscal_month;

-- v_dimension_performance (schema/002 Section 3) needs NO change at all — it
-- already joins budget_figures/sales_forecast against
-- v_dimension_monthly_sales purely on (client_id, dimension, entity_code,
-- fiscal_month), with no hardcoded dimension list anywhere in its own
-- definition. It picks up every new dim_N branch above automatically.
