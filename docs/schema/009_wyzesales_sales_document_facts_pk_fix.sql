-- ============================================================================
-- WyzeSales — sales_document_facts: natural key -> generated id (Supabase / Postgres)
-- ============================================================================
-- Ninth migration. Corrective, for wyzesales-staging specifically — confirmed
-- by direct query against it (2026-08-25) that it's still running the
-- original primary key from schema/001 as first written:
--   sales_document_facts_pkey primary key (client_id, document_kind, document, item_code)
-- That natural key was wrong and was corrected in the schema/001 file itself
-- while WyzeSalesExtract was being built (see that file's current comment on
-- sales_document_facts) — but the fix never went out as its own migration,
-- so an environment that already ran the old 001 (wyzesales-staging) never
-- picked it up. This migration is that missing follow-up.
--
-- Why the natural key was wrong: a real document can legitimately carry the
-- same item on two separate lines (re-entered separately, bundled
-- differently, etc.), and IQRetail's own line tables don't expose a
-- line-number column WyzeSalesExtract captures. A primary key on
-- (client_id, document_kind, document, item_code) would silently collapse
-- two genuinely separate lines into one — either rejecting the second
-- line's insert outright, or (with an upsert) overwriting the first line's
-- values with the second's.
--
-- Safe to run regardless of whether the table currently holds any rows:
-- sales_document_facts is fully derived and safe to replace wholesale each
-- run (WyzeSalesExtract deletes and reinserts the whole rolling window every
-- run, same as sales_forecast) — there's no natural-key uniqueness being
-- protected here that's worth keeping, and no risk of the ADD COLUMN step
-- losing data: Postgres backfills a new GENERATED ALWAYS AS IDENTITY column
-- with sequential values for existing rows automatically.
--
-- Written defensively (IF EXISTS / IF NOT EXISTS / a existence check before
-- the final ADD PRIMARY KEY) so this is safe to run twice by accident, and
-- a no-op on any environment that already has the corrected schema — e.g.
-- Production, which doesn't exist yet as of this migration and should just
-- run the already-corrected schema/001 directly rather than 001-then-009.
-- ============================================================================

alter table sales_document_facts add column if not exists id bigint generated always as identity;

alter table sales_document_facts drop constraint if exists sales_document_facts_pkey;

do $$
begin
  if not exists (
    select 1 from information_schema.table_constraints
    where table_schema = 'public'
      and table_name = 'sales_document_facts'
      and constraint_type = 'PRIMARY KEY'
  ) then
    alter table sales_document_facts add primary key (id);
  end if;
end $$;

create index if not exists sales_document_facts_client_doc_idx
  on sales_document_facts (client_id, document_kind, document);

-- Verify after running (same query used to diagnose this on wyzesales-staging):
--
-- select tc.constraint_name, tc.constraint_type, kcu.column_name
-- from information_schema.table_constraints tc
-- left join information_schema.key_column_usage kcu
--   on tc.constraint_name = kcu.constraint_name
--  and tc.table_schema = kcu.table_schema
-- where tc.table_name = 'sales_document_facts'
--   and tc.table_schema = 'public'
--   and tc.constraint_type = 'PRIMARY KEY';
--
-- Expect exactly one row back: sales_document_facts_pkey / PRIMARY KEY / id.
