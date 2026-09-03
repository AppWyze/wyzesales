-- ============================================================================
-- WyzeSales — Budgets become viewable (never editable) by User/RegUser,
-- scoped per level; Category/Item open up, Customer tightens to "allocated"
-- ============================================================================
-- Thirty-first migration. Craig, 2026-09-03: "A User must be able to see
-- their own Budget but also Category Budget, Item Budget, and only their
-- allocated Customers Budgets. Not Branch or Company. A Regional User must
-- see the Branch Sales Persons, Category, Items, Branch Customers and the
-- Branch Budget. Admin sees everything. Users and RegUsers only have view
-- access. They cannot change anything Admin can."
--
-- THIS REVERSES A DELIBERATE EARLIER DECISION, same as Section 68's
-- attribution reversal — schema/018 Section 2 explicitly excluded Category/
-- Item/Company from both the reguser and user branches, on Craig's own
-- answer at the time ("those three have no rep/branch owner, so a User/
-- RegUser sees nothing for them"). Craig's instruction here supersedes that
-- for Category and Item specifically (Company stays excluded for both
-- levels — never mentioned as something either should see, consistent with
-- the existing adminuser-only company-wide target concept from Section 62/
-- migration 027-028's own back-and-forth). Category/Item budgets have no
-- rep/branch owner at all — an item can be sold by any rep at any branch —
-- so unlike Sales Person/Customer/Branch there is no scoping rule that would
-- even make sense here: every level either sees ALL of a dimension's budget
-- rows or none, and Craig's answer is now "all," for User and RegUser alike.
-- This matches customers_select/sales_reps_select's own item/category
-- reference-data tables, which schema/018 already left fully open to every
-- client member for the exact same reason ("neither has a rep or branch
-- owner").
--
-- CUSTOMER DIMENSION TIGHTENS FOR 'user': schema/018's original
-- fn_customer_visible_to_rep is a UNION rule (assigned_rep_code match OR the
-- rep has personally invoiced that customer at least once) — deliberately
-- reused from sales_document_facts_select's old "don't hide a rep's own
-- work" reasoning (Decisions doc Section 3). Craig's wording here — "only
-- their allocated Customers Budgets" — asks for something narrower: the
-- same strict assigned_rep_code-only concept migration 029/030 already
-- established for sales attribution and visibility, not "any customer I've
-- ever happened to invoice." Confirmed explicitly with Craig rather than
-- assumed, given the two readings genuinely diverge (a rep who's sold to a
-- customer without being its assigned rep would see a budget row for it
-- under the old union rule, and none under the new one) and this session's
-- own history of RLS decisions needing a second look once shipped on a
-- first guess. New helper function `fn_customer_allocated_to_rep` expresses
-- this exact narrower rule, used ONLY for budget_figures/sales_forecast's
-- customer dimension — `fn_customer_visible_to_rep` itself is UNCHANGED and
-- still used by customers_select (the customer filter picker everywhere
-- else in the app), since Craig's ask this round is specifically "the
-- Budgets" screen, not a company-wide redefinition of "which customers can
-- a rep browse." One real, accepted consequence of keeping these two rules
-- different: a rep can still pick, in a global Customer filter, a customer
-- they've sold to but aren't allocated to — Budgets will simply show no
-- entry for that customer under this new stricter rule, which is expected,
-- not a bug.
--
-- 'reguser' is otherwise UNCHANGED here beyond the Category/Item addition —
-- "Branch Sales Persons"/"Branch Customers"/"the Branch Budget" are already
-- exactly what fn_rep_sold_at_branch/fn_customer_sold_at_branch/
-- entity_code = branch_code already express (schema/018), so nothing about
-- those three needed to change, only Category/Item being newly added
-- alongside them.
--
-- `p.level = 'adminuser'` ONLY, deliberately not `in ('adminuser',
-- 'superuser')` the way sales_document_facts_select/customers_select still
-- read — double-checked against schema/008 (multitenancy) before assuming
-- that difference was a copy-paste bug worth "fixing": schema/008 retired
-- `superuser` outright ("nothing will carry the superuser level going
-- forward"), migrated every existing superuser profile away from it, and
-- explicitly narrowed budget_figures' own WRITE policies
-- (budget_figures_write/_update) from `in ('adminuser','superuser')` down to
-- `= 'adminuser'` for exactly that reason. schema/018's SELECT policy
-- (`adminuser` only, no superuser) already matches that decision correctly —
-- it's sales_document_facts_select/customers_select's own `superuser`
-- mentions elsewhere that are the (harmless — nothing is ever that level any
-- more) leftovers, not this one. Kept as `= 'adminuser'` here to match the
-- write side it sits alongside, not "corrected" to add superuser back in.
--
-- WRITE ACCESS ("Users and RegUsers only have view access. They cannot
-- change anything Admin can."): already true at the database level and
-- UNCHANGED by this migration — schema/008's budget_figures_write (INSERT)
-- and budget_figures_update (UPDATE) have only ever granted adminuser (see
-- above), never user/reguser. sales_forecast has no write policy at all for
-- any level (schema/001's own comment: "forecast is never written by a
-- user" — true for every level, not just non-admins). The gap Craig is
-- actually closing here is entirely on the Flutter side: the Budgets SCREEN
-- itself has, until now, refused to even render for anyone but an admin
-- ("Budgets are only visible to Admin and SuperUser accounts") — see the
-- accompanying Dart change for the read-only view this migration unlocks
-- data for.
-- ============================================================================

create or replace function fn_customer_allocated_to_rep(p_client_id uuid, p_customer_code text, p_rep_code text)
returns boolean language sql security definer stable
set search_path = public
as $$
  select exists (
    select 1 from customers c
    where c.client_id = p_client_id and c.code = p_customer_code and c.assigned_rep_code = p_rep_code
  );
$$;

grant execute on function fn_customer_allocated_to_rep(uuid, text, text) to authenticated;


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
            budget_figures.dimension in ('category', 'item')
            or (budget_figures.dimension = 'branch' and budget_figures.entity_code = p.branch_code)
            or (budget_figures.dimension = 'sales_person'
                and fn_rep_sold_at_branch(budget_figures.client_id, budget_figures.entity_code, p.branch_code))
            or (budget_figures.dimension = 'customer'
                and fn_customer_sold_at_branch(budget_figures.client_id, budget_figures.entity_code, p.branch_code))
          )
        )
        or (
          p.level = 'user' and (
            budget_figures.dimension in ('category', 'item')
            or (budget_figures.dimension = 'sales_person' and budget_figures.entity_code = p.rep_code)
            or (budget_figures.dimension = 'customer'
                and fn_customer_allocated_to_rep(budget_figures.client_id, budget_figures.entity_code, p.rep_code))
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
            sales_forecast.dimension in ('category', 'item')
            or (sales_forecast.dimension = 'branch' and sales_forecast.entity_code = p.branch_code)
            or (sales_forecast.dimension = 'sales_person'
                and fn_rep_sold_at_branch(sales_forecast.client_id, sales_forecast.entity_code, p.branch_code))
            or (sales_forecast.dimension = 'customer'
                and fn_customer_sold_at_branch(sales_forecast.client_id, sales_forecast.entity_code, p.branch_code))
          )
        )
        or (
          p.level = 'user' and (
            sales_forecast.dimension in ('category', 'item')
            or (sales_forecast.dimension = 'sales_person' and sales_forecast.entity_code = p.rep_code)
            or (sales_forecast.dimension = 'customer'
                and fn_customer_allocated_to_rep(sales_forecast.client_id, sales_forecast.entity_code, p.rep_code))
          )
        )
      )
  )
);
