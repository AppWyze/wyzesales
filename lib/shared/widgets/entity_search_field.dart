import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/app_providers.dart';
import '../../core/filters/global_filters.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/client_dimension_config.dart';
import '../../data/models/reference_data.dart';
import '../utils/responsive.dart';

/// Real, server-backed search dialog for picking one Category/Item/Sales
/// Person/Branch/Customer — Craig, 2026-08-26: "Elastic search on filters."
///
/// Why this exists rather than a plain dropdown: ReferenceDataRepository
/// already supports a `search` parameter on every entity lookup
/// (customers()/items()/etc.), but customers and items are capped at 200
/// rows when that parameter is left off. The dropdowns this replaced loaded
/// that capped list ONCE with no search term and then filtered it
/// client-side as the user typed — which meant anything past the first 200
/// customers/items (alphabetically) was never reachable at all, no matter
/// what was typed. This dialog instead re-queries the repository's `search`
/// parameter on every keystroke (debounced 300ms, the same pattern
/// TopBarSearch already uses), so what's actually being searched is always
/// the full table, not a local copy that silently stopped at 200 rows.
///
/// 2026-08-27: the boxed `EntitySearchField` widget that used to open this
/// dialog from an inline per-screen filter row (Sales Analysis/Quote
/// Analysis/Sales Order Analysis' old `FilterBar`) was removed — Craig:
/// "check the sizing and consistency of all of the filter boxes... some of
/// them are... double labelled." Category/Item/Sales Person/Branch/Customer
/// were shown TWICE on those three screens: once in that inline row, and
/// again as chips in the app-wide `GlobalFilterBar` (mounted by AppShell on
/// every screen), since both read/wrote the exact same
/// `globalFiltersProvider` state. Unlike the Year/Month boxes those screens
/// also had (which surface a real default — "today's fiscal year" — that
/// GlobalFilterBar's chip-only display can't show until a value is
/// explicitly set), these five had no such default: unset means "All" on
/// both, so the inline copy added a second editable control for the same
/// value with zero new information. This dialog function is now called
/// directly by `global_filter_bar.dart`'s "Add filter" picker only — the
/// single remaining place any of the 5 dimension filters get set.
///
/// 2026-09-01: rows with no matching sales data under whichever OTHER
/// global filters are already active now render greyed out with a "No
/// data" tag — Craig: "If I filter on an Item and then I look up Customer
/// in the Customer Filter, I should only be able to select a customer who
/// has purchased that item... greyed out." Deliberately not blocked from
/// selection (Craig, same conversation: still selectable) — greying is a
/// hint, not a hard rule, since sometimes a user knows data is coming or
/// wants to confirm a combination is genuinely empty. Deliberately NOT
/// applied to TopBarSearch (searchAllDimensions) — this dialog is the only
/// place that behaviour was asked for. See schema/017's own doc comment for
/// the database side of this (`fn_dimension_filter_options`) and
/// ReferenceDataRepository.filterOptionCodes for how it's called.
///
/// 2026-09-06 (multi-tenant dimension model Step 4/5): generalized from a
/// `SalesDimension` parameter to a full `ClientDimensionConfig` so this
/// dialog can search a brand-new client's own 'fact_column'/
/// 'customer_attribute' dimension (backed by `client_dimension_values`,
/// via `entitiesForConfig`), not just the 6 'existing' dimensions built
/// into `SalesDimension`. An 'existing' dimension still routes through the
/// exact same `entitiesFor` call as before (`entitiesForConfig`'s own doc
/// comment) — WCSA's own 6 dimensions are byte-for-byte unchanged. The
/// "no data" greying feature above stays scoped to 'existing' dimensions
/// only (see `_loadMatchingCodes` below) — `fn_dimension_filter_options`
/// itself hasn't been generalized to a generic dimension_key yet, and
/// that's real RPC work the design doc's own sequencing plan hasn't asked
/// for here; a generic dimension simply never greys anything, which is
/// already a legitimate state this dialog supports (see `_matchingCodes`'
/// own doc comment).
Future<CodeName?> showEntitySearchDialog(BuildContext context, {required ClientDimensionConfig dimension, required String title}) {
  return showDialog<CodeName>(
    context: context,
    builder: (context) => _EntitySearchDialog(dimension: dimension, title: title),
  );
}

class _EntitySearchDialog extends ConsumerStatefulWidget {
  const _EntitySearchDialog({required this.dimension, required this.title});

  final ClientDimensionConfig dimension;
  final String title;

  @override
  ConsumerState<_EntitySearchDialog> createState() => _EntitySearchDialogState();
}

class _EntitySearchDialogState extends ConsumerState<_EntitySearchDialog> {
  final _controller = TextEditingController();
  Timer? _debounce;
  List<CodeName> _results = [];
  bool _loading = true;

  /// Codes with at least one matching row under every OTHER active global
  /// filter — schema/017, Craig 2026-09-01: "If I filter on an Item... I
  /// should only be able to select a customer who has purchased that item...
  /// greyed out." Null means "don't grey anything" — either no other filter
  /// is active, or this dialog's own dimension has no such thing as "other"
  /// filters to check against (there always is one, since a dimension is
  /// never checked against its own current value — see
  /// ReferenceDataRepository.filterOptionCodes' own doc comment). Fetched
  /// once per dialog open, in parallel with the initial browse list, since
  /// the global filters can't change while this modal is the only thing on
  /// screen.
  Set<String>? _matchingCodes;

  @override
  void initState() {
    super.initState();
    _search(''); // initial browse list — same "first N, unfiltered" default the old dropdowns opened to.
    _loadMatchingCodes();
  }

  Future<void> _loadMatchingCodes() async {
    // `filterOptionCodes` (fn_dimension_filter_options) is still
    // `SalesDimension`-only — see this dialog's own doc comment above — so a
    // brand-new 'fact_column'/'customer_attribute' dimension (asSalesDimension
    // == null) just leaves `_matchingCodes` null, i.e. "don't grey anything,"
    // rather than calling an RPC that doesn't know about it.
    final existing = widget.dimension.asSalesDimension;
    if (existing == null) return;
    final filters = ref.read(globalFiltersProvider);
    final codes = await ref.read(referenceDataRepositoryProvider).filterOptionCodes(existing, filters);
    if (!mounted || codes == null) return;
    setState(() => _matchingCodes = codes);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => _search(value));
  }

  Future<void> _search(String value) async {
    setState(() => _loading = true);
    final trimmed = value.trim();
    final results =
        await ref.read(referenceDataRepositoryProvider).entitiesForConfig(widget.dimension, search: trimmed.isEmpty ? null : trimmed);
    if (!mounted) return;
    setState(() {
      _results = results;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      // 2026-09-07 (Craig: "optimised for Mobile, Tablet and Desktop") — this
      // dialog is opened by every "Add filter" entity pick in GlobalFilterBar
      // (one of the most-used dialogs in the app), and its content used to be
      // a flat SizedBox(width: 360, height: 420) with no awareness of the
      // viewport at all. `dialogInsetPadding`/`dialogMaxWidth`/
      // `dialogMaxHeight` (responsive.dart) are the same helpers
      // platform_admin_screen.dart's and settings_screen.dart's own dialogs
      // already use for exactly this — clamping to what's actually on
      // screen, accounting for the keyboard when it's open, rather than
      // assuming a desktop-sized viewport.
      insetPadding: dialogInsetPadding,
      title: Text(widget.title),
      content: SizedBox(
        width: dialogMaxWidth(context, 360),
        height: dialogMaxHeight(context, 420),
        child: Column(
          children: [
            TextField(
              controller: _controller,
              autofocus: true,
              decoration: const InputDecoration(isDense: true, prefixIcon: Icon(Icons.search), hintText: 'Search…'),
              onChanged: _onChanged,
            ),
            const SizedBox(height: 4),
            ListTile(
              dense: true,
              title: const Text('All'),
              onTap: () => Navigator.of(context).pop(const CodeName(code: '')),
            ),
            const Divider(height: 1),
            Expanded(
              child: _loading
                  ? const Center(child: RepaintBoundary(child: CircularProgressIndicator()))
                  : _results.isEmpty
                      ? const Center(child: Text('No matches.'))
                      : ListView.builder(
                          itemCount: _results.length,
                          itemBuilder: (context, index) {
                            final entity = _results[index];
                            // Greyed, not removed/disabled — Craig, 2026-09-01:
                            // still selectable on tap either way (schema/017's
                            // own doc comment has the full reasoning: a hint,
                            // not a hard block).
                            final noData = _matchingCodes != null && !_matchingCodes!.contains(entity.code);
                            final mutedColor = Theme.of(context).disabledColor;
                            return ListTile(
                              dense: true,
                              title: Text(
                                entity.displayLabel,
                                overflow: TextOverflow.ellipsis,
                                style: noData ? TextStyle(color: mutedColor) : null,
                              ),
                              trailing: noData
                                  ? Text('No data', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: mutedColor))
                                  : null,
                              onTap: () => Navigator.of(context).pop(entity),
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

/// Multi-select variant of `showEntitySearchDialog` above — 2026-09-25,
/// Craig, Sales Analysis Chart tab's dimension-comparison feature: "we
/// should have a tick box next to each one and then we select as many as we
/// want and they will then chart." Same server-backed, debounced search as
/// the single-select dialog (`entitiesForConfig`), so it works for a
/// small dimension (Revenue Split's 2 entities) and a large one (Customer,
/// Item) exactly the same way — but ticking a row doesn't close the dialog;
/// selections accumulate in a running set, shown as removable chips above
/// the search box so a tick made under one search term stays visible (and
/// un-tickable) after typing a different one, until "Done" is pressed.
///
/// Deliberately NOT the same dialog with a `multiSelect` flag bolted on —
/// this one has no "All" row (a multi-select returning an empty list already
/// means "nothing to compare" to its caller, unlike the single-select
/// dialog's "All" meaning "clear this global filter") and no "no data under
/// other active filters" greying (that feature reads `globalFiltersProvider`
/// directly, which has nothing to do with a chart-local comparison set —
/// see this dialog's caller for how it scopes the actual data fetch
/// instead). Keeping the two dialogs separate keeps both of their doc
/// comments honest about what they actually do.
Future<List<CodeName>?> showEntityMultiSelectDialog(
  BuildContext context, {
  required ClientDimensionConfig dimension,
  required String title,
  List<CodeName> initiallySelected = const [],
}) {
  return showDialog<List<CodeName>>(
    context: context,
    builder: (context) => _EntityMultiSelectDialog(dimension: dimension, title: title, initiallySelected: initiallySelected),
  );
}

class _EntityMultiSelectDialog extends ConsumerStatefulWidget {
  const _EntityMultiSelectDialog({required this.dimension, required this.title, required this.initiallySelected});

  final ClientDimensionConfig dimension;
  final String title;
  final List<CodeName> initiallySelected;

  @override
  ConsumerState<_EntityMultiSelectDialog> createState() => _EntityMultiSelectDialogState();
}

class _EntityMultiSelectDialogState extends ConsumerState<_EntityMultiSelectDialog> {
  final _controller = TextEditingController();
  Timer? _debounce;
  List<CodeName> _results = [];
  bool _loading = true;

  // Keyed by code, not a plain List — re-ticking the same entity under a
  // different search term must not duplicate it, and a prior tick has to
  // survive even once that entity scrolls out of the CURRENT search's
  // results (the chips row below reads straight off this map's values, not
  // off `_results`, which is why a selection stays visible after the search
  // term changes).
  late final Map<String, CodeName> _selected = {for (final e in widget.initiallySelected) e.code: e};

  @override
  void initState() {
    super.initState();
    _search(''); // initial browse list — same "first N, unfiltered" default the single-select dialog opens to.
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => _search(value));
  }

  Future<void> _search(String value) async {
    setState(() => _loading = true);
    final trimmed = value.trim();
    final results =
        await ref.read(referenceDataRepositoryProvider).entitiesForConfig(widget.dimension, search: trimmed.isEmpty ? null : trimmed);
    if (!mounted) return;
    setState(() {
      _results = results;
      _loading = false;
    });
  }

  void _toggle(CodeName entity, bool? ticked) {
    setState(() {
      if (ticked == true) {
        _selected[entity.code] = entity;
      } else {
        _selected.remove(entity.code);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      insetPadding: dialogInsetPadding,
      title: Text(widget.title),
      content: SizedBox(
        width: dialogMaxWidth(context, 360),
        height: dialogMaxHeight(context, 480),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _controller,
              autofocus: true,
              decoration: const InputDecoration(isDense: true, prefixIcon: Icon(Icons.search), hintText: 'Search…'),
              onChanged: _onChanged,
            ),
            if (_selected.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  // 2026-09-28, Craig: "The formatting of this looks default
                  // and untidy. Please can you polish this to align with the
                  // rest of the app." — this Chip was missing the
                  // teal-tinted, borderless treatment every OTHER removable
                  // chip in the app already gets (global_filter_bar.dart's
                  // `_RemovableChip`, and this same Compare feature's own
                  // dimension chip in sales_analysis_screen.dart), so it fell
                  // back to Material's plain grey/outlined default instead.
                  for (final entity in _selected.values)
                    Chip(
                      label: Text(entity.displayLabel, style: const TextStyle(fontSize: 12)),
                      onDeleted: () => _toggle(entity, false),
                      deleteIconColor: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      backgroundColor: AppColors.teal.withValues(alpha: 0.14),
                      side: BorderSide.none,
                    ),
                ],
              ),
            ],
            const SizedBox(height: 4),
            const Divider(height: 1),
            Expanded(
              child: _loading
                  ? const Center(child: RepaintBoundary(child: CircularProgressIndicator()))
                  : _results.isEmpty
                      ? const Center(child: Text('No matches.'))
                      : ListView.builder(
                          itemCount: _results.length,
                          itemBuilder: (context, index) {
                            final entity = _results[index];
                            return CheckboxListTile(
                              dense: true,
                              value: _selected.containsKey(entity.code),
                              onChanged: (ticked) => _toggle(entity, ticked),
                              controlAffinity: ListTileControlAffinity.leading,
                              title: Text(entity.displayLabel, overflow: TextOverflow.ellipsis),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_selected.values.toList()),
          child: Text('Done (${_selected.length})'),
        ),
      ],
    );
  }
}
