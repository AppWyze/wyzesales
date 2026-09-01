import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../../core/app_providers.dart';
import '../../../core/constants/fiscal.dart';
import '../../../core/filters/global_filters.dart';
import '../../../core/supabase/supabase_config.dart';
import '../../../core/utils/formatters.dart';
import '../../../data/models/budget_figure.dart';
import '../../../data/models/reference_data.dart';
import '../../../shared/widgets/app_shell.dart';
import '../../../shared/widgets/async_section.dart';
import '../../../shared/widgets/boxed_dropdown.dart';
import '../../../shared/widgets/responsive_data_table.dart';

/// 2026-09-01, Craig, looking at a screenshot of this exact screen: "The
/// Sales Budget input value is not formatted to 591,080." Every other
/// number in the app already gets comma-grouped thousands via
/// formatRand/formatQuantity (formatters.dart) — this TextField was the one
/// place displaying a raw editable number (a plain `keyboardType:
/// TextInputType.number` field with no formatter at all), because it's the
/// one live-editable numeric input in the app rather than a read-only
/// Text/DataCell. Re-formats to "591,080" on every keystroke as the admin
/// types; digits are stripped back out again before parsing/saving
/// (`_MonthTableState._save`), so what's actually persisted is still the
/// plain numeric value budget_figures.budget_value always was.
///
/// Deliberately simple rather than cursor-position-preserving: always
/// re-collapses to the digits typed so far and places the cursor at the
/// end. A budget figure is typed once, start to finish, in one sitting —
/// there's no realistic case here of editing in the middle of an existing
/// number the way there might be in a general-purpose form field — so the
/// simpler implementation was not worth trading against a much fussier
/// mid-string-edit-safe version for a field nobody edits that way.
class _ThousandsInputFormatter extends TextInputFormatter {
  static final RegExp _nonDigits = RegExp(r'[^\d]');
  static final NumberFormat _format = NumberFormat.decimalPattern('en_US');

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final digits = newValue.text.replaceAll(_nonDigits, '');
    if (digits.isEmpty) {
      return const TextEditingValue(text: '');
    }
    final formatted = _format.format(int.parse(digits));
    return TextEditingValue(text: formatted, selection: TextSelection.collapsed(offset: formatted.length));
  }
}

class _BudgetEntityData {
  final List<CodeName> entities;
  const _BudgetEntityData(this.entities);
}

class _BudgetMonthData {
  final Map<String, num> budget; // fiscal_month -> value
  final Map<String, num> forecast;
  final Map<String, String> confidence;
  const _BudgetMonthData({required this.budget, required this.forecast, required this.confidence});
}

/// Entity picker on the left, two 12-month fiscal columns on the right — an
/// editable Sales Budget and a read-only Seasonal Forecast
/// (Wyzesales_Screens_and_Recommendations.md Section 1). Editing requires
/// adminuser/superuser (schema/004 + schema/005 — see those migrations for
/// why both are needed for a second edit to the same month to actually
/// save).
class BudgetsScreen extends ConsumerStatefulWidget {
  const BudgetsScreen({super.key, required this.dimension});

  final SalesDimension dimension;

  @override
  ConsumerState<BudgetsScreen> createState() => _BudgetsScreenState();
}

class _BudgetsScreenState extends ConsumerState<BudgetsScreen> {
  late Future<_BudgetEntityData> _entitiesFuture;
  String? _selectedEntityCode;
  String? _selectedEntityName;
  Future<_BudgetMonthData>? _monthDataFuture;

  @override
  void initState() {
    super.initState();
    _entitiesFuture = _loadEntities();
  }

  @override
  void didUpdateWidget(covariant BudgetsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.dimension != widget.dimension) {
      _selectedEntityCode = null;
      _monthDataFuture = null;
      _entitiesFuture = _loadEntities();
    }
  }

  Future<_BudgetEntityData> _loadEntities() async {
    final list = await ref.read(referenceDataRepositoryProvider).entitiesFor(widget.dimension);
    final data = _BudgetEntityData(list);
    _applyGlobalFilterSelection(data);
    return data;
  }

  /// Budgets/forecast (budget_figures/sales_forecast, schema/001 Section 4/
  /// 5) are keyed by ONE dimension + entity_code only — there's no other
  /// dimension's code recorded against a budget row at all, so unlike every
  /// other screen this migration wires up, a global filter for a DIFFERENT
  /// dimension genuinely can't narrow anything here (there's no data to
  /// narrow). What this can do is jump straight to the entity a global
  /// filter already names for THIS screen's own dimension — e.g. arriving
  /// on Budgets — Sales Person with a global Sales Person filter active
  /// auto-selects that rep instead of leaving the list unselected. Flagged
  /// in Wyzesales_Rebuild_Decisions.md Section 18 as the one screen this
  /// pass only partially wires up, rather than silently pretending it's
  /// fully filterable.
  void _applyGlobalFilterSelection(_BudgetEntityData data) {
    final selection = ref.read(globalFiltersProvider).forDimension(widget.dimension);
    if (selection == null || !mounted) return;
    final match = data.entities.where((e) => e.code == selection.code).toList();
    if (match.isEmpty) return;
    _selectEntity(match.first);
  }

  void _selectEntity(CodeName entity) {
    setState(() {
      _selectedEntityCode = entity.code;
      _selectedEntityName = entity.displayLabel;
      _monthDataFuture = _loadMonthData(entity.code);
    });
  }

  Future<_BudgetMonthData> _loadMonthData(String entityCode) async {
    final budgetRepo = ref.read(budgetRepositoryProvider);
    final results = await Future.wait([
      budgetRepo.fetchBudget(dimension: widget.dimension.dbValue, entityCode: entityCode),
      _fetchForecast(entityCode),
    ]);
    final budgetRows = results[0] as List<BudgetFigure>;
    final forecastRows = results[1] as List<Map<String, dynamic>>;
    return _BudgetMonthData(
      budget: {for (final b in budgetRows) b.fiscalMonth: b.budgetValue},
      forecast: {for (final f in forecastRows) f['fiscal_month'] as String: f['forecast_value'] as num},
      confidence: {for (final f in forecastRows) f['fiscal_month'] as String: f['confidence'] as String},
    );
  }

  /// sales_forecast is read-only and only needed on this one screen, so
  /// queried directly rather than adding a dedicated repository for a
  /// single call site.
  Future<List<Map<String, dynamic>>> _fetchForecast(String entityCode) async {
    return supabase
        .from('sales_forecast')
        .select('fiscal_month, forecast_value, confidence')
        .eq('dimension', widget.dimension.dbValue)
        .eq('entity_code', entityCode);
  }

  @override
  Widget build(BuildContext context) {
    final profileAsync = ref.watch(sessionProvider);

    // Admin/SuperUser only, per Craig's decision. This is the real
    // enforcement point — app_shell.dart's nav gate only hides the menu
    // entry, so this check is what actually stops a User/RegUser who
    // navigates straight to /budgets/:dimension (e.g. a bookmarked or
    // typed URL) from seeing the screen at all. Checked separately from
    // "not yet loaded" so a still-loading profile shows a spinner instead
    // of flashing "access denied" before the real value arrives.
    if (profileAsync.isLoading) {
      return AppShell(
        title: 'Budgets — ${widget.dimension.label}',
        currentRoute: '/budgets/${widget.dimension.dbValue}',
        body: const Center(child: RepaintBoundary(child: CircularProgressIndicator())),
      );
    }

    final canEdit = profileAsync.value?.canEditBudgets ?? false;
    if (!canEdit) {
      return AppShell(
        title: 'Budgets — ${widget.dimension.label}',
        currentRoute: '/budgets/${widget.dimension.dbValue}',
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.lock_outline, size: 48, color: Theme.of(context).textTheme.bodyMedium?.color),
                const SizedBox(height: 12),
                Text(
                  'Budgets are only visible to Admin and SuperUser accounts.',
                  style: Theme.of(context).textTheme.titleMedium,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      );
    }

    return AppShell(
      title: 'Budgets — ${widget.dimension.label}',
      currentRoute: '/budgets/${widget.dimension.dbValue}',
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 260,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: BoxedDropdown<SalesDimension>(
                    value: widget.dimension,
                    width: 236,
                    items: SalesDimension.values.map((d) => DropdownMenuItem(value: d, child: Text(d.label))).toList(),
                    onChanged: (d) {
                      if (d != null && d != widget.dimension) context.go('/budgets/${d.dbValue}');
                    },
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: AsyncSection<_BudgetEntityData>(
                    future: _entitiesFuture,
                    isEmpty: (d) => d.entities.isEmpty,
                    builder: (context, data) => ListView.builder(
                      itemCount: data.entities.length,
                      itemBuilder: (context, index) {
                        final entity = data.entities[index];
                        return ListTile(
                          title: Text(entity.displayLabel, overflow: TextOverflow.ellipsis),
                          selected: entity.code == _selectedEntityCode,
                          onTap: () => _selectEntity(entity),
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: _selectedEntityCode == null
                ? const Center(child: Text('Select an entity from the list.'))
                : Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_selectedEntityName ?? _selectedEntityCode!, style: Theme.of(context).textTheme.titleLarge),
                        const SizedBox(height: 12),
                        Expanded(
                          child: AsyncSection<_BudgetMonthData>(
                            future: _monthDataFuture!,
                            builder: (context, data) => _MonthTable(
                              dimension: widget.dimension,
                              entityCode: _selectedEntityCode!,
                              data: data,
                              // Always true here — the whole screen already
                              // returned an access-denied state above for
                              // anyone who fails canEditBudgets, so nobody
                              // who reaches this point is read-only anymore.
                              canEdit: true,
                              clientId: profileAsync.value?.clientId,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _MonthTable extends ConsumerStatefulWidget {
  const _MonthTable({
    required this.dimension,
    required this.entityCode,
    required this.data,
    required this.canEdit,
    required this.clientId,
  });

  final SalesDimension dimension;
  final String entityCode;
  final _BudgetMonthData data;
  final bool canEdit;
  final String? clientId;

  @override
  ConsumerState<_MonthTable> createState() => _MonthTableState();
}

class _MonthTableState extends ConsumerState<_MonthTable> {
  late final Map<String, TextEditingController> _controllers;
  // Computed once at mount, same as ytd_comparative_screen.dart's
  // _fiscalYears — this table's row/column ORDER is display-only (every
  // lookup below is keyed by the calendar month label itself, e.g.
  // widget.data.budget[month], so a different rotation never changes which
  // value a row shows, only which row it shows first).
  late final List<String> _months;

  @override
  void initState() {
    super.initState();
    _months = fiscalMonthOrderFor(startMonth: ref.read(fiscalYearStartMonthProvider).valueOrNull ?? 3);
    _controllers = {
      for (final month in _months)
        // Comma-grouped from the start (e.g. "591,080") to match what
        // _ThousandsInputFormatter keeps it as on every subsequent keystroke
        // — see that class's own doc comment.
        month: TextEditingController(text: _ThousandsInputFormatter._format.format(widget.data.budget[month] ?? 0)),
    };
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save(String month) async {
    final clientId = widget.clientId;
    if (clientId == null) return;
    // _ThousandsInputFormatter keeps this field's text comma-grouped (e.g.
    // "591,080") — strip that back out before parsing, since budget_figures
    // itself still just stores the plain numeric value.
    final digitsOnly = _controllers[month]!.text.replaceAll(RegExp(r'[^\d]'), '');
    final parsed = digitsOnly.isEmpty ? 0 : num.tryParse(digitsOnly);
    if (parsed == null) return;
    await ref.read(budgetRepositoryProvider).setBudgetValue(
          clientId: clientId,
          dimension: widget.dimension.dbValue,
          entityCode: widget.entityCode,
          fiscalMonth: month,
          budgetValue: parsed,
        );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$month budget saved.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    // No onSort here, deliberately — unlike every other table in the app,
    // this one is an editable grid where the row order (fiscal month, Mar ->
    // Feb) IS the meaningful, expected order for entering a budget, and each
    // row holds a live TextEditingController; letting rows jump around
    // under a half-typed value seemed like the wrong trade for a "sort by
    // column" feature nobody's likely to reach for on a 12-row form.
    // Flagged back to Craig rather than silently applied — happy to add it
    // if it turns out to be wanted here too.
    //
    // stickyHeader: false — 2026-08-27, the rest of the app's tables got a
    // frozen header (+ frozen Totals row where they have one) via
    // ResponsiveDataTable, now backed by the data_table_2 package (Craig:
    // "lock the Headers and Totals so we don't lose them when scrolling
    // down"). This table opts out — not because of any technical
    // constraint (data_table_2 renders the row list once, so the earlier
    // hand-rolled version's "two simultaneously-mounted TextField
    // controllers" hazard doesn't apply here any more), but because this
    // table's Totals row deliberately stays at the BOTTOM, unpinned
    // (Wyzesales_Rebuild_Decisions.md Section 22b: Budgets was never
    // included in the "Totals to the top" scope Craig confirmed for the
    // other tables). A frozen HEADER alone would be safe to add here today
    // if wanted — flagged as an easy follow-up, not applied unasked.
    return ResponsiveDataTable(
      stickyHeader: false,
      columns: const [
        DataColumn(label: Text('Month')),
        DataColumn(label: Text('Sales Budget'), numeric: true),
        DataColumn(label: Text('Seasonal Forecast'), numeric: true),
        DataColumn(label: Text('Confidence')),
      ],
      rows: [
        ..._months.map((month) {
          return DataRow(cells: [
            DataCell(Text(month)),
            DataCell(
              widget.canEdit
                  ? SizedBox(
                      width: 120,
                      child: TextField(
                        controller: _controllers[month],
                        keyboardType: TextInputType.number,
                        // Right-aligned to match the read-only Seasonal
                        // Forecast column beside it (Craig, 2026-09-01,
                        // "can you right justify these values as well") —
                        // DataTable's `numeric: true` column setting only
                        // right-aligns a plain Text cell automatically, not
                        // a TextField, so this needed setting explicitly.
                        textAlign: TextAlign.right,
                        inputFormatters: [_ThousandsInputFormatter()],
                        decoration: const InputDecoration(isDense: true, prefixText: 'R '),
                        onSubmitted: (_) => _save(month),
                      ),
                    )
                  : Text(formatRand(widget.data.budget[month])),
            ),
            DataCell(Text(formatRand(widget.data.forecast[month]))),
            DataCell(Text(widget.data.confidence[month] ?? '—')),
          ]);
        }),
        _totalsRow(),
      ],
    );
  }

  /// Bold annual total — Craig, 2026-08-26: "Can we have total for each
  /// column in each table." Sums the saved Sales Budget figures
  /// (widget.data.budget), same source the read-only display already uses,
  /// not each field's live unsaved text — this table doesn't currently
  /// rebuild on every keystroke (only on save), so a total sourced from the
  /// text controllers would just as often show a stale figure as a current
  /// one; summing the saved values is the one source that's always accurate
  /// for what's actually been recorded. Confidence has no meaningful total
  /// (it's a label, not a number) so that cell is left blank.
  DataRow _totalsRow() {
    final totalBudget = _months.fold<num>(0, (sum, month) => sum + (widget.data.budget[month] ?? 0));
    final totalForecast = _months.fold<num>(0, (sum, month) => sum + (widget.data.forecast[month] ?? 0));
    const style = TextStyle(fontWeight: FontWeight.bold);
    return DataRow(cells: [
      const DataCell(Text('Total', style: style)),
      DataCell(Text(formatRand(totalBudget), style: style)),
      DataCell(Text(formatRand(totalForecast), style: style)),
      const DataCell(Text('')),
    ]);
  }
}
