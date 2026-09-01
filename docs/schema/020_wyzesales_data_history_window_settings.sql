-- ============================================================================
-- WyzeSales — configurable data history window (3 or 5 fiscal years)
-- (Supabase / Postgres)
-- ============================================================================
-- Twentieth migration. Craig, 2026-09-01: "We are only looking at 36 months
-- (3 years of data). I think there should be an option in the Settings >
-- Company Screen for either 3 or 5 years of data that we can Add and Edit.
-- Once again, the relevant screens and filters will need to align with this
-- as well as the Server Side Extract program."
--
-- Lives on `fiscal_year_settings` (schema/001 Section 7) rather than a new
-- table — it's the same shape of fact (one client-level number, one row per
-- client, same "who can edit it" rule) as start_month, added by schema/019
-- right next to it in the same Settings > Company screen. Reusing the table
-- means schema/019's `fiscal_year_settings_adminuser_insert`/`_update`
-- policies already cover this column too — RLS policies are row-level, not
-- column-level, so nothing new is needed there; this migration is genuinely
-- just the column and its constraint.
--
-- CHECK constrained to exactly 3 or 5 (not a general 1-N range like
-- start_month's 1-12) — Craig's own ask was explicitly "either 3 or 5
-- years," not an arbitrary number, and the Flutter side's dropdown only
-- ever offers those two values.
-- ============================================================================

alter table fiscal_year_settings
  add column history_years int not null default 3;

alter table fiscal_year_settings
  add constraint fiscal_year_settings_history_years_choice check (history_years in (3, 5));
