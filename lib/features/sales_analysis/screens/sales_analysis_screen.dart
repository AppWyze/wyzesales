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

  /// True when `targetBars` is a derived, proportional estimate (2+
  /// dimension filters active at once — see core/utils/target_overlay.dart)
  /// rather than a real entered Budgets figure. Drives both the legend
  /// label and the bars' own visual treatment.
  final bool targetIsEstimated;

  const _GraphData({required this.rows, required this.targetBars, required this.targetIsEstimated});
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
  late Future<_GraphData> _future;

  // 2026-08-26 (Craig's global cross-dimension filters): same treatment as
  // ytd_comparative_screen.dart, which reads the exact same view — the 5
  // dimension filters and the global Month filter apply, Year does not
  // (this chart's whole point is a fixed trailing-3-fiscal-year trend).

  GlobalFilters _graphFilters(GlobalFilters filters) => filters.copyWith(fiscalYear: null);

  @override
  void initState() {
    super.initState();
    final startMonth = ref.read(fiscalYearStartMonthProvider).valueOrNull ?? 3;
    final currentFy = fiscalYearFor(DateTime.now(), startMonth: startMonth);
    final historyYears = ref.read(fiscalYearHistoryYearsProvider).valueOrNull ?? 3;
    // Oldest-to-newest so the chart's series order (and its legend) reads
    // left-to-right the same way the lines do on screen.
    _fiscalYears = fiscalYearWindow(currentFy, historyYears);
    _months = fiscalMonthOrderFor(startMonth: startMonth);
    _future = _load(ref.read(globalFiltersProvider));
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
    final currentYearRows = rows.where((r) => r.fiscalYear == _fiscalYears.last).toList();
    final target = await _loadTargetBars(filters: filters, currentYearActualRows: currentYearRows);
    return _GraphData(rows: rows, targetBars: target.bars, targetIsEstimated: target.isEstimated);
  }

  /// Target overlay bars for the CURRENT fiscal year only (Craig,
  /// 2026-09-03 — see _GraphData's own doc comment). Three cases, per
  /// core/utils/target_overlay.dart:
  ///   - 0 dimension filters active: the real, entered Company target.
  ///   - exactly 1 active: that dimension+entity's own real entered target.
  ///   - 2+ active at once: no real target exists for that exact
  ///     combination (Decisions doc Section 58), so one is derived as this
  ///     combination's share of whole-company actual, applied to the
  ///     whole-company target — Craig's own worked example, confirmed with
  ///     him before building this.
  /// Wrapped in try/catch: a failure here (a Budgets/Performance-side
  /// hiccup) degrades to "no overlay" rather than breaking the whole
  /// actual-revenue chart, which has nothing to do with Targets and
  /// worked fine long before this feature existed.
  Future<({List<num?> bars, bool isEstimated})> _loadTargetBars({
    required GlobalFilters filters,
    required List<ConsolidatedSales> currentYearActualRows,
  }) async {
    try {
      final repo = ref.read(salesRepositoryProvider);
      final currentFy = _fiscalYears.last;
      final single = singleActiveDimensionFilter(filters);
      final dimCount = activeDimensionFilterCount(filters);

      if (dimCount <= 1) {
        final dimension = single?.dimension ?? SalesDimension.company;
        final entityCode = single?.selection.code ?? 'ALL';
        final rows = await repo.fetchDimensionPerformance(
          dimension: dimension,
          entityCode: entityCode,
          fiscalYear: currentFy,
          fiscalMonth: filters.fiscalMonth,
        );
        final byMonth = {for (final r in rows) r.fiscalMonth: r.targetValue};
        return (bars: [for (final m in _months) byMonth[m]], isEstimated: false);
      }

      final companyTargetRows = await repo.fetchDimensionPerformance(
        dimension: SalesDimension.company,
        entityCode: 'ALL',
        fiscalYear: currentFy,
        fiscalMonth: filters.fiscalMonth,
      );
      final totalActualRows = await repo.fetchConsolidatedSales(fiscalYears: [currentFy]);

      final companyTargetByMonth = {for (final r in companyTargetRows) r.fiscalMonth: r.targetValue};
      final totalActualByMonth = {for (final r in totalActualRows) DateFormat('MMM').format(r.month): r.value};
      final filteredActualByMonth = {for (final r in currentYearActualRows) DateFormat('MMM').format(r.month): r.value};

      final bars = [
        for (final m in _months)
          deriveProportionalTarget(
            companyTarget: companyTargetByMonth[m],
            totalActual: totalActualByMonth[m],
            filteredActual: filteredActualByMonth[m],
          ),
      ];
      return (bars: bars, isEstimated: true);
    } catch (_) {
      return (bars: List<num?>.filled(_months.length, null), isEstimated: false);
    }
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
    return ExportData(
      headers: ['Month', for (final fy in _fiscalYears) 'FY$fy', if (targetHeader != null) targetHeader],
      rows: [
        for (var i = 0; i < _months.length; i++)
          [
            _months[i],
            for (final fy in _fiscalYears) _formatOrDash(_valueFor(byMonth, _months[i], fy)),
            if (includeTarget) _formatOrDash(data.targetBars[i]),
          ],
      ],
      fileNameBase: 'wyzesales_sales_analysis_chart_${DateTime.now().millisecondsSinceEpoch}',
      title: 'WyzeSales — Sales Analysis ($measureLabel, trailing ${_fiscalYears.length} fiscal years)',
    );
  }

  String _formatOrDash(num? value) => value == null ? '—' : formatRand(value);

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
    const targetTooltip =
        'No target is entered for this exact combination of filters — this is this combination\'s share of whole-company '
        'actual revenue, applied to the whole-company target, one fiscal month at a time.';

    return TrendLineChart(
      categories: _months,
      series: series,
      axisValueFormatter: _compactRand,
      detailValueFormatter: (v) => formatRand(v),
      targetBars: showTarget ? data.targetBars : null,
      targetLabel: showTarget ? targetLabel : null,
      targetColor: showTarget ? targetColor : null,
      targetTooltip: showTarget && data.targetIsEstimated ? targetTooltip : null,
    );
  }
}
