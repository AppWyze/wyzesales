import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/app_providers.dart';
import '../../../core/constants/fiscal.dart';
import '../../../core/filters/global_filters.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/utils/performance_rollup.dart';
import '../../../core/utils/sales_coverage.dart';
import '../../../data/models/dimension_performance.dart';
import '../../../shared/widgets/app_shell.dart';
import '../../../shared/widgets/async_section.dart';
import '../../../shared/widgets/boxed_dropdown.dart';
import '../../../shared/widgets/data_export_buttons.dart';
import '../../../shared/widgets/responsive_data_table.dart';

class _PerformanceData {
  final List<DimensionPerformance> rows;
  final Map<String, String> names;
  // R Gap / % Coverage Needed (task #93/#102) — raw inputs from
  // fn_dimension_sales_history (schema/023), keyed by entity_code for
  // `ownHistory` (one row per entity in this dimension) and a single
  // always-present-or-null row for `companyHistory` (the <3-active-months
  // fallback target). See core/utils/sales_coverage.dart for why this data
  // is fetched raw and turned into a display figure here in Dart, not in SQL.
  final Map<String, EntitySalesHistory> ownHistory;
  final EntitySalesHistory? companyHistory;

  // Whether the filtered period is the one currently in progress right now
  // — for a Month grain, today's fiscal year AND fiscal month; for a Year
  // grain (see `isYearGrain` below), just today's fiscal year, since the
  // year itself isn't over yet. See `_load()`'s own comment on exactly how
  // this is decided, and `_coverageText`'s doc comment for why it matters.
  // 2026-09-02, Craig, looking at a closed FY2027/August: "I don't think it
  // can say % Coverage Needed for a past period as this makes no sense. You
  // cannot catch it up."
  final bool isLivePeriod;

  // True when this is a Year-only filter (`mergeAcrossMonths` in
  // performance_rollup.dart, task #93 follow-up, 2026-09-02) rather than one
  // specific fiscal month (optionally merged across years). Only changes
  // what `_coverageColumnLabel` calls the past-period column — "% Below Avg
  // Year" reads better than "% Below Avg Month" once the row is actually a
  // whole year's totals, per Craig's own suggestion.
  final bool isYearGrain;

  // How many months' worth of average revenue the Gap should be measured
  // against — 1 for a single fiscal month (the original, still-default
  // case), or however many months a Year filter's row actually sums (see
  // `_load()`). Passed straight through to `computeCoverage`'s `periods`.
  final int coveragePeriods;

  const _PerformanceData({
    required this.rows,
    required this.names,
    required this.ownHistory,
    this.companyHistory,
    required this.isLivePeriod,
    this.isYearGrain = false,
    this.coveragePeriods = 1,
  });

  CoverageResult coverageFor(DimensionPerformance row) => computeCoverage(
        targetValue: row.targetValue,
        actualValue: row.actualValue,
        own: ownHistory[row.entityCode],
        company: companyHistory,
        periods: coveragePeriods,
      );
}

/// %Contribution, R Value, R Target, %Target, R Profit, %GP, Quantity — one
/// row per entity for a chosen fiscal year/month
/// (Wyzesales_Screens_and_Recommendations.md Section 1). Almost no
/// client-side math: v_dimension_performance (schema/002 Section 3) already
/// computes all three ratios in SQL.
///
/// R Gap and % Coverage Needed (task #93/#102, added 2026-09-02) are the two
/// exceptions — see core/utils/sales_coverage.dart's doc comment for the
/// formula and Wyzesales_Rebuild_Decisions.md Section 55 for why this
/// replaced the originally-planned quote/order lifecycle tracking entirely.
class PerformanceScreen extends ConsumerStatefulWidget {
  const PerformanceScreen({super.key, required this.dimension});

  final SalesDimension dimension;

  @override
  ConsumerState<PerformanceScreen> createState() => _PerformanceScreenState();
}

class _PerformanceScreenState extends ConsumerState<PerformanceScreen> {
  late Future<_PerformanceData> _future;

  // 2026-08-27, diagnosing Craig's "Filters are not working correctly"
  // report: bumped on every _load() call and used as AsyncSection's `key`
  // below. Purely a belt-and-suspenders measure — a Future reassigned to
  // FutureBuilder's `future:` parameter is already supposed to make it
  // resubscribe on its own (this is standard, documented FutureBuilder
  // behaviour) — but giving it a genuinely new widget identity on every
  // refetch removes any possible doubt that a stale snapshot could survive
  // across rebuilds, at zero cost. Combined with the debugPrint calls in
  // _refetch()/_load() below (temporary — remove once this is confirmed
  // fixed), this should make it possible to tell, from Craig's own `flutter
  // run` console, exactly which of the three suspected failure points is
  // real: (1) _refetch() never firing when a filter changes while already on
  // this screen, (2) _load() firing but reading stale/wrong filter values,
  // or (3) the fetch running correctly but the widget not visibly updating.
  int _loadGeneration = 0;

  // R Value descending — matches this table's pre-existing hardcoded sort,
  // now user-adjustable via the column headers (2026-08-26, Craig: "sort
  // ascending or descending order by clicking on a column header").
  int _sortColumnIndex = 2;
  bool _sortAscending = false;

  // 2026-08-27: this screen's own inline Year/Month dropdowns were removed —
  // Craig: "Performance: drop Year, Month," part of consolidating every
  // filter into the single GlobalFilterBar rather than duplicating any of
  // them locally (superseding the 2026-08-26 "keep Year/Month inline, they
  // show a real default" exception — Craig decided consistency/simplicity
  // wins over that). Year/Month are still read here (via
  // _effectiveFiscalYear/_effectiveFiscalMonth) and still default to
  // "today"'s fiscal year/month before either is explicitly set — that part
  // is unchanged — only the two boxes that let you set them ON THIS SCREEN
  // are gone; setting either now happens through GlobalFilterBar's "Add
  // filter" like every other filter. The ref.listen in build() below still
  // covers all of them, so a filter set on a different screen (or via
  // GlobalFilterBar right here) still triggers a refetch.

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void didUpdateWidget(covariant PerformanceScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // setState() wrapper added 2026-08-27 — same pre-existing bug
    // sales_by_screen.dart's own didUpdateWidget already had fixed ("this
    // used to reassign _future without a setState() wrapper, so a dimension
    // switch via the switcher dropdown didn't reliably repaint the
    // AsyncSection into its loading state straight away"); Performance had
    // the identical unwrapped reassignment and never got the matching fix.
    if (oldWidget.dimension != widget.dimension) {
      setState(() {
        _loadGeneration++;
        _future = _load();
      });
    }
  }

  String _currentFiscalMonthLabel(DateTime date) {
    const labels = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return labels[date.month - 1];
  }

  /// 2026-09-01, Craig: "if I filter on August then it must filter on and
  /// display and sum all transactions for all of the augusts not just the
  /// last one" — reported against Sales Analysis/Quote Analysis/Sales Order
  /// Analysis but explicitly named Performance too. This screen used to
  /// default straight to the current fiscal year the moment Year was unset,
  /// even with a Month filter active on its own — same class of bug as
  /// document_analysis_view.dart's `_effectiveFiscalYear` (see that file's
  /// own doc comment on the fix), fixed the same way: only default to the
  /// current fiscal year when NEITHER Year nor Month is set at all. A Month
  /// filter on its own now returns null here, so `fetchDimensionPerformance`
  /// (which already treats a null `fiscalYear` as "every fiscal year",
  /// unlike this screen's old always-current-year default) can return one
  /// row per entity PER FISCAL YEAR that has data for that month — `_load`
  /// below collapses those into a single merged row per entity when that
  /// happens (see `mergeAcrossYears`'s own doc comment, core/utils/performance_rollup.dart).
  int? _effectiveFiscalYear(GlobalFilters filters) {
    if (filters.fiscalYear != null) return filters.fiscalYear;
    if (filters.fiscalMonth != null) return null;
    return fiscalYearFor(DateTime.now(), startMonth: ref.read(fiscalYearStartMonthProvider).valueOrNull ?? 3);
  }

  /// 2026-09-02, Craig: "it does not recognise a only year filter. i.e. If I
  /// input Year = 2027 it will show no data." Same bug class as
  /// `_effectiveFiscalYear` above, mirrored: this used to default straight to
  /// TODAY's calendar month whenever Month wasn't explicitly set — even when
  /// a Year filter WAS explicitly set on its own — so "Year 2027" silently
  /// became "Year 2027 + (today's fiscal month)," which can easily have
  /// little or no data if today's fiscal month has barely started (Craig hit
  /// this on 2026-09-02, day 2 of September). Fixed the same way: only
  /// default to the current fiscal month when NEITHER Year nor Month is set.
  /// A Year-only filter now returns null here, so `fetchDimensionPerformance`
  /// (which already treats a null `fiscalMonth` as "every fiscal month",
  /// same as it always has for `fiscalYear`) can return one row per entity
  /// PER FISCAL MONTH within that year — `_load` below collapses those into
  /// a single merged row per entity via `mergeAcrossMonths`
  /// (core/utils/performance_rollup.dart) when that happens.
  String? _effectiveFiscalMonth(GlobalFilters filters) {
    if (filters.fiscalMonth != null) return filters.fiscalMonth;
    if (filters.fiscalYear != null) return null;
    return _currentFiscalMonthLabel(DateTime.now());
  }

  Future<_PerformanceData> _load() async {
    final filters = ref.read(globalFiltersProvider);
    final effectiveYear = _effectiveFiscalYear(filters);
    final effectiveMonth = _effectiveFiscalMonth(filters);
    // TEMPORARY — 2026-08-27, diagnosing Craig's "Filters are not working
    // correctly" report (Year/Month applied on Performance itself don't
    // change the table, and clearing doesn't either, even though arriving
    // here from Sales Analysis with a filter already set DOES show filtered
    // data). Remove once the actual cause is confirmed and fixed. Run via
    // `flutter run` (not a release build — debugPrint is a no-op there) and
    // watch the console while reproducing: if NOTHING prints when you change
    // Year/Month on this screen, _refetch() itself isn't firing (a
    // ref.listen/Riverpod subscription problem). If this DOES print but with
    // the wrong year/month, _load() is reading stale filters. If it prints
    // the CORRECT values but the table still doesn't change, the bug is in
    // the fetch/query itself, not in when it's triggered.
    debugPrint(
      '[PerformanceScreen] _load() dimension=${widget.dimension.dbValue} '
      'effectiveYear=$effectiveYear effectiveMonth=$effectiveMonth '
      'rawFilters(year=${filters.fiscalYear}, month=${filters.fiscalMonth}, '
      'salesPerson=${filters.forDimension(SalesDimension.salesPerson)?.code}, category=${filters.forDimension(SalesDimension.category)?.code}, '
      'customer=${filters.forDimension(SalesDimension.customer)?.code}, item=${filters.forDimension(SalesDimension.item)?.code}, '
      'branch=${filters.forDimension(SalesDimension.branch)?.code})',
    );
    // currentFy/historyYears computed up front (not just inside the
    // effectiveYear==null branch below) because the coverage history fetch
    // needs the same trailing window regardless of whether a specific Year
    // is filtered — an entity's historical average is a standalone baseline,
    // not something that should shrink to one year just because Performance
    // Analysis itself is currently viewing one year (see schema/023's own
    // header comment on this same point).
    final startMonth = ref.read(fiscalYearStartMonthProvider).valueOrNull ?? 3;
    final currentFy = fiscalYearFor(DateTime.now(), startMonth: startMonth);
    final historyYears = ref.read(fiscalYearHistoryYearsProvider).valueOrNull ?? 3;
    final historyWindow = fiscalYearWindow(currentFy, historyYears);
    final results = await Future.wait([
      ref.read(salesRepositoryProvider).fetchDimensionPerformance(
            dimension: widget.dimension,
            fiscalYear: effectiveYear,
            fiscalMonth: effectiveMonth,
            filters: filters,
          ),
      ref.read(referenceDataRepositoryProvider).namesFor(widget.dimension),
      ref.read(salesRepositoryProvider).fetchSalesHistory(dimension: widget.dimension.dbValue, fiscalYears: historyWindow),
      ref.read(salesRepositoryProvider).fetchSalesHistory(dimension: 'company', fiscalYears: historyWindow),
    ]);
    var rawRows = results[0] as List<DimensionPerformance>;
    final ownHistory = {for (final h in results[2] as List<EntitySalesHistory>) h.entityCode: h};
    final companyHistoryRows = results[3] as List<EntitySalesHistory>;
    final companyHistory = companyHistoryRows.isEmpty ? null : companyHistoryRows.first;
    // effectiveYear == null means the query above wasn't restricted to one
    // fiscal year, so `rawRows` can hold more than one row per entity (one
    // per fiscal year that has data for `effectiveMonth`) — merge before
    // this reaches _buildTable/_totalsRow/_buildExportData, all three of
    // which assume exactly one row per entity. When effectiveYear IS set,
    // this is a no-op (every entity already has at most one row) and
    // returns rawRows completely unchanged, so the normal single-period
    // case can never regress from this change.
    //
    // 2026-09-01: `fn_dimension_performance_filtered`'s `p_fiscal_year` is a
    // single nullable int (schema/011), not the int[] the other two
    // filtered-RPC functions take — so a null year here genuinely means
    // "every fiscal year with ANY data on record," not "every fiscal year
    // in the client's configured 3/5-year history window" the way it does
    // everywhere else in the app (Sales Analysis, Sales By, YTD Comparative,
    // Dashboard all bound their own multi-year queries to
    // `fiscalYearWindow`). Left unbounded, an older client's data could
    // silently pull in far more years than the window setting promises, and
    // — since `mergeAcrossYears` below scales R Target by how many years
    // it merges — an ever-growing, unbounded year count would keep
    // inflating that scale factor too, not just the actual figures.
    // Filtered client-side (rather than changing the SQL function's
    // signature) since this is the only screen with the gap and a plain
    // `.where` is a much smaller change than a new migration.
    if (effectiveYear == null) {
      final window = historyWindow.toSet();
      rawRows = rawRows.where((r) => window.contains(r.fiscalYear)).toList();
    }

    // Three distinct shapes `rawRows` can arrive in, each needing its own
    // merge (or none) before this reaches _buildTable/_totalsRow/
    // _buildExportData, all three of which assume exactly one row per
    // entity:
    //  - Year-only filter (`effectiveMonth == null`, new 2026-09-02, Craig:
    //    "it does not recognise a only year filter") — one row per entity
    //    PER FISCAL MONTH within that year. `mergeAcrossMonths`
    //    (core/utils/performance_rollup.dart) collapses those into one
    //    whole-year row per entity — confirmed with Craig: "Yes" to summing
    //    the whole year's totals per entity, same shape as every other
    //    column.
    //  - Bare-Month filter (`effectiveYear == null`) — one row per entity
    //    PER FISCAL YEAR that has data for that month. `mergeAcrossYears`
    //    collapses those (task #92/#93, see that function's own doc
    //    comment).
    //  - Both set (the normal single-period case) — already exactly one row
    //    per entity, no merge needed.
    final bool isYearGrain = effectiveMonth == null;
    final List<DimensionPerformance> rows;
    if (isYearGrain) {
      rows = mergeAcrossMonths(rawRows);
    } else if (effectiveYear == null) {
      rows = mergeAcrossYears(rawRows, currentFy);
    } else {
      rows = rawRows;
    }
    debugPrint('[PerformanceScreen] _load() completed — ${rawRows.length} raw row(s), ${rows.length} after merge');

    // Is the filtered period the one actually still in progress right now?
    // Craig, 2026-09-02, looking at a closed FY2027/August row: "I don't
    // think it can say % Coverage Needed for a past period as this makes no
    // sense. You cannot catch it up." For a Year-only (year-grain) filter, a
    // year isn't over until its last day regardless of which month within it
    // — so it's live purely based on whether the pinned year is the current
    // fiscal year (Craig, confirming this design, 2026-09-02: "if it is the
    // current year then we are also looking at % Coverage Needed"). For a
    // Month-grain filter, live requires BOTH the effective month to be
    // today's own fiscal month AND (no Year is pinned, or the pinned Year is
    // this fiscal year) — a specific past Year+Month, or the current Year
    // with an earlier Month, are both fully closed and get the
    // backward-looking label instead (`_coverageText`'s doc comment has the
    // full reasoning, including why a bare Month filter spanning several
    // years is still correctly "live" whenever the current year's own
    // occurrence of that month hasn't finished yet).
    final currentMonthLabel = _currentFiscalMonthLabel(DateTime.now());
    final isLivePeriod = isYearGrain
        ? effectiveYear == currentFy
        : effectiveMonth == currentMonthLabel && (effectiveYear == null || effectiveYear == currentFy);

    // How many months' worth of average revenue a Year-grain Gap should be
    // measured against — every elapsed fiscal month if this is the current,
    // still-open fiscal year, or the full 12 for a year that's entirely in
    // the past. Same "avg × elapsed months" reasoning as the Dashboard's own
    // YTD coverage tile (Craig: "Multiply average by elapsed months"). Not
    // meaningful outside the Year-grain branch, so left at the
    // `_PerformanceData` default of 1 (a single month's Gap against one
    // month's average) for both Month-grain cases.
    int coveragePeriods = 1;
    if (isYearGrain) {
      if (effectiveYear == currentFy) {
        final fiscalMonths = fiscalMonthOrderFor(startMonth: startMonth);
        final currentFiscalMonthIndex = fiscalMonths.indexOf(currentMonthLabel);
        coveragePeriods = currentFiscalMonthIndex + 1;
      } else {
        coveragePeriods = 12;
      }
    }

    return _PerformanceData(
      rows: rows,
      names: results[1] as Map<String, String>,
      ownHistory: ownHistory,
      companyHistory: companyHistory,
      isLivePeriod: isLivePeriod,
      isYearGrain: isYearGrain,
      coveragePeriods: coveragePeriods,
    );
  }

  void _refetch() {
    // TEMPORARY — see _load()'s doc comment above.
    debugPrint('[PerformanceScreen] _refetch() called (ref.listen fired on a GlobalFilters change)');
    setState(() {
      _loadGeneration++;
      _future = _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    // ref.listen, not a manual diff-in-build + WidgetsBinding.
    // addPostFrameCallback — see document_analysis_view.dart's build() for
    // why that pattern was replaced (2026-08-26, Craig's branch filter bug
    // report).
    ref.listen<GlobalFilters>(globalFiltersProvider, (previous, next) => _refetch());
    // 2026-08-27 — RESTORED. Wyzesales_Rebuild_Decisions.md Section 18a
    // ("Branch filter not applying") explicitly documents that this screen
    // originally paired ref.listen (above) with this ref.watch, precisely
    // because it rendered its own Year/Month dropdowns straight from
    // GlobalFilters. When those dropdowns were dropped the same week ("drop
    // Year, Month" — see the comment on `_loadGeneration`'s State field),
    // `filters` became an unused local and this call was deleted along with
    // it — a plausible, easy-to-miss regression: nothing else in build()
    // needed the VALUE, so nobody noticed this line was also doing a second
    // job. Diagnosing Craig's "Year/Month set or cleared on this screen
    // itself doesn't filter" report now, and putting it back to match this
    // screen's own documented working configuration, discarding the value
    // since nothing here renders it anymore — the subscription/dependency
    // registration is the point, not the return value.
    ref.watch(globalFiltersProvider);

    return AppShell(
      title: 'Performance — ${widget.dimension.label}',
      currentRoute: '/performance/${widget.dimension.dbValue}',
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // 2026-08-27: Year/Month dropdowns dropped — Craig:
                // "Performance: drop Year, Month." Only the SalesDimension
                // switcher stays inline (it navigates between
                // /performance/:dimension routes, which isn't something
                // GlobalFilterBar's "Add filter" could do); setting Year or
                // Month now happens through GlobalFilterBar like every other
                // filter.
                BoxedDropdown<SalesDimension>(
                  value: widget.dimension,
                  width: 160,
                  items: SalesDimension.values.map((d) => DropdownMenuItem(value: d, child: Text(d.label))).toList(),
                  onChanged: (d) {
                    if (d != null && d != widget.dimension) context.go('/performance/${d.dbValue}');
                  },
                ),
                DataExportButtons(onExport: _buildExportData),
              ],
            ),
            const SizedBox(height: 16),
            Expanded(
              // key: ValueKey(_loadGeneration) — see _loadGeneration's own
              // doc comment above; forces a genuinely fresh AsyncSection
              // (and its internal FutureBuilder) on every refetch rather
              // than relying solely on FutureBuilder detecting the `future`
              // parameter changed.
              child: AsyncSection<_PerformanceData>(
                key: ValueKey(_loadGeneration),
                future: _future,
                isEmpty: (data) => data.rows.isEmpty,
                builder: (context, data) => _buildTable(context, data),
              ),
            ),
          ],
        ),
      ),
    );
  }

  int _compareRows(DimensionPerformance a, DimensionPerformance b, _PerformanceData data, int columnIndex) {
    switch (columnIndex) {
      case 0:
        return (data.names[a.entityCode] ?? a.entityCode).compareTo(data.names[b.entityCode] ?? b.entityCode);
      case 1:
        return (a.contributionPercent ?? 0).compareTo(b.contributionPercent ?? 0);
      case 2:
        return a.actualValue.compareTo(b.actualValue);
      case 3:
        return (a.targetValue ?? 0).compareTo(b.targetValue ?? 0);
      case 4:
        return (a.targetPercent ?? 0).compareTo(b.targetPercent ?? 0);
      case 5:
        return (data.coverageFor(a).rGap ?? 0).compareTo(data.coverageFor(b).rGap ?? 0);
      case 6:
        return (data.coverageFor(a).coveragePercent ?? 0).compareTo(data.coverageFor(b).coveragePercent ?? 0);
      case 7:
        return a.actualProfit.compareTo(b.actualProfit);
      case 8:
        return a.gpPercent.compareTo(b.gpPercent);
      case 9:
        return a.actualQuantity.compareTo(b.actualQuantity);
      default:
        return 0;
    }
  }

  void _onSort(int columnIndex, bool ascending) {
    setState(() {
      _sortColumnIndex = columnIndex;
      _sortAscending = ascending;
    });
  }

  /// Column header for the "R Gap" pair's second column — "% Coverage
  /// Needed" only when `isLivePeriod` (the filtered period is still
  /// actually in progress, so there's genuinely still time to close the
  /// gap); otherwise a purely descriptive, backward-looking framing for a
  /// period that's already closed — "% Below Avg Month" for a Month-grain
  /// view, or "% Below Avg Year" for a Year-only (year-grain) view. Craig,
  /// 2026-09-02, on seeing a closed FY2027/August row labelled "% Coverage
  /// Needed": "I don't think it can say % Coverage Needed for a past period
  /// as this makes no sense. You cannot catch it up." — confirmed "% Below
  /// Avg Month" as the past-period wording, then, once a Year-only filter's
  /// own past-period case came up, "% Below Avg Year" as its counterpart
  /// (same reasoning, different noun — a live current year still just says
  /// "% Coverage Needed," no year-specific wording needed there).
  String _coverageColumnLabel(bool isLivePeriod, bool isYearGrain) {
    if (isLivePeriod) return '% Coverage Needed';
    return isYearGrain ? '% Below Avg Year' : '% Below Avg Month';
  }

  /// The coverage cell's own text — see core/utils/sales_coverage.dart's
  /// CoverageResult doc comment for what each of the three non-percentage
  /// states means. "On Target" only applies to a still-open period (there's
  /// a real target left to hit); a closed period that met its target says
  /// "Met Target" instead, matching the same live/past distinction
  /// `_coverageColumnLabel` makes for the header. The trailing `*` on a
  /// fallback figure is explained by the italic caption `_buildTable`
  /// renders below the table whenever any row uses it (Craig, 2026-09-02:
  /// this "must be flagged/visible in the UI when this fallback is used").
  String _coverageText(CoverageResult coverage, bool isLivePeriod) {
    if (coverage.onTarget) return isLivePeriod ? 'On Target' : 'Met Target';
    if (coverage.insufficientData) return '—';
    final pct = formatPercent(coverage.coveragePercent);
    return coverage.usedFallback ? '$pct *' : pct;
  }

  /// Color for the R Gap / % Coverage Needed cells (both share one color per
  /// row) — Craig, 2026-09-02, asking for these to be colored "to make them
  /// more understandable," e.g. "Johan Botha should be green, Mark Fischer I
  /// guess should be red." Confirmed thresholds (AskUserQuestion): On Target
  /// or under 25% coverage needed is green (a small ask relative to a
  /// typical month), 25-50% is amber (a meaningful chunk of a typical month),
  /// over 50% is red (more than half a typical month's revenue still
  /// needed). `insufficientData` (no target set, or no usable average even
  /// after falling back to the company) gets the same neutral/muted color
  /// every other tile in this app uses for "nothing meaningful to show."
  Color _coverageColor(BuildContext context, CoverageResult coverage) {
    if (coverage.insufficientData) return Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6);
    if (coverage.onTarget) return AppColors.positive;
    final pct = coverage.coveragePercent ?? 0;
    if (pct < 25) return AppColors.positive;
    if (pct <= 50) return AppColors.caution;
    return AppColors.negative;
  }

  Widget _buildTable(BuildContext context, _PerformanceData data) {
    final rows = [...data.rows]..sort((a, b) {
      final cmp = _compareRows(a, b, data, _sortColumnIndex);
      return _sortAscending ? cmp : -cmp;
    });
    final anyFallback = rows.any((r) => data.coverageFor(r).usedFallback);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: ResponsiveDataTable(
            sortColumnIndex: _sortColumnIndex,
            sortAscending: _sortAscending,
            // Totals is rows[0] only when there's at least one row (see the
            // `if (rows.isNotEmpty) _totalsRow(...)` below) — pinning follows
            // the same condition, otherwise there'd be nothing there to
            // freeze (2026-08-27, Craig: "lock the Headers and Totals so we
            // don't lose them when scrolling down").
            pinnedRowCount: rows.isNotEmpty ? 1 : 0,
            columns: [
              DataColumn(label: Text(widget.dimension.label), onSort: _onSort),
              DataColumn(label: const Text('% Contribution'), numeric: true, onSort: _onSort),
              DataColumn(label: const Text('R Value'), numeric: true, onSort: _onSort),
              DataColumn(label: const Text('R Target'), numeric: true, onSort: _onSort),
              DataColumn(label: const Text('% Target'), numeric: true, onSort: _onSort),
              DataColumn(label: const Text('R Gap'), numeric: true, onSort: _onSort),
              DataColumn(label: Text(_coverageColumnLabel(data.isLivePeriod, data.isYearGrain)), numeric: true, onSort: _onSort),
              DataColumn(label: const Text('R Profit'), numeric: true, onSort: _onSort),
              DataColumn(label: const Text('% GP'), numeric: true, onSort: _onSort),
              DataColumn(label: const Text('Quantity'), numeric: true, onSort: _onSort),
            ],
            rows: [
              if (rows.isNotEmpty) _totalsRow(context, rows, data),
              ...rows.map((row) {
                final coverage = data.coverageFor(row);
                final coverageColor = _coverageColor(context, coverage);
                final gpColor = row.actualProfit < 0 ? Theme.of(context).colorScheme.error : null;
                return DataRow(cells: [
                  DataCell(Text(data.names[row.entityCode] ?? row.entityCode)),
                  DataCell(Text(formatPercent(row.contributionPercent))),
                  DataCell(Text(formatRand(row.actualValue))),
                  DataCell(Text(formatRand(row.targetValue))),
                  DataCell(Text(formatPercent(row.targetPercent))),
                  DataCell(Text(formatRand(coverage.rGap), style: TextStyle(color: coverageColor))),
                  DataCell(Text(_coverageText(coverage, data.isLivePeriod), style: TextStyle(color: coverageColor))),
                  DataCell(Text(formatRand(row.actualProfit), style: TextStyle(color: gpColor))),
                  DataCell(Text(formatPercent(row.gpPercent), style: TextStyle(color: gpColor))),
                  DataCell(Text(formatQuantity(row.actualQuantity))),
                ]);
              }),
            ],
          ),
        ),
        if (anyFallback)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '* using company-wide average — under 3 months of this entity\'s own sales history',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic),
            ),
          ),
      ],
    );
  }

  /// Bold, pinned as the FIRST row (2026-08-27, Craig: "Does it make sense
  /// to have the Totals as the first line in a view?" — confirmed yes,
  /// app-wide) rather than the last, unaffected by the active column sort
  /// either way since it's built from `rows` before the sort reorders the
  /// entity rows below it. %Contribution is the one column here that's
  /// correct to sum plainly
  /// rather than recompute: each row's contribution is already "this
  /// entity's share of the company total," so the shares add back up to
  /// (approximately) 100% on their own. %Target and %GP are NOT that kind
  /// of figure — each is a ratio specific to one entity — so those two are
  /// recomputed from the totalled Rand columns instead (a correct weighted
  /// average, not a simple average of every entity's own percentage).
  ///
  /// R Gap totals the same way (totalTarget - totalValue, a plain sum — Gap
  /// is already additive, unlike a percentage). % Coverage Needed for the
  /// Total row treats the summed figures as the company's own — passing
  /// `data.companyHistory` as BOTH `own` and `company` to computeCoverage,
  /// so the <3-active-months fallback never fires here (a real client's
  /// company-wide history essentially always clears that bar once it has any
  /// sales on record) and the result is simply the company's own coverage
  /// figure for this period, not any one entity's.
  DataRow _totalsRow(BuildContext context, List<DimensionPerformance> rows, _PerformanceData data) {
    final totalContribution = rows.fold<num>(0, (sum, r) => sum + (r.contributionPercent ?? 0));
    final totalValue = rows.fold<num>(0, (sum, r) => sum + r.actualValue);
    final totalTarget = rows.fold<num>(0, (sum, r) => sum + (r.targetValue ?? 0));
    final totalProfit = rows.fold<num>(0, (sum, r) => sum + r.actualProfit);
    final totalQuantity = rows.fold<num>(0, (sum, r) => sum + r.actualQuantity);
    final totalTargetPercent = totalTarget == 0 ? null : (totalValue / totalTarget) * 100;
    final totalGpPercent = totalValue == 0 ? null : (totalProfit / totalValue) * 100;
    final totalCoverage = computeCoverage(
      targetValue: totalTarget == 0 ? null : totalTarget,
      actualValue: totalValue,
      own: data.companyHistory,
      company: data.companyHistory,
      periods: data.coveragePeriods,
    );
    const style = TextStyle(fontWeight: FontWeight.bold);
    final gpColor = totalProfit < 0 ? Theme.of(context).colorScheme.error : null;
    final coverageColor = _coverageColor(context, totalCoverage);
    return DataRow(
      color: WidgetStatePropertyAll(Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.04)),
      cells: [
        const DataCell(Text('Total', style: style)),
        DataCell(Text(formatPercent(totalContribution), style: style)),
        DataCell(Text(formatRand(totalValue), style: style)),
        DataCell(Text(formatRand(totalTarget), style: style)),
        DataCell(Text(formatPercent(totalTargetPercent), style: style)),
        DataCell(Text(formatRand(totalCoverage.rGap), style: style.copyWith(color: coverageColor))),
        DataCell(Text(_coverageText(totalCoverage, data.isLivePeriod), style: style.copyWith(color: coverageColor))),
        DataCell(Text(formatRand(totalProfit), style: style.copyWith(color: gpColor))),
        DataCell(Text(formatPercent(totalGpPercent), style: style.copyWith(color: gpColor))),
        DataCell(Text(formatQuantity(totalQuantity), style: style)),
      ],
    );
  }

  /// Same 10 columns as _buildTable, same totals-row weighted-ratio
  /// recomputation as _totalsRow (see that method's own doc comment for why
  /// %Target/%GP aren't simply averaged, and how the Total row's own R Gap/%
  /// Coverage Needed are derived) — built from whatever `_future` already
  /// resolved to, since this screen (unlike DocumentAnalysisView) holds its
  /// full per-dimension result set in memory rather than one paginated page,
  /// so there's no extra "fetch everything" fetch needed here.
  Future<ExportData> _buildExportData() async {
    final data = await _future;
    final rows = data.rows;
    final headers = [
      widget.dimension.label,
      '% Contribution',
      'R Value',
      'R Target',
      '% Target',
      'R Gap',
      _coverageColumnLabel(data.isLivePeriod, data.isYearGrain),
      'R Profit',
      '% GP',
      'Quantity',
    ];
    final dataRows = <List<String>>[];
    if (rows.isNotEmpty) {
      final totalContribution = rows.fold<num>(0, (sum, r) => sum + (r.contributionPercent ?? 0));
      final totalValue = rows.fold<num>(0, (sum, r) => sum + r.actualValue);
      final totalTarget = rows.fold<num>(0, (sum, r) => sum + (r.targetValue ?? 0));
      final totalProfit = rows.fold<num>(0, (sum, r) => sum + r.actualProfit);
      final totalQuantity = rows.fold<num>(0, (sum, r) => sum + r.actualQuantity);
      final totalTargetPercent = totalTarget == 0 ? null : (totalValue / totalTarget) * 100;
      final totalGpPercent = totalValue == 0 ? null : (totalProfit / totalValue) * 100;
      final totalCoverage = computeCoverage(
        targetValue: totalTarget == 0 ? null : totalTarget,
        actualValue: totalValue,
        own: data.companyHistory,
        company: data.companyHistory,
        periods: data.coveragePeriods,
      );
      dataRows.add([
        'Total',
        formatPercent(totalContribution),
        formatRand(totalValue),
        formatRand(totalTarget),
        formatPercent(totalTargetPercent),
        formatRand(totalCoverage.rGap),
        _coverageText(totalCoverage, data.isLivePeriod),
        formatRand(totalProfit),
        formatPercent(totalGpPercent),
        formatQuantity(totalQuantity),
      ]);
    }
    for (final row in rows) {
      final coverage = data.coverageFor(row);
      dataRows.add([
        data.names[row.entityCode] ?? row.entityCode,
        formatPercent(row.contributionPercent),
        formatRand(row.actualValue),
        formatRand(row.targetValue),
        formatPercent(row.targetPercent),
        formatRand(coverage.rGap),
        _coverageText(coverage, data.isLivePeriod),
        formatRand(row.actualProfit),
        formatPercent(row.gpPercent),
        formatQuantity(row.actualQuantity),
      ]);
    }
    return ExportData(
      headers: headers,
      rows: dataRows,
      fileNameBase: 'performance_${widget.dimension.dbValue}',
      title: 'Performance — ${widget.dimension.label}',
    );
  }
}
