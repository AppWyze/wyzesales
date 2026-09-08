import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/app_providers.dart';
import '../../../core/constants/fiscal.dart';
import '../../../core/filters/global_filters.dart';
import '../../../core/utils/formatters.dart';
import '../../../data/models/client_dimension_config.dart';
import '../../../data/models/dimension_monthly_sales.dart';
import '../../../shared/widgets/async_section.dart';
import '../../../shared/widgets/responsive_data_table.dart';

/// Option B of the Dashboard's layout switch (schema/053, Profile.
/// dashboardLayout) — Craig, 2026-09-08, looking at Edgetec's old standalone
/// report (Revenue Split / Group / Business Unit / Market laid out as
/// classification tables with R Value / R Profit / % GP): "I would like to
/// offer the current dashboard as option A and this one as option B... option
/// B alignes with the defined Dimensions for the client."
///
/// Deliberately scoped to just this client's CLASSIFICATION-style dimensions
/// — `client_dimensions` rows with `resolution_kind != 'existing'` (Group/
/// Market/Revenue Split/Category Type/Business Unit for Edgetec) — not every
/// configured dimension. Sales Person/Customer/Item/Category/Branch already
/// have dedicated breakdown screens (Sales By, Performance), and Customer/
/// Item in particular can run into the hundreds of entities, which doesn't
/// suit this screen's compact one-table-per-dimension layout the way a
/// handful of classification labels does. A client with none of these
/// configured (WCSA today) sees an explanatory empty state rather than a
/// blank screen — Option A stays its only real choice until it configures
/// one via the Dimensions tab.
///
/// Reads the SAME `globalFiltersProvider` fiscal year/month/quarter state
/// every other screen already shares (GlobalFilterBar is mounted once in
/// AppShell, above this screen's body, per that widget's own doc comment) —
/// deliberately no separate Year/Quarter/Month control of its own here, so
/// switching period stays in lock-step with the rest of the app rather than
/// forking a second, disconnected filter the way Edgetec's old standalone
/// report's own buttons worked in isolation.
class DashboardTableView extends ConsumerStatefulWidget {
  const DashboardTableView({super.key});

  @override
  ConsumerState<DashboardTableView> createState() => _DashboardTableViewState();
}

class _EntityTotals {
  num value = 0;
  num profit = 0;
}

class _PanelData {
  const _PanelData({required this.dimension, required this.rows, required this.names});
  final ClientDimensionConfig dimension;
  final Map<String, _EntityTotals> rows;
  final Map<String, String> names;
}

class _DashboardTableViewState extends ConsumerState<DashboardTableView> {
  Future<List<_PanelData>>? _future;
  GlobalFilters? _loadedForFilters;
  String? _loadedForDimensionsKey;

  @override
  Widget build(BuildContext context) {
    final filters = ref.watch(globalFiltersProvider);
    final startMonth = ref.watch(fiscalYearStartMonthProvider).valueOrNull ?? 3;
    final dimensionsAsync = ref.watch(clientDimensionsProvider);

    return dimensionsAsync.when(
      loading: () => const Center(child: Padding(padding: EdgeInsets.all(32), child: RepaintBoundary(child: CircularProgressIndicator()))),
      error: (error, _) => Center(child: Padding(padding: const EdgeInsets.all(32), child: Text('Something went wrong: $error'))),
      data: (allDimensions) {
        // Cache key includes the dimension list itself, not just the active
        // filters — `clientDimensionsProvider` can still be `loading` on the
        // very first build (this `.when`'s own `loading` branch above covers
        // that), but if it resolves to a DIFFERENT list on a later rebuild
        // (a Platform Admin adds/publishes a new dimension mid-session) this
        // still needs to re-fetch, not keep serving a `_future` built off an
        // empty/stale list — same "don't block rendering, but don't cache a
        // wrong answer either" concern every other `.valueOrNull ?? []`
        // caller in this app already has to account for.
        final dimensionsKey = allDimensions.map((d) => '${d.dimensionKey}:${d.resolutionKind}').join(',');
        if (_future == null || _loadedForFilters != filters || _loadedForDimensionsKey != dimensionsKey) {
          _loadedForFilters = filters;
          _loadedForDimensionsKey = dimensionsKey;
          _future = _load(filters: filters, startMonth: startMonth, allDimensions: allDimensions);
        }

        return AsyncSection<List<_PanelData>>(
          future: _future!,
          isEmpty: (data) => data.isEmpty,
          emptyMessage: 'This client has no classification dimensions configured yet (Group/Market/Revenue '
              'Split-style breakdowns) — ask a Platform Admin to add one under Dimensions, or switch back to '
              'the standard Dashboard view above.',
          builder: (context, panels) {
            return LayoutBuilder(
              builder: (context, constraints) {
                // 2026-09-08, Craig: "two tables next to each other... this
                // will hopefully work in Desktop view and maybe Tablet. When
                // it becomes too narrow then revert to a single table."
                // Deliberately a HIGHER threshold than dashboard_screen.dart's
                // own `_kpiGridBreakpoint` (900) — that one decides between 2
                // and 3 KPI tiles, which stay legible much narrower than a
                // full 4-column, sortable financial table does. Estimated
                // from `ResponsiveDataTable`'s own per-column width floor
                // (`_estimatedColumnWidth`): a name column plus 3 numeric
                // columns lands around ~550px before that table starts
                // needing its own horizontal scroll, so two side by side plus
                // the gap between them need on the order of ~1100px — a
                // typical laptop/desktop width, and a landscape tablet if it
                // has one. Below that, each panel gets the full width to
                // itself instead of squeezing two half-width tables into
                // their own horizontal scrollbars.
                const spacing = 16.0;
                const twoColumnBreakpoint = 1050.0;
                final columns = constraints.maxWidth >= twoColumnBreakpoint ? 2 : 1;
                final panelWidth = columns == 2 ? (constraints.maxWidth - spacing) / 2 : constraints.maxWidth;
                return SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Wrap(
                    spacing: spacing,
                    runSpacing: spacing,
                    children: [
                      for (final panel in panels) SizedBox(width: panelWidth, child: _DimensionPanel(panel: panel)),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  Future<List<_PanelData>> _load({
    required GlobalFilters filters,
    required int startMonth,
    required List<ClientDimensionConfig> allDimensions,
  }) async {
    final dimensions = allDimensions.where((d) => d.resolutionKind != 'existing').toList()
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    if (dimensions.isEmpty) return const [];

    // No fiscalYear filter active -> the current fiscal year, same fallback
    // `_loadDimension`/GlobalFilterBar's own Year picker use elsewhere
    // (fiscalYearFor, core/constants/fiscal.dart). Month/Quarter (if set)
    // reach `fetchDimensionMonthlySales` via `filters` itself, same as every
    // other filtered screen — deliberately NOT stripped the way Option A's
    // own `_dashboardFilters` strips them (that screen computes its own MTD/
    // QTD/YTD independently of the global fiscal filter; this one is
    // explicitly meant to track it, per Craig's own answer on how the period
    // toggle should behave).
    final year = filters.fiscalYear ?? fiscalYearFor(DateTime.now(), startMonth: startMonth);

    final salesRepo = ref.read(salesRepositoryProvider);
    final referenceRepo = ref.read(referenceDataRepositoryProvider);

    return Future.wait(dimensions.map((dimension) async {
      final results = await Future.wait([
        salesRepo.fetchDimensionMonthlySales(dimension: dimension.dimensionKey, fiscalYears: [year], filters: filters),
        referenceRepo.namesForConfig(dimension),
      ]);
      final rows = results[0] as List<DimensionMonthlySales>;
      final names = results[1] as Map<String, String>;

      final totals = <String, _EntityTotals>{};
      for (final row in rows) {
        final entry = totals.putIfAbsent(row.entityCode, () => _EntityTotals());
        entry.value += row.value;
        entry.profit += row.profit;
      }
      return _PanelData(dimension: dimension, rows: totals, names: names);
    }));
  }
}

/// One entity's row, resolved once per panel build so both the sort
/// comparator and the rendered cells agree on the exact same numbers —
/// `_gp` deliberately left nullable (mirrors `ratioPercent`'s own null-on-
/// zero-denominator convention, formatters.dart) so a zero-Value row sorts
/// predictably (treated as 0 below) rather than throwing on a null compare.
class _EntityRow {
  const _EntityRow({required this.code, required this.label, required this.value, required this.profit, required this.gp});
  final String code;
  final String label;
  final num value;
  final num profit;
  final double? gp;
}

/// A real, sortable [ResponsiveDataTable] per dimension — 2026-09-08, Craig:
/// "it doesn't look pretty... only show the first 5 rows with totals on the
/// top row and the ability to sort each column asc or desc." Switched from
/// this file's original hand-rolled `Row`s to the same shared table widget
/// every other screen's rollup uses (Sales By, Performance, Document
/// Analysis) — same bold pinned-Totals-row-at-the-top convention
/// (`ResponsiveDataTable`'s own doc comment: "Totals to the top," app-wide
/// except Budgets), same `DataColumn(onSort: ...)` per-column sort.
///
/// The Totals row is always computed from EVERY entity, never just the
/// visible 5 — it's the true dimension total regardless of how the table
/// happens to be sorted/truncated. The 5 entity rows shown are the first 5
/// of whatever the CURRENT sort produces: sort by R Value descending (the
/// default) to see the top 5 by revenue, ascending for the bottom 5, or sort
/// by name/Profit/%GP instead — one consistent "sort, then take 5" rule
/// rather than a separate fixed "top 5" behind the scenes.
class _DimensionPanel extends StatefulWidget {
  const _DimensionPanel({required this.panel});
  final _PanelData panel;

  @override
  State<_DimensionPanel> createState() => _DimensionPanelState();
}

class _DimensionPanelState extends State<_DimensionPanel> {
  // Column 1 (R Value), descending — same default SalesByScreen's own table
  // opens on (_SalesByScreenState._sortColumnIndex/_sortAscending's own doc
  // comment) for exactly the same reason: the current FY/R Value column is
  // the one figure most worth seeing highest-first by default.
  int _sortColumnIndex = 1;
  bool _sortAscending = false;

  static const _visibleRowCount = 5;

  void _onSort(int columnIndex, bool ascending) {
    setState(() {
      _sortColumnIndex = columnIndex;
      _sortAscending = ascending;
    });
  }

  @override
  Widget build(BuildContext context) {
    final panel = widget.panel;
    final allRows = [
      for (final entry in panel.rows.entries)
        _EntityRow(
          code: entry.key,
          label: panel.names[entry.key] ?? entry.key,
          value: entry.value.value,
          profit: entry.value.profit,
          gp: ratioPercent(entry.value.profit, entry.value.value),
        ),
    ];

    num totalValue = 0;
    num totalProfit = 0;
    for (final row in allRows) {
      totalValue += row.value;
      totalProfit += row.profit;
    }
    final totalGp = ratioPercent(totalProfit, totalValue);

    allRows.sort((a, b) {
      int cmp;
      switch (_sortColumnIndex) {
        case 0:
          cmp = a.label.compareTo(b.label);
          break;
        case 2:
          cmp = a.profit.compareTo(b.profit);
          break;
        case 3:
          cmp = (a.gp ?? 0).compareTo(b.gp ?? 0);
          break;
        case 1:
        default:
          cmp = a.value.compareTo(b.value);
      }
      return _sortAscending ? cmp : -cmp;
    });
    final visibleRows = allRows.take(_visibleRowCount).toList();

    const totalStyle = TextStyle(fontWeight: FontWeight.bold);

    // No outer Card here — `ResponsiveDataTable` below already renders
    // itself as one (rounded corners, elevation); wrapping it in a SECOND
    // Card just for this panel's label would draw a card inside a card,
    // exactly the kind of visual clutter Craig flagged ("doesn't look
    // pretty"). A plain label above the table, same as every other screen's
    // page title sits above ITS table, keeps one clean frame per panel.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(panel.dimension.displayLabel, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        if (allRows.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text('No data for the current filters.', style: Theme.of(context).textTheme.bodySmall),
              )
            else ...[
              // `DataTable2` (behind `ResponsiveDataTable`) manages its own
              // internal vertical scroll region, which needs a BOUNDED
              // height to lay out against — every other screen that uses
              // `ResponsiveDataTable` gets that for free from an ancestor
              // `Expanded` inside a full-height `Column` (see
              // SalesByScreen.build()'s own `Expanded(child: _buildTable(...))`).
              // This panel instead sits inside a `Wrap` (so two can sit side
              // by side), which hands its children unconstrained height —
              // so a fixed height is worked out explicitly here instead, from
              // the actual row count about to be rendered (header + the
              // pinned Total row + up to 5 entity rows), rather than left
              // to an ancestor that was never going to bound it.
              SizedBox(
                height: 56 + (1 + visibleRows.length) * 52,
                child: ResponsiveDataTable(
                  sortColumnIndex: _sortColumnIndex,
                  sortAscending: _sortAscending,
                  // Totals is always rows[0] — see this class's own doc
                  // comment for why it's pinned regardless of the active sort.
                  pinnedRowCount: 1,
                  columns: [
                    DataColumn(label: Text(panel.dimension.displayLabel), onSort: _onSort),
                    DataColumn(label: const Text('R Value'), numeric: true, onSort: _onSort),
                    DataColumn(label: const Text('R Profit'), numeric: true, onSort: _onSort),
                    DataColumn(label: const Text('% GP'), numeric: true, onSort: _onSort),
                  ],
                  rows: [
                    DataRow(
                      color: WidgetStatePropertyAll(Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.04)),
                      cells: [
                        const DataCell(Text('Total', style: totalStyle)),
                        DataCell(Text(formatRand(totalValue, precise: true), style: totalStyle)),
                        DataCell(Text(formatRand(totalProfit, precise: true), style: totalStyle)),
                        // ratioPercent already returns null (-> '—' via
                        // formatPercent) on a zero-Value denominator — not
                        // the "inf.00" Edgetec's old report showed for its
                        // zero-Value/nonzero-Profit "OTHER" Market row.
                        // That's a bug in the legacy report worth fixing on
                        // the way through, not a behaviour to faithfully
                        // reproduce, same "fixed, not preserved" call made
                        // for every other ported quirk this project.
                        DataCell(Text(formatPercent(totalGp), style: totalStyle)),
                      ],
                    ),
                    for (final row in visibleRows)
                      DataRow(cells: [
                        DataCell(Text(row.label, overflow: TextOverflow.ellipsis)),
                        DataCell(Text(formatRand(row.value, precise: true))),
                        DataCell(Text(formatRand(row.profit, precise: true))),
                        DataCell(Text(formatPercent(row.gp))),
                      ]),
                  ],
                ),
              ),
              if (allRows.length > _visibleRowCount)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    'Showing $_visibleRowCount of ${allRows.length} — sort a column to change which ones.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
        ],
      ],
    );
  }
}
