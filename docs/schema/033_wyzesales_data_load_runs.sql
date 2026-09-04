-- ============================================================================
-- WyzeSales — data_load_runs (extract run history / health tracking)
-- ============================================================================
-- Thirty-third migration. Item 2 of the post-forecast-deploy roadmap: Craig
-- chose "real run tracking from the start" over a staleness-only heuristic
-- (AskUserQuestion, 2026-09-04) — so a failed or hung WyzeSalesExtract run
-- shows up in the app as an actual failure, not just an old timestamp that
-- could mean anything from "it failed" to "nobody's opened the app since".
--
-- One row per WyzeSalesExtract run attempt. WyzeSalesExtract inserts a
-- 'running' row the moment it has a Supabase connection and a resolved
-- client_id — BEFORE it ever touches WCSA (ExtractRunner.cs was reordered,
-- 2026-09-04, to connect to Supabase first for exactly this reason: a WCSA
-- connection failure is the single most common real-world failure mode, and
-- under the old order there was no row to report it against at all) — then
-- updates that same row to 'success' or 'failure' once the run finishes
-- either way, including on the way out of the top-level catch block.
--
-- A row stuck on 'running' long after a run should have finished (per
-- WyzeSalesExtract's own Schedule.RunTimes) is itself a real signal — the
-- process crashed, was killed, or the machine lost power before it could
-- report anything, which a plain "last successful timestamp" can never
-- distinguish from "hasn't been told to run yet". The Flutter side treats an
-- old 'running' row as a failure for display purposes rather than inventing
-- a third on-screen state for it.
--
-- Row counts and duration are informational only — for a human glancing at
-- run history, not for any downstream calculation — so nullable, filled in
-- only when a run gets far enough to know them.
--
-- error_message holds WyzeSalesExtract's own sanitized exception text (see
-- ExtractRunner.cs's SanitizeErrorMessage, 2026-09-04) — connection strings
-- and DSNs are stripped before this ever leaves the process, so nothing
-- sensitive should land here even though it's readable by any signed-in
-- user of the client (same read-scope as every other table here).
--
-- Written by WyzeSalesExtract over its normal direct Postgres connection
-- (Session mode pooler, `postgres` role — see WyzeSalesExtract/README.md
-- "Setup" step 3), which is already a superuser connection that bypasses
-- RLS entirely, same as every other raw-fact table this program writes
-- (schema/006's own header). No WyzeSalesExtract-side GRANT is needed here
-- for that reason — only the app-side `authenticated` SELECT grant below.
-- ============================================================================

create table if not exists data_load_runs (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references clients(id) on delete cascade,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  status text not null default 'running' check (status in ('running', 'success', 'failure')),
  error_message text,
  sales_document_facts_rows integer,
  stock_movement_facts_rows integer,
  item_stock_snapshot_rows integer,
  duration_seconds numeric
);

create index if not exists data_load_runs_client_started_idx
  on data_load_runs (client_id, started_at desc);

alter table data_load_runs enable row level security;

-- Same shape as every other reference/fact table's read policy (schema/006):
-- "you have a profile for this client". Read-only from the app's side — this
-- table is written exclusively by WyzeSalesExtract's own elevated
-- connection, never through the authenticated/anon REST API.
create policy data_load_runs_select on data_load_runs
for select using (
  exists (select 1 from profiles p where p.id = auth.uid() and p.client_id = data_load_runs.client_id)
);

grant select on data_load_runs to authenticated;
