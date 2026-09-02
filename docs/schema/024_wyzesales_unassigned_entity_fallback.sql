-- ============================================================================
-- WyzeSales — never let an unattributed line produce a NULL entity code
-- (Supabase / Postgres)
-- ============================================================================
-- Twenty-fourth migration. Craig, 2026-09-02, asking whether Revenue sums
-- reconcile across every dimension including the new `company` view
-- (schema/024's own sibling, task/Section 57): they should, since every
-- dimension is just a different GROUP BY over the exact same underlying
-- rows — EXCEPT that `sales_document_facts.invoice_rep_code` and
-- `.warehouse_code` are both nullable (schema/001 Section 3), and an item
-- can be missing from `items`/`categories` or have no `department_code` set,
-- so a line with none of those resolved would still count toward Company/
-- Customer/Item (account_code and item_code are NOT NULL, always present),
-- but produce a NULL `entity_code` on the Sales Person/Branch/Category
-- breakdowns specifically. Checked the Dart side while answering that
-- question: `DimensionMonthlySales.fromMap`/`DimensionPerformance.fromMap`
-- both do `map['entity_code'] as String` — a non-nullable cast that would
-- throw and fail the ENTIRE fetch for that dimension/screen the moment a
-- single row like this appears, not just silently miscount. Craig: "Yes
-- please" to hardening this rather than leaving it to chance.
--
-- THE FIX: `v_sales_documents` (schema/001 Section 9) is the single
-- resolution point every rollup in this app is ultimately built from —
-- `v_dimension_monthly_sales` (schema/002)'s own `base` CTE and
-- `v_sales_cube_monthly` (schema/011) both select straight from it. Fixing
-- the 4 exposed code/name columns here, once, at the source, means every
-- downstream view/function inherits the fix automatically — no separate
-- change needed to schema/002 or schema/011's already-shipped SQL.
--
-- Deliberately NOT touching `resolved_rep_code()` (the function) itself —
-- that function is also the single source of truth `sales_document_facts_
-- select`'s RLS policies call directly (schema/001 Section 8's own doc
-- comment: "used by both the reporting view... and the RLS policies"). A
-- NULL return there currently makes `resolved_rep_code(...) = <a specific
-- user's own rep_code>` evaluate to NULL (never true) for every 'user'-level
-- person — i.e. an unattributed line is invisible to every ordinary rep by
-- default, a safe outcome. Coalescing the FUNCTION's return to a literal
-- 'UNASSIGNED' would still be safe in practice (no real rep_code will ever
-- equal that string) but needlessly widens a security-relevant function's
-- behaviour for a display-only concern — safer and just as effective to
-- coalesce only the OUTPUT column exposed by the reporting view below,
-- leaving every RLS policy and the function itself completely untouched.
-- The join predicates that produce `resolved_rep_name`/`branch_name`/
-- `category_name` (sr.rep_code = resolved_rep_code(...), br.code =
-- f.warehouse_code, items/categories) are likewise left exactly as they
-- were — still joined on the RAW (possibly null) value, so an unassigned
-- line correctly gets no name either, not a spurious match.
--
-- Sentinel chosen: the literal string 'UNASSIGNED' — matches the fallback
-- `DimensionMonthlySales.fromMap`/`DimensionPerformance.fromMap` also gained
-- in this same change (defense in depth: even if a future code path somehow
-- reintroduces a NULL entity_code, the Dart layer no longer crashes on it
-- either). `reference_data_repository.dart`'s `namesFor` additionally maps
-- this code to the friendlier display label "Unassigned" for the 3
-- dimensions it can actually occur on (Sales Person, Branch, Category) —
-- Customer and Item can never produce it, since `account_code`/`item_code`
-- are NOT NULL on `sales_document_facts` itself.
--
-- customer_name/item_name/category_name and branch_display_code are left as
-- plain nullable display fields (unchanged) — those already read "—" or
-- blank sensibly wherever they're shown; only the GROUPING/filtering code
-- columns needed hardening, since those are the ones every rollup view
-- groups and joins budget/forecast targets by.

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
  end as profit_percent
from sales_document_facts f
left join fiscal_year_settings fys on fys.client_id = f.client_id
left join customers cu  on cu.client_id = f.client_id and cu.code = f.account_code
left join sales_reps sr on sr.client_id = f.client_id
                        and sr.rep_code = resolved_rep_code(f.client_id, f.account_code, f.invoice_rep_code)
left join branches br   on br.client_id = f.client_id and br.code = f.warehouse_code
left join items it      on it.client_id = f.client_id and it.code = f.item_code
left join categories cat on cat.client_id = f.client_id and cat.department_code = it.department_code;

-- Every downstream object (v_consolidated_sales, v_dimension_monthly_sales,
-- v_dimension_performance, v_sales_cube_monthly and the functions built on
-- it, RLS policies referencing v_sales_documents if any) is a plain SELECT
-- against this view with no column list of its own baked in beyond what
-- CREATE OR REPLACE VIEW already preserves (same column names/order/types —
-- only the 3 expressions above changed, wrapped in coalesce(), not retyped),
-- so nothing else needs to be re-created or re-granted.
