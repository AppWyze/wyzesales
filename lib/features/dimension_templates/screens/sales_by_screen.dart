import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../../core/app_providers.dart';
import '../../../core/constants/fiscal.dart';
import '../../../core/filters/global_filters.dart';
import '../../../core/utils/formatters.dart';
import '../../../shared/widgets/app_shell.dart';
import '../../../shared/widgets/async_section.dart';
import '../../../shared/widgets/boxed_dropdown.dart';
import '../../../shared/widgets/data_export_buttons.dart';
import '../../../shared/widgets/responsive_data_table.dart';
import '../../../shared/widgets/value_gp_toggle.dart';

/// One of the 3 parameterized templates replacing the old app's 15
/// dimension-duplicated screens (Wyzesales_Screens_and_Recommendations.md
/// Section 3). Per-entity rows, 3 fiscal-year columns + variance %, and the
/// 3 most recent individual months + variance %, side by side.
class SalesByScreen extends ConsumerStatefulWidget {
  const SalesByScreen({
    super.key,
    required this.dimension,
    this.highlightCode,
    this.initialRank,
    this.initialPeriod,
    this.initialMeasure,
  });

  final SalesDimension dimension;

  /// Set by the Dashboard's pie-chart drill-down (2026-08-26, via
  /// /sales-by/:dimension?highlight=<code>) — pins that entity's row to the
  /// top of the table with a highlighted background, rather than filtering
  /// everything else out, so the rest of the dimension stays visible for
  /// comparison. Dismissible via the banner's close button, which just
  /// clears the local highlight state (the route itself is left alone).
  ///
  /// 2026-08-27: the top-bar search used to set this too (arriving here
  /// with the searched entity pinned to the top rather than filtered) —
  /// Craig asked for that to become a real global filter instead ("Exactly
  /// the same way as if I filtered on Sales Person Sarah"), so picking a
  /// top-bar search result no longer navigates here at all; see
  /// top_bar_search.dart. This field is now set only by the pie-chart
  /// drill-down.
  final String? highlightCode;

  /// Only set by the Dashboard's pie-chart drill-down (2026-08-26, Craig:
  /// "Top 5 Customers must show Sales by Customer formatted top 5 in
  /// descending order. Bottom 5 would show in ascending order etc.") —
  /// `initialRank` is one of the Dashboard's rank-mode names ('top5'/
  /// 'bottom5'/'diminishing5'/'growth5'), `initialPeriod` is 'mtd' or 'ytd',
  /// and `initialMeasure` is 'rValue' or 'grossProfit'. Together they pick
  /// which column this screen opens sorted by (and in which direction) so
  /// the table matches whatever chart/mode was actually clicked, instead of
  /// always defaulting to "current FY, highest first."
  final String? initialRank;
  final String? initialPeriod;
  final String? initialMeasure;

  @override
  ConsumerState<SalesByScreen> createState() => _SalesByScreenState();
}

/// Where a fiscal-year or recent-month's value/variance column sits, once
/// this data's actual shape (the configured 3- or 5-fiscal-year history
/// window — Settings > Company, "Data history window" — but only 0-3 recent
/// months depending on how much data actually exists) is known — used both to sort
/// by whichever column a click lands on, and to resolve a drill-down's rank
/// mode onto the matching column (2026-08-26).
class _ColumnPositions {
  const _ColumnPositions({
    required this.currentFYValue,
    this.currentFYVariance,
    this.latestMonthValue,
    this.latestMonthVariance,
  });

  final int currentFYValue;
  final int? currentFYVariance;
  final int? latestMonthValue;
  final int? latestMonthVariance;
}

class _SalesByScreenState extends ConsumerState<SalesByScreen> {
  ValueMeasure _measure = ValueMeasure.rValue;

  // Column 0 is the dimension-name column; every column after that is
  // either a fiscal-year value, a "vs prior FY" variance, a recent-month
  // value, or a "vs prior month" variance, in the same left-to-right order
  // _buildTable lays them out in below. Defaults to the current FY,
  // descending — this table's original default before column-click sorting
  // existed (2026-08-26, Craig: "sort ascending or descending order by
  // clicking on a column header"). Column 1 specifically because the fiscal-
  // year columns are now newest-first (2026-09-01, Craig: "the user having
  // to scroll to right to view the most recent data") — the current FY's
  // value column is always the very first column after the dimension name,
  // regardless of whether the history window is 3 or 5 years.
  int _sortColumnIndex = 1;
  bool _sortAscending = false;

  // True from initState/didUpdateWidget until the next _buildTable call
  // resolves widget.initialRank/initialPeriod into a concrete column index
  // — deferred rather than resolved immediately in initState, because which
  // column is "the latest month" depends on how many distinct recent months
  // the fetch actually returns, which isn't known until `data` has loaded.
  bool _rankPending = false;

  late Future<_SalesByData> _future;
  String? _highlightCode;

  // 2026-08-26 (Craig's global cross-dimension filters): Year is
  // deliberately NOT applied here — this screen's whole point is a fixed
  // 3-fiscal-year comparison window computed from "today", and a single
  // global Year wouldn't fit that shape without collapsing the very
  // comparison the screen exists to show; only the 5 dimension filters and
  // the global Month filter are passed through (see the ref.listen in
  // build() below). A dimension filter that happens to match
  // widget.dimension itself (e.g. viewing Sales by Customer with a global
  // Customer filter active) is NOT special-cased away — it just narrows the
  // table to that one entity's row, same as filtering any other dimension.

  ValueMeasure _measureFrom(String? value) {
    switch (value) {
      case 'grossProfit':
        return ValueMeasure.grossProfit;
      case 'rValue':
        return ValueMeasure.rValue;
      default:
        return _measure;
    }
  }

  @override
  void didUpdateWidget(covariant SalesByScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final dimensionChanged = oldWidget.dimension != widget.dimension;
    final measureChanged = oldWidget.initialMeasure != widget.initialMeasure && widget.initialMeasure != null;
    final rankChanged = oldWidget.initialRank != widget.initialRank || oldWidget.initialPeriod != widget.initialPeriod;
    final highlightChanged = oldWidget.highlightCode != widget.highlightCode;
    if (!dimensionChanged && !measureChanged && !rankChanged && !highlightChanged) return;
    setState(() {
      if (highlightChanged) _highlightCode = widget.highlightCode;
      if (measureChanged) _measure = _measureFrom(widget.initialMeasure);
      if (rankChanged) _rankPending = true;
      // Fixes a pre-existing bug: this used to reassign _future without a
      // setState() wrapper, so a dimension switch via the switcher dropdown
      // didn't reliably repaint the AsyncSection into its loading state
      // straight away.
      if (dimensionChanged || measureChanged) _future = _load();
    });
  }

  @override
  void initState() {
    super.initState();
    _highlightCode = widget.highlightCode;
    _measure = _measureFrom(widget.initialMeasure);
    _rankPending = widget.initialRank != null && widget.initialPeriod != null;
    _future = _load();
  }

  Future<_SalesByData> _load() async {
    final currentFy = fiscalYearFor(DateTime.now(), startMonth: ref.read(fiscalYearStartMonthProvider).valueOrNull ?? 3);
    final historyYears = ref.read(fiscalYearHistoryYearsProvider).valueOrNull ?? 3;
    final fiscalYears = fiscalYearWindow(currentFy, historyYears);
    final filters = ref.read(globalFiltersProvider);

    final rows = await ref.read(salesRepositoryProvider).fetchDimensionMonthlySales(
          dimension: widget.dimension,
          fiscalYears: fiscalYears,
          filters: filters,
        );

    final names = await ref.read(referenceDataRepositoryProvider).namesFor(widget.dimension);

    final months = rows.map((r) => r.month).toSet().toList()..sort((a, b) => b.compareTo(a));
    final recentMonths = months.take(3).toList();

    final yearTotals = <String, Map<int, num>>{};
    final monthTotals = <String, Map<DateTime, num>>{};
    for (final row in rows) {
      final value = _measure == ValueMeasure.rValue ? row.value : row.profit;
      yearTotals.putIfAbsent(row.entityCode, () => {});
      yearTotals[row.entityCode]![row.fiscalYear] = (yearTotals[row.entityCode]![row.fiscalYear] ?? 0) + value;
      if (recentMonths.contains(row.month)) {
        monthTotals.putIfAbsent(row.entityCode, () => {});
        monthTotals[row.entityCode]![row.month] = value;
      }
    }

    return _SalesByData(
      fiscalYears: fiscalYears,
      recentMonths: recentMonths,
      entityCodes: yearTotals.keys.toList(),
      yearTotals: yearTotals,
      monthTotals: monthTotals,
      names: names,
    );
  }

  // Recompute happens via _load() re-run; measure toggle re-derives totals
  // from the same underlying rows without a fresh network round trip.
  void _reloadWithNewMeasure(ValueMeasure measure) {
    setState(() {
      _measure = measure;
      _future = _load();
    });
  }

  void _onSort(int columnIndex, bool ascending) {
    setState(() {
      _sortColumnIndex = columnIndex;
      _sortAscending = ascending;
      _rankPending = false; // a manual header click always wins over a stale pending drill-down
    });
  }

  _ColumnPositions _columnPositions(_SalesByData data, List<DateTime> chronological) {
    var position = 1;
    int? currentFYValue;
    int? currentFYVariance;
    // Newest fiscal year first (2026-09-01, Craig: "the user having to
    // scroll to right to view the most recent data") — walked newest to
    // oldest so the current FY's value/variance columns are always captured
    // by the `??=` below on the FIRST iteration only, landing them at
    // positions 1/2 regardless of how many years the history window holds.
    // Each "vs" variance still compares to fiscalYears[i-1] — the
    // chronologically PRIOR year — not whichever column sits to its left.
    for (var i = data.fiscalYears.length - 1; i >= 0; i--) {
      currentFYValue ??= position;
      position++;
      if (i > 0) {
        currentFYVariance ??= position;
        position++;
      }
    }
    int? latestMonthValue;
    int? latestMonthVariance;
    for (var i = 0; i < chronological.length; i++) {
      latestMonthValue = position;
      position++;
      latestMonthVariance = null;
      if (i > 0) {
        latestMonthVariance = position;
        position++;
      }
    }
    return _ColumnPositions(
      // data.fiscalYears is never empty in practice (historyYears is always
      // 3 or 5), so the loop above always sets this on its first iteration —
      // the `??` fallback is just so the type checker doesn't need
      // currentFYValue itself to be nullable.
      currentFYValue: currentFYValue ?? 1,
      currentFYVariance: currentFYVariance,
      latestMonthValue: latestMonthValue,
      latestMonthVariance: latestMonthVariance,
    );
  }

  /// One value-extractor per column after the name column (index 0), in the
  /// same left-to-right order `_buildTable` lays the real columns out in.
  /// Variance columns extract the same percentage the cell itself displays
  /// — so clicking "vs FY2026" sorts by literally what's printed in that
  /// column, not some hidden number. That is a deliberate difference from
  /// the Dashboard's own Diminishing 5/Growth 5 ranking, which compares raw
  /// Rand amounts, not percentages (see _resolveInitialRank's doc comment).
  List<num? Function(String code)> _columnValueExtractors(_SalesByData data, List<DateTime> chronological) {
    final extractors = <num? Function(String code)>[];
    // Newest fiscal year first — see _columnPositions' doc comment. Walking
    // i from the end down to 0 makes the order extractors are appended in
    // match the new left-to-right column order exactly; "vs" still compares
    // to fiscalYears[i-1], the chronologically prior year.
    for (var i = data.fiscalYears.length - 1; i >= 0; i--) {
      final year = data.fiscalYears[i];
      extractors.add((code) => data.yearTotals[code]?[year]);
      if (i > 0) {
        final previousYear = data.fiscalYears[i - 1];
        extractors.add((code) => variancePercent(data.yearTotals[code]?[year], data.yearTotals[code]?[previousYear]));
      }
    }
    for (var i = 0; i < chronological.length; i++) {
      final month = chronological[i];
      extractors.add((code) => data.monthTotals[code]?[month]);
      if (i > 0) {
        final previousMonth = chronological[i - 1];
        extractors.add((code) => variancePercent(data.monthTotals[code]?[month], data.monthTotals[code]?[previousMonth]));
      }
    }
    return extractors;
  }

  /// Maps the Dashboard drill-down's rank/period query params onto a
  /// concrete (columnIndex, ascending) pair for this specific data —
  /// deferred until `data` has loaded (unlike a plain enum-based sort would
  /// be) because which column is "the latest month" depends on how many
  /// distinct recent months the fetch actually returned. MTD maps to the
  /// latest-month column, YTD to the current-FY column — the same two
  /// columns the Dashboard's MTD/YTD pies are themselves built from.
  ///
  /// Diminishing 5/Growth 5 map onto the "vs" variance column, which this
  /// table sorts by *percentage* (matching what that column displays) —
  /// the Dashboard's own pies rank Diminishing 5/Growth 5 by raw Rand
  /// change, not percentage, so a drill-down from one of those two modes
  /// opens this table pre-sorted by the closest matching visible column
  /// rather than an exact re-derivation of the pie's own ranking. Flagged
  /// rather than silently different: an entity can rank differently by
  /// percentage change than by Rand change (a large account's modest %
  /// swing can outweigh a small account's dramatic one), so the 5 rows this
  /// opens sorted to the top of won't always be pixel-identical to the 5
  /// wedges that were in the chart.
  (int, bool)? _resolveInitialRank(_SalesByData data, List<DateTime> chronological) {
    final rank = widget.initialRank;
    final period = widget.initialPeriod;
    if (rank == null || period == null) return null;
    final isMtd = period == 'mtd';
    final positions = _columnPositions(data, chronological);

    switch (rank) {
      case 'top5':
        final col = isMtd ? positions.latestMonthValue : positions.currentFYValue;
        return col == null ? null : (col, false);
      case 'bottom5':
        final col = isMtd ? positions.latestMonthValue : positions.currentFYValue;
        return col == null ? null : (col, true);
      case 'diminishing5':
        final col = isMtd
            ? (positions.latestMonthVariance ?? positions.latestMonthValue)
            : (positions.currentFYVariance ?? positions.currentFYValue);
        return col == null ? null : (col, true);
      case 'growth5':
        final col = isMtd
            ? (positions.latestMonthVariance ?? positions.latestMonthValue)
            : (positions.currentFYVariance ?? positions.currentFYValue);
        return col == null ? null : (col, false);
      default:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    // ref.listen, not a manual diff-in-build + WidgetsBinding.
    // addPostFrameCallback — see document_analysis_view.dart's build() for
    // why that pattern was replaced (2026-08-26, Craig's branch filter bug
    // report).
    ref.listen<GlobalFilters>(globalFiltersProvider, (previous, next) {
      setState(() => _future = _load());
    });

    return AppShell(
      title: 'Sales by ${widget.dimension.label}',
      currentRoute: '/sales-by/${widget.dimension.dbValue}',
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Wrap, not a bare Row — this header used to overflow sideways on
            // a narrow window instead of dropping the export/toggle group to
            // a new line (Craig, 2026-08-26: "insert a scroll function
            // instead of truncating the data" — reflow keeps every control
            // visible without a scroll gesture). SizedBox(width:
            // double.infinity) forces the Wrap to the full row width so
            // spaceBetween has space to push the second group to the right
            // edge (2026-08-26 follow-up) — a bare Wrap here would otherwise
            // shrink-wrap to just its two groups and sit left-aligned,
            // silently ignoring the alignment.
            SizedBox(
              width: double.infinity,
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 16,
                runSpacing: 12,
                children: [
                  _DimensionSwitcher(current: widget.dimension, routePrefix: '/sales-by'),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ValueGpToggle(value: _measure, onChanged: _reloadWithNewMeasure),
                      DataExportButtons(onExport: _buildExportData),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: AsyncSection<_SalesByData>(
                future: _future,
                isEmpty: (data) => data.entityCodes.isEmpty,
                builder: (context, data) {
                  final highlightName = _highlightCode == null ? null : (data.names[_highlightCode!] ?? _highlightCode);
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (highlightName != null) ...[
                        _HighlightBanner(
                          name: highlightName,
                          detail: _rankDescription,
                          onDismiss: () => setState(() => _highlightCode = null),
                        ),
                        const SizedBox(height: 12),
                      ],
                      Expanded(child: _buildTable(context, data)),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTable(BuildContext context, _SalesByData data) {
    // recentMonths is sorted most-recent-first; walked oldest-to-newest here
    // — same direction as the FY columns (FY2025 -> FY2026 -> FY2027, each
    // "vs" comparing back to the column on its left) — so "vs prior month"
    // reads left-to-right chronologically. Computed once and shared by the
    // header loop, the row-cell loop, and the sort machinery below, all of
    // which must agree on the same column order (a prior version had the
    // header loop and the cell loop iterating two different orderings,
    // which silently swapped two columns' data under each other's headers
    // — caught 2026-08-26 when Craig cross-checked the Dashboard's MTD pie
    // against this table).
    final chronological = data.recentMonths.reversed.toList();

    if (_rankPending) {
      final resolved = _resolveInitialRank(data, chronological);
      _sortColumnIndex = resolved?.$1 ?? 4;
      _sortAscending = resolved?.$2 ?? false;
      _rankPending = false;
    }

    final extractors = _columnValueExtractors(data, chronological);
    final entities = [...data.entityCodes]
      ..sort((a, b) {
        int cmp;
        if (_sortColumnIndex == 0) {
          cmp = (data.names[a] ?? a).compareTo(data.names[b] ?? b);
        } else {
          final idx = _sortColumnIndex - 1;
          final aValue = (idx >= 0 && idx < extractors.length) ? extractors[idx](a) ?? 0 : 0;
          final bValue = (idx >= 0 && idx < extractors.length) ? extractors[idx](b) ?? 0 : 0;
          cmp = aValue.compareTo(bValue);
        }
        return _sortAscending ? cmp : -cmp;
      });

    // Pinned to the top regardless of the active sort, not filtered in on
    // its own — see SalesByScreen.highlightCode's doc comment for why this
    // is a pin rather than a hard filter.
    final highlightCode = _highlightCode;
    if (highlightCode != null && entities.remove(highlightCode)) {
      entities.insert(0, highlightCode);
    }

    final monthFormat = DateFormat('MMM yy');

    return ResponsiveDataTable(
      sortColumnIndex: _sortColumnIndex,
      sortAscending: _sortAscending,
      // Totals is always rows[0] here — see `_totalsRow`'s own doc comment
      // — so it's always the one row frozen under the header (2026-08-27,
      // Craig: "lock the Headers and Totals so we don't lose them when
      // scrolling down").
      pinnedRowCount: 1,
      columns: [
        DataColumn(label: Text(widget.dimension.label), onSort: _onSort),
        // Newest fiscal year first — see _columnPositions' doc comment.
        for (var i = data.fiscalYears.length - 1; i >= 0; i--) ...[
          DataColumn(label: Text('FY${data.fiscalYears[i]}'), numeric: true, onSort: _onSort),
          if (i > 0) DataColumn(label: Text('vs FY${data.fiscalYears[i - 1]}'), numeric: true, onSort: _onSort),
        ],
        for (var i = 0; i < chronological.length; i++) ...[
          DataColumn(label: Text(monthFormat.format(chronological[i])), numeric: true, onSort: _onSort),
          if (i > 0) DataColumn(label: const Text('vs prior month'), numeric: true, onSort: _onSort),
        ],
      ],
      rows: [
        _totalsRow(context, data, chronological),
        ...entities.map((code) {
          final cells = <DataCell>[DataCell(Text(data.names[code] ?? code))];
          for (var i = data.fiscalYears.length - 1; i >= 0; i--) {
            final current = data.yearTotals[code]?[data.fiscalYears[i]];
            cells.add(DataCell(Text(formatRand(current))));
            if (i > 0) {
              final previous = data.yearTotals[code]?[data.fiscalYears[i - 1]];
              cells.add(DataCell(Text(_varianceLabel(current, previous))));
            }
          }
          for (var i = 0; i < chronological.length; i++) {
            final current = data.monthTotals[code]?[chronological[i]];
            cells.add(DataCell(Text(formatRand(current))));
            if (i > 0) {
              final previous = data.monthTotals[code]?[chronological[i - 1]];
              cells.add(DataCell(Text(_varianceLabel(current, previous))));
            }
          }
          return DataRow(
            color: code == highlightCode
                ? WidgetStatePropertyAll(Theme.of(context).colorScheme.primary.withValues(alpha: 0.12))
                : null,
            cells: cells,
          );
        }),
      ],
    );
  }

  /// Bold, pinned as the FIRST row (2026-08-27, Craig: "Does it make sense
  /// to have the Totals as the first line in a view?" — confirmed yes, app-
  /// wide, as part of the same pass that added real server-side pagination
  /// to the line-level Document Analysis tables; this screen isn't paginated
  /// — it's a bounded rollup, one row per entity — but moved for visual
  /// consistency with the tables that now are) rather than the last —
  /// inserted ahead of the sorted/pinned entity rows above so it always sits
  /// at the top regardless of the active column sort. Each "vs" variance
  /// column is
  /// recomputed from the two years'/months' TOTALS (a correct weighted
  /// figure), not an average of every entity's own variance — summing
  /// percentages that are each relative to a different entity's base would
  /// produce a number with no real meaning.
  DataRow _totalsRow(BuildContext context, _SalesByData data, List<DateTime> chronological) {
    num yearTotal(int year) => data.entityCodes.fold<num>(0, (sum, code) => sum + (data.yearTotals[code]?[year] ?? 0));
    num monthTotal(DateTime month) => data.entityCodes.fold<num>(0, (sum, code) => sum + (data.monthTotals[code]?[month] ?? 0));

    const style = TextStyle(fontWeight: FontWeight.bold);
    final cells = <DataCell>[const DataCell(Text('Total', style: style))];
    for (var i = data.fiscalYears.length - 1; i >= 0; i--) {
      final current = yearTotal(data.fiscalYears[i]);
      cells.add(DataCell(Text(formatRand(current), style: style)));
      if (i > 0) {
        final previous = yearTotal(data.fiscalYears[i - 1]);
        cells.add(DataCell(Text(_varianceLabel(current, previous), style: style)));
      }
    }
    for (var i = 0; i < chronological.length; i++) {
      final current = monthTotal(chronological[i]);
      cells.add(DataCell(Text(formatRand(current), style: style)));
      if (i > 0) {
        final previous = monthTotal(chronological[i - 1]);
        cells.add(DataCell(Text(_varianceLabel(current, previous), style: style)));
      }
    }
    return DataRow(
      color: WidgetStatePropertyAll(Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.04)),
      cells: cells,
    );
  }

  String _varianceLabel(num? current, num? previous) {
    final variance = variancePercent(current, previous);
    return variance == null ? '—' : formatPercent(variance);
  }

  /// Same column layout as _buildTable (dimension name, then a value/
  /// variance pair per fiscal year, then a value/variance pair per recent
  /// month), same sort order and highlight-pin currently on screen, and the
  /// same weighted-totals-row math as _totalsRow (recomputed from the
  /// summed columns, not averaged from each entity's own variance — see
  /// that method's own doc comment) — built from whatever `_future` already
  /// resolved to, since this screen holds its full per-dimension rollup in
  /// memory rather than a paginated page (same as Performance).
  Future<ExportData> _buildExportData() async {
    final data = await _future;
    final chronological = data.recentMonths.reversed.toList();
    final extractors = _columnValueExtractors(data, chronological);
    final entities = [...data.entityCodes]
      ..sort((a, b) {
        int cmp;
        if (_sortColumnIndex == 0) {
          cmp = (data.names[a] ?? a).compareTo(data.names[b] ?? b);
        } else {
          final idx = _sortColumnIndex - 1;
          final aValue = (idx >= 0 && idx < extractors.length) ? extractors[idx](a) ?? 0 : 0;
          final bValue = (idx >= 0 && idx < extractors.length) ? extractors[idx](b) ?? 0 : 0;
          cmp = aValue.compareTo(bValue);
        }
        return _sortAscending ? cmp : -cmp;
      });
    final highlightCode = _highlightCode;
    if (highlightCode != null && entities.remove(highlightCode)) {
      entities.insert(0, highlightCode);
    }

    final monthFormat = DateFormat('MMM yy');
    final headers = <String>[widget.dimension.label];
    // Newest fiscal year first — matches the on-screen table (see
    // _columnPositions' doc comment) so the export lines up with what's
    // displayed.
    for (var i = data.fiscalYears.length - 1; i >= 0; i--) {
      headers.add('FY${data.fiscalYears[i]}');
      if (i > 0) headers.add('vs FY${data.fiscalYears[i - 1]}');
    }
    for (var i = 0; i < chronological.length; i++) {
      headers.add(monthFormat.format(chronological[i]));
      if (i > 0) headers.add('vs prior month');
    }

    num yearTotal(int year) => data.entityCodes.fold<num>(0, (sum, code) => sum + (data.yearTotals[code]?[year] ?? 0));
    num monthTotal(DateTime month) => data.entityCodes.fold<num>(0, (sum, code) => sum + (data.monthTotals[code]?[month] ?? 0));

    final totalsRow = <String>['Total'];
    for (var i = data.fiscalYears.length - 1; i >= 0; i--) {
      final current = yearTotal(data.fiscalYears[i]);
      totalsRow.add(formatRand(current));
      if (i > 0) {
        final previous = yearTotal(data.fiscalYears[i - 1]);
        totalsRow.add(_varianceLabel(current, previous));
      }
    }
    for (var i = 0; i < chronological.length; i++) {
      final current = monthTotal(chronological[i]);
      totalsRow.add(formatRand(current));
      if (i > 0) {
        final previous = monthTotal(chronological[i - 1]);
        totalsRow.add(_varianceLabel(current, previous));
      }
    }

    final rows = <List<String>>[totalsRow];
    for (final code in entities) {
      final cells = <String>[data.names[code] ?? code];
      for (var i = data.fiscalYears.length - 1; i >= 0; i--) {
        final current = data.yearTotals[code]?[data.fiscalYears[i]];
        cells.add(formatRand(current));
        if (i > 0) {
          final previous = data.yearTotals[code]?[data.fiscalYears[i - 1]];
          cells.add(_varianceLabel(current, previous));
        }
      }
      for (var i = 0; i < chronological.length; i++) {
        final current = data.monthTotals[code]?[chronological[i]];
        cells.add(formatRand(current));
        if (i > 0) {
          final previous = data.monthTotals[code]?[chronological[i - 1]];
          cells.add(_varianceLabel(current, previous));
        }
      }
      rows.add(cells);
    }

    return ExportData(
      headers: headers,
      rows: rows,
      fileNameBase: 'sales_by_${widget.dimension.dbValue}',
      title: 'Sales by ${widget.dimension.label}',
    );
  }

  /// Only non-null right after arriving via a pie-chart drill-down (i.e.
  /// widget.initialRank/initialPeriod were set) — names the rank mode and
  /// period in the highlight banner so it's obvious the table is pre-sorted
  /// to match the chart that was clicked, not just pinning a row at random.
  String? get _rankDescription {
    final rank = widget.initialRank;
    final period = widget.initialPeriod;
    if (rank == null || period == null) return null;
    final periodLabel = period == 'mtd' ? 'MTD' : 'YTD';
    final rankLabel = switch (rank) {
      'top5' => 'Top 5',
      'bottom5' => 'Bottom 5',
      'diminishing5' => 'Diminishing 5',
      'growth5' => 'Growth 5',
      _ => rank,
    };
    return '$rankLabel · $periodLabel';
  }
}

/// Dismissible banner shown above the table when arriving via the
/// Dashboard's pie-chart drill-down — names the pinned entity so it's clear
/// why one row jumped to the top instead of just looking like a sorting
/// quirk. Dismissing just clears the local highlight; the table itself is
/// otherwise unaffected.
class _HighlightBanner extends StatelessWidget {
  const _HighlightBanner({required this.name, this.detail, required this.onDismiss});
  final String name;

  /// e.g. "Top 5 · MTD" — only set when arriving via a pie-chart drill-down;
  /// null for a plain top-bar-search visit, where there's no rank mode to
  /// describe.
  final String? detail;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final message = detail == null ? 'Showing $name pinned to the top.' : 'Showing $name pinned to the top — sorted to match $detail.';
    return Material(
      color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Icon(Icons.push_pin_outlined, size: 16, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(message, overflow: TextOverflow.ellipsis),
            ),
            IconButton(
              tooltip: 'Clear',
              icon: const Icon(Icons.close, size: 16),
              onPressed: onDismiss,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            ),
          ],
        ),
      ),
    );
  }
}

class _SalesByData {
  final List<int> fiscalYears;
  final List<DateTime> recentMonths; // most-recent-first
  final List<String> entityCodes;
  final Map<String, Map<int, num>> yearTotals;
  final Map<String, Map<DateTime, num>> monthTotals;
  final Map<String, String> names;

  const _SalesByData({
    required this.fiscalYears,
    required this.recentMonths,
    required this.entityCodes,
    required this.yearTotals,
    required this.monthTotals,
    required this.names,
  });
}

/// Small switcher so a user can jump between dimensions without returning to
/// the drawer — reuses the same /sales-by/:dimension, /budgets/:dimension,
/// /performance/:dimension route shape the templates already use.
class _DimensionSwitcher extends StatelessWidget {
  const _DimensionSwitcher({required this.current, required this.routePrefix});
  final SalesDimension current;
  final String routePrefix;

  @override
  Widget build(BuildContext context) {
    return BoxedDropdown<SalesDimension>(
      value: current,
      // 160 — standardized 2026-08-27 to match every other dimension
      // switcher in the app (Performance, Dashboard's breakdown picker):
      // Craig, "check the sizing and consistency of all of the filter
      // boxes across the application... keep them as small as reasonably
      // possible."
      width: 160,
      items: SalesDimension.values.map((d) => DropdownMenuItem(value: d, child: Text(d.label))).toList(),
      onChanged: (d) {
        if (d != null && d != current) context.go('$routePrefix/${d.dbValue}');
      },
    );
  }
}
