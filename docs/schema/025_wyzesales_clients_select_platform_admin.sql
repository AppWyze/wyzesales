-- WyzeSales — schema/025: platform admin visibility on clients (RLS gap fix)
-- ============================================================================
-- Craig, 2026-09-02: created a second client via the Platform Admin screen's
-- "Add client" (part of testing the leaked-service-role-key remediation's
-- Edge Functions) — the new client row existed in the database but never
-- appeared in the Clients list on screen, with no error shown either.
--
-- Root cause: clients_select (schema/006, written back when this app had
-- exactly one tenant) only ever allowed seeing a client row whose id
-- matches YOUR OWN profile's client_id:
--
--   exists (select 1 from profiles p where p.id = auth.uid() and p.client_id = clients.id)
--
-- schema/008 introduced is_platform_admin() and correctly added it to every
-- other cross-tenant table this same Admin screen reads/writes — license,
-- pricing_plan, profiles — and even to clients' own UPDATE/INSERT policies
-- (clients_platform_admin_update/_insert) — but clients_select itself was
-- never revisited, so a platform admin could only ever see their OWN
-- client row, never any other tenant's. This stayed invisible the whole
-- time because Water Components SA was the only client that existed until
-- this test: the policy was accidentally correct for exactly as long as
-- there was only one row it could ever apply to, not because it was
-- actually scoped right.
--
-- Fix: the same is_platform_admin() OR clause every other cross-tenant
-- policy here already uses. Drop and recreate rather than an in-place
-- ALTER POLICY, since Postgres has no ALTER POLICY ... ADD CONDITION —
-- this mirrors how schema/018 replaced customers_select for the same
-- reason.
-- ============================================================================

drop policy if exists clients_select on clients;

create policy clients_select on clients
for select using (
  is_platform_admin()
  or exists (select 1 from profiles p where p.id = auth.uid() and p.client_id = clients.id)
);
