import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/app_providers.dart';
import '../../../core/constants/fiscal.dart';
import '../../../core/filters/global_filters.dart';
import '../../../core/utils/formatters.dart';
import '../../../data/models/client_dimension_config.dart';
import '../../../data/models/dimension_monthly_sales.dart';
import '../../../shared/widgets/async_section.dart';

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
                // Same 2-column/1-column breakpoint dashboard_screen.dart's
                // own KPI tile grid and rankings section already use
                // (_kpiGridBreakpoint) — one width decision for the app to
                // reason about, not a fourth bespoke one for this screen.
                const spacing = 16.0;
                final columns = constraints.maxWidth >= 900 ? 2 : 1;
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

class _DimensionPanel extends StatelessWidget {
  const _DimensionPanel({required this.panel});
  final _PanelData panel;

  @override
  Widget build(BuildContext context) {
    final entries = panel.rows.entries.toList()..sort((a, b) => b.value.value.compareTo(a.value.value));
    num totalValue = 0;
    num totalProfit = 0;
    for (final entry in entries) {
      totalValue += entry.value.value;
      totalProfit += entry.value.profit;
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${panel.dimension.displayLabel}:', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            if (entries.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text('No data for the current filters.', style: Theme.of(context).textTheme.bodySmall),
              )
            else ...[
              const _PanelHeaderRow(),
              const Divider(height: 1),
              for (final entry in entries)
                _PanelRow(label: panel.names[entry.key] ?? entry.key, value: entry.value.value, profit: entry.value.profit),
              const Divider(height: 1),
              _PanelRow(label: 'Total', value: totalValue, profit: totalProfit, bold: true),
            ],
          ],
        ),
      ),
    );
  }
}

class _PanelHeaderRow extends StatelessWidget {
  const _PanelHeaderRow();

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w600);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(flex: 3, child: Text('', style: style)),
          Expanded(flex: 2, child: Text('R Value', style: style, textAlign: TextAlign.right)),
          Expanded(flex: 2, child: Text('R Profit', style: style, textAlign: TextAlign.right)),
          Expanded(flex: 1, child: Text('% GP', style: style, textAlign: TextAlign.right)),
        ],
      ),
    );
  }
}

class _PanelRow extends StatelessWidget {
  const _PanelRow({required this.label, required this.value, required this.profit, this.bold = false});

  final String label;
  final num value;
  final num profit;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(fontWeight: bold ? FontWeight.w700 : FontWeight.w400, fontSize: 13);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(flex: 3, child: Text(label, style: style, overflow: TextOverflow.ellipsis)),
          Expanded(flex: 2, child: Text(formatRand(value, precise: true), style: style, textAlign: TextAlign.right)),
          Expanded(flex: 2, child: Text(formatRand(profit, precise: true), style: style, textAlign: TextAlign.right)),
          // ratioPercent already returns null (-> '—') on a zero-value
          // denominator (formatters.dart) — deliberately NOT the "inf.00"
          // Edgetec's old report showed for a zero-Value/nonzero-Profit row
          // (the "OTHER" Market row in Craig's screenshot): that's a bug in
          // the legacy report worth fixing on the way through, not a
          // behaviour to faithfully reproduce, same "fixed, not preserved"
          // call made for every other ported quirk this project.
          Expanded(flex: 1, child: Text(formatPercent(ratioPercent(profit, value)), style: style, textAlign: TextAlign.right)),
        ],
      ),
    );
  }
}
