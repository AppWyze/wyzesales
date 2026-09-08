import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../core/app_providers.dart';
import '../../../core/constants/fiscal.dart';
import '../../../core/filters/global_filters.dart';
import '../../../core/utils/formatters.dart';
import '../../../data/models/consolidated_sales.dart';
import '../../../shared/widgets/app_shell.dart';
import '../../../shared/widgets/async_section.dart';
import '../../../shared/widgets/data_export_buttons.dart';
import '../../../shared/widgets/responsive_data_table.dart';
import '../../../shared/widgets/value_gp_toggle.dart';

/// Month rows, one column per fiscal year, variance % between consecutive
/// years — Wyzesales_Screens_and_Recommendations.md Section 1. Reads
/// v_consolidated_sales (whole-company) for the same reason noted on Sales
/// Analysis' Graph tab: combining several of the old screen's filter
/// dimensions into one pivot isn't something the current rollup views
/// support in a single query yet — flagged as a follow-up, not silently
/// dropped.
class YtdComparativeScreen extends ConsumerStatefulWidget {
  const YtdComparativeScreen({super.key});

  @override
  ConsumerState<YtdComparativeScreen> createState() => _YtdComparativeScreenState();
}

class _YtdRow {
  final String monthLabel;
  final Map<int, num> yearValues;
  const _YtdRow(this.monthLabel, this.yearValues);
}

/// A single data column in the year comparison — either one fiscal year's
/// value, or the variance % between it and the next-older year.
///
/// 2026-09-08 (Craig, screenshots of the original app): columns render as
/// "newest year, next-older year, variance between those two, next-older
/// year, variance between THAT pair, ..." — e.g. for fiscal years
/// [2024, 2025, 2026]: FY2026, FY2025, vs FY2025 (2026-vs-2025), FY2024,
/// vs FY2024 (2025-vs-2024). That is deliberately NOT "each year
/// immediately followed by its own variance" (FY2026, vs FY2025, FY2025,
/// vs FY2024, FY2024), which is what this screen rendered before and which
/// put every variance one column too early compared to the original app.
class _YearColumn {
  const _YearColumn.value(this.year) : previousYear = null;
  const _YearColumn.variance(this.year, int previous) : previousYear = previous;

  /// The year this column is about. For a value column, the year whose
  /// total is shown. For a variance column, the NEWER of the two years
  /// being compared (matches the "vs FY<previousYear>" header label, which
  /// names the OLDER one).
  final int year;

  /// Non-null only for a variance column — the OLDER year [year] is being
  /// compared against.
  final int? previousYear;

  bool get isVariance => previousYear != null;
}

class _YtdComparativeScreenState extends ConsumerState<YtdComparativeScreen> {
  ValueMeasure _measure = ValueMeasure.rValue;
  late final List<int> _fiscalYears;
  late Future<List<ConsolidatedSales>> _future;

  // Month/ascending — the natural fiscal-month order (Mar -> Feb) this table
  // always rendered in, now user-adjustable via the column headers
  // (2026-08-26, Craig: "sort ascending or descending order by clicking on a
  // column header").
  int _sortColumnIndex = 0;
  bool _sortAscending = true;

  // 2026-08-26 (Craig's global cross-dimension filters): the 5 dimension
  // filters and the global Month filter both apply here (Month restricts
  // every fiscal-year column's sum down to that one fiscal month, still
  // compared across the same fiscal-year window) — Year does NOT, since this
  // screen's whole point is a fixed comparison window (3 or 5 fiscal years,
  // per the Settings > Company "Data history window" setting) computed from
  // "today", the same reasoning sales_by_screen.dart flags for its own FY
  // columns. The ref.listen in build() below tracks the full filter set so a
  // change on another screen still triggers a refetch here.

  GlobalFilters _ytdFilters(GlobalFilters filters) => filters.copyWith(fiscalYear: null);

  @override
  void initState() {
    super.initState();
    final currentFy = fiscalYearFor(DateTime.now(), startMonth: ref.read(fiscalYearStartMonthProvider).valueOrNull ?? 3);
    final historyYears = ref.read(fiscalYearHistoryYearsProvider).valueOrNull ?? 3;
    _fiscalYears = fiscalYearWindow(currentFy, historyYears);
    _future = ref
        .read(salesRepositoryProvider)
        .fetchConsolidatedSales(fiscalYears: _fiscalYears, filters: _ytdFilters(ref.read(globalFiltersProvider)));
  }

  void _refetch() {
    setState(() {
      _future = ref
          .read(salesRepositoryProvider)
          .fetchConsolidatedSales(fiscalYears: _fiscalYears, filters: _ytdFilters(ref.read(globalFiltersProvider)));
    });
  }

  @override
  Widget build(BuildContext context) {
    // ref.listen, not a manual diff-in-build + WidgetsBinding.
    // addPostFrameCallback — see document_analysis_view.dart's build() for
    // why that pattern was replaced (2026-08-26, Craig's branch filter bug
    // report).
    ref.listen<GlobalFilters>(globalFiltersProvider, (previous, next) => _refetch());

    return AppShell(
      title: 'YTD Comparative',
      currentRoute: '/ytd-comparative',
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Wrap, not a bare Row — reflows instead of overflowing sideways
            // on a narrow window (Craig, 2026-08-26: "insert a scroll
            // function instead of truncating the data"). SizedBox(width:
            // double.infinity) forces the Wrap to the full row width so
            // spaceBetween has space to push the toggle/export group to the
            // right edge (2026-08-26 follow-up) — a bare Wrap here would
            // otherwise shrink-wrap to just its two children and sit
            // left-aligned, silently ignoring the alignment.
            SizedBox(
              width: double.infinity,
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 16,
                runSpacing: 12,
                children: [
                  ValueGpToggle(value: _measure, onChanged: (v) => setState(() => _measure = v)),
                  DataExportButtons(onExport: _buildExportData),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: AsyncSection<List<ConsolidatedSales>>(
                future: _future,
                isEmpty: (rows) => rows.isEmpty,
                builder: (context, rows) => _buildTable(context, rows),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The full ordered column list for the fiscal-year comparison — see
  /// `_YearColumn`'s own doc comment for the exact interleaving.
  List<_YearColumn> _yearColumns() {
    // Newest fiscal year first (2026-09-01, Craig: "the user having to
    // scroll to right to view the most recent data").
    final order = [for (var i = _fiscalYears.length - 1; i >= 0; i--) _fiscalYears[i]];
    final columns = <_YearColumn>[];
    for (var idx = 0; idx < order.length; idx++) {
      columns.add(_YearColumn.value(order[idx]));
      if (idx > 0) columns.add(_YearColumn.variance(order[idx - 1], order[idx]));
    }
    return columns;
  }

  /// Value for whichever column `columnIndex` is, matching the exact same
  /// column layout `_buildTable` lays out below — column 0 is the month
  /// label (handled separately, since it sorts by fiscal-month position, not
  /// by value); every column after that is `_yearColumns()[columnIndex - 1]`.
  num? _valueForColumn(_YtdRow row, int columnIndex) {
    final columns = _yearColumns();
    final idx = columnIndex - 1;
    if (idx < 0 || idx >= columns.length) return null;
    final col = columns[idx];
    if (!col.isVariance) return row.yearValues[col.year];
    return variancePercent(row.yearValues[col.year], row.yearValues[col.previousYear]);
  }

  int _compareRows(_YtdRow a, _YtdRow b, int columnIndex) {
    if (columnIndex == 0) {
      final months = fiscalMonthOrderFor(startMonth: ref.read(fiscalYearStartMonthProvider).valueOrNull ?? 3);
      return months.indexOf(a.monthLabel).compareTo(months.indexOf(b.monthLabel));
    }
    return (_valueForColumn(a, columnIndex) ?? 0).compareTo(_valueForColumn(b, columnIndex) ?? 0);
  }

  void _onSort(int columnIndex, bool ascending) {
    setState(() {
      _sortColumnIndex = columnIndex;
      _sortAscending = ascending;
    });
  }

  // month label (e.g. 'Mar') -> fiscal year -> total for the chosen measure.
  // Shared by the table and by export so both always agree.
  List<_YtdRow> _buildYtdRows(List<ConsolidatedSales> rows) {
    final byMonth = <String, Map<int, num>>{};
    for (final row in rows) {
      final label = DateFormat('MMM').format(row.month);
      final value = _measure == ValueMeasure.rValue ? row.value : row.profit;
      final yearTotals = byMonth.putIfAbsent(label, () => {});
      yearTotals[row.fiscalYear] = (yearTotals[row.fiscalYear] ?? 0) + value;
    }
    final months = fiscalMonthOrderFor(startMonth: ref.read(fiscalYearStartMonthProvider).valueOrNull ?? 3);
    return months.map((label) => _YtdRow(label, byMonth[label] ?? const {})).toList();
  }

  String _varianceLabel(num? current, num? previous) {
    final variance = variancePercent(current, previous);
    return variance == null ? '—' : formatPercent(variance);
  }

  Future<ExportData> _buildExportData() async {
    final rows = await _future;
    final ytdRows = _buildYtdRows(rows);

    num yearTotal(int year) => ytdRows.fold<num>(0, (sum, row) => sum + (row.yearValues[year] ?? 0));

    // Matches the on-screen table (see `_YearColumn`'s doc comment) so the
    // export lines up with what's displayed.
    final columns = _yearColumns();
    final totalsRow = <String>['Total'];
    for (final col in columns) {
      totalsRow.add(
        col.isVariance ? _varianceLabel(yearTotal(col.year), yearTotal(col.previousYear!)) : formatRand(yearTotal(col.year)),
      );
    }

    final measureLabel = _measure == ValueMeasure.rValue ? 'R Value' : 'R Gross Profit';
    return ExportData(
      headers: [
        'Month',
        for (final col in columns) col.isVariance ? 'vs FY${col.previousYear}' : 'FY${col.year}',
      ],
      rows: [
        totalsRow,
        for (final row in ytdRows)
          [
            row.monthLabel,
            for (final col in columns)
              col.isVariance
                  ? _varianceLabel(row.yearValues[col.year], row.yearValues[col.previousYear])
                  : formatRand(row.yearValues[col.year]),
          ],
      ],
      fileNameBase: 'wyzesales_ytd_comparative_${DateTime.now().millisecondsSinceEpoch}',
      title: 'WyzeSales — YTD Comparative ($measureLabel)',
    );
  }

  Widget _buildTable(BuildContext context, List<ConsolidatedSales> rows) {
    final ytdRows = _buildYtdRows(rows)
      ..sort((a, b) {
        final cmp = _compareRows(a, b, _sortColumnIndex);
        return _sortAscending ? cmp : -cmp;
      });

    return ResponsiveDataTable(
      sortColumnIndex: _sortColumnIndex,
      sortAscending: _sortAscending,
      // Totals is always rows[0] here — see `_totalsRow`'s own doc comment
      // — so it's always the one row frozen under the header (2026-08-27,
      // Craig: "lock the Headers and Totals so we don't lose them when
      // scrolling down").
      pinnedRowCount: 1,
      columns: [
        DataColumn(label: const Text('Month'), onSort: _onSort),
        // See `_YearColumn`'s doc comment for the column order.
        for (final col in _yearColumns())
          DataColumn(
            label: Text(col.isVariance ? 'vs FY${col.previousYear}' : 'FY${col.year}'),
            numeric: true,
            onSort: _onSort,
          ),
      ],
      rows: [
        _totalsRow(context, ytdRows),
        ...ytdRows.map((row) {
          final cells = <DataCell>[DataCell(Text(row.monthLabel))];
          for (final col in _yearColumns()) {
            if (!col.isVariance) {
              cells.add(DataCell(Text(formatRand(row.yearValues[col.year]))));
            } else {
              final current = row.yearValues[col.year];
              final previous = row.yearValues[col.previousYear];
              final variance = variancePercent(current, previous);
              final color = variance == null
                  ? null
                  : (variance < 0 ? Theme.of(context).colorScheme.error : null);
              cells.add(DataCell(Text(variance == null ? '—' : formatPercent(variance), style: TextStyle(color: color))));
            }
          }
          return DataRow(
            // Row click -> global cross-filter (Craig, 2026-09-08 — see
            // `applyRowCrossFilters`'s own doc comment, core/filters/
            // global_filters.dart). This screen's own rows don't fit that
            // helper directly, though: each row is a fiscal MONTH spanning
            // every year in the comparison window at once (FY2025/FY2026/
            // FY2027 are separate columns on the SAME row), so there's no
            // single calendar date to derive a Year from the way Sales
            // Analysis' per-document rows have. Setting Month alone, leaving
            // Year untouched, is the same "as if set up independently"
            // behavior a bare Month filter already has everywhere else in
            // the app (it applies across every fiscal year on record, not
            // just one) — see document_analysis_view.dart's own
            // `_effectiveFiscalYear` doc comment for that established rule.
            onSelectChanged: (_) => ref.read(globalFiltersProvider.notifier).setFiscalMonth(row.monthLabel),
            cells: cells,
          );
        }),
      ],
    );
  }

  /// Bold, pinned as the FIRST row (2026-08-27, Craig: "Does it make sense
  /// to have the Totals as the first line in a view?" — confirmed yes,
  /// app-wide) rather than the last, inserted ahead of the sorted rows above
  /// so it always sits at the top regardless of the active column sort. Sums
  /// every fiscal-month row into a full-year total per FY column (a useful
  /// sanity check: this should match what Sales Analysis' Graph tab shows
  /// as that year's whole-company total), and recomputes each "vs" variance
  /// from those annual totals rather than averaging the 12 monthly
  /// variances, which would give equal weight to a quiet month and a
  /// blockbuster one.
  DataRow _totalsRow(BuildContext context, List<_YtdRow> ytdRows) {
    num yearTotal(int year) => ytdRows.fold<num>(0, (sum, row) => sum + (row.yearValues[year] ?? 0));
    const style = TextStyle(fontWeight: FontWeight.bold);
    final cells = <DataCell>[const DataCell(Text('Total', style: style))];
    for (final col in _yearColumns()) {
      if (!col.isVariance) {
        cells.add(DataCell(Text(formatRand(yearTotal(col.year)), style: style)));
      } else {
        final current = yearTotal(col.year);
        final previous = yearTotal(col.previousYear!);
        final variance = variancePercent(current, previous);
        final color = variance == null ? null : (variance < 0 ? Theme.of(context).colorScheme.error : null);
        cells.add(DataCell(Text(variance == null ? '—' : formatPercent(variance), style: style.copyWith(color: color))));
      }
    }
    return DataRow(
      color: WidgetStatePropertyAll(Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.04)),
      cells: cells,
    );
  }
}
