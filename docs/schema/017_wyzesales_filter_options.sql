-- ============================================================================
-- WyzeSales — cross-dimension filter option narrowing (Supabase / Postgres)
-- ============================================================================
-- Seventeenth migration. Craig, 2026-09-01: "When a filter is applied, that
-- filter needs to apply to the other filters as well. e.g. If I filter on an
-- Item and then I look up Customer in the Customer Filter, I should only be
-- able to select a customer who has purchased that item... Customers who
-- have not purchased the item should be greyed out in the filter. This
-- applies to all filters but not the Top Bar search." Follow-up decisions
-- the same day: Year/Month participate in this too (not just the 5 entity
-- dimensions), and a greyed-out option stays selectable rather than being
-- hard-blocked — greying is a hint, not a restriction, since a user who
-- knows new data is coming (or wants to double-check a combination is
-- really empty) shouldn't be prevented from picking it anyway.
--
-- THE GAP THIS CLOSES: entity_search_field.dart's picker dialog (the only
-- remaining place any of the 5 dimension filters get set — see that file's
-- own doc comment) queries each dimension's plain reference table
-- (customers/items/categories/branches/sales_reps) directly, with zero
-- awareness of whatever OTHER global filters are already active. Today you
-- can genuinely filter to Item X, then pick a Customer who has never once
-- purchased Item X — the combination silently returns nothing on every
-- screen, with no warning at the point the second filter was picked.
--
-- THE FIX: one function that, given a target dimension plus whichever OTHER
-- filters are currently active (the 4 other dimensions + fiscal year/month),
-- returns just the set of entity codes for that dimension that actually have
-- at least one matching row — built on the exact same v_sales_cube_monthly
-- (schema/011) already used for cross-dimension rollups, so this reuses
-- infrastructure rather than inventing a new one. The Flutter picker calls
-- this once per open (see reference_data_repository.dart's
-- `filterOptionCodes`), and greys out any row whose code isn't in the
-- returned set — it doesn't remove those rows, so the list's shape/order
-- doesn't jump around as other filters change.
--
-- Deliberately NOT applied to TopBarSearch (searchAllDimensions) — Craig was
-- explicit that only the dimension filter pickers should behave this way;
-- the top bar's job is "jump straight to any entity in the system," which a
-- currently-active filter narrowing has no business interfering with.
--
-- Deliberately NOT applied to the Document filter (_pickDocument) either,
-- for a structural reason rather than a scope choice: a document number is a
-- single transaction, not an aggregate dimension entity, and doesn't have a
-- column on v_sales_cube_monthly to narrow against the same way. Craig
-- didn't ask for this and it's a much smaller/rarer picker (a free-text
-- search, not a browse list), so left out rather than force-fit.
-- ============================================================================

-- ============================================================================
-- 1. fn_dimension_filter_options — which entity_codes for p_dimension have
--    at least one matching row under every OTHER active filter
-- ============================================================================
-- p_dimension's own current filter value is deliberately not one of this
-- function's parameters at all (unlike the p_entity_code narrowing
-- fn_dimension_monthly_sales_filtered supports) — picking a NEW Customer
-- should never be constrained by whichever Customer is already active; the
-- Dart caller always passes null for that one dimension's own p_filter_*
-- slot, same convention fn_dimension_monthly_sales_filtered already uses by
-- keeping p_dimension and its own p_filter_customer/etc. as separate,
-- independently-nullable parameters.
--
-- `distinct` rather than a `group by`/aggregate — this only ever needs to
-- answer "does at least one row exist," not any measure, so there's nothing
-- to sum.
--
-- `language sql stable`, no `security definer` — same as every other
-- function in schema/011, so RLS on the underlying sales_document_facts
-- still applies per-caller through v_sales_documents -> v_sales_cube_monthly
-- exactly as it does today. No RLS/policy change needed on any existing
-- table.

create or replace function fn_dimension_filter_options(
  p_dimension text,
  p_fiscal_year int default null,
  p_fiscal_month text default null,
  p_filter_sales_person text default null,
  p_filter_customer text default null,
  p_filter_item text default null,
  p_filter_category text default null,
  p_filter_branch text default null
)
returns table (entity_code text)
language sql stable as $$
  select distinct
    case p_dimension
      when 'sales_person' then sales_person_code
      when 'customer'     then customer_code
      when 'item'         then item_code
      when 'category'     then category_code
      when 'branch'       then branch_code
    end as entity_code
  from v_sales_cube_monthly c
  where (p_fiscal_year  is null or c.fiscal_year  = p_fiscal_year)
    and (p_fiscal_month is null or c.fiscal_month = p_fiscal_month)
    and (p_filter_sales_person is null or c.sales_person_code = p_filter_sales_person)
    and (p_filter_customer     is null or c.customer_code     = p_filter_customer)
    and (p_filter_item         is null or c.item_code         = p_filter_item)
    and (p_filter_category     is null or c.category_code     = p_filter_category)
    and (p_filter_branch       is null or c.branch_code       = p_filter_branch)
$$;


-- ============================================================================
-- 2. GRANTS
-- ============================================================================
-- Same belt-and-braces convention as schema/007 and schema/011 — Postgres
-- grants EXECUTE to PUBLIC by default (which already covers `authenticated`),
-- granted explicitly anyway so this doesn't rely on an ambient default. No
-- new SELECT grant needed on v_sales_cube_monthly — schema/011 already
-- granted that to `authenticated`, and this function is the only new thing
-- touching it here.

grant execute on function fn_dimension_filter_options(
  text, int, text, text, text, text, text, text
) to authenticated;
