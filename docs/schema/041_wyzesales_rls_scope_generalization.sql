-- ============================================================================
-- WyzeSales — RegUser RLS scoping generalizes beyond Branch
-- ============================================================================
-- Forty-first migration. The single highest-stakes piece of the multi-tenant
-- dimension model (design doc Section 3.4: "a mistake here risks leaking data
-- across reps or clients rather than just a display bug"). Generalizes
-- sales_document_facts_select's reguser branch from the hardcoded
-- `p.branch_code = sales_document_facts.warehouse_code` (schema/001, carried
-- unchanged through schema/018/029) to "match whichever dimension THIS
-- CLIENT flagged is_rls_scope in client_dimensions (migration 038), resolved
-- the correct way for its kind" — Branch for WCSA, and (once their own
-- client_dimensions rows are entered per the design doc's Section 6 step 5)
-- Market for EdgeTec, Area for Morgenster.
--
-- ZERO BEHAVIOUR CHANGE FOR WCSA, verified below, not just claimed: WCSA's
-- only client_dimensions row with is_rls_scope = true is 'branch', with
-- resolution_kind = 'existing' (migration 038's seed). Both new helper
-- functions below special-case exactly that combination to read
-- p.branch_code / f.warehouse_code directly — the same two columns, the same
-- comparison, that today's policy already makes. No client without a
-- 'branch' row configured this way is affected differently either, since
-- there is currently exactly one client (WCSA) and this is exactly its
-- existing configuration.
--
-- DELIBERATELY NOT DONE HERE, flagged rather than silently decided:
--   1. budget_figures_select / sales_forecast_select (schema/018, most
--      recently rewritten by migration 031) have real per-dimension
--      visibility rules beyond "match my scope value" — e.g. Category/Item
--      are open to every reguser/user unconditionally (no rep/branch owner),
--      while Sales Person/Customer get a "has this rep/customer transacted
--      within my scope" check via fn_rep_sold_at_branch/
--      fn_customer_sold_at_branch. Generalizing these for the NEW generic
--      dimensions needs the same kind of explicit rule Craig gave for each
--      case that's already in migration 031 (his own words: "A Regional User
--      must see the Branch Sales Persons, Category, Items, Branch Customers
--      and the Branch Budget") — there's no existing precedent yet for "how
--      should budget visibility work for a brand-new fact-row dimension like
--      Revenue Split" or "a brand-new customer-attribute dimension that
--      ISN'T the RLS scope, like Morgenster's Region when Area is the
--      boundary." My own default guess, to confirm before it becomes a
--      migration: new fact-row dimensions (Group/Business Unit, Category
--      Type, Revenue Split, Range, Type) behave like Category/Item today —
--      no rep/branch/scope owner, open to every level unconditionally; new
--      customer-attribute dimensions above the RLS-scope dimension in a
--      hierarchy (Morgenster's Region/Country, Customer Category) get a
--      generalized version of fn_customer_sold_at_branch, walking the same
--      client_dimension_values.parent_code chain the design doc's Section
--      3.2 already models. Holding off writing this until it's confirmed,
--      same way migration 031 itself was written only once Craig gave the
--      exact rule, not guessed at.
--   2. customers_select / sales_reps_select / branches_select (schema/018
--      Section 3) similarly scope the filter-picker lists to a reguser/
--      user's own branch/rep today. These need the same kind of
--      generalization once (1) above is settled, for the same reason.
-- Neither gap affects WCSA today, and neither blocks EdgeTec/Morgenster's
-- core Sales Analysis / Sales By / Performance screens, which all run on
-- sales_document_facts_select (generalized right here) via v_sales_documents
-- / v_dimension_monthly_sales / v_dimension_performance.
-- ============================================================================


-- ============================================================================
-- 1. HELPER FUNCTIONS
-- ============================================================================
-- Both use `to_jsonb(row) ->> (name)` to reach a dynamically-named column
-- (dim_N_code / attr_N_code) rather than a 12-way CASE per function — the
-- column NAME comes from client_dimensions.dimension_key, which is always
-- one of exactly the twelve values migration 039 added columns for, so this
-- is a lookup by a controlled, constrained name, not arbitrary user input.
-- `security definer` for the same reason schema/005/018's helpers all are:
-- fn_fact_rls_scope_value reads customers (a different table with its own
-- RLS), and calling it from sales_document_facts_select's own policy would
-- otherwise recurse the same way schema/005's comment describes.

-- What value does THIS fact row carry for the client's current RLS-scope
-- dimension? Returns null if the client has no is_rls_scope dimension
-- configured (nothing yet configured -> nobody at reguser level can see
-- anything for that client, a safe default, not an open one).
create or replace function fn_fact_rls_scope_value(p_client_id uuid, f sales_document_facts)
returns text language plpgsql stable security definer
set search_path = public
as $$
declare
  v_dimension_key   text;
  v_resolution_kind text;
  v_customer        jsonb;
begin
  select dimension_key, resolution_kind into v_dimension_key, v_resolution_kind
  from client_dimensions
  where client_id = p_client_id and is_rls_scope;

  if v_dimension_key is null then
    return null;
  end if;

  if v_resolution_kind = 'existing' then
    -- Branch is the only 'existing' dimension that can be an RLS scope
    -- (design doc principle 5) — resolved directly off the fact row's own
    -- warehouse code, exactly as sales_document_facts_select always has.
    return case v_dimension_key when 'branch' then f.warehouse_code else null end;
  elsif v_resolution_kind = 'fact_column' then
    return to_jsonb(f) ->> (v_dimension_key || '_code');
  elsif v_resolution_kind = 'customer_attribute' then
    select to_jsonb(c) into v_customer
    from customers c
    where c.client_id = p_client_id and c.code = f.account_code;
    return v_customer ->> (replace(v_dimension_key, 'dim_', 'attr_') || '_code');
  end if;

  return null;
end;
$$;

-- What value has THIS reguser been assigned for the client's current
-- RLS-scope dimension? 'branch' reads profiles.branch_code (unchanged from
-- today); anything else reads the new generic profiles.rls_scope_code
-- (migration 039).
create or replace function fn_reguser_rls_scope_value(p_client_id uuid, p profiles)
returns text language plpgsql stable security definer
set search_path = public
as $$
declare
  v_dimension_key text;
begin
  select dimension_key into v_dimension_key
  from client_dimensions
  where client_id = p_client_id and is_rls_scope;

  if v_dimension_key is null then
    return null;
  elsif v_dimension_key = 'branch' then
    return p.branch_code;
  else
    return p.rls_scope_code;
  end if;
end;
$$;

grant execute on function fn_fact_rls_scope_value(uuid, sales_document_facts) to authenticated;
grant execute on function fn_reguser_rls_scope_value(uuid, profiles) to authenticated;


-- ============================================================================
-- 2. sales_document_facts_select — generalized reguser branch
-- ============================================================================
-- adminuser branch tidied to drop the 'superuser' mention while this policy
-- is being rewritten anyway — schema/008 retired that level outright and
-- migration 031 already made the same cleanup for budget_figures_select;
-- harmless either way since nothing is ever level = 'superuser' after
-- schema/008's one-time migration, not a functional change.
--
-- 'user' branch is byte-for-byte unchanged from migration 029 — Sales Person
-- stays an 'existing' dimension for every client (design doc principle 3),
-- resolved exactly as it is today, nothing about it generalizes here.

drop policy if exists sales_document_facts_select on sales_document_facts;

create policy sales_document_facts_select on sales_document_facts
for select using (
  exists (
    select 1 from profiles p
    where p.id = auth.uid()
      and p.client_id = sales_document_facts.client_id
      and (
        p.level = 'adminuser'
        or (
          p.level = 'reguser'
          and fn_reguser_rls_scope_value(p.client_id, p) is not null
          and fn_reguser_rls_scope_value(p.client_id, p) = fn_fact_rls_scope_value(sales_document_facts.client_id, sales_document_facts)
        )
        or (
          p.level = 'user'
          and p.rep_code in (
                sales_document_facts.invoice_rep_code,
                resolved_rep_code(sales_document_facts.client_id, sales_document_facts.account_code, sales_document_facts.invoice_rep_code)
              )
        )
      )
  )
);

-- Performance note (schema/026 already had to learn this lesson once): both
-- helper functions above are O(1) per row for WCSA specifically — they never
-- scan sales_document_facts the way schema/018's fn_customer_visible_to_rep/
-- fn_rep_sold_at_branch/fn_customer_sold_at_branch do; they read a small,
-- indexed client_dimensions lookup (primary-keyed by client_id) plus, for a
-- 'customer_attribute' scope only, one indexed point lookup into customers
-- via its own (client_id, code) primary key. No new index is added here for
-- that reason. Revisit once EdgeTec/Morgenster are live with real data
-- volumes, the same way schema/026 revisited schema/018 once real usage
-- exposed a cost the seed data hadn't.
