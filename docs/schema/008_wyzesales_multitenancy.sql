-- ============================================================================
-- WyzeSales — multi-tenancy: license, pricing, platform admin (Supabase / Postgres)
-- ============================================================================
-- Eighth migration. Builds the same shape as SeaWyze's Admin/Settings tier
-- system (see docs/Wyzesales_MultiTenancy_Design_Proposal.md, confirmed with
-- Craig 2026-08-25), simplified to WyzeSales' actual unit: a client is users
-- only, never vessels. Every vessel-shaped column SeaWyze carries
-- (max_vessels, base_vessels, price_per_additional_vessel, helm_tier) is
-- dropped entirely rather than carried along unused.
--
-- What this migration does, in order:
--   1. pricing_plan + license tables (Section 1/2 below)
--   2. profiles gains is_active, is_platform_admin (Section 3)
--   3. SECURITY DEFINER helpers: get_my_client_id(), is_adminuser(),
--      is_platform_admin() — same recursion-safe pattern schema/005
--      established for is_superuser() (Section 4)
--   4. RLS + grants for the two new tables (Section 5)
--   5. Seat-limit trigger on profiles (Section 6)
--   6. Role migration: superuser -> adminuser + is_platform_admin, and the
--      profiles/budget_figures policies that referenced 'superuser' updated
--      to key off adminuser only (Section 7) — per Craig's decision 8,
--      "superuser should fall away and be replaced with
--      administer-platform... all adminuser's should be able to add, delete
--      and edit users." superuser stays in the user_level enum as an unused
--      legacy value (Postgres can't cleanly drop a single enum value without
--      recreating the type), it's just never assigned again after this runs.
--   7. WCSA backfill: a Standard pricing_plan row and a license row so the
--      existing client has real data under the new model, not a null gap
--      (Section 8) — PLACEHOLDER figures, Craig adjusts via the new Pricing
--      tab immediately after deploying.
--
-- NOT done here, needs a manual step after this migration runs (Supabase
-- Auth users can't be created from plain SQL — inserting into auth.users
-- directly bypasses identity/credential setup and isn't supported): create
-- the support+wcsa@wyzesales.com login (full_name 'WyzeSales Support',
-- client_id = WCSA's clients.id, level = 'adminuser', is_platform_admin =
-- true) via the new create-user Edge Function once deployed, or via the
-- Supabase dashboard's "Add user" + a matching profiles insert. Craig's own
-- existing login needs no separate action here beyond this migration — the
-- role migration in Section 7 already flags it is_platform_admin = true.
-- ============================================================================


-- ============================================================================
-- 1. PRICING PLAN
-- ============================================================================
-- One row per named plan (e.g. 'Standard'). Rates are monthly, same
-- convention SeaWyze's Pricing tab used — license.annual_price is computed
-- by multiplying by 12 wherever it's (re)calculated, both here and in the
-- app (see Section 8's backfill and the Platform Admin Pricing tab).

create table pricing_plan (
  id                          uuid primary key default gen_random_uuid(),
  name                        text not null unique,
  description                 text,
  base_price                  numeric not null default 0,   -- ZAR/month, includes base_users seats
  price_per_additional_user   numeric not null default 0,   -- ZAR/month per seat beyond base_users
  base_users                  int not null default 5,
  currency                    text not null default 'ZAR',
  is_active                   boolean not null default true,
  created_at                  timestamptz not null default now()
);


-- ============================================================================
-- 2. LICENSE
-- ============================================================================
-- One row per client. discount_percent is Craig's preferred alternative to
-- an is_custom_price override flag (design doc Section 4, decision 5): a
-- manually negotiated rate is expressed as a percentage off the plan-derived
-- total (computed_total * (1 - discount_percent / 100)), so it stays correct
-- automatically if the base plan's rates change later, rather than freezing
-- a stale absolute number the way SeaWyze's plan-recalculation bug does
-- (platform_admin_screen.dart's _PricingTabState._save() silently overwrites
-- every license's annual_price, including ones with a hand-negotiated rate —
-- see design doc Section 1). annual_price here is still a stored, computed
-- column (matches SeaWyze's shape and this project's existing style of
-- storing computed figures rather than deriving them per-query — see
-- v_consolidated_sales) — the Platform Admin Pricing tab is what keeps it in
-- sync when rates or a license's own max_users/discount change.

create table license (
  id                  uuid primary key default gen_random_uuid(),
  client_id           uuid not null references clients(id) on delete cascade,
  plan_id             uuid references pricing_plan(id),
  max_users           int not null default 5,
  base_users          int not null default 5,
  start_date          date not null default current_date,
  end_date            date not null,
  status              text not null default 'active' check (status in ('active', 'expired', 'suspended')),
  annual_price        numeric,
  discount_percent    numeric not null default 0 check (discount_percent >= 0 and discount_percent <= 100),
  created_at          timestamptz not null default now()
);

-- One active license per client at a time — mirrors SeaWyze's de-facto
-- "getLicense(companyId) returns .maybeSingle()" assumption (settings_
-- repository.dart) by actually enforcing it, rather than relying on every
-- caller to remember to filter/order/limit if a client ever accumulated more
-- than one row.
create unique index license_one_per_client on license (client_id);


-- ============================================================================
-- 3. PROFILES — is_active, is_platform_admin
-- ============================================================================
-- is_active: mirrors SeaWyze's app_user.is_active (deactivate without
-- deleting — settings_repository.dart's deactivateUser/reactivateUser).
-- Enforcement that a deactivated user can't use the app is an app-layer
-- check (SessionNotifier signs them out if their own profile comes back
-- is_active = false), not something Supabase Auth itself consults — Auth has
-- no knowledge of this table.
--
-- is_platform_admin: WyzeSales staff (currently Craig, plus each client's
-- support+<clientcode>@wyzesales.com login going forward) — reaches the new
-- cross-tenant Platform Admin screen, and is excluded from its own client's
-- billable seat count (Section 6's trigger, Section 8's backfill).

alter table profiles add column is_active boolean not null default true;
alter table profiles add column is_platform_admin boolean not null default false;


-- ============================================================================
-- 4. SECURITY DEFINER HELPERS
-- ============================================================================
-- Same recursion-safe shape schema/005 established for is_superuser(): a
-- SECURITY DEFINER function's internal query against profiles runs as its
-- owner (the migration role, which has BYPASSRLS in Supabase) instead of
-- re-triggering profiles' own RLS policies. Without this, a policy on
-- profiles (or on license/pricing_plan) that queries profiles to check the
-- caller's own row would recurse exactly the way schema/005's comment
-- describes.

create or replace function get_my_client_id() returns uuid
language sql security definer stable
set search_path = public
as $$
  select client_id from profiles where id = auth.uid();
$$;

create or replace function is_adminuser() returns boolean
language sql security definer stable
set search_path = public
as $$
  select exists (
    select 1 from profiles where id = auth.uid() and level = 'adminuser'
  );
$$;

create or replace function is_platform_admin() returns boolean
language sql security definer stable
set search_path = public
as $$
  select exists (
    select 1 from profiles where id = auth.uid() and is_platform_admin = true
  );
$$;


-- ============================================================================
-- 5. RLS + GRANTS — license, pricing_plan
-- ============================================================================
-- Deliberately tighter than SeaWyze's own equivalent tables, which the
-- design doc flagged as a gap worth closing rather than copying (Section 1:
-- SeaWyze's platform_admin_update_pricing / platform_admin_insert_license
-- policies are USING(true) — any authenticated request can write them,
-- there's no is_platform_admin check in the policy itself, only in the
-- Flutter screen deciding whether to show the button). Here, every write is
-- gated by is_platform_admin() in the policy, not just in the UI.

alter table license enable row level security;
alter table pricing_plan enable row level security;

-- A client's own adminuser can see their own license (read-only — the
-- License tab in the new Settings screen); a platform admin can see every
-- license (the Admin screen's Licenses tab).
create policy license_select on license
for select using (
  is_platform_admin() or (is_adminuser() and client_id = get_my_client_id())
);

create policy license_platform_admin_write on license
for insert with check (is_platform_admin());

create policy license_platform_admin_update on license
for update using (is_platform_admin()) with check (is_platform_admin());

create policy license_platform_admin_delete on license
for delete using (is_platform_admin());

-- clients (schema/001/006) previously had only a SELECT policy — nobody
-- could rename their own client, matching SeaWyze's Company tab having no
-- equivalent to edit either (its Settings > Company tab edit is
-- is_platform_admin-gated in the UI, per platform_admin_screen.dart's
-- _EditCompanyDialog, not something a company's own admin can do there).
-- Same split here: a client's own adminuser can update their client's row
-- (currently just `name` — clients has no address/contact columns, per the
-- design doc's "on top of the existing clients/profiles" scope), a
-- platform admin can update any client.
create policy clients_adminuser_update on clients
for update using (is_adminuser() and id = get_my_client_id())
with check (is_adminuser() and id = get_my_client_id());

create policy clients_platform_admin_update on clients
for update using (is_platform_admin()) with check (is_platform_admin());

create policy clients_platform_admin_insert on clients
for insert with check (is_platform_admin());

grant update, insert on clients to authenticated;

-- pricing_plan isn't per-client data (it's the shared rate card every
-- client's license points at), so read access is any adminuser/platform
-- admin rather than scoped by client_id — matches who can reach a screen
-- that needs it (the License tab shows the plan name/rate; the Admin
-- screen's Pricing tab edits it).
create policy pricing_plan_select on pricing_plan
for select using (is_platform_admin() or is_adminuser());

create policy pricing_plan_platform_admin_write on pricing_plan
for insert with check (is_platform_admin());

create policy pricing_plan_platform_admin_update on pricing_plan
for update using (is_platform_admin()) with check (is_platform_admin());

create policy pricing_plan_platform_admin_delete on pricing_plan
for delete using (is_platform_admin());

-- Base SQL privileges — schema/007's comment explains why this is a
-- separate gate from RLS and needed even though RLS above already narrows
-- what any given request can actually touch.
grant select, insert, update, delete on license to authenticated;
grant select, insert, update, delete on pricing_plan to authenticated;


-- ============================================================================
-- 6. SEAT LIMIT — enforced at the DB level, not just in the app
-- ============================================================================
-- Per Craig's decision 4 ("Yes, DB level enforcement as well") — SeaWyze
-- only checks max_users in the Flutter Users-tab "Add user" flow
-- (design doc Section 1's "gap"), so a direct API call bypasses it entirely.
-- This trigger makes going over a client's max_users fail at the database
-- regardless of which path inserts/reactivates the row.
--
-- is_platform_admin rows (support logins) never count against the seat
-- limit — matches SeaWyze's own rule (design doc Section 1/5) and Section 8's
-- WCSA backfill below, which relies on exactly this to not itself trip the
-- limit it's setting up.
--
-- Fires on INSERT (new user) and on UPDATE only when the row is *newly*
-- becoming counted — going active, losing platform-admin status, or moving
-- to a different client — not on every unrelated profile edit (e.g. editing
-- someone's name shouldn't re-run a seat check that was already satisfied).

create or replace function enforce_license_seat_limit() returns trigger
language plpgsql security definer
set search_path = public
as $$
declare
  v_max_users int;
  v_current_count int;
begin
  if new.is_platform_admin then
    return new;
  end if;

  if tg_op = 'UPDATE'
     and old.is_active = new.is_active
     and old.is_platform_admin = new.is_platform_admin
     and old.client_id = new.client_id then
    return new; -- nothing seat-relevant changed
  end if;

  if not new.is_active then
    return new; -- deactivating (or inserting inactive) never needs a seat
  end if;

  select max_users into v_max_users
  from license
  where client_id = new.client_id and status = 'active';

  if v_max_users is null then
    return new; -- no active license row yet — don't block, nothing to check against
  end if;

  select count(*) into v_current_count
  from profiles
  where client_id = new.client_id
    and is_platform_admin = false
    and is_active = true
    and id is distinct from new.id;

  if v_current_count >= v_max_users then
    raise exception 'Seat limit reached: this client''s license allows % active user(s)', v_max_users;
  end if;

  return new;
end;
$$;

create trigger profiles_seat_limit_check
before insert or update on profiles
for each row execute function enforce_license_seat_limit();


-- ============================================================================
-- 7. ROLE MIGRATION — superuser -> adminuser + is_platform_admin
-- ============================================================================
-- Craig's decision 8: superuser falls away, replaced with the
-- is_platform_admin flag (same shape as SeaWyze's app_user.is_platform_admin),
-- and every adminuser can add/edit/delete users — not just a single
-- top-tier role. Applied narrowly (today this only matches Craig's own
-- account) rather than assuming which rows qualify.

update profiles set level = 'adminuser', is_platform_admin = true where level = 'superuser';

-- profiles_superuser_all (schema/005) let a superuser manage ANY client's
-- profiles rows with no client_id scoping at all — that was fine while
-- there was exactly one client and one superuser, but it's a real
-- cross-tenant hole under multi-tenancy. Replaced with two narrower
-- policies: a client's own adminuser can only manage their own client's
-- users, and cross-tenant reach is granted only to is_platform_admin()
-- (the intended new "Craig / support logins can see everything" tier).
drop policy if exists profiles_superuser_all on profiles;

create policy profiles_adminuser_manage_own_client on profiles
for all using (is_adminuser() and client_id = get_my_client_id())
with check (is_adminuser() and client_id = get_my_client_id());

create policy profiles_platform_admin_all on profiles
for all using (is_platform_admin())
with check (is_platform_admin());

-- is_superuser() (schema/005) has no remaining callers after the drop
-- above — removed rather than left around unused, now that its one caller
-- is gone. (The user_level enum itself still lists 'superuser' — Postgres
-- can't drop a single enum value without recreating the type, so it stays
-- as an unused legacy value; nothing will be set to it again after the
-- UPDATE above.)
drop function if exists is_superuser();

-- budget_figures_write/_update (schema/001, schema/004) both still say
-- "level in ('adminuser','superuser')" — narrowed to adminuser only, since
-- nothing will carry the superuser level going forward.
drop policy if exists budget_figures_write on budget_figures;
drop policy if exists budget_figures_update on budget_figures;

create policy budget_figures_write on budget_figures
for insert with check (
  exists (select 1 from profiles p where p.id = auth.uid()
          and p.client_id = budget_figures.client_id and p.level = 'adminuser')
);

create policy budget_figures_update on budget_figures
for update using (
  exists (select 1 from profiles p where p.id = auth.uid()
          and p.client_id = budget_figures.client_id and p.level = 'adminuser')
)
with check (
  exists (select 1 from profiles p where p.id = auth.uid()
          and p.client_id = budget_figures.client_id and p.level = 'adminuser')
);


-- ============================================================================
-- 8. WCSA BACKFILL
-- ============================================================================
-- Craig's decision 7: "we will need to backfill everything to accommodate
-- this new function." Gives the existing WCSA client a real pricing_plan +
-- license row instead of the app finding nulls the first time it queries
-- them. Figures below are PLACEHOLDERS — adjust via the new Platform Admin
-- screen's Pricing/Licenses tabs immediately after this migration runs;
-- nothing here is a real quoted WyzeSales price.

insert into pricing_plan (name, description, base_price, price_per_additional_user, base_users, currency, is_active)
values ('Standard', 'Standard WyzeSales plan — PLACEHOLDER rates, set via Platform Admin > Pricing', 2500, 350, 5, 'ZAR', true)
on conflict (name) do nothing;

insert into license (client_id, plan_id, max_users, base_users, start_date, end_date, status, annual_price, discount_percent)
select
  c.id,
  p.id,
  20,                                    -- PLACEHOLDER max seats for WCSA
  p.base_users,
  current_date,
  current_date + interval '1 year',
  'active',
  (p.base_price + (20 - p.base_users) * p.price_per_additional_user) * 12,
  0
from clients c, pricing_plan p
where c.code = 'WCSA' and p.name = 'Standard'
on conflict (client_id) do nothing;
