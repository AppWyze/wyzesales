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
// Schedule: Supabase Cron, once daily, after the morning extract lands and
//           WyzeSalesExtract has loaded the day's sales_document_facts —
//           e.g. 05:00, an hour after the 04:00 extract run. See the design
//           notes doc for the exact `cron.schedule(...)` call.
//
// Depends on: forecast_input_series() (003_wyzesales_forecast_series.sql),
// which returns a clean, gap-free monthly series per entity — genuine zero
// months included, pre-existence months excluded. This function does no
// gap-filling itself; it trusts that series as-is.
//
// 2026-09-04: uses getServiceKey() (_shared/service_key.ts), same as the
// other 4 full-access functions — the legacy SUPABASE_SERVICE_ROLE_KEY this
// function originally read was fully deleted from the project in Section 59,
// so reading it directly would authenticate with nothing at all. Needs the
// same "wyzesales_edge" secret key those 4 functions use, plus its own
// GRANTs (032_wyzesales_compute_forecast_grants.sql) — that key's role does
// not automatically inherit table/function privileges the way the old
// service_role key did (see Section 59's own postscript for that gap on
// profiles/clients/license/pricing_plan; this migration is the same fix for
// the tables/function this function touches instead).

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { getServiceKey } from "../_shared/service_key.ts";

const DIMENSIONS = ["sales_person", "customer", "item", "category", "branch", "company"];
const MONTH_NAMES = [
  "Jan", "Feb", "Mar", "Apr", "May", "Jun",
  "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
];

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

/**
 * monthlyHistory: oldest -> newest, one entry per calendar month, no gaps
 * (guaranteed by forecast_input_series). startMonthIndex: 0=Jan..11=Dec,
 * the calendar month of monthlyHistory[0].
 */
function holtWintersForecast(
  monthlyHistory: number[],
  startMonthIndex: number,
  settings: ForecastSettings,
): ForecastResult | null {
  const n = monthlyHistory.length;
  const PERIOD = 12;
  if (n === 0) return null;

  const monthAt = (offsetFromStart: number) => MONTH_NAMES[(startMonthIndex + offsetFromStart) % 12];

  // Tier 3: not enough history to trust a seasonal pattern - straight
  // recent-trend projection, flat across all 12 forecast months.
  if (n < settings.partial_history_months) {
    const recent = monthlyHistory.slice(-Math.min(3, n));
    const avg = recent.reduce((a, b) => a + b, 0) / recent.length;
    const forecastByMonth: Record<string, number> = {};
    for (let h = 0; h < 12; h++) forecastByMonth[monthAt(n + h)] = Math.max(0, avg);
    return { forecastByMonth, confidence: "low" };
  }

  // Tiers 1 & 2: full Holt-Winters. Initialize from however many full years
  // of history are available (1 year -> flat trend/no cross-year seasonal
  // averaging; 2+ years -> real trend and averaged seasonal ratios).
  const years = Math.floor(n / PERIOD);
  const yearAverages = Array.from({ length: years }, (_, y) => {
    const slice = monthlyHistory.slice(y * PERIOD, (y + 1) * PERIOD);
    return slice.reduce((a, b) => a + b, 0) / PERIOD;
  });

  let level = yearAverages[0];
  let trend = years >= 2 ? (yearAverages[1] - yearAverages[0]) / PERIOD : 0;

  const seasonal = Array.from({ length: PERIOD }, (_, m) => {
    const ratios = Array.from({ length: years }, (_, y) => {
      const denom = yearAverages[y] === 0 ? 1 : yearAverages[y];
      return monthlyHistory[y * PERIOD + m] / denom;
    });
    return ratios.reduce((a, b) => a + b, 0) / ratios.length;
  });
  const seasonalMean = seasonal.reduce((a, b) => a + b, 0) / PERIOD || 1;
  for (let i = 0; i < PERIOD; i++) seasonal[i] /= seasonalMean;

  // Recursive updates across ALL available history (not just whole years) -
  // this is what lets a trailing partial year still sharpen the estimate.
  for (let t = 0; t < n; t++) {
    const s = seasonal[t % PERIOD] || 1;
    const prevLevel = level;
    level = settings.alpha * (monthlyHistory[t] / s) + (1 - settings.alpha) * (level + trend);
    trend = settings.beta * (level - prevLevel) + (1 - settings.beta) * trend;
    seasonal[t % PERIOD] = settings.gamma * (monthlyHistory[t] / (level || 1)) + (1 - settings.gamma) * s;
  }

  const forecastByMonth: Record<string, number> = {};
  for (let h = 0; h < 12; h++) {
    const value = Math.max(0, (level + (h + 1) * trend) * seasonal[(n + h) % PERIOD]);
    forecastByMonth[monthAt(n + h)] = value;
  }

  return {
    forecastByMonth,
    confidence: n >= settings.full_history_months ? "full" : "partial",
  };
}

Deno.serve(async (_req) => {
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    getServiceKey(),
  );

  const { data: clients, error: clientsError } = await supabase.from("clients").select("id");
  if (clientsError) {
    return new Response(JSON.stringify({ ok: false, error: clientsError.message }), { status: 500 });
  }

  const rowsWrittenByClient: Record<string, number> = {};

  for (const client of clients ?? []) {
    const clientId = client.id as string;

    const { data: settingsRow } = await supabase
      .from("forecast_settings")
      .select("alpha, beta, gamma, full_history_months, partial_history_months")
      .eq("client_id", clientId)
      .maybeSingle();

    const settings: ForecastSettings = settingsRow ?? DEFAULT_SETTINGS;

    const rowsToUpsert: Array<{
      client_id: string;
      dimension: string;
      entity_code: string;
      fiscal_month: string;
      forecast_value: number;
      confidence: Confidence;
      computed_at: string;
    }> = [];
    const runTimestamp = new Date().toISOString();

    for (const dimension of DIMENSIONS) {
      const { data: series, error: seriesError } = await supabase.rpc("forecast_input_series", {
        p_client_id: clientId,
        p_dimension: dimension,
      });

      if (seriesError) {
        console.error(`[${clientId}/${dimension}] forecast_input_series failed:`, seriesError.message);
        continue;
      }

      // forecast_input_series returns flat (entity_code, month, value) rows,
      // already ordered oldest -> newest per entity - group them back into
      // one array per entity.
      const byEntity = new Map<string, { month: string; value: number }[]>();
      for (const row of (series ?? []) as { entity_code: string; month: string; value: number }[]) {
        const list = byEntity.get(row.entity_code) ?? [];
        list.push({ month: row.month, value: row.value });
        byEntity.set(row.entity_code, list);
      }

      for (const [entityCode, points] of byEntity) {
        const history = points.map((p) => p.value);
        const startMonthIndex = new Date(points[0].month).getUTCMonth();
        const result = holtWintersForecast(history, startMonthIndex, settings);
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
    }

    if (rowsToUpsert.length > 0) {
      const { error: upsertError } = await supabase
        .from("sales_forecast")
        .upsert(rowsToUpsert, { onConflict: "client_id,dimension,entity_code,fiscal_month" });

      if (upsertError) {
        console.error(`[${clientId}] sales_forecast upsert failed:`, upsertError.message);
      }
    }

    rowsWrittenByClient[clientId] = rowsToUpsert.length;
  }

  return new Response(JSON.stringify({ ok: true, rowsWritten: rowsWrittenByClient }), {
    headers: { "Content-Type": "application/json" },
  });
});
