import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/app_providers.dart';
import '../../../core/constants/fiscal.dart';
import '../../../core/filters/global_filters.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/utils/dimension_ranking.dart';
import '../../../core/utils/sales_coverage.dart';
import '../../../core/utils/target_overlay.dart';
import '../../../data/models/budget_figure.dart';
import '../../../data/models/consolidated_sales.dart';
import '../../../data/models/dimension_monthly_sales.dart';
import '../../../data/models/profile.dart';
import '../../../data/models/sales_document.dart';
import '../../../data/models/sales_forecast_figure.dart';
import '../../../shared/widgets/app_shell.dart';
import '../../../shared/widgets/async_section.dart';
import '../../../shared/widgets/simple_pie_chart.dart';
import '../../../shared/widgets/toggle_stat_card.dart';
import '../../../shared/widgets/boxed_dropdown.dart';
import '../../../shared/widgets/value_gp_toggle.dart';

/// Every KPI tile in the Dashboard's 6-tile row is held to this exact
/// height (2026-08-27, Craig: "The tiles all need to be the same size as
/// well") via `_KpiTileGrid` below, not left to size itself off its own
/// content — which is what let one tile (Revenue Target Attainment, with a
/// longer subtitle) come out visibly taller than the rest before this fix.
/// Sized generously enough that a 2-line label, the always-reserved toggle
/// row, a 2-line value, and a 2-line subtitle all fit without truncating —
/// see ToggleStatCard's own doc comment for the exact vertical budget this
/// height covers, and Wyzesales_Rebuild_Decisions.md for the full story.
///
/// Shrunk 2026-08-28 (190 -> 150) alongside ToggleStatCard's own
/// toggle-shrinking and padding cuts (Craig: "halve the size of the toggles
/// ... remove the unnecessary white space on the tiles") — safe to shrink
/// now that "Revenue & Gross Profit" (the one tile with a 2-line compound
/// Rand value, e.g. "R 1,475,556 · R 469,790") is gone, replaced by Returns
/// / Credit Note Rate, whose value is always a short single-line
/// percentage. Nudged from an initial 145 up to 150 once the toggle itself
/// came back up from 12px to 20px (Craig: "The MTD / YTD text does not fit
/// into the toggle!") — see ToggleStatCard's own doc comment for the
/// vertical budget this height covers.
///
/// There's no matching `_kpiTileWidth` any more (2026-08-28) — tiles used
/// to sit at a fixed width inside a `Wrap`, but `_KpiTileGrid` now stretches
/// each tile to fill an equal share of its row instead, so only the height
/// stays fixed.
const double _kpiTileHeight = 150;

/// Below this width, `_KpiTileGrid` drops from 3 columns to 2 (Craig,
/// 2026-08-28: "does it perhaps make sense to have two rows of three
/// each?" — followed by asking how that holds up on a narrower window,
/// since 3 tiles across get cramped below a certain point). Deliberately
/// reuses the exact threshold `AppShell` already uses to collapse its
/// sidebar into a drawer, and that this same screen already uses further
/// down for its rankings grid (2 columns vs 1) — one width decision for the
/// whole app to reason about, not a third bespoke breakpoint.
const double _kpiGridBreakpoint = 900;

enum _RankMode {
  top5('Top 5'),
  bottom5('Bottom 5'),
  diminishing5('Diminishing 5'),
  growth5('Growth 5');

  const _RankMode(this.label);
  final String label;
}

/// Actual vs Target, MTD/YTD — read by the KPI row's Revenue Target
/// Attainment tile. Despite the name (kept to avoid a wider rename — this
/// used to always be whole-company), this is no longer always the literal
/// company total: 2026-09-04, Craig reported "I have selected a sales
/// person but it is still showing Company Wide. If I log in as a Sales
/// Person then it is correct" — this used to resolve its scope from
/// `defaultTargetScope(profile)` alone (the SIGNED-IN user's own level),
/// completely ignoring whatever global dimension filter an admin had
/// manually picked on screen. Now resolves via `_effectiveScope` (see its
/// own doc comment) instead: a single active global filter (e.g. Sales
/// Person: Sarah Naidoo) wins over the viewer's own default scope, so an
/// admin picking a rep sees THAT rep's actual vs target, same as if that
/// rep were signed in themselves. Falls back to the old whole-
/// viewer's-own-scope behavior when no filter is active (unchanged) or when
/// 2+ are stacked at once — budget_figures has no per-dimension breakdown
/// for a combined filter (the same reason a `company` row never had a
/// Branch/Customer/etc split), so comparing an over-narrowed Actual against
/// an unfiltered Target would be worse than just falling back — see
/// `_fetchWholeCompanyTarget`'s own doc comment for the full reasoning.
class _WholeCompanyTarget {
  final num actualMtd;
  final num actualYtd;
  final num targetMtd;
  final num targetYtd;
  const _WholeCompanyTarget({required this.actualMtd, required this.actualYtd, required this.targetMtd, required this.targetYtd});
}

/// 2026-08-27 — grew from 4 plain fields (Sales/GP MTD/YTD) to the full data
/// set behind the Dashboard's 6-tile KPI row, after Craig asked "What do you
/// think are the 5 kpi's that need to be on a sales analysis dashboard,"
/// reviewed a mockup, and said "Go ahead and build this please." See
/// Wyzesales_Rebuild_Decisions.md for the full narrative — this class just
/// holds what every tile needs, computed once per load/refresh.
class _KpiData {
  final num salesMtd;
  final num salesYtd;
  final num profitMtd;
  final num profitYtd;

  // Revenue Target Attainment reads these — see _WholeCompanyTarget's doc
  // comment for what scope these actually resolve to (no longer always
  // whole-company, despite the field names), and _fetchWholeCompanyTarget's
  // doc comment for the one call site that computes them.
  final num companyActualMtd;
  final num companyActualYtd;
  final num companyTargetMtd;
  final num companyTargetYtd;

  // Sales Coverage (task #93/#103, replaced the Quote → Order Conversion
  // tile 2026-09-02 — see Wyzesales_Rebuild_Decisions.md Section 55 for why:
  // quotes/sales orders are never reliably captured anywhere in WCSA's data,
  // not even in their own daily-use IQRetail application). `companyActualMtd`
  // /`companyActualYtd`/`companyTargetMtd`/`companyTargetYtd` above already
  // carry everything needed for the Gap side of the calc.
  //
  // 2026-09-03 correction: this used to carry a single
  // `companyAvgRevenuePerPeriod` fetched with `dimension: 'company'` always
  // — copied from this tile's original 2026-09-02 build, one day before
  // Craig's "the dashboard must be specific" scoping rule (Section 68/the
  // `companyActualMtd` fields above) landed and was never propagated here.
  // The result: for a User or RegUser login, the Gap (their own, correctly
  // scoped, per `defaultTargetScope`) was being divided by the WHOLE
  // COMPANY's average revenue per period, not their own — Johan, with a real
  // R170,005 MTD gap, saw "Sales Coverage 34.6%" because his gap was tiny
  // relative to the whole company's average, not his own. Now carries the
  // same `own`/`company` pair Performance Analysis' identical calc already
  // uses (`computeCoverage`, core/utils/sales_coverage.dart) — `own` is the
  // viewer's own scoped history (their rep/branch/company, matching
  // `defaultTargetScope`), `company` is the fallback used only when `own`
  // has under `kMinActiveMonthsForOwnAverage` months of history (or doesn't
  // exist at all). `elapsedMonthsYtd` is how many fiscal months of the
  // current year have actually elapsed — YTD's Gap covers that many months
  // at once, so the YTD calc scales the average by this count rather than
  // treating it as if it were a single month's Gap (Craig, 2026-09-02,
  // confirming how to scale YTD: "Multiply average by elapsed months").
  final EntitySalesHistory? ownSalesHistory;
  final EntitySalesHistory? companySalesHistory;
  final int elapsedMonthsYtd;

  // Top 5 Customer Concentration.
  final num top5CustomerValueMtd;
  final num totalCustomerValueMtd;
  final int top5CustomerCountMtd; // min(5, distinct customers with activity)
  final num top5CustomerValueYtd;
  final num totalCustomerValueYtd;
  final int top5CustomerCountYtd;

  // Rep Target Attainment — whole roster (every rep with a target this
  // period) by default, since budget_figures carries no per-Branch/
  // Category/etc split on top of the rep themselves for the other 4
  // dashboard filters to narrow by. 2026-09-04: when a Sales Person filter
  // IS active, `_loadKpis` narrows these four down to that one rep (1 of 1 /
  // 0 of 1) instead — see the "narrow to the filtered rep" block in
  // `_loadKpis` for why a Sales Person filter specifically gets this
  // treatment when the other 4 don't.
  final int repsAtTargetMtd;
  final int repsTotalMtd;
  final int repsAtTargetYtd;
  final int repsTotalYtd;

  // Returns / Credit Note Rate — 2026-08-28, Craig: replaces the old
  // "Revenue & Gross Profit" tile ("it is repetitive" — Gross Profit Margin
  // already shows the same two underlying figures). `creditNoteMtd`/
  // `creditNoteYtd` are stored as positive magnitudes (credit notes are
  // negative in sales_document_facts, since v_consolidated_sales relies on
  // that sign to net them against invoices for Actual Revenue) — the ratio
  // is computed as creditNote/grossInvoiced at display time.
  final num grossInvoicedMtd;
  final num creditNoteMtd;
  final num grossInvoicedYtd;
  final num creditNoteYtd;

  const _KpiData({
    required this.salesMtd,
    required this.salesYtd,
    required this.profitMtd,
    required this.profitYtd,
    required this.companyActualMtd,
    required this.companyActualYtd,
    required this.companyTargetMtd,
    required this.companyTargetYtd,
    required this.ownSalesHistory,
    required this.companySalesHistory,
    required this.elapsedMonthsYtd,
    required this.top5CustomerValueMtd,
    required this.totalCustomerValueMtd,
    required this.top5CustomerCountMtd,
    required this.top5CustomerValueYtd,
    required this.totalCustomerValueYtd,
    required this.top5CustomerCountYtd,
    required this.repsAtTargetMtd,
    required this.repsTotalMtd,
    required this.repsAtTargetYtd,
    required this.repsTotalYtd,
    required this.grossInvoicedMtd,
    required this.creditNoteMtd,
    required this.grossInvoicedYtd,
    required this.creditNoteYtd,
  });
}

/// Every monthly row for the currently-selected dimension, across the
/// current and prior fiscal year — enough for both the MTD pie (this month
/// vs last calendar month) and the YTD pie (this FY-to-date vs the same
/// elapsed months last FY) to be derived client-side with no further
/// network round trips, the same way switching R Value/Gross Profit or the
/// Top 5/Bottom 5/Diminishing 5/Growth 5 selector doesn't refetch either.
class _DimensionRawData {
  final List<DimensionMonthlySales> rows;
  final Map<String, String> names;
  final int fiscalYear;
  const _DimensionRawData({required this.rows, required this.names, required this.fiscalYear});
}

class _EntityPeriod {
  final num value;
  final num profit;
  const _EntityPeriod(this.value, this.profit);
}

/// Whole-company KPI row, then an interactive breakdown: pick a dimension
/// and a Top 5/Bottom 5/Diminishing 5/Growth 5 selection, see it as two
/// donut charts (MTD, YTD), click a segment to drill into that entity on
/// the Sales By screen
/// (Wyzesales_Screens_and_Recommendations.md Section 1; rebuilt 2026-08-26
/// per Craig's request to replace the old 8-bar-chart grid).
///
/// R Value/Gross Profit and the rank-mode/dimension pickers never refetch —
/// only switching *dimension* does, since that's the only thing that
/// actually needs different rows from the server; everything else is a
/// pure client-side re-derivation of data already in memory. This was the
/// actual fix for "I don't see why the whole screen needs to disappear /
/// refresh when flipping between R Value and Gross Profit" (2026-08-26):
/// the old code reassigned the screen's one big Future on every toggle,
/// which sent the entire body back through AsyncSection's loading state.
class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  late Future<_KpiData> _kpiFuture;

  // 2026-09-03: guards against the profile-loaded listener (see build())
  // firing a second, fully-overlapping ~10-query KPI batch while the
  // initial one from initState is still in flight — see that listener's
  // own doc comment for why overlapping batches are a real problem here
  // (this screen's RLS performance gap, Wyzesales_Rebuild_Decisions.md
  // Section 62), not just wasted duplicate work. `true` from construction
  // until the very first _loadKpis() call settles.
  bool _initialKpiLoadInFlight = true;
  bool _profileReloadQueued = false;

  ValueMeasure _measure = ValueMeasure.rValue;
  SalesDimension _dimension = SalesDimension.customer;
  _RankMode _rankMode = _RankMode.top5;

  _DimensionRawData? _dimensionData;
  bool _dimensionLoading = false;
  String? _dimensionError;

  /// The active dimension filters, with Year/Month stripped — the KPI row
  /// and pies are already "as of right now" (MTD/YTD relative to today), so
  /// a global Year/Month filter has no well-defined meaning on this screen;
  /// only the 5 dimension filters (including Customer) are passed through.
  ///
  /// 2026-08-27: briefly excluded Customer too, on a misreading of Craig's
  /// "Dashboard: drop Customer Filter" — he clarified that a global Customer
  /// filter (e.g. one set via the top-bar search) SHOULD still filter this
  /// screen's KPIs/pies like every other dimension filter does; "reinsert
  /// this." Reverted the same day. Whatever "drop Customer Filter" actually
  /// referred to, it wasn't this.
  GlobalFilters _dashboardFilters(GlobalFilters filters) => filters.copyWith(fiscalYear: null, fiscalMonth: null);

  @override
  void initState() {
    super.initState();
    _kpiFuture = _loadKpis()
      ..whenComplete(() {
        _initialKpiLoadInFlight = false;
        // Same `mounted` guard _loadDimension's own post-await continuation
        // already uses just below — the user may have navigated away before
        // this settles, and calling _refresh() (setState/ref.invalidate)
        // after disposal would throw.
        if (!mounted) return;
        // The profile finished loading WHILE the initial batch was still in
        // flight, and the listener below deliberately held off rather than
        // firing a second overlapping batch — run that deferred refresh now
        // that it's safe to.
        if (_profileReloadQueued) {
          _profileReloadQueued = false;
          _refresh();
        }
      });
    // Direct field write, not setState — this seeds the very first build
    // that's already about to happen when initState returns. Calling
    // setState() here (even indirectly, via the synchronous prefix of an
    // async method before its first await) trips Flutter's "setState()
    // called during build" assertion, since initState itself runs inside
    // the same locked build pass that mounts this widget. _loadDimension
    // below only ever calls setState from its post-await continuations and
    // from event handlers (_onDimensionChanged/_refresh) — never from here.
    _dimensionLoading = true;
    _loadDimension();
  }

  /// Resolves which single (dimension, entityCode) pair Revenue Target
  /// Attainment and Sales Coverage's own-history baseline should measure
  /// against — 2026-09-04, fixing Craig's report that these tiles ignored a
  /// manually applied global filter (see `_fetchWholeCompanyTarget`'s own
  /// doc comment for the full story). Reuses the exact same
  /// `singleActiveDimensionFilter` mechanism Sales Analysis's own Target
  /// overlay already established for this identical problem
  /// (target_overlay.dart, sales_analysis_screen.dart's `_loadTargetBars`) —
  /// a single active filter (exactly one of the 5 filterable dimensions)
  /// wins over the viewer's own `defaultTargetScope`; zero or 2+ active
  /// filters fall back to `defaultTargetScope` unchanged, same as before
  /// this fix.
  ({SalesDimension dimension, String entityCode}) _effectiveScope(GlobalFilters filters) {
    final single = singleActiveDimensionFilter(filters);
    if (single != null) return (dimension: single.dimension, entityCode: single.selection.code);
    return defaultTargetScope(ref.read(sessionProvider).value);
  }

  /// Actual (v_consolidated_sales) vs Target (budget_figures) numbers for
  /// the KPI row's Revenue Target Attainment tile (`_KpiData.companyActualMtd`
  /// /etc. — field names kept even though this is no longer always
  /// whole-company, see below, to avoid a wider rename across every reader
  /// of `_KpiData`). Used to be called a second time by a separate
  /// `_loadTargetChart` method, kept in sync as a shared fetch+compute
  /// helper so the two independently-timed loaders (the KPI row and the
  /// "Actual Revenue vs Sales Target" bar chart underneath it) never
  /// disagreed — that chart was removed 2026-08-28 (Section 32 of
  /// Wyzesales_Rebuild_Decisions.md), so this is back down to the one
  /// caller and the one round trip its name always implied.
  ///
  /// The TARGET side used to always be dimension='company' regardless of
  /// who was looking — Craig, 2026-09-03, once a plain 'user' login showed
  /// "R 8,780 of R 0 target": schema/018 (2026-09-01) already hides the
  /// 'company' dimension from User/RegUser, silently breaking this tile for
  /// every non-admin login since it shipped. Rather than widening access to
  /// the literal whole-company figure, Craig's answer was "The dashboard
  /// must be specific. i.e. User sees only their info. RegUsers sees their
  /// branch and Admin sees everything" — so the target now comes from
  /// `defaultTargetScope` (core/utils/target_overlay.dart, shared with Sales
  /// Analysis' own default-view fix), which resolves to the CALLER'S own
  /// rep/branch/company target depending on their profile level. The ACTUAL
  /// side needed no change at all — `fetchConsolidatedSales` already reads
  /// an RLS-scoped view, so it was always naturally "my own visible revenue"
  /// for a User, "my branch's" for a RegUser, and the true company total
  /// only for an Admin; only the target side was ever hardcoded.
  ///
  /// Also now falls back to `sales_forecast` via `resolveTarget` when there's
  /// no real `budget_figures` value (2026-09-03, found retesting Section 62:
  /// after `defaultTargetScope` landed, Johan's own tile still read "R 0
  /// target" even though "he does have a sales target" — this method never
  /// read `sales_forecast` at all, only `budget_figures`, so a rep whose
  /// September figure exists only as a forecast (not a manually-entered
  /// budget) showed 0 here while Sales Analysis's Target overlay — which
  /// already does this same `resolveTarget` fallback, Section 62 — showed
  /// the real number for the exact same rep/month). Same gap existed for
  /// Rep Target Attainment below, fixed the same way.
  ///
  /// 2026-09-04: `scope` used to come from `defaultTargetScope(profile)`
  /// alone — the SIGNED-IN user's own level — with no way for a manually
  /// applied global dimension filter to ever change it. Craig: "I have
  /// selected a sales person but it is still showing Company Wide. If I log
  /// in as a Sales Person then it is correct" — exactly this: an admin's own
  /// `defaultTargetScope` is always `company`, so picking Sales Person:
  /// Sarah Naidoo on the filter bar had zero effect here even though it
  /// correctly narrowed Gross Profit Margin and the Customer pies right next
  /// to it. `scope` now comes from `_effectiveScope` (see its own doc
  /// comment) — a single active global filter wins over the viewer's own
  /// default scope. The ACTUAL side follows the same rule via
  /// `actualFilters`: when a single filter is driving `scope`, that filter
  /// is applied here too (so Actual and Target measure the SAME entity);
  /// with zero filters active, `actualFilters` stays null and RLS alone
  /// scopes it to the viewer's own visible rows, unchanged from before. With
  /// 2+ filters stacked, `scope` has already fallen back to the viewer's own
  /// default (see `_effectiveScope`), so `actualFilters` falls back to null
  /// too here — there's no real entered target for a combined filter
  /// (budget_figures is keyed by one dimension at a time), and comparing an
  /// over-narrowed Actual against an unfiltered Target would be worse than
  /// this fallback. Sales Analysis's Graph tab handles that same 2+ filter
  /// case with a full proportional-share derivation
  /// (`deriveHierarchicalTarget`, target_overlay.dart) — worth reusing here
  /// too if stacking filters on the Dashboard turns out to be a common real
  /// workflow, but that's a bigger mechanism than this compact KPI tile
  /// needs today.
  Future<_WholeCompanyTarget> _fetchWholeCompanyTarget(int currentFiscalYear, DateTime monthStart, GlobalFilters filters) async {
    final scope = _effectiveScope(filters);
    final actualFilters = singleActiveDimensionFilter(filters) != null ? filters : null;
    final results = await Future.wait([
      ref.read(salesRepositoryProvider).fetchConsolidatedSales(fiscalYears: [currentFiscalYear], filters: actualFilters),
      ref.read(budgetRepositoryProvider).fetchBudget(dimension: scope.dimension.dbValue, entityCode: scope.entityCode),
      ref.read(budgetRepositoryProvider).fetchForecast(dimension: scope.dimension.dbValue, entityCode: scope.entityCode),
    ]);
    final consolidatedRows = results[0] as List<ConsolidatedSales>;
    final budgetRows = results[1] as List<BudgetFigure>;
    final forecastRows = results[2] as List<SalesForecastFigure>;

    num actualMtd = 0, actualYtd = 0;
    for (final row in consolidatedRows) {
      actualYtd += row.value;
      if (row.month.year == monthStart.year && row.month.month == monthStart.month) {
        actualMtd += row.value;
      }
    }

    final budgetByMonth = <String, num>{};
    for (final row in budgetRows) {
      budgetByMonth[row.fiscalMonth] = (budgetByMonth[row.fiscalMonth] ?? 0) + row.budgetValue;
    }
    final forecastByMonth = <String, num>{};
    for (final row in forecastRows) {
      forecastByMonth[row.fiscalMonth] = (forecastByMonth[row.fiscalMonth] ?? 0) + row.forecastValue;
    }
    final targetByMonth = <String, num>{
      for (final month in {...budgetByMonth.keys, ...forecastByMonth.keys})
        month: resolveTarget(budgetValue: budgetByMonth[month], forecastValue: forecastByMonth[month]) ?? 0,
    };
    final currentMonthLabel = fiscalMonthLabelFor(monthStart);
    final elapsedMonthLabels = consolidatedRows.map((r) => fiscalMonthLabelFor(r.month)).toSet();
    final targetMtd = targetByMonth[currentMonthLabel] ?? 0;
    final targetYtd = elapsedMonthLabels.fold<num>(0, (sum, label) => sum + (targetByMonth[label] ?? 0));

    return _WholeCompanyTarget(actualMtd: actualMtd, actualYtd: actualYtd, targetMtd: targetMtd, targetYtd: targetYtd);
  }

  Future<_KpiData> _loadKpis() async {
    final now = DateTime.now();
    final startMonth = ref.read(fiscalYearStartMonthProvider).valueOrNull ?? 3;
    final currentFiscalYear = fiscalYearFor(now, startMonth: startMonth);
    final monthStart = firstOfMonth(now);
    final currentMonthLabel = fiscalMonthLabelFor(monthStart);
    final fiscalMonths = fiscalMonthOrderFor(startMonth: startMonth);
    final currentFiscalMonthIndex = fiscalMonths.indexOf(currentMonthLabel);
    // Every fiscal month up to and including the current one — the same
    // "has this month actually happened yet" boundary sales_analysis_screen
    // and ytd_comparative_screen already use for their own YTD sums, reused
    // here for Rep Target Attainment's YTD roster/total.
    final elapsedFiscalMonths = fiscalMonths.sublist(0, currentFiscalMonthIndex + 1).toSet();

    // Whole-company totals for the Sales/GP tiles — pulled from
    // v_consolidated_sales (the same source Sales Analysis' Graph tab
    // uses), not a sum of the per-dimension top-5s below, which would
    // under-count once an entity falls outside the top 5. `filters`
    // narrows this to whatever global dimension filters are active (e.g.
    // Branch=Cape Town) — see _dashboardFilters' doc comment for why
    // Year/Month aren't included.
    final filters = _dashboardFilters(ref.read(globalFiltersProvider));
    final salesRepo = ref.read(salesRepositoryProvider);

    // Sales Coverage's historical average revenue per period — trailing
    // 3/5-year window, same `fiscalYearWindow` convention Performance
    // Analysis uses for the identical per-entity calc
    // (core/utils/sales_coverage.dart).
    //
    // 2026-09-04: this now goes through `_effectiveScope` — a single active
    // global filter (e.g. Sales Person: Sarah Naidoo) wins over the viewer's
    // own scope, same fix and same reasoning as `_fetchWholeCompanyTarget`'s
    // own doc comment. schema/023's own header comment already frames
    // Coverage as a per-entity measure (it mirrors Performance Analysis'
    // identical per-row column there) — the OLD "deliberately not narrowed
    // by filters" reasoning here was really just inherited from
    // companyActualMtd/companyTargetMtd's own (since-fixed) bug, not an
    // independent design decision, so there's nothing worth preserving by
    // keeping this un-narrowed once that bug is fixed.
    //
    // 2026-09-03: this reads the RESOLVED scope's own history rather than
    // always `dimension: 'company'` — see `_KpiData.ownSalesHistory`'s doc
    // comment for why the old always-company version was wrong for any
    // non-admin login. When the resolved scope IS `company` (no filter
    // active and an Admin is looking), the "own" fetch would just be a
    // second, redundant copy of the exact same query — skipped entirely,
    // reusing the company row as `own` too (see the `coverageScope.dimension
    // == SalesDimension.company` check below).
    final historyYears = ref.read(fiscalYearHistoryYearsProvider).valueOrNull ?? 3;
    final historyWindow = fiscalYearWindow(currentFiscalYear, historyYears);
    final coverageScope = _effectiveScope(filters);

    final results = await Future.wait([
      salesRepo.fetchConsolidatedSales(fiscalYears: [currentFiscalYear], filters: filters),
      _fetchWholeCompanyTarget(currentFiscalYear, monthStart, filters),
      salesRepo.fetchSalesHistory(dimension: 'company', fiscalYears: historyWindow),
      salesRepo.fetchDimensionMonthlySales(
        dimension: SalesDimension.customer,
        fiscalYears: [currentFiscalYear],
        filters: filters,
      ),
      // Rep Target Attainment's own roster fetch is always whole-roster,
      // unfiltered — narrowing down to one rep (when a Sales Person filter
      // is active) happens AFTER these results come back, by picking that
      // one rep out of the roster rather than querying differently — see
      // the "narrow to the filtered rep" block below. See _KpiData's own
      // doc comment for why the other 4 dashboard filters don't narrow this
      // tile the way they do the rest of the row.
      ref.read(budgetRepositoryProvider).fetchBudget(dimension: 'sales_person'),
      salesRepo.fetchDimensionMonthlySales(dimension: SalesDimension.salesPerson, fiscalYears: [currentFiscalYear]),
      // Returns / Credit Note Rate — invoice and credit_note totals fetched
      // SEPARATELY (fn_sales_documents_totals aggregates every document_kind
      // passed to it into one combined row, it doesn't split by kind), so
      // this is 4 small calls rather than 1: invoice/credit_note x MTD/YTD.
      salesRepo.fetchSalesDocumentsTotals(
        documentKinds: const ['invoice'],
        fiscalYear: currentFiscalYear,
        fiscalMonth: currentMonthLabel,
        categoryCode: filters.category?.code,
        itemCode: filters.item?.code,
        repCode: filters.salesPerson?.code,
        branchCode: filters.branch?.code,
        customerCode: filters.customer?.code,
      ),
      salesRepo.fetchSalesDocumentsTotals(
        documentKinds: const ['credit_note'],
        fiscalYear: currentFiscalYear,
        fiscalMonth: currentMonthLabel,
        categoryCode: filters.category?.code,
        itemCode: filters.item?.code,
        repCode: filters.salesPerson?.code,
        branchCode: filters.branch?.code,
        customerCode: filters.customer?.code,
      ),
      salesRepo.fetchSalesDocumentsTotals(
        documentKinds: const ['invoice'],
        fiscalYear: currentFiscalYear,
        categoryCode: filters.category?.code,
        itemCode: filters.item?.code,
        repCode: filters.salesPerson?.code,
        branchCode: filters.branch?.code,
        customerCode: filters.customer?.code,
      ),
      salesRepo.fetchSalesDocumentsTotals(
        documentKinds: const ['credit_note'],
        fiscalYear: currentFiscalYear,
        categoryCode: filters.category?.code,
        itemCode: filters.item?.code,
        repCode: filters.salesPerson?.code,
        branchCode: filters.branch?.code,
        customerCode: filters.customer?.code,
      ),
      // Every rep's sales_forecast row alongside repBudgetRows above (index
      // 4) — Rep Target Attainment needs the same budget-or-forecast
      // fallback `_fetchWholeCompanyTarget` gained the same day (see that
      // method's own doc comment), just across every rep at once rather
      // than one entity.
      ref.read(budgetRepositoryProvider).fetchForecast(dimension: 'sales_person'),
      // Sales Coverage's OWN-scope history (see the doc comment above
      // `coverageScope`) — appended at the end rather than inserted earlier
      // in this list so every existing `results[N]` index above stays
      // unchanged. Admin's scope is already `company`, so there's nothing
      // new to fetch — reuse the `dimension: 'company'` result (index 2)
      // instead of firing the exact same query twice.
      coverageScope.dimension == SalesDimension.company
          ? Future.value(<EntitySalesHistory>[])
          : salesRepo.fetchSalesHistory(dimension: coverageScope.dimension.dbValue, fiscalYears: historyWindow),
    ]);

    final consolidatedRows = results[0] as List<ConsolidatedSales>;
    final wholeCompanyTarget = results[1] as _WholeCompanyTarget;
    final companyHistoryRows = results[2] as List<EntitySalesHistory>;
    final companySalesHistory = companyHistoryRows.isEmpty ? null : companyHistoryRows.first;
    final ownHistoryRows = results[11] as List<EntitySalesHistory>;
    EntitySalesHistory? ownSalesHistory;
    if (coverageScope.dimension == SalesDimension.company) {
      ownSalesHistory = companySalesHistory;
    } else {
      for (final row in ownHistoryRows) {
        if (row.entityCode == coverageScope.entityCode) {
          ownSalesHistory = row;
          break;
        }
      }
    }
    final customerMonthlyRows = results[3] as List<DimensionMonthlySales>;
    final repBudgetRows = results[4] as List<BudgetFigure>;
    final repMonthlyRows = results[5] as List<DimensionMonthlySales>;
    final invoiceTotalsMtd = results[6] as SalesDocumentTotals;
    final creditNoteTotalsMtd = results[7] as SalesDocumentTotals;
    final invoiceTotalsYtd = results[8] as SalesDocumentTotals;
    final creditNoteTotalsYtd = results[9] as SalesDocumentTotals;
    final repForecastRows = results[10] as List<SalesForecastFigure>;

    num salesMtd = 0, profitMtd = 0, salesYtd = 0, profitYtd = 0;
    for (final row in consolidatedRows) {
      salesYtd += row.value;
      profitYtd += row.profit;
      if (row.month.year == monthStart.year && row.month.month == monthStart.month) {
        salesMtd += row.value;
        profitMtd += row.profit;
      }
    }

    // --- Top 5 Customer Concentration --------------------------------
    // fiscalYears: [currentFiscalYear] on the fetch above already scopes
    // customerMonthlyRows to the current FY, so summing every row gives the
    // YTD total directly; MTD narrows further to the current calendar
    // month, same boundary _loadDimension's own MTD pie uses.
    final customerMtdTotals = _sumRows(customerMonthlyRows.where((r) => _sameMonth(r.month, monthStart)));
    final customerYtdTotals = _sumRows(customerMonthlyRows);

    num top5Sum(Map<String, _EntityPeriod> totals) {
      final sorted = totals.values.map((p) => p.value).toList()..sort((a, b) => b.compareTo(a));
      return sorted.take(5).fold<num>(0, (sum, v) => sum + v);
    }

    num totalSum(Map<String, _EntityPeriod> totals) => totals.values.fold<num>(0, (sum, p) => sum + p.value);

    // --- Rep Target Attainment ----------------------------------------
    // entityCode -> fiscal month label -> that rep's actual/target for the
    // month. Built from two independently-fetched lists (actual sales,
    // budget targets) rather than v_dimension_performance's own join,
    // because that view is generated FROM the sales rollup — a rep with a
    // target but literally zero sales in a month has no row there at all,
    // which would silently drop them from the "how many reps have a
    // target" denominator. Building both maps here and reading targets as
    // the source of truth for "which reps count" avoids that gap.
    final repActualByMonth = <String, Map<String, num>>{};
    for (final row in repMonthlyRows) {
      final byMonth = repActualByMonth.putIfAbsent(row.entityCode, () => {});
      byMonth[row.fiscalMonth] = (byMonth[row.fiscalMonth] ?? 0) + row.value;
    }
    // Budget and forecast collected per rep separately, then merged one
    // (rep, month) at a time via resolveTarget — same budget-takes-
    // precedence-else-forecast rule as _fetchWholeCompanyTarget above and
    // Sales Analysis's Target overlay, so a rep whose figure only exists as
    // a forecast still counts as having "a target this month" here.
    final repBudgetByMonth = <String, Map<String, num>>{};
    for (final row in repBudgetRows) {
      final byMonth = repBudgetByMonth.putIfAbsent(row.entityCode, () => {});
      byMonth[row.fiscalMonth] = (byMonth[row.fiscalMonth] ?? 0) + row.budgetValue;
    }
    final repForecastByMonth = <String, Map<String, num>>{};
    for (final row in repForecastRows) {
      final byMonth = repForecastByMonth.putIfAbsent(row.entityCode, () => {});
      byMonth[row.fiscalMonth] = (byMonth[row.fiscalMonth] ?? 0) + row.forecastValue;
    }
    final repTargetByMonth = <String, Map<String, num>>{};
    for (final rep in {...repBudgetByMonth.keys, ...repForecastByMonth.keys}) {
      final months = {...(repBudgetByMonth[rep]?.keys ?? const <String>{}), ...(repForecastByMonth[rep]?.keys ?? const <String>{})};
      repTargetByMonth[rep] = {
        for (final month in months)
          month: resolveTarget(budgetValue: repBudgetByMonth[rep]?[month], forecastValue: repForecastByMonth[rep]?[month]) ?? 0,
      };
    }

    final repsWithMtdTarget = repTargetByMonth.entries.where((e) => e.value.containsKey(currentMonthLabel)).map((e) => e.key).toSet();
    final repsAtTargetMtd = repsWithMtdTarget.where((rep) {
      final actual = repActualByMonth[rep]?[currentMonthLabel] ?? 0;
      final target = repTargetByMonth[rep]![currentMonthLabel]!;
      return actual >= target;
    }).length;

    final repsWithYtdTarget = repTargetByMonth.entries
        .where((e) => e.value.keys.any((month) => elapsedFiscalMonths.contains(month)))
        .map((e) => e.key)
        .toSet();
    final repsAtTargetYtd = repsWithYtdTarget.where((rep) {
      final targetYtdForRep = repTargetByMonth[rep]!
          .entries
          .where((e) => elapsedFiscalMonths.contains(e.key))
          .fold<num>(0, (sum, e) => sum + e.value);
      final actualYtdForRep = (repActualByMonth[rep] ?? const {})
          .entries
          .where((e) => elapsedFiscalMonths.contains(e.key))
          .fold<num>(0, (sum, e) => sum + e.value);
      return actualYtdForRep >= targetYtdForRep;
    }).length;

    // 2026-09-04: narrow Rep Target Attainment down to just the one rep when
    // a Sales Person global filter is active, rather than always the
    // whole-roster count — Craig's report ("still showing Company Wide")
    // covered this tile too, and a "0 of 6" sitting next to a dashboard
    // that's otherwise entirely about Sarah Naidoo reads as if her own
    // filter selection was ignored here. Only Sales Person narrows this
    // particular tile (unlike Revenue Target Attainment/Sales Coverage
    // above, which any of the 5 filters can drive via `_effectiveScope`) —
    // "which reps" has no well-defined narrower meaning for a Branch/
    // Customer/Item/Category filter or for 2+ filters stacked, so every
    // other combination keeps the full-roster counts computed above
    // unchanged.
    final filteredRepCode = filters.salesPerson?.code;
    final repsTotalMtdFinal = filteredRepCode == null ? repsWithMtdTarget.length : (repsWithMtdTarget.contains(filteredRepCode) ? 1 : 0);
    final repsAtTargetMtdFinal = filteredRepCode == null
        ? repsAtTargetMtd
        : (repsWithMtdTarget.contains(filteredRepCode) &&
                (repActualByMonth[filteredRepCode]?[currentMonthLabel] ?? 0) >= repTargetByMonth[filteredRepCode]![currentMonthLabel]!
            ? 1
            : 0);
    final repsTotalYtdFinal = filteredRepCode == null ? repsWithYtdTarget.length : (repsWithYtdTarget.contains(filteredRepCode) ? 1 : 0);
    int repsAtTargetYtdFinal;
    if (filteredRepCode == null) {
      repsAtTargetYtdFinal = repsAtTargetYtd;
    } else if (repsWithYtdTarget.contains(filteredRepCode)) {
      final targetYtdForRep = repTargetByMonth[filteredRepCode]!
          .entries
          .where((e) => elapsedFiscalMonths.contains(e.key))
          .fold<num>(0, (sum, e) => sum + e.value);
      final actualYtdForRep = (repActualByMonth[filteredRepCode] ?? const {})
          .entries
          .where((e) => elapsedFiscalMonths.contains(e.key))
          .fold<num>(0, (sum, e) => sum + e.value);
      repsAtTargetYtdFinal = actualYtdForRep >= targetYtdForRep ? 1 : 0;
    } else {
      repsAtTargetYtdFinal = 0;
    }

    return _KpiData(
      salesMtd: salesMtd,
      salesYtd: salesYtd,
      profitMtd: profitMtd,
      profitYtd: profitYtd,
      companyActualMtd: wholeCompanyTarget.actualMtd,
      companyActualYtd: wholeCompanyTarget.actualYtd,
      companyTargetMtd: wholeCompanyTarget.targetMtd,
      companyTargetYtd: wholeCompanyTarget.targetYtd,
      ownSalesHistory: ownSalesHistory,
      companySalesHistory: companySalesHistory,
      elapsedMonthsYtd: elapsedFiscalMonths.length,
      top5CustomerValueMtd: top5Sum(customerMtdTotals),
      totalCustomerValueMtd: totalSum(customerMtdTotals),
      top5CustomerCountMtd: customerMtdTotals.length < 5 ? customerMtdTotals.length : 5,
      top5CustomerValueYtd: top5Sum(customerYtdTotals),
      totalCustomerValueYtd: totalSum(customerYtdTotals),
      top5CustomerCountYtd: customerYtdTotals.length < 5 ? customerYtdTotals.length : 5,
      repsAtTargetMtd: repsAtTargetMtdFinal,
      repsTotalMtd: repsTotalMtdFinal,
      repsAtTargetYtd: repsAtTargetYtdFinal,
      repsTotalYtd: repsTotalYtdFinal,
      grossInvoicedMtd: invoiceTotalsMtd.value,
      creditNoteMtd: creditNoteTotalsMtd.value.abs(),
      grossInvoicedYtd: invoiceTotalsYtd.value,
      creditNoteYtd: creditNoteTotalsYtd.value.abs(),
    );
  }

  Future<void> _loadDimension() async {
    final dimension = _dimension;
    try {
      final currentFy = fiscalYearFor(DateTime.now(), startMonth: ref.read(fiscalYearStartMonthProvider).valueOrNull ?? 3);
      final filters = _dashboardFilters(ref.read(globalFiltersProvider));
      final results = await Future.wait([
        ref.read(salesRepositoryProvider).fetchDimensionMonthlySales(
              dimension: dimension,
              fiscalYears: [currentFy - 1, currentFy],
              filters: filters,
            ),
        ref.read(referenceDataRepositoryProvider).namesFor(dimension),
      ]);
      if (!mounted || dimension != _dimension) return; // a newer dimension pick already superseded this one
      setState(() {
        _dimensionData = _DimensionRawData(
          rows: results[0] as List<DimensionMonthlySales>,
          names: results[1] as Map<String, String>,
          fiscalYear: currentFy,
        );
        _dimensionLoading = false;
        _dimensionError = null;
      });
    } catch (error) {
      if (!mounted || dimension != _dimension) return;
      setState(() {
        _dimensionLoading = false;
        _dimensionError = error.toString();
      });
    }
  }

  void _onDimensionChanged(SalesDimension? value) {
    if (value == null || value == _dimension) return;
    // Deliberately keep the previous dimension's charts on screen (just
    // dimmed via the small inline spinner next to the heading) rather than
    // clearing _dimensionData here — the whole point of this rebuild was
    // not blanking the screen on a control change.
    setState(() {
      _dimension = value;
      _dimensionLoading = true;
    });
    _loadDimension();
  }

  Future<void> _refresh() async {
    ref.invalidate(lastDataUpdateProvider);
    final kpis = _loadKpis();
    setState(() {
      _kpiFuture = kpis;
      _dimensionLoading = true;
    });
    await Future.wait([kpis, _loadDimension()]);
  }

  Map<String, _EntityPeriod> _sumRows(Iterable<DimensionMonthlySales> rows) {
    final totals = <String, _EntityPeriod>{};
    for (final row in rows) {
      final existing = totals[row.entityCode];
      totals[row.entityCode] = _EntityPeriod((existing?.value ?? 0) + row.value, (existing?.profit ?? 0) + row.profit);
    }
    return totals;
  }

  num _valueOf(_EntityPeriod? period, ValueMeasure measure) {
    if (period == null) return 0;
    return measure == ValueMeasure.rValue ? period.value : period.profit;
  }

  DimensionRankMode _toDimensionRankMode(_RankMode mode) {
    switch (mode) {
      case _RankMode.top5:
        return DimensionRankMode.top5;
      case _RankMode.bottom5:
        return DimensionRankMode.bottom5;
      case _RankMode.diminishing5:
        return DimensionRankMode.diminishing5;
      case _RankMode.growth5:
        return DimensionRankMode.growth5;
    }
  }

  List<PieSlice> _pickSlices({
    required Map<String, _EntityPeriod> current,
    required Map<String, _EntityPeriod> previous,
    required Map<String, String> names,
  }) {
    // 2026-09-01, Craig, testing on 1 September with no data loaded yet
    // for the brand-new fiscal month: "This is incorrect as we have no
    // MTD data for September yet" — the MTD pie's legend was showing 5
    // real customer names, each next to R0. Checked here before handing
    // off to `rankEntityCodes` (core/utils/dimension_ranking.dart), which
    // now also covers the same bug's smaller sibling — "we have SOME
    // current-period entities, just fewer than 5" — see that file's own
    // doc comment for the 2026-09-03 follow-up report ("where does five
    // customers come from???") this was split out to fix.
    if (current.isEmpty) return const [];

    final currentValues = current.map((code, period) => MapEntry(code, _valueOf(period, _measure)));
    final previousValues = previous.map((code, period) => MapEntry(code, _valueOf(period, _measure)));

    final codes = rankEntityCodes(
      current: currentValues,
      previous: previousValues,
      mode: _toDimensionRankMode(_rankMode),
    );

    return codes.map((code) {
      return PieSlice(label: names[code] ?? code, entityCode: code, rawValue: currentValues[code] ?? 0);
    }).toList();
  }

  bool _sameMonth(DateTime a, DateTime b) => a.year == b.year && a.month == b.month;

  // Carries the rank mode, MTD/YTD period, and measure along with the
  // clicked entity (Craig, 2026-08-26: "Top 5 Customers must show Sales by
  // Customer formatted top 5 in descending order. Bottom 5 would show in
  // ascending order etc.") so Sales By can open pre-sorted to match rather
  // than always defaulting to "current FY, highest first" regardless of
  // which chart/mode was actually clicked.
  void _drillDown(PieSlice slice, {required String period}) {
    context.go(
      '/sales-by/${_dimension.dbValue}'
      '?highlight=${Uri.encodeComponent(slice.entityCode)}'
      '&rank=${_rankMode.name}'
      '&period=$period'
      '&measure=${_measure.name}',
    );
  }

  @override
  Widget build(BuildContext context) {
    // A global filter changed — on this screen (unlikely; Dashboard has no
    // filter controls of its own beyond the dimension/rank/measure pickers
    // already handled below) or, far more commonly, on another screen
    // before navigating here. Refresh both the KPI row and the pies so they
    // reflect it. ref.listen, not a manual diff-in-build +
    // WidgetsBinding.addPostFrameCallback — see document_analysis_view.dart's
    // build() for why that pattern was replaced (2026-08-26, Craig's branch
    // filter bug report).
    ref.listen<GlobalFilters>(globalFiltersProvider, (previous, next) => _refresh());

    // Refresh once the signed-in profile actually finishes loading — Craig,
    // 2026-09-03: "Dashboard opens and it shows 0 target. I navigate to
    // another screen and then back to Dashboard and it shows correctly."
    // Root cause: initState's very first `_loadKpis()` call reads
    // `sessionProvider` synchronously via `defaultTargetScope(ref.read(
    // sessionProvider).value)` inside `_fetchWholeCompanyTarget`, which can
    // run before SessionNotifier (core/app_providers.dart) finishes its own
    // async profile fetch after sign-in — landing while the provider is
    // still `loading`/has no value yet, `defaultTargetScope(null)` falls
    // back to the company-wide scope, invisible to a non-admin login under
    // RLS (schema/018) — 0 target, exactly this symptom.
    //
    // Deliberately does NOT call `_refresh()` immediately if the initial
    // load is still in flight (`_initialKpiLoadInFlight`) — this screen
    // already fires ~10 concurrent queries per load, and a non-admin
    // login's RLS evaluation on `sales_document_facts` is genuinely
    // expensive per row (Section 62's `statement timeout` investigation).
    // Firing a SECOND full batch on top of the first, still-running one
    // was exactly what an earlier version of this fix did — Craig hit a
    // real `PostgrestException: canceling statement due to statement
    // timeout` on the very next retest, most plausibly because doubling
    // concurrent load during this exact startup window tipped an already
    // marginal query plan over the edge. Queuing the refresh instead, to
    // run once the initial load actually settles (see initState's
    // `whenComplete`), keeps at most one full batch in flight at a time.
    ref.listen<AsyncValue<Profile?>>(sessionProvider, (previous, next) {
      if (previous?.value != null || next.value == null) return;
      if (_initialKpiLoadInFlight) {
        _profileReloadQueued = true;
      } else {
        _refresh();
      }
    });

    final dimData = _dimensionData;

    List<PieSlice> mtdSlices = const [];
    List<PieSlice> ytdSlices = const [];
    if (dimData != null) {
      final now = DateTime.now();
      final currentMonthStart = DateTime(now.year, now.month, 1);
      final previousMonthStart = DateTime(now.year, now.month - 1, 1);

      final mtdCurrent = _sumRows(dimData.rows.where((r) => _sameMonth(r.month, currentMonthStart)));
      final mtdPrevious = _sumRows(dimData.rows.where((r) => _sameMonth(r.month, previousMonthStart)));
      mtdSlices = _pickSlices(current: mtdCurrent, previous: mtdPrevious, names: dimData.names);

      // "YTD looks at the yearly trend" (Craig, 2026-08-26) — compared
      // against the SAME set of elapsed fiscal months last year, not the
      // whole prior year, so a 5-month-old fiscal year isn't compared
      // against a full 12 months of the one before it.
      final elapsedFiscalMonths = dimData.rows.where((r) => r.fiscalYear == dimData.fiscalYear).map((r) => r.fiscalMonth).toSet();
      final ytdCurrent = _sumRows(dimData.rows.where((r) => r.fiscalYear == dimData.fiscalYear));
      final ytdPrevious = _sumRows(
        dimData.rows.where((r) => r.fiscalYear == dimData.fiscalYear - 1 && elapsedFiscalMonths.contains(r.fiscalMonth)),
      );
      ytdSlices = _pickSlices(current: ytdCurrent, previous: ytdPrevious, names: dimData.names);
    }

    return AppShell(
      title: 'Dashboard',
      currentRoute: '/',
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(20),
          child: AsyncSection<_KpiData>(
            future: _kpiFuture,
            builder: (context, kpis) {
              final onSurface = Theme.of(context).colorScheme.onSurface;
              final neutralMuted = onSurface.withValues(alpha: 0.6);

              // Revenue Target Attainment. Originally shipped with NO
              // toggle — the Actual vs Target chart below already shows
              // both periods permanently, so a toggle here would just
              // re-answer a question the chart already answers a few
              // pixels down (see Section 27 of
              // Wyzesales_Rebuild_Decisions.md for the full reasoning
              // Craig signed off on at the time). Got the toggle back
              // 2026-08-28 anyway — Craig: "for conformance purposes can we
              // build in the MTD/YTD toggle on the Revenue Attainment tile
              // as well," i.e. matching the other 5 tiles mattered more
              // than avoiding the chart's slight redundancy.
              final revenueAttainmentMtd = ratioPercent(kpis.companyActualMtd, kpis.companyTargetMtd);
              final revenueAttainmentYtd = ratioPercent(kpis.companyActualYtd, kpis.companyTargetYtd);
              Color revenueAttainmentColor(num? percent) =>
                  percent == null ? neutralMuted : (percent >= 100 ? AppColors.positive : AppColors.caution);

              // Gross Profit Margin.
              final gpMarginMtd = ratioPercent(kpis.profitMtd, kpis.salesMtd);
              final gpMarginYtd = ratioPercent(kpis.profitYtd, kpis.salesYtd);
              Color gpMarginColor(num? percent) => percent == null ? neutralMuted : (percent >= 0 ? AppColors.positive : AppColors.negative);

              // Sales Coverage (task #93/#103, replaced Quote → Order
              // Conversion 2026-09-02 — see Wyzesales_Rebuild_Decisions.md
              // Section 55). Same Gap-over-average-revenue-per-period idea
              // as Performance Analysis' per-entity "% Coverage Needed"
              // column — and, as of 2026-09-03 (Section 68), now genuinely
              // the SAME calc, via the same `computeCoverage` pure function
              // (core/utils/sales_coverage.dart), rather than a simplified
              // always-company copy of it. `own`/`company` come from
              // `_KpiData.ownSalesHistory`/`companySalesHistory` — see that
              // field's doc comment for why the old version was wrong for a
              // non-admin login. `usedFallback` is surfaced with the same
              // trailing `*` convention Performance Analysis' own coverage
              // column uses (Craig, 2026-09-02: a fallback "must be
              // flagged/visible in the UI when this fallback is used").
              final coverageMtd = computeCoverage(
                targetValue: kpis.companyTargetMtd,
                actualValue: kpis.companyActualMtd,
                own: kpis.ownSalesHistory,
                company: kpis.companySalesHistory,
              );
              final coverageYtd = computeCoverage(
                targetValue: kpis.companyTargetYtd,
                actualValue: kpis.companyActualYtd,
                own: kpis.ownSalesHistory,
                company: kpis.companySalesHistory,
                periods: kpis.elapsedMonthsYtd,
              );
              // usedFallback doesn't depend on `periods` (only on how many
              // active months `own` itself has), so MTD/YTD always agree —
              // safe to fold into one page-level flag for the caption below.
              final coverageUsedFallback = coverageMtd.usedFallback || coverageYtd.usedFallback;

              String coverageText(CoverageResult coverage) {
                if (coverage.onTarget) return 'On Target';
                if (coverage.insufficientData) return '—';
                final pct = formatPercent(coverage.coveragePercent);
                return coverage.usedFallback ? '$pct *' : pct;
              }

              // Same 3-tier thresholds as Performance Analysis' % Coverage
              // Needed column (see `_coverageColor`'s doc comment in
              // performance_screen.dart for the full reasoning) — kept in
              // sync deliberately, so "green"/"amber"/"red" mean the same
              // thing everywhere in the app rather than this one tile using
              // a coarser 2-tier scale. Craig, 2026-09-02, confirming the
              // cutoffs: On Target or under 25% is green, 25-50% is amber,
              // over 50% is red.
              Color coverageColor(CoverageResult coverage) {
                if (coverage.insufficientData) return neutralMuted;
                if (coverage.onTarget) return AppColors.positive;
                final pct = coverage.coveragePercent ?? 0;
                if (pct < 25) return AppColors.positive;
                if (pct <= 50) return AppColors.caution;
                return AppColors.negative;
              }

              final coverageGapMtd = kpis.companyTargetMtd - kpis.companyActualMtd;
              final coverageGapYtd = kpis.companyTargetYtd - kpis.companyActualYtd;
              final coverageMtdText = coverageText(coverageMtd);
              final coverageYtdText = coverageText(coverageYtd);

              // Top 5 Customer Concentration — 40% is a starting-point
              // "worth keeping an eye on" threshold, not a hard business
              // rule; easy to move if Craig wants a different cutoff once
              // this is live against real numbers.
              final concentrationMtd = ratioPercent(kpis.top5CustomerValueMtd, kpis.totalCustomerValueMtd);
              final concentrationYtd = ratioPercent(kpis.top5CustomerValueYtd, kpis.totalCustomerValueYtd);
              Color concentrationColor(num? percent) => percent == null ? neutralMuted : (percent >= 40 ? AppColors.caution : onSurface);

              Color repAttainmentColor(int atTarget, int total) =>
                  total == 0 ? neutralMuted : (atTarget >= total ? AppColors.positive : AppColors.caution);

              // Returns / Credit Note Rate — 2026-08-28, Craig: replaces the
              // old "Revenue & Gross Profit" tile ("it is repetitive" — the
              // same Sales/GP figures are already visible in Gross Profit
              // Margin's own subtitle). A quality signal, not a revenue one:
              // credit notes as a % of gross invoiced value. 3% is a
              // starting-point threshold, same caveat as Customer
              // Concentration's 40% — easy to move once this is live
              // against real numbers.
              final returnsRateMtd = ratioPercent(kpis.creditNoteMtd, kpis.grossInvoicedMtd);
              final returnsRateYtd = ratioPercent(kpis.creditNoteYtd, kpis.grossInvoicedYtd);
              Color returnsRateColor(num? percent) => percent == null ? neutralMuted : (percent > 3 ? AppColors.caution : AppColors.positive);

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 2026-08-28: switched from a `Wrap` of fixed-180px tiles
                  // to a deliberate fixed-column grid (`_KpiTileGrid` below).
                  // The `Wrap` (2026-08-26 onward, see git history/this
                  // doc's earlier revisions for that whole story — spread-
                  // across-the-screen spacing, then grown from 4 tiles to 6,
                  // then twice narrowed after real-device feedback) fit as
                  // many fixed-width tiles as the current window happened to
                  // allow, which meant the row split (5+1, 4+2, ...) was
                  // purely a function of window width, not a deliberate
                  // layout — Craig, seeing a lone 6th tile stranded on its
                  // own row: "The standard layout of 4 tiles on top and then
                  // one below. Does it perhaps make sense to have two rows
                  // of three each?" Since 6 divides evenly by both 3 and 2,
                  // a fixed-column grid always comes out as full rows with
                  // no stray leftover tile, regardless of window width.
                  //
                  // `_kpiGridBreakpoint` (900px) reuses the exact threshold
                  // this same screen already uses for its rankings grid a
                  // few sections down, and that `AppShell` uses to collapse
                  // its sidebar into a drawer — one width decision for the
                  // whole app to reason about, not a second bespoke number
                  // for this row alone. Above it: 3 columns, 2 rows. At or
                  // below it: 2 columns, 3 rows, so 3-across doesn't get
                  // forced into a window too narrow to hold it without
                  // cramping labels and toggles. Every tile stretches to
                  // fill its equal share of the row's width (via `Expanded`
                  // inside `_KpiTileGrid`) rather than sitting at a fixed
                  // width — that's what fills a wide monitor properly
                  // instead of leaving whitespace down the sides now that
                  // the row is a deliberate grid, not "as many fixed-width
                  // boxes as fit."
                  _KpiTileGrid(
                    columns: MediaQuery.of(context).size.width > _kpiGridBreakpoint ? 3 : 2,
                    tileHeight: _kpiTileHeight,
                    tiles: [
                      // 1. Toggle added back 2026-08-28 for conformance with
                      // the other 5 tiles (see the comment on
                      // revenueAttainmentColor() above). Subtitle carries the
                      // actual/target Rand amounts for whichever period is
                      // selected — the separate "Actual Revenue vs Sales
                      // Target" bar chart that used to live below this row
                      // was removed the same day (Craig: "does it make sense
                      // to also have the bar charts? Should we not include
                      // the actual numbers on the tile and remove the bar
                      // charts?" — chosen over trimming the chart or leaving
                      // both as-is). One period's Rand figures at a time
                      // fits on one line at this tile's width — cramming
                      // BOTH periods into one subtitle simultaneously is
                      // what caused the earlier truncation problem (Craig,
                      // 2026-08-27: "Cannot truncate... The tiles all need
                      // to be the same size as well"); this shows only the
                      // toggled period's own figures, same as every other
                      // tile.
                      ToggleStatCard(
                        label: 'Revenue Target Attainment',
                        mtdValue: formatPercent(revenueAttainmentMtd),
                        mtdColor: revenueAttainmentColor(revenueAttainmentMtd),
                        mtdSubtitle: '${formatRand(kpis.companyActualMtd)} of ${formatRand(kpis.companyTargetMtd)} target (MTD)',
                        ytdValue: formatPercent(revenueAttainmentYtd),
                        ytdColor: revenueAttainmentColor(revenueAttainmentYtd),
                        ytdSubtitle: '${formatRand(kpis.companyActualYtd)} of ${formatRand(kpis.companyTargetYtd)} target (YTD)',
                      ),
                      ToggleStatCard(
                        label: 'Gross Profit Margin',
                        mtdValue: formatPercent(gpMarginMtd),
                        mtdColor: gpMarginColor(gpMarginMtd),
                        mtdSubtitle: '${formatRand(kpis.profitMtd)} of ${formatRand(kpis.salesMtd)} sales (MTD)',
                        ytdValue: formatPercent(gpMarginYtd),
                        ytdColor: gpMarginColor(gpMarginYtd),
                        ytdSubtitle: '${formatRand(kpis.profitYtd)} of ${formatRand(kpis.salesYtd)} sales (YTD)',
                      ),
                      ToggleStatCard(
                        label: 'Sales Coverage',
                        mtdValue: coverageMtdText,
                        mtdColor: coverageColor(coverageMtd),
                        mtdSubtitle: coverageGapMtd <= 0
                            ? '${formatRand(coverageGapMtd.abs())} above target (MTD)'
                            : '${formatRand(coverageGapMtd)} gap to target (MTD)',
                        ytdValue: coverageYtdText,
                        ytdColor: coverageColor(coverageYtd),
                        ytdSubtitle: coverageGapYtd <= 0
                            ? '${formatRand(coverageGapYtd.abs())} above target (YTD)'
                            : '${formatRand(coverageGapYtd)} gap to target (YTD)',
                      ),
                      ToggleStatCard(
                        label: 'Top 5 Customer Concentration',
                        // Craig, 2026-08-27: "Customer Concentration must
                        // default to year."
                        initialPeriod: StatPeriod.ytd,
                        mtdValue: formatPercent(concentrationMtd),
                        mtdColor: concentrationColor(concentrationMtd),
                        mtdSubtitle: 'of MTD revenue, top ${formatQuantity(kpis.top5CustomerCountMtd)} accounts',
                        ytdValue: formatPercent(concentrationYtd),
                        ytdColor: concentrationColor(concentrationYtd),
                        ytdSubtitle: 'of YTD revenue, top ${formatQuantity(kpis.top5CustomerCountYtd)} accounts',
                      ),
                      ToggleStatCard(
                        label: 'Rep Target Attainment',
                        mtdValue: kpis.repsTotalMtd == 0 ? '—' : '${formatQuantity(kpis.repsAtTargetMtd)} of ${formatQuantity(kpis.repsTotalMtd)}',
                        mtdColor: repAttainmentColor(kpis.repsAtTargetMtd, kpis.repsTotalMtd),
                        mtdSubtitle: kpis.repsTotalMtd == 0 ? 'no rep targets set for this month' : 'reps at/above target (MTD)',
                        ytdValue: kpis.repsTotalYtd == 0 ? '—' : '${formatQuantity(kpis.repsAtTargetYtd)} of ${formatQuantity(kpis.repsTotalYtd)}',
                        ytdColor: repAttainmentColor(kpis.repsAtTargetYtd, kpis.repsTotalYtd),
                        ytdSubtitle: kpis.repsTotalYtd == 0 ? 'no rep targets set this year' : 'reps at/above target (YTD)',
                      ),
                      // 6. Returns / Credit Note Rate — replaced "Revenue &
                      // Gross Profit" 2026-08-28 (Craig: "remove the
                      // Revenue & Gross Profit tile as it is repetitive. In
                      // it's place can we insert this tile as per your
                      // suggestion: a returns/credit-note rate (credit note
                      // value as a % of gross invoiced value) as a quality
                      // signal"). Sales and Gross Profit are already
                      // visible via other tiles/charts on this screen, so
                      // this slot now carries a distinct signal instead:
                      // what share of what was invoiced came back as a
                      // credit note. Higher = worse (more returns/credit
                      // notes relative to sales), so the color scale in
                      // returnsRateColor() is inverted relative to the
                      // "higher is better" tiles above.
                      ToggleStatCard(
                        label: 'Returns / Credit Note Rate',
                        mtdValue: formatPercent(returnsRateMtd),
                        mtdColor: returnsRateColor(returnsRateMtd),
                        mtdSubtitle: '${formatRand(kpis.creditNoteMtd)} of ${formatRand(kpis.grossInvoicedMtd)} invoiced (MTD)',
                        ytdValue: formatPercent(returnsRateYtd),
                        ytdColor: returnsRateColor(returnsRateYtd),
                        ytdSubtitle: '${formatRand(kpis.creditNoteYtd)} of ${formatRand(kpis.grossInvoicedYtd)} invoiced (YTD)',
                      ),
                      // "Last Updated" tile removed 2026-08-26 — that
                      // data-freshness reading now lives in AppShell's top
                      // bar (visible on every screen, not just this one)
                      // instead of taking up a KPI slot here.
                    ],
                  ),
                  // Sales Coverage's fallback flag (2026-09-03, Section 68) —
                  // Craig required this be "flagged/visible in the UI when
                  // this fallback is used," same requirement Performance
                  // Analysis' own coverage column already satisfies with a
                  // page footnote. Conditionally shown (only when
                  // `coverageUsedFallback`), unlike the always-present
                  // caveat Craig asked removed from this same spot
                  // 2026-08-28 (see the comment just below) — this is a
                  // genuine, situational data-quality signal, not a
                  // standing disclaimer.
                  if (coverageUsedFallback) ...[
                    const SizedBox(height: 8),
                    Text(
                      '* Sales Coverage is using the company-wide average — '
                      'under 3 months of your own sales history so far.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic, color: neutralMuted),
                    ),
                  ],
                  // The Quote → Order Conversion caveat footnote (same-period
                  // count, not a matched per-quote rate) was printed here as
                  // italic text under the KPI row until 2026-08-28, when
                  // Craig marked it for removal on a screenshot ("Remove",
                  // arrow pointing at this line). The caveat itself still
                  // holds — see Section 27/28 of
                  // Wyzesales_Rebuild_Decisions.md — it's just no longer
                  // shown on the Dashboard itself.
                  // The "Actual Revenue vs Sales Target" bar chart that used
                  // to sit here (two horizontal bar-pairs, MTD and YTD, plus
                  // a "% achieved" badge — see ActualVsTargetChart's own doc
                  // comment for that widget's history) was removed
                  // 2026-08-28, once the Revenue Target Attainment tile
                  // above got its own MTD/YTD toggle back (Section 32):
                  // Craig, "does it make sense to also have the bar charts?
                  // Should we not include the actual numbers on the tile and
                  // remove the bar charts?" — the chart's "% achieved" badge
                  // was a genuine duplicate of the tile's own headline
                  // percentage once that toggle existed, and the tile's
                  // subtitle now carries the same Rand actual/target amounts
                  // the chart's bars did, one period at a time. The widget
                  // itself (`shared/widgets/actual_vs_target_chart.dart`)
                  // is left in place rather than deleted, same as
                  // `StatCard` after the Section 27 KPI redesign — unused
                  // today, but a working, self-contained bar chart if some
                  // future screen wants one.
                  const SizedBox(height: 24),
                  // Flattened to one Wrap of individual items (heading,
                  // then each control) rather than two nested groups —
                  // spaceBetween now spreads all of them across the full
                  // row width on a wide screen, matching Craig's "chart
                  // filter options" half of the same "spread across the
                  // available screen space" request (2026-08-26), instead
                  // of just pinning two clusters to opposite ends. Still
                  // reflows safely to multiple lines on a narrow window,
                  // same as before.
                  //
                  // (2026-08-26, follow-up) Same SizedBox(width:
                  // double.infinity) fix as the KPI row above and for the
                  // same reason — a bare Wrap here shrink-wraps to just the
                  // heading + 3 controls, which was well short of the full
                  // row width, so spaceBetween had no free space to spread
                  // and everything sat bunched on the left.
                  SizedBox(
                    width: double.infinity,
                    child: Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 16,
                      runSpacing: 12,
                      children: [
                        Wrap(
                          spacing: 10,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text('${_dimension.label} breakdown', style: Theme.of(context).textTheme.titleMedium),
                            if (_dimensionLoading)
                              const SizedBox(width: 14, height: 14, child: RepaintBoundary(child: CircularProgressIndicator(strokeWidth: 2))),
                          ],
                        ),
                        // 160 — standardized 2026-08-27 to match every
                        // other dimension switcher in the app (Sales By,
                        // Performance): Craig, "check the sizing and
                        // consistency of all of the filter boxes across the
                        // application."
                        BoxedDropdown<SalesDimension>(
                          value: _dimension,
                          width: 160,
                          // `filterable`, not `values` — this picker ranks
                          // entities WITHIN a dimension (Top 5 reps, Top 5
                          // branches, etc.); "Company" has only ever one
                          // entity, nothing to rank (2026-09-02, Section 57;
                          // the Dashboard's own KPI tiles above already cover
                          // whole-company figures).
                          items: SalesDimension.filterable.map((d) => DropdownMenuItem(value: d, child: Text(d.label))).toList(),
                          onChanged: _onDimensionChanged,
                        ),
                        BoxedDropdown<_RankMode>(
                          value: _rankMode,
                          width: 160,
                          items: _RankMode.values.map((m) => DropdownMenuItem(value: m, child: Text(m.label))).toList(),
                          onChanged: (m) {
                            if (m != null) setState(() => _rankMode = m);
                          },
                        ),
                        ValueGpToggle(
                          value: _measure,
                          onChanged: (m) => setState(() => _measure = m),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (dimData == null && _dimensionError != null)
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'Something went wrong loading this: $_dimensionError',
                        style: TextStyle(color: Theme.of(context).colorScheme.error),
                      ),
                    )
                  else if (dimData == null)
                    const Padding(padding: EdgeInsets.all(32), child: Center(child: RepaintBoundary(child: CircularProgressIndicator())))
                  else
                    GridView.count(
                      crossAxisCount: MediaQuery.of(context).size.width > 900 ? 2 : 1,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      mainAxisSpacing: 16,
                      crossAxisSpacing: 16,
                      childAspectRatio: 1.5,
                      children: [
                        _PieCard(
                          title: '${_dimension.label} — MTD',
                          totalLabel: 'MTD',
                          slices: mtdSlices,
                          onSliceTap: (slice) => _drillDown(slice, period: 'mtd'),
                        ),
                        _PieCard(
                          title: '${_dimension.label} — YTD',
                          totalLabel: 'YTD',
                          slices: ytdSlices,
                          onSliceTap: (slice) => _drillDown(slice, period: 'ytd'),
                        ),
                      ],
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

// _QuickActions (the row of Sales Analysis/YTD Comparative/Quote
// Analysis/Sales Order Analysis/Budgets tiles) was removed 2026-08-26 per
// Craig's request: "Remove Quick actions and replace with Actual Revenue vs
// Sales Target as a bar chart." All of those destinations remain reachable
// from the app shell's nav drawer (see app_shell.dart), so no navigation
// path was lost — this was a pure duplicate shortcut.

/// Lays a fixed set of equal-height KPI tiles into an even grid of
/// `columns` columns, wrapping to as many rows as `tiles.length` needs —
/// with 6 tiles and `columns` set to 3 or 2 (see `_kpiGridBreakpoint`),
/// that's always exactly 2 or 3 full rows, never a stray leftover tile on
/// its own row. Replaced a `Wrap` of fixed-width tiles 2026-08-28 (Craig:
/// "does it perhaps make sense to have two rows of three each?") — see the
/// KPI row's own comment in `build()` for the full reasoning.
///
/// Each tile stretches to fill an equal share of its row's width via
/// `Expanded`, rather than sitting at a fixed width — that's what fills a
/// wide monitor properly instead of leaving whitespace down the sides, and
/// what shrinks tiles gracefully on a narrower one instead of forcing a
/// fixed width that might not fit.
///
/// `_spacing` (12px, matching the old `Wrap`'s own spacing/runSpacing) is a
/// private constant rather than a constructor parameter — `flutter
/// analyze`'s `unused_element_parameter` lint correctly flagged an earlier
/// version's `spacing` parameter as dead configurability, since this
/// widget's one call site never passed anything but the default.
class _KpiTileGrid extends StatelessWidget {
  const _KpiTileGrid({required this.tiles, required this.columns, required this.tileHeight});

  final List<Widget> tiles;
  final int columns;
  final double tileHeight;

  static const double _spacing = 12;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var start = 0; start < tiles.length; start += columns) {
      final rowTiles = tiles.skip(start).take(columns).toList();
      if (rows.isNotEmpty) rows.add(const SizedBox(height: _spacing));
      rows.add(
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < rowTiles.length; i++) ...[
              if (i > 0) const SizedBox(width: _spacing),
              Expanded(child: SizedBox(height: tileHeight, child: rowTiles[i])),
            ],
          ],
        ),
      );
    }
    return Column(children: rows);
  }
}

class _PieCard extends StatelessWidget {
  const _PieCard({required this.title, required this.totalLabel, required this.slices, required this.onSliceTap});

  final String title;
  final String totalLabel;
  final List<PieSlice> slices;
  final ValueChanged<PieSlice> onSliceTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Expanded(
              child: SimplePieChart(
                slices: slices,
                totalLabel: totalLabel,
                valueFormatter: formatRand,
                onSliceTap: onSliceTap,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
