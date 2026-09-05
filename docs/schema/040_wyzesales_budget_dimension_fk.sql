-- ============================================================================
-- WyzeSales — budget_figures/sales_forecast.dimension becomes a real FK
-- ============================================================================
-- Fortieth migration. schema/001 hardcoded `dimension text not null check
-- (dimension in ('sales_person','customer','item','category','branch',
-- 'company'))` on both tables — fine while there was exactly one client with
-- exactly one fixed dimension set, but it can never let EdgeTec or Morgenster
-- carry a budget/target against Market, Area, or any other new dimension
-- (design doc Section 3.3). Replaced with a foreign key into
-- client_dimensions(client_id, dimension_key) (migration 038) — any
-- dimension a client has actually configured, old or new, can carry a
-- budget/target the same way Branch already does for WCSA.
--
-- Safe to run immediately after migration 038: every value WCSA's existing
-- budget_figures/sales_forecast rows can hold today (the same six names the
-- old CHECK constraint allowed) is exactly what migration 038's WCSA seed
-- just inserted into client_dimensions — so the FK below cannot orphan a
-- single existing row. Must run AFTER 038, not before.
--
-- Constraint names below match Postgres's own auto-generated name for
-- schema/001's inline `check (...)` (`<table>_<column>_check`) — `if exists`
-- since a name this migration didn't itself choose is worth guarding
-- defensively, same convention as every drop-and-recreate policy change in
-- this schema so far.
-- ============================================================================

alter table budget_figures drop constraint if exists budget_figures_dimension_check;
alter table sales_forecast drop constraint if exists sales_forecast_dimension_check;

alter table budget_figures
  add constraint budget_figures_dimension_fkey
  foreign key (client_id, dimension) references client_dimensions (client_id, dimension_key);

alter table sales_forecast
  add constraint sales_forecast_dimension_fkey
  foreign key (client_id, dimension) references client_dimensions (client_id, dimension_key);

-- Supporting index — the FK's referencing side (budget_figures/sales_forecast
-- already have (client_id, dimension) as a PK prefix, so no new index is
-- needed there); client_dimensions' own (client_id, dimension_key) primary
-- key already covers the referenced side. Nothing further required.
