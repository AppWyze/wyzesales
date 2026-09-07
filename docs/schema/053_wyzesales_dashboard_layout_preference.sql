-- ============================================================================
-- WyzeSales — per-user Dashboard layout preference (Option A / Option B)
-- ============================================================================
-- Fifty-third migration. Craig, looking at Edgetec's old standalone report
-- (Revenue Split / Group / Business Unit / Market laid out as classification
-- tables with R Value / R Profit / %GP): "I would like to offer the current
-- dashboard as option A and this one as option B. The user can pick and set
-- to default and then the default displays on log in. Obviously option B
-- alignes with the defined Dimensions for the client." Option B itself is
-- built client-side (dashboard_screen.dart) off the SAME generalized
-- client_dimensions/v_dimension_monthly_sales plumbing every other screen
-- already reads from — this migration is only the one new piece of state
-- needed to remember which layout a given LOGIN prefers, persisted so it
-- "displays on log in" rather than resetting every session.
--
-- FIRST ATTEMPT, caught before shipping: tried gating this with plain
-- Postgres column-level GRANTs (revoke the table-wide UPDATE grant, re-grant
-- the admin-write columns explicitly, grant `dashboard_layout` separately)
-- on the theory that Postgres would enforce "which columns" independently of
-- RLS's "which rows." Verified against the scratch DB under real
-- impersonation and that theory was WRONG: column privileges are granted to
-- the ROLE (`authenticated`), not scoped to whichever RLS policy matched —
-- since profiles_adminuser_manage_own_client (schema/008) already needs
-- `authenticated` to hold column privilege on `level` (for admin editing
-- OTHER users), a plain User satisfying the new self-row policy
-- (`id = auth.uid()`) could ALSO set `level` on their own row in the very
-- same UPDATE, because Postgres only checks "does the role have privilege on
-- every touched column, considered separately from which row-policy
-- applied." Confirmed live: `update profiles set dashboard_layout = 'A',
-- level = 'adminuser' where id = <self>` SUCCEEDED under that design — a
-- genuine self-promotion path, not a display bug.
--
-- THE FIX: a BEFORE UPDATE trigger, not column grants. `fn_profiles_
-- restrict_self_update` fires for every profiles UPDATE; when the row being
-- updated is the CALLER'S OWN (`old.id = auth.uid()`), it rejects the
-- statement outright unless every column except `dashboard_layout` is
-- unchanged from OLD to NEW. An adminuser editing a DIFFERENT profile
-- (`old.id <> auth.uid()`) never triggers this check at all — Settings >
-- Users keeps working exactly as it does today, still gated entirely by
-- profiles_adminuser_manage_own_client's row check, untouched by this
-- migration. The table-wide UPDATE grant to `authenticated` (schema/007)
-- is left exactly as it was — this fix doesn't depend on grants at all.
--
-- Verified against the scratch DB (auth.uid() redefined per test profile,
-- same impersonation technique used for every other RLS change this
-- project): Test User updating {dashboard_layout: 'B'} on their OWN row
-- succeeds; the identical call also setting {level: 'adminuser'} is REJECTED
-- (trigger exception, statement rolled back, level unchanged); Test User
-- updating Test Reguser's dashboard_layout affects 0 rows (RLS row check
-- blocks it, trigger never even reaches the level check since old.id <>
-- auth.uid() there — but the ROW itself was never reachable regardless).
-- Test Admin's existing Settings > Users edit of ANOTHER profile in the same
-- client (name/level/rep_code) still succeeds unchanged.
-- ============================================================================

alter table profiles
  add column dashboard_layout text not null default 'A' check (dashboard_layout in ('A', 'B'));

create or replace function fn_profiles_restrict_self_update()
returns trigger language plpgsql as $$
begin
  if old.id = auth.uid() then
    if new.client_id is distinct from old.client_id
      or new.name is distinct from old.name
      or new.email is distinct from old.email
      or new.contact_number is distinct from old.contact_number
      or new.level is distinct from old.level
      or new.rep_code is distinct from old.rep_code
      or new.branch_code is distinct from old.branch_code
      or new.rls_scope_code is distinct from old.rls_scope_code
      or new.is_active is distinct from old.is_active
      or new.is_platform_admin is distinct from old.is_platform_admin
    then
      raise exception 'You can only change your own Dashboard layout preference.';
    end if;
  end if;
  return new;
end;
$$;

create trigger trg_profiles_restrict_self_update
before update on profiles
for each row execute function fn_profiles_restrict_self_update();

-- The new self-service write path itself — without this, id = auth.uid()
-- never matches any existing UPDATE policy (profiles_adminuser_manage_own_
-- client requires the CALLER to be an adminuser; a plain User/RegUser
-- updating their own row matches nothing today), so the row is simply
-- unreachable regardless of the trigger above.
create policy profiles_self_update_dashboard_layout on profiles
for update using (id = auth.uid())
with check (id = auth.uid());
