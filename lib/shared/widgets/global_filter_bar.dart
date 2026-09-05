import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/app_providers.dart';
import '../../core/constants/fiscal.dart';
import '../../core/filters/global_filters.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/client_dimension_config.dart';
import '../../data/models/filter_preset.dart';
import '../../data/models/reference_data.dart';
import 'boxed_dropdown.dart';
import 'entity_search_field.dart';

/// Visible, editable summary of every active global filter — Craig,
/// 2026-08-26: "on each screen we need to be able to somehow see what
/// filters are applied." Mounted once in AppShell (below the top bar) so
/// it's the same strip on every screen, reading/writing the one
/// globalFiltersProvider instance that also backs each screen's own
/// dimension/Year/Month pickers (sales_by_screen.dart,
/// document_analysis_view.dart, performance_screen.dart,
/// ytd_comparative_screen.dart) — changing a filter anywhere, including
/// right here, is what makes it "stick" on every other screen (Craig: "If I
/// select a sales person on any screen and I navigate to another screen
/// that filtered salesperson must stay filtered").
class GlobalFilterBar extends ConsumerWidget {
  const GlobalFilterBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filters = ref.watch(globalFiltersProvider);
    final notifier = ref.read(globalFiltersProvider.notifier);
    // 2026-09-05 (multi-tenant dimension model Step 2): this client's own
    // configured dimension list (client_dimensions, schema/038) replaces the
    // hardcoded `SalesDimension.filterable` this loop used to iterate —
    // `drivesCrossFilter`, not every configured dimension, mirrors
    // `filterable` excluding `company` exactly (see schema/038's WCSA seed
    // comment). `valueOrNull ?? const []` (not `.when`/a loading spinner) —
    // same "don't block rendering, just show nothing yet" approach every
    // other FutureProvider-backed picker in this file already takes (see
    // `_handleAdd`'s own `fiscalYearDataAvailabilityProvider` read) — WCSA's
    // own six rows load fast enough that this is only ever visible for a
    // single frame.
    final filterableDimensions =
        ref.watch(clientDimensionsProvider).valueOrNull?.where((d) => d.drivesCrossFilter).toList() ?? const <ClientDimensionConfig>[];

    final chips = <Widget>[
      for (final dimension in filterableDimensions)
        if (filters.forKey(dimension.dimensionKey) != null)
          _RemovableChip(
            label: '${dimension.displayLabel}: ${filters.forKey(dimension.dimensionKey)!.label}',
            onDeleted: () => notifier.clearDimension(dimension.dimensionKey),
          ),
      if (filters.fiscalYear != null)
        _RemovableChip(label: 'Year: FY${filters.fiscalYear}', onDeleted: () => notifier.setFiscalYear(null)),
      if (filters.fiscalMonth != null)
        _RemovableChip(label: 'Month: ${filters.fiscalMonth}', onDeleted: () => notifier.setFiscalMonth(null)),
      if (filters.document != null)
        _RemovableChip(label: 'Document: ${filters.document}', onDeleted: () => notifier.setDocument(null)),
    ];

    return Container(
      width: double.infinity,
      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.025),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Icon(Icons.filter_alt_outlined, size: 16, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5)),
          if (chips.isEmpty)
            Text('No filters applied', style: Theme.of(context).textTheme.bodySmall)
          else
            ...chips,
          // A BoxedDropdown, not the Chip+PopupMenuButton this used to be
          // (Craig, 2026-08-26: "format the Add filter box to conform with
          // the other selection options") — same bordered box every Year/
          // Month/dimension dropdown in the app already gets from the
          // theme. `value` stays permanently null: picking an entry applies
          // it to globalFiltersProvider immediately (via onChanged) and
          // shows up as its own chip to the left, rather than the dropdown
          // itself holding a selection — so it always resets back to
          // showing the `hint` text instead of the item just picked.
          BoxedDropdown<String?>(
            value: null,
            // 160 — standardized 2026-08-27 to match every dimension
            // switcher/selector box in the app: Craig, "check the sizing
            // and consistency of all of the filter boxes across the
            // application."
            width: 160,
            hint: const Text('Add filter'),
            items: [
              // This client's own dimensions again (see `filterableDimensions`
              // above) — "Company" isn't something you can narrow everything
              // down to (it already means "no narrowing at all"), so it's
              // deliberately excluded via `drivesCrossFilter` the same way
              // `SalesDimension.filterable` always excluded it.
              for (final dimension in filterableDimensions)
                DropdownMenuItem<String?>(value: dimension.dimensionKey, child: Text(dimension.displayLabel)),
              const DropdownMenuItem<String?>(value: '_year', child: Text('Year')),
              const DropdownMenuItem<String?>(value: '_month', child: Text('Month')),
              // 2026-08-27, Craig: "We need to add Document to the Filters
              // dropdown" — see _pickDocument below.
              const DropdownMenuItem<String?>(value: '_document', child: Text('Document')),
            ],
            onChanged: (key) {
              if (key != null) _handleAdd(context, ref, notifier, filters, key, filterableDimensions);
            },
          ),
          // 2026-09-04, Craig: "Saved filter presets" — save/reapply the 5
          // dimension filters by name (Decisions doc Section 79). A plain
          // icon+label button here, not another BoxedDropdown — this opens a
          // dialog rather than picking a value inline, so it isn't really a
          // "dropdown" the way Add filter/Year/Month are.
          TextButton.icon(
            style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8), minimumSize: const Size(0, 32)),
            onPressed: () => showDialog<void>(context: context, builder: (_) => _PresetsDialog(filters: filters, notifier: notifier)),
            icon: const Icon(Icons.bookmark_outline, size: 16),
            label: const Text('Presets'),
          ),
          if (filters.activeCount > 0)
            TextButton(
              style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 32)),
              onPressed: notifier.clearAll,
              child: const Text('Clear all'),
            ),
        ],
      ),
    );
  }

  Future<void> _handleAdd(
    BuildContext context,
    WidgetRef ref,
    GlobalFiltersNotifier notifier,
    GlobalFilters filters,
    String key,
    List<ClientDimensionConfig> filterableDimensions,
  ) async {
    // .valueOrNull ?? 3 — fiscalYearStartMonthProvider's own fallback while
    // it's still loading, matching fiscal.dart's pre-feature default exactly
    // (see fiscalMonthOrderFor's doc comment).
    final startMonth = ref.read(fiscalYearStartMonthProvider).valueOrNull ?? 3;
    // null (still loading, or the query hasn't resolved yet) means "don't
    // grey anything" — see _pickFromList's isEnabled param — rather than
    // blocking the picker on a check that hasn't finished.
    final availability = ref.read(fiscalYearDataAvailabilityProvider).valueOrNull;
    if (key == '_year') {
      final currentFy = fiscalYearFor(DateTime.now(), startMonth: startMonth);
      final historyYears = ref.read(fiscalYearHistoryYearsProvider).valueOrNull ?? 3;
      final year = await _pickFromList<int>(
        context,
        title: 'Year',
        // Newest first for this dropdown, unlike fiscalYearWindow's own
        // oldest-first convention — matches how this list has always
        // presented (current year at the top).
        options: fiscalYearWindow(currentFy, historyYears).reversed.toList(),
        labelOf: (y) => 'FY$y',
        // 2026-09-01, Craig: "there is no data for 2023 and 2024" — grey out
        // and disable any year in the window with zero rows on record (see
        // fiscalYearDataAvailabilityProvider's doc comment).
        isEnabled: availability == null ? null : (y) => availability.yearsWithData.contains(y),
      );
      if (year != null) notifier.setFiscalYear(year);
      return;
    }
    if (key == '_month') {
      // 2026-09-01, Craig: "2027 has no data for Sept forward therefore
      // these should be greyed out" — grey out any calendar month with no
      // rows on record for the RELEVANT scope. With a Year filter active,
      // "relevant" means that year specifically (Year 2027 + September ->
      // checked against FY2027 alone, correctly greyed; Year 2025 +
      // September -> checked against FY2025 alone). With NO Year filter
      // active, Craig: "If I only select September then it must not be
      // greyed out and it must filter on and show data for all of the past
      // septembers" — i.e. a bare month applies across every fiscal year in
      // the window (matching how the Month filter actually behaves
      // everywhere else — see class doc comment above), so it's only grey
      // when NOT ONE year in the whole window has that month's data.
      //
      // (This replaces two earlier, both wrong, attempts: checking only the
      // current fiscal year unconditionally left September greyed even with
      // Year 2025 selected; falling back to "current fiscal year only" when
      // no Year was selected still greyed a plain "September" pick even
      // though older years had real data for it. See
      // fiscalYearDataAvailabilityProvider's doc comment for the full
      // history.)
      final referenceYear = filters.fiscalYear;
      final monthsWithData = availability == null
          ? null
          : referenceYear != null
              ? (availability.monthsWithDataByYear[referenceYear] ?? const <String>{})
              : availability.monthsWithDataByYear.values.expand((months) => months).toSet();
      final month = await _pickFromList<String>(
        context,
        title: 'Month',
        options: fiscalMonthOrderFor(startMonth: startMonth),
        isEnabled: monthsWithData == null ? null : (m) => monthsWithData.contains(m),
      );
      if (month != null) notifier.setFiscalMonth(month);
      return;
    }
    if (key == '_document') {
      final document = await _pickDocument(context);
      if (document != null) notifier.setDocument(document.isEmpty ? null : document);
      return;
    }
    final dimensionConfig = filterableDimensions.firstWhere((d) => d.dimensionKey == key);
    // `asSalesDimension` is null for a 'fact_column'/'customer_attribute'
    // dimension — Step 2 deliberately doesn't teach the entity picker
    // (`_pickEntity` below, and `entitiesFor`/`searchAllDimensions` it
    // depends on) how to search anything beyond the 6 'existing' dimensions
    // yet, since that's real RPC/reference-data generalization work the
    // design doc's own sequencing plan defers to Step 3. WCSA never reaches
    // this branch — every one of its rows is 'existing' — so this is a
    // silent no-op rather than a crash for the first client that DOES add a
    // generic dimension, until Step 3 teaches this how to pick one.
    final dimension = dimensionConfig.asSalesDimension;
    if (dimension == null) return;
    final selection = await _pickEntity(context, dimension);
    if (selection != null) notifier.setDimension(dimensionConfig.dimensionKey, selection);
  }
}

/// `isEnabled` (2026-09-01, Craig: "apply the no data rule shaded grey") —
/// when provided, an option it returns false for is shown greyed out and
/// can't be tapped, but stays in the list rather than being hidden, so it's
/// still obvious that period exists and simply has no data yet. Leave null
/// (the dimension-entity and Document pickers don't use this) to enable
/// every option, same as before this param existed.
Future<T?> _pickFromList<T>(
  BuildContext context, {
  required String title,
  required List<T> options,
  String Function(T)? labelOf,
  bool Function(T)? isEnabled,
}) {
  return showDialog<T>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text(title),
      children: [
        for (final option in options)
          SimpleDialogOption(
            onPressed: (isEnabled == null || isEnabled(option)) ? () => Navigator.of(context).pop(option) : null,
            child: Text(
              labelOf == null ? option.toString() : labelOf(option),
              style: (isEnabled == null || isEnabled(option)) ? null : TextStyle(color: Theme.of(context).disabledColor),
            ),
          ),
      ],
    ),
  );
}

/// 2026-08-26: routed through the shared, server-backed search dialog
/// (entity_search_field.dart) instead of this file's own client-side-filter
/// picker — see that widget's doc comment for why a locally-filtered,
/// pre-loaded list silently couldn't reach past the first 200 customers or
/// items (Craig: "Elastic search on filters"). An empty-code result means
/// "All" was picked, which has no meaning for "add a new filter" (there's
/// nothing to clear yet), so it's treated the same as a cancelled dialog.
Future<FilterSelection?> _pickEntity(BuildContext context, SalesDimension dimension) async {
  final picked = await showEntitySearchDialog(context, dimension: dimension, title: 'Filter by ${dimension.label}');
  if (picked == null || picked.code.isEmpty) return null;
  return FilterSelection(picked.code, picked.displayLabel);
}

/// Same debounced, server-backed search pattern as `showEntitySearchDialog`
/// (entity_search_field.dart) — 2026-08-27, Craig: "We need to add Document
/// to the Filters dropdown." Kept local to this file rather than folded into
/// that shared dialog: it searches `ReferenceDataRepository.searchDocuments`
/// (document numbers) instead of `entitiesFor` (dimension entities), and
/// returns a plain `String` rather than a `CodeName`, so the two don't
/// actually share a return type to unify around. Unlike that dialog, there's
/// no "browse everything" default list to show before typing —
/// `searchDocuments` itself returns nothing for an empty query (see its own
/// doc comment), so this shows a prompt instead of an empty list on open.
/// Returns null if cancelled, or '' for the explicit "All" (clear) option —
/// callers should treat an empty result as "clear the filter."
Future<String?> _pickDocument(BuildContext context) {
  return showDialog<String>(context: context, builder: (context) => const _DocumentSearchDialog());
}

class _DocumentSearchDialog extends ConsumerStatefulWidget {
  const _DocumentSearchDialog();

  @override
  ConsumerState<_DocumentSearchDialog> createState() => _DocumentSearchDialogState();
}

class _DocumentSearchDialogState extends ConsumerState<_DocumentSearchDialog> {
  final _controller = TextEditingController();
  Timer? _debounce;
  List<DocumentSearchResult> _results = [];
  bool _loading = false;
  bool _searched = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      setState(() {
        _results = [];
        _loading = false;
        _searched = false;
      });
      return;
    }
    setState(() => _loading = true);
    _debounce = Timer(const Duration(milliseconds: 300), () => _search(trimmed));
  }

  Future<void> _search(String value) async {
    final results = await ref.read(referenceDataRepositoryProvider).searchDocuments(value);
    if (!mounted) return;
    setState(() {
      _results = results;
      _loading = false;
      _searched = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Filter by Document'),
      content: SizedBox(
        width: 360,
        height: 360,
        child: Column(
          children: [
            TextField(
              controller: _controller,
              autofocus: true,
              decoration: const InputDecoration(isDense: true, prefixIcon: Icon(Icons.search), hintText: 'Doc number…'),
              onChanged: _onChanged,
            ),
            const SizedBox(height: 4),
            ListTile(
              dense: true,
              title: const Text('All'),
              onTap: () => Navigator.of(context).pop(''),
            ),
            const Divider(height: 1),
            Expanded(
              child: _loading
                  ? const Center(child: RepaintBoundary(child: CircularProgressIndicator()))
                  : !_searched
                      ? const Center(child: Padding(padding: EdgeInsets.all(16), child: Text('Type a document number to search.')))
                      : _results.isEmpty
                          ? const Center(child: Text('No matches.'))
                          : ListView.builder(
                              itemCount: _results.length,
                              itemBuilder: (context, index) {
                                final r = _results[index];
                                return ListTile(
                                  dense: true,
                                  title: Text(r.document, overflow: TextOverflow.ellipsis),
                                  trailing: Text(r.documentKind, style: Theme.of(context).textTheme.bodySmall),
                                  onTap: () => Navigator.of(context).pop(r.document),
                                );
                              },
                            ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
      ],
    );
  }
}

/// "Presets" button's dialog — save the current 5 dimension filters under a
/// name, or reapply/delete one already saved (schema/035, filter_presets
/// repository/provider, app_providers.dart). `filters`/`notifier` are passed
/// in rather than watched here: this is a plain (non-Consumer) dialog over a
/// snapshot of the filter bar's own already-current values, which can't
/// change out from under it while the modal dialog is open anyway.
class _PresetsDialog extends ConsumerStatefulWidget {
  const _PresetsDialog({required this.filters, required this.notifier});

  final GlobalFilters filters;
  final GlobalFiltersNotifier notifier;

  @override
  ConsumerState<_PresetsDialog> createState() => _PresetsDialogState();
}

class _PresetsDialogState extends ConsumerState<_PresetsDialog> {
  final _nameController = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  /// Craig's own scope for what a preset captures ("Just the 5 dimension
  /// filters") means a preset with none of them set would save nothing
  /// meaningful — the name field + Save button are hidden in favor of an
  /// explanatory line instead, rather than letting Craig save an empty
  /// preset and wonder later why applying it didn't do anything.
  bool get _hasDimensionFilter => widget.filters.hasAnyDimensionSelected;

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    setState(() => _saving = true);
    try {
      await ref.read(filterPresetRepositoryProvider).save(name, widget.filters);
      ref.invalidate(filterPresetsProvider);
      _nameController.clear();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Loops over every filterable dimension, not just the ones this preset
  /// has — see FilterPreset.forDimension's own doc comment for why that's
  /// what makes this a wholesale replace of the current 5 dimension filters
  /// rather than a merge. Year/Month/Document are never touched.
  void _apply(FilterPreset preset) {
    for (final dimension in SalesDimension.filterable) {
      widget.notifier.setDimension(dimension.dbValue, preset.forDimension(dimension));
    }
    Navigator.of(context).pop();
  }

  Future<void> _delete(FilterPreset preset) async {
    // Same confirm-dialog shape as Settings > Users' own delete-user
    // confirmation (settings_screen.dart's _confirmDelete) — Cancel/Delete,
    // Delete styled negative-red, "this cannot be undone."
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('Delete preset', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        content: Text('Delete the "${preset.name}" preset? This cannot be undone.', style: const TextStyle(fontSize: 13)),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete', style: TextStyle(color: AppColors.negative, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref.read(filterPresetRepositoryProvider).delete(preset.id);
      ref.invalidate(filterPresetsProvider);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final presetsAsync = ref.watch(filterPresetsProvider);
    return AlertDialog(
      title: const Text('Saved filter presets'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!_hasDimensionFilter)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  'Select a Sales Person, Category, Customer, Item, or Branch filter above, then come back here to save it as a preset.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _nameController,
                        autofocus: true,
                        decoration: const InputDecoration(isDense: true, hintText: 'Preset name'),
                        onSubmitted: (_) => _save(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _saving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: RepaintBoundary(child: CircularProgressIndicator(strokeWidth: 2)),
                          )
                        : TextButton(onPressed: _save, child: const Text('Save')),
                  ],
                ),
              ),
            const Divider(height: 1),
            SizedBox(
              height: 240,
              child: presetsAsync.when(
                data: (presets) => presets.isEmpty
                    ? const Center(child: Padding(padding: EdgeInsets.all(16), child: Text('No saved presets yet.')))
                    : ListView.builder(
                        itemCount: presets.length,
                        itemBuilder: (context, index) {
                          final preset = presets[index];
                          return ListTile(
                            dense: true,
                            title: Text(preset.name, overflow: TextOverflow.ellipsis),
                            onTap: () => _apply(preset),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete_outline, size: 18),
                              tooltip: 'Delete preset',
                              onPressed: () => _delete(preset),
                            ),
                          );
                        },
                      ),
                loading: () => const Center(child: RepaintBoundary(child: CircularProgressIndicator())),
                error: (e, _) => Center(child: Text('Error: $e')),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
      ],
    );
  }
}

class _RemovableChip extends StatelessWidget {
  const _RemovableChip({required this.label, required this.onDeleted});

  final String label;
  final VoidCallback onDeleted;

  @override
  Widget build(BuildContext context) {
    return Chip(
      label: Text(label, style: const TextStyle(fontSize: 12)),
      onDeleted: onDeleted,
      deleteIconColor: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      backgroundColor: AppColors.teal.withValues(alpha: 0.14),
      side: BorderSide.none,
    );
  }
}
