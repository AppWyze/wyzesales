-- ============================================================================
-- WyzeSales — RegUser/User scoping for client_dimension_values (the generic
-- dimension picker's own reference list)
-- ============================================================================
-- Forty-sixth migration. Closes the last gap migration 044 itself flagged and
-- deliberately left open: "branches_select is deliberately left untouched...
-- EdgeTec's Market and Morgenster's Area have no equivalent physical table;
-- their values live in client_dimension_values instead... That table's own
-- reguser/user scoping — should a Regional user's Area/Market picker show
-- every client value or just their own scope's — is a real, separate
-- question nobody's asked yet since no client has any data in it... worth a
-- specific answer from Craig once EdgeTec/Morgenster are actually being
-- onboarded."
--
-- Asked, and answered, Craig (2026-09-07), with a concrete example: "The
-- answer is a RegUser can only see what applies to them i.e. If the RegUser
-- is Western Cape and there are areas A,B,C,D. the first 3 fall under
-- Western Cape and the 4th falls under Gauteng then the user would only see
-- A,B,C and not D. D should not appear in the filter."
--
-- That example scopes a FINER dimension's values (Area) against a BROADER
-- RLS-scope dimension (Region-shaped, "Western Cape"/"Gauteng") — the mirror
-- image of migration 044's own Case 2 (a BROADER dimension's row, e.g.
-- Region/Country, checked against a FINER RLS-scope value, e.g. an
-- Area-scoped RegUser). fn_dimension_value_is_ancestor (migration 044)
-- already walks the parent_dimension_key/parent_code chain in one direction
-- only; fn_dimension_value_visible_to_reguser below calls it in BOTH
-- directions, so a candidate client_dimension_values row is visible whether
-- it's an ancestor of the RegUser's own scope value (Case 2, already
-- proven), a descendant of it (this migration, Craig's A/B/C/D example), or
-- an exact match on the scope dimension itself (unchanged from
-- branches_select's existing `branches.code = p.branch_code` shape).
-- Deliberately generic about WHICH of a client's dimensions ends up flagged
-- is_rls_scope (Area vs Region, say) — neither EdgeTec nor Morgenster has
-- entered their real client_dimensions rows yet, so nothing here hard-codes
-- an assumption either way; it works correctly whichever dimension a
-- platform admin eventually flags, and whichever direction the dimension
-- being filtered sits relative to it.
--
-- A dimension with NO hierarchy relationship to the client's RLS-scope
-- dimension at all (neither an ancestor nor a descendant of it) defaults to
-- HIDDEN for a RegUser, not open — the conservative reading of Craig's own
-- principle ("if it doesn't belong to the sales rep then they should not be
-- able to see it"). Deliberately NOT reusing migration 044's Case 1 "no
-- owner, stays open" answer here: that answer was given specifically for
-- budget_figures/sales_forecast ROW visibility, a different table: extending
-- it to this table would be guessing rather than reading back a rule Craig
-- actually gave for THIS one. No real client has such a dimension configured
-- yet (EdgeTec/Morgenster's only generic dimensions described so far are
-- exactly the connected Area/Region/Market/Country hierarchy), so this
-- default has nothing to affect today — revisit with a concrete question if
-- one ever shows up, the same way Case 1 itself was only answered once
-- budget_figures/sales_forecast needed it.
--
-- Symmetrically extends the same scoping to 'user' level (an individual
-- rep) via fn_dimension_value_visible_to_user, sourced from the rep's OWN
-- actual sales rather than a single assigned scope value — ordinary reps
-- have no rls_scope_code, only RegUsers do (migration 039). This is the same
-- shape schema/018's branches_select already uses for Branch
-- (`fn_rep_sold_at_branch`), generalized here the way fn_rep_sold_within_
-- scope (migration 044) already generalized fn_rep_sold_at_branch itself.
-- NOT something Craig was asked directly this time — flagging this specific
-- extrapolation the same way migration 044's own fn_dimension_entity_
-- visible_to_user comment flagged its own: leaving 'user' with MORE
-- visibility here than a RegUser above them would be a real inconsistency
-- with Craig's stated principle, so this errs toward the same restriction
-- rather than none. Correct if wrong once EdgeTec/Morgenster have real
-- individual-rep logins to check it against.
--
-- ZERO BEHAVIOUR CHANGE FOR WCSA: WCSA has never had a single row in
-- client_dimension_values (all six of its dimensions are 'existing', backed
-- by their own physical tables) — this policy stays unreachable for WCSA,
-- exactly as before this migration.
-- ============================================================================


-- ============================================================================
-- 1. HELPER FUNCTIONS
-- ============================================================================

-- Is client_dimension_values row (p_dimension_key, p_code) visible to this
-- RegUser? Unlike fn_dimension_entity_visible_to_reguser (migration 044,
-- used for budget_figures/sales_forecast row visibility), this never needs
-- the sales_person/customer ownership branches — client_dimension_values
-- only ever holds rows for 'fact_column'/'customer_attribute' dimensions;
-- the six 'existing' dimensions (including sales_person/customer) live in
-- their own physical tables and never appear here.
create or replace function fn_dimension_value_visible_to_reguser(
  p_client_id uuid,
  p_dimension_key text,
  p_code text,
  p profiles
)
returns boolean language plpgsql stable security definer
set search_path = public
as $$
declare
  v_scope_key   text;
  v_scope_value text;
begin
  select dimension_key into v_scope_key from client_dimensions where client_id = p_client_id and is_rls_scope;
  v_scope_value := fn_reguser_rls_scope_value(p_client_id, p);

  if v_scope_key is null or v_scope_value is null then
    return false; -- no scope configured for this client, or this RegUser has none assigned — same safe default fn_dimension_entity_visible_to_reguser already uses
  end if;

  if p_dimension_key = v_scope_key then
    return p_code = v_scope_value; -- exact match on my own scope value — same shape branches_select's reguser branch already uses (`branches.code = p.branch_code`)
  end if;

  return fn_dimension_value_is_ancestor(p_client_id, v_scope_key, v_scope_value, p_dimension_key, p_code)   -- p_code is BROADER than my scope (a Region/Country my Area belongs to) — migration 044's Case 2
      or fn_dimension_value_is_ancestor(p_client_id, p_dimension_key, p_code, v_scope_key, v_scope_value);  -- p_code is FINER than my scope (an Area under my own Region) — Craig's A/B/C/D example
end;
$$;

-- 'user' (individual rep) equivalent — see this migration's own header
-- comment for why this is sourced from the rep's actual transaction history
-- rather than a single assigned scope value. `f.invoice_rep_code = p.
-- rep_code`, not resolved_rep_code — same "attribution follows the actual
-- seller" rule schema/030 established, matching fn_rep_sold_at_branch/
-- fn_rep_sold_within_scope's own convention exactly.
--
-- Performance note (same category schema/026 already flagged once for
-- fn_rep_sold_at_branch): this is a real per-row EXISTS scan of the rep's own
-- sales_document_facts rows, not an O(1) lookup — acceptable for the same
-- reason fn_rep_sold_at_branch already was (bounded by one rep's own row
-- count, and dormant for WCSA, which has nothing in client_dimension_values
-- to ever call this against). Revisit once EdgeTec/Morgenster are live with
-- real data volumes, same as schema/026 revisited schema/018.
create or replace function fn_dimension_value_visible_to_user(
  p_client_id uuid,
  p_dimension_key text,
  p_code text,
  p profiles
)
returns boolean language plpgsql stable security definer
set search_path = public
as $$
declare
  v_scope_key text;
begin
  select dimension_key into v_scope_key from client_dimensions where client_id = p_client_id and is_rls_scope;
  if v_scope_key is null then
    return false;
  end if;

  return exists (
    select 1 from sales_document_facts f
    where f.client_id = p_client_id
      and f.invoice_rep_code = p.rep_code
      and (
        fn_dimension_value_is_ancestor(p_client_id, v_scope_key, fn_fact_rls_scope_value(p_client_id, f), p_dimension_key, p_code)
        or fn_dimension_value_is_ancestor(p_client_id, p_dimension_key, p_code, v_scope_key, fn_fact_rls_scope_value(p_client_id, f))
      )
  );
end;
$$;

grant execute on function fn_dimension_value_visible_to_reguser(uuid, text, text, profiles) to authenticated;
grant execute on function fn_dimension_value_visible_to_user(uuid, text, text, profiles) to authenticated;


-- ============================================================================
-- 2. client_dimension_values_select — reguser/user scoping
-- ============================================================================
-- adminuser keeps the unconditional, unrestricted read it already had (same
-- shape branches_select/customers_select/sales_reps_select all use) — only
-- the reguser/user branches are new.

drop policy if exists client_dimension_values_select on client_dimension_values;

create policy client_dimension_values_select on client_dimension_values
for select using (
  is_platform_admin()
  or exists (
    select 1 from profiles p
    where p.id = auth.uid()
      and p.client_id = client_dimension_values.client_id
      and (
        p.level = 'adminuser'
        or (
          p.level = 'reguser'
          and fn_dimension_value_visible_to_reguser(client_dimension_values.client_id, client_dimension_values.dimension_key, client_dimension_values.code, p)
        )
        or (
          p.level = 'user'
          and fn_dimension_value_visible_to_user(client_dimension_values.client_id, client_dimension_values.dimension_key, client_dimension_values.code, p)
        )
      )
  )
);
