/// "Sales Coverage" — task #93's final shape, after a long pivot away from
/// its original quote/order-lifecycle scope. See Wyzesales_Rebuild_
/// Decisions.md Section 55 for the full reasoning trail: quotes and sales
/// orders are never reliably captured anywhere in WCSA's data (not even in
/// their own daily-use IQRetail application), so lifecycle-status tracking
/// was dropped entirely in favour of a purely actual-sales-vs-target measure
/// of "gap in sales cover" — Craig's own framing: "the Gap between Actual
/// Sales and Target Sales."
///
/// R Gap needs no data beyond what DimensionPerformance already carries — R
/// Target minus R Value, both already resolved server-side (schema/002 +
/// schema/021's Budget→Forecast fallback). % Coverage Needed additionally
/// needs each entity's HISTORICAL AVERAGE REVENUE PER PERIOD — total revenue
/// over its trailing history window (fn_dimension_sales_history, schema/023)
/// divided by how many of those months it actually has sales in ("active
/// months" — months WITH recorded sales, not calendar tenure, since nothing
/// in this system tracks hire dates).
///
/// Deliberately kept as pure functions over plain data here, the same
/// pattern performance_rollup.dart's mergeAcrossYears established for task
/// #92 — auditable and unit-testable in Dart, rather than buried in SQL (see
/// schema/023's own header comment for why the SQL side stops at raw sums).
library;

/// One row of fn_dimension_sales_history's output (schema/023) — either one
/// entity's own trailing-window figures, or (when fetched with
/// dimension='company') the single company-wide fallback row.
class EntitySalesHistory {
  final String entityCode;
  final int activeMonths;
  final num totalValue;

  const EntitySalesHistory({required this.entityCode, required this.activeMonths, required this.totalValue});

  factory EntitySalesHistory.fromMap(Map<String, dynamic> map) {
    return EntitySalesHistory(
      entityCode: map['entity_code'] as String,
      activeMonths: (map['active_months'] as num).toInt(),
      totalValue: map['total_value'] as num? ?? 0,
    );
  }

  /// Total revenue over the trailing window, spread across only the months
  /// that actually had sales — not the window's calendar length. Zero when
  /// there's no history at all (activeMonths == 0), rather than dividing by
  /// zero.
  num get avgRevenuePerPeriod => activeMonths == 0 ? 0 : totalValue / activeMonths;
}

/// Below this many active months, an entity's own average is considered
/// statistically unreliable and the company-wide average is used instead —
/// Craig, 2026-09-02, picking between two proposed fallback options: "I like
/// 2. the fall back option and my guess is less than 3 months of history
/// activates the fall back."
const int kMinActiveMonthsForOwnAverage = 3;

/// The outcome of the % Coverage Needed calc for one entity/period.
///
/// Exactly one of these is the "headline" state a UI renders:
///  - `onTarget` — R Gap <= 0, already at or above target; show "On Target",
///    no percentage.
///  - `insufficientData` — no target is set at all, or even the company-wide
///    fallback has no usable average (e.g. a brand-new client with no sales
///    history yet); show "-" / "insufficient data", no percentage.
///  - otherwise — `coveragePercent` is a real number to display, and
///    `usedFallback` says whether it came from the entity's own average or
///    the company-wide one (Craig: this must be "flagged/visible in the UI
///    when this fallback is used", e.g. "using team average").
class CoverageResult {
  final num? rGap;
  final num? coveragePercent;
  final bool onTarget;
  final bool usedFallback;
  final bool insufficientData;

  const CoverageResult({
    this.rGap,
    this.coveragePercent,
    required this.onTarget,
    required this.usedFallback,
    required this.insufficientData,
  });
}

/// Computes R Gap and % Coverage Needed for one DimensionPerformance row (or
/// one row already aggregated across several months by `mergeAcrossMonths`
/// — see `periods` below).
///
/// `own` is this entity's own fn_dimension_sales_history row (null if it has
/// no history at all yet — e.g. a brand-new rep who hasn't sold anything).
/// `company` is the company-wide fallback row (fn_dimension_sales_history
/// called with dimension='company') — should in practice always be present
/// once any client has any sales on record at all, but handled as
/// nullable/zero regardless rather than assumed.
///
/// `periods` — how many months' worth of average revenue the Gap should be
/// measured against. Defaults to 1 (a single fiscal month's Gap against one
/// month's average — every original call site). A Year filter on Performance
/// Analysis (2026-09-02, Craig noticing a Year-only filter returned no data,
/// then confirming the fix should sum the whole year per entity) produces a
/// Gap spanning several months at once, so it needs to be measured against
/// that many months of average revenue, not one — the exact same reasoning
/// already applied to the Dashboard's YTD coverage tile (`avg × elapsed
/// months`, Craig: "Multiply average by elapsed months"). `avg` itself is
/// still a single month's figure (`EntitySalesHistory.avgRevenuePerPeriod`)
/// either way; only the multiplier changes.
///
/// Worked examples (confirmed with Craig, 2026-09-02):
///  - Brand-new rep, 1 active month of own history -> falls back to company
///    average (e.g. R250,000/month); R Gap R60,000 -> 24%, flagged as using
///    the team average.
///  - Established rep, 36 active months, own average R60,000/month; R Gap
///    R30,000 -> 50%, own figure, no flag.
CoverageResult computeCoverage({
  required num? targetValue,
  required num actualValue,
  required EntitySalesHistory? own,
  required EntitySalesHistory? company,
  int periods = 1,
}) {
  if (targetValue == null) {
    return const CoverageResult(onTarget: false, usedFallback: false, insufficientData: true);
  }

  final gap = targetValue - actualValue;
  if (gap <= 0) {
    return CoverageResult(rGap: gap, onTarget: true, usedFallback: false, insufficientData: false);
  }

  final useFallback = own == null || own.activeMonths < kMinActiveMonthsForOwnAverage;
  final source = useFallback ? company : own;
  final avg = (source?.avgRevenuePerPeriod ?? 0) * periods;

  if (source == null || avg <= 0) {
    return CoverageResult(rGap: gap, onTarget: false, usedFallback: useFallback, insufficientData: true);
  }

  return CoverageResult(
    rGap: gap,
    coveragePercent: (gap / avg) * 100,
    onTarget: false,
    usedFallback: useFallback,
    insufficientData: false,
  );
}
