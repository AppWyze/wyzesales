import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/app_providers.dart';
import '../../core/constants/fiscal.dart';
import '../../core/filters/global_filters.dart';
import '../../core/theme/app_theme.dart';
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

    final chips = <Widget>[
      for (final dimension in SalesDimension.values)
        if (filters.forDimension(dimension) != null)
          _RemovableChip(
            label: '${dimension.label}: ${filters.forDimension(dimension)!.label}',
            onDeleted: () => notifier.clearDimension(dimension),
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
              for (final dimension in SalesDimension.values)
                DropdownMenuItem<String?>(value: dimension.dbValue, child: Text(dimension.label)),
              const DropdownMenuItem<String?>(value: '_year', child: Text('Year')),
              const DropdownMenuItem<String?>(value: '_month', child: Text('Month')),
              // 2026-08-27, Craig: "We need to add Document to the Filters
              // dropdown" — see _pickDocument below.
              const DropdownMenuItem<String?>(value: '_document', child: Text('Document')),
            ],
            onChanged: (key) {
              if (key != null) _handleAdd(context, ref, notifier, filters, key);
            },
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
  ) async {
    // .valueOrNull ?? 3 — fiscalYearStartMonthProvider's own fallback while
    // it's still loading, matching fiscal.dart's pre-feature default exactly
    // (see fiscalMonthOrderFor's doc comment).
    final startMonth = ref.read(fiscalYearStartMonthProvider).valueOrNull ?? 3;
    if (key == '_year') {
      final currentFy = fiscalYearFor(DateTime.now(), startMonth: startMonth);
      final year = await _pickFromList<int>(
        context,
        title: 'Year',
        options: [currentFy, currentFy - 1, currentFy - 2],
        labelOf: (y) => 'FY$y',
      );
      if (year != null) notifier.setFiscalYear(year);
      return;
    }
    if (key == '_month') {
      final month = await _pickFromList<String>(context, title: 'Month', options: fiscalMonthOrderFor(startMonth: startMonth));
      if (month != null) notifier.setFiscalMonth(month);
      return;
    }
    if (key == '_document') {
      final document = await _pickDocument(context);
      if (document != null) notifier.setDocument(document.isEmpty ? null : document);
      return;
    }
    final dimension = SalesDimension.values.firstWhere((d) => d.dbValue == key);
    final selection = await _pickEntity(context, dimension);
    if (selection != null) notifier.setDimension(dimension, selection);
  }
}

Future<T?> _pickFromList<T>(
  BuildContext context, {
  required String title,
  required List<T> options,
  String Function(T)? labelOf,
}) {
  return showDialog<T>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text(title),
      children: [
        for (final option in options)
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(option),
            child: Text(labelOf == null ? option.toString() : labelOf(option)),
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
