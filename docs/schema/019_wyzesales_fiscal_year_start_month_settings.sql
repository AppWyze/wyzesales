-- ============================================================================
-- WyzeSales — make fiscal_year_settings.start_month actually editable
-- (Supabase / Postgres)
-- ============================================================================
-- Nineteenth migration. Craig, 2026-09-01: "We are assuming that a Client's
-- Financial Year runs from March to February but this will not always be the
-- case. We need to add a field to the Settings > Company Screen whereby we
-- can Add and Edit this. Then the presentation of the data in the relevant
-- screen / filters etc. will need to align with this field."
--
-- THE GOOD NEWS, confirmed before writing a line of this: the hard part
-- already existed. `fiscal_year_settings` (schema/001 Section 7) and the
-- `fiscal_year(doc_date, start_month)` function (schema/001 Section 8) were
-- built per-client-parameterized from the very first migration —
-- v_sales_documents already computes every row's fiscal_year via
-- `fiscal_year(f.doc_date, coalesce(fys.start_month, 3))`, joined against
-- this exact table. Nothing server-side needs to change for a row's fiscal
-- year to respect a non-March start month; it already does, today, for any
-- client with a row in this table.
--
-- THE ACTUAL GAP: nothing has ever WRITTEN to fiscal_year_settings outside
-- the schema/010 seed data. schema/006 gave it a SELECT policy only —
-- correct at the time (nothing needed to write it, since nothing above the
-- database read the value either), but it means there is currently no way
-- for Settings > Company's new field to save a change even once the Flutter
-- side calls for it. This migration is purely that: write access, following
-- the exact same pattern `clients_adminuser_update` (schema/008) already
-- established for "a client's own adminuser can edit one field of their own
-- client's settings, nobody else can touch it."
--
-- Two policies rather than one UPSERT-shaped policy, because `for insert`
-- and `for update` are genuinely different Postgres RLS commands with their
-- own `with check` clauses — INSERT is needed at all because a client
-- created before this feature has no fiscal_year_settings row yet (v_sales_
-- documents' own `coalesce(fys.start_month, 3)` already treats "no row" as
-- "assume March" server-side, so the very first save from a client that's
-- never touched this setting has to INSERT a new row, not UPDATE one that
-- doesn't exist).
--
-- A CHECK constraint on start_month (1-12) is added too — schema/001's
-- column had no constraint at all, harmless while nothing but a trusted seed
-- script ever wrote to it, but this is now a value a real UI form submits,
-- so it's worth the database refusing anything a dropdown of 12 named months
-- couldn't have produced.
-- ============================================================================


-- ============================================================================
-- 1. CHECK CONSTRAINT — start_month must be a real calendar month
-- ============================================================================

alter table fiscal_year_settings
  add constraint fiscal_year_settings_start_month_range check (start_month between 1 and 12);


-- ============================================================================
-- 2. RLS — a client's own adminuser can insert/update their own row
-- ============================================================================
-- Mirrors clients_adminuser_update (schema/008) exactly: is_adminuser() +
-- client_id = get_my_client_id(), both already-existing security definer
-- helpers (schema/008 Section 4) — no new helper functions needed here.

create policy fiscal_year_settings_adminuser_insert on fiscal_year_settings
for insert with check (is_adminuser() and client_id = get_my_client_id());

create policy fiscal_year_settings_adminuser_update on fiscal_year_settings
for update using (is_adminuser() and client_id = get_my_client_id())
with check (is_adminuser() and client_id = get_my_client_id());

grant insert, update on fiscal_year_settings to authenticated;
