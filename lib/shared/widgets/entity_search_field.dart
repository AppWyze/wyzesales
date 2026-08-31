import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/app_providers.dart';
import '../../core/constants/fiscal.dart';
import '../../data/models/reference_data.dart';

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
Future<CodeName?> showEntitySearchDialog(BuildContext context, {required SalesDimension dimension, required String title}) {
  return showDialog<CodeName>(
    context: context,
    builder: (context) => _EntitySearchDialog(dimension: dimension, title: title),
  );
}

class _EntitySearchDialog extends ConsumerStatefulWidget {
  const _EntitySearchDialog({required this.dimension, required this.title});

  final SalesDimension dimension;
  final String title;

  @override
  ConsumerState<_EntitySearchDialog> createState() => _EntitySearchDialogState();
}

class _EntitySearchDialogState extends ConsumerState<_EntitySearchDialog> {
  final _controller = TextEditingController();
  Timer? _debounce;
  List<CodeName> _results = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _search(''); // initial browse list — same "first N, unfiltered" default the old dropdowns opened to.
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
    final results = await ref.read(referenceDataRepositoryProvider).entitiesFor(widget.dimension, search: trimmed.isEmpty ? null : trimmed);
    if (!mounted) return;
    setState(() {
      _results = results;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 360,
        height: 420,
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
                            return ListTile(
                              dense: true,
                              title: Text(entity.displayLabel, overflow: TextOverflow.ellipsis),
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
