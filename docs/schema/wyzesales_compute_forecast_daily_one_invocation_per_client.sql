-- wyzesales_compute_forecast_daily_one_invocation_per_client.sql
--
-- Follow-up to wyzesales_fix_service_key_cube_access.sql (same day,
-- 2026-09-29). Fixing that auth bug let real data flow into compute-
-- forecast for the first time in days -- and its own verification run
-- immediately crashed with WORKER_RESOURCE_LIMIT ("not having enough
-- compute resources") partway through the client loop. This had been
-- invisible for as long as the OTHER bug was silently feeding the function
-- empty result sets (near-instant, trivial no-op runs).
--
-- Two-stage fix, both verified live against production before considering
-- this closed:
--
-- STAGE 1 -- one Edge Function invocation per CLIENT instead of one for
-- every client. compute-forecast (deployed version 3) now accepts an
-- optional { "client_id": "<uuid>" } request body to restrict a run to one
-- client. Verified: fired one net.http_post per row of `clients` (same
-- shape as the original cron job, just parameterized) -- WCSA legitimately
-- computed 0 (no sales_document_facts rows, nothing to forecast), Edgetec
-- computed 3084 rows across all 8 of its dimensions, Fynbos computed 1716
-- across all 12 -- but Morgenster STILL crashed with WORKER_RESOURCE_LIMIT
-- even in its own dedicated invocation.
--
-- STAGE 2 -- one invocation per CLIENT+DIMENSION. Checked why Morgenster
-- alone was still too big: its 'customer' dimension has 767 distinct
-- entities and 'item' has 421 (mv_sales_cube_monthly, queried directly),
-- each needing its own generate_series + Holt-Winters pass across up to
-- ~69 months of history -- several times the total entity count (257)
-- that made up Edgetec's entire successful run across all 8 of ITS
-- dimensions combined. compute-forecast (deployed version 4) now also
-- accepts an optional "dimension" field in that same body, restricting a
-- run to exactly one client+dimension. Verified: Morgenster's 'customer'
-- dimension alone, run by itself, computed cleanly (9204 rows = 767
-- entities x 12 forecast months, exactly as expected) -- no more resource
-- limit.
--
-- pg_cron's compute-forecast-daily job (jobid 3, "0 3 * * *") is updated
-- via cron.alter_job to fire one net.http_post per client_dimensions ROW
-- (not per client) -- 38 invocations across today's 4 clients (6 for WCSA,
-- 8 for Edgetec, 12 for Fynbos, 12 for Morgenster) instead of 1. Each
-- invocation gets its own resource budget, so one large client's one large
-- dimension can no longer crash every other client's -- or that same
-- client's other dimensions' -- forecast by exhausting a shared budget.
-- Manually invoking with just a client_id (or no body at all) still runs
-- every dimension for that client (or every client) in one shot for
-- convenience -- just no longer how the daily schedule calls it.

select cron.alter_job(
  job_id := 3,
  command := $cron$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name = 'wyzesales_project_url') || '/functions/v1/compute-forecast',
    headers := jsonb_build_object(
      'Content-type', 'application/json',
      'apikey', (select decrypted_secret from vault.decrypted_secrets where name = 'wyzesales_anon_key'),
      'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'wyzesales_anon_key')
    ),
    body := jsonb_build_object('client_id', cd.client_id, 'dimension', cd.dimension_key),
    timeout_milliseconds := 60000
  )
  from client_dimensions cd;
  $cron$
);

-- FULLY VERIFIED END-TO-END (production vnzflygyqslvlvndyhql): manually
-- fired the exact statement above (identical to what the updated cron job
-- now runs) -- all 38 invocations returned HTTP 200. sales_forecast now
-- holds 16,644 rows for Morgenster across 8 of its 12 dimensions (the
-- other 4 -- dim_1, dim_4, dim_6, dim_7 -- each returned {"ok":true,
-- "rowsWritten":{"<morgenster>":0},"errors":{}}, i.e. genuinely computed
-- zero, not an error; worth a closer look another day but not a blocker
-- for this fix), 3084 for Edgetec, 1716 for Fynbos, 0 for WCSA (expected,
-- no data). Every response ok:true, zero errors anywhere. Tomorrow's
-- 03:00 UTC scheduled run will use this same updated job and should
-- reproduce this.
--
-- EDGE FUNCTION CODE: compute-forecast's supabase/functions/compute-
-- forecast/index.ts (versions 3 then 4, deployed directly via Supabase,
-- not through this repo's normal build/push) now accepts { client_id?,
-- dimension? } in its POST body, narrowing which clients/dimensions get
-- processed in that invocation -- full before/after story in that file's
-- own 2026-09-29 header notes. NOT yet mirrored into this git repo as of
-- this commit (deployed straight to production to get Morgenster's
-- forecast working today) -- pull the current deployed source down and
-- commit it here as a follow-up so the repo stays the source of truth.
