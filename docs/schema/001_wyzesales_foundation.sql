-- ============================================================================
-- WyzeSales — Foundation Schema (Supabase / Postgres)
-- ============================================================================
-- First migration: tenancy, reference data, raw extracted facts, budgets,
-- forecast, users/roles, and the core resolution view + RLS.
--
-- This is deliberately scoped to the foundation, not the whole system. Once
-- this is reviewed, the remaining per-dimension rollup views (the Sales
-- Analysis Yr1-3/Mth1-3 shape, the 5-dimension Sales-by / Performance views)
-- follow the exact same pattern established here (v_sales_documents +
-- resolved_rep_code) and will be a second migration.
--
-- Grounded directly in the real IQRetail field names already used in
-- WyzeSalesExtract (Data/Facts.cs, Data/Lookups.cs) so this isn't guesswork —
-- see the design notes doc alongside this file for what's assumption vs fact.
-- ============================================================================


-- ============================================================================
-- 1. TENANCY
-- ============================================================================
-- Every table below carries client_id, even though only WCSA exists today,
-- per the decision to design for multi-client from day one.

create table clients (
  id          uuid primary key default gen_random_uuid(),
  code        text not null unique,          -- e.g. 'WCSA'
  name        text not null,                 -- e.g. 'Water Components SA'
  created_at  timestamptz not null default now()
);


-- ============================================================================
-- 2. REFERENCE / DIMENSION TABLES
-- ============================================================================

-- `code` is the raw warehouse/location code as it appears on every transaction
-- line (INVITEMS/QTEItems/SOrdItem/STOCKLCNT's Warehouse/LOCATION field, e.g.
-- '001'), NOT the display label. `display_code` is the old hardcoded remap
-- target ('CPT-001' etc.) — now a data row per branch instead of a 3-way
-- hardcoded IF/ELSEIF, so WCSA adding a 4th branch is an insert, not a
-- redeploy. See the note on v_sales_documents (Section 9) for why branch is
-- resolved from this table directly off each row's own warehouse code, not
-- from the selling rep — that was a mistake in an earlier draft of this
-- migration, corrected before anything was built against it.
create table branches (
  client_id     uuid not null references clients(id) on delete cascade,
  code          text not null,                  -- raw warehouse code, e.g. '001'
  display_code  text,                            -- e.g. 'CPT-001'
  name          text,                            -- e.g. 'Cape Town' (confirm real names with WCSA)
  primary key (client_id, code)
);

-- One row per rep code that has ever appeared on an invoice/quote/order.
-- Not every rep_code is a login — e.g. "Retail" (code 44) is a bucket, not a
-- person — so this is deliberately separate from `profiles` (Section 8),
-- which only has rows for rep codes that also have an app login.
--
-- Deliberately carries NO branch_code. REPS (IQRetail's rep master, queried
-- in Lookups.cs as REPS.REPNUM/REPNAME) has no branch/location column at
-- all — a rep isn't tied to one branch in the source data. An earlier draft
-- of this migration invented a "rep's home branch" concept and derived
-- transaction branch from it; that wasn't grounded in anything real and has
-- been removed. Branch is resolved directly from each transaction's own
-- warehouse code instead (Section 9).
create table sales_reps (
  client_id    uuid not null references clients(id) on delete cascade,
  rep_code     text not null,
  name         text,
  primary key (client_id, rep_code)
);

-- Sourced from DEBTORS (name) and Invoices header rows (per Map_CustomerName
-- in Lookups.cs — last row wins there; here it's just the current name).
create table customers (
  client_id                  uuid not null references clients(id) on delete cascade,
  code                       text not null,               -- ACCNUM
  name                       text,
  assigned_rep_code          text,                        -- DEBTORS.NORMALREP
  -- Generalizes the old hardcoded SalesPersonOverrideAccounts list (11
  -- accounts in appsettings.json today) into a per-customer flag. Same
  -- accounts, same starting behaviour — now editable as data, not code.
  attribute_to_assigned_rep  boolean not null default false,
  primary key (client_id, code)
);

create table categories (
  client_id        uuid not null references clients(id) on delete cascade,
  department_code  text not null,             -- DEPTMNTS.DEPARTMENT
  name             text,                      -- DEPTMNTS.DESCRIPTIO
  primary key (client_id, department_code)
);

create table suppliers (
  client_id     uuid not null references clients(id) on delete cascade,
  account_code  text not null,                -- CREDITRS.ACCOUNT
  name          text,
  primary key (client_id, account_code)
);

create table items (
  client_id             uuid not null references clients(id) on delete cascade,
  code                  text not null,          -- Stock.CODE (cleaned)
  name                  text,                   -- Stock.DESCRIPT (cleaned)
  department_code       text,
  supplier_account_code text,
  default_cost          numeric,                -- Stock.LTSTCOST
  default_sell_price    numeric,                -- Stock.SELLPRICE1
  -- Generalizes the old hardcoded SuppressedSupplierNames list (~125 names in
  -- appsettings.json today) into a per-item flag, same reasoning as
  -- customers.attribute_to_assigned_rep above.
  supplier_suppressed   boolean not null default false,
  primary key (client_id, code),
  foreign key (client_id, department_code) references categories(client_id, department_code),
  foreign key (client_id, supplier_account_code) references suppliers(client_id, account_code)
);


-- ============================================================================
-- 3. RAW EXTRACTED FACTS
-- ============================================================================
-- Written by the simplified WyzeSalesExtract. Full refresh per run (truncate
-- + reload for the extract's rolling window), matching the extract's current
-- window logic (3 fiscal years for sales documents, 36 months for stock
-- movement) but landing directly in Supabase instead of pipe-delimited files.

create type document_kind as enum ('invoice', 'credit_note', 'quote', 'sales_order');

-- Unifies what were four separate source-table pulls in the original QVS/Xojo
-- system (Invoices+INVITEMS for invoices and credit notes, QUOTES+QTEItems,
-- SOrders+SOrdItem) into one table with a document_kind discriminator. This
-- is a deliberate structural change, not just a port — see the design notes
-- doc for why: it's what makes the branch/rep resolution bug structurally
-- impossible to reintroduce, since there's only ever one resolution path.
-- Primary key is a plain generated id, NOT a natural key on (document,
-- item_code) — corrected while building the extractor: a real document can
-- legitimately carry the same item on two separate lines (re-entered
-- separately, bundled differently, etc.), and IQRetail's own line tables
-- don't expose a line-number column this extract already captures. A natural
-- key there would silently collapse two genuinely separate lines into one.
-- Since this table is fully derived and safe to replace wholesale each run
-- (same as sales_forecast), it doesn't need upsert-by-natural-key semantics
-- anyway — the extractor deletes and reinserts the whole rolling window every
-- run, so a generated id is simpler and strictly safer.
create table sales_document_facts (
  id                 bigint generated always as identity primary key,
  client_id          uuid not null references clients(id) on delete cascade,
  document_kind      document_kind not null,
  document           text not null,
  account_code       text not null,             -- ACCNUM
  doc_date           date not null,
  invoice_rep_code   text,                       -- Invoices.REP / QUOTES.REP / SOrders.REP ("as sold")
  item_code          text not null,              -- PARTNO (cleaned)
  warehouse_code     text,                       -- source warehouse/location on the line itself
  quantity           numeric not null default 0,
  value              numeric not null default 0, -- LINETOTALEXCL
  cost               numeric not null default 0, -- LINECOST * QTY
  discount_amount    numeric not null default 0, -- LDISCAM
  extracted_at       timestamptz not null default now()
);

create index on sales_document_facts (client_id, account_code);
create index on sales_document_facts (client_id, doc_date);
create index on sales_document_facts (client_id, document_kind, document);

-- Trailing 36-month net movement per item+location (StockMovementRow today).
create table stock_movement_facts (
  client_id      uuid not null references clients(id) on delete cascade,
  item_code      text not null,
  location_code  text not null,
  month          date not null,                  -- first-of-month
  quantity       numeric not null default 0,
  sales_amount   numeric not null default 0,
  sales_profit   numeric not null default 0,
  extracted_at   timestamptz not null default now(),
  primary key (client_id, item_code, location_code, month)
);

-- Point-in-time stock/lead-time snapshot (ItemWyzestock/LocationWyzestock/
-- CompanyWyzestock today).
create table item_stock_snapshot (
  client_id                   uuid not null references clients(id) on delete cascade,
  item_code                   text not null,
  location_code               text not null,
  qty_on_hand                 numeric,
  on_purchase_order_qty       numeric,
  on_sales_order_qty          numeric,
  calculated_cost             numeric,
  selling_price                numeric,
  avg_supplier_lead_time_days  int,
  first_sale_date              date,
  last_sale_date                date,
  active_months                  int,
  snapshot_date                   date not null,
  primary key (client_id, item_code, location_code, snapshot_date)
);


-- ============================================================================
-- 4. BUDGET FIGURES (user-owned — never touched by any scheduled job)
-- ============================================================================
-- CONFIRMED (2026-08-20): only the Budget (value) column is ever looked at —
-- BudgetQ (quantity) and BudgetP (profit) exist in the current database's six
-- *Budget tables but aren't used. So this is value-only, no `measure` column.

create table budget_figures (
  client_id      uuid not null references clients(id) on delete cascade,
  dimension      text not null check (dimension in
                   ('sales_person','customer','item','category','branch','company')),
  entity_code    text not null,
  fiscal_month   text not null check (fiscal_month in
                   ('Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec','Jan','Feb')),
  budget_value   numeric not null default 0,
  updated_by     uuid references auth.users(id),
  updated_at     timestamptz not null default now(),
  primary key (client_id, dimension, entity_code, fiscal_month)
);


-- ============================================================================
-- 5. FORECAST (fully computed, fully replaceable — see Wyzesales_Forecast_Redesign.md)
-- ============================================================================
-- Value-only, matching budget_figures above — the "Seasonal Forecast" column
-- on the Budgets screen and the "R Target" derivation on Performance both
-- only ever needed the value measure.

create table sales_forecast (
  client_id       uuid not null references clients(id) on delete cascade,
  dimension       text not null check (dimension in
                    ('sales_person','customer','item','category','branch','company')),
  entity_code     text not null,
  fiscal_month    text not null check (fiscal_month in
                    ('Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec','Jan','Feb')),
  forecast_value  numeric not null default 0,
  confidence      text not null check (confidence in ('full','partial','low')),
  computed_at     timestamptz not null default now(),
  primary key (client_id, dimension, entity_code, fiscal_month)
);

-- Tunable without a redeploy — the Holt-Winters smoothing weights and the
-- history-length thresholds that decide which confidence tier applies.
create table forecast_settings (
  client_id                uuid primary key references clients(id) on delete cascade,
  alpha                    numeric not null default 0.3,
  beta                     numeric not null default 0.1,
  gamma                    numeric not null default 0.3,
  full_history_months      int not null default 24,
  partial_history_months   int not null default 12
);


-- ============================================================================
-- 6. USERS / ROLES
-- ============================================================================

create type user_level as enum ('user', 'reguser', 'adminuser', 'superuser');

-- One row per app login, linked to Supabase Auth. Mirrors the current Add/
-- Edit/Delete Users screen fields exactly (Name, Email, Contact Number,
-- Level, Rep Code, Branch Code).
create table profiles (
  id              uuid primary key references auth.users(id) on delete cascade,
  client_id       uuid not null references clients(id) on delete cascade,
  name            text not null,
  email           text not null,
  contact_number  text,
  level           user_level not null default 'user',
  rep_code        text,     -- nullable: SuperUser/AdminUser aren't required to be a real rep
  branch_code     text,
  created_at      timestamptz not null default now(),
  foreign key (client_id, rep_code) references sales_reps(client_id, rep_code),
  foreign key (client_id, branch_code) references branches(client_id, code)
);


-- ============================================================================
-- 7. REMAINING CONFIG
-- ============================================================================
-- Two of the old hardcoded business-rule lists (SalesPersonOverrideAccounts,
-- SuppressedSupplierNames) are now flags on customers/items directly (see
-- Section 2). ExcludedCustomerAccounts stays a standalone list since it's not
-- a property of a customer that exists in Supabase — it's an instruction to
-- the extract about which accounts to skip entirely.

create table excluded_customer_accounts (
  client_id     uuid not null references clients(id) on delete cascade,
  account_code  text not null,
  reason        text,
  primary key (client_id, account_code)
);

create table fiscal_year_settings (
  client_id      uuid primary key references clients(id) on delete cascade,
  start_month    int not null default 3,   -- March
  override_year  int                       -- null = auto-compute
);


-- ============================================================================
-- 8. HELPER FUNCTIONS
-- ============================================================================
-- Single canonical implementations, replacing what was 4 separately-written
-- copies of the fiscal-year shift and 2 separate (one broken) branch-lookup
-- code paths in the old Xojo daily load.

create or replace function fiscal_year(p_doc_date date, p_start_month int default 3)
returns int language sql immutable as $$
  select case
    when extract(month from p_doc_date)::int >= p_start_month
      then extract(year from p_doc_date)::int + 1
    else extract(year from p_doc_date)::int
  end;
$$;

-- The single source of truth for "who does this sale count toward" — used by
-- both the reporting view (Section 9) and the RLS policies (Section 10), so
-- there is exactly one place this rule is expressed, not one-per-screen.
create or replace function resolved_rep_code(p_client_id uuid, p_account_code text, p_invoice_rep_code text)
returns text language sql stable as $$
  select coalesce(
    (select c.assigned_rep_code from customers c
     where c.client_id = p_client_id and c.code = p_account_code and c.attribute_to_assigned_rep),
    p_invoice_rep_code
  );
$$;


-- ============================================================================
-- 9. CORE RESOLUTION VIEW
-- ============================================================================
-- Replaces Transaction / QuotesAnalysis / SalesOrderAnalysis in one view.
-- Every document_kind resolves branch and rep through the exact same path —
-- this is what makes the old stale-Location bug (Quotes/SalesOrders never
-- looking up branch) structurally impossible here, not just fixed once.
--
-- Branch resolution: directly off f.warehouse_code via the branches table —
-- the raw warehouse/location code is a real field on every transaction line
-- (INVITEMS/QTEItems/SOrdItem's Warehouse column), so there's no rep-based
-- indirection needed here the way there is for rep attribution. (An earlier
-- draft resolved branch via the selling rep's "home branch" — removed once
-- grounding this against Lookups.cs confirmed REPS has no branch column at
-- all, so that concept didn't exist in the source data to begin with.)
--
-- security_invoker means this view enforces the RLS policy on the underlying
-- table for whoever is querying it, rather than running as the view's owner.

create view v_sales_documents
with (security_invoker = true) as
select
  f.client_id,
  f.document_kind,
  f.document,
  f.doc_date,
  fiscal_year(f.doc_date, coalesce(fys.start_month, 3)) as fiscal_year,
  f.account_code,
  cu.name as customer_name,
  f.invoice_rep_code,
  cu.assigned_rep_code as customer_assigned_rep_code,
  resolved_rep_code(f.client_id, f.account_code, f.invoice_rep_code) as resolved_rep_code,
  sr.name as resolved_rep_name,
  f.warehouse_code as branch_code,
  coalesce(br.display_code, f.warehouse_code) as branch_display_code,
  br.name as branch_name,
  f.item_code,
  it.name as item_name,
  it.department_code,
  cat.name as category_name,
  f.quantity,
  f.value,
  f.cost,
  (f.value - f.cost) as profit,
  case when f.value = 0 then 0
       else round((f.value - f.cost) / f.value * 100, 2)
  end as profit_percent
from sales_document_facts f
left join fiscal_year_settings fys on fys.client_id = f.client_id
left join customers cu  on cu.client_id = f.client_id and cu.code = f.account_code
left join sales_reps sr on sr.client_id = f.client_id
                        and sr.rep_code = resolved_rep_code(f.client_id, f.account_code, f.invoice_rep_code)
left join branches br   on br.client_id = f.client_id and br.code = f.warehouse_code
left join items it      on it.client_id = f.client_id and it.code = f.item_code
left join categories cat on cat.client_id = f.client_id and cat.department_code = it.department_code;

-- The simplest possible derived rollup — a monthly GROUP BY over the view
-- above, restricted to actual sales (matches ConsolidatedSales today).
create view v_consolidated_sales
with (security_invoker = true) as
select
  client_id,
  fiscal_year,
  date_trunc('month', doc_date)::date as month,
  sum(quantity) as quantity,
  sum(value) as value,
  sum(profit) as profit
from v_sales_documents
where document_kind in ('invoice', 'credit_note')
group by client_id, fiscal_year, date_trunc('month', doc_date)::date;


-- ============================================================================
-- 10. ROW LEVEL SECURITY
-- ============================================================================
-- Four-tier model: user (own transactions, union rule), reguser (own
-- branch), adminuser/superuser (everything). Visibility deliberately uses
-- the *union* of invoice-rep and customer-assigned-rep (not just the
-- resolved single value) — see Wyzesales_Rebuild_Decisions.md Section 3 for
-- why: nobody's own legitimate work should ever be hidden from them just
-- because it touched a customer assigned to someone else.

alter table sales_document_facts enable row level security;
alter table profiles enable row level security;
alter table budget_figures enable row level security;
alter table sales_forecast enable row level security;

create policy sales_document_facts_select on sales_document_facts
for select using (
  exists (
    select 1 from profiles p
    where p.id = auth.uid()
      and p.client_id = sales_document_facts.client_id
      and (
        p.level in ('adminuser', 'superuser')
        or (
          p.level = 'reguser'
          and p.branch_code = sales_document_facts.warehouse_code
        )
        or (
          p.level = 'user'
          and p.rep_code in (
                sales_document_facts.invoice_rep_code,
                (select c.assigned_rep_code from customers c
                 where c.client_id = sales_document_facts.client_id
                   and c.code = sales_document_facts.account_code)
              )
        )
      )
  )
);

-- Everyone can see their own profile; only SuperUser can see/manage others
-- (matches "only Craig can reach the User Management screen").
create policy profiles_self_select on profiles
for select using (id = auth.uid());

create policy profiles_superuser_all on profiles
for all using (
  exists (select 1 from profiles p where p.id = auth.uid() and p.level = 'superuser')
);

-- Budgets and forecasts: readable by anyone who could see the underlying
-- entity's transactions; writable (budgets only — forecast is never written
-- by a user) by adminuser/superuser. Sketch — refine once the Budgets screen
-- permissions are pinned down (e.g. can a User edit their own budget?).
create policy budget_figures_select on budget_figures
for select using (
  exists (select 1 from profiles p where p.id = auth.uid() and p.client_id = budget_figures.client_id)
);

create policy budget_figures_write on budget_figures
for insert with check (
  exists (select 1 from profiles p where p.id = auth.uid()
          and p.client_id = budget_figures.client_id and p.level in ('adminuser','superuser'))
);

create policy sales_forecast_select on sales_forecast
for select using (
  exists (select 1 from profiles p where p.id = auth.uid() and p.client_id = sales_forecast.client_id)
);
