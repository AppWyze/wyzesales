import '../../data/models/profile.dart';
import '../constants/fiscal.dart';
import '../filters/global_filters.dart';

/// 2026-09-03, Craig — Sales Analysis's Graph tab: "I would like to add an
/// overlay light coloured bar chart with the Target for each filtered
/// Dimension including Company." This is the pure decision logic behind
/// that overlay (which dimension's target applies, and how to derive one
/// when the current filter combination has no real entered target),
/// pulled out of the screen itself so it's independently unit-testable —
/// the same reason `performance_rollup.dart`/`sales_coverage.dart` are
/// standalone utility files rather than private State methods.

/// One dimension + the entity currently selected for it — the single
/// dimension a Target overlay can source a REAL entered target from. Every
/// other caller of `SalesDimension.filterable` treats "which one dimension
/// is picked" as a UI concern (a dropdown, a filter chip); this is the one
/// place that needs to distinguish "exactly one active" from "several at
/// once", since a real entered target only ever exists per single
/// dimension (Wyzesales_Rebuild_Decisions.md Section 58 — targets are
/// never cross-tabulated across dimensions).
class ActiveDimensionFilter {
  final SalesDimension dimension;
  final FilterSelection selection;
  const ActiveDimensionFilter(this.dimension, this.selection);
}

/// How many of the 5 REAL (filterable) dimensions currently have a
/// selection. Year/Month/Document deliberately don't count here — they
/// narrow WHICH period or rows are summed, not WHICH dimension's target
/// applies to what's shown.
int activeDimensionFilterCount(GlobalFilters filters) => [
      filters.salesPerson,
      filters.category,
      filters.customer,
      filters.item,
      filters.branch,
    ].where((v) => v != null).length;

/// The single active dimension filter, or null when zero or more than one
/// of the 5 real dimensions is active (see [activeDimensionFilterCount] —
/// callers needing the zero-active/"whole company" case handle that
/// separately, since there's no `FilterSelection` to return for it).
ActiveDimensionFilter? singleActiveDimensionFilter(GlobalFilters filters) {
  if (activeDimensionFilterCount(filters) != 1) return null;
  if (filters.salesPerson != null) return ActiveDimensionFilter(SalesDimension.salesPerson, filters.salesPerson!);
  if (filters.category != null) return ActiveDimensionFilter(SalesDimension.category, filters.category!);
  if (filters.customer != null) return ActiveDimensionFilter(SalesDimension.customer, filters.customer!);
  if (filters.item != null) return ActiveDimensionFilter(SalesDimension.item, filters.item!);
  return ActiveDimensionFilter(SalesDimension.branch, filters.branch!);
}

/// Craig's own worked example (2026-09-03, walked through with real
/// screenshotted numbers before this was built): with 2+ dimension filters
/// stacked at once, there is no real entered target for that exact
/// combination — derive one instead as this combination's share of
/// whole-company actual revenue, applied to the whole-company target, for
/// one period (a fiscal month, in Sales Analysis' case):
///
///   derived target = companyTarget × (filteredActual ÷ totalActual)
///
/// Returns null whenever any required input is missing, or whole-company
/// actual is zero (nothing to take a share of) — callers should treat null
/// as "no bar for this period" rather than falling back to zero, since a
/// zero-value bar would misleadingly claim "the target here is genuinely
/// nothing" rather than "nothing could be derived".
num? deriveProportionalTarget({
  required num? companyTarget,
  required num? totalActual,
  required num? filteredActual,
}) {
  // `<= 0`, not `== 0` — 2026-09-04, Craig, after asking for a review of this
  // whole mechanism: a whole-company (or, since deriveHierarchicalTarget
  // below reuses this same guard for every basis, any single-dimension
  // basis's) actual can in principle be negative for a period with heavier
  // credit notes/returns than invoices. Dividing by a negative denominator
  // would flip the derived target's sign in a way nobody reading the chart
  // would expect — treated the same as "no baseline to take a share of"
  // rather than producing a technically-computed but nonsensical number.
  if (companyTarget == null || filteredActual == null || totalActual == null || totalActual <= 0) return null;
  final derived = companyTarget * (filteredActual / totalActual);
  // Floored at 0, not returned as-is or filtered out to null — a heavily
  // credit-noted period can also make `filteredActual` itself negative even
  // with a perfectly normal positive `totalActual`, which would derive a
  // negative "target." A target reading negative on the chart would look
  // like a rendering bug rather than what it actually is (a real, if
  // extreme, share of a real number) — floored to 0 so it still draws as a
  // (visibly small) real bar rather than vanishing into a misleading dash.
  return derived < 0 ? 0 : derived;
}

/// One month's worth of actual revenue — the minimal shape
/// [sumTrailingWindow] needs, so it stays decoupled from
/// `data/models/consolidated_sales.dart` (ConsolidatedSales) the same way
/// every other function in this file avoids a dependency on Supabase/
/// repository types, for the same testability reasoning as the file's own
/// header comment.
typedef MonthlyValue = ({DateTime month, num value});

/// How many trailing calendar months [sumTrailingWindow] sums by default —
/// matches `sales_coverage.dart`'s own `kMinActiveMonthsForOwnAverage`
/// (also 3), for the same reason: a single month's own actual revenue is
/// noisy for a narrow filter combination (Section 61/73 — Craig, reviewing
/// the Customer+Item worked example: "how does it calculate a future month
/// with no actual revenue yet?" surfaced that a single point-in-time ratio
/// swings hard for a low-volume slice, e.g. a customer who orders once a
/// quarter showing a huge one-month "share" and near-zero every other
/// month). 3 trailing months smooths that out while still being recent
/// enough to track a genuine change in mix, not just noise.
const int kTargetTrailingWindowMonths = 3;

/// Sums `.value` for every entry whose `.month` falls within the trailing
/// `windowMonths` calendar months ending at (and including) `endMonth` —
/// e.g. windowMonths=3, endMonth=1 Sep 2027 sums Jul+Aug+Sep 2027,
/// regardless of where a fiscal year happens to start (this is pure
/// calendar-month arithmetic, deliberately not fiscal-aware, since
/// `ConsolidatedSales.month` is already a real calendar date). A month with
/// no matching entry at all (nothing sold, or a genuinely future month)
/// contributes 0 rather than being treated specially — the caller's own
/// null-vs-zero handling ([deriveProportionalTarget]'s `totalActual <= 0`
/// guard) is what turns "the whole window summed to 0" into "no bar," not
/// this function.
num sumTrailingWindow({
  required Iterable<MonthlyValue> series,
  required DateTime endMonth,
  int windowMonths = kTargetTrailingWindowMonths,
}) {
  final start = DateTime(endMonth.year, endMonth.month - (windowMonths - 1));
  final endExclusive = DateTime(endMonth.year, endMonth.month + 1);
  num total = 0;
  for (final entry in series) {
    final m = DateTime(entry.month.year, entry.month.month);
    if (!m.isBefore(start) && m.isBefore(endExclusive)) total += entry.value;
  }
  return total;
}

/// One candidate "base" the proportional-target estimate could scale from —
/// either a single actively-filtered dimension's own real entered target
/// (the narrowest, most specific base available), or the whole-company
/// target as the last-resort candidate every caller should include. `label`
/// is only ever shown to the user once this candidate is the one actually
/// used (see [ProportionalTargetResult.basisLabel]), e.g. "Item: Multistage
/// Vertical Pump" or "Company".
class TargetBasisCandidate {
  final String label;

  /// This basis's own real entered target (`resolveTarget`'s result) for
  /// the month/period in question — null when nothing's entered for it.
  final num? target;

  /// This basis's own trailing-window actual revenue, IGNORING every other
  /// currently-active filter — e.g. for an "Item" candidate, this is that
  /// item's total revenue across every customer/rep/branch, not just the
  /// slice matching every filter stacked on top of it.
  final num? ownActual;

  const TargetBasisCandidate({required this.label, required this.target, required this.ownActual});
}

class ProportionalTargetResult {
  /// The derived target itself — already floored at 0 (see
  /// [deriveProportionalTarget]).
  final num value;

  /// The share actually applied (filteredActual ÷ the winning candidate's
  /// ownActual) — e.g. 0.422 for "42.2%". Surfaced so the UI can show the
  /// reader exactly what was computed rather than asking them to take the
  /// derived number on faith (Craig, 2026-09-04: asked for the mechanism to
  /// be more transparent after having to reverse-engineer this exact
  /// percentage by hand).
  final double share;

  /// Which candidate actually won — see [TargetBasisCandidate.label].
  final String basisLabel;

  const ProportionalTargetResult({required this.value, required this.share, required this.basisLabel});
}

/// Tries each candidate in [candidates], IN THE ORDER GIVEN, and returns a
/// derived target from the first one that has both a real entered target
/// and a positive trailing-window actual to divide by — see
/// [deriveProportionalTarget] for the exact per-candidate arithmetic (reused
/// here unchanged, so every one of its existing null/zero/negative
/// guarantees applies uniformly to every candidate, company included).
///
/// Callers should order `candidates` most-specific-first (e.g. each actively
/// filtered dimension, in `SalesDimension.filterable` order) and put a
/// whole-company candidate LAST, since that's the one base with a real
/// entered target almost always available — a narrower candidate that
/// qualifies is preferred because it dilutes the estimate through less
/// unrelated data than the whole company would (Craig, 2026-09-04, agreeing
/// this was worth building: "a smaller reference base... might align better
/// with that item's own growth expectations rather than diluting through
/// the whole company's mix"). Returns null only if EVERY candidate fails —
/// callers should treat that exactly like a null from
/// [deriveProportionalTarget] itself ("no bar for this period").
ProportionalTargetResult? deriveHierarchicalTarget({
  required List<TargetBasisCandidate> candidates,
  required num? filteredActual,
}) {
  for (final candidate in candidates) {
    final derived = deriveProportionalTarget(
      companyTarget: candidate.target,
      totalActual: candidate.ownActual,
      filteredActual: filteredActual,
    );
    if (derived == null) continue;
    final share = filteredActual! / candidate.ownActual!;
    return ProportionalTargetResult(value: derived, share: share, basisLabel: candidate.label);
  }
  return null;
}

/// Mirrors schema/021's `coalesce(nullif(budget_value, 0), forecast_value)`
/// target resolution client-side (Craig, 2026-09-03: filtering to a customer
/// with no September sales showed "Actual Revenue = 0" but no Target bar).
/// v_dimension_performance/fn_dimension_performance_filtered only ever
/// surface a target for a fiscal month that has at least one ACTUAL sales
/// row, because they're built by joining budget/forecast ONTO actual sales
/// rather than the other way round — so a genuinely real, entered target for
/// a month with zero actual sales was being silently dropped, for any
/// dimension+entity, not just whole-company. budget_figures/sales_forecast
/// carry no fiscal_year column at all (one figure per fiscal_month label,
/// reused every year), so there's nothing year- or actual-sales-specific to
/// join against in the first place — reading them directly (BudgetRepository
/// .fetchBudget/.fetchForecastValues) and resolving here sidesteps the
/// actual-sales dependency entirely.
/// `budgetValue` treats 0 the same as "not entered" (not distinguishable
/// from a real 0, per schema/021's own reasoning — budget_value is `not
/// null default 0`) and falls back to `forecastValue`.
num? resolveTarget({required num? budgetValue, required num? forecastValue}) {
  if (budgetValue != null && budgetValue != 0) return budgetValue;
  return forecastValue;
}

/// The dimension + entity to use for a "nothing filtered" Target lookup —
/// Sales Analysis' default (0-dimension-filter) view and the Dashboard's
/// Revenue Target Attainment tile, scoped to the VIEWER'S OWN access level
/// rather than always the whole company. Craig, 2026-09-03, after seeing a
/// plain 'user' login's Dashboard tile compare their own personal revenue
/// against the entire company's target: "The dashboard must be specific.
/// i.e. User sees only their info. RegUsers sees their branch and Admin
/// sees everything" — extended, on his confirmation, to Sales Analysis'
/// own default view too, so neither screen shows a non-admin login a target
/// that isn't theirs to see.
///
/// adminuser/superuser (and a null profile, e.g. mid-load) keep the
/// original whole-company behaviour every login saw before this existed.
/// reguser/user fall back to 'ALL' if their own branch_code/rep_code is
/// somehow unset — schema/001 doesn't make either mandatory for every
/// level, so this stays null-safe rather than assuming they're always
/// present.
({SalesDimension dimension, String entityCode}) defaultTargetScope(Profile? profile) {
  if (profile?.level == UserLevel.reguser) {
    return (dimension: SalesDimension.branch, entityCode: profile?.branchCode ?? 'ALL');
  }
  if (profile?.level == UserLevel.user) {
    return (dimension: SalesDimension.salesPerson, entityCode: profile?.repCode ?? 'ALL');
  }
  return (dimension: SalesDimension.company, entityCode: 'ALL');
}
