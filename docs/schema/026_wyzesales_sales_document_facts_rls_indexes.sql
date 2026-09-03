-- ============================================================================
-- WyzeSales — supporting indexes for schema/018's rep/branch RLS checks
-- ============================================================================
-- Twenty-sixth migration. Craig, 2026-09-03, logged on as a plain 'user'
-- (Johan Botha) for the first time since schema/018 shipped (2026-09-01):
-- the Dashboard threw `PostgrestException(message: canceling statement due
-- to statement timeout, code: 57014, ...)` on a reload.
--
-- ROOT CAUSE, confirmed with EXPLAIN ANALYZE against a scratch copy of this
-- whole schema chain plus the seed data: schema/018's 'user'/'reguser'
-- helper functions (fn_customer_visible_to_rep, fn_rep_sold_at_branch,
-- fn_customer_sold_at_branch) all filter sales_document_facts by
-- invoice_rep_code and/or warehouse_code — columns schema/001 never
-- indexed (it only ever indexed (client_id, account_code), (client_id,
-- doc_date), and (client_id, document_kind, document)). Worse,
-- sales_document_facts_select's OWN pre-existing 'user' branch (schema/001
-- Section 10) already runs a correlated subquery into `customers` for
-- EVERY row it evaluates ("the customer's assigned rep") — and since
-- schema/018, that per-row read of `customers` now ALSO evaluates
-- customers_select's own (newly non-trivial) RLS policy, which calls
-- fn_customer_visible_to_rep. So every 'user'/'reguser' read of
-- sales_document_facts — which is nearly every screen in this app, Dashboard
-- especially, which fires ~10 of these queries CONCURRENTLY on every load
-- (dashboard_screen.dart's _loadKpis, one big Future.wait) — went from "one
-- cheap profiles lookup per row" (adminuser: no subquery at all) to
-- "one lookup into customers, itself running a full unindexed scan of
-- sales_document_facts, for every single outer row" the moment the caller
-- is a 'user'/'reguser'. This was never load-tested under a non-admin login
-- until now, 2 days after schema/018 shipped.
--
-- This alone didn't reproduce a multi-second timeout against the small
-- seed dataset tested locally (a full sales_document_facts scan for a
-- 'user' profile ran in ~35-70ms even unindexed) — but it's a genuine O(n)
-- cost per query that scales with data volume, and Dashboard fires ~10 of
-- these at once on a real, shared, possibly cold Supabase instance under
-- real network latency, which is a far less forgiving environment than a
-- warm local Postgres running one query at a time. Whether or not this
-- alone fully explains the specific timeout Craig hit, it's a real,
-- measurable inefficiency worth fixing outright: confirmed via EXPLAIN
-- ANALYZE that fn_customer_visible_to_rep's own
-- `... and f.account_code = p_customer_code and f.invoice_rep_code =
-- p_rep_code` check flips from a Seq Scan to an Index Only Scan once the
-- third index below exists, and the same reasoning applies to
-- fn_rep_sold_at_branch/fn_customer_sold_at_branch's own
-- invoice_rep_code/warehouse_code filters and to sales_document_facts_
-- select's own reguser/user branches, which filter warehouse_code/
-- invoice_rep_code directly on the outer row too.
--
-- Purely additive — three new indexes, nothing else changes. Safe to run
-- any time; CREATE INDEX (not CONCURRENTLY) briefly locks the table, fine
-- for this table's size and for a non-production-hours run, same as every
-- other migration in this set.
-- ============================================================================

create index if not exists sales_document_facts_client_rep_idx
  on sales_document_facts (client_id, invoice_rep_code);

create index if not exists sales_document_facts_client_branch_idx
  on sales_document_facts (client_id, warehouse_code);

create index if not exists sales_document_facts_client_account_rep_idx
  on sales_document_facts (client_id, account_code, invoice_rep_code);
