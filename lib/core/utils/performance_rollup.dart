import '../../data/models/dimension_performance.dart';

/// Collapses possibly-several-per-entity rows (one per fiscal year that
/// had data for the filtered month) into one row per entity, the shape
/// every other part of the Performance screen assumes. The additive ACTUAL
/// measures (actualValue/actualQuantity/actualProfit) are summed across
/// years the same way the screen's own totals row sums them across entities
/// — `gpPercent` is recomputed from the summed Rand figures rather than
/// averaged, the same "a ratio of ratios isn't the right ratio" reasoning
/// that applies to %Target/%GP everywhere else in this app.
///
/// 2026-09-01: extracted out of `performance_screen.dart`'s private
/// `_mergeAcrossYears` (unchanged logic — this is a pure, behaviour-preserving
/// move, not a rewrite) so it can be unit-tested directly (task #92,
/// "targeted regression tests around the fiscal-year/rollup logic") without
/// needing a `State` instance, a `BuildContext`, or any Supabase/Riverpod
/// wiring — every input this function needs is a plain `DimensionPerformance`
/// list plus the caller's current fiscal year.
///
/// `targetValue` — this formula went through three attempts before landing
/// here, each caught by Craig testing rather than by review, and this final
/// version is a design he explicitly confirmed before it was built
/// (2026-09-01), not something decided unilaterally. See
/// Wyzesales_Rebuild_Decisions.md Section 52 for the full history; summarized
/// for future maintainers:
///
/// Bug #1: `budget_figures` (schema/001) has no `fiscal_year` column at
/// all — its primary key is `(client_id, dimension, entity_code,
/// fiscal_month)` — so a plain join to it (`v_dimension_performance`,
/// schema/002, and `fn_dimension_performance_filtered`, schema/011) returns
/// the exact same single budget figure for every fiscal year's August row
/// for a given entity, because there IS only one August target on record
/// per entity, full stop — it isn't set per year. The first version of this
/// function summed that identical figure once per matched year, same as the
/// real, genuinely-additive actuals above — silently multiplying a single
/// real target by however many years happened to have August data (3
/// matched years made R Target show 3x the actual budget).
///
/// Bug #2: Craig — "the analysis now is rubbish because it is comparing
/// three years august sales with 1 august target inflating the % target."
/// Taking the single unscaled target fixed R Target's own displayed
/// number, but left %Target comparing an N-year SUM of actuals against a
/// single year's worth of target.
///
/// Second attempt (also superseded): scaling the single target UP by how
/// many years contributed a row, so R Target and R Value sat on the same
/// N-year basis. Mathematically this landed on the exact same number bug
/// #1 already produced (multiplying an identical repeated value by N is
/// multiplying it by N, whichever way you write it) — Craig caught that it
/// was "still incorrect" and asked to agree the actual formula before
/// anything else got built.
///
/// **Agreed design**: R Target = (this entity's actual sales for every
/// PAST year in the merged set) + (the one target on file, which
/// `targetValue` already treats as "this current period's target" —
/// stands in for what THIS year, specifically, is expected to reach).
/// `currentFy` is the client's actual current fiscal year (computed once by
/// the caller — not just "the newest year that happens to have a row" —
/// Craig confirmed if the current year's August hasn't happened/loaded yet,
/// every contributing row counts as "past," R Value is the historical sum
/// only, and R Target (historical sum + target) is deliberately larger than
/// R Value until this year's August actually occurs — %Target understating
/// until then is expected, not a bug). `targetValue` per row is already
/// resolved to budget-or-Seasonal-Forecast by schema/021 (falls back to the
/// forecast figure when Sales Budget hasn't been entered for that
/// entity/month) — this function doesn't need to know which source it came
/// from, only that it's the one figure standing in for "this period's
/// expectation."
///
/// `contributionPercent` is recomputed too, as this entity's merged
/// actualValue divided by every merged entity's actualValue summed
/// together — the best available definition of "this entity's share"
/// once a single row no longer means "share of one specific period's
/// company total." Flagged here because it's the one figure with real
/// room for a different, equally defensible definition (e.g. an average
/// of each year's own contribution) — worth Craig's eyes if the %
/// Contribution total row doesn't land where he expects with a bare Month
/// filter active.
List<DimensionPerformance> mergeAcrossYears(List<DimensionPerformance> rawRows, int currentFy) {
  final byEntity = <String, List<DimensionPerformance>>{};
  for (final row in rawRows) {
    byEntity.putIfAbsent(row.entityCode, () => []).add(row);
  }
  final grandTotalValue = rawRows.fold<num>(0, (sum, r) => sum + r.actualValue);
  return byEntity.entries.map((entry) {
    final entityRows = entry.value;
    final value = entityRows.fold<num>(0, (sum, r) => sum + r.actualValue);
    final quantity = entityRows.fold<num>(0, (sum, r) => sum + r.actualQuantity);
    final profit = entityRows.fold<num>(0, (sum, r) => sum + r.actualProfit);
    // Agreed design — see doc comment above. Past years' actual (every
    // contributing row that ISN'T the current fiscal year) plus the one
    // target on file for the current period.
    final pastActual = entityRows.where((r) => r.fiscalYear != currentFy).fold<num>(0, (sum, r) => sum + r.actualValue);
    final singleTarget = entityRows.first.targetValue;
    final target = singleTarget == null ? null : pastActual + singleTarget;
    return DimensionPerformance(
      dimension: entityRows.first.dimension,
      entityCode: entry.key,
      // Not displayed or exported anywhere on this screen — kept as the
      // most recent contributing year purely so this remains a real,
      // meaningful value rather than an arbitrary placeholder.
      fiscalYear: entityRows.map((r) => r.fiscalYear).reduce((a, b) => a > b ? a : b),
      fiscalMonth: entityRows.first.fiscalMonth,
      actualValue: value,
      actualQuantity: quantity,
      actualProfit: profit,
      gpPercent: value == 0 ? 0 : (profit / value) * 100,
      targetValue: target,
      targetPercent: (target == null || target == 0) ? null : (value / target) * 100,
      contributionPercent: grandTotalValue == 0 ? null : (value / grandTotalValue) * 100,
    );
  }).toList();
}
