-- ============================================================================
-- WyzeSales — fix infinite RLS recursion on profiles (Supabase / Postgres)
-- ============================================================================
-- Fifth migration. Found while verifying 004 against a real seeded Postgres
-- instance — not a hypothetical: without this fix, EVERY query touching
-- sales_document_facts, budget_figures, or sales_forecast fails outright
-- with "infinite recursion detected in policy for relation profiles", for
-- every user, not just admins. This would have broken the app on first
-- real use.
--
-- Cause: `profiles_superuser_all` (schema/001 Section 10) checks "is this
-- caller a superuser" by running `select 1 from profiles where id =
-- auth.uid() and level = 'superuser'` directly inside a policy ON profiles
-- itself. That inner select is, itself, a query against a row-level-secured
-- table, so Postgres must evaluate profiles' policies again to run it —
-- including profiles_superuser_all again — which needs to run the same
-- inner select again, forever. And because every other table's policy
-- (sales_document_facts_select, budget_figures_select/write/update,
-- sales_forecast_select) also queries profiles to check the caller's level,
-- ANY access to ANY of those tables triggers the same recursion the moment
-- Postgres touches profiles.
--
-- Fix: move the "is this caller a superuser" check into a SECURITY DEFINER
-- function. A security-definer function runs with its owner's privileges —
-- when created by the migration-running role (`postgres` in Supabase, which
-- has BYPASSRLS), its internal query against profiles skips RLS entirely
-- instead of re-triggering profiles' own policies, which breaks the cycle.
-- This is the standard, documented fix for this exact class of bug on a
-- self-referencing profiles/RLS table.
--
-- profiles_self_select (id = auth.uid()) was never part of the recursion —
-- it doesn't query profiles again — and already covers every other table's
-- "look up my own row" subqueries (they all filter p.id = auth.uid()). This
-- migration only touches profiles_superuser_all, which exists for a
-- separate reason: letting a superuser see/manage OTHER users' rows (the
-- User Management screen), not for other tables' RLS checks.
-- ============================================================================

create or replace function is_superuser() returns boolean
language sql security definer stable
set search_path = public
as $$
  select exists (
    select 1 from profiles where id = auth.uid() and level = 'superuser'
  );
$$;

drop policy if exists profiles_superuser_all on profiles;

create policy profiles_superuser_all on profiles
for all using (is_superuser())
with check (is_superuser());

-- Verified (2026-08-21) against a real seeded local Postgres instance:
-- before this migration, an adminuser's second edit to the same
-- budget_figures month failed with the recursion error above; after it,
-- inserts, edits, RLS-correct denial of a non-admin's write, and the
-- documented union-rule rep visibility on sales_document_facts (a rep sees
-- their own invoices AND every invoice for a customer assigned to them,
-- even ones another rep sold — see Wyzesales_Rebuild_Decisions.md Section 3)
-- all behaved exactly as designed.
