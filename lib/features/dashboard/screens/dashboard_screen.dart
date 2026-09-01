import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/app_providers.dart';
import '../../../core/constants/fiscal.dart';
import '../../../core/filters/global_filters.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/formatters.dart';
import '../../../data/models/budget_figure.dart';
import '../../../data/models/consolidated_sales.dart';
import '../../../data/models/dimension_monthly_sales.dart';
import '../../../data/models/sales_document.dart';
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

/// Whole-company Actual vs Target, MTD/YTD — read by the KPI row's Revenue
/// Target Attainment tile. Deliberately NOT filtered by the 5 global
/// dimension filters: budget_figures has no per-Branch/Customer/etc
/// breakdown for a `dimension = 'company'` row, so filtering only the
/// Actual side would produce a mismatched comparison against an unfiltered
/// Target.
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
  // comment for why this is whole-company, and _fetchWholeCompanyTarget's
  // doc comment for the one call site that computes them.
  final num companyActualMtd;
  final num companyActualYtd;
  final num companyTargetMtd;
  final num companyTargetYtd;

  // Quote → Order Conversion — DISTINCT document counts, not a sum of line
  // values (see SalesRepository.fetchDocumentCounts' doc comment).
  final int quoteCountMtd;
  final int orderCountMtd;
  final int quoteCountYtd;
  final int orderCountYtd;

  // Top 5 Customer Concentration.
  final num top5CustomerValueMtd;
  final num totalCustomerValueMtd;
  final int top5CustomerCountMtd; // min(5, distinct customers with activity)
  final num top5CustomerValueYtd;
  final num totalCustomerValueYtd;
  final int top5CustomerCountYtd;

  // Rep Target Attainment — also whole-company; budget_figures carries no
  // per-Branch/Category/etc split on top of the rep themselves, so the 5
  // dashboard filters have no clean way to narrow "which reps" beyond what
  // a Sales Person filter already would on every other screen.
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
    required this.quoteCountMtd,
    required this.orderCountMtd,
    required this.quoteCountYtd,
    required this.orderCountYtd,
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
    _kpiFuture = _loadKpis();
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

  /// Whole-company Actual (v_consolidated_sales) vs Target (budget_figures,
  /// dimension='company') numbers, computed once per Dashboard load/refresh
  /// and read by the KPI row's Revenue Target Attainment tile
  /// (`_KpiData.companyActualMtd`/etc.). Used to be called a second time by
  /// a separate `_loadTargetChart` method, kept in sync as a shared
  /// fetch+compute helper so the two independently-timed loaders (the KPI
  /// row and the "Actual Revenue vs Sales Target" bar chart underneath it)
  /// never disagreed — that chart was removed 2026-08-28 (Section 32 of
  /// Wyzesales_Rebuild_Decisions.md), so this is back down to the one
  /// caller and the one round trip its name always implied.
  Future<_WholeCompanyTarget> _fetchWholeCompanyTarget(int currentFiscalYear, DateTime monthStart) async {
    final results = await Future.wait([
      ref.read(salesRepositoryProvider).fetchConsolidatedSales(fiscalYears: [currentFiscalYear]),
      ref.read(budgetRepositoryProvider).fetchBudget(dimension: 'company'),
    ]);
    final consolidatedRows = results[0] as List<ConsolidatedSales>;
    final budgetRows = results[1] as List<BudgetFigure>;

    num actualMtd = 0, actualYtd = 0;
    for (final row in consolidatedRows) {
      actualYtd += row.value;
      if (row.month.year == monthStart.year && row.month.month == monthStart.month) {
        actualMtd += row.value;
      }
    }

    final targetByMonth = <String, num>{};
    for (final row in budgetRows) {
      targetByMonth[row.fiscalMonth] = (targetByMonth[row.fiscalMonth] ?? 0) + row.budgetValue;
    }
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

    final results = await Future.wait([
      salesRepo.fetchConsolidatedSales(fiscalYears: [currentFiscalYear], filters: filters),
      _fetchWholeCompanyTarget(currentFiscalYear, monthStart),
      salesRepo.fetchDocumentCounts(
        documentKinds: const ['quote', 'sales_order'],
        fiscalYear: currentFiscalYear,
        categoryCode: filters.category?.code,
        itemCode: filters.item?.code,
        repCode: filters.salesPerson?.code,
        branchCode: filters.branch?.code,
        customerCode: filters.customer?.code,
      ),
      salesRepo.fetchDocumentCounts(
        documentKinds: const ['quote', 'sales_order'],
        fiscalYear: currentFiscalYear,
        fiscalMonth: currentMonthLabel,
        categoryCode: filters.category?.code,
        itemCode: filters.item?.code,
        repCode: filters.salesPerson?.code,
        branchCode: filters.branch?.code,
        customerCode: filters.customer?.code,
      ),
      salesRepo.fetchDimensionMonthlySales(
        dimension: SalesDimension.customer,
        fiscalYears: [currentFiscalYear],
        filters: filters,
      ),
      // Rep Target Attainment is deliberately whole-company — no `filters`
      // — see _KpiData's doc comment for why the 5 dashboard filters don't
      // apply here the way they do to the rest of the row.
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
    ]);

    final consolidatedRows = results[0] as List<ConsolidatedSales>;
    final wholeCompanyTarget = results[1] as _WholeCompanyTarget;
    final documentCountsYtd = results[2] as Map<String, int>;
    final documentCountsMtd = results[3] as Map<String, int>;
    final customerMonthlyRows = results[4] as List<DimensionMonthlySales>;
    final repBudgetRows = results[5] as List<BudgetFigure>;
    final repMonthlyRows = results[6] as List<DimensionMonthlySales>;
    final invoiceTotalsMtd = results[7] as SalesDocumentTotals;
    final creditNoteTotalsMtd = results[8] as SalesDocumentTotals;
    final invoiceTotalsYtd = results[9] as SalesDocumentTotals;
    final creditNoteTotalsYtd = results[10] as SalesDocumentTotals;

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
    final repTargetByMonth = <String, Map<String, num>>{};
    for (final row in repBudgetRows) {
      final byMonth = repTargetByMonth.putIfAbsent(row.entityCode, () => {});
      byMonth[row.fiscalMonth] = (byMonth[row.fiscalMonth] ?? 0) + row.budgetValue;
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

    return _KpiData(
      salesMtd: salesMtd,
      salesYtd: salesYtd,
      profitMtd: profitMtd,
      profitYtd: profitYtd,
      companyActualMtd: wholeCompanyTarget.actualMtd,
      companyActualYtd: wholeCompanyTarget.actualYtd,
      companyTargetMtd: wholeCompanyTarget.targetMtd,
      companyTargetYtd: wholeCompanyTarget.targetYtd,
      quoteCountMtd: documentCountsMtd['quote'] ?? 0,
      orderCountMtd: documentCountsMtd['sales_order'] ?? 0,
      quoteCountYtd: documentCountsYtd['quote'] ?? 0,
      orderCountYtd: documentCountsYtd['sales_order'] ?? 0,
      top5CustomerValueMtd: top5Sum(customerMtdTotals),
      totalCustomerValueMtd: totalSum(customerMtdTotals),
      top5CustomerCountMtd: customerMtdTotals.length < 5 ? customerMtdTotals.length : 5,
      top5CustomerValueYtd: top5Sum(customerYtdTotals),
      totalCustomerValueYtd: totalSum(customerYtdTotals),
      top5CustomerCountYtd: customerYtdTotals.length < 5 ? customerYtdTotals.length : 5,
      repsAtTargetMtd: repsAtTargetMtd,
      repsTotalMtd: repsWithMtdTarget.length,
      repsAtTargetYtd: repsAtTargetYtd,
      repsTotalYtd: repsWithYtdTarget.length,
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

  List<PieSlice> _pickSlices({
    required Map<String, _EntityPeriod> current,
    required Map<String, _EntityPeriod> previous,
    required Map<String, String> names,
  }) {
    // 2026-09-01, Craig, testing on 1 September with no data loaded yet
    // for the brand-new fiscal month: "This is incorrect as we have no
    // MTD data for September yet" — the MTD pie's legend was showing 5
    // real customer names, each next to R0, which reads as "these are
    // this month's top 5 customers" when the real situation is simpler
    // and more important: there is no data for this period AT ALL yet
    // (the extract hasn't run for September). Root cause: with `current`
    // completely empty, every rank mode's sort compares `_valueOf(current
    // [x])` values that are all 0 — a no-op that just preserves whatever
    // order the union Set below happened to produce — so `.take(5)`
    // silently surfaced 5 arbitrary PREVIOUS-month customer codes as if
    // they still applied this month. Checked here, before the deliberate
    // union logic below (which handles a genuinely different case — see
    // its own comment): a period with zero rows on record isn't "every
    // customer declined to zero," it's "we don't have this period's data
    // yet," and none of the four rank modes has anything real to show for
    // that. Returning no slices lets SimplePieChart's own "No data for the
    // current filters" fallback say the honest thing instead.
    if (current.isEmpty) return const [];

    // Union, not just current.keys — an entity that had activity last
    // period but none this period (dropped to zero) is exactly the kind of
    // thing "Diminishing 5" should be able to surface, not silently omit.
    final codes = <String>{...current.keys, ...previous.keys}.toList();

    num delta(String code) => _valueOf(current[code], _measure) - _valueOf(previous[code], _measure);

    switch (_rankMode) {
      case _RankMode.top5:
        codes.sort((a, b) => _valueOf(current[b], _measure).compareTo(_valueOf(current[a], _measure)));
        break;
      case _RankMode.bottom5:
        codes.sort((a, b) => _valueOf(current[a], _measure).compareTo(_valueOf(current[b], _measure)));
        break;
      case _RankMode.diminishing5:
        codes.sort((a, b) => delta(a).compareTo(delta(b))); // most negative delta (biggest decline) first
        break;
      case _RankMode.growth5:
        codes.sort((a, b) => delta(b).compareTo(delta(a))); // most positive delta (biggest growth) first
        break;
    }

    return codes.take(5).map((code) {
      return PieSlice(label: names[code] ?? code, entityCode: code, rawValue: _valueOf(current[code], _measure));
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

              // Quote → Order Conversion is a same-period count (distinct
              // quote documents vs distinct sales-order documents raised in
              // the same period), not a matched per-quote conversion rate —
              // there's no field linking a specific quote to the order it
              // becomes. That caveat used to be printed under the KPI row;
              // Craig had it removed 2026-08-28. Still documented in
              // Wyzesales_Rebuild_Decisions.md (Section 27/28) for anyone
              // who needs the full explanation.
              final conversionMtd = ratioPercent(kpis.orderCountMtd, kpis.quoteCountMtd);
              final conversionYtd = ratioPercent(kpis.orderCountYtd, kpis.quoteCountYtd);

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
                        label: 'Quote → Order Conversion',
                        mtdValue: formatPercent(conversionMtd),
                        mtdColor: onSurface,
                        // 2026-09-01, Craig: "format all numbers with the
                        // thousand [separator]... This must apply to all
                        // numbers in the application" — these counts were
                        // interpolated raw; wrapped in formatQuantity like
                        // every other number in the app already is.
                        mtdSubtitle: '${formatQuantity(kpis.quoteCountMtd)} quotes → ${formatQuantity(kpis.orderCountMtd)} orders',
                        ytdValue: formatPercent(conversionYtd),
                        ytdColor: onSurface,
                        ytdSubtitle: '${formatQuantity(kpis.quoteCountYtd)} quotes → ${formatQuantity(kpis.orderCountYtd)} orders',
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
                          items: SalesDimension.values.map((d) => DropdownMenuItem(value: d, child: Text(d.label))).toList(),
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
