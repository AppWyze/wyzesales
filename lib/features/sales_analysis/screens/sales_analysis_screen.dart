import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../core/app_providers.dart';
import '../../../core/constants/fiscal.dart';
import '../../../core/filters/global_filters.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/utils/target_overlay.dart';
import '../../../data/models/client_dimension_config.dart';
import '../../../data/models/consolidated_sales.dart';
import '../../../data/models/profile.dart';
import '../../../data/models/reference_data.dart';
import '../../../shared/widgets/app_shell.dart';
import '../../../shared/widgets/async_section.dart';
import '../../../shared/widgets/data_export_buttons.dart';
import '../../../shared/widgets/document_analysis_view.dart';
import '../../../shared/widgets/entity_search_field.dart';
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

  // 2026-09-21 (schema/055) — the custom date-range filter Edgetec asked
  // for, scoped to Sales Analysis only (both tabs) per Craig's own
  // confirmation. Deliberately screen-local State, NOT part of the shared
  // `globalFiltersProvider` — every other screen (Dashboard, Budgets,
  // Performance, Sales By, YTD Comparative) reads from the monthly-
  // pre-aggregated rollup views, which carry no day-level detail to filter
  // by at all, so a date range picked here has nothing to mean on any of
  // them. Keeping it local also means navigating away and back leaves it
  // exactly as it was — it doesn't leak into the global Year/Month/Quarter
  // chips other screens show, and clearing it just means "go back to
  // whatever the global filters already say."
  DateTime? _fromDate;
  DateTime? _toDate;

  Future<void> _pickDateRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2015),
      lastDate: now,
      initialDateRange: _fromDate != null && _toDate != null ? DateTimeRange(start: _fromDate!, end: _toDate!) : null,
      helpText: 'Sales Analysis date range',
      // en_GB, not the app's default (no `locale`/`supportedLocales` is set
      // on MaterialApp.router, so Flutter's MaterialLocalizations falls
      // back to en_US) — 2026-09-22, Craig: "Format must be dd/mm/yyyy."
      // Overriding just this dialog's Localizations, rather than the whole
      // app's, keeps this scoped to the one thing Craig actually flagged;
      // formatters.dart's own hardcoded en_US currency formatting elsewhere
      // in the app is untouched.
      builder: (context, child) => Localizations.override(context: context, locale: const Locale('en', 'GB'), child: child),
    );
    if (picked == null) return;
    setState(() {
      _fromDate = picked.start;
      _toDate = picked.end;
    });
  }

  void _clearDateRange() => setState(() {
        _fromDate = null;
        _toDate = null;
      });

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
      // 2026-09-22, Craig: "put the date range selection with the other
      // filters" — moved out of the Chart/Table toggle row (below) into the
      // shared GlobalFilterBar strip, alongside Year/Month/Quarter, even
      // though its state stays screen-local (see `_fromDate`/`_toDate`'s own
      // doc comment for why it isn't part of globalFiltersProvider).
      //
      // 2026-09-23, Craig: "add the date range option into the filters drop
      // down and not as a selection on the screen" — `extraFilterBarChip`
      // now only renders once a range is actually picked (a removable chip,
      // same as every other active filter); picking it in the first place
      // goes through the "Add filter" dropdown itself via `extraFilterLabel`/
      // `onExtraFilterSelected` instead of a standalone always-visible
      // button sitting in the strip.
      extraFilterBarChip: _fromDate != null && _toDate != null
          ? _DateRangeControl(fromDate: _fromDate!, toDate: _toDate!, onPick: _pickDateRange, onClear: _clearDateRange)
          : null,
      extraFilterLabel: 'Date range',
      onExtraFilterSelected: _pickDateRange,
      // 2026-09-24, Craig: "Clear all needs to work for date range as well"
      // — GlobalFilterBar's "Clear all" button has no way to reach this
      // screen-local state on its own (see `_fromDate`/`_toDate`'s own doc
      // comment for why it deliberately isn't part of globalFiltersProvider)
      // without this passthrough.
      onExtraFilterCleared: _clearDateRange,
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
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      SegmentedButton<_ViewMode>(
                        segments: const [
                          ButtonSegment(value: _ViewMode.chart, label: Text('Chart')),
                          ButtonSegment(value: _ViewMode.table, label: Text('Table')),
                        ],
                        selected: {_mode},
                        onSelectionChanged: (selection) => setState(() => _mode = selection.first),
                      ),
                    ],
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
                _GraphTab(
                  fromDate: _fromDate,
                  toDate: _toDate,
                  onExportReady: (fn) => _chartExporter = fn,
                ),
                DocumentAnalysisView(
                  documentKinds: const ['invoice', 'credit_note'],
                  showExportButtons: false,
                  fromDate: _fromDate,
                  toDate: _toDate,
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

/// The active date-range filter's own removable chip — `_RemovableChip`-style
/// (global_filter_bar.dart's own styling, reused here rather than imported
/// since this one lives entirely outside `GlobalFilters`). Deliberately its
/// own small widget rather than inlined — both `onPick`/`onClear` are plain
/// callbacks, so this has no state of its own to manage. Rendered inside the
/// shared GlobalFilterBar strip via AppShell's `extraFilterBarChip`
/// (2026-09-22), not inline in this screen's own body — see
/// SalesAnalysisScreen.build's own comment on that.
///
/// 2026-09-23, Craig: "add the date range option into the filters drop down
/// and not as a selection on the screen" — this widget is now ONLY ever
/// built once a range is picked (SalesAnalysisScreen.build passes
/// `extraFilterBarChip: null` otherwise), so `fromDate`/`toDate` are
/// non-nullable and the "nothing picked yet" button branch this used to have
/// is gone — that job now belongs to the "Add filter" dropdown's own "Date
/// range" entry (`extraFilterLabel`/`onExtraFilterSelected`) instead.
/// Tapping the chip itself still reopens the picker (`onPick`), same as
/// every other InputChip in the app.
class _DateRangeControl extends StatelessWidget {
  const _DateRangeControl({required this.fromDate, required this.toDate, required this.onPick, required this.onClear});

  final DateTime fromDate;
  final DateTime toDate;
  final VoidCallback onPick;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    // dd/mm/yyyy — 2026-09-22, Craig: "Format must be dd/mm/yyyy" (the app
    // sets no `locale` on MaterialApp.router, so DateFormat's own implicit
    // default would otherwise follow whatever `Intl.systemLocale` resolves
    // to in the browser, not necessarily this).
    final format = DateFormat('dd/MM/yyyy');
    return InputChip(
      label: Text('${format.format(fromDate)} – ${format.format(toDate)}', style: const TextStyle(fontSize: 12)),
      avatar: const Icon(Icons.date_range, size: 16),
      onPressed: onPick,
      onDeleted: onClear,
      deleteIconColor: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      backgroundColor: AppColors.teal.withValues(alpha: 0.14),
      side: BorderSide.none,
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

  /// 2026-09-27, Craig: "Default to all years but if a year is selected then
  /// show only that year." The fiscal years this batch was actually fetched
  /// (and should be plotted) for — the full trailing window
  /// (`_GraphTabState._fiscalYears`) by default, or just the one year picked
  /// in the global Year filter when it's set (see `_load`, which resolves
  /// this once at fetch time — same "carry the resolved value alongside the
  /// data" reasoning as `_CompareGraphData.year`, so a fetch already in
  /// flight can't render against a different selection than the one it
  /// actually queried for). Deliberately its own field rather than reusing
  /// `_fiscalYears` directly in `_buildChart`/`_buildExportData` — those
  /// still need the REAL trailing window too, for the Target overlay's
  /// "current fiscal year" (`_fiscalYears.last`), which stays the actual
  /// current year regardless of which year is selected here.
  final List<int> years;

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
    required this.years,
    required this.rows,
    required this.targetBars,
    required this.targetShareBars,
    required this.targetBasisBars,
    required this.targetIsEstimated,
  });
}

/// The Chart tab's date-range mode (schema/055, 2026-09-21) — see
/// `_GraphTabState._loadRangeData`'s own doc comment. One entry per calendar
/// month touched by the picked range, index-aligned across all three lists;
/// `categories[i]` is that month's label (e.g. "Mar 2026").
class _DateRangeGraphData {
  final List<String> categories;
  final List<num?> values;
  final List<num?> profits;

  /// 2026-09-24, Craig: "When selecting a date range and there is a
  /// forecast (i.e. current year) then please show the forecast bars as
  /// well. If it is a potion for the month then divide the forecast by the
  /// days and multiply out. i.e. apportion." One entry per `categories`
  /// index, same alignment as `values`/`profits`. Sourced from the exact
  /// same `_loadTargetBars` call the non-range chart's own overlay reads
  /// (Budgets/Forecast, current fiscal year only — see `_GraphData
  /// .targetBars`' own doc comment for why it's current-year-only), not a
  /// separate fetch. Null wherever the calendar month falls outside the
  /// CURRENT fiscal year (a target never exists for any other one in this
  /// app) or wherever that fiscal month's own target/forecast is itself
  /// null. A category only partially covered by the picked range (the
  /// first or last month, when the range doesn't start/end on a calendar-
  /// month boundary) has its whole month's figure scaled down to just the
  /// days actually inside the range — see `_loadRangeData` for the exact
  /// apportionment.
  final List<num?> targetBars;
  final List<double?> targetShareBars;
  final List<String?> targetBasisBars;
  final bool targetIsEstimated;

  const _DateRangeGraphData({
    required this.categories,
    required this.values,
    required this.profits,
    required this.targetBars,
    required this.targetShareBars,
    required this.targetBasisBars,
    required this.targetIsEstimated,
  });
}

/// The Chart tab's dimension-comparison mode (2026-09-25, Craig: "select a
/// dimension... tick box next to each one and then we select as many as we
/// want and they will then chart... for the selected year"). Replaces the
/// normal "one line per fiscal year" comparison with "one line per ticked
/// entity" for a single fiscal year — the two comparisons (which entities,
/// which years) don't fit on one line chart at once (more than a handful of
/// lines stops being readable regardless of how they're coloured), so this
/// mode picks entities and holds years fixed at one, same as the normal mode
/// picks years and holds the filtered entity fixed at one. Month/quarter
/// granularity and R Value/R Gross Profit still apply exactly as they do in
/// every other mode.
///
/// Pre-aggregated here (entity code -> fiscal month label -> that month's R
/// Value/R Gross Profit) rather than stored as the raw
/// `fetchDimensionMonthlySales` rows the way `_GraphData.rows` stores its
/// own fetch — this mode's grouping key (entity code) differs from that
/// path's (fiscal year), and nothing else needs the raw rows, so there's no
/// reason to carry them past `_loadCompareData`.
class _CompareGraphData {
  final Map<String, Map<String, ({num value, num profit})>> byEntityAndMonth;

  /// 2026-09-26, Craig: "I don't see the need to include the year selection
  /// as we can already select this from the main filter." The fiscal year
  /// this batch was fetched for — resolved once, in `_loadCompareData`, from
  /// the global Year filter (falling back to the current fiscal year when
  /// unset) and carried alongside the data rather than re-read from the
  /// global filter at render time, so a fetch already in flight can't render
  /// against a DIFFERENT year than the one it actually queried for if the
  /// global filter changes again before it resolves.
  final int year;

  const _CompareGraphData({required this.year, required this.byEntityAndMonth});
}

/// 2026-09-25, Craig: "The chart displays months on years. Can we have a
/// toggle to flip to Quarters. i.e. quarters on years." Only meaningful for
/// the normal trailing-fiscal-years comparison (`_buildChart`) — date-range
/// mode (`_buildRangeChart`) already buckets by calendar month across a
/// single, arbitrary span rather than comparing fiscal years against each
/// other, so there's no "years" axis there for a quarter rollup to sit
/// alongside; the toggle only renders when `!_hasDateRange` (see `build()`).
enum _ChartGranularity { months, quarters }

class _GraphTab extends ConsumerStatefulWidget {
  const _GraphTab({this.fromDate, this.toDate, this.onExportReady});

  /// 2026-09-21 (schema/055) — see SalesAnalysisScreen's own `_fromDate`/
  /// `_toDate` doc comment. When both are set, this tab shows a single
  /// calendar-month-bucketed line for exactly the picked range instead of
  /// its normal trailing-3-fiscal-year comparison — see `_loadRangeData`'s
  /// own doc comment for why that comparison has no sensible reading for an
  /// arbitrary date span in the first place.
  final DateTime? fromDate;
  final DateTime? toDate;

  /// Same handoff pattern as DocumentAnalysisView.onExportReady — this tab
  /// has no DataExportButtons of its own, the parent's shared row exports
  /// whichever tab is current.
  final ValueChanged<Future<ExportData> Function()>? onExportReady;

  @override
  ConsumerState<_GraphTab> createState() => _GraphTabState();
}

class _GraphTabState extends ConsumerState<_GraphTab> {
  ValueMeasure _measure = ValueMeasure.rValue;

  // 2026-09-25, Craig — see `_ChartGranularity`'s own doc comment. Plain
  // screen-local State, same treatment as `_measure` above: purely a
  // client-side rebuild against the already-fetched `_GraphData`/`_future`,
  // no refetch needed (see `_buildChart`'s quarterly aggregation below), so
  // this never needs to touch `_refetch()`.
  _ChartGranularity _granularity = _ChartGranularity.months;
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
  Future<_GraphData>? _future;

  // 2026-09-21 (schema/055) — the date-range mode's own future, kept
  // entirely separate from `_future` above rather than trying to force both
  // shapes through one Future<T>. See `_hasDateRange`/`_loadRangeData`'s own
  // doc comments.
  Future<_DateRangeGraphData>? _rangeFuture;

  bool get _hasDateRange => widget.fromDate != null && widget.toDate != null;

  // 2026-09-25, Craig — see `_CompareGraphData`'s own doc comment. Which
  // entities, in which dimension, is screen-local state, same treatment as
  // `_fromDate`/`_toDate` on the parent screen: "tick several entities of
  // one dimension to compare" isn't a shape any OTHER screen's single-entity
  // global filter can represent. Which YEAR to plot them for is NOT
  // screen-local, though — see `_compareFuture`'s own doc comment just below
  // for why that one deliberately reads the global Year filter instead.
  ClientDimensionConfig? _compareDimension;
  List<CodeName> _compareEntities = const [];

  /// 2026-09-26, Craig: "I don't see the need to include the year selection
  /// as we can already select this from the main filter" — replaces this
  /// mode's original own year dropdown. The normal trailing-years chart
  /// (`_load`/`_displayYears`) shows every trailing year UNLESS the global
  /// Year filter narrows it to one; Compare mode has no "every trailing
  /// year" state to begin with (2026-09-25, Craig: "for the selected year"
  /// — it was always single-year), so it just always reads the global Year
  /// filter directly, falling back to the current fiscal year when unset.
  /// See `_loadCompareData` for where `filters.fiscalYear` is actually read.
  Future<_CompareGraphData>? _compareFuture;

  // Only meaningful outside date-range mode (see `_ChartGranularity`'s own
  // doc comment for why that mode has no "years" axis for this to sit
  // alongside either) — and only once at least one entity is actually
  // ticked; a dimension picked with nothing ticked yet falls back to the
  // normal trailing-years chart rather than rendering an empty one.
  bool get _isComparing => !_hasDateRange && _compareDimension != null && _compareEntities.isNotEmpty;

  // Which of the three Export functions the parent's shared Export button
  // should call right now — re-resolved (and re-registered via
  // `widget.onExportReady`) everywhere any of the three modes can turn on or
  // off: initState, didUpdateWidget (date range), and every Compare-state
  // change (see `_openCompareDialog`/`_clearCompare` below).
  Future<ExportData> Function() _currentExporter() {
    if (_hasDateRange) return _buildRangeExportData;
    if (_isComparing) return _buildCompareExportData;
    return _buildExportData;
  }

  // Same overlapping-batch guard as dashboard_screen.dart's own
  // `_initialKpiLoadInFlight`/`_profileReloadQueued` — see that file's
  // profile-loaded `ref.listen` for the full reasoning (2026-09-03,
  // Section 62/65 of the Decisions doc). Only meaningful for the normal
  // (non-range) path — date-range mode has no session-scoped Target logic
  // to race against (see `_loadRangeData`'s own doc comment), so it's simply
  // left at its default and never toggled while a range is active.
  bool _initialLoadInFlight = true;
  bool _profileReloadQueued = false;

  // 2026-08-26 (Craig's global cross-dimension filters): same treatment as
  // ytd_comparative_screen.dart, which reads the exact same view — the 5
  // dimension filters and the global Month filter apply here exactly as
  // `filters.toFilterParams()` sends them. Year is handled separately
  // (`_displayYears` below), never through this map — see that method's own
  // doc comment for why.
  GlobalFilters _graphFilters(GlobalFilters filters) => filters.copyWith(fiscalYear: null);

  /// 2026-09-27, Craig: "Default to all years but if a year is selected then
  /// show only that year." The trailing window (`_fiscalYears`) stays the
  /// default, but a picked global Year filter narrows the chart to just that
  /// one year — the Year dropdown's own options (global_filter_bar.dart) are
  /// always drawn from this exact same `_fiscalYears` window, so a selected
  /// year is always one already in it; there's no "selected a year outside
  /// the window" case to handle.
  ///
  /// Still passed as its own `fiscalYears:` fetch param rather than left in
  /// `filters.fiscalYear` for `_graphFilters`'s filter map to carry — the
  /// backend ANDs `p_fiscal_years` and `p_filters.fiscal_year` together when
  /// both are present, and leaving the single selected year in BOTH places
  /// would work by coincidence but only because they'd happen to agree;
  /// `_graphFilters` stripping it and this method being the one place that
  /// decides which years to fetch keeps that unambiguous.
  List<int> _displayYears(GlobalFilters filters) => filters.fiscalYear != null ? [filters.fiscalYear!] : _fiscalYears;

  @override
  void initState() {
    super.initState();
    _startMonth = ref.read(fiscalYearStartMonthProvider).valueOrNull ?? 3;
    final currentFy = fiscalYearFor(DateTime.now(), startMonth: _startMonth);
    final historyYears = ref.read(fiscalYearHistoryYearsProvider).valueOrNull ?? 3;
    // Oldest-to-newest so the chart's series order (and its legend) reads
    // left-to-right the same way the lines do on screen. Computed
    // unconditionally (even in date-range mode, where they go unused) —
    // cheap, no network round trip, and keeps this block identical to
    // before rather than adding a branch here too.
    _fiscalYears = fiscalYearWindow(currentFy, historyYears);
    _months = fiscalMonthOrderFor(startMonth: _startMonth);
    if (_hasDateRange) {
      _rangeFuture = _loadRangeData(widget.fromDate!, widget.toDate!);
    } else {
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
    }
    widget.onExportReady?.call(_currentExporter());
  }

  void _refetch() {
    setState(() {
      if (_hasDateRange) {
        _rangeFuture = _loadRangeData(widget.fromDate!, widget.toDate!);
      } else {
        _future = _load(ref.read(globalFiltersProvider));
        // Compare mode now reads the global Year filter directly
        // (`_loadCompareData`) rather than its own local state, so a Year
        // pick has to trigger a Compare refetch the same way it already
        // triggers this normal-mode one — `ref.listen<GlobalFilters>` in
        // build() calls this on every global filter change, Year included.
        if (_isComparing) _compareFuture = _loadCompareData();
      }
    });
  }

  /// The date range itself changing (picked, edited, or cleared) doesn't go
  /// through `globalFiltersProvider` at all — see `fromDate`/`toDate`'s own
  /// doc comment — so `ref.listen<GlobalFilters>` in `build()` below can't
  /// catch it; this is the equivalent hook for a plain constructor-param
  /// change, same as document_analysis_view.dart's identical override.
  /// Re-registers the export callback too — switching in or out of
  /// date-range mode also switches which of `_buildExportData`/
  /// `_buildRangeExportData` the parent's shared Export button should call.
  @override
  void didUpdateWidget(covariant _GraphTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.fromDate != oldWidget.fromDate || widget.toDate != oldWidget.toDate) {
      widget.onExportReady?.call(_currentExporter());
      _refetch();
    }
  }

  Future<_GraphData> _load(GlobalFilters filters) async {
    final repo = ref.read(salesRepositoryProvider);
    final years = _displayYears(filters);
    final rows = await repo.fetchConsolidatedSales(fiscalYears: years, filters: _graphFilters(filters));
    final target = await _loadTargetBars(filters: filters);
    return _GraphData(
      years: years,
      rows: rows,
      targetBars: target.bars,
      targetShareBars: target.shares,
      targetBasisBars: target.basisLabels,
      targetIsEstimated: target.isEstimated,
    );
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
          monthsFilter: _activePeriodMonths(filters),
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
      final unrestrictedFilters = filters.copyWith(fiscalYear: null, fiscalMonth: null, fiscalQuarter: null, fiscalQuarterMonths: null);
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
        monthsFilter: null,
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
          filters: GlobalFilters.only(dimension.dbValue, selection),
        );
        final ownTargetByMonth = await _fetchTargetByMonth(
          dimension: dimension,
          entityCode: selection.code,
          monthsFilter: null,
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
      // monthsFilter: null above: with a global Month OR Quarter filter
      // active, only that period's own bar(s) (and their share/basis)
      // should show. `_activePeriodMonths` (2026-09-07) generalizes the old
      // single-month check to either a 1-month (Month) or 3-month (Quarter)
      // set.
      final activePeriodMonths = _activePeriodMonths(filters);
      if (activePeriodMonths != null) {
        for (var i = 0; i < _months.length; i++) {
          if (!activePeriodMonths.contains(_months[i])) {
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
  /// The active Month/Quarter global filter, resolved to a set of fiscal
  /// month labels — a bare Month is a 1-element set, a Quarter is `filters.
  /// fiscalQuarterMonths` (already resolved to 3 labels — see GlobalFilters'
  /// own doc comment), neither active is null (no masking). The two are also
  /// kept mutually exclusive at selection time (GlobalFiltersNotifier), so
  /// at most one of them is ever actually driving this.
  Set<String>? _activePeriodMonths(GlobalFilters filters) {
    if (filters.fiscalMonth != null) return {filters.fiscalMonth!};
    if (filters.fiscalQuarterMonths != null) return filters.fiscalQuarterMonths!.toSet();
    return null;
  }

  Future<Map<String, num?>> _fetchTargetByMonth({
    required SalesDimension dimension,
    required String entityCode,
    Set<String>? monthsFilter,
  }) async {
    final budgetRepo = ref.read(budgetRepositoryProvider);
    final budgetRows = await budgetRepo.fetchBudget(dimension: dimension.dbValue, entityCode: entityCode);
    final forecastByMonth = await budgetRepo.fetchForecastValues(dimension: dimension.dbValue, entityCode: entityCode);
    final budgetByMonth = {for (final b in budgetRows) b.fiscalMonth: b.budgetValue};

    final full = {
      for (final m in _months) m: resolveTarget(budgetValue: budgetByMonth[m], forecastValue: forecastByMonth[m]),
    };
    if (monthsFilter == null) return full;
    // Same scoping fetchDimensionPerformance's own p_fiscal_month param used
    // to give: with a global Month or Quarter filter active, only that
    // period's own month(s) should show, not all 12.
    return {for (final m in _months) m: monthsFilter.contains(m) ? full[m] : null};
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

  /// Sales Analysis' Chart tab under a custom date range (schema/055,
  /// 2026-09-21) — Craig: "if the range is mar 15 2026 to june 12 2026 then
  /// show the partial data for March and the partial data for june and the
  /// full data for the in between." Replaces the normal trailing-3-fiscal-
  /// year, one-line-per-year comparison entirely — there's no sensible
  /// year-over-year reading of an arbitrary date span (which fiscal years
  /// would even be compared?) — with ONE line, bucketed by calendar month,
  /// sourced from the same per-line document data the Table tab reads
  /// (`fn_sales_documents_monthly_totals`, schema/055) rather than the
  /// fiscal-month-keyed monthly rollup `fetchConsolidatedSales` uses.
  ///
  /// 2026-09-24, Craig: "When selecting a date range and there is a
  /// forecast (i.e. current year) then please show the forecast bars as
  /// well." Budgets/Forecast are entered per FISCAL month, which has no
  /// clean correspondence to a boundary calendar month that's only
  /// partially inside the picked range — resolved per Craig's own
  /// instruction ("divide the forecast by the days and multiply out") by
  /// scaling that one fiscal month's whole-month figure down to the
  /// fraction of it actually covered by the range. A calendar month is
  /// never split across two fiscal months in this app (fiscal months are
  /// just calendar months relabelled — see fiscal.dart's own doc comments),
  /// so there's never more than one fiscal month's figure to apportion for
  /// any given category here.
  ///
  /// Both `value` and `profit` are computed here regardless of the CURRENT
  /// `_measure` (same reasoning as `_GraphData.rows` in the normal path) —
  /// toggling R Value/R Gross Profit is then just a rebuild against whichever
  /// list `_buildRangeChart`/`_buildRangeExportData` pick, not a re-fetch.
  /// Sparse server-side (a month with zero matching rows has no row at all —
  /// see `SalesRepository.fetchSalesDocumentsMonthlyTotals`'s own doc
  /// comment); filled in as a real 0 here, not left as a gap — unlike the
  /// normal chart's "still-future fiscal month" null, every month touched by
  /// a picked, definite date range has either real data or genuinely zero
  /// data, never an unknown future.
  Future<_DateRangeGraphData> _loadRangeData(DateTime fromDate, DateTime toDate) async {
    final repo = ref.read(salesRepositoryProvider);
    final filters = ref.read(globalFiltersProvider);
    final totals = await repo.fetchSalesDocumentsMonthlyTotals(
      documentKinds: const ['invoice', 'credit_note'],
      fromDate: fromDate,
      toDate: toDate,
      filters: filters.toFilterParams(),
    );
    final byMonth = {for (final t in totals) DateTime(t.monthStart.year, t.monthStart.month): t};

    // 2026-09-24 — see _DateRangeGraphData.targetBars' own doc comment.
    // Fetched once up front (same source as the non-range path's own
    // `_load`), then sliced/apportioned per calendar month below.
    final target = await _loadTargetBars(filters: filters);
    final currentFy = _fiscalYears.last;

    final categories = <String>[];
    final values = <num?>[];
    final profits = <num?>[];
    final targetBars = <num?>[];
    final targetShareBars = <double?>[];
    final targetBasisBars = <String?>[];
    final labelFormat = DateFormat('MMM yyyy');
    var cursor = DateTime(fromDate.year, fromDate.month);
    final end = DateTime(toDate.year, toDate.month);
    while (!cursor.isAfter(end)) {
      categories.add(labelFormat.format(cursor));
      final row = byMonth[cursor];
      values.add(row?.value ?? 0);
      profits.add(row?.profit ?? 0);

      // Apportionment — Craig: "if it is a potion for the month then divide
      // the forecast by the days and multiply out." Only the first and last
      // categories can ever be partial (every month strictly between them is
      // fully inside the picked range either way); a single-calendar-month
      // range is both at once.
      final daysInMonth = DateTime(cursor.year, cursor.month + 1, 0).day;
      final isFirstMonth = cursor.year == fromDate.year && cursor.month == fromDate.month;
      final isLastMonth = cursor.year == toDate.year && cursor.month == toDate.month;
      final daysIncluded = isFirstMonth && isLastMonth
          ? toDate.day - fromDate.day + 1
          : isFirstMonth
              ? daysInMonth - fromDate.day + 1
              : isLastMonth
                  ? toDate.day
                  : daysInMonth;
      final fraction = daysIncluded / daysInMonth;

      // A target only ever exists for the CURRENT fiscal year (see
      // _GraphData.targetBars' own doc comment) — a category landing in any
      // other fiscal year gets no bar, same as the non-range chart never
      // draws one for a prior year's line.
      final fiscalYear = fiscalYearFor(cursor, startMonth: _startMonth);
      if (fiscalYear == currentFy) {
        final monthIndex = _months.indexOf(fiscalMonthLabelFor(cursor));
        final fullValue = target.bars[monthIndex];
        targetBars.add(fullValue == null ? null : fullValue * fraction);
        targetShareBars.add(target.shares[monthIndex]);
        targetBasisBars.add(target.basisLabels[monthIndex]);
      } else {
        targetBars.add(null);
        targetShareBars.add(null);
        targetBasisBars.add(null);
      }

      cursor = DateTime(cursor.year, cursor.month + 1);
    }
    return _DateRangeGraphData(
      categories: categories,
      values: values,
      profits: profits,
      targetBars: targetBars,
      targetShareBars: targetShareBars,
      targetBasisBars: targetBasisBars,
      targetIsEstimated: target.isEstimated,
    );
  }

  Future<ExportData> _buildRangeExportData() async {
    final data = await _rangeFuture!;
    final measureLabel = _measure == ValueMeasure.rValue ? 'R Value' : 'R Gross Profit';
    final dateFormat = DateFormat('yyyy-MM-dd');
    final fromLabel = dateFormat.format(widget.fromDate!);
    final toLabel = dateFormat.format(widget.toDate!);
    // Same target-column treatment as `_buildExportData` (2026-09-24, Craig
    // — see `_DateRangeGraphData.targetBars`' own doc comment) so an
    // exported date-range chart carries the same forecast figures the
    // on-screen overlay shows, apportionment included.
    final includeTarget = _measure == ValueMeasure.rValue && data.targetBars.any((v) => v != null);
    final targetHeader = includeTarget ? (data.targetIsEstimated ? 'Estimated Target (FY${_fiscalYears.last})' : 'Target (FY${_fiscalYears.last})') : null;
    final includeTargetBasis = includeTarget && data.targetIsEstimated;
    return ExportData(
      headers: [
        'Month',
        measureLabel,
        if (targetHeader != null) targetHeader,
        if (includeTargetBasis) 'Target Basis',
        if (includeTargetBasis) 'Target Share %',
      ],
      rows: [
        for (var i = 0; i < data.categories.length; i++)
          [
            data.categories[i],
            _formatOrDash(_measure == ValueMeasure.rValue ? data.values[i] : data.profits[i]),
            if (includeTarget) _formatOrDash(data.targetBars[i]),
            if (includeTargetBasis) data.targetBasisBars[i] ?? '—',
            if (includeTargetBasis) _formatShareOrDash(data.targetShareBars[i]),
          ],
      ],
      fileNameBase: 'wyzesales_sales_analysis_chart_${DateTime.now().millisecondsSinceEpoch}',
      title: 'WyzeSales — Sales Analysis ($measureLabel, $fromLabel to $toLabel)',
    );
  }

  /// Which dimensions Compare mode can offer — same list GlobalFilterBar's
  /// own "Add filter" dropdown already builds from (`drivesCrossFilter`
  /// excludes `company`, which isn't something to compare entities within —
  /// see that class' own doc comment), so Compare only ever offers a
  /// dimension a user could already narrow the whole app down to one entity
  /// of, never a dimension that doesn't make sense as a filter target at
  /// all.
  List<ClientDimensionConfig> _compareDimensions() =>
      ref.read(clientDimensionsProvider).valueOrNull?.where((d) => d.drivesCrossFilter).toList() ?? const <ClientDimensionConfig>[];

  Future<ClientDimensionConfig?> _pickCompareDimension(List<ClientDimensionConfig> dimensions) {
    return showDialog<ClientDimensionConfig>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Compare which dimension?'),
        children: [
          for (final dimension in dimensions)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(dimension),
              child: Text(dimension.displayLabel),
            ),
        ],
      ),
    );
  }

  /// Opens Compare mode's two-step picker — 2026-09-25, Craig: "select a
  /// dimension... tick box next to each one." `pickDimension: false` (the
  /// Compare chip's own tap handler, once a dimension is already active)
  /// skips straight to the entity checklist for the CURRENT dimension,
  /// matching how tapping the date-range chip reopens its picker directly
  /// rather than making the user pick "date range" again first.
  Future<void> _openCompareDialog({bool pickDimension = true}) async {
    final dimensions = _compareDimensions();
    if (dimensions.isEmpty) return;
    final dimension = (pickDimension || _compareDimension == null) ? await _pickCompareDimension(dimensions) : _compareDimension;
    if (dimension == null || !mounted) return;
    final selected = await showEntityMultiSelectDialog(
      context,
      dimension: dimension,
      title: 'Compare ${dimension.displayLabel}',
      // Only pre-tick the prior selection when re-editing the SAME
      // dimension — switching to a different dimension starts the tick list
      // empty rather than carrying over codes that belong to a different
      // dimension entirely.
      initiallySelected: dimension.dimensionKey == _compareDimension?.dimensionKey ? _compareEntities : const [],
    );
    if (selected == null || !mounted) return;
    if (selected.isEmpty) {
      _clearCompare();
      return;
    }
    setState(() {
      _compareDimension = dimension;
      _compareEntities = selected;
      _compareFuture = _loadCompareData();
    });
    widget.onExportReady?.call(_currentExporter());
  }

  void _clearCompare() {
    setState(() {
      _compareDimension = null;
      _compareEntities = const [];
      _compareFuture = null;
    });
    widget.onExportReady?.call(_currentExporter());
  }

  /// Fetches every ticked entity's month-level R Value/R Gross Profit for
  /// the global Year filter (`filters.fiscalYear`, falling back to the
  /// current fiscal year when unset — see `_CompareGraphData.year`'s own
  /// doc comment for why this mode reads that filter directly instead of
  /// its own local state), off the exact same `fetchDimensionMonthlySales`
  /// call the "Sales by [Dimension]" table already uses
  /// (sales_by_screen.dart's own `_load`) — no new backend query, just a
  /// different client-side grouping (by entity, for one year, instead of by
  /// year, for every entity).
  ///
  /// `filters.withDimension(dimension.dimensionKey, null)` strips only the
  /// dimension being compared out of whatever's globally filtered right now
  /// — every OTHER active filter (Branch, Sales Person, ...) still narrows
  /// this fetch, same as every other mode on this screen composes with the
  /// global filters; but if the dimension being compared also happened to be
  /// pinned to one entity globally, leaving that in place would make this
  /// fetch only ever return that one entity, defeating the whole point of
  /// comparing several.
  Future<_CompareGraphData> _loadCompareData() async {
    final dimension = _compareDimension;
    if (dimension == null || _compareEntities.isEmpty) {
      return _CompareGraphData(year: _fiscalYears.last, byEntityAndMonth: const {});
    }
    final tickedCodes = _compareEntities.map((e) => e.code).toSet();
    final filters = ref.read(globalFiltersProvider);
    final year = filters.fiscalYear ?? _fiscalYears.last;
    final rows = await ref.read(salesRepositoryProvider).fetchDimensionMonthlySales(
          dimension: dimension.dimensionKey,
          fiscalYears: [year],
          filters: filters.withDimension(dimension.dimensionKey, null),
        );
    final byEntityAndMonth = <String, Map<String, ({num value, num profit})>>{};
    for (final row in rows) {
      if (!tickedCodes.contains(row.entityCode)) continue;
      final label = fiscalMonthLabelFor(row.month);
      byEntityAndMonth.putIfAbsent(row.entityCode, () => {});
      byEntityAndMonth[row.entityCode]![label] = (value: row.value, profit: row.profit);
    }
    return _CompareGraphData(year: year, byEntityAndMonth: byEntityAndMonth);
  }

  /// Same "null only means genuinely still-future" rule `_valueFor` uses for
  /// the normal trailing-years path — a month with no row for this entity is
  /// a real 0 (nothing sold that month) UNLESS `year` is the current,
  /// still-partial fiscal year AND this month hasn't happened yet, in which
  /// case it's a gap, not a zero.
  num? _compareValueFor(Map<String, ({num value, num profit})> monthMap, String month, int year) {
    final row = monthMap[month];
    if (row != null) return _measure == ValueMeasure.rValue ? row.value : row.profit;
    final currentFiscalMonthIndex = _months.indexOf(fiscalMonthLabelFor(DateTime.now()));
    final currentFy = fiscalYearFor(DateTime.now(), startMonth: _startMonth);
    final isStillFuture = year == currentFy && _months.indexOf(month) > currentFiscalMonthIndex;
    return isStillFuture ? null : 0;
  }

  /// Quarterly rollup for Compare mode — same "null only when every one of
  /// the 3 months is" reasoning as `_quarterlyValueFor` uses for the normal
  /// path, just keyed by this mode's own per-entity month map instead of
  /// `_groupByMonth`'s fiscal-year one.
  num? _compareQuarterlyValueFor(Map<String, ({num value, num profit})> monthMap, String quarterLabel, int year) {
    final monthValues = [
      for (final month in fiscalMonthsInQuarter(quarterLabel, startMonth: _startMonth)) _compareValueFor(monthMap, month, year),
    ];
    if (monthValues.every((v) => v == null)) return null;
    return monthValues.fold<num>(0, (sum, v) => sum + (v ?? 0));
  }

  /// One entity's value for one category (a month label, or — when
  /// `isQuarterly` — a quarter label), reading `_CompareGraphData` and
  /// falling through to `_compareValueFor`/`_compareQuarterlyValueFor`.
  /// Shared by `_buildCompareChart` and `_buildCompareExportData` so both
  /// read the exact same figure for the exact same cell.
  num? _compareEntityValue(_CompareGraphData data, CodeName entity, String category, bool isQuarterly) {
    final monthMap = data.byEntityAndMonth[entity.code] ?? const {};
    return isQuarterly
        ? _compareQuarterlyValueFor(monthMap, category, data.year)
        : _compareValueFor(monthMap, category, data.year);
  }

  Widget _buildCompareChart(_CompareGraphData data) {
    final isQuarterly = _granularity == _ChartGranularity.quarters;
    final categories = isQuarterly ? fiscalQuarterLabels : _months;
    // Same fixed 5-colour palette every other series list on this chart
    // already uses (_buildChart's own comment has the full reasoning) — here
    // assigned by tick ORDER rather than by fiscal year, so the same entity
    // keeps the same colour across a session as long as it isn't un-ticked
    // and re-ticked in a different order.
    const seriesPalette = [AppColors.info, AppColors.positive, AppColors.teal, AppColors.accentPurple, AppColors.caution];
    final series = [
      for (var i = 0; i < _compareEntities.length; i++)
        TrendSeries(
          label: _compareEntities[i].displayLabel,
          color: seriesPalette[i % seriesPalette.length],
          values: [for (final category in categories) _compareEntityValue(data, _compareEntities[i], category, isQuarterly)],
        ),
    ];
    // No Target overlay here (2026-09-25) — a target/forecast figure belongs
    // to one specific entity (or the whole company), and there's no single
    // clean "target" to overlay behind several different entities' own
    // lines at once. Worth revisiting once this first pass has been
    // reviewed, not before.
    return TrendLineChart(
      categories: categories,
      series: series,
      axisValueFormatter: _compactRand,
      detailValueFormatter: (v) => formatRand(v),
    );
  }

  Future<ExportData> _buildCompareExportData() async {
    final data = await _compareFuture!;
    final isQuarterly = _granularity == _ChartGranularity.quarters;
    final categories = isQuarterly ? fiscalQuarterLabels : _months;
    final measureLabel = _measure == ValueMeasure.rValue ? 'R Value' : 'R Gross Profit';
    final dimensionLabel = _compareDimension?.displayLabel ?? '';
    return ExportData(
      headers: [
        isQuarterly ? 'Quarter' : 'Month',
        for (final entity in _compareEntities) entity.displayLabel,
      ],
      rows: [
        for (final category in categories)
          [
            category,
            for (final entity in _compareEntities) _formatOrDash(_compareEntityValue(data, entity, category, isQuarterly)),
          ],
      ],
      fileNameBase: 'wyzesales_sales_analysis_chart_${DateTime.now().millisecondsSinceEpoch}',
      title: 'WyzeSales — Sales Analysis ($measureLabel, comparing $dimensionLabel, FY${data.year})',
    );
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

    // The global Year filter's raw value — null means "no year picked",
    // which is what tells the normal chart to default back to every
    // trailing year (`_displayYears`) and its header label below. Watched,
    // not read, so picking or clearing a Year updates this label the
    // instant it changes rather than lagging behind the refetch it also
    // triggers (`ref.listen<GlobalFilters>` above).
    final selectedYear = ref.watch(globalFiltersProvider).fiscalYear;
    // Compare mode's effective year — same fallback `_loadCompareData` uses
    // (`filters.fiscalYear ?? _fiscalYears.last`) — computed here too so the
    // header can show it immediately rather than waiting on `_compareFuture`
    // to resolve. Unlike the normal chart, Compare mode is never "every
    // year," so it always has SOME year to show, hence the fallback.
    final compareYear = selectedYear ?? _fiscalYears.last;

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
                  _hasDateRange
                      ? '${DateFormat('d MMM yyyy').format(widget.fromDate!)} – ${DateFormat('d MMM yyyy').format(widget.toDate!)}, monthly.'
                      : _isComparing
                          ? 'Comparing ${_compareEntities.length} of ${_compareDimension!.displayLabel}, FY$compareYear, '
                              '${_granularity == _ChartGranularity.quarters ? 'quarterly' : 'monthly'}.'
                          // 2026-09-27, Craig: "Default to all years but if
                          // a year is selected then show only that year." —
                          // mirrors `_displayYears`, which this label just
                          // describes rather than drives (the fetch itself
                          // already switched by the time this rebuilds).
                          : '${selectedYear != null ? 'FY$selectedYear' : 'Trailing ${_fiscalYears.length} fiscal years'}, '
                              '${_granularity == _ChartGranularity.quarters ? 'quarterly' : 'monthly'}.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    // 2026-09-25, Craig: "The chart displays months on
                    // years. Can we have a toggle to flip to Quarters. i.e.
                    // quarters on years." Only shown for the normal
                    // trailing-fiscal-years comparison — see
                    // `_ChartGranularity`'s own doc comment for why
                    // date-range mode has no "years" axis for this to apply
                    // to. A plain client-side toggle, same as `_measure`
                    // below it — both rebuild `_buildChart` against the
                    // already-fetched `_future`, no refetch needed.
                    if (!_hasDateRange)
                      SegmentedButton<_ChartGranularity>(
                        segments: const [
                          ButtonSegment(value: _ChartGranularity.months, label: Text('Months')),
                          ButtonSegment(value: _ChartGranularity.quarters, label: Text('Quarters')),
                        ],
                        selected: {_granularity},
                        onSelectionChanged: (selection) => setState(() => _granularity = selection.first),
                      ),
                    ValueGpToggle(value: _measure, onChanged: (v) => setState(() => _measure = v)),
                    // 2026-09-25, Craig: "select a dimension... tick box
                    // next to each one and then we select as many as we
                    // want and they will then chart... for the selected
                    // year." Same "button until picked, then a chip"
                    // pattern as the date-range control above — before a
                    // dimension's picked there's nothing to show a chip
                    // for, so a plain button opens the two-step picker
                    // instead. Only offered outside date-range mode — see
                    // `_isComparing`'s own doc comment.
                    if (!_hasDateRange)
                      _compareDimension == null
                          ? TextButton.icon(
                              onPressed: () => _openCompareDialog(),
                              icon: const Icon(Icons.compare_arrows, size: 16),
                              label: const Text('Compare entities'),
                            )
                          // 2026-09-26, Craig: "I don't see the need to
                          // include the year selection as we can already
                          // select this from the main filter" — replaces the
                          // local year dropdown that used to sit next to this
                          // chip. The year Compare mode is plotting is now
                          // the global Year filter (`compareYear`, computed
                          // above), so it's folded into the chip's own label
                          // instead of a separate control — there's nothing
                          // left here for a dropdown to pick.
                          : InputChip(
                              label: Text(
                                'Comparing ${_compareEntities.length} of ${_compareDimension!.displayLabel} (FY$compareYear)',
                                style: const TextStyle(fontSize: 12),
                              ),
                              avatar: const Icon(Icons.compare_arrows, size: 16),
                              onPressed: () => _openCompareDialog(pickDimension: false),
                              onDeleted: _clearCompare,
                              deleteIconColor: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                              visualDensity: VisualDensity.compact,
                              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              backgroundColor: AppColors.teal.withValues(alpha: 0.14),
                              side: BorderSide.none,
                            ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: _hasDateRange
                ? AsyncSection<_DateRangeGraphData>(
                    future: _rangeFuture!,
                    isEmpty: (data) => data.categories.isEmpty,
                    builder: (context, data) => Card(
                      margin: EdgeInsets.zero,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: _buildRangeChart(data),
                      ),
                    ),
                  )
                : _isComparing
                    ? AsyncSection<_CompareGraphData>(
                        future: _compareFuture!,
                        isEmpty: (data) => data.byEntityAndMonth.isEmpty,
                        builder: (context, data) => Card(
                          margin: EdgeInsets.zero,
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: _buildCompareChart(data),
                          ),
                        ),
                      )
                    : AsyncSection<_GraphData>(
                        future: _future!,
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

  /// 2026-09-25 — see `_ChartGranularity`'s own doc comment. Sums the 3
  /// months making up `quarterLabel` (via `fiscalMonthsInQuarter`) using
  /// `_valueFor` above, so it inherits that method's exact "null only means
  /// genuinely still-future" rule rather than a separate one: a quarter is
  /// null only when EVERY one of its 3 months is (the whole quarter hasn't
  /// happened yet); a quarter already partway through sums whatever real
  /// months exist so far (a still-future month inside it contributes 0, not
  /// a missing value) instead of hiding the running total until the quarter
  /// closes — same "show real partial data, don't hide it" reasoning behind
  /// `_valueFor`'s own 0-vs-null split (Craig, 2026-08-27: "if there is a 0
  /// value the chart line disappears... can it rather continue").
  num? _quarterlyValueFor(Map<String, Map<int, ConsolidatedSales>> byMonth, String quarterLabel, int fiscalYear) {
    final monthValues = [
      for (final month in fiscalMonthsInQuarter(quarterLabel, startMonth: _startMonth)) _valueFor(byMonth, month, fiscalYear),
    ];
    if (monthValues.every((v) => v == null)) return null;
    return monthValues.fold<num>(0, (sum, v) => sum + (v ?? 0));
  }

  /// Same rollup, for the Target overlay's monthly bars (`_GraphData
  /// .targetBars`, indexed by `_months`) — sums the 3 months' figures the
  /// same way. Deliberately takes the raw bars list rather than a
  /// `_GraphData`, since `_buildChart` calls this once per quarter with the
  /// same `data.targetBars` each time.
  num? _quarterlyTargetFor(List<num?> monthlyTargetBars, String quarterLabel) {
    final values = [
      for (final month in fiscalMonthsInQuarter(quarterLabel, startMonth: _startMonth)) monthlyTargetBars[_months.indexOf(month)],
    ];
    if (values.every((v) => v == null)) return null;
    return values.fold<num>(0, (sum, v) => sum + (v ?? 0));
  }

  Future<ExportData> _buildExportData() async {
    // Only ever called while !_hasDateRange (see initState/didUpdateWidget's
    // onExportReady registration) — _future is guaranteed set in that mode.
    final data = await _future!;
    final byMonth = _groupByMonth(data.rows);
    final measureLabel = _measure == ValueMeasure.rValue ? 'R Value' : 'R Gross Profit';
    // 2026-09-25, Craig — export mirrors whichever granularity the chart is
    // currently showing (see `_ChartGranularity`'s own doc comment), same as
    // it already mirrors `_measure`.
    final isQuarterly = _granularity == _ChartGranularity.quarters;
    final categories = isQuarterly ? fiscalQuarterLabels : _months;
    final targetBars = isQuarterly ? [for (final q in fiscalQuarterLabels) _quarterlyTargetFor(data.targetBars, q)] : data.targetBars;
    // Target is a Rand-revenue figure (Sales Budget) — only meaningful
    // alongside R Value, not R Gross Profit, same reasoning _buildChart
    // below uses to decide whether to pass targetBars to the chart at all.
    // Also skipped when every entry is null (a failed fetch, or genuinely
    // nothing entered) — same as the chart, no point in an all-dash column.
    // Same "current fiscal year only" suppression as `_buildChart`'s own
    // `showTarget` — see that comment for the reasoning.
    final includeTarget =
        _measure == ValueMeasure.rValue && data.years.contains(_fiscalYears.last) && targetBars.any((v) => v != null);
    final targetHeader = includeTarget ? (data.targetIsEstimated ? 'Estimated Target (FY${_fiscalYears.last})' : 'Target (FY${_fiscalYears.last})') : null;
    // 2026-09-04, Craig — same "surface the actual percentage" request that
    // added it to the chart's own hover row: only meaningful for a derived
    // estimate (a real target has no "share"/"basis" to report), so these
    // two extra columns are skipped entirely for the exact-single-dimension
    // case, same as `includeTarget` itself already skips the whole Target
    // column when nothing was ever entered at all. Also skipped entirely at
    // quarterly granularity (2026-09-25) — see `_buildChart`'s own comment
    // on why a quarter's target has no single share/basis to report.
    final includeTargetBasis = includeTarget && data.targetIsEstimated && !isQuarterly;
    // 2026-09-27, Craig: "Default to all years but if a year is selected
    // then show only that year." — mirrors `_buildChart`'s own switch from
    // `_fiscalYears` to `data.years`; see `_displayYears`'s doc comment.
    final yearsLabel = data.years.length == 1 ? 'FY${data.years.single}' : 'trailing ${data.years.length} fiscal years';
    return ExportData(
      headers: [
        isQuarterly ? 'Quarter' : 'Month',
        for (final fy in data.years) 'FY$fy',
        if (targetHeader != null) targetHeader,
        if (includeTargetBasis) 'Target Basis',
        if (includeTargetBasis) 'Target Share %',
      ],
      rows: [
        for (var i = 0; i < categories.length; i++)
          [
            categories[i],
            for (final fy in data.years)
              _formatOrDash(isQuarterly ? _quarterlyValueFor(byMonth, categories[i], fy) : _valueFor(byMonth, categories[i], fy)),
            if (includeTarget) _formatOrDash(targetBars[i]),
            if (includeTargetBasis) data.targetBasisBars[i] ?? '—',
            if (includeTargetBasis) _formatShareOrDash(data.targetShareBars[i]),
          ],
      ],
      fileNameBase: 'wyzesales_sales_analysis_chart_${DateTime.now().millisecondsSinceEpoch}',
      title: 'WyzeSales — Sales Analysis ($measureLabel, $yearsLabel${isQuarterly ? ', quarterly' : ''})',
    );
  }

  String _formatOrDash(num? value) => value == null ? '—' : formatRand(value);

  String _formatShareOrDash(double? share) => share == null ? '—' : '${(share * 100).toStringAsFixed(1)}%';

  Widget _buildChart(_GraphData data) {
    final byMonth = _groupByMonth(data.rows);
    num? valueFor(String month, int fiscalYear) => _valueFor(byMonth, month, fiscalYear);

    // 2026-09-25, Craig: "The chart displays months on years. Can we have a
    // toggle to flip to Quarters. i.e. quarters on years." — see
    // `_ChartGranularity`'s own doc comment.
    final isQuarterly = _granularity == _ChartGranularity.quarters;
    final categories = isQuarterly ? fiscalQuarterLabels : _months;

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
    // 2026-09-27, Craig: "Default to all years but if a year is selected
    // then show only that year." `data.years` is `_fiscalYears` itself by
    // default, or just the one picked year — see `_displayYears`'s own doc
    // comment. Colours still index off the full 5-colour palette rather than
    // being recomputed for a 1-entry list, so a single selected year keeps
    // whichever colour it already has in the unfiltered view (e.g. FY2025
    // reads the same amber whether it's showing alongside FY2026 or alone).
    const seriesPalette = [AppColors.info, AppColors.positive, AppColors.teal, AppColors.accentPurple, AppColors.caution];
    final seriesColors = List<Color>.generate(
      data.years.length,
      (i) => seriesPalette[_fiscalYears.indexOf(data.years[i]) % seriesPalette.length],
    );

    final series = [
      for (var i = 0; i < data.years.length; i++)
        TrendSeries(
          label: 'FY${data.years[i]}',
          color: seriesColors[i],
          values: [
            for (final category in categories)
              isQuarterly ? _quarterlyValueFor(byMonth, category, data.years[i]) : valueFor(category, data.years[i]),
          ],
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
    //
    // 2026-09-25 — rolled up to quarters too when that's the active
    // granularity, via `_quarterlyTargetFor`. `targetShareBars`/
    // `targetBasisBars` are NOT summed alongside it: each of a quarter's 3
    // months can genuinely resolve to a different basis (see
    // `_loadTargetBars`'s own per-month hierarchical fallback above), so
    // there's no single clean "X% of Y" to report for the quarter as a
    // whole — the bar itself still shows (a plain total), just without that
    // per-month detail in the hover row, and the legend tooltip explaining
    // the mechanism is suppressed too rather than left describing a detail
    // no longer there.
    final targetBars = isQuarterly ? [for (final q in fiscalQuarterLabels) _quarterlyTargetFor(data.targetBars, q)] : data.targetBars;
    final targetShareBars = isQuarterly ? List<double?>.filled(categories.length, null) : data.targetShareBars;
    final targetBasisBars = isQuarterly ? List<String?>.filled(categories.length, null) : data.targetBasisBars;
    // Target is always the CURRENT fiscal year's own budget (`_GraphData
    // .targetBars`'s own doc comment) — showing it overlaid on a single
    // PAST year's actuals (Year filter set to something other than the
    // current fiscal year) would be comparing that old year's real revenue
    // against this year's target, which isn't a comparison anyone asked
    // for. Suppressed whenever the current fiscal year isn't among the
    // years actually being plotted; unaffected the rest of the time, same
    // as before this mode existed.
    final showTarget =
        _measure == ValueMeasure.rValue && data.years.contains(_fiscalYears.last) && targetBars.any((v) => v != null);
    final targetColor = AppColors.info.withValues(alpha: data.targetIsEstimated ? 0.30 : 0.45);
    final targetLabel = data.targetIsEstimated ? 'Estimated Target (FY${_fiscalYears.last})' : 'Target (FY${_fiscalYears.last})';
    return TrendLineChart(
      categories: categories,
      series: series,
      axisValueFormatter: _compactRand,
      detailValueFormatter: (v) => formatRand(v),
      targetBars: showTarget ? targetBars : null,
      targetShareBars: showTarget ? targetShareBars : null,
      targetBasisBars: showTarget ? targetBasisBars : null,
      targetLabel: showTarget ? targetLabel : null,
      targetColor: showTarget ? targetColor : null,
      targetTooltip: showTarget && data.targetIsEstimated && !isQuarterly ? _targetTooltip : null,
    );
  }

  // 2026-09-04, reworded alongside the trailing-window + hierarchical-basis
  // rework (target_overlay.dart) — the exact per-month percentage and which
  // basis produced it now show directly in the hover/tap detail row
  // (targetShareBars/targetBasisBars), so this static blurb only needs to
  // explain the MECHANISM once, not repeat numbers that are already on
  // screen per month. Pulled out to a class-level constant (2026-09-24) so
  // both `_buildChart` and the date-range mode's `_buildRangeChart` share
  // the exact same wording rather than two copies drifting apart.
  static const String _targetTooltip =
      'No target is entered for this exact combination of filters. One is derived instead: the most specific of the '
      'currently-filtered dimensions that has its own real entered target (falling back to the whole company if none '
      'does) is scaled by this combination\'s trailing-3-month share of that basis\'s own actual revenue. Hover a point '
      'to see the exact share and basis used for that month.';

  /// Same target-overlay treatment as `_buildChart`, for the date-range
  /// mode's single line (2026-09-24, Craig — see `_DateRangeGraphData
  /// .targetBars`' own doc comment). Deliberately mirrors `_buildChart`'s
  /// colour/label logic exactly rather than factoring it out into one
  /// shared helper — the two callers read slightly different fields
  /// (`_fiscalYears.last` is still the right "current fiscal year" label in
  /// both cases, but one reads `data.rows`-derived series, the other
  /// `data.values`/`data.profits`), and the duplication here is small
  /// enough that a shared helper would need almost as many parameters as it
  /// saved lines.
  Widget _buildRangeChart(_DateRangeGraphData data) {
    final series = [
      TrendSeries(
        label: _measure == ValueMeasure.rValue ? 'R Value' : 'R Gross Profit',
        color: AppColors.teal,
        values: _measure == ValueMeasure.rValue ? data.values : data.profits,
      ),
    ];

    final showTarget = _measure == ValueMeasure.rValue && data.targetBars.any((v) => v != null);
    final targetColor = AppColors.info.withValues(alpha: data.targetIsEstimated ? 0.30 : 0.45);
    final targetLabel = data.targetIsEstimated ? 'Estimated Target (FY${_fiscalYears.last})' : 'Target (FY${_fiscalYears.last})';

    return TrendLineChart(
      categories: data.categories,
      series: series,
      axisValueFormatter: _compactRand,
      detailValueFormatter: (v) => formatRand(v),
      targetBars: showTarget ? data.targetBars : null,
      targetShareBars: showTarget ? data.targetShareBars : null,
      targetBasisBars: showTarget ? data.targetBasisBars : null,
      targetLabel: showTarget ? targetLabel : null,
      targetColor: showTarget ? targetColor : null,
      targetTooltip: showTarget && data.targetIsEstimated ? _targetTooltip : null,
    );
  }
}
