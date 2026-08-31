import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../core/app_providers.dart';
import '../../core/constants/fiscal.dart';
import '../../core/filters/global_filters.dart';
import '../../core/utils/formatters.dart';
import '../../data/models/sales_document.dart';
import 'async_section.dart';
import 'data_export_buttons.dart';
import 'responsive_data_table.dart';

/// Shared line-level detail view behind Sales Analysis' Table tab, Quote
/// Analysis, and Sales Order Analysis — same filter/column layout in the old
/// app for all three (Wyzesales_Screens_and_Recommendations.md Section 1),
/// differing only in which document_kind(s) they read.
///
/// "Sub Category" from the old screen spec isn't a separate column here —
/// confirmed in Wyzesales_Rollups_DesignNotes.md Section 3 that it was
/// always an identical copy of Category in the source data, never a real
/// second dimension.
///
/// This screen has no filter controls of its own any more — every filter
/// that applies here (Year, Month, Document, Category, Item, Sales Person,
/// Branch, Customer) is set and shown exclusively through the app-wide
/// `GlobalFilterBar` that AppShell mounts above every screen, including this
/// one. That wasn't always true:
///
/// - 2026-08-26, this screen's own Year/Month/Category/Item/Sales
///   Person/Branch/Customer dropdowns were switched from local State to
///   reading/writing `globalFiltersProvider` directly (Craig: "If I select a
///   sales person on any screen and I navigate to another screen that
///   filtered salesperson must stay filtered"), and a Document text field was
///   added as purely local State.
/// - 2026-08-27, the Category/Item/Sales Person/Branch/Customer boxes were
///   removed as pure duplicates of GlobalFilterBar's own chips/"Add filter"
///   picker, then (same day, follow-up) Year/Month/Document followed — see
///   `GlobalFilters.document`'s doc comment for that history.
/// - 2026-08-27 (same day, second follow-up): Craig, after seeing this
///   screen load 448 lines in one shot: "What happens when there 4000 lines?
///   What is considered the norm in apps like this?" The previous version
///   fetched up to 1000 rows in one go with no pagination and no indication
///   anything was ever cut off, then filtered/sorted whatever came back
///   entirely client-side. That's gone now: `SalesRepository.fetchSalesDocumentsPage`
///   fetches ONE page at a time (`_pageSize` rows) via a server-side
///   LIMIT/OFFSET query (schema/012's `fn_sales_documents_page`), the
///   Document substring filter moved server-side with it (a client-side
///   substring filter over one page's rows would only ever narrow THAT
///   page, not the true filtered result), and the Totals row (below) is
///   sourced from a SEPARATE full-result-set aggregate query
///   (`fn_sales_documents_totals`) rather than summed from whichever page
///   happens to be on screen — see Wyzesales_Rebuild_Decisions.md Section 22
///   for the full reasoning.
/// - 2026-08-27 (same day, third follow-up): column-header sorting, briefly
///   removed by the pagination change above, is back — Craig: "The column
///   sorting is a real issue we need to be able to sort on all columns."
///   Sorting is now a real server-side ORDER BY inside `fn_sales_documents_page`
///   itself (schema/013), not a client-side re-sort of whatever page is in
///   memory — see `_DocumentTable.sortColumnKeys`' doc comment for why that
///   distinction matters once there's more than one page.
class DocumentAnalysisView extends ConsumerStatefulWidget {
  const DocumentAnalysisView({
    super.key,
    required this.documentKinds,
    this.showExportButtons = true,
    this.onExportReady,
  });

  final List<String> documentKinds;

  /// 2026-08-27, cosmetic fix: Sales Analysis passes `false` here and
  /// renders its own `DataExportButtons` sharing a row with the Chart/Table
  /// toggle above this widget — Craig: "align this as per the YTD
  /// Comparative," whose own ValueGpToggle and DataExportButtons sit
  /// side-by-side in one row rather than stacked on two. Quote Analysis and
  /// Sales Order Analysis have no toggle to share a row with, so they keep
  /// the default (this widget renders its own export buttons, right-aligned
  /// at its own top) unchanged.
  final bool showExportButtons;

  /// 2026-08-31: when `showExportButtons` is false, this widget still needs
  /// to hand its export logic somewhere — Sales Analysis's own top-row
  /// DataExportButtons must export this view's rows when its Table tab is
  /// selected. Called once, right after this State mounts, with the same
  /// function `showExportButtons: true` would have wired into its own
  /// DataExportButtons directly — a "lift the callback up" handoff rather
  /// than exposing this private State (or its rows/totals) to the parent.
  final ValueChanged<Future<ExportData> Function()>? onExportReady;

  @override
  ConsumerState<DocumentAnalysisView> createState() => _DocumentAnalysisViewState();
}

class _DocumentAnalysisViewState extends ConsumerState<DocumentAnalysisView> {
  // 100 — small enough that a DataTable (which builds every row's widgets
  // eagerly, unlike a lazily-built ListView) stays comfortably responsive,
  // large enough that most filtered views still fit on one page. Not
  // user-configurable (yet) — Craig didn't ask for a page-size picker, and
  // one more control here would cut against "keep them as small as
  // reasonably possible" (Section 20b) for no clearly requested benefit.
  static const _pageSize = 100;

  int _page = 0;
  late Future<List<SalesDocument>> _pageFuture;

  // Index into `_DocumentTable.sortColumnKeys`, plus direction — default
  // matches this table's original pre-sort order (newest first) and
  // `fn_sales_documents_page`'s own default parameters (schema/013:
  // `p_sort_column default 'doc_date', p_sort_ascending default false`), so
  // the very first load needs no special-casing against the RPC's defaults.
  int _sortColumnIndex = 2;
  bool _sortAscending = false;

  // Totals are tracked separately from `_pageFuture` (not bundled into one
  // combined future) on purpose: turning a page should only re-fetch that
  // page — cheap — not re-run the full-result-set aggregate query behind
  // the Totals row every time. Only an actual filter change reloads this.
  // Same manual future/loading/error trio Dashboard's own
  // `_dimensionData`/`_dimensionLoading`/`_dimensionError` already uses for
  // exactly this "different refresh cadence than the main future" reason.
  SalesDocumentTotals? _totals;
  bool _totalsLoading = true;
  String? _totalsError;

  @override
  void initState() {
    super.initState();
    _pageFuture = _loadPage();
    _totalsLoading = true;
    _loadTotals();
    // Not gated on `showExportButtons` — a caller only bothers passing this
    // when it's false, so this is a no-op for Quote/Sales Order Analysis.
    widget.onExportReady?.call(_buildExportData);
  }

  Future<List<SalesDocument>> _loadPage() {
    final filters = ref.read(globalFiltersProvider);
    return ref.read(salesRepositoryProvider).fetchSalesDocumentsPage(
          documentKinds: widget.documentKinds,
          fiscalYear: filters.fiscalYear ?? fiscalYearFor(DateTime.now()),
          fiscalMonth: filters.fiscalMonth,
          categoryCode: filters.category?.code,
          itemCode: filters.item?.code,
          repCode: filters.salesPerson?.code,
          branchCode: filters.branch?.code,
          customerCode: filters.customer?.code,
          document: filters.document,
          sortColumn: _DocumentTable.sortColumnKeys[_sortColumnIndex],
          sortAscending: _sortAscending,
          page: _page,
          pageSize: _pageSize,
        );
  }

  Future<void> _loadTotals() async {
    final filters = ref.read(globalFiltersProvider);
    try {
      final totals = await ref.read(salesRepositoryProvider).fetchSalesDocumentsTotals(
            documentKinds: widget.documentKinds,
            fiscalYear: filters.fiscalYear ?? fiscalYearFor(DateTime.now()),
            fiscalMonth: filters.fiscalMonth,
            categoryCode: filters.category?.code,
            itemCode: filters.item?.code,
            repCode: filters.salesPerson?.code,
            branchCode: filters.branch?.code,
            customerCode: filters.customer?.code,
            document: filters.document,
          );
      if (!mounted) return;
      setState(() {
        _totals = totals;
        _totalsLoading = false;
        _totalsError = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _totalsLoading = false;
        _totalsError = error.toString();
      });
    }
  }

  /// A filter changed — the previous page may no longer exist against the
  /// new, narrower (or wider) result set, so this goes back to page 0 rather
  /// than trying to preserve a page index that might now be out of range.
  /// Both the page and the totals reload here, unlike `_goToPage` below.
  void _onFiltersChanged() {
    setState(() {
      _page = 0;
      _pageFuture = _loadPage();
      _totalsLoading = true;
    });
    _loadTotals();
  }

  void _goToPage(int page) {
    setState(() {
      _page = page;
      _pageFuture = _loadPage();
    });
  }

  /// A new column/direction is a real re-fetch (schema/013's `ORDER BY`),
  /// not a local re-sort — so, like a filter change, this goes back to page
  /// 0 rather than trying to preserve a page index that meant something
  /// different under the old order. Totals don't need reloading — an
  /// aggregate over the whole filtered set has no sort order to be wrong
  /// about.
  void _onSort(int columnIndex, bool ascending) {
    setState(() {
      _sortColumnIndex = columnIndex;
      _sortAscending = ascending;
      _page = 0;
      _pageFuture = _loadPage();
    });
  }

  @override
  Widget build(BuildContext context) {
    // Covers every way the filter set can change — this screen's own
    // dropdowns, the global filter bar, or another screen entirely — with
    // one code path instead of a separate explicit refetch per call site.
    // ref.listen, not a manual "did it change" diff in build() plus
    // WidgetsBinding.addPostFrameCallback: Craig, 2026-08-26: "When I select
    // a branch nothing is filtered but when I clear the filter then it
    // filters" — the manual version's deferred-by-a-frame callback could
    // lose a race against a second quick filter change and fire the refetch
    // one action late. ref.listen is Riverpod's own primitive for exactly
    // this "run a side effect when a watched provider changes" case, firing
    // the refetch immediately and exactly once per actual change instead.
    ref.listen<GlobalFilters>(globalFiltersProvider, (previous, next) => _onFiltersChanged());

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Just the export buttons now — every filter that used to live in
          // this row (Year, Month, Document, Category, Item, Sales
          // Person, Branch, Customer) is set and shown exclusively through
          // GlobalFilterBar above (2026-08-27) — see this file's class doc
          // comment. Suppressed on Sales Analysis (see showExportButtons'
          // doc comment above), which renders its own copy sharing a row
          // with its Chart/Table toggle instead.
          if (widget.showExportButtons) ...[
            Align(alignment: Alignment.centerRight, child: DataExportButtons(onExport: _buildExportData)),
            const SizedBox(height: 16),
          ],
          Expanded(
            child: AsyncSection<List<SalesDocument>>(
              future: _pageFuture,
              isEmpty: (rows) => rows.isEmpty && _page == 0,
              builder: (context, rows) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _DocumentTable(
                      rows: rows,
                      totals: _totals,
                      totalsLoading: _totalsLoading,
                      totalsError: _totalsError,
                      sortColumnIndex: _sortColumnIndex,
                      sortAscending: _sortAscending,
                      onSort: _onSort,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _PaginationBar(
                    page: _page,
                    pageSize: _pageSize,
                    rowsOnPage: rows.length,
                    totalCount: _totals?.count,
                    onFirst: _page > 0 ? () => _goToPage(0) : null,
                    onPrevious: _page > 0 ? () => _goToPage(_page - 1) : null,
                    onNext: _canGoNext(rows.length) ? () => _goToPage(_page + 1) : null,
                    onLast: _lastPage() != null && _page != _lastPage() ? () => _goToPage(_lastPage()!) : null,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Disabled once the current page came back short (fewer than a full page
  /// — nothing left after it) or, once totals have loaded, once this page's
  /// last row would already be at or past the true total. Checking the
  /// short-page case even before totals resolve means Next doesn't sit
  /// enabled-by-default for the one extra beat before the aggregate query
  /// returns.
  bool _canGoNext(int rowsOnPage) {
    if (rowsOnPage < _pageSize) return false;
    final totalCount = _totals?.count;
    if (totalCount == null) return true;
    return (_page + 1) * _pageSize < totalCount;
  }

  /// Null until totals resolve — matches `_PaginationBar`'s existing
  /// "totalCount is null for the brief window before the aggregate
  /// resolves" handling, so the Last button simply stays disabled rather
  /// than jumping to a page number that might be wrong.
  int? _lastPage() {
    final totalCount = _totals?.count;
    if (totalCount == null) return null;
    if (totalCount == 0) return 0;
    return (totalCount - 1) ~/ _pageSize;
  }

  // 20,000 rows — comfortably past anything Craig's actually filtered down
  // to in practice, but small enough that generating a CSV/PDF from it in
  // the browser tab stays fast. This is a real fetch of the FULL filtered
  // result set (not just the 100-row page on screen — see `_DocumentTable`'s
  // class doc comment on why a page-local view would be actively misleading
  // once there's more than one page, same reasoning applies to export),
  // reusing `fetchSalesDocumentsPage` itself with `page: 0` and a large
  // `pageSize` rather than writing a second, parallel "fetch everything"
  // query — schema/012's underlying RPC already supports this, it's just an
  // unusually large LIMIT.
  static const _maxExportRows = 20000;

  Future<ExportData> _buildExportData() async {
    final totalCount = _totals?.count ?? 0;
    if (totalCount > _maxExportRows) {
      throw ExportUnavailableException(
        'too many rows (${formatQuantity(totalCount)}) to export at once — '
        'narrow your filters to under ${formatQuantity(_maxExportRows)} rows first',
      );
    }
    final filters = ref.read(globalFiltersProvider);
    final allRows = await ref.read(salesRepositoryProvider).fetchSalesDocumentsPage(
          documentKinds: widget.documentKinds,
          fiscalYear: filters.fiscalYear ?? fiscalYearFor(DateTime.now()),
          fiscalMonth: filters.fiscalMonth,
          categoryCode: filters.category?.code,
          itemCode: filters.item?.code,
          repCode: filters.salesPerson?.code,
          branchCode: filters.branch?.code,
          customerCode: filters.customer?.code,
          document: filters.document,
          sortColumn: _DocumentTable.sortColumnKeys[_sortColumnIndex],
          sortAscending: _sortAscending,
          page: 0,
          pageSize: totalCount == 0 ? _pageSize : totalCount,
        );
    final dateFormat = DateFormat('yyyy-MM-dd');
    const headers = [
      'Doc', 'Type', 'Date', 'Sales Person', 'Branch', 'Category', 'Item', 'Customer', 'Qty', 'Revenue', 'GP', 'GP%',
    ];
    final totals = _totals;
    final rows = <List<String>>[
      if (totals != null)
        [
          'Total', '', '', '', '', '', '', '',
          formatQuantity(totals.quantity),
          formatRand(totals.value, precise: true),
          formatRand(totals.profit, precise: true),
          formatPercent(totals.gpPercent),
        ],
      for (final doc in allRows)
        [
          doc.document,
          doc.documentKind,
          dateFormat.format(doc.docDate),
          doc.resolvedRepName ?? doc.resolvedRepCode ?? '—',
          doc.branchDisplayCode ?? doc.branchCode ?? '—',
          doc.categoryName ?? doc.departmentCode ?? '—',
          doc.itemName ?? doc.itemCode,
          doc.customerName ?? doc.accountCode,
          formatQuantity(doc.quantity),
          formatRand(doc.value, precise: true),
          formatRand(doc.profit, precise: true),
          formatPercent(doc.profitPercent),
        ],
    ];
    final kindLabel = widget.documentKinds.length == 1 ? widget.documentKinds.first : 'documents';
    final niceLabel = kindLabel.replaceAll('_', ' ');
    return ExportData(
      headers: headers,
      rows: rows,
      fileNameBase: 'wyzesales_${kindLabel}_${DateTime.now().millisecondsSinceEpoch}',
      title: 'WyzeSales — ${niceLabel[0].toUpperCase()}${niceLabel.substring(1)}',
    );
  }
}

/// "Showing 1-100 of 4,238" plus Previous/Next — replaces the old unbounded
/// "Showing 448 line(s)" label now that a screen can hold many more rows
/// than are ever in memory at once (2026-08-27, Craig: "What happens when
/// there 4000 lines?"). `totalCount` is null for the brief window before the
/// separate totals aggregate resolves; the range still renders using just
/// what's on this page rather than blocking on it.
class _PaginationBar extends StatelessWidget {
  const _PaginationBar({
    required this.page,
    required this.pageSize,
    required this.rowsOnPage,
    required this.totalCount,
    required this.onFirst,
    required this.onPrevious,
    required this.onNext,
    required this.onLast,
  });

  final int page;
  final int pageSize;
  final int rowsOnPage;
  final int? totalCount;

  // 2026-08-27, Craig: "Can we have a control the goes to the first page and
  // one that goes to the last page to avoid having to go back or forwards
  // only 1 page at a time." `onFirst`/`onLast` are null (button disabled)
  // exactly when there's nowhere further to jump — already on page 0, or
  // `_lastPage()` hasn't resolved yet / we're already on it — mirroring how
  // `onPrevious`/`onNext` were already null'd out rather than left enabled
  // and silently doing nothing.
  final VoidCallback? onFirst;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final VoidCallback? onLast;

  @override
  Widget build(BuildContext context) {
    final from = rowsOnPage == 0 ? 0 : page * pageSize + 1;
    final to = page * pageSize + rowsOnPage;
    final rangeLabel = totalCount == null
        ? 'Showing ${formatQuantity(from)}–${formatQuantity(to)}'
        : 'Showing ${formatQuantity(from)}–${formatQuantity(to)} of ${formatQuantity(totalCount!)}';
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(rangeLabel, style: Theme.of(context).textTheme.bodyMedium),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(tooltip: 'First page', icon: const Icon(Icons.first_page), onPressed: onFirst),
            IconButton(tooltip: 'Previous page', icon: const Icon(Icons.chevron_left), onPressed: onPrevious),
            IconButton(tooltip: 'Next page', icon: const Icon(Icons.chevron_right), onPressed: onNext),
            IconButton(tooltip: 'Last page', icon: const Icon(Icons.last_page), onPressed: onLast),
          ],
        ),
      ],
    );
  }
}

/// 2026-08-27: no longer a `StatefulWidget` managing its own re-sortable copy
/// of `rows` — the parent now controls exactly which rows are on screen
/// (one server-fetched page) AND which sort is active, so there is nothing
/// left for local State to own here.
///
/// Column-header sorting (Craig, 2026-08-26: "sort ascending or descending
/// order by clicking on a column header") was briefly removed when
/// pagination first landed — the old sort re-ordered whatever page's rows
/// happened to be in memory, which was only ever correct because every row
/// used to be fetched at once; with real pagination, clicking "Customer"
/// ascending would otherwise only reorder the 100 rows on the current page,
/// not the true order across every page. It's back now (Craig, same day,
/// immediate follow-up: "The column sorting is a real issue we need to be
/// able to sort on all columns") as a real server-side `ORDER BY` inside
/// `fn_sales_documents_page` itself (schema/013) — `onSort` above just
/// records which column/direction is active and triggers a re-fetch;
/// `sortColumnKeys` below is the index-aligned list of column keys schema/013
/// accepts as `p_sort_column`, and `SalesRepository.fetchSalesDocumentsPage`'s
/// own doc comment points back to this exact list as its source of truth.
class _DocumentTable extends StatelessWidget {
  const _DocumentTable({
    required this.rows,
    required this.totals,
    required this.totalsLoading,
    required this.totalsError,
    required this.sortColumnIndex,
    required this.sortAscending,
    required this.onSort,
  });

  final List<SalesDocument> rows;
  final SalesDocumentTotals? totals;
  final bool totalsLoading;
  final String? totalsError;
  final int sortColumnIndex;
  final bool sortAscending;
  final void Function(int columnIndex, bool ascending) onSort;

  /// Index-aligned with the 12 `DataColumn`s in `build()` below, and with
  /// schema/013's `fn_sales_documents_page` CASE/WHEN list — a column here
  /// that isn't also one of schema/013's hardcoded cases would silently fall
  /// through to that function's `else 'v.doc_date'` default instead of
  /// erroring, so any future column added to this table needs a matching
  /// entry added to both places, in the same order.
  static const sortColumnKeys = [
    'document',
    'document_kind',
    'doc_date',
    'sales_person',
    'branch',
    'category',
    'item',
    'customer',
    'quantity',
    'value',
    'profit',
    'profit_percent',
  ];

  /// Pinned as the FIRST row now, not the last — 2026-08-27, Craig: "Does it
  /// make sense to have the Totals as the first line in a view?" Sourced
  /// from `totals` (the full-filtered-result-set aggregate), never from
  /// `rows` (just whichever page is on screen) — see this file's class doc
  /// comment and SalesDocumentTotals' own doc comment for why a page-local
  /// sum would be actively misleading once there's more than one page. GP%
  /// is recomputed from the totalled Revenue/GP, not averaged from each
  /// row's own GP%, same as every other totals row in the app.
  DataRow _totalsRow(BuildContext context) {
    const style = TextStyle(fontWeight: FontWeight.bold);
    final current = totals;
    if (current == null) {
      final label = totalsError != null ? 'Total (unavailable)' : (totalsLoading ? 'Total (loading…)' : 'Total');
      return DataRow(
        color: WidgetStatePropertyAll(Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.04)),
        cells: [
          DataCell(Text(label, style: style)),
          for (var i = 0; i < 11; i++) const DataCell(Text('')),
        ],
      );
    }
    final gpColor = current.profit < 0 ? Theme.of(context).colorScheme.error : null;
    return DataRow(
      color: WidgetStatePropertyAll(Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.04)),
      cells: [
        const DataCell(Text('Total', style: style)),
        const DataCell(Text('')),
        const DataCell(Text('')),
        const DataCell(Text('')),
        const DataCell(Text('')),
        const DataCell(Text('')),
        const DataCell(Text('')),
        const DataCell(Text('')),
        DataCell(Text(formatQuantity(current.quantity), style: style)),
        DataCell(Text(formatRand(current.value, precise: true), style: style)),
        DataCell(Text(formatRand(current.profit, precise: true), style: style.copyWith(color: gpColor))),
        DataCell(Text(formatPercent(current.gpPercent), style: style.copyWith(color: gpColor))),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final dateFormat = DateFormat('yyyy-MM-dd');
    return ResponsiveDataTable(
      sortColumnIndex: sortColumnIndex,
      sortAscending: sortAscending,
      // Totals is always rows[0] here — see `_totalsRow`'s own doc comment
      // — so it's always the one row frozen under the header (2026-08-27,
      // Craig: "lock the Headers and Totals so we don't lose them when
      // scrolling down").
      pinnedRowCount: 1,
      columns: [
        DataColumn(label: const Text('Doc'), onSort: onSort),
        DataColumn(label: const Text('Type'), onSort: onSort),
        DataColumn(label: const Text('Date'), onSort: onSort),
        DataColumn(label: const Text('Sales Person'), onSort: onSort),
        DataColumn(label: const Text('Branch'), onSort: onSort),
        DataColumn(label: const Text('Category'), onSort: onSort),
        DataColumn(label: const Text('Item'), onSort: onSort),
        DataColumn(label: const Text('Customer'), onSort: onSort),
        DataColumn(label: const Text('Qty'), numeric: true, onSort: onSort),
        DataColumn(label: const Text('Revenue'), numeric: true, onSort: onSort),
        DataColumn(label: const Text('GP'), numeric: true, onSort: onSort),
        DataColumn(label: const Text('GP%'), numeric: true, onSort: onSort),
      ],
      rows: [
        _totalsRow(context),
        ...rows.map((doc) {
          final gpColor = doc.profit < 0 ? Theme.of(context).colorScheme.error : null;
          return DataRow(cells: [
            DataCell(Text(doc.document)),
            DataCell(Text(doc.documentKind)),
            DataCell(Text(dateFormat.format(doc.docDate))),
            DataCell(Text(doc.resolvedRepName ?? doc.resolvedRepCode ?? '—')),
            DataCell(Text(doc.branchDisplayCode ?? doc.branchCode ?? '—')),
            DataCell(Text(doc.categoryName ?? doc.departmentCode ?? '—')),
            DataCell(Text(doc.itemName ?? doc.itemCode)),
            DataCell(Text(doc.customerName ?? doc.accountCode)),
            DataCell(Text(formatQuantity(doc.quantity))),
            DataCell(Text(formatRand(doc.value, precise: true))),
            DataCell(Text(formatRand(doc.profit, precise: true), style: TextStyle(color: gpColor))),
            DataCell(Text(formatPercent(doc.profitPercent), style: TextStyle(color: gpColor))),
          ]);
        }),
      ],
    );
  }
}
