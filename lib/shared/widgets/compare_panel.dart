import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/app_providers.dart';
import '../../core/constants/fiscal.dart';
import '../../core/filters/global_filters.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import 'async_section.dart';
import 'boxed_dropdown.dart';
import 'trend_line_chart.dart';
import 'value_gp_toggle.dart';

// 2026-10-04, Craig (Morgenster): "The ability to compare entities in all
// screens" — narrowed to Performance and Sales By ("We only need this for
// Sales By and Performance"). Interaction chosen: tick rows in the table,
// then press Compare. This file is the one shared piece both screens use:
// the tick-box cell (`CompareTickCell`), the Compare/Clear buttons
// (`CompareButtons`) and the panel itself (`ComparePanel`) — a month-by-month
// line chart (one line per ticked entity) plus a side-by-side figures table.
//
// The chart reuses Sales Analysis' own Compare-mode data source
// (`fetchDimensionMonthlySales`, one call per ticked entity) and the same
// TrendLineChart, so there is no new backend query. Every OTHER active
// global filter (Branch, Sales Person, ...) still narrows the chart, but the
// dimension being compared is stripped out of the filters (otherwise a
// filter pinned to one entity would hide the rest), and Year/Month/Quarter
// are stripped too — the chart is always the 12 months of one fiscal year
// (picked in the panel itself, defaulting to the global Year, else the
// current fiscal year), the same shape as Sales Analysis' Compare mode.

/// Most entities that can be compared at once. Matches the colour palette
/// below (5 colours) — a 6th line would have to reuse a colour.
const int kCompareMaxEntities = 5;

// AppColors.teal and AppColors.caution are both amber, so they are not used
// together here — five clearly different hues instead.
const List<Color> _comparePalette = [
  AppColors.info,
  AppColors.positive,
  AppColors.caution,
  AppColors.accentPurple,
  Color(0xFF06B6D4),
];

/// Phones and small tablets (and short windows): the Compare panel opens as
/// a full-screen sheet instead of squeezing in under the table, where it
/// would only get a sliver of the height. Wider/taller windows keep it inline.
bool compareIsCompact(BuildContext context) {
  final size = MediaQuery.of(context).size;
  return size.width < 720 || size.height < 640;
}

/// Opens [builder]'s panel full-screen. `close` pops the sheet.
Future<void> showCompareSheet(BuildContext context, Widget Function(VoidCallback close) builder) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => Dialog.fullscreen(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: builder(() => Navigator.of(dialogContext).pop()),
      ),
    ),
  );
}

/// One ticked row.
class CompareEntity {
  const CompareEntity(this.code, this.name);
  final String code;
  final String name;
}

/// The figures the side-by-side table shows for one entity. When a screen
/// passes these in (Performance does, straight from its own table rows) the
/// table matches that screen's table exactly; when it doesn't (Sales By),
/// the panel totals the chart year's months itself.
class CompareSummary {
  const CompareSummary({required this.value, required this.profit, required this.quantity, this.target});
  final num value;
  final num profit;
  final num quantity;
  final num? target;
}

/// The checkbox + name that goes in a table's first cell. Putting the tick
/// inside the existing first cell (rather than adding a column) leaves every
/// column index — and so every screen's sort logic — exactly as it was.
class CompareTickCell extends StatelessWidget {
  const CompareTickCell({super.key, required this.name, required this.ticked, required this.canTick, required this.onChanged});

  final String name;
  final bool ticked;

  /// False once [kCompareMaxEntities] rows are ticked — the remaining
  /// unticked boxes grey out until one is unticked.
  final bool canTick;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final enabled = ticked || canTick;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 36,
          height: 36,
          child: Tooltip(
            message: enabled ? 'Tick to compare' : 'Maximum of $kCompareMaxEntities — untick one first',
            child: Checkbox(
              value: ticked,
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              onChanged: enabled ? (v) => onChanged(v ?? false) : null,
            ),
          ),
        ),
        const SizedBox(width: 6),
        Flexible(child: Text(name, maxLines: 2, overflow: TextOverflow.ellipsis)),
      ],
    );
  }
}

/// "Clear ticks" + "Compare (N)" — sits beside the export buttons in a
/// screen's header.
class CompareButtons extends StatelessWidget {
  const CompareButtons({super.key, required this.tickedCount, required this.onCompare, required this.onClear});

  final int tickedCount;
  final VoidCallback onCompare;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final ready = tickedCount >= 2;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (tickedCount > 0) TextButton(onPressed: onClear, child: const Text('Clear ticks')),
        const SizedBox(width: 4),
        Tooltip(
          message: ready ? 'Compare the ticked rows' : 'Tick 2 to $kCompareMaxEntities rows to compare',
          child: FilledButton.icon(
            onPressed: ready ? onCompare : null,
            icon: const Icon(Icons.stacked_line_chart, size: 18),
            label: Text(tickedCount >= 2 ? 'Compare ($tickedCount)' : 'Compare'),
          ),
        ),
      ],
    );
  }
}

typedef _MonthFigures = ({num value, num profit, num quantity});

class _CompareData {
  const _CompareData({required this.year, required this.byEntity});
  final int year;
  final Map<String, Map<String, _MonthFigures>> byEntity;
}

class ComparePanel extends ConsumerStatefulWidget {
  const ComparePanel({
    super.key,
    required this.dimensionKey,
    required this.dimensionLabel,
    required this.entities,
    required this.onClose,
    this.summaries,
    this.summaryNote,
    this.initialMeasure = ValueMeasure.rValue,
  });

  /// client_dimensions.dimension_key of the screen's dimension.
  final String dimensionKey;
  final String dimensionLabel;

  /// The ticked rows, in tick order.
  final List<CompareEntity> entities;
  final VoidCallback onClose;

  /// Optional per-entity figures for the table (keyed by entity code) — see
  /// [CompareSummary]. An entity missing from this map shows zeros.
  final Map<String, CompareSummary>? summaries;

  /// Small caption under the table, e.g. which period those figures are for.
  final String? summaryNote;

  /// Which measure the chart opens on (Sales By passes its own toggle's
  /// current value). The panel has its own toggle from there.
  final ValueMeasure initialMeasure;

  @override
  ConsumerState<ComparePanel> createState() => _ComparePanelState();
}

class _ComparePanelState extends ConsumerState<ComparePanel> {
  late int _year;
  late List<int> _years;
  late int _startMonth;
  late ValueMeasure _measure;

  // entity code -> colour slot. An entity keeps its colour while it stays
  // ticked, so unticking another one never repaints the survivors.
  final Map<String, int> _slots = {};

  // entity code -> that entity's figures by fiscal month label, for `_year`
  // under the current global filters. Cleared whenever either changes.
  final Map<String, Map<String, _MonthFigures>> _cache = {};
  int _generation = 0;
  late Future<_CompareData> _future;

  @override
  void initState() {
    super.initState();
    _measure = widget.initialMeasure;
    _startMonth = ref.read(fiscalYearStartMonthProvider).valueOrNull ?? 3;
    final currentFy = fiscalYearFor(DateTime.now(), startMonth: _startMonth);
    final historyYears = ref.read(fiscalYearHistoryYearsProvider).valueOrNull ?? 3;
    final window = fiscalYearWindow(currentFy, historyYears);
    _year = ref.read(globalFiltersProvider).fiscalYear ?? currentFy;
    _years = <int>{...window, _year}.toList()..sort();
    _future = _load();
  }

  @override
  void didUpdateWidget(covariant ComparePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.dimensionKey != widget.dimensionKey) {
      _cache.clear();
      _slots.clear();
      _generation++;
      _future = _load();
      return;
    }
    final oldCodes = oldWidget.entities.map((e) => e.code).join('|');
    final newCodes = widget.entities.map((e) => e.code).join('|');
    if (oldCodes != newCodes) _future = _load();
  }

  void _reload() {
    setState(() {
      _cache.clear();
      _generation++;
      _future = _load();
    });
  }

  Future<_CompareData> _load() async {
    final generation = _generation;
    final year = _year;
    final codes = widget.entities.map((e) => e.code).toList();
    final missing = codes.where((c) => !_cache.containsKey(c)).toList();
    if (missing.isNotEmpty) {
      // Only the dimension being compared and the Year/Month/Quarter are
      // stripped — see this file's header comment. Every other filter stays.
      final filters = ref
          .read(globalFiltersProvider)
          .withDimension(widget.dimensionKey, null)
          .copyWith(fiscalYear: null, fiscalMonth: null, fiscalQuarter: null, fiscalQuarterMonths: null);
      final repo = ref.read(salesRepositoryProvider);
      final results = await Future.wait([
        for (final code in missing)
          repo.fetchDimensionMonthlySales(
            dimension: widget.dimensionKey,
            entityCode: code,
            fiscalYears: [year],
            filters: filters,
          ),
      ]);
      // A newer reload (year / filter change) started while this was in
      // flight — don't let this older answer land in the fresh cache.
      if (generation == _generation) {
        for (var i = 0; i < missing.length; i++) {
          final byMonth = <String, _MonthFigures>{};
          for (final row in results[i]) {
            byMonth[fiscalMonthLabelFor(row.month)] = (value: row.value, profit: row.profit, quantity: row.quantity);
          }
          _cache[missing[i]] = byMonth;
        }
      }
    }
    return _CompareData(
      year: year,
      byEntity: {for (final c in codes) c: _cache[c] ?? const <String, _MonthFigures>{}},
    );
  }

  void _syncSlots() {
    final codes = widget.entities.map((e) => e.code).toSet();
    _slots.removeWhere((code, _) => !codes.contains(code));
    for (final e in widget.entities) {
      if (_slots.containsKey(e.code)) continue;
      var slot = 0;
      while (_slots.containsValue(slot)) {
        slot++;
      }
      _slots[e.code] = slot;
    }
  }

  Color _colorFor(String code) => _comparePalette[(_slots[code] ?? 0) % _comparePalette.length];

  num _measureOf(_MonthFigures f) => switch (_measure) {
        ValueMeasure.rValue => f.value,
        ValueMeasure.grossProfit => f.profit,
        ValueMeasure.quantity => f.quantity,
      };

  /// A month with no row is a real 0 (nothing sold) — unless this is the
  /// current, still-partial fiscal year and the month hasn't happened yet,
  /// in which case it's a gap (null), not a zero. Same rule Sales Analysis'
  /// Compare mode uses.
  num? _monthValue(Map<String, _MonthFigures> byMonth, String month, int year) {
    final figures = byMonth[month];
    if (figures != null) return _measureOf(figures);
    final months = fiscalMonthOrderFor(startMonth: _startMonth);
    final now = DateTime.now();
    final currentFy = fiscalYearFor(now, startMonth: _startMonth);
    final stillFuture = year == currentFy && months.indexOf(month) > months.indexOf(fiscalMonthLabelFor(now));
    return stillFuture ? null : 0;
  }

  CompareSummary _totalsFor(Map<String, _MonthFigures> byMonth) {
    num value = 0;
    num profit = 0;
    num quantity = 0;
    for (final f in byMonth.values) {
      value += f.value;
      profit += f.profit;
      quantity += f.quantity;
    }
    return CompareSummary(value: value, profit: profit, quantity: quantity);
  }

  String _compact(num value) {
    final abs = value.abs();
    final prefix = _measure == ValueMeasure.quantity ? '' : 'R';
    if (abs >= 1000000) return '$prefix${(value / 1000000).toStringAsFixed(1)}M';
    if (abs >= 1000) return '$prefix${(value / 1000).toStringAsFixed(0)}K';
    return '$prefix${value.toStringAsFixed(0)}';
  }

  String _detail(num v) => _measure == ValueMeasure.quantity ? formatQuantity(v) : formatRand(v);

  @override
  Widget build(BuildContext context) {
    // A global filter change (a Branch / Sales Person pick, a Year pick, ...)
    // refetches the chart. A new global Year also moves this panel's own
    // year dropdown to match.
    ref.listen<GlobalFilters>(globalFiltersProvider, (previous, next) {
      final y = next.fiscalYear;
      if (y != null && y != _year) {
        _year = y;
        if (!_years.contains(y)) _years = [..._years, y]..sort();
      }
      _reload();
    });
    _syncSlots();
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Wrap(
                      spacing: 16,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text('Comparing ${widget.entities.length} · ${widget.dimensionLabel}', style: theme.textTheme.titleMedium),
                        BoxedDropdown<int>(
                          key: ValueKey<int>(_year),
                          value: _year,
                          width: 120,
                          items: [for (final y in _years) DropdownMenuItem(value: y, child: Text('FY$y'))],
                          onChanged: (y) {
                            if (y == null || y == _year) return;
                            _year = y;
                            _reload();
                          },
                        ),
                        // Phone width: the 3-way toggle is wider than the screen, so let it scroll sideways.
                        compareIsCompact(context)
                            ? SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                child: ValueGpToggle(value: _measure, onChanged: (m) => setState(() => _measure = m)),
                              )
                            : ValueGpToggle(value: _measure, onChanged: (m) => setState(() => _measure = m)),
                      ],
                    ),
                  ),
                  IconButton(tooltip: 'Close', icon: const Icon(Icons.close), onPressed: widget.onClose),
                ],
              ),
              const SizedBox(height: 8),
              AsyncSection<_CompareData>(
                future: _future,
                isEmpty: (data) => data.byEntity.values.every((m) => m.isEmpty),
                emptyMessage: 'No sales for the ticked rows in FY$_year under the current filters.',
                builder: (context, data) => _buildBody(context, data),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, _CompareData data) {
    final categories = fiscalMonthOrderFor(startMonth: _startMonth);
    final series = [
      for (final e in widget.entities)
        TrendSeries(
          label: e.name,
          color: _colorFor(e.code),
          values: [for (final m in categories) _monthValue(data.byEntity[e.code] ?? const <String, _MonthFigures>{}, m, data.year)],
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${_measure.label} by month, FY${data.year}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 300,
          child: TrendLineChart(
            categories: categories,
            series: series,
            axisValueFormatter: _compact,
            detailValueFormatter: _detail,
          ),
        ),
        const SizedBox(height: 12),
        _buildFiguresTable(context, data),
        if (widget.summaryNote != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(widget.summaryNote!, style: Theme.of(context).textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic)),
          )
        else
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Table figures are the FY${data.year} totals for each ticked row.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic),
            ),
          ),
      ],
    );
  }

  Widget _buildFiguresTable(BuildContext context, _CompareData data) {
    final summaries = <CompareSummary>[
      for (final e in widget.entities)
        widget.summaries != null
            ? (widget.summaries![e.code] ?? const CompareSummary(value: 0, profit: 0, quantity: 0))
            : _totalsFor(data.byEntity[e.code] ?? const <String, _MonthFigures>{}),
    ];
    final showTarget = summaries.any((s) => s.target != null);
    double? targetPercent(CompareSummary s) => (s.target == null || s.target == 0) ? null : (s.value / s.target!) * 100;
    double? gpPercent(CompareSummary s) => s.value == 0 ? null : (s.profit / s.value) * 100;

    // Bold the best figure in each comparable column (highest value, highest
    // % Target, highest profit, highest % GP, highest quantity).
    num? maxOf(Iterable<num?> values) {
      num? best;
      for (final v in values) {
        if (v == null) continue;
        if (best == null || v > best) best = v;
      }
      return best;
    }

    final bestValue = maxOf(summaries.map((s) => s.value));
    final bestTargetPct = maxOf(summaries.map(targetPercent));
    final bestProfit = maxOf(summaries.map((s) => s.profit));
    final bestGp = maxOf(summaries.map(gpPercent));
    final bestQty = maxOf(summaries.map((s) => s.quantity));
    TextStyle? bold(bool isBest) => isBest && widget.entities.length > 1 ? const TextStyle(fontWeight: FontWeight.bold) : null;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columns: [
          DataColumn(label: Text(widget.dimensionLabel)),
          const DataColumn(label: Text('R Value'), numeric: true),
          if (showTarget) const DataColumn(label: Text('R Target'), numeric: true),
          if (showTarget) const DataColumn(label: Text('% Target'), numeric: true),
          const DataColumn(label: Text('R Profit'), numeric: true),
          const DataColumn(label: Text('% GP'), numeric: true),
          const DataColumn(label: Text('Quantity'), numeric: true),
        ],
        rows: [
          for (var i = 0; i < widget.entities.length; i++)
            DataRow(
              cells: [
                DataCell(
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(color: _colorFor(widget.entities[i].code), shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 8),
                      Text(widget.entities[i].name),
                    ],
                  ),
                ),
                DataCell(Text(formatRand(summaries[i].value), style: bold(summaries[i].value == bestValue))),
                if (showTarget) DataCell(Text(formatRand(summaries[i].target))),
                if (showTarget)
                  DataCell(Text(formatPercent(targetPercent(summaries[i])), style: bold(targetPercent(summaries[i]) != null && targetPercent(summaries[i]) == bestTargetPct))),
                DataCell(Text(formatRand(summaries[i].profit), style: bold(summaries[i].profit == bestProfit))),
                DataCell(Text(formatPercent(gpPercent(summaries[i])), style: bold(gpPercent(summaries[i]) != null && gpPercent(summaries[i]) == bestGp))),
                DataCell(Text(formatQuantity(summaries[i].quantity), style: bold(summaries[i].quantity == bestQty))),
              ],
            ),
        ],
      ),
    );
  }
}
