import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../core/app_providers.dart';
import '../../../core/constants/fiscal.dart';
import '../../../core/filters/global_filters.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/utils/target_overlay.dart';
import '../../../data/models/consolidated_sales.dart';
import '../../../data/models/profile.dart';
import '../../../shared/widgets/app_shell.dart';
import '../../../shared/widgets/async_section.dart';
import '../../../shared/widgets/data_export_buttons.dart';
import '../../../shared/widgets/document_analysis_view.dart';
import '../../../shared/widgets/trend_line_chart.dart';
import '../../../shared/widgets/value_gp_toggle.dart';

/// Chart tab + Table tab, per Wyzesales_Screens_and_Recommendations.md
/// Section 1. The Table tab is the shared DocumentAnalysisView, scoped to
/// actual sales (invoice/credit_note) — same shape as Quote Analysis/Sales
/// Order Analysis with a different document_kind filter.
///
/// 2026-08-27: the TabBar/TabBarView pair was replaced with a
/// SegmentedButton toggle — Craig: "Change Graph to Chart on Sales Analysis
/// and turn Chart and Table into a toggle conforming with the others ones in
/// the app," i.e. the same SegmentedButton shape as ValueGpToggle
/// (value_gp_toggle.dart), already used for R Value/R Gross Profit on this
/// same screen and elsewhere. An IndexedStack, not a plain conditional
/// widget swap, keeps both `_GraphTab` and `DocumentAnalysisView` mounted
/// behind the toggle — matching what TabBarView already did (it builds both
/// of its only two children up front) — so switching the toggle back and
/// forth doesn't throw away either tab's already-fetched data and force a
/// refetch.
class SalesAnalysisScreen extends StatefulWidget {
  const SalesAnalysisScreen({super.key});

  @override
  State<SalesAnalysisScreen> createState() => _SalesAnalysisScreenState();
}

enum _ViewMode { chart, table }

class _SalesAnalysisScreenState extends State<SalesAnalysisScreen> {
  // Defaults to table — Craig, 2026-08-26: "Toggle Table / Chart defaults to
  // Table" (carried over from the old TabBar's initialIndex: 1).
  _ViewMode _mode = _ViewMode.table;

  // Handed up by the two IndexedStack children once each mounts (see
  // DocumentAnalysisView.onExportReady's own doc comment) — this screen's
  // one DataExportButtons row needs to export whichever tab is actually on
  // screen, not always the same one. Plain fields, not State reassigned via
  // setState: nothing needs to rebuild when these become non-null, they
  // just need to hold the latest value by the time someone actually presses
  // Export, which is always well after both children have mounted.
  Future<ExportData> Function()? _tableExporter;
  Future<ExportData> Function()? _chartExporter;

  Future<ExportData> _export() {
    final exporter = _mode == _ViewMode.table ? _tableExporter : _chartExporter;
    if (exporter == null) {
      // Shouldn't be reachable in practice (both tabs mount and register
      // their exporter before a user can click anything), but a clear
      // message beats a null-check crash if it ever is.
      throw const ExportUnavailableException('Still loading — try again in a moment.');
    }
    return exporter();
  }

  @override
  Widget build(BuildContext context) {
    return AppShell(
      title: 'Sales Analysis',
      currentRoute: '/sales-analysis',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Toggle + export buttons share one row, spaceBetween, left/right/
          // top 16 — the same shape as YTD Comparative's ValueGpToggle +
          // DataExportButtons row (ytd_comparative_screen.dart). Craig,
          // 2026-08-27, cosmetic fix: first pass only inset the toggle
          // itself, leaving the export buttons stacked on their own line
          // below (inside DocumentAnalysisView) instead of sharing this row
          // — "It is still not correct. Please refer to the alignment on
          // YTD Comparative screen," with a screenshot circling both
          // controls to show they belong on one row. DocumentAnalysisView's
          // own copy of the export buttons is suppressed here
          // (showExportButtons: false) since this row now renders them
          // instead; Quote/Sales Order Analysis are unaffected; they have no
          // toggle to share a row with, so they keep their own.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: SizedBox(
              width: double.infinity,
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 16,
                runSpacing: 12,
                children: [
                  SegmentedButton<_ViewMode>(
                    segments: const [
                      ButtonSegment(value: _ViewMode.chart, label: Text('Chart')),
                      ButtonSegment(value: _ViewMode.table, label: Text('Table')),
                    ],
                    selected: {_mode},
                    onSelectionChanged: (selection) => setState(() => _mode = selection.first),
                  ),
                  DataExportButtons(onExport: _export),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: IndexedStack(
              index: _mode.index,
              children: [
                _GraphTab(onExportReady: (fn) => _chartExporter = fn),
                DocumentAnalysisView(
                  documentKinds: const ['invoice', 'credit_note'],
                  showExportButtons: false,
                  onExportReady: (fn) => _tableExporter = fn,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Everything one load of the Graph tab needs: the actual-revenue rows
/// (unchanged from before) plus the current fiscal year's Target overlay
/// bars (2026-09-03) — bundled into one object/one Future rather than two
/// separately-tracked futures, since the target bars are themselves derived
/// FROM the actual-revenue rows in the 2+-filter case (see
/// _GraphTabState._loadTargetBars) and always need to be ready at the same
/// time the chart itself is built.
class _GraphData {
  final List<ConsolidatedSales> rows;

  /// One entry per fiscal month (`_months` order), for the CURRENT fiscal
  /// year only — Craig, 2026-09-03: "we are only doing this for the
  /// current fiscal year. No point in doing this for prior years agreed?"
  /// Null throughout when the target fetch itself failed (see
  /// _loadTargetBars) so a Budgets/Performance hiccup degrades to "no
  /// overlay" rather than breaking the whole chart.
  final List<num?> targetBars;

  /// The share actually applied at each month (`targetBars[i] / that
  /// month's winning basis's own actual`) — e.g. 0.422 for "42.2%". Only
  /// meaningful alongside `targetIsEstimated: true`; every entry is null for
  /// a real entered target (there's no "share" to speak of — it's just what
  /// was typed into Budgets). 2026-09-04, Craig, after having to reverse-
  /// engineer this exact percentage by hand to sanity-check a number:
  /// surfaced directly so nobody else has to.
  final List<double?> targetShareBars;

  /// Which basis produced each month's derived figure — e.g. "Item:
  /// Multistage Vertical Pump" or "Company" — see
  /// core/utils/target_overlay.dart's `deriveHierarchicalTarget`. Can
  /// genuinely differ month to month (one month's Item might have a real
  /// entered target while another month's doesn't, falling through to
  /// Company that month instead), which is why this is a per-month list
  /// rather than one label for the whole overlay. Null wherever
  /// `targetBars` is null, and always null for a real (non-estimated)
  /// target.
  final List<String?> targetBasisBars;

  /// True when `targetBars` is a derived, proportional estimate (2+
  /// dimension filters active at once — see core/utils/target_overlay.dart)
  /// rather than a real entered Budgets figure. Drives both the legend
  /// label and the bars' own visual treatment.
  final bool targetIsEstimated;

  const _GraphData({
    required this.rows,
    required this.targetBars,
    required this.targetShareBars,
    required this.targetBasisBars,
    required this.targetIsEstimated,
  });
}

class _GraphTab extends ConsumerStatefulWidget {
  const _GraphTab({this.onExportReady});

  /// Same handoff pattern as DocumentAnalysisView.onExportReady — this tab
  /// has no DataExportButtons of its own, the parent's shared row exports
  /// whichever tab is current.
  final ValueChanged<Future<ExportData> Function()>? onExportReady;

  @override
  ConsumerState<_GraphTab> createState() => _GraphTabState();
}

class _GraphTabState extends ConsumerState<_GraphTab> {
  ValueMeasure _measure = ValueMeasure.rValue;
  late final List<int> _fiscalYears;
  // Computed once at mount, same as _fiscalYears — this chart's category/
  // row ORDER is display-only, every lookup below is keyed by the calendar
  // month label itself (_groupByMonth), so a different rotation never
  // changes which value a point shows, only which month starts the x-axis.
  late final List<String> _months;
  // Pulled out to its own field (2026-09-04) — the original single use in
  // initState was a local, but _loadTargetBars' new trailing-window
  // calculation needs the client's own fiscal start month too (to map a
  // fiscal month label like 'Sep' back to the specific calendar date it
  // falls on in the current fiscal year, via calendarMonthStartFor).
  late final int _startMonth;
  late Future<_GraphData> _future;

  // Same overlapping-batch guard as dashboard_screen.dart's own
  // `_initialKpiLoadInFlight`/`_profileReloadQueued` — see that file's
  // profile-loaded `ref.listen` for the full reasoning (2026-09-03,
  // Section 62/65 of the Decisions doc).
  bool _initialLoadInFlight = true;
  bool _profileReloadQueued = false;

  // 2026-08-26 (Craig's global cross-dimension filters): same treatment as
  // ytd_comparative_screen.dart, which reads the exact same view — the 5
  // dimension filters and the global Month filter apply, Year does not
  // (this chart's whole point is a fixed trailing-3-fiscal-year trend).

  GlobalFilters _graphFilters(GlobalFilters filters) => filters.copyWith(fiscalYear: null);

  @override
  void initState() {
    super.initState();
    _startMonth = ref.read(fiscalYearStartMonthProvider).valueOrNull ?? 3;
    final currentFy = fiscalYearFor(DateTime.now(), startMonth: _startMonth);
    final historyYears = ref.read(fiscalYearHistoryYearsProvider).valueOrNull ?? 3;
    // Oldest-to-newest so the chart's series order (and its legend) reads
    // left-to-right the same way the lines do on screen.
    _fiscalYears = fiscalYearWindow(currentFy, historyYears);
    _months = fiscalMonthOrderFor(startMonth: _startMonth);
    _future = _load(ref.read(globalFiltersProvider))
      ..whenComplete(() {
        _initialLoadInFlight = false;
        // Same `mounted` guard dashboard_screen.dart's own equivalent
        // callback uses — the user may have navigated away before this
        // settles, and calling _refetch() (setState) after disposal would
        // throw.
        if (!mounted) return;
        if (_profileReloadQueued) {
          _profileReloadQueued = false;
          _refetch();
        }
      });
    widget.onExportReady?.call(_buildExportData);
  }

  void _refetch() {
    setState(() {
      _future = _load(ref.read(globalFiltersProvider));
    });
  }

  Future<_GraphData> _load(GlobalFilters filters) async {
    final repo = ref.read(salesRepositoryProvider);
    final rows = await repo.fetchConsolidatedSales(fiscalYears: _fiscalYears, filters: _graphFilters(filters));
    final target = await _loadTargetBars(filters: filters);
    return _GraphData(
      rows: rows,
      targetBars: target.bars,
      targetShareBars: target.shares,
      targetBasisBars: target.basisLabels,
      targetIsEstimated: target.isEstimated,
    );
  }

  /// Builds a filters object with ONLY `dimension` set — used by the 2+
  /// filter branch below to fetch one candidate basis's own actual revenue
  /// in isolation, ignoring whatever ELSE is currently filtered. `company`
  /// never reaches this (it's excluded from `SalesDimension.filterable`,
  /// the only source of `dimension` values this is ever called with) — the
  /// arm exists purely to satisfy the switch's exhaustiveness check.
  GlobalFilters _onlyDimension(SalesDimension dimension, FilterSelection selection) {
    return switch (dimension) {
      SalesDimension.salesPerson => GlobalFilters(salesPerson: selection),
      SalesDimension.category => GlobalFilters(category: selection),
      SalesDimension.customer => GlobalFilters(customer: selection),
      SalesDimension.item => GlobalFilters(item: selection),
      SalesDimension.branch => GlobalFilters(branch: selection),
      SalesDimension.company => const GlobalFilters(),
    };
  }

  Iterable<MonthlyValue> _asSeries(List<ConsolidatedSales> rows) => rows.map((r) => (month: r.month, value: r.value));

  /// Target overlay bars for the CURRENT fiscal year only (Craig,
  /// 2026-09-03 — see _GraphData's own doc comment). Three cases, per
  /// core/utils/target_overlay.dart:
  ///   - 0 dimension filters active: the real, entered Company target.
  ///   - exactly 1 active: that dimension+entity's own real entered target.
  ///   - 2+ active at once: no real target exists for that exact
  ///     combination (Decisions doc Section 58), so one is derived —
  ///     originally (Section 61) as a single month's share of whole-company
  ///     actual applied to the whole-company target; reworked 2026-09-04
  ///     (Craig, reviewing the mechanism end to end: "please build these")
  ///     into a trailing-window share against a hierarchical choice of
  ///     basis — see core/utils/target_overlay.dart's own doc comments for
  ///     the full reasoning behind both changes.
  /// Wrapped in try/catch: a failure here (a Budgets/Performance-side
  /// hiccup) degrades to "no overlay" rather than breaking the whole
  /// actual-revenue chart, which has nothing to do with Targets and
  /// worked fine long before this feature existed.
  Future<({List<num?> bars, List<double?> shares, List<String?> basisLabels, bool isEstimated})> _loadTargetBars({
    required GlobalFilters filters,
  }) async {
    final noOverlay = (
      bars: List<num?>.filled(_months.length, null),
      shares: List<double?>.filled(_months.length, null),
      basisLabels: List<String?>.filled(_months.length, null),
      isEstimated: false,
    );
    try {
      final repo = ref.read(salesRepositoryProvider);
      final single = singleActiveDimensionFilter(filters);
      final dimCount = activeDimensionFilterCount(filters);

      if (dimCount <= 1) {
        // Nothing filtered: default to the VIEWER'S OWN scope, not always
        // the whole company — Craig, 2026-09-03: "The dashboard must be
        // specific. i.e. User sees only their info. RegUsers sees their
        // branch and Admin sees everything," confirmed to apply here too.
        // A real single-dimension filter (`single != null`) always wins
        // regardless of level — the picker dialogs themselves already only
        // ever offer entities schema/018's RLS lets this login see, so
        // there's nothing further to scope there.
        final defaultScope = defaultTargetScope(ref.read(sessionProvider).value);
        final dimension = single?.dimension ?? defaultScope.dimension;
        final entityCode = single?.selection.code ?? defaultScope.entityCode;
        final byMonth = await _fetchTargetByMonth(
          dimension: dimension,
          entityCode: entityCode,
          fiscalMonthFilter: filters.fiscalMonth,
        );
        return (
          bars: [for (final m in _months) byMonth[m]],
          shares: List<double?>.filled(_months.length, null),
          basisLabels: List<String?>.filled(_months.length, null),
          isEstimated: false,
        );
      }

      // 2+ filters stacked. Every fetch below strips BOTH fiscalYear and
      // fiscalMonth — unlike `_graphFilters` (which deliberately KEEPS
      // fiscalMonth, narrowing the chart's own actual-revenue lines to just
      // that one month when a global Month filter is active), the
      // trailing-window sum below needs the months BEFORE whichever one
      // the global filter narrows display down to, so it can't reuse the
      // display-scoped `rows` this screen already fetched for the chart
      // itself. Month-narrowing for the overlay is instead applied once, at
      // the very end, to bars/shares/basisLabels together.
      final unrestrictedFilters = filters.copyWith(fiscalYear: null, fiscalMonth: null);
      final fullyFilteredSeries = _asSeries(
        await repo.fetchConsolidatedSales(fiscalYears: _fiscalYears, filters: unrestrictedFilters),
      ).toList();
      final totalActualSeries = _asSeries(await repo.fetchConsolidatedSales(fiscalYears: _fiscalYears)).toList();
      // For a non-admin login this resolves to null throughout (schema/018
      // doesn't grant User/RegUser the 'company' dimension) — the
      // hierarchical candidate list below still tries every ACTIVELY
      // filtered dimension's own target first, so this only matters as the
      // final fallback, and `deriveHierarchicalTarget` already degrades
      // gracefully (no estimated bar) if every candidate — Company
      // included — comes up empty for a given month.
      final companyTargetByMonth = await _fetchTargetByMonth(
        dimension: SalesDimension.company,
        entityCode: 'ALL',
        fiscalMonthFilter: null,
      );

      // One further actual-revenue fetch + one target fetch per ACTIVELY
      // filtered dimension, in the app's canonical dimension order
      // (SalesDimension.filterable) — each scoped to JUST that one filter,
      // so its own trailing-window sum genuinely represents "how much of MY
      // total came from this narrower slice," not diluted by whatever else
      // happens to also be filtered right now. Realistically 2-3 of these
      // for how this screen actually gets used (stacking all 5 at once
      // isn't a real workflow), so the extra round trips stay modest.
      final basisCandidates = <({String label, Map<String, num?> targetByMonth, List<MonthlyValue> ownSeries})>[];
      for (final dimension in SalesDimension.filterable) {
        final selection = filters.forDimension(dimension);
        if (selection == null) continue;
        final ownRows = await repo.fetchConsolidatedSales(
          fiscalYears: _fiscalYears,
          filters: _onlyDimension(dimension, selection),
        );
        final ownTargetByMonth = await _fetchTargetByMonth(
          dimension: dimension,
          entityCode: selection.code,
          fiscalMonthFilter: null,
        );
        basisCandidates.add((label: '${dimension.label}: ${selection.label}', targetByMonth: ownTargetByMonth, ownSeries: _asSeries(ownRows).toList()));
      }

      final bars = <num?>[];
      final shares = <double?>[];
      final basisLabels = <String?>[];

      for (final m in _months) {
        final endMonth = calendarMonthStartFor(_fiscalYears.last, m, startMonth: _startMonth);
        final filteredWindow = sumTrailingWindow(series: fullyFilteredSeries, endMonth: endMonth);

        // Most-specific-first, Company last — see
        // deriveHierarchicalTarget's own doc comment for why order matters
        // here (a narrower candidate that qualifies dilutes the estimate
        // through less unrelated data than Company would).
        final candidates = <TargetBasisCandidate>[
          for (final c in basisCandidates)
            TargetBasisCandidate(
              label: c.label,
              target: c.targetByMonth[m],
              ownActual: sumTrailingWindow(series: c.ownSeries, endMonth: endMonth),
            ),
          TargetBasisCandidate(
            label: 'Company',
            target: companyTargetByMonth[m],
            ownActual: sumTrailingWindow(series: totalActualSeries, endMonth: endMonth),
          ),
        ];

        final result = deriveHierarchicalTarget(candidates: candidates, filteredActual: filteredWindow);
        bars.add(result?.value);
        shares.add(result?.share);
        basisLabels.add(result?.basisLabel);
      }

      // Same scoping fetchDimensionPerformance's own p_fiscal_month param
      // gives, and what `_fetchTargetByMonth`'s own tail used to do for
      // this method before its fetches were all switched to
      // fiscalMonthFilter: null above: with a global Month filter active,
      // only that one month's bar (and its share/basis) should show.
      if (filters.fiscalMonth != null) {
        for (var i = 0; i < _months.length; i++) {
          if (_months[i] != filters.fiscalMonth) {
            bars[i] = null;
            shares[i] = null;
            basisLabels[i] = null;
          }
        }
      }

      return (bars: bars, shares: shares, basisLabels: basisLabels, isEstimated: true);
    } catch (_) {
      return noOverlay;
    }
  }

  /// A dimension+entity's real target, per fiscal month, straight off
  /// budget_figures/sales_forecast (BudgetRepository) rather than through
  /// v_dimension_performance/fn_dimension_performance_filtered.
  ///
  /// Craig, 2026-09-03: "if I filter a customer who has no sales transaction
  /// for September, Actual Revenue = 0 and Target does not show." Those two
  /// views/functions are built by joining budget/forecast ONTO actual sales
  /// (schema/021), so a fiscal month with zero actual rows for this exact
  /// dimension+entity never gets a row at all — dropping a perfectly real,
  /// entered target purely because nobody bought anything that month.
  /// budget_figures/sales_forecast have no fiscal_year column regardless
  /// (one figure per fiscal_month label, reused every year), so there's
  /// nothing actual-sales-shaped to join against in the first place — this
  /// reads both tables directly and resolves them with
  /// core/utils/target_overlay.dart's `resolveTarget`, sidestepping the
  /// dependency on actual sales entirely. Deliberately does NOT touch
  /// fetchDimensionPerformance/v_dimension_performance/fn_dimension_
  /// performance_filtered themselves — Performance Analysis still relies on
  /// those exactly as they are.
  Future<Map<String, num?>> _fetchTargetByMonth({
    required SalesDimension dimension,
    required String entityCode,
    String? fiscalMonthFilter,
  }) async {
    final budgetRepo = ref.read(budgetRepositoryProvider);
    final budgetRows = await budgetRepo.fetchBudget(dimension: dimension.dbValue, entityCode: entityCode);
    final forecastByMonth = await budgetRepo.fetchForecastValues(dimension: dimension.dbValue, entityCode: entityCode);
    final budgetByMonth = {for (final b in budgetRows) b.fiscalMonth: b.budgetValue};

    final full = {
      for (final m in _months) m: resolveTarget(budgetValue: budgetByMonth[m], forecastValue: forecastByMonth[m]),
    };
    if (fiscalMonthFilter == null) return full;
    // Same scoping fetchDimensionPerformance's own p_fiscal_month param used
    // to give: with a global Month filter active, only that one month's bar
    // should show, not all 12.
    return {for (final m in _months) m: m == fiscalMonthFilter ? full[m] : null};
  }

  /// A short form for the chart's y-axis gridlines — "R 1 234 567" doesn't
  /// fit in the tight margin those need, so this rounds to the nearest
  /// thousand/million instead. The hover/tap detail row still uses the full
  /// formatRand() precision (see _buildChart below).
  String _compactRand(num value) {
    final abs = value.abs();
    if (abs >= 1000000) return 'R${(value / 1000000).toStringAsFixed(1)}M';
    if (abs >= 1000) return 'R${(value / 1000).toStringAsFixed(0)}K';
    return 'R${value.toStringAsFixed(0)}';
  }

  @override
  Widget build(BuildContext context) {
    // ref.listen, not a manual diff-in-build + WidgetsBinding.
    // addPostFrameCallback — see document_analysis_view.dart's build() for
    // why that pattern was replaced (2026-08-26, Craig's branch filter bug
    // report).
    ref.listen<GlobalFilters>(globalFiltersProvider, (previous, next) => _refetch());

    // Refetch once the signed-in profile actually finishes loading — Craig,
    // 2026-09-03, reporting the identical race on the Dashboard: "Dashboard
    // opens and it shows 0 target. I navigate to another screen and then
    // back to Dashboard and it shows correctly." Root cause: initState's
    // `_load` call above reads `sessionProvider` synchronously via
    // `defaultTargetScope(ref.read(sessionProvider).value)` in
    // `_loadTargetBars`, which can run before SessionNotifier
    // (core/app_providers.dart) has finished its own async profile fetch —
    // on a fresh app load/sign-in, that read can land while the provider is
    // still `loading`/has no value yet, so `defaultTargetScope(null)` falls
    // back to the company-wide scope, invisible to a non-admin login under
    // RLS. This screen has the exact same `ref.read(sessionProvider).value`
    // call (see `_loadTargetBars` below) and so the exact same latent race,
    // even though it hadn't been reported here yet.
    //
    // Deliberately does NOT refetch immediately if the initial load is
    // still in flight (`_initialLoadInFlight`) — an earlier version of this
    // fix did, and firing a second overlapping query batch while the first
    // was still running is the most plausible cause of a real
    // `statement timeout` Craig hit retesting the Dashboard's identical
    // pattern (Wyzesales_Rebuild_Decisions.md Section 62/65). Queuing the
    // refetch instead, to run once the initial load settles, keeps at most
    // one batch in flight at a time.
    ref.listen<AsyncValue<Profile?>>(sessionProvider, (previous, next) {
      if (previous?.value != null || next.value == null) return;
      if (_initialLoadInFlight) {
        _profileReloadQueued = true;
      } else {
        _refetch();
      }
    });

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Wrap, not a bare Row — reflows instead of overflowing sideways
          // on a narrow window (Craig, 2026-08-26: "insert a scroll
          // function instead of truncating the data"). SizedBox(width:
          // double.infinity) forces the Wrap to the full row width so
          // spaceBetween has space to push the toggle to the right edge
          // (2026-08-26 follow-up) — a bare Wrap here would otherwise
          // shrink-wrap to just its two children and sit left-aligned,
          // silently ignoring the alignment.
          SizedBox(
            width: double.infinity,
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 16,
              runSpacing: 8,
              children: [
                Text(
                  'Trailing ${_fiscalYears.length} fiscal years, monthly.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                ValueGpToggle(value: _measure, onChanged: (v) => setState(() => _measure = v)),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: AsyncSection<_GraphData>(
              future: _future,
              isEmpty: (data) => data.rows.isEmpty,
              builder: (context, data) => Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: _buildChart(data),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // month label (e.g. 'Mar') -> fiscal year -> that month's row, matching
  // YTD Comparative's own grouping (each fiscal year visits a given
  // calendar month exactly once, so there's nothing to sum here). Shared by
  // the chart itself and by export, so both always agree on the same
  // grouping.
  Map<String, Map<int, ConsolidatedSales>> _groupByMonth(List<ConsolidatedSales> rows) {
    final byMonth = <String, Map<int, ConsolidatedSales>>{};
    for (final row in rows) {
      final label = DateFormat('MMM').format(row.month);
      byMonth.putIfAbsent(label, () => {})[row.fiscalYear] = row;
    }
    return byMonth;
  }

  // 2026-08-27, Craig: "On the sale analysis line chart if there is a 0
  // value the chart line disappears. Can it rather continue instead of
  // having a broken line." A month with genuinely zero invoice/credit_note
  // activity never gets a row from fetchConsolidatedSales at all (it's a
  // GROUP BY over the underlying facts — nothing to sum means no row, not
  // a row with 0s), which is indistinguishable, by absence alone, from a
  // future month in the current, still-partial fiscal year that simply
  // hasn't happened yet. TrendLineChart correctly breaks the line across a
  // real `null` (that's the "no data YET" case this was originally built
  // for) — the bug was treating BOTH cases as that same gap. Only a
  // still-future month of the current fiscal year should stay a gap;
  // every other missing row is a completed month that really did total
  // zero, and should plot as 0 so the line carries through it. Export uses
  // this same method (via `_buildExportData` below) so a "—" in the
  // exported file lines up exactly with a broken point on the chart.
  num? _valueFor(Map<String, Map<int, ConsolidatedSales>> byMonth, String month, int fiscalYear) {
    final row = byMonth[month]?[fiscalYear];
    if (row != null) return _measure == ValueMeasure.rValue ? row.value : row.profit;
    final currentFiscalMonthIndex = _months.indexOf(fiscalMonthLabelFor(DateTime.now()));
    // _fiscalYears is built via fiscalYearWindow(currentFy, historyYears) in
    // initState, which always places the current fiscal year last regardless
    // of the configured 3- or 5-year window length — so .last is always the
    // current (possibly still-partial) fiscal year, the only one any month
    // could still be "in the future" within.
    final isStillFuture = fiscalYear == _fiscalYears.last && _months.indexOf(month) > currentFiscalMonthIndex;
    return isStillFuture ? null : 0;
  }

  Future<ExportData> _buildExportData() async {
    final data = await _future;
    final byMonth = _groupByMonth(data.rows);
    final measureLabel = _measure == ValueMeasure.rValue ? 'R Value' : 'R Gross Profit';
    // Target is a Rand-revenue figure (Sales Budget) — only meaningful
    // alongside R Value, not R Gross Profit, same reasoning _buildChart
    // below uses to decide whether to pass targetBars to the chart at all.
    // Also skipped when every entry is null (a failed fetch, or genuinely
    // nothing entered) — same as the chart, no point in an all-dash column.
    final includeTarget = _measure == ValueMeasure.rValue && data.targetBars.any((v) => v != null);
    final targetHeader = includeTarget ? (data.targetIsEstimated ? 'Estimated Target (FY${_fiscalYears.last})' : 'Target (FY${_fiscalYears.last})') : null;
    // 2026-09-04, Craig — same "surface the actual percentage" request that
    // added it to the chart's own hover row: only meaningful for a derived
    // estimate (a real target has no "share"/"basis" to report), so these
    // two extra columns are skipped entirely for the exact-single-dimension
    // case, same as `includeTarget` itself already skips the whole Target
    // column when nothing was ever entered at all.
    final includeTargetBasis = includeTarget && data.targetIsEstimated;
    return ExportData(
      headers: [
        'Month',
        for (final fy in _fiscalYears) 'FY$fy',
        if (targetHeader != null) targetHeader,
        if (includeTargetBasis) 'Target Basis',
        if (includeTargetBasis) 'Target Share %',
      ],
      rows: [
        for (var i = 0; i < _months.length; i++)
          [
            _months[i],
            for (final fy in _fiscalYears) _formatOrDash(_valueFor(byMonth, _months[i], fy)),
            if (includeTarget) _formatOrDash(data.targetBars[i]),
            if (includeTargetBasis) data.targetBasisBars[i] ?? '—',
            if (includeTargetBasis) _formatShareOrDash(data.targetShareBars[i]),
          ],
      ],
      fileNameBase: 'wyzesales_sales_analysis_chart_${DateTime.now().millisecondsSinceEpoch}',
      title: 'WyzeSales — Sales Analysis ($measureLabel, trailing ${_fiscalYears.length} fiscal years)',
    );
  }

  String _formatOrDash(num? value) => value == null ? '—' : formatRand(value);

  String _formatShareOrDash(double? share) => share == null ? '—' : '${(share * 100).toStringAsFixed(1)}%';

  Widget _buildChart(_GraphData data) {
    final byMonth = _groupByMonth(data.rows);
    num? valueFor(String month, int fiscalYear) => _valueFor(byMonth, month, fiscalYear);

    // A genuinely distinct colour per fiscal year (2026-09-01, Craig: "Line
    // chart colours. Please can we have a separate colour for each set of
    // data") — replaces the earlier fading-neutral scheme, which collapsed
    // every year older than the second-to-last into the same grey and made
    // them hard to tell apart on a 5-year window. Reuses the exact 5-colour
    // palette SimplePieChart already uses for other multi-series breakdowns
    // elsewhere in the app (Dashboard's Top 5 pie), so a fiscal year's colour
    // here is visually consistent with the same idea of "distinct series"
    // used there, and 5 is exactly the largest history window this app
    // offers (Settings > Company, "Data history window"), so it never has to
    // repeat a colour.
    const seriesPalette = [AppColors.info, AppColors.positive, AppColors.teal, AppColors.accentPurple, AppColors.caution];
    final seriesColors = List<Color>.generate(_fiscalYears.length, (i) => seriesPalette[i % seriesPalette.length]);

    final series = [
      for (var i = 0; i < _fiscalYears.length; i++)
        TrendSeries(
          label: 'FY${_fiscalYears[i]}',
          color: seriesColors[i],
          values: [for (final month in _months) valueFor(month, _fiscalYears[i])],
        ),
    ];

    // Target is a Rand-revenue figure (Sales Budget) — showing it against R
    // Gross Profit lines would be comparing two different units, so the
    // overlay only appears for R Value. Originally tinted from the CURRENT
    // fiscal year's own line colour, but that meant the bars' actual colour
    // depended on the configured history-window length (e.g. AppColors.teal
    // — an amber, despite the name — for the default 3-year window), which
    // read as too pale/orange to Craig: "change the colour to a light blue
    // but also make it slightly darker so it is easier to read" (2026-09-03).
    // Fixed to AppColors.info (the app's one blue) at a higher, more opaque
    // alpha than before; the estimated (2+-filter) case stays visually
    // lighter than a real entered figure and keeps its "Estimated" label,
    // per Craig's earlier request not to blur a derived number with a real
    // one.
    // Also false when every entry is null (the target fetch failed, or
    // genuinely nothing has ever been entered for this combination) — no
    // point showing a legend entry and swatch for an overlay with no
    // visible bars behind it.
    final showTarget = _measure == ValueMeasure.rValue && data.targetBars.any((v) => v != null);
    final targetColor = AppColors.info.withValues(alpha: data.targetIsEstimated ? 0.30 : 0.45);
    final targetLabel = data.targetIsEstimated ? 'Estimated Target (FY${_fiscalYears.last})' : 'Target (FY${_fiscalYears.last})';
    // 2026-09-04, reworded alongside the trailing-window + hierarchical-
    // basis rework (target_overlay.dart) — the exact per-month percentage
    // and which basis produced it now show directly in the hover/tap detail
    // row (targetShareBars/targetBasisBars below), so this static blurb only
    // needs to explain the MECHANISM once, not repeat numbers that are
    // already on screen per month.
    const targetTooltip =
        'No target is entered for this exact combination of filters. One is derived instead: the most specific of the '
        'currently-filtered dimensions that has its own real entered target (falling back to the whole company if none '
        'does) is scaled by this combination\'s trailing-3-month share of that basis\'s own actual revenue. Hover a point '
        'to see the exact share and basis used for that month.';

    return TrendLineChart(
      categories: _months,
      series: series,
      axisValueFormatter: _compactRand,
      detailValueFormatter: (v) => formatRand(v),
      targetBars: showTarget ? data.targetBars : null,
      targetShareBars: showTarget ? data.targetShareBars : null,
      targetBasisBars: showTarget ? data.targetBasisBars : null,
      targetLabel: showTarget ? targetLabel : null,
      targetColor: showTarget ? targetColor : null,
      targetTooltip: showTarget && data.targetIsEstimated ? targetTooltip : null,
    );
  }
}
