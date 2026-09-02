-- ============================================================================
-- WyzeSales — budget_figures UPDATE policy (Supabase / Postgres)
-- ============================================================================
-- Fourth migration. Found while building the Flutter app's budget-editing
-- screen, not previously flagged: schema/001 Section 10 gave budget_figures
-- an INSERT policy (budget_figures_write) but no UPDATE policy. Postgres RLS
-- checks an UPSERT's "update an existing row" path against UPDATE policies,
-- not INSERT ones — so with only an INSERT policy in place, an adminuser or
-- superuser could set a month's budget for the first time, but editing that
-- same month again later would be silently blocked by RLS (the request
-- succeeds with 0 rows affected, no error, which is a confusing thing to
-- debug from the app side). Since the whole point of the Budgets screen is
-- editing the same 12 months repeatedly as the year goes on, this needed
-- catching before it reached you as "my edit didn't save and nothing told
-- me why."
--
-- Same access rule as the existing INSERT policy — adminuser/superuser only,
-- scoped to their own client_id — just extended to cover updates too.
-- ============================================================================

create policy budget_figures_update on budget_figures
for update using (
  exists (select 1 from profiles p where p.id = auth.uid()
          and p.client_id = budget_figures.client_id and p.level in ('adminuser','superuser'))
)
with check (
  exists (select 1 from profiles p where p.id = auth.uid()
          and p.client_id = budget_figures.client_id and p.level in ('adminuser','superuser'))
);
