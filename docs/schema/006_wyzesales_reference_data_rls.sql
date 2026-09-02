-- ============================================================================
-- WyzeSales — enable RLS on the remaining tables (Supabase / Postgres)
-- ============================================================================
-- Sixth migration. Found by Supabase's own SQL editor linter when running
-- 001 into a fresh project — not hypothetical: schema/001 only enabled RLS
-- on four tables (sales_document_facts, profiles, budget_figures,
-- sales_forecast). Every other table it creates was left with RLS off
-- entirely, which in Supabase means anyone with the anon or authenticated
-- key — which is not a secret, it's meant to be public and RLS is the only
-- thing standing between it and your data — could read (and, depending on
-- default grants, write) branches, sales reps, customers, categories,
-- suppliers, items, stock movement, stock snapshots, and every config table,
-- straight through the auto-generated REST API, no login required.
--
-- Two tables are a bigger miss than the rest: stock_movement_facts and
-- item_stock_snapshot are raw extracted business data (like
-- sales_document_facts), not just reference/config data, and were
-- completely unprotected — this wasn't just the "obviously fine to leave
-- open" reference tables, it was real operational data too.
--
-- This migration enables RLS on every remaining table and adds SELECT
-- policies scoped to "you have a profile for this client" — the same shape
-- already used successfully for budget_figures_select/sales_forecast_select
-- in schema/001, which schema/005 confirmed doesn't recurse. No INSERT/
-- UPDATE/DELETE policies are added for any of these: they're written by
-- WyzeSalesExtract and WCSA staff directly, both of which connect with
-- elevated database access that bypasses RLS rather than through the app's
-- anon/authenticated API — the app should never write to these tables.
-- ============================================================================

alter table clients enable row level security;
alter table branches enable row level security;
alter table sales_reps enable row level security;
alter table customers enable row level security;
alter table categories enable row level security;
alter table suppliers enable row level security;
alter table items enable row level security;
alter table stock_movement_facts enable row level security;
alter table item_stock_snapshot enable row level security;
alter table excluded_customer_accounts enable row level security;
alter table fiscal_year_settings enable row level security;
alter table forecast_settings enable row level security;

-- clients has no client_id column of its own — it IS the id every other
-- table's client_id points at — so its check is "the client I have a
-- profile for", not "my own client_id column".
create policy clients_select on clients
for select using (
  exists (select 1 from profiles p where p.id = auth.uid() and p.client_id = clients.id)
);

create policy branches_select on branches
for select using (
  exists (select 1 from profiles p where p.id = auth.uid() and p.client_id = branches.client_id)
);

create policy sales_reps_select on sales_reps
for select using (
  exists (select 1 from profiles p where p.id = auth.uid() and p.client_id = sales_reps.client_id)
);

create policy customers_select on customers
for select using (
  exists (select 1 from profiles p where p.id = auth.uid() and p.client_id = customers.client_id)
);

create policy categories_select on categories
for select using (
  exists (select 1 from profiles p where p.id = auth.uid() and p.client_id = categories.client_id)
);

create policy suppliers_select on suppliers
for select using (
  exists (select 1 from profiles p where p.id = auth.uid() and p.client_id = suppliers.client_id)
);

create policy items_select on items
for select using (
  exists (select 1 from profiles p where p.id = auth.uid() and p.client_id = items.client_id)
);

create policy stock_movement_facts_select on stock_movement_facts
for select using (
  exists (select 1 from profiles p where p.id = auth.uid() and p.client_id = stock_movement_facts.client_id)
);

create policy item_stock_snapshot_select on item_stock_snapshot
for select using (
  exists (select 1 from profiles p where p.id = auth.uid() and p.client_id = item_stock_snapshot.client_id)
);

create policy excluded_customer_accounts_select on excluded_customer_accounts
for select using (
  exists (select 1 from profiles p where p.id = auth.uid() and p.client_id = excluded_customer_accounts.client_id)
);

create policy fiscal_year_settings_select on fiscal_year_settings
for select using (
  exists (select 1 from profiles p where p.id = auth.uid() and p.client_id = fiscal_year_settings.client_id)
);

create policy forecast_settings_select on forecast_settings
for select using (
  exists (select 1 from profiles p where p.id = auth.uid() and p.client_id = forecast_settings.client_id)
);
