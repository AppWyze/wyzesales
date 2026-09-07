-- ============================================================================
-- WyzeSales — let a platform admin read ANY client's fiscal_year_settings
-- ============================================================================
-- Forty-eighth migration. 2026-09-07, Craig: "align a client's license with
-- their fiscal year. License starts on the 1st day of their fiscal year and
-- expires on the last day of their fiscal year." Platform Admin's Licenses
-- tab needs to read the TARGET client's actual fiscal_year_settings.
-- start_month (whatever that client has configured on their own Settings >
-- Company screen — defaulting to March if they've never touched it) in
-- order to compute and offer a fiscal-year-aligned license period for an
-- ARBITRARY other client, not the signed-in platform admin's own.
--
-- `fiscal_year_settings_select` (schema/006) only ever allowed "your own
-- client's row" — `exists (select 1 from profiles p where p.id = auth.uid()
-- and p.client_id = fiscal_year_settings.client_id)`, no `is_platform_
-- admin()` bypass. That's the SAME shape `client_dimensions_select`
-- (schema/038) had before 2026-09-07's cross-tenant fix
-- (reference_data_repository.dart's `clientDimensions()` doc comment) —
-- except here the effect is the OPPOSITE of that bug: rather than LEAKING
-- every client's rows together for a platform-admin caller, it BLOCKS a
-- platform admin from reading ANY other client's row at all, since there
-- was no bypass to fall back on. A platform admin managing, say, Edgetec's
-- license while signed in as a login tied to a different client's own
-- profile row would get zero rows back from this table for Edgetec — not
-- "the wrong client's settings," just nothing.
--
-- Fixed the same way `client_dimensions_select` already is: `is_platform_
-- admin() OR own client`, so PlatformAdminRepository's explicit,
-- caller-chosen `clientId` (see that class's own doc comment on the
-- pattern every one of its other methods already follows) actually returns
-- a row instead of nothing.
--
-- Read-only. This does NOT let a platform admin CHANGE another client's
-- fiscal year start month — `fiscal_year_settings_adminuser_insert`/
-- `_update` (schema/019) are untouched, still scoped to that client's own
-- adminuser only. Only the SELECT policy changes here.
-- ============================================================================

drop policy if exists fiscal_year_settings_select on fiscal_year_settings;

create policy fiscal_year_settings_select on fiscal_year_settings
for select using (
  is_platform_admin()
  or exists (select 1 from profiles p where p.id = auth.uid() and p.client_id = fiscal_year_settings.client_id)
);
