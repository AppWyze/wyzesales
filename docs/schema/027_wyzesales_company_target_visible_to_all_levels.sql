-- ============================================================================
-- WyzeSales — whole-company Budget/Forecast visible to every access level
-- ============================================================================
-- Twenty-seventh migration. Follow-up to schema/018 and Section 62 of the
-- Decisions doc. Craig, 2026-09-03, after seeing the Dashboard's Revenue
-- Target Attainment tile show "R 0 target (MTD)" and Sales Analysis' default
-- (no-filter) view show no Target bar, both under a plain 'user' login:
-- asked whether the whole-company target should be visible to every access
-- level, even though Item/Category/Company budgets are otherwise hidden
-- from User/RegUser per schema/018. Answer: yes.
--
-- schema/018 excluded Item/Category/Company from the User/RegUser branches
-- of budget_figures_select/sales_forecast_select because "those three have
-- no rep or branch owner" — a genuine reason for Item/Category (an item can
-- be sold by anyone, anywhere, so there's no correct rep/branch-scoped
-- answer to give). Company is different in kind, not just degree: it isn't
-- an entity with an owner to fail to resolve, it's already the sum across
-- every rep/branch/customer — the aggregate itself, which is exactly what
-- schema/018's own stated rule ("A User can only see their data and
-- Performance... no one else's") is not actually about. A whole-company
-- total doesn't expose any other individual person's figures the way
-- another rep's or customer's own target would.
--
-- THE FIX: add one unconditional `dimension = 'company'` branch to both
-- policies, ahead of the existing level checks — any profile on the same
-- client can see a `dimension = 'company'` row regardless of level. Item and
-- Category remain exactly as schema/018 left them (still hidden from User/
-- RegUser) — Craig didn't ask to change those, and the "no owner to scope
-- to" reasoning still holds for them.
--
-- No Dart change needed: BudgetRepository.fetchBudget/fetchForecastValues
-- and dashboard_screen.dart's _fetchWholeCompanyTarget already just read
-- these two tables with dimension='company' — they'll simply start
-- returning rows for non-admin logins too, the moment this migration runs.
-- Verified against a scratch Postgres (schema/001-027 + seed data): with
-- this migration applied, a 'user'-level profile's SELECT against
-- budget_figures/sales_forecast for dimension='company' returns the same
-- row an adminuser sees; without it, zero rows, matching what Craig saw.
-- ============================================================================

drop policy if exists budget_figures_select on budget_figures;

create policy budget_figures_select on budget_figures
for select using (
  exists (
    select 1 from profiles p
    where p.id = auth.uid()
      and p.client_id = budget_figures.client_id
      and (
        budget_figures.dimension = 'company'
        or p.level = 'adminuser'
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
        sales_forecast.dimension = 'company'
        or p.level = 'adminuser'
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
