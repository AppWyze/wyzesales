-- 054_wyzesales_company_dimension_never_cross_filters.sql
--
-- Bug report (Craig, 2026-09-08, screenshot of the top-bar search): typing
-- "jacqi" returned two results — the real match, "JACQI" (Sales Person), AND
-- a spurious "Company" result (tagged "Company") that has nothing to do with
-- "jacqi" at all.
--
-- Root cause: `client_dimensions.drives_cross_filter` (schema/038) is meant
-- to be false for the 'company' pseudo-dimension on every client — Company
-- isn't a real, filterable entity (there's only ever one, entity_code
-- 'ALL'), it already means "no narrowing at all" (see fiscal.dart's own
-- `SalesDimension.company` doc comment: "it already means 'no narrowing at
-- all', and there's nothing to rank within a single whole-company total").
-- `ReferenceDataRepository.entitiesFor`'s own 'company' branch doesn't even
-- wire the search term to anything — it always returns the single ALL/
-- Company row regardless of what was typed. `searchAllDimensions`
-- (reference_data_repository.dart) filters its dimension list to
-- `drivesCrossFilter` specifically so this never-actually-searched row is
-- excluded from search — and the same flag (plus `shows_on_dashboard_top5`)
-- is what GlobalFilterBar's "Add filter" dropdown and the Dashboard's
-- ranking-breakdown picker both rely on for the identical reason.
--
-- WCSA's own 'company' row (the only one ever created by a SQL seed —
-- schema/038 Section 4) correctly has drives_cross_filter = false,
-- shows_on_dashboard_top5 = false. Every OTHER client's dimensions
-- (Edgetec's Group/Market/Revenue Split/etc, and its own Company entry) are
-- created through the Platform Admin Dimensions tab instead
-- (platform_admin_screen.dart's `_EditDimensionDialog`), whose "add
-- dimension" form defaults BOTH flags to `true` — a sensible default for a
-- REAL dimension, but wrong for 'company' specifically, and (until this
-- same commit's Dart-side fix) nothing in that form warned an admin that
-- Company needs the opposite of the default. Confirmed directly against
-- this sandbox's scratch DB (seeded to mirror the two real clients' actual
-- client_dimensions data):
--
--   code | dimension_key | drives_cross_filter | shows_on_dashboard_top5
--   EDGE | company       | t                    | t
--   WCSA | company       | f                    | f
--
-- Edgetec's 'company' row was created via the admin UI with both defaults
-- left unchanged — exactly this bug, live. (`drives_budgets` staying `true`
-- for 'company' on every client, WCSA included, is correct and untouched
-- here — Budgets legitimately offers a whole-company target, see
-- budgets_screen.dart's own `_allowedDimensionsFor`.)
--
-- Fixed two ways, not just one — a data patch alone would leave the exact
-- same mistake available to make again the next time a client is
-- configured, or the next time someone edits an existing Company row and
-- happens to leave a checkbox ticked:
--
--  1. Data fix (below): correct every EXISTING client_dimensions row that
--     has dimension_key = 'company' but either flag still wrongly true.
--  2. A CHECK constraint enforcing the invariant at the database level, for
--     every client, forever — this is a fact about what 'company' MEANS,
--     not a per-client preference an admin (or a future form default)
--     should be trusted to get right by hand every time. Scoped to only
--     these two flags — is_rls_scope/drives_budgets have no equivalent
--     "company is special" rule, so they're left exactly as whatever value
--     is otherwise chosen.
--
-- A companion Dart-side fix (platform_admin_screen.dart, same commit) also
-- auto-corrects and locks these two switches the moment 'company' is
-- selected in the Add/Edit Dimension dialog, so a friendly locked control
-- is what an admin sees rather than a raw constraint-violation error
-- surfacing on Save — but that UI fix is belt-and-suspenders on top of this
-- constraint, not a substitute for it: the constraint is what actually
-- guarantees the invariant, regardless of which code path writes the row.
--
-- No other Dart change needed: searchAllDimensions/GlobalFilterBar/the
-- Dashboard ranking picker already all gate on
-- drivesCrossFilter/showsOnDashboardTop5 correctly — this was purely a bad
-- VALUE reaching them, not a bug in how they use it, so closing the gap at
-- the one place every one of those reads from fixes all three call sites
-- (and any future one) at once.

update client_dimensions
set
  drives_cross_filter = false,
  shows_on_dashboard_top5 = false
where dimension_key = 'company'
  and (drives_cross_filter or shows_on_dashboard_top5);

alter table client_dimensions
  add constraint client_dimensions_company_never_cross_filters
  check (
    dimension_key <> 'company'
    or (drives_cross_filter = false and shows_on_dashboard_top5 = false)
  );
