-- ============================================================================
-- WyzeSales — rep/branch-scoped access control, applied consistently
-- (Supabase / Postgres)
-- ============================================================================
-- Eighteenth migration. Craig, 2026-09-01: "A User can only see their data
-- and Performance no one else's across the entire application. A RegUser
-- can only see theirs and their Region and no one else's. Other users
-- Admin etc. can see everyones... The User Level combined with these two
-- fields [Rep code, Branch code] determine what a User can view."
--
-- THE GOOD NEWS, CONFIRMED BEFORE WRITING A LINE OF THIS: the core rule
-- Craig just described is already fully built and working — it's exactly
-- what sales_document_facts_select (schema/001 Section 10) does today:
-- adminuser sees everything, reguser is scoped to their own branch_code
-- (matched against warehouse_code), user is scoped to their own rep_code
-- (a UNION of the invoice's rep and the customer's assigned rep — see
-- Wyzesales_Rebuild_Decisions.md Section 3 — so nobody's own legitimate
-- work is ever hidden from them). That covers every screen built on
-- v_sales_documents / v_sales_cube_monthly / the rollup views: Sales
-- Analysis, Quote Analysis, Sales Order Analysis, Sales By, YTD
-- Comparative, and the actual-sales side of Performance and Dashboard.
-- NONE of that needs to change here.
--
-- THE ACTUAL GAP this migration closes, confirmed by reading every existing
-- RLS policy rather than assumed: two other places never got this same
-- treatment, both flagged explicitly at the time they were built as
-- deliberately left open —
--   1. budget_figures / sales_forecast (schema/001 Section 10's own comment:
--      "Sketch — refine once the Budgets screen permissions are pinned
--      down") — SELECT is open to any profile on the client, no rep/branch
--      scoping at all. Section 5 of the decisions doc documents this was a
--      conscious trade-off (Performance's "R Target"/"% Target" needed to
--      keep showing to everyone), not an oversight — but Craig's answer
--      just now, plus his explicit call that Item/Category/Company-level
--      targets should be hidden entirely for User/RegUser (those three
--      dimensions have no rep or branch owner at all — an item can be sold
--      by any rep at any branch), gives this a real, buildable rule instead
--      of an all-or-nothing choice.
--   2. customers / sales_reps / branches (schema/006) — every SELECT policy
--      there only checks "same client," no per-level scoping, so the filter
--      picker dialogs (entity_search_field.dart) show the full company-wide
--      list to every level today. Craig's answer: restrict these too, same
--      as the rest.
--
-- DESIGN: rather than re-deriving "does this rep/branch relationship exist"
-- inline in five different policies (and risking a subtly different copy in
-- each, the exact bug schema/001 Section 8's helper-function philosophy was
-- written to prevent), three small helper functions below express each
-- relationship exactly once, mirroring sales_document_facts_select's own
-- fields precisely so nothing here invents a new rule:
--   - fn_customer_visible_to_rep — the same union check
--     sales_document_facts_select already uses for 'user': a customer is
--     visible to a rep if the customer's assigned_rep_code matches, OR the
--     rep has ever actually invoiced that customer.
--   - fn_rep_sold_at_branch / fn_customer_sold_at_branch — "has this
--     rep/customer ever transacted at this branch," the natural
--     region/branch analogue of the same idea, used for a RegUser's
--     "sales_person"/"customer"-dimension budget rows and for scoping the
--     sales_reps/customers reference tables to a RegUser's own branch.
--
-- All three are `security definer`, not plain `stable` — deliberately, and
-- for the exact same reason schema/005 exists. Before this migration,
-- customers_select only checked "same client" — a one-way dependency
-- (sales_document_facts_select's own policy already reads customers, to
-- look up assigned_rep_code) that never looped back. This migration's new
-- customers_select now ALSO reads sales_document_facts (via these
-- functions) to decide visibility — which makes the dependency
-- BIDIRECTIONAL: evaluating sales_document_facts_select can require
-- evaluating customers_select, which can require evaluating
-- sales_document_facts_select again. That is structurally the same class of
-- bug schema/005's own comment describes in detail ("infinite recursion
-- detected in policy for relation X"), just a two-table cycle instead of
-- profiles referencing itself. `security definer` breaks the cycle the same
-- way schema/005 broke its own: the function's internal query runs with the
-- function owner's privileges (bypassing the target table's RLS entirely)
-- instead of re-triggering that table's own policy for the calling role.
-- `set search_path = public` is pinned on all three, matching schema/005's
-- own `is_superuser()` — standard hardening for a security-definer function
-- so it can't be tricked into resolving an unqualified table name against a
-- schema the caller controls.
--
-- Not a privilege-escalation risk despite bypassing RLS internally: every
-- call site below passes the CALLING profile's own rep_code/branch_code as
-- one of the two arguments (never someone else's) — each function only ever
-- answers "does MY OWN rep/branch code relate to this specific row," never
-- "tell me every row visible to some other, arbitrary profile."
--
-- A User's own Branch code is deliberately NOT used to scope anything here,
-- even though it's about to become a mandatory field alongside Rep code
-- (see the Flutter-side change in settings_screen.dart) — sales_
-- document_facts_select's existing 'user' rule never used branch_code
-- either, only rep_code, since a rep can legitimately sell across more than
-- one branch. Extending that to branch_code now would be inventing a new
-- restriction Craig didn't ask for and the existing transactional rule
-- doesn't have. Branch code is mandatory for User too because Craig asked
-- for both fields to be mandatory together, not because User-level scoping
-- reads it.
-- ============================================================================


-- ============================================================================
-- 1. HELPER FUNCTIONS
-- ============================================================================

-- Same union rule as sales_document_facts_select's own 'user' branch,
-- factored out so budget_figures_select/customers_select don't each carry a
-- separately-typed copy of it.
create or replace function fn_customer_visible_to_rep(p_client_id uuid, p_customer_code text, p_rep_code text)
returns boolean language sql security definer stable
set search_path = public
as $$
  select
    exists (
      select 1 from customers c
      where c.client_id = p_client_id and c.code = p_customer_code and c.assigned_rep_code = p_rep_code
    )
    or exists (
      select 1 from sales_document_facts f
      where f.client_id = p_client_id and f.account_code = p_customer_code and f.invoice_rep_code = p_rep_code
    );
$$;

-- "Has this rep ever sold at this branch" — used both directions: a
-- RegUser's own branch checked against a candidate rep code (budget_figures/
-- sales_reps_select), and a User's own rep code checked against a candidate
-- branch (branches_select) — it's the same existence check either way.
create or replace function fn_rep_sold_at_branch(p_client_id uuid, p_rep_code text, p_branch_code text)
returns boolean language sql security definer stable
set search_path = public
as $$
  select exists (
    select 1 from sales_document_facts f
    where f.client_id = p_client_id and f.invoice_rep_code = p_rep_code and f.warehouse_code = p_branch_code
  );
$$;

-- "Has this customer ever transacted at this branch" — a RegUser's region
-- analogue of fn_customer_visible_to_rep, used for the customer dimension of
-- budget_figures/sales_forecast and for customers_select.
create or replace function fn_customer_sold_at_branch(p_client_id uuid, p_customer_code text, p_branch_code text)
returns boolean language sql security definer stable
set search_path = public
as $$
  select exists (
    select 1 from sales_document_facts f
    where f.client_id = p_client_id and f.account_code = p_customer_code and f.warehouse_code = p_branch_code
  );
$$;


-- ============================================================================
-- 2. budget_figures / sales_forecast — dimension-aware scoping
-- ============================================================================
-- Item/Category/Company dimensions are deliberately absent from both the
-- reguser and user branches below — Craig's explicit call: those three have
-- no rep/branch owner, so a User/RegUser sees nothing for them rather than
-- an arbitrary/misleading answer. adminuser is unchanged (sees every
-- dimension, as today). Both tables get an identical shape, since both are
-- keyed the same way (dimension, entity_code) and Craig's rule applies
-- equally to targets and forecasts ("Performance" was named explicitly).

drop policy if exists budget_figures_select on budget_figures;

create policy budget_figures_select on budget_figures
for select using (
  exists (
    select 1 from profiles p
    where p.id = auth.uid()
      and p.client_id = budget_figures.client_id
      and (
        p.level = 'adminuser'
        or (
          p.level = 'reguser' and (
            (budget_figures.dimension = 'branch' and budget_figures.entity_code = p.branch_code)
            or (budget_figures.dimension = 'sales_person'
                and fn_rep_sold_at_branch(budget_figures.client_id, budget_figures.entity_code, p.branch_code))
            or (budget_figures.dimension = 'customer'
                and fn_customer_sold_at_branch(budget_figures.client_id, budget_figures.entity_code, p.branch_code))
          )
        )
        or (
          p.level = 'user' and (
            (budget_figures.dimension = 'sales_person' and budget_figures.entity_code = p.rep_code)
            or (budget_figures.dimension = 'customer'
                and fn_customer_visible_to_rep(budget_figures.client_id, budget_figures.entity_code, p.rep_code))
          )
        )
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
        or (
          p.level = 'reguser' and (
            (sales_forecast.dimension = 'branch' and sales_forecast.entity_code = p.branch_code)
            or (sales_forecast.dimension = 'sales_person'
                and fn_rep_sold_at_branch(sales_forecast.client_id, sales_forecast.entity_code, p.branch_code))
            or (sales_forecast.dimension = 'customer'
                and fn_customer_sold_at_branch(sales_forecast.client_id, sales_forecast.entity_code, p.branch_code))
          )
        )
        or (
          p.level = 'user' and (
            (sales_forecast.dimension = 'sales_person' and sales_forecast.entity_code = p.rep_code)
            or (sales_forecast.dimension = 'customer'
                and fn_customer_visible_to_rep(sales_forecast.client_id, sales_forecast.entity_code, p.rep_code))
          )
        )
      )
  )
);


-- ============================================================================
-- 3. customers / sales_reps / branches — scope the filter picker lists too
-- ============================================================================
-- Craig's explicit answer: yes, restrict these too, not just the report
-- data — a rep should only ever see customers/reps/branches that are
-- actually theirs to see, consistent with how the report data already
-- behaves, rather than browsing the full company list and finding out only
-- after picking that a combination returns nothing (schema/017's own
-- "greyed out" feature already softened that same UX problem for
-- CROSS-filter combinations; this closes the more basic case of the
-- picker's initial full list). `items` and `categories` are deliberately
-- UNCHANGED (still open to any client member, schema/006's original) — same
-- reasoning as Item/Category budgets above: neither has a rep or branch
-- owner, an item can be sold by anyone anywhere, so there's nothing correct
-- to scope it down to.
--
-- MUST drop schema/006's original policies first, not just add new ones
-- alongside them — Postgres OR's every applicable policy together for a
-- given command, so leaving the old "any client member" policy in place
-- would silently keep everything visible to everyone regardless of whatever
-- new, narrower policy also exists.

drop policy if exists customers_select on customers;

create policy customers_select on customers
for select using (
  exists (
    select 1 from profiles p
    where p.id = auth.uid()
      and p.client_id = customers.client_id
      and (
        p.level = 'adminuser'
        or (p.level = 'reguser' and fn_customer_sold_at_branch(customers.client_id, customers.code, p.branch_code))
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
        or (p.level = 'reguser' and fn_rep_sold_at_branch(sales_reps.client_id, sales_reps.rep_code, p.branch_code))
        or (p.level = 'user' and sales_reps.rep_code = p.rep_code)
      )
  )
);

drop policy if exists branches_select on branches;

create policy branches_select on branches
for select using (
  exists (
    select 1 from profiles p
    where p.id = auth.uid()
      and p.client_id = branches.client_id
      and (
        p.level = 'adminuser'
        or (p.level = 'reguser' and branches.code = p.branch_code)
        or (p.level = 'user' and fn_rep_sold_at_branch(branches.client_id, p.rep_code, branches.code))
      )
  )
);


-- ============================================================================
-- 4. GRANTS
-- ============================================================================
-- Same belt-and-braces convention as every prior migration — Postgres
-- grants EXECUTE to PUBLIC by default (already covering `authenticated`),
-- granted explicitly anyway. No table-level SELECT grant changes needed —
-- schema/007 already grants SELECT on every table touched here to
-- `authenticated`; only the row-level policies changed.

grant execute on function fn_customer_visible_to_rep(uuid, text, text) to authenticated;
grant execute on function fn_rep_sold_at_branch(uuid, text, text) to authenticated;
grant execute on function fn_customer_sold_at_branch(uuid, text, text) to authenticated;
