-- ============================================================================
-- WyzeSales — saved filter presets (Decisions doc Section 79)
-- ============================================================================
-- Thirty-fifth migration. Craig's own choice (AskUserQuestion) for what to
-- tackle after the 2026-09-04 Dashboard filter-scoping fix: let a user save
-- their current combination of global filters under a name and reapply it
-- later, instead of re-picking the same Sales Person/Branch/etc. every time
-- they sign in.
--
-- Two design questions Craig answered directly (AskUserQuestion, 2026-09-04):
--
-- 1. Scope: "Private per user" — NOT shared with the rest of the client's
--    users. Each row belongs to exactly one profile (`user_id`), and RLS
--    below never lets anyone read, edit, or delete a preset that isn't
--    theirs. No "shared/team" concept exists here at all — if Craig wants
--    that later it's a new column + policy, not a retrofit of this one.
--
-- 2. Fields captured: "Just the 5 dimension filters" — Sales Person,
--    Category, Customer, Item, Branch. Deliberately does NOT capture Year,
--    Month, or Document — Craig's own reasoning (paraphrased from the
--    options he was given): a preset is "my view of the data," and Year/
--    Month should stay live/current each time it's reapplied rather than
--    freezing a specific past period into a preset meant to be reused
--    indefinitely. `global_filters.dart`'s `GlobalFilters` class holds all
--    8 fields for the app's own live session state (2026-08-26 decision);
--    this table intentionally only mirrors 5 of them.
--
-- One row per (user, preset name) — `unique(user_id, name)` — so a user
-- can't accidentally end up with two presets both called "My Branch" and no
-- way to tell them apart in the picker.
--
-- `user_id`/`client_id` both default from the signed-in session
-- (`auth.uid()`/`get_my_client_id()`, schema/008) rather than being passed
-- by the app on insert — one less thing the Flutter side can get wrong, and
-- it means a preset can never be inserted under someone else's id even if a
-- future bug tried to.
-- ============================================================================

create table filter_presets (
  id                  uuid primary key default gen_random_uuid(),
  user_id             uuid not null default auth.uid() references profiles(id) on delete cascade,
  client_id           uuid not null default get_my_client_id() references clients(id) on delete cascade,
  name                text not null,
  sales_person_code   text,
  sales_person_label  text,
  category_code       text,
  category_label      text,
  customer_code       text,
  customer_label      text,
  item_code           text,
  item_label          text,
  branch_code         text,
  branch_label        text,
  created_at          timestamptz not null default now(),
  unique (user_id, name)
);

alter table filter_presets enable row level security;

-- Private per user (see header) — every policy checks `user_id = auth.uid()`
-- and nothing else. No level/adminuser carve-out: even an adminuser can only
-- see and manage their OWN saved presets here, same as everyone else.
create policy filter_presets_select on filter_presets
for select using (user_id = auth.uid());

create policy filter_presets_insert on filter_presets
for insert with check (user_id = auth.uid());

create policy filter_presets_update on filter_presets
for update using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy filter_presets_delete on filter_presets
for delete using (user_id = auth.uid());

grant select, insert, update, delete on filter_presets to authenticated;
