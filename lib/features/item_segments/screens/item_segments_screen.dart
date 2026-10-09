import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/app_providers.dart';
import '../../../core/filters/global_filters.dart';
import '../../../core/utils/formatters.dart';
import '../../../data/models/client_dimension_config.dart';
import '../../../data/models/item_segment.dart';
import '../../../shared/widgets/app_shell.dart';
import '../../../shared/widgets/async_section.dart';
import '../../../shared/widgets/data_export_buttons.dart';
import '../../../shared/widgets/help_info_icon.dart';

/// Item Segments — every item that sold in the last 12 months, placed by what
/// its sales are doing (across: New, Growing, Steady, Declining, Occasional,
/// Stopped) and how much it matters (down: A, B, C by value), plus the items
/// that have gone dormant.
///
/// Craig, 2026-10-09, after reviewing a mock-up built from real Morgenster and
/// Edgetec numbers. The classification lives in Postgres
/// (schema/061_wyzesales_item_segments.sql); this screen only fetches the
/// per-cell summary, the concentration figures and, on request, the item list
/// for one cell.
///
/// The period is fixed at the last 12 closed months (the segments are defined
/// against that window, see schema/061). The app-wide dimension filters (Sales
/// Person, Branch, Category, Customer ...) narrow which sales are counted;
/// Year / Quarter / Month are deliberately NOT applied.
///
/// Per client: `clients.item_segments_enabled` (Platform Admin > Edit client)
/// hides the screen, and `clients.item_segments_excluded_codes` leaves service
/// and non-stock lines (Gratuity, Freight, Tasting ...) out. A company without
/// an Item dimension never sees it either.
class ItemSegmentsScreen extends ConsumerStatefulWidget {
  const ItemSegmentsScreen({super.key});

  @override
  ConsumerState<ItemSegmentsScreen> createState() => _ItemSegmentsScreenState();
}

class _ItemSegData {
  final List<ItemSegmentCell> cells;
  final ItemConcentration concentration;
  const _ItemSegData(this.cells, this.concentration);
}

class _ItemSegmentsScreenState extends ConsumerState<ItemSegmentsScreen> {
  String? _selectedKey;
  late Future<_ItemSegData> _future;
  late DateTime _asOf;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_ItemSegData> _load() async {
    final now = DateTime.now();
    _asOf = DateTime(now.year, now.month, now.day);
    final repo = ref.read(salesRepositoryProvider);
    final filters = ref.read(globalFiltersProvider).toFilterParams();
    final results = await Future.wait([
      repo.fetchItemSegmentsSummary(asOf: _asOf, filters: filters),
      repo.fetchItemConcentration(asOf: _asOf, filters: filters),
    ]);
    return _ItemSegData(results[0] as List<ItemSegmentCell>, results[1] as ItemConcentration);
  }

  void _refetch() {
    setState(() {
      _future = _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<GlobalFilters>(globalFiltersProvider, (previous, next) {
      // Only the dimension filters matter here; ignore a change that touched
      // nothing but Year / Quarter / Month / Document.
      if (previous == null || previous.toFilterParams().toString() != next.toFilterParams().toString()) {
        _refetch();
      }
    });

    final client = ref.watch(currentClientProvider).valueOrNull;
    final dimensions = ref.watch(clientDimensionsProvider).valueOrNull;
    final hasItem = dimensions == null || dimensions.forKey('item') != null;
    final enabled = client == null || client.itemSegmentsEnabled;

    return AppShell(
      title: 'Item Segments',
      currentRoute: '/item-segments',
      help: const TileHelp(
        title: 'How Item Segments works',
        paragraphs: [
          'Every item that sold in the last 12 months is placed on a chart. Across the chart is what the item\'s sales are doing: New (first sold in the last 12 months), Growing or Declining (more or less than 15% different from the 12 months before), Steady (about the same), Occasional (sold in 5 of the last 12 months or fewer) and Stopped (sold in the last 12 months but nothing for the last 4).',
          'Down the chart is how much the item matters. A items are the ones that make up the first 80% of your sales, B items the next 15%, and C items the long tail of the last 5%.',
          'The grey Dormant box underneath holds items with no sales for 12 months or more. They are left out of the percentages.',
          'Click a box (or a row in the table) to see what it means, what the Seasonal Forecast does with those items, its biggest items, and the full list.',
          '"Depends on one or two customers" lists A and B items where two customers or fewer buy the item, or one customer is 60% or more of it. "Stopped selling" is the first place to look for an item that should still be selling.',
          'The dimension filters (Sales Person, Branch and so on) narrow which sales are counted. Year, Quarter and Month filters do not apply here: this screen always looks at the last 12 months. Value is invoices less credit notes.',
        ],
      ),
      body: !hasItem || !enabled
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text('Item Segments is not switched on for this company.'),
              ),
            )
          : Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.end,
                      spacing: 16,
                      runSpacing: 12,
                      children: [
                        const Chip(label: Text('Period: last 12 months')),
                        DataExportButtons(onExport: _buildExportData),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Expanded(
                    child: AsyncSection<_ItemSegData>(
                      future: _future,
                      isEmpty: (data) => data.cells.isEmpty,
                      emptyMessage: 'No items sold in the last 12 months with the current filters.',
                      builder: (context, data) => _buildContent(context, data),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildContent(BuildContext context, _ItemSegData data) {
    final byKey = {for (final c in data.cells) c.cellKey: c};
    final active = data.cells.where((c) => c.segmentKey != kItemDormantKey).toList();
    final dormant = data.cells.where((c) => c.segmentKey == kItemDormantKey).toList();
    final dormantCell = dormant.isEmpty ? null : dormant.first;
    final totalItems = active.fold<int>(0, (sum, c) => sum + c.items);
    final totalValue = active.fold<num>(0, (sum, c) => sum + c.totalValue);

    String selectedKey = _selectedKey ?? '';
    if (!byKey.containsKey(selectedKey)) {
      if (active.isNotEmpty) {
        final sorted = [...active]..sort((a, b) => b.totalValue.compareTo(a.totalValue));
        selectedKey = sorted.first.cellKey;
      } else if (dormantCell != null) {
        selectedKey = dormantCell.cellKey;
      }
    }
    final selected = byKey[selectedKey];

    final chart = _ChartCard(
      byKey: byKey,
      dormant: dormantCell,
      totalValue: totalValue,
      selectedKey: selectedKey,
      onSelect: (key) => setState(() => _selectedKey = key),
    );
    final detail = selected == null
        ? const SizedBox.shrink()
        : _DetailCard(
            cell: selected,
            totalItems: totalItems,
            totalValue: totalValue,
            onViewAll: () => _showItemList(context, selected),
            onOpenItem: _openItem,
          );

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 900;
        final concentrationCard = _ConcentrationCard(concentration: data.concentration, onOpenItem: _openItem);
        final stoppedCard = _StoppedCard(
          cells: [
            for (final key in const ['stopped|A', 'stopped|B', 'stopped|C']) if (byKey[key] != null) byKey[key]!,
          ],
          totalValue: totalValue,
          onOpenItem: _openItem,
        );
        return SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: _buildSummaryText(context, byKey, dormantCell, totalItems, totalValue),
                ),
              ),
              const SizedBox(height: 16),
              if (wide)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 3, child: chart),
                    const SizedBox(width: 16),
                    Expanded(flex: 2, child: detail),
                  ],
                )
              else ...[
                chart,
                const SizedBox(height: 16),
                detail,
              ],
              const SizedBox(height: 16),
              if (wide)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: concentrationCard),
                    const SizedBox(width: 16),
                    Expanded(child: stoppedCard),
                  ],
                )
              else ...[
                concentrationCard,
                const SizedBox(height: 16),
                stoppedCard,
              ],
              const SizedBox(height: 16),
              _TableCard(
                cells: data.cells,
                totalItems: totalItems,
                totalValue: totalValue,
                selectedKey: selectedKey,
                onSelect: (key) => setState(() => _selectedKey = key),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  'Growing and Declining compare the last 12 months with the 12 before (items less than two years old are compared on the months they existed, scaled to 12). A change of more than 15% either way counts; anything inside that is Steady. Value is invoices less credit notes.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSummaryText(
    BuildContext context,
    Map<String, ItemSegmentCell> byKey,
    ItemSegmentCell? dormant,
    int totalItems,
    num totalValue,
  ) {
    final base = Theme.of(context).textTheme.bodyMedium;
    final bold = base?.copyWith(fontWeight: FontWeight.w700);
    final aCells = byKey.values.where((c) => c.abc == 'A').toList();
    final aItems = aCells.fold<int>(0, (sum, c) => sum + c.items);
    final aValue = aCells.fold<num>(0, (sum, c) => sum + c.totalValue);
    final stoppedA = byKey['stopped|A'];
    final spans = <InlineSpan>[
      TextSpan(text: '$totalItems', style: bold),
      const TextSpan(text: ' items sold in the last 12 months, worth '),
      TextSpan(text: formatRand(totalValue), style: bold),
      const TextSpan(text: '. Just '),
      TextSpan(text: '$aItems', style: bold),
      const TextSpan(text: ' of them (the A items) make up '),
      TextSpan(text: _pctLabel(aValue, totalValue), style: bold),
      const TextSpan(text: ' of sales. '),
    ];
    if (stoppedA != null) {
      spans.addAll([
        TextSpan(text: '${stoppedA.items}', style: bold),
        TextSpan(
          text: stoppedA.items == 1
              ? ' A item has stopped selling (${formatRand(stoppedA.totalValue)} of last year\'s sales), and '
              : ' A items have stopped selling (${formatRand(stoppedA.totalValue)} of last year\'s sales), and ',
        ),
      ]);
    }
    if (dormant != null) {
      spans.addAll([
        TextSpan(text: '${dormant.items}', style: bold),
        const TextSpan(text: ' older items have had no sales for 12 months or more.'),
      ]);
    }
    return Text.rich(TextSpan(style: base, children: spans));
  }

  void _openItem(String code) {
    context.go('/sales-by/item?highlight=${Uri.encodeQueryComponent(code)}');
  }

  Future<void> _showItemList(BuildContext context, ItemSegmentCell cell) {
    final isDormant = cell.segmentKey == kItemDormantKey;
    final def = itemSegDefFor(cell.segmentKey);
    final title = isDormant ? 'Dormant' : '${def?.name ?? cell.segmentKey} · ${cell.abc} items';
    final future = ref.read(salesRepositoryProvider).fetchItemSegmentItems(
          asOf: _asOf,
          segmentKey: cell.segmentKey,
          abc: cell.abc,
          filters: ref.read(globalFiltersProvider).toFilterParams(),
        );
    return showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final size = MediaQuery.of(dialogContext).size;
        final dialogWidth = size.width < 720 ? size.width * 0.9 : 820.0;
        return AlertDialog(
          title: Text('$title · ${cell.items} items'),
          content: SizedBox(
            width: dialogWidth,
            height: size.height * 0.6,
            child: FutureBuilder<List<ItemSegmentItem>>(
              future: future,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return Center(
                    child: Text('Something went wrong loading this: ${snapshot.error}',
                        style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  );
                }
                final items = snapshot.data ?? const <ItemSegmentItem>[];
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (cell.items > items.length)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          'Showing the biggest ${items.length} of ${cell.items}.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    Expanded(
                      child: SingleChildScrollView(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: ConstrainedBox(
                            constraints: BoxConstraints(minWidth: dialogWidth),
                            child: DataTable(
                              showCheckboxColumn: false,
                              columns: [
                                const DataColumn(label: Text('Item')),
                                DataColumn(label: Text(isDormant ? 'Sold in the year before' : 'Net sales, last 12 months'), numeric: true),
                                const DataColumn(label: Text('Customers'), numeric: true),
                                const DataColumn(label: Text('First sold')),
                                const DataColumn(label: Text('Last sold')),
                              ],
                              rows: [
                                for (final i in items)
                                  DataRow(
                                    onSelectChanged: (_) {
                                      Navigator.of(dialogContext).pop();
                                      _openItem(i.code);
                                    },
                                    cells: [
                                      DataCell(ConstrainedBox(
                                        constraints: const BoxConstraints(maxWidth: 300),
                                        child: Text(i.name, maxLines: 2, overflow: TextOverflow.ellipsis),
                                      )),
                                      DataCell(Text(formatRand(isDormant ? i.priorValue : i.value))),
                                      DataCell(Text(isDormant ? '–' : formatQuantity(i.customers))),
                                      DataCell(Text(i.firstMonth)),
                                      DataCell(Text(i.lastMonth)),
                                    ],
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Close')),
          ],
        );
      },
    );
  }

  Future<ExportData> _buildExportData() async {
    final data = await _future;
    final active = data.cells.where((c) => c.segmentKey != kItemDormantKey).toList();
    final totalItems = active.fold<int>(0, (sum, c) => sum + c.items);
    final totalValue = active.fold<num>(0, (sum, c) => sum + c.totalValue);
    String pct(num part, num whole) => whole == 0 ? '0%' : '${(part / whole * 100).toStringAsFixed(1)}%';
    final order = [for (final d in kItemSegDefs) d.key];
    final sorted = [...data.cells]..sort((a, b) {
        final sa = order.indexOf(a.segmentKey);
        final sb = order.indexOf(b.segmentKey);
        final ia = sa < 0 ? 99 : sa;
        final ib = sb < 0 ? 99 : sb;
        if (ia != ib) return ia.compareTo(ib);
        return a.abc.compareTo(b.abc);
      });
    return ExportData(
      title: 'Item Segments (last 12 months)',
      fileNameBase: 'item_segments',
      headers: const ['Segment', 'Class', 'Items', '% of items', 'Net sales (last 12 months)', '% of sales', 'Sold in the year before (dormant)'],
      rows: [
        for (final c in sorted)
          [
            c.segmentKey == kItemDormantKey ? 'Dormant' : (itemSegDefFor(c.segmentKey)?.name ?? c.segmentKey),
            c.abc,
            '${c.items}',
            c.segmentKey == kItemDormantKey ? '' : pct(c.items, totalItems),
            c.segmentKey == kItemDormantKey ? '' : formatRand(c.totalValue),
            c.segmentKey == kItemDormantKey ? '' : pct(c.totalValue, totalValue),
            c.segmentKey == kItemDormantKey ? formatRand(c.priorValue) : '',
          ],
      ],
    );
  }
}

String _pctLabel(num part, num whole) {
  if (whole == 0) return '0%';
  final p = part / whole * 100;
  return p < 10 ? '${p.toStringAsFixed(1)}%' : '${p.toStringAsFixed(0)}%';
}

const List<String> _kClasses = ['A', 'B', 'C'];
const Map<String, String> _kClassHint = {'A': 'top 80%', 'B': 'next 15%', 'C': 'tail 5%'};

// ---------------------------------------------------------------------------
// Chart
// ---------------------------------------------------------------------------

class _ChartCard extends StatelessWidget {
  const _ChartCard({
    required this.byKey,
    required this.dormant,
    required this.totalValue,
    required this.selectedKey,
    required this.onSelect,
  });

  final Map<String, ItemSegmentCell> byKey;
  final ItemSegmentCell? dormant;
  final num totalValue;
  final String selectedKey;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Item segment chart', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text('Across: what sales are doing. Down: how much the item matters.', style: muted),
            const SizedBox(height: 12),
            LayoutBuilder(
              builder: (context, constraints) {
                final compact = constraints.maxWidth < 560;
                final labelW = compact ? 26.0 : 66.0;
                const gap = 3.0;
                final headerH = compact ? 56.0 : 26.0;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        SizedBox(width: labelW),
                        for (final d in kItemSegDefs)
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: gap / 2),
                              child: SizedBox(
                                height: headerH,
                                child: compact
                                    ? RotatedBox(
                                        quarterTurns: 3,
                                        child: Align(
                                          alignment: Alignment.centerLeft,
                                          child: Text(d.name, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600)),
                                        ),
                                      )
                                    : Align(
                                        alignment: Alignment.bottomLeft,
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Container(
                                              width: 10,
                                              height: 10,
                                              margin: const EdgeInsets.only(right: 5),
                                              decoration: BoxDecoration(color: d.color, borderRadius: BorderRadius.circular(2)),
                                            ),
                                            Flexible(
                                              child: Text(
                                                d.name,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    for (final abc in _kClasses)
                      Padding(
                        padding: const EdgeInsets.only(bottom: gap),
                        child: SizedBox(
                          height: compact ? 72 : 92,
                          child: Row(
                            children: [
                              SizedBox(
                                width: labelW,
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(abc, style: theme.textTheme.titleMedium),
                                    if (!compact) Text(_kClassHint[abc]!, style: muted),
                                  ],
                                ),
                              ),
                              for (final d in kItemSegDefs)
                                Expanded(
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: gap / 2),
                                    child: _Tile(
                                      def: d,
                                      cell: byKey['${d.key}|$abc'],
                                      totalValue: totalValue,
                                      compact: compact,
                                      selected: selectedKey == '${d.key}|$abc',
                                      onTap: () => onSelect('${d.key}|$abc'),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('← newer items', style: muted),
                Text('items that have stopped →', style: muted),
              ],
            ),
            if (dormant != null) ...[
              const SizedBox(height: 10),
              _DormantBar(cell: dormant!, selected: selectedKey == dormant!.cellKey, onTap: () => onSelect(dormant!.cellKey)),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 14,
              runSpacing: 6,
              children: [
                Text('A = first 80% of sales', style: muted),
                Text('B = next 15%', style: muted),
                Text('C = last 5% (the long tail)', style: muted),
                Text('· thin bar in a tile = its share of sales', style: muted),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.def,
    required this.cell,
    required this.totalValue,
    required this.compact,
    required this.selected,
    required this.onTap,
  });

  final ItemSegDef def;
  final ItemSegmentCell? cell;
  final num totalValue;
  final bool compact;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = cell;
    final theme = Theme.of(context);
    if (c == null) {
      return Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: theme.dividerColor),
        ),
        alignment: Alignment.center,
        child: Text('–', style: theme.textTheme.bodySmall),
      );
    }
    final fg = def.onColor;
    final share = totalValue == 0 ? 0.0 : (c.totalValue / totalValue).toDouble().clamp(0.0, 1.0).toDouble();
    final message =
        '${def.name} ${c.abc}: ${c.items} items, ${_pctLabel(c.totalValue, totalValue)} of sales';
    return Tooltip(
      message: message,
      child: Container(
        decoration: BoxDecoration(
          color: def.color,
          borderRadius: BorderRadius.circular(6),
          border: selected ? Border.all(color: theme.colorScheme.onSurface, width: 3) : null,
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: onTap,
            child: Padding(
              padding: EdgeInsets.all(compact ? 4 : 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        '${c.items}',
                        style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: compact ? 16 : 24, height: 1.1),
                      ),
                      if (!compact)
                        Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: Text(c.items == 1 ? 'item' : 'items', style: TextStyle(color: fg, fontSize: 11)),
                        ),
                    ],
                  ),
                  const Spacer(),
                  if (!compact)
                    Text(
                      '${_pctLabel(c.totalValue, totalValue)} of sales',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: fg, fontSize: 10.5, height: 1.2),
                    ),
                  const SizedBox(height: 4),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: Stack(
                      children: [
                        Container(height: 4, color: fg.withValues(alpha: 0.28)),
                        FractionallySizedBox(
                          widthFactor: share < 0.02 ? 0.02 : share,
                          child: Container(height: 4, color: fg),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DormantBar extends StatelessWidget {
  const _DormantBar({required this.cell, required this.selected, required this.onTap});

  final ItemSegmentCell cell;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: selected ? theme.colorScheme.onSurface : theme.dividerColor, width: selected ? 3 : 1),
        ),
        child: Wrap(
          spacing: 12,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(color: Colors.grey, borderRadius: BorderRadius.circular(3)),
            ),
            Text('${cell.items}', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
            Text('Dormant items', style: theme.textTheme.titleSmall),
            Text(
              'no sales for 12 months or more · they sold ${formatRand(cell.priorValue)} in the year before that',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Detail panel
// ---------------------------------------------------------------------------

class _DetailCard extends StatelessWidget {
  const _DetailCard({
    required this.cell,
    required this.totalItems,
    required this.totalValue,
    required this.onViewAll,
    required this.onOpenItem,
  });

  final ItemSegmentCell cell;
  final int totalItems;
  final num totalValue;
  final VoidCallback onViewAll;
  final ValueChanged<String> onOpenItem;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDormant = cell.segmentKey == kItemDormantKey;
    final def = itemSegDefFor(cell.segmentKey);

    Widget row(String label, String value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
              const SizedBox(width: 12),
              Flexible(child: Text(value, textAlign: TextAlign.right, style: theme.textTheme.bodyMedium)),
            ],
          ),
        );

    final forecastNote = isDormant ? kItemDormantNote : (def?.forecastNote ?? '');
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 12,
                  height: 12,
                  margin: const EdgeInsets.only(right: 8),
                  decoration: BoxDecoration(color: def?.color ?? Colors.grey, borderRadius: BorderRadius.circular(3)),
                ),
                Expanded(
                  child: Text(
                    isDormant ? 'Dormant' : '${def?.name ?? cell.segmentKey} · ${cell.abc} items',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                Text('${cell.items} items', style: theme.textTheme.bodySmall),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              isDormant
                  ? 'No sales for 12 months or more. Kept so you can see what has dropped away.'
                  : (def?.description ?? ''),
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            if (isDormant) ...[
              row('Items', '${cell.items}'),
              row('Sold in the year before the last 12 months', formatRand(cell.priorValue)),
            ] else ...[
              row('Share of items', _pctLabel(cell.items, totalItems)),
              row('Share of sales', _pctLabel(cell.totalValue, totalValue)),
              row('Sales, last 12 months', formatRand(cell.totalValue)),
              row('Average per item', formatRand(cell.items == 0 ? 0 : cell.totalValue / cell.items)),
            ],
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: theme.colorScheme.primary.withValues(alpha: 0.3)),
              ),
              child: Text.rich(
                TextSpan(
                  style: theme.textTheme.bodySmall,
                  children: [
                    const TextSpan(text: 'Forecast: ', style: TextStyle(fontWeight: FontWeight.w700)),
                    TextSpan(text: forecastNote),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(isDormant ? 'Biggest items that went quiet' : 'Biggest items here', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            for (final t in cell.top)
              InkWell(
                onTap: () => onOpenItem(t.code),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      Expanded(child: Text(t.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
                      const SizedBox(width: 12),
                      Text(
                        isDormant
                            ? '${formatRand(t.value)} · last ${t.lastMonth}'
                            : '${formatRand(t.value)} · ${t.customers} ${t.customers == 1 ? 'customer' : 'customers'}',
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton(
                onPressed: onViewAll,
                child: Text('View all ${cell.items} items'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Concentration and stopped cards
// ---------------------------------------------------------------------------

class _ConcentrationCard extends StatelessWidget {
  const _ConcentrationCard({required this.concentration, required this.onOpenItem});

  final ItemConcentration concentration;
  final ValueChanged<String> onOpenItem;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = concentration;
    return SizedBox(
      width: double.infinity,
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Depends on one or two customers', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              if (c.abItems == 0)
                Text('No A or B items to check.', style: theme.textTheme.bodyMedium)
              else ...[
                Text(
                  '${c.riskyItems} of the ${c.abItems} A and B items are bought by two customers or fewer, or have one customer making up 60% or more of the item. ${c.riskyAItems} of them are A items, worth ${formatRand(c.riskyAValue)}.',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 8),
                for (final t in c.top)
                  InkWell(
                    onTap: () => onOpenItem(t.code),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(
                        children: [
                          Expanded(child: Text(t.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
                          const SizedBox(width: 12),
                          Text('${formatRand(t.value)} · ${t.customers} cust · top ${t.topSharePct}%',
                              style: theme.textTheme.bodySmall),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 6),
                Text(
                  'Losing one customer would take most of that item\'s sales with it.',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _StoppedCard extends StatelessWidget {
  const _StoppedCard({required this.cells, required this.totalValue, required this.onOpenItem});

  final List<ItemSegmentCell> cells;
  final num totalValue;
  final ValueChanged<String> onOpenItem;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = cells.fold<int>(0, (sum, c) => sum + c.items);
    final value = cells.fold<num>(0, (sum, c) => sum + c.totalValue);
    final abValue = cells.where((c) => c.abc == 'A' || c.abc == 'B').fold<num>(0, (sum, c) => sum + c.totalValue);
    final tops = <MapEntry<String, ItemSegmentTop>>[
      for (final c in cells.where((c) => c.abc == 'A' || c.abc == 'B'))
        for (final t in c.top.take(3)) MapEntry(c.abc, t),
    ]..sort((a, b) => b.value.value.compareTo(a.value.value));
    return SizedBox(
      width: double.infinity,
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Stopped selling', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              if (items == 0)
                Text('No items have stopped selling.', style: theme.textTheme.bodyMedium)
              else ...[
                Text(
                  '$items items sold in the last 12 months but nothing for the last 4. They account for ${formatRand(value)} (${_pctLabel(value, totalValue)}) of last year\'s sales'
                  '${abValue > 0 ? '; the A and B items among them are ${formatRand(abValue)}' : ''}.',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 8),
                for (final e in tops.take(5))
                  InkWell(
                    onTap: () => onOpenItem(e.value.code),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(
                        children: [
                          Expanded(child: Text(e.value.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
                          const SizedBox(width: 12),
                          Text('${formatRand(e.value.value)} · class ${e.key}', style: theme.textTheme.bodySmall),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 6),
                Text(
                  'The forecast fades these to zero. If one should still be selling, this list is where you would find out.',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Table view of every segment
// ---------------------------------------------------------------------------

class _TableCard extends StatelessWidget {
  const _TableCard({
    required this.cells,
    required this.totalItems,
    required this.totalValue,
    required this.selectedKey,
    required this.onSelect,
  });

  final List<ItemSegmentCell> cells;
  final int totalItems;
  final num totalValue;
  final String selectedKey;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = <DataRow>[];
    for (final def in kItemSegDefs) {
      final mine = cells.where((c) => c.segmentKey == def.key).toList();
      if (mine.isEmpty) continue;
      final items = mine.fold<int>(0, (sum, c) => sum + c.items);
      final value = mine.fold<num>(0, (sum, c) => sum + c.totalValue);
      int countFor(String abc) => mine.where((c) => c.abc == abc).fold<int>(0, (sum, c) => sum + c.items);
      mine.sort((a, b) => b.totalValue.compareTo(a.totalValue));
      final firstKey = mine.first.cellKey;
      rows.add(DataRow(
        selected: selectedKey.startsWith('${def.key}|'),
        onSelectChanged: (_) => onSelect(firstKey),
        cells: [
          DataCell(Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 10,
                height: 10,
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(color: def.color, borderRadius: BorderRadius.circular(2)),
              ),
              Text(def.name),
            ],
          )),
          DataCell(Text('$items')),
          DataCell(Text(_pctLabel(items, totalItems))),
          DataCell(Text(formatRand(value))),
          DataCell(Text(_pctLabel(value, totalValue))),
          DataCell(Text(formatRand(items == 0 ? 0 : value / items))),
          DataCell(Text('${countFor('A')}')),
          DataCell(Text('${countFor('B')}')),
          DataCell(Text('${countFor('C')}')),
        ],
      ));
    }
    final dormantList = cells.where((c) => c.segmentKey == kItemDormantKey).toList();
    if (dormantList.isNotEmpty) {
      final d = dormantList.first;
      rows.add(DataRow(
        selected: selectedKey == d.cellKey,
        onSelectChanged: (_) => onSelect(d.cellKey),
        cells: [
          DataCell(Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 10,
                height: 10,
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(color: Colors.grey, borderRadius: BorderRadius.circular(2)),
              ),
              const Text('Dormant'),
            ],
          )),
          DataCell(Text('${d.items}')),
          const DataCell(Text('–')),
          DataCell(Text('sold ${formatRand(d.priorValue)} in the year before')),
          const DataCell(Text('–')),
          const DataCell(Text('–')),
          const DataCell(Text('–')),
          const DataCell(Text('–')),
          const DataCell(Text('–')),
        ],
      ));
    }
    return SizedBox(
      width: double.infinity,
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('All segments', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              LayoutBuilder(
                builder: (context, constraints) => SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minWidth: constraints.maxWidth),
                    child: DataTable(
                      showCheckboxColumn: false,
                      columns: const [
                        DataColumn(label: Text('Segment')),
                        DataColumn(label: Text('Items'), numeric: true),
                        DataColumn(label: Text('% items'), numeric: true),
                        DataColumn(label: Text('Net sales'), numeric: true),
                        DataColumn(label: Text('% sales'), numeric: true),
                        DataColumn(label: Text('Avg per item'), numeric: true),
                        DataColumn(label: Text('A'), numeric: true),
                        DataColumn(label: Text('B'), numeric: true),
                        DataColumn(label: Text('C'), numeric: true),
                      ],
                      rows: rows,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
