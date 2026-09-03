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
  if (companyTarget == null || filteredActual == null || totalActual == null || totalActual == 0) return null;
  return companyTarget * (filteredActual / totalActual);
}
