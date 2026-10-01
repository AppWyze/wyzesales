-- ============================================================================
-- WyzeSales — let a platform admin read EVERY client's data_load_runs
-- ============================================================================
-- Fifty-sixth migration. 2026-10-01, Craig: "Under Platform Admin - Clients
-- can you include the Load Chip information for each client. So that I can
-- go to one view and see exactly the load status for each client." Platform
-- Admin's Clients tab needs to read every client's latest data_load_runs
-- row at once to show the same "Updated {date}" / "Loading…" / "Load stuck
-- since {date}" / "Load failed {date}" chip app_shell.dart's
-- _LastDataUpdateChip already shows the signed-in user their OWN client's
-- status as, in a single cross-client view.
--
-- `data_load_runs_select` (schema/033) only ever allowed "your own client's
-- rows" — `client_id = (select p.client_id from profiles p where p.id =
-- auth.uid())`, no `is_platform_admin()` bypass. That's the exact same gap
-- `fiscal_year_settings_select` (schema/006) had before schema/048's
-- identical fix: a platform admin signed in under one client's own profile
-- row got zero rows back for every OTHER client, not "the wrong client's
-- load status" — just nothing. Fixed the same way, same shape:
-- `is_platform_admin() OR own client`.
--
-- Read-only — WyzeSalesExtract's own writes (SupabaseWriter.
-- StartLoadRunAsync/CompleteLoadRunAsync) go through the service-role
-- connection, which bypasses RLS entirely and is untouched by this.
-- ============================================================================

drop policy if exists data_load_runs_select on data_load_runs;

create policy data_load_runs_select on data_load_runs
for select using (
  is_platform_admin()
  or exists (select 1 from profiles p where p.id = auth.uid() and p.client_id = data_load_runs.client_id)
);
