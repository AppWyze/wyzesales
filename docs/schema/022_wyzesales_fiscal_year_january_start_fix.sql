-- ============================================================================
-- WyzeSales — fix fiscal_year() mislabelling every date under a January
-- fiscal-year start month
-- (Supabase / Postgres)
-- ============================================================================
-- Twenty-second migration. Found 2026-09-02 while writing task #92's Dart
-- regression tests (Wyzesales_Rebuild_Decisions.md Section 46/52-53) for
-- fiscal.dart's fiscalYearFor() — the client-side mirror of this very
-- function — and confirmed with Craig before fixing: "We need to fix this
-- please."
--
-- THE BUG: a fiscal year is meant to be labelled by the calendar year its
-- LAST month falls in — a Mar-start fiscal year running Mar 2025 -> Feb 2026
-- is "FY2026". For any start_month from 2-12 the original formula gets this
-- right: `+1` once a date reaches start_month, otherwise unchanged. But
-- start_month=1 is the one case where a fiscal year ends in the SAME
-- calendar year it starts in (Jan 2026 -> Dec 2026 ends in 2026, not 2027) —
-- and `extract(month from p_doc_date) >= p_start_month` is true for EVERY
-- month when p_start_month is 1 (every month is >= 1), so the original CASE
-- always took the +1 branch unconditionally, labelling every single date one
-- year ahead of where it actually belongs.
--
-- NOT YET LIVE FOR ANY CLIENT: fiscal_year_settings.start_month has only
-- ever been 3 (the hardcoded default every client started with, per
-- schema/019) until Settings > Company made it editable this same day — no
-- client on record has picked start_month=1 yet, so this has not actually
-- mislabelled anyone's real data. It would the first time a client did.
--
-- NO BACKFILL NEEDED: fiscal_year is never stored — v_sales_documents
-- (schema/001) computes it live from doc_date on every query via this
-- function, and every rollup/view built on top of v_sales_documents inherits
-- that same live computation. Replacing the function below takes effect
-- immediately for every future query, with nothing to migrate.
--
-- Companion fix: lib/core/constants/fiscal.dart's fiscalYearFor(), which
-- exists specifically to mirror this function client-side (used for default
-- filter values, never for anything written back to the database) — fixed
-- the same way, same day, committed alongside this file.
-- ============================================================================

create or replace function fiscal_year(p_doc_date date, p_start_month int default 3)
returns int language sql immutable as $$
  select case
    -- A January-start fiscal year runs Jan Y -> Dec Y and ends in the same
    -- year it starts — always just the date's own calendar year, with no
    -- "does this date reach start_month yet" branch to get wrong.
    when p_start_month = 1 then extract(year from p_doc_date)::int
    when extract(month from p_doc_date)::int >= p_start_month
      then extract(year from p_doc_date)::int + 1
    else extract(year from p_doc_date)::int
  end;
$$;
