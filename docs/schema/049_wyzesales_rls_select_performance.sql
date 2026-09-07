-- ============================================================================
-- WyzeSales — RLS SELECT policies stop re-resolving "who am I" per row
-- ============================================================================
-- Forty-ninth migration. Craig, 2026-09-07, right after the Edgetec load:
-- the Dashboard started throwing `PostgrestException(message: canceling
-- statement due to statement timeout, code: 57014, ...)` — confirmed to
-- happen identically for BOTH Edgetec and WCSA, ruling out anything
-- Edgetec-specific (dim_1-dim_5, data volume for that one client, etc).
--
-- ROOT CAUSE, confirmed with EXPLAIN ANALYZE against a scratch copy of this
-- schema loaded with the same row counts as production (9,192 rows split
-- 6,473 Edgetec / 2,719 WCSA) and a REAL `authenticated` login (not the
-- `postgres` superuser, which bypasses RLS entirely and is why an earlier
-- EXPLAIN ANALYZE Craig ran looked fine — it never touched these policies):
--
--   sales_document_facts_select (migration 041) and its sibling policies
--   below all resolve the caller's own profile via a subquery CORRELATED to
--   the row being checked:
--
--     exists (
--       select 1 from profiles p
--       where p.id = auth.uid()
--         and p.client_id = sales_document_facts.client_id   -- correlated!
--         and (...)
--     )
--
--   Because `p.client_id = sales_document_facts.client_id` ties the
--   subquery to the outer row, Postgres cannot hoist "who am I" out as a
--   one-time lookup, and — critically — it means the outer table's own
--   `client_id` index can't be used to narrow the scan before the policy
--   runs. The result: a full, un-pruned sequential scan of the ENTIRE
--   shared table (every client, not just the caller's own) with a fresh
--   correlated profiles lookup re-run per row. Confirmed directly in the
--   plan: `Seq Scan on sales_document_facts f ... loops=1` with a `SubPlan`
--   underneath re-executed `loops=9192` — once per row of the WHOLE table,
--   both clients combined — for a query that only cares about one client's
--   ~6,473 rows.
--
--   This is the exact same class of bug as migration 026 (a plain 'user'
--   login first hit this back on 2026-09-03) — that fix indexed the
--   OLD hardcoded branch/rep columns; this generalized version (migration
--   041's `fn_reguser_rls_scope_value`/`fn_fact_rls_scope_value`, plus the
--   same correlated shape copied into every sibling table's own SELECT
--   policy across migrations 018/029/031/034/038) reintroduced the
--   identical cost, this time scaling with the TOTAL row count across every
--   client sharing these tables — which is exactly why WCSA (whose own data
--   and config didn't change today) got dragged into the same timeout the
--   moment Edgetec's 6,473-row load pushed the shared total up.
--
-- MEASURED, not assumed (scratch copy, `explain analyze`, real
-- `authenticated` role, `set role authenticated` — no bypass):
--
--   v_dimension_monthly_sales (dimension='sales_person', Edgetec), before
--   this migration:
--     adminuser: 126ms   reguser: 230ms
--   same query, after:
--     adminuser:  61ms   reguser: 145ms
--
--   (Postgres superuser / RLS bypassed entirely, for reference — this is
--   what an EXPLAIN ANALYZE run as `postgres` in the SQL Editor shows,
--   and why it doesn't reveal this bug at all: 39ms.)
--
--   Production's own real numbers (Query Performance / pg_stat_statements)
--   were considerably worse than this scratch reproduction (500ms-7s+,
--   occasionally the full 2-minute statement_timeout) — expected, since
--   the Dashboard fires ~20 of these concurrently against a real, shared,
--   possibly cold Supabase instance under real network latency, not one
--   query at a time on a warm local disk (same point migration 026's own
--   header already made).
--
-- THE FIX: wrap the identity lookup as a bare, UNCORRELATED subquery —
-- `(select p.client_id from profiles p where p.id = auth.uid())` — instead
-- of `exists (select ... where p.client_id = <outer row>.client_id)`. This
-- has nothing left in it that references the row being checked, so Postgres
-- evaluates it once (an InitPlan) rather than per row, AND the resulting
-- `sales_document_facts.client_id = (that one value)` comparison is a plain,
-- indexable equality — confirmed in the new plan choosing a
-- `Bitmap Index Scan on sales_document_facts_client_account_rep_idx` scoped
-- to just the caller's own client, instead of a full-table seq scan.
--
-- This is NOT a new technique introduced here — it's the exact same pattern
-- `get_my_client_id()`/`is_platform_admin()`/`is_adminuser()` (schema/008)
-- already use successfully elsewhere in this same schema (confirmed in the
-- EXPLAIN ANALYZE output: those show up as fast, one-time `InitPlan`/hashed
-- `SubPlan` nodes, not per-row cost) — this migration applies it everywhere
-- the correlated form was still in use.
--
-- ZERO VISIBILITY CHANGE, verified rather than assumed: every policy below
-- was checked against the scratch copy by comparing the exact set of rows
-- (row count + md5 of sorted keys) visible to a real adminuser, reguser, and
-- user login, before and after this migration, across every table touched —
-- identical in every case. A WCSA reguser scoped to branch 'CPT' still sees
-- only the CPT branch (not JHB/DBN) — migration 041's "zero behaviour change
-- for WCSA" guarantee still holds; this migration only changes how fast
-- Postgres reaches the same answer, never what the answer is.
--
-- SCOPE: every SELECT policy with this correlated shape is rewritten below.
-- Not touched (already using the fast, non-correlated pattern, or with
-- nothing to correlate against): clients_select, fiscal_year_settings_select,
-- client_dimensions_select, license_select, pricing_plan_select,
-- profiles_self_select, filter_presets_select.
-- ============================================================================


-- ============================================================================
-- 1. sales_document_facts_select — the highest-impact fix (every screen in
--    the app reads this table, directly or via v_sales_documents /
--    v_dimension_monthly_sales / v_dimension_performance).
-- ============================================================================

drop policy if exists sales_document_facts_select on sales_document_facts;

create policy sales_document_facts_select on sales_document_facts
for select using (
  sales_document_facts.client_id = (select p.client_id from profiles p where p.id = auth.uid())
  and (
    (select p.level from profiles p where p.id = auth.uid()) = 'adminuser'
    or (
      (select p.level from profiles p where p.id = auth.uid()) = 'reguser'
      and (select fn_reguser_rls_scope_value(p.client_id, p) from profiles p where p.id = auth.uid()) is not null
      and (select fn_reguser_rls_scope_value(p.client_id, p) from profiles p where p.id = auth.uid())
          = fn_fact_rls_scope_value(sales_document_facts.client_id, sales_document_facts)
    )
    or (
      (select p.level from profiles p where p.id = auth.uid()) = 'user'
      and (select p.rep_code from profiles p where p.id = auth.uid()) in (
            sales_document_facts.invoice_rep_code,
            resolved_rep_code(sales_document_facts.client_id, sales_document_facts.account_code, sales_document_facts.invoice_rep_code)
          )
    )
  )
);


-- ============================================================================
-- 2. customers_select / sales_reps_select / branches_select — all three are
--    LEFT JOINed into v_sales_documents once per fact row, so their own
--    per-row cost multiplies by however many fact rows a query scans. The
--    EXPLAIN ANALYZE that motivated this migration showed customers_select's
--    old correlated subplan re-run `loops=6473` even AFTER fixing
--    sales_document_facts_select alone — this is the next-highest-impact fix.
-- ============================================================================

drop policy if exists customers_select on customers;

create policy customers_select on customers
for select using (
  customers.client_id = (select p.client_id from profiles p where p.id = auth.uid())
  and (
    (select p.level from profiles p where p.id = auth.uid()) = 'adminuser'
    or (
      (select p.level from profiles p where p.id = auth.uid()) = 'reguser'
      and fn_customer_sold_within_scope(
            customers.client_id, customers.code,
            fn_reguser_rls_scope_value(customers.client_id, (select p from profiles p where p.id = auth.uid()))
          )
    )
    or (
      (select p.level from profiles p where p.id = auth.uid()) = 'user'
      and fn_customer_visible_to_rep(customers.client_id, customers.code, (select p.rep_code from profiles p where p.id = auth.uid()))
    )
  )
);

drop policy if exists sales_reps_select on sales_reps;

create policy sales_reps_select on sales_reps
for select using (
  sales_reps.client_id = (select p.client_id from profiles p where p.id = auth.uid())
  and (
    (select p.level from profiles p where p.id = auth.uid()) = 'adminuser'
    or (
      (select p.level from profiles p where p.id = auth.uid()) = 'reguser'
      and fn_rep_sold_within_scope(
            sales_reps.client_id, sales_reps.rep_code,
            fn_reguser_rls_scope_value(sales_reps.client_id, (select p from profiles p where p.id = auth.uid()))
          )
    )
    or (
      (select p.level from profiles p where p.id = auth.uid()) = 'user'
      and sales_reps.rep_code = (select p.rep_code from profiles p where p.id = auth.uid())
    )
  )
);

drop policy if exists branches_select on branches;

create policy branches_select on branches
for select using (
  branches.client_id = (select p.client_id from profiles p where p.id = auth.uid())
  and (
    (select p.level from profiles p where p.id = auth.uid()) = 'adminuser'
    or (
      (select p.level from profiles p where p.id = auth.uid()) = 'reguser'
      and branches.code = (select p.branch_code from profiles p where p.id = auth.uid())
    )
    or (
      (select p.level from profiles p where p.id = auth.uid()) = 'user'
      and fn_rep_sold_at_branch(branches.client_id, (select p.rep_code from profiles p where p.id = auth.uid()), branches.code)
    )
  )
);


-- ============================================================================
-- 3. budget_figures_select / sales_forecast_select — same correlated shape
--    (migration 031), read by the Budgets screen and every Dashboard/
--    Performance target-attainment calculation.
-- ============================================================================

drop policy if exists budget_figures_select on budget_figures;

create policy budget_figures_select on budget_figures
for select using (
  budget_figures.client_id = (select p.client_id from profiles p where p.id = auth.uid())
  and (
    (select p.level from profiles p where p.id = auth.uid()) = 'adminuser'
    or (
      (select p.level from profiles p where p.id = auth.uid()) = 'reguser'
      and fn_dimension_entity_visible_to_reguser(
            budget_figures.client_id, budget_figures.dimension, budget_figures.entity_code,
            (select p from profiles p where p.id = auth.uid())
          )
    )
    or (
      (select p.level from profiles p where p.id = auth.uid()) = 'user'
      and fn_dimension_entity_visible_to_user(
            budget_figures.client_id, budget_figures.dimension, budget_figures.entity_code,
            (select p from profiles p where p.id = auth.uid())
          )
    )
  )
);

drop policy if exists sales_forecast_select on sales_forecast;

create policy sales_forecast_select on sales_forecast
for select using (
  sales_forecast.client_id = (select p.client_id from profiles p where p.id = auth.uid())
  and (
    (select p.level from profiles p where p.id = auth.uid()) = 'adminuser'
    or (
      (select p.level from profiles p where p.id = auth.uid()) = 'reguser'
      and fn_dimension_entity_visible_to_reguser(
            sales_forecast.client_id, sales_forecast.dimension, sales_forecast.entity_code,
            (select p from profiles p where p.id = auth.uid())
          )
    )
    or (
      (select p.level from profiles p where p.id = auth.uid()) = 'user'
      and fn_dimension_entity_visible_to_user(
            sales_forecast.client_id, sales_forecast.dimension, sales_forecast.entity_code,
            (select p from profiles p where p.id = auth.uid())
          )
    )
  )
);


-- ============================================================================
-- 4. client_dimension_values_select — same shape (migration 046), keeps its
--    existing is_platform_admin() bypass unchanged.
-- ============================================================================

drop policy if exists client_dimension_values_select on client_dimension_values;

create policy client_dimension_values_select on client_dimension_values
for select using (
  is_platform_admin()
  or (
    client_dimension_values.client_id = (select p.client_id from profiles p where p.id = auth.uid())
    and (
      (select p.level from profiles p where p.id = auth.uid()) = 'adminuser'
      or (
        (select p.level from profiles p where p.id = auth.uid()) = 'reguser'
        and fn_dimension_value_visible_to_reguser(
              client_dimension_values.client_id, client_dimension_values.dimension_key, client_dimension_values.code,
              (select p from profiles p where p.id = auth.uid())
            )
      )
      or (
        (select p.level from profiles p where p.id = auth.uid()) = 'user'
        and fn_dimension_value_visible_to_user(
              client_dimension_values.client_id, client_dimension_values.dimension_key, client_dimension_values.code,
              (select p from profiles p where p.id = auth.uid())
            )
      )
    )
  )
);


-- ============================================================================
-- 5. Plain client_id-only policies — no level branching, so the fix is a
--    pure mechanical rewrite (the whole USING clause is just "is this my
--    client"), included for consistency and because several of these
--    (items, categories) are ALSO joined per fact row in v_sales_documents.
-- ============================================================================

drop policy if exists items_select on items;
create policy items_select on items
for select using (items.client_id = (select p.client_id from profiles p where p.id = auth.uid()));

drop policy if exists categories_select on categories;
create policy categories_select on categories
for select using (categories.client_id = (select p.client_id from profiles p where p.id = auth.uid()));

drop policy if exists suppliers_select on suppliers;
create policy suppliers_select on suppliers
for select using (suppliers.client_id = (select p.client_id from profiles p where p.id = auth.uid()));

drop policy if exists stock_movement_facts_select on stock_movement_facts;
create policy stock_movement_facts_select on stock_movement_facts
for select using (stock_movement_facts.client_id = (select p.client_id from profiles p where p.id = auth.uid()));

drop policy if exists item_stock_snapshot_select on item_stock_snapshot;
create policy item_stock_snapshot_select on item_stock_snapshot
for select using (item_stock_snapshot.client_id = (select p.client_id from profiles p where p.id = auth.uid()));

drop policy if exists excluded_customer_accounts_select on excluded_customer_accounts;
create policy excluded_customer_accounts_select on excluded_customer_accounts
for select using (excluded_customer_accounts.client_id = (select p.client_id from profiles p where p.id = auth.uid()));

drop policy if exists data_load_runs_select on data_load_runs;
create policy data_load_runs_select on data_load_runs
for select using (data_load_runs.client_id = (select p.client_id from profiles p where p.id = auth.uid()));

drop policy if exists forecast_settings_select on forecast_settings;
create policy forecast_settings_select on forecast_settings
for select using (forecast_settings.client_id = (select p.client_id from profiles p where p.id = auth.uid()));

drop policy if exists alert_settings_select on alert_settings;
create policy alert_settings_select on alert_settings
for select using (alert_settings.client_id = (select p.client_id from profiles p where p.id = auth.uid()));


-- ============================================================================
-- Verification performed before delivery (not just claimed):
--
-- 1. Loaded a scratch copy of this schema (all 48 prior migrations) with
--    9,192 sales_document_facts rows split 6,473 Edgetec / 2,719 WCSA —
--    matching production's real row counts at the time this bug was found.
-- 2. Created real profiles (adminuser/reguser/user, Edgetec AND WCSA) and
--    ran every table above through `set role authenticated` with a real
--    `auth.uid()` — not the `postgres` superuser, which bypasses RLS and
--    would hide this class of bug entirely.
-- 3. Captured row count + md5(sorted key list) for every affected table,
--    for every login level, BEFORE this migration (original policies) and
--    AFTER (this migration's policies) — identical in every case. A WCSA
--    reguser scoped to branch 'CPT' saw only 'CPT', not 'JHB'/'DBN', both
--    before and after.
-- 4. EXPLAIN ANALYZE timing (adminuser / reguser, Edgetec,
--    v_dimension_monthly_sales dimension='sales_person'): 126ms/230ms
--    before this migration, 61ms/145ms after — and, more importantly than
--    the absolute numbers, the plan shifted from a full sequential scan of
--    the entire shared sales_document_facts table (every client) to an
--    index scan scoped to just the caller's own client.
-- ============================================================================
