// compute-forecast — Supabase Edge Function
//
// Computes the next-12-month sales VALUE forecast for every dimension/entity
// combination, for every client, using multiplicative Holt-Winters triple
// exponential smoothing (design: Wyzesales_Forecast_Redesign.md). Fully
// replaces the relevant sales_forecast rows on every run — safe to do,
// because sales_forecast is 100% computed, never user-entered (unlike
// budget_figures, which this function never touches).
//
// Deploy:   supabase functions deploy compute-forecast
// Schedule: fn_forecast_enqueue() (03:00 UTC) fills forecast_dispatch_queue and
//           fn_forecast_dispatch() (every minute 03:00-06:59 UTC) sends a few
//           chunks per minute to this function. fn_forecast_reconcile_ready()
//           then scales every dimension's entity forecasts so they sum to the
//           company forecast. See docs/schema/forecast_dispatch.sql.
//
// Depends on: forecast_input_series() (003_wyzesales_forecast_series.sql) and
// its chunked wrapper forecast_input_series_chunk(), which return a clean,
// monthly series per entity — genuine zero months included, pre-existence
// months excluded. The series only ever extends to the entity's OWN last real
// month (Fix #6); this function appends the trailing zero months itself (Fix #9).
//
// 2026-10-08 (v14) — #12 SEASONAL RATIOS ARE CAPPED. Edgetec (project-based,
//   lumpy: one R80m month in Jan 2025 against a typical R7m) was forecast
//   R59m for next January because that one spike became a seasonal index of
//   ~7x. A month's seasonal ratio (month value / that year's typical value) is
//   now capped at SEASONAL_RATIO_CAP (3x) both when seeded and when updated.
//   Edgetec company: R205m -> R174m a year (last 12 months R124m, prior 12
//   months R190m). No effect on steady businesses (WCSA company identical).
//
// 2026-10-08 (v13) — THREE MORE FIXES, found validating v12 on WCSA (company
// forecast now R153m vs R158m actual, but customer/item still summed to 1.45x
// the company figure):
//
//   9. ENTITIES THAT STOPPED BUYING WERE FORECAST AS IF THEY WERE STILL ACTIVE.
//      The series ends at the entity's last real month, so a customer whose
//      last purchase was 8 months ago was projected from a level that had not
//      decayed (e.g. TPG8179: last bought Nov 2025, R44k in the last 12
//      months, forecast R455k). The complete months between the entity's last
//      real month and last month are now appended as genuine zero months for
//      the Holt-Winters tiers, so the level decays the way it should.
//      (Dormancy at >= 12 idle months is unchanged: flat zero.)
//
//  10. SPARSE / INTERMITTENT ENTITIES BLEW UP THE SEASONAL MATHS. When more
//      than half the history months are zero, the year's MEDIAN is 0, so the
//      level started at 0 and the seasonal ratios divided by a made-up 1 —
//      e.g. GEC001 (R133k in the last 12 months) forecast at R2.26m. Now: an
//      entity that traded in fewer than half of its history months is forecast
//      flat at its trailing-12-month average (confidence "low"), and where a
//      year's median is 0 the year's mean is used for the seasonal base.
//
//  11. TIER 3 DENOMINATOR FLOOR 6 -> 9. Back-test on WCSA customers (history
//      under 12 months at three cut-off dates; actual next-12-month sales vs
//      history total): span 1-3 months 1.25x, 4-6 months 1.09x, 7-11 months
//      1.28x of history. Floor 9 gives 1.33x for new customers and ~1.1-1.3x
//      for 7-11 months: a close match (the floor of 6 gave 2.0x).
//
// 2026-10-08 (v12): #7 the current, incomplete calendar month is excluded from
//   the history (company forecast R99.8m with it, R153.3m without, WCSA); #8 new
//   Tier 3 formula (total over last up-to-12 complete months / months since
//   first purchase, flat for 12 months) instead of repeating the last 1-3 months.
//   Every dimension is then reconciled to the company forecast in SQL
//   (fn_forecast_reconcile).
//
// 2026-10-08 (earlier, v11): silent failures + WCSA never forecasting.
//   (a) pg_net only sends an HTTP request when the calling transaction
//       commits, so the old cron job's pg_sleep(1.5) between posts spaced
//       nothing out. (b) a failed series read was only console.error'd; now
//       surfaced in `errors` (HTTP 207). (c) WCSA customer/item exceed one
//       worker's resource limit; the body now also accepts { chunk, chunks }.
//       Upserts are batched (2,000 rows).
//
// 2026-09-29: optional JSON body { client_id, dimension } to restrict a run.
// 2026-09-29 (WORKER_RESOURCE_LIMIT): one invocation per client+dimension.
// 2026-09-04: uses getServiceKey() (_shared/service_key.ts) — the legacy
// SUPABASE_SERVICE_ROLE_KEY was deleted; "wyzesales_edge" secret key + GRANTs
// (032_wyzesales_compute_forecast_grants.sql).
//
// 2026-09-21: robustness fixes #1-#3 (median year seeds; symmetric cap/floor;
// damped trend). 2026-09-30: #4 history window = most recent
// `full_history_months`; #5 tighter of peak-relative and median-relative cap;
// #6 dormancy (no activity for >= `partial_history_months` => flat zero).

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { getServiceKey } from "../_shared/service_key.ts";

const MONTH_NAMES = [
  "Jan", "Feb", "Mar", "Apr", "May", "Jun",
  "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
];

// Standard damped-trend factor (Fix #3). Numeric-robustness constant.
const TREND_DAMPING = 0.90;

// Fix #5: how far above/below the entity's own MEDIAN non-zero month the
// deseasonalized cap/floor may reach; the tighter of this and the 1.5x-peak
// bound wins.
const MEDIAN_CAP_MULTIPLE = 5;

// Fix #12: a single month's seasonal ratio (value / that year's typical
// value) may not exceed this multiple, so one project-sized spike cannot
// become a permanent seasonal peak.
const SEASONAL_RATIO_CAP = 3;

// Fix #8/#11: Tier 3 averaging denominator bounds (months).
const TIER3_MIN_DENOMINATOR = 9;
const TIER3_MAX_DENOMINATOR = 12;

// Fix #10: an entity that traded in fewer than this share of its history
// months is "intermittent" and is forecast flat instead of seasonally.
const INTERMITTENT_MIN_ACTIVE_SHARE = 0.5;

// Rows per sales_forecast upsert request.
const UPSERT_BATCH_SIZE = 2000;

type Confidence = "full" | "partial" | "low";

interface ForecastSettings {
  alpha: number;
  beta: number;
  gamma: number;
  full_history_months: number;
  partial_history_months: number;
}

interface ForecastResult {
  forecastByMonth: Record<string, number>; // 'Jan'..'Dec' -> forecast value
  confidence: Confidence;
}

const DEFAULT_SETTINGS: ForecastSettings = {
  alpha: 0.3,
  beta: 0.1,
  gamma: 0.3,
  full_history_months: 24,
  partial_history_months: 12,
};

// Median of a numeric array (Fix #1).
function median(values: number[]): number {
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 0
    ? (sorted[mid - 1] + sorted[mid]) / 2
    : sorted[mid];
}

// Damped-trend cumulative contribution over `steps` months ahead (Fix #3).
function dampedTrendContribution(trend: number, phi: number, steps: number): number {
  if (phi >= 1) return trend * steps; // undamped fallback; TREND_DAMPING never actually reaches this
  return (trend * phi * (1 - Math.pow(phi, steps))) / (1 - phi);
}

// Fix #12: clamp a seasonal ratio to [0, SEASONAL_RATIO_CAP].
function clampSeasonalRatio(ratio: number): number {
  return Math.max(0, Math.min(ratio, SEASONAL_RATIO_CAP));
}

/**
 * tier3 = true: monthlyHistory is the entity's REAL complete months (first
 * purchase -> last real month), trailingZeroMonths the complete months since.
 * tier3 = false: monthlyHistory is oldest -> newest COMPLETE calendar months
 * INCLUDING appended trailing zeros (Fix #9), already truncated by the caller
 * to at most `full_history_months` (Fix #4), ending at last month.
 * startMonthIndex: 0=Jan..11=Dec, the calendar month of monthlyHistory[0].
 * monthsSinceLastActivity: months between the entity's own last REAL month
 * (including the current month, if it traded in it) and today (Fix #6).
 */
function holtWintersForecast(
  monthlyHistory: number[],
  startMonthIndex: number,
  settings: ForecastSettings,
  monthsSinceLastActivity: number,
  trailingZeroMonths: number,
  tier3: boolean,
): ForecastResult | null {
  const n = monthlyHistory.length;
  const PERIOD = 12;
  if (n === 0) return null;

  const monthAt = (offsetFromStart: number) => MONTH_NAMES[(startMonthIndex + offsetFromStart) % 12];
  const flat = (monthly: number): Record<string, number> => {
    const out: Record<string, number> = {};
    for (let h = 0; h < 12; h++) out[monthAt(n + h)] = monthly;
    return out;
  };

  // Fix #6: no real trading activity in at least `partial_history_months`
  // months => flat zero, "low" confidence. Takes priority over everything.
  if (monthsSinceLastActivity >= settings.partial_history_months) {
    return { forecastByMonth: flat(0), confidence: "low" };
  }

  // Tier 3 (Fix #8, #11): not enough history to trust a seasonal pattern.
  // The entity's total over the last up-to-12 complete months, divided by the
  // months since its first purchase (floored at TIER3_MIN_DENOMINATOR, capped
  // at TIER3_MAX_DENOMINATOR), spread flat across the 12 forecast months.
  if (tier3) {
    const observedMonths = n + trailingZeroMonths; // first purchase -> last complete month
    const windowStart = Math.max(0, n - Math.max(0, TIER3_MAX_DENOMINATOR - trailingZeroMonths));
    const total = monthlyHistory.slice(windowStart).reduce((a, b) => a + b, 0);
    const denominator = Math.min(TIER3_MAX_DENOMINATOR, Math.max(TIER3_MIN_DENOMINATOR, observedMonths));
    return { forecastByMonth: flat(Math.max(0, total / denominator)), confidence: "low" };
  }

  // Fix #10: intermittent entity (traded in under half its history months):
  // flat at the trailing-12-month average; seasonal maths is meaningless.
  const activeMonths = monthlyHistory.filter((v) => v !== 0).length;
  if (activeMonths < n * INTERMITTENT_MIN_ACTIVE_SHARE) {
    const last12 = monthlyHistory.slice(Math.max(0, n - 12));
    const monthly = Math.max(0, last12.reduce((a, b) => a + b, 0) / last12.length);
    return { forecastByMonth: flat(monthly), confidence: "low" };
  }

  // Tiers 1 & 2: full Holt-Winters. Initialize from however many full years
  // of history are available (1 year -> flat trend/no cross-year seasonal
  // averaging; 2+ years -> real trend and averaged seasonal ratios).
  //
  // Fix #1: each year's "typical value" is its MEDIAN, not its mean (Fix #10:
  // or its mean when the median is 0).
  const years = Math.floor(n / PERIOD);
  const yearTypicalValues = Array.from({ length: years }, (_, y) => {
    const slice = monthlyHistory.slice(y * PERIOD, (y + 1) * PERIOD);
    const med = median(slice);
    return med !== 0 ? med : slice.reduce((a, b) => a + b, 0) / slice.length;
  });

  let level = yearTypicalValues[0];
  let trend = years >= 2 ? (yearTypicalValues[1] - yearTypicalValues[0]) / PERIOD : 0;

  const seasonal = Array.from({ length: PERIOD }, (_, m) => {
    const ratios = Array.from({ length: years }, (_, y) => {
      const denom = yearTypicalValues[y] === 0 ? 1 : yearTypicalValues[y];
      return clampSeasonalRatio(monthlyHistory[y * PERIOD + m] / denom); // Fix #12
    });
    return ratios.reduce((a, b) => a + b, 0) / ratios.length;
  });
  const seasonalMean = seasonal.reduce((a, b) => a + b, 0) / PERIOD || 1;
  for (let i = 0; i < PERIOD; i++) seasonal[i] /= seasonalMean;

  // 2026-09-04: cap the deseasonalized value fed into the level/trend update
  // at 1.5x this entity's own highest ACTUAL month. Fix #2 added the symmetric
  // floor; Fix #5 added the median-relative bounds (tighter of the two wins).
  // `nonZeroMonths` excludes 0s so a run of zeros can't drag the typical
  // month to 0 for an intermittent entity.
  const maxActual = Math.max(...monthlyHistory, 0);
  const peakCap = maxActual * 1.5;
  const minActual = Math.min(...monthlyHistory, 0);
  const peakFloor = minActual * 1.5;
  const nonZeroMonths = monthlyHistory.filter((v) => v !== 0);
  const typicalMonth = nonZeroMonths.length > 0 ? median(nonZeroMonths) : 0;
  const medianCap = typicalMonth > 0 ? typicalMonth * MEDIAN_CAP_MULTIPLE : Infinity;
  const medianFloor = typicalMonth < 0 ? typicalMonth * MEDIAN_CAP_MULTIPLE : -Infinity;
  const deseasonalizedCap = Math.min(peakCap, medianCap);
  const deseasonalizedFloor = Math.max(peakFloor, medianFloor);

  // Recursive updates across ALL available history (not just whole years).
  for (let t = 0; t < n; t++) {
    const s = seasonal[t % PERIOD] || 1;
    const prevLevel = level;
    const deseasonalized = Math.max(deseasonalizedFloor, Math.min(monthlyHistory[t] / s, deseasonalizedCap));
    // Fix #3: one-step-ahead expectation is level + a DAMPED 1-step trend.
    level = settings.alpha * deseasonalized + (1 - settings.alpha) * (level + dampedTrendContribution(trend, TREND_DAMPING, 1));
    trend = settings.beta * (level - prevLevel) + (1 - settings.beta) * trend;
    seasonal[t % PERIOD] = settings.gamma * clampSeasonalRatio(monthlyHistory[t] / (level || 1)) + (1 - settings.gamma) * s; // Fix #12
  }

  const forecastByMonth: Record<string, number> = {};
  for (let h = 0; h < 12; h++) {
    // Fix #3: damped multi-step trend contribution.
    const value = Math.max(0, (level + dampedTrendContribution(trend, TREND_DAMPING, h + 1)) * seasonal[(n + h) % PERIOD]);
    forecastByMonth[monthAt(n + h)] = value;
  }

  return {
    forecastByMonth,
    confidence: n >= settings.full_history_months ? "full" : "partial",
  };
}

// Supabase's project-wide "Max Rows" (PostgREST db-max-rows, 1000) silently
// TRUNCATES any single response, so this paginates via .range(); safe because
// the series function's own `order by entity_code, month` is stable.
// Reads through forecast_input_series_chunk() so a large dimension can be
// fetched and forecast one ~500-entity chunk at a time (chunks <= 1 = every
// entity).
async function fetchAllInputSeries(
  supabase: ReturnType<typeof createClient>,
  clientId: string,
  dimension: string,
  chunk: number,
  chunks: number,
): Promise<{
  data: { entity_code: string; month: string; value: number }[] | null;
  error: { message: string } | null;
}> {
  const pageSize = 1000;
  const allRows: { entity_code: string; month: string; value: number }[] = [];
  let from = 0;
  while (true) {
    const { data, error } = await supabase
      .rpc("forecast_input_series_chunk", {
        p_client_id: clientId,
        p_dimension: dimension,
        p_chunk: chunk,
        p_chunks: chunks,
      })
      .range(from, from + pageSize - 1);
    if (error) return { data: null, error };
    const page = (data ?? []) as { entity_code: string; month: string; value: number }[];
    allRows.push(...page);
    if (page.length < pageSize) break; // short page = that was the last one
    from += pageSize;
  }
  return { data: allRows, error: null };
}

Deno.serve(async (req) => {
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    getServiceKey(),
  );

  // Optional { client_id, dimension, chunk, chunks } body (see header notes).
  let requestedClientId: string | null = null;
  let requestedDimension: string | null = null;
  let requestedChunk = 0;
  let requestedChunks = 1;
  try {
    const body = await req.json();
    if (body && typeof body.client_id === "string" && body.client_id.length > 0) {
      requestedClientId = body.client_id;
    }
    if (body && typeof body.dimension === "string" && body.dimension.length > 0) {
      requestedDimension = body.dimension;
    }
    if (
      body &&
      Number.isInteger(body.chunks) && body.chunks > 1 &&
      Number.isInteger(body.chunk) && body.chunk >= 0 && body.chunk < body.chunks
    ) {
      requestedChunks = body.chunks;
      requestedChunk = body.chunk;
    }
  } catch {
    // No body, or not valid JSON — treat as "every client".
  }

  let clientsQuery = supabase.from("clients").select("id");
  if (requestedClientId) {
    clientsQuery = clientsQuery.eq("id", requestedClientId);
  }
  const { data: clients, error: clientsError } = await clientsQuery;
  if (clientsError) {
    return new Response(JSON.stringify({ ok: false, error: clientsError.message }), { status: 500 });
  }

  const rowsWrittenByClient: Record<string, number> = {};
  const errorsByClient: Record<string, string> = {};

  // Fix #7: the first day of the current (incomplete) calendar month, UTC.
  const nowUtc = new Date();
  const currentMonthStartMs = Date.UTC(nowUtc.getUTCFullYear(), nowUtc.getUTCMonth(), 1);
  const currentMonthIndex = nowUtc.getUTCFullYear() * 12 + nowUtc.getUTCMonth();

  for (const client of clients ?? []) {
    const clientId = client.id as string;

    const { data: settingsRow } = await supabase
      .from("forecast_settings")
      .select("alpha, beta, gamma, full_history_months, partial_history_months")
      .eq("client_id", clientId)
      .maybeSingle();

    const settings: ForecastSettings = settingsRow ?? DEFAULT_SETTINGS;

    // Dimensions come from this client's own `client_dimensions` rows.
    const { data: dimensionRows, error: dimensionsError } = await supabase
      .from("client_dimensions")
      .select("dimension_key")
      .eq("client_id", clientId);
    if (dimensionsError) {
      console.error(`[${clientId}] client_dimensions read failed:`, dimensionsError.message);
      errorsByClient[`${clientId}/client_dimensions`] = dimensionsError.message;
      continue;
    }
    let dimensions = (dimensionRows ?? []).map((d) => d.dimension_key as string);
    if (requestedDimension) {
      dimensions = dimensions.filter((d) => d === requestedDimension);
    }

    const runTimestamp = new Date().toISOString();
    let clientRowsWritten = 0;
    let clientHadWork = false;

    // Dimensions are processed (and upserted) one at a time, so one failed
    // dimension no longer loses the others and memory stays bounded.
    for (const dimension of dimensions) {
      const errKey = `${clientId}/${dimension}#${requestedChunk}`;
      const { data: series, error: seriesError } = await fetchAllInputSeries(
        supabase, clientId, dimension, requestedChunk, requestedChunks,
      );

      if (seriesError) {
        console.error(`[${clientId}/${dimension}] forecast_input_series failed:`, seriesError.message);
        errorsByClient[errKey] = seriesError.message;
        continue;
      }

      // Group the flat (entity_code, month, value) rows back into one array
      // per entity, oldest -> newest.
      const byEntity = new Map<string, { month: string; value: number }[]>();
      for (const row of (series ?? []) as { entity_code: string; month: string; value: number }[]) {
        const list = byEntity.get(row.entity_code) ?? [];
        list.push({ month: row.month, value: row.value });
        byEntity.set(row.entity_code, list);
      }

      if (byEntity.size === 0) {
        errorsByClient[errKey] = "no input series returned";
        continue;
      }

      const rowsToUpsert: Array<{
        client_id: string;
        dimension: string;
        entity_code: string;
        fiscal_month: string;
        forecast_value: number;
        confidence: Confidence;
        computed_at: string;
      }> = [];

      for (const [entityCode, points] of byEntity) {
        // Fix #6: months since this entity's own last REAL month, from the FULL
        // (untruncated, current-month-inclusive) series.
        const lastActivityMonth = new Date(points[points.length - 1].month);
        const monthsSinceLastActivity =
          (nowUtc.getUTCFullYear() - lastActivityMonth.getUTCFullYear()) * 12 +
          (nowUtc.getUTCMonth() - lastActivityMonth.getUTCMonth());

        // Fix #7: only COMPLETE calendar months feed the maths.
        const completePoints = points.filter((p) => new Date(p.month).getTime() < currentMonthStartMs);
        if (completePoints.length === 0) continue; // first ever activity is this month — nothing complete to forecast from yet

        const realValues = completePoints.map((p) => p.value);
        const firstMonth = new Date(completePoints[0].month);
        const firstIndex = firstMonth.getUTCFullYear() * 12 + firstMonth.getUTCMonth();
        const lastRealMonth = new Date(completePoints[completePoints.length - 1].month);
        const lastRealIndex = lastRealMonth.getUTCFullYear() * 12 + lastRealMonth.getUTCMonth();

        // Fix #9: complete months between the entity's last real month and the
        // last complete calendar month — genuine zero months.
        const trailingZeroMonths = Math.max(0, currentMonthIndex - 1 - lastRealIndex);

        // Fix #8: Tier 3 = under `partial_history_months` months from first
        // purchase to last complete month.
        const spanMonths = realValues.length + trailingZeroMonths;
        const tier3 = spanMonths < settings.partial_history_months;

        let history: number[];
        let startMonthIndex: number;
        if (tier3) {
          history = realValues;
          startMonthIndex = firstIndex % 12;
        } else {
          // Extend with the trailing zeros (Fix #9), then Fix #4: keep the most
          // recent `full_history_months` months.
          const extended = trailingZeroMonths > 0 ? realValues.concat(new Array(trailingZeroMonths).fill(0)) : realValues;
          const cap = settings.full_history_months;
          const dropped = extended.length > cap ? extended.length - cap : 0;
          history = dropped > 0 ? extended.slice(dropped) : extended;
          startMonthIndex = (firstIndex + dropped) % 12;
        }

        const result = holtWintersForecast(
          history, startMonthIndex, settings, monthsSinceLastActivity, trailingZeroMonths, tier3,
        );
        if (!result) continue;

        for (const [fiscalMonth, forecastValue] of Object.entries(result.forecastByMonth)) {
          rowsToUpsert.push({
            client_id: clientId,
            dimension,
            entity_code: entityCode,
            fiscal_month: fiscalMonth,
            forecast_value: Math.round(forecastValue * 100) / 100,
            confidence: result.confidence,
            computed_at: runTimestamp,
          });
        }
      }

      // Only report a count once the upsert has actually succeeded; batches of
      // UPSERT_BATCH_SIZE rows.
      let dimensionOk = true;
      for (let i = 0; i < rowsToUpsert.length; i += UPSERT_BATCH_SIZE) {
        const { error: upsertError } = await supabase
          .from("sales_forecast")
          .upsert(rowsToUpsert.slice(i, i + UPSERT_BATCH_SIZE), {
            onConflict: "client_id,dimension,entity_code,fiscal_month",
          });
        if (upsertError) {
          console.error(`[${clientId}/${dimension}] sales_forecast upsert failed:`, upsertError.message);
          errorsByClient[errKey] = upsertError.message;
          dimensionOk = false;
          break;
        }
      }
      if (dimensionOk) {
        clientRowsWritten += rowsToUpsert.length;
        clientHadWork = true;
      }
    }

    if (clientHadWork) rowsWrittenByClient[clientId] = clientRowsWritten;
  }

  const ok = Object.keys(errorsByClient).length === 0;
  return new Response(JSON.stringify({ ok, rowsWritten: rowsWrittenByClient, errors: errorsByClient }), {
    status: ok ? 200 : 207,
    headers: { "Content-Type": "application/json" },
  });
});
