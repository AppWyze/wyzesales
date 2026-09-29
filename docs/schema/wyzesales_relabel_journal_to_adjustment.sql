-- wyzesales_relabel_journal_to_adjustment.sql
--
-- Run this yourself against PRODUCTION (project vnzflygyqslvlvndyhql) in
-- the Supabase SQL editor. Nothing here is applied automatically.
--
-- Craig, 2026-09-29: "Wyzesales now needs to cater for Invoice, Credit and
-- Adjustment. That's it... Journals etc. are all just adjustments." This
-- relabels every existing 'journal' row to 'adjustment' so the data itself
-- matches that 3-kind model, not just the app's aggregation logic.
--
-- STEP 0 — what's actually there right now (run this first, read it):
--   Only Edgetec Systems has 'journal' rows: 1,911 rows, R467,908.65.
--   Morgenster has 433 'adjustment' rows (R443,435.93) already correctly
--   labelled — nothing to do there. Fynbos Hill Vineyards has neither.
--   No client has any 'quote' or 'sales_order' rows anywhere in
--   sales_document_facts — nothing to relabel or clean up for those; they
--   were never actually used as far as the data shows, consistent with
--   Quote Analysis/Sales Order Analysis being removed from the app on
--   2026-09-02, before most of today's clients' data was ever loaded.

select
  c.name as client_name,
  f.document_kind,
  count(*) as row_count,
  sum(f.value) as total_value
from sales_document_facts f
join clients c on c.id = f.client_id
group by c.name, f.document_kind
order by c.name, f.document_kind;

-- STEP 1 — the actual relabel. Safe and reversible (it's a label change,
-- not a value change — nothing about quantity/value/cost/profit moves).
-- Wrapped in a transaction so you can inspect the affected row count
-- before committing; adjust client_id below if new clients pick up journal
-- rows before you get to run this.

begin;

update sales_document_facts
set document_kind = 'adjustment'
where document_kind = 'journal';

-- Sanity check before committing — should show 0 rows.
select count(*) from sales_document_facts where document_kind = 'journal';

-- If that shows 0, this is safe to commit:
commit;

-- If you want to double check first instead, replace the `commit;` above
-- with `rollback;`, review the row count it reports, then re-run just the
-- `update` + `commit` once you're happy.

-- STEP 2 — once this has been run (production has zero 'journal' rows
-- left), tell Claude / re-run this check yourself, and the very last step
-- is a one-line change: `fn_revenue_document_kinds()` and
-- `kRevenueDocumentKinds` (lib/core/constants/document_kinds.dart) both
-- drop 'journal' from their list. No view or matview rebuild needed for
-- that — see docs/schema/wyzesales_fn_revenue_document_kinds.sql for why.

-- Repeat the same on STAGING (project uxyqthscnlznrjpyogwg) once
-- production looks right — staging's data is unrelated test data (not a
-- copy of Morgenster/Edgetec/Fynbos), but worth keeping the same rule
-- applied everywhere for consistency.
