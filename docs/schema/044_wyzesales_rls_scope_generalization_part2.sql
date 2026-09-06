-- ============================================================================
-- WyzeSales — RegUser/User RLS scoping generalizes for budget_figures/
-- sales_forecast/customers/sales_reps, plus a fix to the value-hierarchy FK
-- ============================================================================
-- Forty-fourth migration. Migration 041 generalized sales_document_facts_
-- select (the highest-stakes piece, and the one every report screen runs on)
-- but deliberately stopped there, flagging in its own header that
-- budget_figures_select/sales_forecast_select/customers_select/
-- sales_reps_select have real per-dimension visibility RULES that needed
-- Craig's explicit answer before being generalized, not a guess — the same
-- discipline migration 031 itself followed. Craig, asked directly:
--
--   Q1 (a brand-new fact-row classification dimension with no natural owner,
--   e.g. EdgeTec's future Revenue Split/Category Type): "Same as
--   Category/Item — open." Confirmed: these already work exactly like
--   Category/Item today (no rep or branch owns a classification label), so
--   the open rule generalizes directly.
--
--   Q2 (a customer-attribute dimension sitting ABOVE the RLS-scope dimension
--   in a hierarchy, e.g. Morgenster's Region/Country above Area): "Yes, walk
--   the hierarchy up." A RegUser scoped to Area X can see a Region/Country
--   entry for whichever Region/Country Area X itself belongs to.
--
--   General principle, Craig's own words: "The same rules need to apply. If
--   it doesn't belong to the sales rep then they should not be able to
--   see it." — applied below as: every dimension either resolves to an
--   explicit ownership/scope check (Sales Person, Customer, the RLS-scope
--   dimension itself, a hierarchy ancestor of it), or is a classification
--   with no owner at all (Category/Item and any future fact_column
--   dimension shaped like them) and stays open — never a silent default to
--   "open" for something that DOES have an owner.
--
-- ZERO BEHAVIOUR CHANGE FOR WCSA, verified below the same way migration 041
-- was: WCSA's only dimensions are the original six, its only is_rls_scope
-- row is 'branch', and none of them are 'customer_attribute', so every new
-- helper function below reduces to exactly what fn_rep_sold_at_branch/
-- fn_customer_sold_at_branch/the old hardcoded branch_code checks already did.
--
-- ONE SCHEMA BUG FOUND AND FIXED WHILE BUILDING CASE 2 (the hierarchy walk):
-- migration 038's client_dimension_values.parent_code has a foreign key back
-- to client_dimension_values requiring the SAME dimension_key on both sides
-- — `foreign key (client_id, dimension_key, parent_code) references
-- client_dimension_values (client_id, dimension_key, code)`. That can only
-- ever express a hierarchy WITHIN one dimension (e.g. Category → Sub-
-- category, both dimension_key = 'category'); it cannot express Area →
-- Region → Country as three separate dimension_keys, which is exactly what
-- the design doc's own Section 2/3.2 describes and what Craig just confirmed
-- the RLS rule needs. The inline comment on that column ("a Region row's
-- parent_code = its Area's code") also has the relationship backwards versus
-- the "Area → Region → Country" rollup direction stated right next to it — a
-- Region contains many Areas, so a Region row cannot have one specific Area
-- as "its" parent; it's each AREA that has one specific Region as ITS parent.
-- Nothing has ever been seeded into client_dimension_values (WCSA doesn't use
-- it; EdgeTec/Morgenster aren't onboarded), so this corrects course before
-- any real data exists, not a live migration of existing rows. The corrected,
-- and now enforced, convention: `client_dimensions.parent_dimension_key` on
-- the FINER dimension (Area) names the BROADER dimension it rolls up into
-- (Region); `client_dimension_values.parent_code` on a FINER value (an Area
-- code) holds the code of the BROADER value it belongs to (that Region's
-- code) — ordinary child → parent, same direction `parent_dimension_key`'s
-- own name already implies. Section 1 below replaces the old same-dimension
-- FK with a trigger that validates against this corrected, cross-dimension
-- shape instead.
-- ============================================================================


-- ============================================================================
-- 1. client_dimension_values.parent_code — fix to allow crossing dimensions
-- ============================================================================

do $$
declare
  v_conname text;
begin
  select conname into v_conname
  from pg_constraint
  where conrelid = 'client_dimension_values'::regclass
    and confrelid = 'client_dimension_values'::regclass
    and contype = 'f';
  if v_conname is not null then
    execute format('alter table client_dimension_values drop constraint %I', v_conname);
  end if;
end $$;

-- Replaces the dropped FK: parent_code, when set, must be a real code in
-- THIS dimension's declared parent_dimension_key (client_dimensions), not in
-- the same dimension_key as before. A dimension with no parent_dimension_key
-- configured can never have a parent_code value at all — there's nothing for
-- it to mean.
-- security definer so this validation doesn't depend on the calling role's
-- own read visibility into client_dimensions/client_dimension_values (both
-- RLS-protected tables) — the same "administrative check shouldn't be at
-- the mercy of the caller's own policy visibility" reasoning schema/005's
-- helper-function philosophy already established, applied to a trigger
-- instead of a policy USING clause this time.
create or replace function fn_check_dimension_value_parent()
returns trigger language plpgsql security definer
set search_path = public
as $$
declare
  v_parent_dim text;
begin
  if new.parent_code is null then
    return new;
  end if;

  select parent_dimension_key into v_parent_dim
  from client_dimensions
  where client_id = new.client_id and dimension_key = new.dimension_key;

  if v_parent_dim is null then
    raise exception 'client_dimension_values: % has no parent_dimension_key configured, so % cannot set parent_code',
      new.dimension_key, new.code;
  end if;

  if not exists (
    select 1 from client_dimension_values
    where client_id = new.client_id and dimension_key = v_parent_dim and code = new.parent_code
  ) then
    raise exception 'client_dimension_values: parent_code % is not a valid % value for client %',
      new.parent_code, v_parent_dim, new.client_id;
  end if;

  return new;
end;
$$;

drop trigger if exists client_dimension_values_check_parent on client_dimension_values;

create trigger client_dimension_values_check_parent
before insert or update on client_dimension_values
for each row execute function fn_check_dimension_value_parent();


-- ============================================================================
-- 2. HELPER FUNCTIONS
-- ============================================================================

-- Generalizes fn_rep_sold_at_branch (schema/018): "has this rep sold
-- anything within this client's current RLS scope value" instead of
-- specifically "at this branch." For WCSA, fn_fact_rls_scope_value resolves
-- to f.warehouse_code exactly as it always has, so this is byte-identical
-- behaviour for the one client that exists today.
create or replace function fn_rep_sold_within_scope(p_client_id uuid, p_rep_code text, p_scope_value text)
returns boolean language plpgsql stable security definer
set search_path = public
as $$
begin
  if p_scope_value is null then
    return false;
  end if;
  return exists (
    select 1 from sales_document_facts f
    where f.client_id = p_client_id
      and f.invoice_rep_code = p_rep_code
      and fn_fact_rls_scope_value(p_client_id, f) = p_scope_value
  );
end;
$$;

-- Generalizes fn_customer_sold_at_branch (schema/018) the same way.
create or replace function fn_customer_sold_within_scope(p_client_id uuid, p_customer_code text, p_scope_value text)
returns boolean language plpgsql stable security definer
set search_path = public
as $$
begin
  if p_scope_value is null then
    return false;
  end if;
  return exists (
    select 1 from sales_document_facts f
    where f.client_id = p_client_id
      and f.account_code = p_customer_code
      and fn_fact_rls_scope_value(p_client_id, f) = p_scope_value
  );
end;
$$;

-- Case 2: is (p_target_dimension_key, p_target_code) an ancestor of
-- (p_start_dimension_key, p_start_code) — i.e. can you reach it by walking
-- UP from the starting value via parent_dimension_key/parent_code? Used to
-- answer "does my own Area value belong, transitively, to this Region/
-- Country row" — Craig's confirmed Case 2 answer. Depth-capped rather than a
-- recursive CTE (simpler to reason about a per-row loop across a table that
-- doesn't exist yet for any live client, and a real hierarchy will never be
-- more than 2-3 levels deep per the design doc's own catalogue).
create or replace function fn_dimension_value_is_ancestor(
  p_client_id uuid,
  p_start_dimension_key text,
  p_start_code text,
  p_target_dimension_key text,
  p_target_code text
)
returns boolean language plpgsql stable security definer
set search_path = public
as $$
declare
  v_dim        text := p_start_dimension_key;
  v_code       text := p_start_code;
  v_parent_dim text;
  v_parent_code text;
  v_depth      int := 0;
begin
  if v_dim = p_target_dimension_key and v_code = p_target_code then
    return true;
  end if;

  loop
    v_depth := v_depth + 1;
    exit when v_depth > 8; -- generous guard; no configured hierarchy is remotely this deep

    select cd.parent_dimension_key, cdv.parent_code
      into v_parent_dim, v_parent_code
    from client_dimensions cd
    left join client_dimension_values cdv
      on cdv.client_id = p_client_id and cdv.dimension_key = v_dim and cdv.code = v_code
    where cd.client_id = p_client_id and cd.dimension_key = v_dim;

    if v_parent_dim is null or v_parent_code is null then
      return false;
    end if;

    if v_parent_dim = p_target_dimension_key and v_parent_code = p_target_code then
      return true;
    end if;

    v_dim := v_parent_dim;
    v_code := v_parent_code;
  end loop;

  return false;
end;
$$;

-- The full per-dimension decision for a RegUser, used by budget_figures/
-- sales_forecast: Sales Person/Customer keep their existing scope-based
-- rules (generalized to whatever scope this client has, not just Branch);
-- the RLS-scope dimension itself requires an exact match on the reguser's
-- own scope value; any hierarchy ancestor of the reguser's own scope value
-- (Case 2) is visible; a classification dimension with no owner (Category/
-- Item today, any future fact_column dimension shaped like them, per
-- Case 1) is open; everything else defaults to hidden — Craig's principle,
-- "if it doesn't belong to the sales rep then they should not be able to
-- see it," applied as an explicit allow-list, never a silent default-open.
create or replace function fn_dimension_entity_visible_to_reguser(
  p_client_id uuid,
  p_dimension_key text,
  p_entity_code text,
  p profiles
)
returns boolean language plpgsql stable security definer
set search_path = public
as $$
declare
  v_scope_key       text;
  v_scope_value     text;
  v_resolution_kind text;
begin
  select dimension_key into v_scope_key from client_dimensions where client_id = p_client_id and is_rls_scope;
  v_scope_value := fn_reguser_rls_scope_value(p_client_id, p);

  if v_scope_key is null or v_scope_value is null then
    return false; -- no scope configured for this client, or this reguser has none assigned — safe default
  end if;

  if p_dimension_key = 'sales_person' then
    return fn_rep_sold_within_scope(p_client_id, p_entity_code, v_scope_value);
  elsif p_dimension_key = 'customer' then
    return fn_customer_sold_within_scope(p_client_id, p_entity_code, v_scope_value);
  end if;

  if p_dimension_key = v_scope_key then
    return p_entity_code = v_scope_value;
  end if;

  select resolution_kind into v_resolution_kind from client_dimensions where client_id = p_client_id and dimension_key = p_dimension_key;

  if v_resolution_kind = 'fact_column' then
    return true; -- Case 1: classification dimension, no owner
  elsif v_resolution_kind = 'existing' then
    return p_dimension_key in ('category', 'item'); -- Company stays excluded, matching migration 031
  elsif v_resolution_kind = 'customer_attribute' then
    return fn_dimension_value_is_ancestor(p_client_id, v_scope_key, v_scope_value, p_dimension_key, p_entity_code); -- Case 2
  end if;

  return false;
end;
$$;

-- Same decision for 'user' level — narrower than reguser today (Craig,
-- migration 031: "Not Branch or Company"), generalized the same way: the
-- RLS-scope dimension itself, and any dimension that isn't Category/Item/
-- Sales Person/Customer, stays hidden from an individual rep. This includes
-- a hierarchy-ancestor dimension (Case 2) — a User never saw Branch-level
-- budgets either, and a Region/Country entry is the same shape of
-- "broader than my own detail" as Branch was. Flagging this specific
-- extrapolation for Craig to correct if a User should see those after all;
-- everything else here is a direct read of his existing migration 031 rule.
create or replace function fn_dimension_entity_visible_to_user(
  p_client_id uuid,
  p_dimension_key text,
  p_entity_code text,
  p profiles
)
returns boolean language plpgsql stable security definer
set search_path = public
as $$
declare
  v_scope_key       text;
  v_resolution_kind text;
begin
  if p_dimension_key = 'sales_person' then
    return p_entity_code = p.rep_code;
  elsif p_dimension_key = 'customer' then
    return fn_customer_allocated_to_rep(p_client_id, p_entity_code, p.rep_code);
  end if;

  select dimension_key into v_scope_key from client_dimensions where client_id = p_client_id and is_rls_scope;
  if v_scope_key is not null and p_dimension_key = v_scope_key then
    return false; -- generalized "Not Branch"
  end if;

  select resolution_kind into v_resolution_kind from client_dimensions where client_id = p_client_id and dimension_key = p_dimension_key;
  if v_resolution_kind = 'fact_column' or p_dimension_key in ('category', 'item') then
    return true;
  end if;

  return false;
end;
$$;

grant execute on function fn_rep_sold_within_scope(uuid, text, text) to authenticated;
grant execute on function fn_customer_sold_within_scope(uuid, text, text) to authenticated;
grant execute on function fn_dimension_value_is_ancestor(uuid, text, text, text, text) to authenticated;
grant execute on function fn_dimension_entity_visible_to_reguser(uuid, text, text, profiles) to authenticated;
grant execute on function fn_dimension_entity_visible_to_user(uuid, text, text, profiles) to authenticated;


-- ============================================================================
-- 3. budget_figures / sales_forecast — dimension-generic scoping
-- ============================================================================

drop policy if exists budget_figures_select on budget_figures;

create policy budget_figures_select on budget_figures
for select using (
  exists (
    select 1 from profiles p
    where p.id = auth.uid()
      and p.client_id = budget_figures.client_id
      and (
        p.level = 'adminuser'
        or (p.level = 'reguser' and fn_dimension_entity_visible_to_reguser(budget_figures.client_id, budget_figures.dimension, budget_figures.entity_code, p))
        or (p.level = 'user' and fn_dimension_entity_visible_to_user(budget_figures.client_id, budget_figures.dimension, budget_figures.entity_code, p))
      )
  )
);

drop policy if exists sales_forecast_select on sales_forecast;

create policy sales_forecast_select on sales_forecast
for select using (
  exists (
    select 1 from profiles p
    where p.id = auth.uid()
      and p.client_id = sales_forecast.client_id
      and (
        p.level = 'adminuser'
        or (p.level = 'reguser' and fn_dimension_entity_visible_to_reguser(sales_forecast.client_id, sales_forecast.dimension, sales_forecast.entity_code, p))
        or (p.level = 'user' and fn_dimension_entity_visible_to_user(sales_forecast.client_id, sales_forecast.dimension, sales_forecast.entity_code, p))
      )
  )
);


-- ============================================================================
-- 4. customers / sales_reps — scope the filter picker lists the same way
-- ============================================================================
-- fn_customer_visible_to_rep/fn_customer_allocated_to_rep were already
-- generic (rep-code and actual-invoice based, nothing branch-specific in
-- their own definitions) — only the reguser branches below, which called the
-- branch-specific fn_customer_sold_at_branch/fn_rep_sold_at_branch directly,
-- needed changing.
--
-- branches_select (schema/018) is deliberately left untouched: `branches` is
-- a physical reference table that only ever exists for a Branch-scoped
-- client (WCSA) — EdgeTec's Market and Morgenster's Area have no equivalent
-- physical table; their values live in client_dimension_values instead,
-- governed by that table's own RLS (schema/038's client_dimension_values_
-- select). That table's own reguser/user scoping — should a Regional user's
-- Area/Market picker show every client value or just their own scope's — is
-- a real, separate question nobody's asked yet since no client has any data
-- in it. Flagging it here rather than deciding it silently: worth a specific
-- answer from Craig once EdgeTec/Morgenster are actually being onboarded,
-- same as everything else in Section 6 step 5.

drop policy if exists customers_select on customers;

create policy customers_select on customers
for select using (
  exists (
    select 1 from profiles p
    where p.id = auth.uid()
      and p.client_id = customers.client_id
      and (
        p.level = 'adminuser'
        or (p.level = 'reguser' and fn_customer_sold_within_scope(customers.client_id, customers.code, fn_reguser_rls_scope_value(customers.client_id, p)))
        or (p.level = 'user' and fn_customer_visible_to_rep(customers.client_id, customers.code, p.rep_code))
      )
  )
);

drop policy if exists sales_reps_select on sales_reps;

create policy sales_reps_select on sales_reps
for select using (
  exists (
    select 1 from profiles p
    where p.id = auth.uid()
      and p.client_id = sales_reps.client_id
      and (
        p.level = 'adminuser'
        or (p.level = 'reguser' and fn_rep_sold_within_scope(sales_reps.client_id, sales_reps.rep_code, fn_reguser_rls_scope_value(sales_reps.client_id, p)))
        or (p.level = 'user' and sales_reps.rep_code = p.rep_code)
      )
  )
);
