-- ============================================================================
-- WyzeSales — revert 027's company-dimension carve-out; RLS goes back to
-- schema/018's original shape
-- ============================================================================
-- Twenty-eighth migration. Follow-up to schema/027 and Section 62 of the
-- Decisions doc, same day. 027 made budget_figures/sales_forecast's
-- `dimension = 'company'` rows visible to every access level, to fix the
-- Dashboard's Revenue Target Attainment tile (and Sales Analysis' default
-- view) showing "R 0 target" to non-admin logins.
--
-- Working through it further with Craig surfaced a better fix that makes
-- 027 unnecessary: "The dashboard must be specific. i.e. User sees only
-- their info. RegUsers sees their branch and Admin sees everything." Rather
-- than widen RLS so every login can see the literal whole-company figure,
-- lib/core/utils/target_overlay.dart's new `defaultTargetScope` now has the
-- Dashboard tile and Sales Analysis' default view each ask for the VIEWER'S
-- OWN dimension+entity instead — company/ALL for adminuser (unchanged),
-- branch/their own branch_code for reguser, sales_person/their own rep_code
-- for user. Every one of those was already correctly permitted under
-- schema/018's ORIGINAL policies with no widening needed at all — a
-- reguser's own branch_code and a user's own rep_code are exactly what
-- those policies already grant. So 027's carve-out no longer serves the app
-- at all, and leaving it in place would mean a non-admin login could still
-- read the literal whole-company figure by querying budget_figures/
-- sales_forecast directly (e.g. via the Supabase client's own API,
-- independent of anything the UI shows) — a real RLS hole against a
-- principle Craig just stated explicitly, not merely a UI cosmetic one.
--
-- THE FIX: this migration is 027's exact inverse — it re-drops and
-- re-creates both policies back to precisely schema/018's original text,
-- with no `dimension = 'company'` branch. Written to be safe to run whether
-- or not 027 was ever actually applied: DROP POLICY IF EXISTS + CREATE
-- POLICY is idempotent, so this migration alone guarantees the correct end
-- state regardless of which of 026/027 already ran against this project.
--
-- One consequence worth knowing: Sales Analysis' "2+ dimension filters
-- stacked" proportional-share estimate (core/utils/target_overlay.dart's
-- `deriveProportionalTarget`) still needs the TRUE whole-company target/
-- actual as its baseline — there's no "my own" analogue of "this
-- combination's share of the whole company" to substitute. For a
-- non-admin login that resolves to null now (same as before 027 ever
-- existed), which `deriveProportionalTarget` already degrades from
-- gracefully — no estimated bar shown, rather than a company figure that
-- login isn't supposed to see. Not something this migration needs to fix;
-- flagging it since it's the one place a non-admin login still can't get an
-- estimate, by design.
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
