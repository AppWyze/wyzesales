# WyzeSales Forecast Edge Function — Design Notes

Companion to `schema/003_wyzesales_forecast_series.sql` and `supabase/functions/compute-forecast/index.ts`. This turns the Holt-Winters sketch in `Wyzesales_Forecast_Redesign.md` into real, tested code, and covers what changed going from sketch to implementation, how it's deployed, and a bug caught while testing it.

---

## 1. What's new versus the original sketch

- **Runs for every client, every dimension, every entity** in one invocation — the sketch showed the math for a single series; this loops `clients` → 6 dimensions → every entity with any history, using each client's own `forecast_settings` (or sane defaults if a client hasn't set any).
- **Gap-filling moved into SQL** (`forecast_input_series`, migration 003) rather than being the Edge Function's problem. It hands back a clean, ordered, gap-free monthly series per entity — real zero months included, months before the entity existed excluded — so the JS side is pure math with no date-gap logic to get wrong.
- **Thresholds are read from `forecast_settings`**, not hardcoded 24/12 — matches the "tunable without a redeploy" goal from the original design doc.
- **Fully replaces `sales_forecast` via upsert** on `(client_id, dimension, entity_code, fiscal_month)` every run — safe, since that table is 100% computed.
- **Value-only**, matching the `budget_figures`/`sales_forecast` schema change from the "we only look at Budget" confirmation — no quantity/profit forecasting.

---

## 2. A bug caught while testing this, not while reading it

I ran this end-to-end against a real local Postgres instance (all three migrations applied, seeded test data, not just read through) before calling it done, and that testing caught something the sketch would have gotten wrong: `forecast_input_series` originally filled every month from an entity's first sale all the way to **today's calendar date**. That's wrong — if the daily extract ever stalls for a few days, or a slower-moving entity (a seasonal item, an infrequent customer) simply hasn't sold anything recently, every month since its last real sale would get fabricated as a zero. Holt-Winters would then learn "demand collapsed" from a data gap that has nothing to do with actual demand.

Fixed: the series now ends at each entity's own **last actual sale**, not at today's date. Forecasting projects forward from there instead — in a healthy, current pipeline that's the same thing as "next calendar month" anyway, but it degrades safely instead of lying about demand if the pipeline or an entity goes quiet. Confirmed with a seeded test (14 months of data with a genuine mid-series zero month) that the series now stops exactly at the last real month rather than continuing on to today.

---

## 3. How this was verified

Since this touches real business numbers, I didn't just eyeball the code:

- Installed Postgres locally, ran all three migrations (`001`, `002`, `003`) against a clean database end to end — all tables, views, functions, and RLS policies apply without error.
- Seeded realistic test data: a customer with 14 months of history including one genuine zero-sales month in the middle, going through the rep-override path (`attribute_to_assigned_rep`) so `v_sales_documents` had to actually do the override resolution, not just pass data through.
- Queried `v_sales_documents`, `v_dimension_monthly_sales`, and `v_dimension_performance` directly and confirmed: rep/branch resolution honors the override correctly, the mid-series zero month is preserved as a real zero (not silently dropped), and the budget/target/%Contribution/%GP numbers compute correctly, including two different fiscal years correctly sharing one non-year-scoped budget target.
- Type-checked the Edge Function's TypeScript with the compiler directly (catches the class of mistake that got past me on the WyzeSalesExtract `.csproj` before — not repeating that gap here).
- Extracted the Holt-Winters function and ran it standalone in Node against: empty history (correctly returns "nothing to forecast"), short history (correctly falls back to the low-confidence trend tier), and a clean 24-month synthetic series with a known seasonal pattern and a known trend (correctly reconstructed both).
- Ran the full pipeline — real seeded Postgres data through `forecast_input_series`, straight into the Holt-Winters function — and got a sane 12-month forecast reflecting both the upward trend and the seasonal dip from the test data's zero month.

---

## 4. Deployment (updated 2026-09-04)

**2026-09-04 update, before this was ever actually deployed**: this function originally read `Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")` directly. That key no longer exists at all — Section 59 of the Decisions doc had all 4 other full-access functions moved onto a new `wyzesales_edge` secret key months ago, then Craig fully deleted the legacy key once they were confirmed working. Deploying this function unchanged would have authenticated with nothing and failed outright on its first real run. Fixed by switching it onto the same `getServiceKey()` helper (`_shared/service_key.ts`) the other 4 already use — no other code change needed, same as when those 4 were migrated.

That surfaced the same class of gap Section 59 found for those 4 functions: the `wyzesales_edge` key's underlying `service_role` doesn't automatically carry the same standing table GRANTs the old key always had. Reproduced and fixed against a scratch Postgres before sending this (unlike Section 59's fix, which was found live from Postgres's own error hint) — see `032_wyzesales_compute_forecast_grants.sql`. **Run migration `032` before deploying**, in addition to `001`–`003` if this is the first time any of the forecast schema has gone in.

```
supabase functions deploy compute-forecast
```

No manual secret needed beyond what the other 4 functions already require (`SUPABASE_URL` is auto-injected; the `wyzesales_edge` secret key is already configured project-wide since Section 59).

**Scheduling**: once daily, shortly after the morning extract lands (e.g. 05:00, an hour after the 04:00 `WyzeSalesExtract` run). The original sketch of this (below, kept for reference) called `net.http_post(...)` from a `cron.schedule(...)` SQL statement with the service-role key typed directly into the `Authorization` header — worth NOT doing that verbatim now that Section 59 exists: `pg_cron`'s job definitions are stored in a plain table (`cron.job`) readable by anyone with DB access, so pasting a full-access key straight into it would recreate the exact class of exposure Section 59 just spent real effort cleaning up, just in a new place.

**Recommended instead**: Supabase's dashboard now has a native "Cron Jobs" section (Database → Cron Jobs → Create a new cron job → type "Supabase Edge Function") that schedules the call and manages the Authorization header itself via Vault, rather than it ever appearing in plain SQL. Point it at `compute-forecast`, schedule `0 5 * * *`, and it handles the rest — nothing to fill in here since it's driven by the dashboard, not a SQL snippet. If that option isn't available on your plan/version, the fallback is `cron.schedule(...)` with the header pulled from `vault.decrypted_secrets` by name rather than typed in literally — happy to write that exact variant if the dashboard option turns out not to be there.

```sql
-- Reference only — the original sketch, superseded by the guidance above.
select cron.schedule(
  'compute-forecast-daily',
  '0 5 * * *',
  $$
  select net.http_post(
    url := 'https://uxyqthscnlznrjpyogwg.supabase.co/functions/v1/compute-forecast',
    headers := jsonb_build_object('Authorization', 'Bearer <service-role-key>')
  );
  $$
);
```

---

## 5. What's still open

- **Backtesting against real historical data** (Section 6 of the original design doc) — not actually blocked on a historical migration (Section 1 confirmed one was never needed), but on real production data existing at all: `wyzesales-staging` is still the only Supabase project, holding only test/seed data (see Decisions doc Section 43). Naturally lines up with the production-cutover step already on the roadmap, not something to chase separately before then.
- ~~Company-level dimension (`'company'`, entity code `'ALL'`) — worth confirming actually wanted~~ **Resolved 2026-09-02**: Decisions doc Section 57 added Company as a 6th dimension across Sales By/Budgets/Performance — it's a real, used dimension, not dead weight.
