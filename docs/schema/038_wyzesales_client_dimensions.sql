-- ============================================================================
-- WyzeSales — per-client dimension configuration (multi-tenant dimension model)
-- ============================================================================
-- Thirty-eighth migration. First step of the multi-tenant dimension model
-- agreed with Craig — see docs/Wyzesales_MultiTenant_Dimension_Design.md for
-- the full design discussion. WCSA (IQ Retail), EdgeTec (Fincon), and
-- Morgenster (Pastel Partner) each define a different set of Sales Analysis
-- filter dimensions. This migration adds the ONE config table both the
-- Flutter app and each client's own WyzeSalesExtract build will read to know
-- what a given client's dimensions are called, how they resolve, and which
-- one scopes a RegUser's visibility — the design doc's "one config, two
-- consumers" principle (Section 1.1).
--
-- Nothing here changes any existing behaviour. This migration only adds new
-- tables and seeds WCSA's own EXISTING six dimensions (the current
-- `SalesDimension` enum in fiscal.dart: sales_person, category, customer,
-- item, branch, company) as configuration rows, matching exactly what WCSA
-- already does today — see Section 3 below. `document` is deliberately NOT a
-- dimension_key here: it's a raw document-number text filter
-- (global_filters.dart's own comment: "no separate display label... only
-- document_analysis_view.dart actually reads this"), not a Sales By/
-- Performance/Budgets dimension with an entity_code, so it was never a
-- SalesDimension value and doesn't belong in this table either.
--
-- EdgeTec's and Morgenster's own client_dimensions rows are NOT inserted
-- here — that's Section 6 step 5 of the design doc, once their extractors
-- are actually writing into the generic columns (migration 039). Inserting
-- config rows for a client with no data behind them yet would just make
-- half-finished dimensions appear in a filter bar with nothing to show.
-- ============================================================================


-- ============================================================================
-- 1. client_dimensions — the per-client configuration (Platform-Admin-managed)
-- ============================================================================
-- One row per dimension a client's Sales Analysis / Sales By / Performance /
-- Budgets / Dashboard ranking / Saved Filter Presets actually offers.
-- dimension_key is stable and internal: the six names every client can
-- reuse from the existing, already-built tables ('existing' resolution), or
-- one of twelve generic slots ('dim_1'..'dim_12') for a dimension that's
-- genuinely new to a given client (Market, Area, Revenue Split, etc. — see
-- the design doc's dimension catalogue, Section 2).
--
-- Twelve generic slots is a ceiling PER CLIENT, not a shared pool across all
-- clients — dimension_key's meaning is always scoped by client_id, so
-- EdgeTec's 'dim_1' and Morgenster's 'dim_1' can (and will) mean completely
-- different things. See the design doc's "why 12 is not a scarce shared
-- pool" note.

create table client_dimensions (
  client_id                 uuid not null references clients(id) on delete cascade,
  dimension_key             text not null check (
                               dimension_key in (
                                 'sales_person', 'customer', 'item', 'category', 'branch', 'company',
                                 'dim_1', 'dim_2', 'dim_3', 'dim_4', 'dim_5', 'dim_6',
                                 'dim_7', 'dim_8', 'dim_9', 'dim_10', 'dim_11', 'dim_12'
                               )
                             ),
  display_label             text not null,
  sort_order                int not null default 0,
  -- 'existing' = one of the six dimensions above, backed by the tables/
  -- columns that already exist (sales_reps/customers/items/categories/
  -- branches, or the 'company' pseudo-dimension). 'fact_column' = a value
  -- set per transaction line, in the new dim_N_code column on
  -- sales_document_facts (migration 039). 'customer_attribute' = a value
  -- that belongs to the Customer, in the new attr_N_code column on
  -- customers (migration 039).
  resolution_kind           text not null check (resolution_kind in ('existing', 'fact_column', 'customer_attribute')),
  -- Self-reference for a hierarchy level's parent (e.g. Morgenster's Region
  -- -> parent Area) — nullable, only meaningful for 'customer_attribute'
  -- dimensions that sit above another one. Not used by anything seeded in
  -- this migration; WCSA has no hierarchy dimension.
  parent_dimension_key      text,
  drives_budgets            boolean not null default true,
  drives_cross_filter       boolean not null default true,
  -- At most one true row per client (enforced below) — the single dimension
  -- a RegUser is pinned to (design doc principle 5): Branch for WCSA, Market
  -- for EdgeTec, Area for Morgenster.
  is_rls_scope              boolean not null default false,
  -- Feeds the Dashboard's single dynamic ranking-breakdown widget
  -- (dashboard_screen.dart's `_dimension`/`BoxedDropdown<SalesDimension>`,
  -- currently hardcoded to `SalesDimension.filterable`) — NOT a grid of
  -- static per-dimension tiles, despite the design doc's earlier "Top-5
  -- tiles" phrasing; there is one ranking widget whose dimension dropdown
  -- this flag will control the contents of once the app side is built.
  shows_on_dashboard_top5   boolean not null default false,
  created_at                timestamptz not null default now(),
  primary key (client_id, dimension_key),
  foreign key (client_id, parent_dimension_key) references client_dimensions (client_id, dimension_key)
);

-- resolution_kind = 'existing' must be one of the six real dimensions;
-- everything else must be a generic dim_N slot. Keeps the two concepts from
-- ever being mismatched (e.g. someone typo-ing 'existing' against 'dim_3').
alter table client_dimensions add constraint client_dimensions_kind_matches_key check (
  (resolution_kind = 'existing' and dimension_key in ('sales_person', 'customer', 'item', 'category', 'branch', 'company'))
  or (resolution_kind <> 'existing' and dimension_key like 'dim\_%' escape '\')
);

-- The RegUser boundary is singular by design — see design doc principle 5
-- ("one dimension a RegUser is pinned to"). A partial unique index (rather
-- than a plain unique constraint) since most rows have is_rls_scope = false
-- and shouldn't collide with each other.
create unique index client_dimensions_one_rls_scope
  on client_dimensions (client_id) where is_rls_scope;


-- ============================================================================
-- 2. client_dimension_values — one generic lookup table for every new dimension
-- ============================================================================
-- Rather than a bespoke `markets` table, an `areas` table, a `ranges` table
-- and so on, one shared table holds every new generic dimension's values,
-- scoped by client and dimension key — see design doc Section 3.2 for why
-- this simplification is safe (these are pure classification lookups with no
-- extra business columns, unlike Item's cost/price or Customer's
-- rep-attribution flag).
--
-- Not used by WCSA at all today (its dimensions are backed by the existing
-- branches/sales_reps/customers/items/categories tables, not this one) — it
-- exists now so EdgeTec's and Morgenster's config can be entered into it once
-- their extractors are ready, without a further schema change.

create table client_dimension_values (
  client_id       uuid not null references clients(id) on delete cascade,
  dimension_key   text not null,
  code            text not null,
  name            text,
  -- Nullable self-reference to another value's code, e.g. a Region row's
  -- parent_code = its Area's code (Morgenster's Area -> Region -> Country
  -- chain) — see design doc Section 2's "open, non-blocking detail" note on
  -- how strictly this gets enforced as a real hierarchy.
  parent_code     text,
  primary key (client_id, dimension_key, code),
  foreign key (client_id, dimension_key) references client_dimensions (client_id, dimension_key) on delete cascade,
  foreign key (client_id, dimension_key, parent_code) references client_dimension_values (client_id, dimension_key, code)
);


-- ============================================================================
-- 3. RLS + GRANTS
-- ============================================================================
-- Read: any signed-in member of the client (every level needs this to render
-- their own filter bar/dimension dropdowns) — or a platform admin, for any
-- client, to run the config screen. Write: platform admin only, everywhere —
-- design doc principle 2: this is NOT exposed in each client's own Settings,
-- because it has to stay in lockstep with what that client's bespoke
-- extractor actually populates. Same is_platform_admin()/is_adminuser()
-- helpers schema/008 already established — NOT 'superuser', which schema/008
-- retired in favour of the is_platform_admin flag.

alter table client_dimensions enable row level security;
alter table client_dimension_values enable row level security;

create policy client_dimensions_select on client_dimensions
for select using (
  is_platform_admin()
  or exists (select 1 from profiles p where p.id = auth.uid() and p.client_id = client_dimensions.client_id)
);

create policy client_dimensions_platform_admin_insert on client_dimensions
for insert with check (is_platform_admin());

create policy client_dimensions_platform_admin_update on client_dimensions
for update using (is_platform_admin()) with check (is_platform_admin());

create policy client_dimensions_platform_admin_delete on client_dimensions
for delete using (is_platform_admin());

create policy client_dimension_values_select on client_dimension_values
for select using (
  is_platform_admin()
  or exists (select 1 from profiles p where p.id = auth.uid() and p.client_id = client_dimension_values.client_id)
);

create policy client_dimension_values_platform_admin_insert on client_dimension_values
for insert with check (is_platform_admin());

create policy client_dimension_values_platform_admin_update on client_dimension_values
for update using (is_platform_admin()) with check (is_platform_admin());

create policy client_dimension_values_platform_admin_delete on client_dimension_values
for delete using (is_platform_admin());

grant select, insert, update, delete on client_dimensions to authenticated;
grant select, insert, update, delete on client_dimension_values to authenticated;


-- ============================================================================
-- 4. WCSA SEED — the six dimensions WCSA already has, exactly as they work today
-- ============================================================================
-- sort_order matches SalesDimension's current declared order (fiscal.dart)
-- exactly, so the generalized filter bar/dropdowns built later render in the
-- same order WCSA users already see. drives_cross_filter/
-- shows_on_dashboard_top5 = false for 'company' matches
-- `SalesDimension.filterable` excluding it today (a global filter target or
-- a ranking-breakdown entity doesn't make sense for a single whole-company
-- total — see fiscal.dart's own comment).

insert into client_dimensions (
  client_id, dimension_key, display_label, sort_order, resolution_kind,
  is_rls_scope, drives_budgets, drives_cross_filter, shows_on_dashboard_top5
)
select
  c.id, v.dimension_key, v.display_label, v.sort_order, 'existing',
  v.is_rls_scope, true, v.drives_cross_filter, v.shows_on_dashboard_top5
from clients c
cross join (values
  ('sales_person', 'Sales Person', 0, false, true,  true),
  ('category',     'Category',     1, false, true,  true),
  ('customer',     'Customer',     2, false, true,  true),
  ('item',         'Item',         3, false, true,  true),
  ('branch',       'Branch',       4, true,  true,  true),
  ('company',      'Company',      5, false, false, false)
) as v(dimension_key, display_label, sort_order, is_rls_scope, drives_cross_filter, shows_on_dashboard_top5)
where c.code = 'WCSA'
on conflict (client_id, dimension_key) do nothing;
