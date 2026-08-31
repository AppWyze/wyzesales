import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/app_providers.dart';
import '../../core/constants/fiscal.dart';
import '../../core/filters/global_filters.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/reference_data.dart';

/// Top-bar "jump to a customer/item/rep/category/branch/document" search —
/// ported from SeaWyze's own GlobalSearchBar (same Expanded-in-the-top-bar
/// slot, same typeahead-dropdown-via-Overlay shape: a LayerLink +
/// OverlayEntry with a full-screen dismiss layer behind a
/// CompositedTransformFollower dropdown), pointed at WyzeSales' own
/// reference data instead of SeaWyze's vessels/tasks/permits, which have no
/// equivalent here.
///
/// Craig, 2026-08-26: "search on the dimensions and then display the
/// context for the user to choose" — each result shows which dimension
/// it's from (e.g. "Acme Corp — Customer") so a name that happens to match
/// more than one dimension isn't ambiguous.
///
/// 2026-08-27 (follow-up): picking a dimension result now sets that
/// dimension's actual global filter (`globalFiltersProvider`) instead of
/// navigating to a "pinned to the top" Sales By view — Craig: "Can we treat
/// this the same way as the filters. I.e. If I do a global search on Sarah,
/// it show me sales person Sarah. If I then select her it should then
/// filter all of the data and only show me data for sales person Sarah.
/// Exactly the same way as if I filtered on Sales Person Sarah. This will
/// then also populate the filters applied on the top." That's a call to the
/// exact same `notifier.setDimension(...)` the "Add filter" picker in
/// global_filter_bar.dart already uses — picking a search result IS now
/// indistinguishable from picking that same entity there: it shows up as
/// the same chip, filters the same screens, and stays applied while
/// navigating, same as every other global filter. No navigation happens on
/// purpose — setting a filter from the "Add filter" dropdown doesn't jump
/// anywhere either, it just re-filters whatever screen you're already on,
/// so this matches that exactly rather than forcing a trip to Sales By. The
/// old highlight/pin mechanism (SalesByScreen.highlightCode) stays in place
/// for the Dashboard's pie-chart drill-down, which is a different feature
/// (Craig separately asked for that one to pre-sort Sales By to match
/// whatever Top 5/Bottom 5/etc chart was clicked) — this change only
/// affects what selecting a top-bar search result does.
///
/// 2026-08-26: also searches document numbers (Craig: "Include Document in
/// Top Bar search"). 2026-08-27 (follow-up): Document was promoted to a real
/// global filter (`GlobalFilters.document`, see global_filters.dart) — Craig:
/// "We need to add Document to the Filters dropdown." Picking a document
/// result now sets that filter directly (same call GlobalFilterBar's own
/// Document picker makes) AND still navigates to the matching analysis
/// screen, since unlike the 5 dimensions a document number only means
/// anything on Sales/Quote/Sales Order Analysis — the global filter alone
/// wouldn't land you there.
class TopBarSearch extends ConsumerStatefulWidget {
  const TopBarSearch({super.key});

  @override
  ConsumerState<TopBarSearch> createState() => _TopBarSearchState();
}

/// One row in the results dropdown, built fresh by `_runSearch` from
/// whichever of the 5 dimensions or the Document search actually matched.
/// Exactly one of (dimension, entity) or (document, route) is set: a
/// dimension match applies a global filter directly (see _selectResult); a
/// document match sets the global Document filter (2026-08-27, Craig: "We
/// need to add Document to the Filters dropdown") AND navigates, since
/// unlike the 5 dimensions, a document number only means anything on
/// Sales/Quote/Sales Order Analysis — landing on the right one of those
/// three is still worth doing, the global filter alone wouldn't get you
/// there.
class _TopBarResult {
  final String title;
  final String tag;
  final SalesDimension? dimension;
  final CodeName? entity;
  final String? document;
  final String? route;
  const _TopBarResult({required this.title, required this.tag, this.dimension, this.entity, this.document, this.route});
}

class _TopBarSearchState extends ConsumerState<TopBarSearch> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  final _layerLink = LayerLink();
  OverlayEntry? _overlayEntry;
  Timer? _debounce;
  List<_TopBarResult> _results = [];
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_onFocusChange);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _focusNode.removeListener(_onFocusChange);
    _controller.dispose();
    _focusNode.dispose();
    _removeOverlay();
    super.dispose();
  }

  void _onFocusChange() {
    if (_focusNode.hasFocus) {
      _updateOverlay();
      return;
    }
    // Short delay, not an immediate removal — a tap on a result also blurs
    // the field (unfocus happens before the ListTile's onTap fires), so
    // removing the overlay synchronously here would tear it down out from
    // under the very tap that's meant to use it.
    Future.delayed(const Duration(milliseconds: 150), _removeOverlay);
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    setState(() {}); // refreshes the clear (x) button's visibility
    if (value.trim().isEmpty) {
      setState(() {
        _results = [];
        _loading = false;
      });
      _updateOverlay();
      return;
    }
    setState(() => _loading = true);
    _updateOverlay();
    _debounce = Timer(const Duration(milliseconds: 300), () => _runSearch(value));
  }

  /// invoice/credit_note both land on Sales Analysis (its Table tab, which
  /// is the default tab now anyway) — the two document kinds Sales
  /// Analysis' DocumentAnalysisView is scoped to.
  String _routeForDocumentKind(String documentKind) {
    switch (documentKind) {
      case 'quote':
        return '/quote-analysis';
      case 'sales_order':
        return '/sales-order-analysis';
      default:
        return '/sales-analysis';
    }
  }

  Future<void> _runSearch(String value) async {
    final refRepo = ref.read(referenceDataRepositoryProvider);
    final fetched = await Future.wait([refRepo.searchAllDimensions(value), refRepo.searchDocuments(value)]);
    if (!mounted) return;
    final dimensionResults = fetched[0] as List<DimensionSearchResult>;
    final documentResults = fetched[1] as List<DocumentSearchResult>;
    setState(() {
      _results = [
        for (final r in dimensionResults)
          _TopBarResult(title: r.entity.displayLabel, tag: r.dimension.label, dimension: r.dimension, entity: r.entity),
        for (final r in documentResults)
          _TopBarResult(title: r.document, tag: 'Document', document: r.document, route: _routeForDocumentKind(r.documentKind)),
      ];
      _loading = false;
    });
    _updateOverlay();
  }

  void _updateOverlay() {
    _removeOverlay();
    if (!_focusNode.hasFocus || _controller.text.trim().isEmpty) return;
    _overlayEntry = OverlayEntry(
      builder: (context) => _SearchResultsDropdown(
        layerLink: _layerLink,
        loading: _loading,
        results: _results,
        onSelect: _selectResult,
        onDismiss: () => _focusNode.unfocus(),
      ),
    );
    Overlay.of(context).insert(_overlayEntry!);
  }

  void _removeOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  void _selectResult(_TopBarResult result) {
    _controller.clear();
    _results = [];
    _removeOverlay();
    _focusNode.unfocus();
    final dimension = result.dimension;
    final entity = result.entity;
    if (dimension != null && entity != null) {
      // Sets the real global filter — see this class's doc comment. No
      // navigation: exactly like picking the same entity from
      // GlobalFilterBar's "Add filter" dropdown, this just re-filters
      // whatever screen the user is already on.
      ref.read(globalFiltersProvider.notifier).setDimension(dimension, FilterSelection(entity.code, entity.displayLabel));
      setState(() {}); // clears the search field's own visible text immediately
      return;
    }
    final document = result.document;
    if (document != null) {
      // Sets the global Document filter (same "Add filter" call
      // global_filter_bar.dart's own Document picker makes) and navigates
      // to the matching screen — see _TopBarResult's doc comment for why
      // this one still navigates unlike a dimension result.
      ref.read(globalFiltersProvider.notifier).setDocument(document);
    }
    if (result.route != null) context.go(result.route!);
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _layerLink,
      child: SizedBox(
        height: 36,
        child: TextField(
          controller: _controller,
          focusNode: _focusNode,
          onChanged: _onChanged,
          style: const TextStyle(fontSize: 13),
          decoration: InputDecoration(
            isDense: true,
            hintText: 'Search customers, items, reps, categories, branches, documents…',
            hintStyle: const TextStyle(fontSize: 13),
            prefixIcon: const Icon(Icons.search, size: 18),
            prefixIconConstraints: const BoxConstraints(minWidth: 36),
            suffixIcon: _controller.text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.close, size: 16),
                    onPressed: () {
                      _controller.clear();
                      _onChanged('');
                    },
                  ),
            contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          ),
        ),
      ),
    );
  }
}

class _SearchResultsDropdown extends StatelessWidget {
  const _SearchResultsDropdown({
    required this.layerLink,
    required this.loading,
    required this.results,
    required this.onSelect,
    required this.onDismiss,
  });

  final LayerLink layerLink;
  final bool loading;
  final List<_TopBarResult> results;
  final ValueChanged<_TopBarResult> onSelect;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Full-screen dismiss layer, behind the dropdown — tapping anywhere
        // outside the results closes them.
        Positioned.fill(
          child: GestureDetector(
            onTap: onDismiss,
            behavior: HitTestBehavior.translucent,
            child: const SizedBox.expand(),
          ),
        ),
        CompositedTransformFollower(
          link: layerLink,
          showWhenUnlinked: false,
          offset: const Offset(0, 40),
          child: Align(
            alignment: Alignment.topLeft,
            child: Material(
              elevation: 8,
              borderRadius: BorderRadius.circular(8),
              child: Container(
                width: 420,
                constraints: const BoxConstraints(maxHeight: 340),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.12)),
                ),
                child: _buildContent(context),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildContent(BuildContext context) {
    if (loading) {
      return const Padding(
        padding: EdgeInsets.all(20),
        child: Center(child: SizedBox(width: 20, height: 20, child: RepaintBoundary(child: CircularProgressIndicator(strokeWidth: 2)))),
      );
    }
    if (results.isEmpty) {
      return const Padding(padding: EdgeInsets.all(16), child: Text('No matches.'));
    }
    return ListView.separated(
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: results.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final r = results[index];
        return ListTile(
          dense: true,
          title: Text(r.title, overflow: TextOverflow.ellipsis),
          trailing: Text(
            r.tag,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.teal),
          ),
          onTap: () => onSelect(r),
        );
      },
    );
  }
}
