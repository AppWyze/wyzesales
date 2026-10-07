import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/app_providers.dart';
import '../../../core/filters/global_filters.dart';
import '../../../core/utils/formatters.dart';
import '../../../data/models/client_dimension_config.dart';
import '../../../data/models/customer_segment.dart';
import '../../../shared/widgets/app_shell.dart';
import '../../../shared/widgets/async_section.dart';
import '../../../shared/widgets/boxed_dropdown.dart';
import '../../../shared/widgets/data_export_buttons.dart';
import '../../../shared/widgets/help_info_icon.dart';

/// Customer Segments — every customer with activity in the chosen period
/// (default: the last 12 months), scored 1-5 on how recently they bought,
/// how often, and how much, then placed on a fixed 5 x 5 grid and given one
/// of ten segment names (Best customers, Loyal regulars, Slipping away, ...).
///
/// Craig, 2026-10-07 ("I like this a lot. Can you build it into the
/// application"), after reviewing a mock-up built from real Morgenster and
/// Edgetec numbers. The scoring lives in Postgres
/// (schema/060_wyzesales_customer_segments.sql); this screen only fetches the
/// per-segment summary and, on request, the customer list for one segment.
///
/// Filters: the app-wide dimension filters (Sales Person, Branch, Category,
/// and so on) narrow the customer set, so you can look at one rep's
/// customers. Year / Quarter / Month are deliberately NOT applied — this
/// screen has its own rolling period, the same way YTD Comparative has its
/// own fixed comparison window.
class CustomerSegmentsScreen extends ConsumerStatefulWidget {
  const CustomerSegmentsScreen({super.key});

  @override
  ConsumerState<CustomerSegmentsScreen> createState() => _CustomerSegmentsScreenState();
}

class _CustomerSegmentsScreenState extends ConsumerState<CustomerSegmentsScreen> {
  static const List<int> _periodChoices = [6, 12, 24];

  int _months = 12;
  String? _selectedKey;
  late Future<List<CustomerSegmentSummary>> _future;
  late DateTime _fromDate;
  late DateTime _toDate;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<CustomerSegmentSummary>> _load() {
    final now = DateTime.now();
    _toDate = DateTime(now.year, now.month, now.day);
    // 12 months to 7 Oct 2026 means 8 Oct 2025 .. 7 Oct 2026 inclusive.
    _fromDate = DateTime(_toDate.year, _toDate.month - _months, _toDate.day).add(const Duration(days: 1));
    return ref.read(salesRepositoryProvider).fetchCustomerSegmentsSummary(
          fromDate: _fromDate,
          toDate: _toDate,
          filters: ref.read(globalFiltersProvider).toFilterParams(),
        );
  }

  void _refetch() {
    setState(() {
      _future = _load();
    });
  }

  String get _periodLabel => 'last $_months months';

  @override
  Widget build(BuildContext context) {
    ref.listen<GlobalFilters>(globalFiltersProvider, (previous, next) {
      // Only the dimension filters matter here; ignore a change that touched
      // nothing but Year / Quarter / Month / Document.
      if (previous == null || previous.toFilterParams().toString() != next.toFilterParams().toString()) {
        _refetch();
      }
    });

    final dimensions = ref.watch(clientDimensionsProvider).valueOrNull;
    final hasCustomer = dimensions == null || dimensions.forKey('customer') != null;

    return AppShell(
      title: 'Customer Segments',
      currentRoute: '/customer-segments',
      help: const TileHelp(
        title: 'How Customer Segments works',
        paragraphs: [
          'Every customer who bought in the chosen period is scored from 1 to 5 on three things: Recency (how recently they last bought), Frequency (how many invoices) and Monetary (net sales value, invoices less credit notes). Scores are ranked against the rest of your own customers for that period, so they always show how a customer compares with the others.',
          'Recency runs across the chart, from least recent on the left to most recent on the right. Up the chart is Frequency and Monetary combined: higher up means more invoices and more spend.',
          'Each coloured box is a segment. Tile colour shows how healthy the relationship is: green for Best, blue for Growing, amber for Cooling, red for At risk and purple for Dormant. The thin bar at the bottom of a tile is that segment\'s share of your sales.',
          'Click a box (or a row in the table) to see what the segment means, its biggest customers, and the full customer list.',
          'The dimension filters (Sales Person, Branch and so on) narrow which customers are included. Year, Quarter and Month filters do not apply here: this screen has its own period.',
        ],
      ),
      body: !hasCustomer
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text('Customer Segments needs a Customer dimension, which this company does not have set up.'),
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
                        BoxedDropdown<int>(
                          label: 'Period',
                          width: 200,
                          value: _months,
                          items: [
                            for (final m in _periodChoices) DropdownMenuItem<int>(value: m, child: Text('Last $m months')),
                          ],
                          onChanged: (v) {
                            if (v == null || v == _months) return;
                            _months = v;
                            _refetch();
                          },
                        ),
                        DataExportButtons(onExport: _buildExportData),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Expanded(
                    child: AsyncSection<List<CustomerSegmentSummary>>(
                      future: _future,
                      isEmpty: (rows) => rows.isEmpty,
                      emptyMessage: 'No customers bought in this period with the current filters.',
                      builder: (context, rows) => _buildContent(context, rows),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildContent(BuildContext context, List<CustomerSegmentSummary> rows) {
    final byKey = {for (final r in rows) r.segmentKey: r};
    final totalCustomers = rows.fold<int>(0, (sum, r) => sum + r.customers);
    final totalValue = rows.fold<num>(0, (sum, r) => sum + r.totalValue);

    String selectedKey = _selectedKey ?? '';
    if (!byKey.containsKey(selectedKey)) {
      // Default to whichever segment holds the most sales.
      final sorted = [...rows]..sort((a, b) => b.totalValue.compareTo(a.totalValue));
      selectedKey = sorted.first.segmentKey;
    }
    final selected = byKey[selectedKey]!;

    final best = byKey['champ'];
    final slipping = (byKey['risk']?.customers ?? 0) + (byKey['cant']?.customers ?? 0);

    final chart = _SegmentChartCard(
      byKey: byKey,
      totalCustomers: totalCustomers,
      totalValue: totalValue,
      selectedKey: selectedKey,
      onSelect: (key) => setState(() => _selectedKey = key),
    );
    final detail = _SegmentDetailCard(
      summary: selected,
      totalCustomers: totalCustomers,
      totalValue: totalValue,
      onViewAll: () => _showCustomerList(context, selected),
      onOpenCustomer: _openCustomer,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 900;
        return SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: _buildSummaryText(context, totalCustomers, totalValue, best, slipping),
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
              _SegmentTableCard(
                rows: rows,
                totalCustomers: totalCustomers,
                totalValue: totalValue,
                selectedKey: selectedKey,
                onSelect: (key) => setState(() => _selectedKey = key),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  'Scores are quintiles (1 to 5) ranked within this company\'s own customers for the period. Frequency is the number of invoices; value is invoices less credit notes.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSummaryText(BuildContext context, int totalCustomers, num totalValue, CustomerSegmentSummary? best, int slipping) {
    final base = Theme.of(context).textTheme.bodyMedium;
    final bold = base?.copyWith(fontWeight: FontWeight.w700);
    final spans = <InlineSpan>[
      const TextSpan(text: 'The '),
      TextSpan(text: '$totalCustomers', style: bold),
      TextSpan(text: ' customers who bought in the $_periodLabel have been grouped by how they buy. '),
    ];
    if (best != null) {
      final share = totalValue == 0 ? 0 : best.totalValue / totalValue * 100;
      spans.addAll([
        TextSpan(text: '${best.customers}', style: bold),
        const TextSpan(text: ' are Best customers (bought very recently, buy often and spend the most) and they account for '),
        TextSpan(text: '${share.toStringAsFixed(0)}%', style: bold),
        TextSpan(text: ' of ${formatRand(totalValue)} in sales. '),
      ]);
    } else {
      spans.add(TextSpan(text: 'Total sales in the period: ${formatRand(totalValue)}. '));
    }
    if (slipping > 0) {
      spans.addAll([
        TextSpan(text: '$slipping', style: bold),
        const TextSpan(text: ' good customers are slipping away (Slipping away or Win back now).'),
      ]);
    }
    return Text.rich(TextSpan(style: base, children: spans));
  }

  void _openCustomer(String code) {
    context.go('/sales-by/customer?highlight=${Uri.encodeQueryComponent(code)}');
  }

  Future<void> _showCustomerList(BuildContext context, CustomerSegmentSummary summary) {
    final def = segmentDefFor(summary.segmentKey);
    final future = ref.read(salesRepositoryProvider).fetchCustomerSegmentCustomers(
          fromDate: _fromDate,
          toDate: _toDate,
          segmentKey: summary.segmentKey,
          filters: ref.read(globalFiltersProvider).toFilterParams(),
        );
    return showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final size = MediaQuery.of(dialogContext).size;
        return AlertDialog(
          title: Text('${def?.name ?? summary.segmentKey} · ${summary.customers} customers'),
          content: SizedBox(
            width: size.width < 720 ? size.width * 0.9 : 680,
            height: size.height * 0.6,
            child: FutureBuilder<List<CustomerSegmentCustomer>>(
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
                final customers = snapshot.data ?? const <CustomerSegmentCustomer>[];
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (summary.customers > customers.length)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          'Showing the biggest ${customers.length} of ${summary.customers}.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    Expanded(
                      child: SingleChildScrollView(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: DataTable(
                            showCheckboxColumn: false,
                            columns: const [
                              DataColumn(label: Text('Customer')),
                              DataColumn(label: Text('Last bought (days)'), numeric: true),
                              DataColumn(label: Text('Invoices'), numeric: true),
                              DataColumn(label: Text('Net sales'), numeric: true),
                            ],
                            rows: [
                              for (final c in customers)
                                DataRow(
                                  onSelectChanged: (_) {
                                    Navigator.of(dialogContext).pop();
                                    _openCustomer(c.code);
                                  },
                                  cells: [
                                    DataCell(ConstrainedBox(
                                      constraints: const BoxConstraints(maxWidth: 300),
                                      child: Text(c.name, maxLines: 2, overflow: TextOverflow.ellipsis),
                                    )),
                                    DataCell(Text(formatQuantity(c.recDays))),
                                    DataCell(Text(formatQuantity(c.frequency))),
                                    DataCell(Text(formatRand(c.monetary))),
                                  ],
                                ),
                            ],
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
    final rows = await _future;
    final totalCustomers = rows.fold<int>(0, (sum, r) => sum + r.customers);
    final totalValue = rows.fold<num>(0, (sum, r) => sum + r.totalValue);
    final sorted = [...rows]..sort((a, b) => b.totalValue.compareTo(a.totalValue));
    String pct(num part, num whole) => whole == 0 ? '0%' : '${(part / whole * 100).toStringAsFixed(1)}%';
    return ExportData(
      title: 'Customer Segments ($_periodLabel)',
      fileNameBase: 'customer_segments',
      headers: const [
        'Segment',
        'Customers',
        '% of customers',
        'Net sales',
        '% of sales',
        'Average per customer',
        'Last bought (days) from',
        'Last bought (days) to',
      ],
      rows: [
        for (final r in sorted)
          [
            segmentDefFor(r.segmentKey)?.name ?? r.segmentKey,
            '${r.customers}',
            pct(r.customers, totalCustomers),
            formatRand(r.totalValue),
            pct(r.totalValue, totalValue),
            formatRand(r.avgValue),
            '${r.recMin}',
            '${r.recMax}',
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

// ---------------------------------------------------------------------------
// Chart
// ---------------------------------------------------------------------------

class _SegmentChartCard extends StatelessWidget {
  const _SegmentChartCard({
    required this.byKey,
    required this.totalCustomers,
    required this.totalValue,
    required this.selectedKey,
    required this.onSelect,
  });

  final Map<String, CustomerSegmentSummary> byKey;
  final int totalCustomers;
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
            Text('Customer segment chart', style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Grid(
                  byKey: byKey,
                  totalCustomers: totalCustomers,
                  totalValue: totalValue,
                  selectedKey: selectedKey,
                  onSelect: onSelect,
                ),
                const SizedBox(height: 6),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('← less recent', style: muted),
                    Text('Recency', style: muted),
                    Text('more recent →', style: muted),
                  ],
                ),
                Text('Up the chart: more invoices and more spend (Frequency + Monetary)', style: muted),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 14,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final f in SegmentFamily.values)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(color: f.color, borderRadius: BorderRadius.circular(3)),
                      ),
                      const SizedBox(width: 5),
                      Text(f.label, style: muted),
                    ],
                  ),
                Text('· thin bar in a tile = its share of sales', style: muted),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Grid extends StatelessWidget {
  const _Grid({
    required this.byKey,
    required this.totalCustomers,
    required this.totalValue,
    required this.selectedKey,
    required this.onSelect,
  });

  final Map<String, CustomerSegmentSummary> byKey;
  final int totalCustomers;
  final num totalValue;
  final String selectedKey;
  final ValueChanged<String> onSelect;

  static const double _gap = 3;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final cellW = (width - 4 * _gap) / 5;
        final cellH = (cellW * 0.9).clamp(60.0, 96.0).toDouble();
        final height = 5 * cellH + 4 * _gap;
        return SizedBox(
          width: width,
          height: height,
          child: Stack(
            children: [
              for (final def in kSegmentDefs)
                Positioned(
                  left: def.col * (cellW + _gap),
                  top: def.row * (cellH + _gap),
                  width: def.colSpan * cellW + (def.colSpan - 1) * _gap,
                  height: def.rowSpan * cellH + (def.rowSpan - 1) * _gap,
                  child: _Tile(
                    def: def,
                    summary: byKey[def.key],
                    totalCustomers: totalCustomers,
                    totalValue: totalValue,
                    selected: def.key == selectedKey,
                    onTap: () => onSelect(def.key),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.def,
    required this.summary,
    required this.totalCustomers,
    required this.totalValue,
    required this.selected,
    required this.onTap,
  });

  final SegmentDef def;
  final CustomerSegmentSummary? summary;
  final int totalCustomers;
  final num totalValue;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = summary;
    final theme = Theme.of(context);

    if (s == null) {
      return Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: theme.dividerColor),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              def.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
            ),
            const Spacer(),
            Text('no customers', style: theme.textTheme.bodySmall),
          ],
        ),
      );
    }

    final fg = def.family.onColor;
    final shareOfSales = totalValue == 0 ? 0.0 : (s.totalValue / totalValue).toDouble().clamp(0.0, 1.0).toDouble();
    final message =
        '${def.name}: ${s.customers} customers, ${_pctLabel(s.customers, totalCustomers)} of customers, ${_pctLabel(s.totalValue, totalValue)} of sales';

    return LayoutBuilder(
      builder: (context, c) {
        final compact = c.maxWidth < 100;
        final showDetail = !compact && c.maxHeight >= 100;
        return Tooltip(
          message: message,
          child: Container(
            decoration: BoxDecoration(
              color: def.family.color,
              borderRadius: BorderRadius.circular(6),
              border: selected ? Border.all(color: theme.colorScheme.onSurface, width: 3) : null,
            ),
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: onTap,
                child: Padding(
                  padding: EdgeInsets.all(compact ? 5 : 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        def.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: compact ? 10 : 13, height: 1.1),
                      ),
                      const Spacer(),
                      Text(
                        '${s.customers}',
                        style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: compact ? 18 : 24, height: 1.1),
                      ),
                      if (showDetail)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            '${_pctLabel(s.customers, totalCustomers)} of customers · ${_pctLabel(s.totalValue, totalValue)} of sales',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: fg, fontSize: 11),
                          ),
                        ),
                      const SizedBox(height: 4),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: Stack(
                          children: [
                            Container(height: 4, color: fg.withValues(alpha: 0.28)),
                            FractionallySizedBox(
                              widthFactor: shareOfSales < 0.02 ? 0.02 : shareOfSales,
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
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Detail panel
// ---------------------------------------------------------------------------

class _SegmentDetailCard extends StatelessWidget {
  const _SegmentDetailCard({
    required this.summary,
    required this.totalCustomers,
    required this.totalValue,
    required this.onViewAll,
    required this.onOpenCustomer,
  });

  final CustomerSegmentSummary summary;
  final int totalCustomers;
  final num totalValue;
  final VoidCallback onViewAll;
  final ValueChanged<String> onOpenCustomer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final def = segmentDefFor(summary.segmentKey);

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

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (def != null)
                  Container(
                    width: 12,
                    height: 12,
                    margin: const EdgeInsets.only(right: 8),
                    decoration: BoxDecoration(color: def.family.color, borderRadius: BorderRadius.circular(3)),
                  ),
                Expanded(
                  child: Text(def?.name ?? summary.segmentKey, style: theme.textTheme.titleMedium),
                ),
                Text('${summary.customers} customers', style: theme.textTheme.bodySmall),
              ],
            ),
            if (def != null) ...[
              const SizedBox(height: 8),
              Text(def.description, style: theme.textTheme.bodyMedium),
            ],
            const SizedBox(height: 12),
            row('Share of customers', _pctLabel(summary.customers, totalCustomers)),
            row('Share of sales', _pctLabel(summary.totalValue, totalValue)),
            row('Total sales value', formatRand(summary.totalValue)),
            row('Average per customer', formatRand(summary.avgValue)),
            row('Last bought', '${summary.recMin} to ${summary.recMax} days ago'),
            row('Invoices in period', '${formatQuantity(summary.freqMin)} to ${formatQuantity(summary.freqMax)}'),
            row('Spend range', '${formatRand(summary.valueMin)} to ${formatRand(summary.valueMax)}'),
            const SizedBox(height: 12),
            Text('Biggest customers here', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            for (final t in summary.top)
              InkWell(
                onTap: () => onOpenCustomer(t.code),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      Expanded(child: Text(t.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
                      const SizedBox(width: 12),
                      Text(formatRand(t.value)),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton(
                onPressed: onViewAll,
                child: Text('View all ${summary.customers} customers'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Table view of every segment
// ---------------------------------------------------------------------------

class _SegmentTableCard extends StatelessWidget {
  const _SegmentTableCard({
    required this.rows,
    required this.totalCustomers,
    required this.totalValue,
    required this.selectedKey,
    required this.onSelect,
  });

  final List<CustomerSegmentSummary> rows;
  final int totalCustomers;
  final num totalValue;
  final String selectedKey;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sorted = [...rows]..sort((a, b) => b.totalValue.compareTo(a.totalValue));
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('All segments', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                showCheckboxColumn: false,
                columns: const [
                  DataColumn(label: Text('Segment')),
                  DataColumn(label: Text('Customers'), numeric: true),
                  DataColumn(label: Text('% customers'), numeric: true),
                  DataColumn(label: Text('Net sales'), numeric: true),
                  DataColumn(label: Text('% sales'), numeric: true),
                  DataColumn(label: Text('Avg per customer'), numeric: true),
                  DataColumn(label: Text('Last bought (days)'), numeric: true),
                ],
                rows: [
                  for (final r in sorted)
                    DataRow(
                      selected: r.segmentKey == selectedKey,
                      onSelectChanged: (_) => onSelect(r.segmentKey),
                      cells: [
                        DataCell(Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 10,
                              height: 10,
                              margin: const EdgeInsets.only(right: 8),
                              decoration: BoxDecoration(
                                color: segmentDefFor(r.segmentKey)?.family.color ?? Colors.grey,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                            Text(segmentDefFor(r.segmentKey)?.name ?? r.segmentKey),
                          ],
                        )),
                        DataCell(Text('${r.customers}')),
                        DataCell(Text(_pctLabel(r.customers, totalCustomers))),
                        DataCell(Text(formatRand(r.totalValue))),
                        DataCell(Text(_pctLabel(r.totalValue, totalValue))),
                        DataCell(Text(formatRand(r.avgValue))),
                        DataCell(Text('${r.recMin} to ${r.recMax}')),
                      ],
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
