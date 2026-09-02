import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/app_providers.dart';
import '../../../core/constants/fiscal.dart';
import '../../../core/filters/global_filters.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/utils/performance_rollup.dart';
import '../../../data/models/dimension_performance.dart';
import '../../../shared/widgets/app_shell.dart';
import '../../../shared/widgets/async_section.dart';
import '../../../shared/widgets/boxed_dropdown.dart';
import '../../../shared/widgets/data_export_buttons.dart';
import '../../../shared/widgets/responsive_data_table.dart';

class _PerformanceData {
  final List<DimensionPerformance> rows;
  final Map<String, String> names;
  const _PerformanceData({required this.rows, required this.names});
}

/// %Contribution, R Value, R Target, %Target, R Profit, %GP, Quantity — one
/// row per entity for a chosen fiscal year/month
/// (Wyzesales_Screens_and_Recommendations.md Section 1). Almost no
/// client-side math: v_dimension_performance (schema/002 Section 3) already
/// computes all three ratios in SQL.
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

  String _effectiveFiscalMonth(GlobalFilters filters) => filters.fiscalMonth ?? _currentFiscalMonthLabel(DateTime.now());

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
      'salesPerson=${filters.salesPerson?.code}, category=${filters.category?.code}, '
      'customer=${filters.customer?.code}, item=${filters.item?.code}, branch=${filters.branch?.code})',
    );
    final results = await Future.wait([
      ref.read(salesRepositoryProvider).fetchDimensionPerformance(
            dimension: widget.dimension,
            fiscalYear: effectiveYear,
            fiscalMonth: effectiveMonth,
            filters: filters,
          ),
      ref.read(referenceDataRepositoryProvider).namesFor(widget.dimension),
    ]);
    var rawRows = results[0] as List<DimensionPerformance>;
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
    final currentFy = fiscalYearFor(DateTime.now(), startMonth: ref.read(fiscalYearStartMonthProvider).valueOrNull ?? 3);
    if (effectiveYear == null) {
      final historyYears = ref.read(fiscalYearHistoryYearsProvider).valueOrNull ?? 3;
      final window = fiscalYearWindow(currentFy, historyYears).toSet();
      rawRows = rawRows.where((r) => window.contains(r.fiscalYear)).toList();
    }
    final rows = effectiveYear == null ? mergeAcrossYears(rawRows, currentFy) : rawRows;
    debugPrint('[PerformanceScreen] _load() completed — ${rawRows.length} raw row(s), ${rows.length} after merge');
    return _PerformanceData(rows: rows, names: results[1] as Map<String, String>);
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
        return a.actualProfit.compareTo(b.actualProfit);
      case 6:
        return a.gpPercent.compareTo(b.gpPercent);
      case 7:
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

  Widget _buildTable(BuildContext context, _PerformanceData data) {
    final rows = [...data.rows]..sort((a, b) {
      final cmp = _compareRows(a, b, data, _sortColumnIndex);
      return _sortAscending ? cmp : -cmp;
    });
    return ResponsiveDataTable(
      sortColumnIndex: _sortColumnIndex,
      sortAscending: _sortAscending,
      // Totals is rows[0] only when there's at least one row (see the
      // `if (rows.isNotEmpty) _totalsRow(...)` below) — pinning follows the
      // same condition, otherwise there'd be nothing there to freeze
      // (2026-08-27, Craig: "lock the Headers and Totals so we don't lose
      // them when scrolling down").
      pinnedRowCount: rows.isNotEmpty ? 1 : 0,
      columns: [
        DataColumn(label: Text(widget.dimension.label), onSort: _onSort),
        DataColumn(label: const Text('% Contribution'), numeric: true, onSort: _onSort),
        DataColumn(label: const Text('R Value'), numeric: true, onSort: _onSort),
        DataColumn(label: const Text('R Target'), numeric: true, onSort: _onSort),
        DataColumn(label: const Text('% Target'), numeric: true, onSort: _onSort),
        DataColumn(label: const Text('R Profit'), numeric: true, onSort: _onSort),
        DataColumn(label: const Text('% GP'), numeric: true, onSort: _onSort),
        DataColumn(label: const Text('Quantity'), numeric: true, onSort: _onSort),
      ],
      rows: [
        if (rows.isNotEmpty) _totalsRow(context, rows),
        ...rows.map((row) {
          final gpColor = row.actualProfit < 0 ? Theme.of(context).colorScheme.error : null;
          return DataRow(cells: [
            DataCell(Text(data.names[row.entityCode] ?? row.entityCode)),
            DataCell(Text(formatPercent(row.contributionPercent))),
            DataCell(Text(formatRand(row.actualValue))),
            DataCell(Text(formatRand(row.targetValue))),
            DataCell(Text(formatPercent(row.targetPercent))),
            DataCell(Text(formatRand(row.actualProfit), style: TextStyle(color: gpColor))),
            DataCell(Text(formatPercent(row.gpPercent), style: TextStyle(color: gpColor))),
            DataCell(Text(formatQuantity(row.actualQuantity))),
          ]);
        }),
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
  DataRow _totalsRow(BuildContext context, List<DimensionPerformance> rows) {
    final totalContribution = rows.fold<num>(0, (sum, r) => sum + (r.contributionPercent ?? 0));
    final totalValue = rows.fold<num>(0, (sum, r) => sum + r.actualValue);
    final totalTarget = rows.fold<num>(0, (sum, r) => sum + (r.targetValue ?? 0));
    final totalProfit = rows.fold<num>(0, (sum, r) => sum + r.actualProfit);
    final totalQuantity = rows.fold<num>(0, (sum, r) => sum + r.actualQuantity);
    final totalTargetPercent = totalTarget == 0 ? null : (totalValue / totalTarget) * 100;
    final totalGpPercent = totalValue == 0 ? null : (totalProfit / totalValue) * 100;
    const style = TextStyle(fontWeight: FontWeight.bold);
    final gpColor = totalProfit < 0 ? Theme.of(context).colorScheme.error : null;
    return DataRow(
      color: WidgetStatePropertyAll(Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.04)),
      cells: [
        const DataCell(Text('Total', style: style)),
        DataCell(Text(formatPercent(totalContribution), style: style)),
        DataCell(Text(formatRand(totalValue), style: style)),
        DataCell(Text(formatRand(totalTarget), style: style)),
        DataCell(Text(formatPercent(totalTargetPercent), style: style)),
        DataCell(Text(formatRand(totalProfit), style: style.copyWith(color: gpColor))),
        DataCell(Text(formatPercent(totalGpPercent), style: style.copyWith(color: gpColor))),
        DataCell(Text(formatQuantity(totalQuantity), style: style)),
      ],
    );
  }

  /// Same 8 columns as _buildTable, same totals-row weighted-ratio
  /// recomputation as _totalsRow (see that method's own doc comment for why
  /// %Target/%GP aren't simply averaged) — built from whatever `_future`
  /// already resolved to, since this screen (unlike DocumentAnalysisView)
  /// holds its full per-dimension result set in memory rather than one
  /// paginated page, so there's no extra "fetch everything" fetch needed
  /// here.
  Future<ExportData> _buildExportData() async {
    final data = await _future;
    final rows = data.rows;
    final headers = [
      widget.dimension.label,
      '% Contribution',
      'R Value',
      'R Target',
      '% Target',
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
      dataRows.add([
        'Total',
        formatPercent(totalContribution),
        formatRand(totalValue),
        formatRand(totalTarget),
        formatPercent(totalTargetPercent),
        formatRand(totalProfit),
        formatPercent(totalGpPercent),
        formatQuantity(totalQuantity),
      ]);
    }
    for (final row in rows) {
      dataRows.add([
        data.names[row.entityCode] ?? row.entityCode,
        formatPercent(row.contributionPercent),
        formatRand(row.actualValue),
        formatRand(row.targetValue),
        formatPercent(row.targetPercent),
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
