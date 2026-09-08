import '../../core/filters/global_filters.dart';
import '../../core/supabase/supabase_config.dart';
import '../../core/utils/sales_coverage.dart';
import '../models/consolidated_sales.dart';
import '../models/dimension_monthly_sales.dart';
import '../models/dimension_performance.dart';
import '../models/sales_document.dart';

/// Everything Sales Analysis, YTD Comparative, Quote Analysis, Sales Order
/// Analysis, Sales by [Dimension], and Performance read from — three views
/// (v_sales_documents, v_dimension_monthly_sales, v_dimension_performance),
/// per schema/001 Section 9 and schema/002. All reads; RLS on the underlying
/// tables already restricts every query to the caller's own client_id (see
/// AuthRepository's doc comment), so nothing here needs a client_id filter.
///
/// 2026-08-26 (schema/011, global cross-dimension filters): fetchDimension
/// MonthlySales/fetchConsolidatedSales/fetchDimensionPerformance now take an
/// optional `filters` (GlobalFilters — core/filters/global_filters.dart).
/// When none of it applies, the query goes straight to the same plain view
/// query as before (unchanged, no extra round trip). The moment ANY
/// cross-dimension filter (or, for the two monthly-rollup methods, the
/// global Month filter) is active, the query is instead routed to one of
/// three new Postgres functions (fn_dimension_monthly_sales_filtered /
/// fn_consolidated_sales_filtered / fn_dimension_performance_filtered) —
/// see that migration's header comment for exactly why a plain view query
/// can't do this: v_dimension_monthly_sales/v_consolidated_sales/
/// v_dimension_performance are each grouped by (at most) one dimension
/// already, so none of them carry a second dimension's code as a filterable
/// column. Both paths return the exact same row shape, so the existing
/// model classes' fromMap needs no changes either way.
class SalesRepository {
  /// Line-level detail, ONE PAGE at a time — Sales Analysis' Table tab when
  /// documentKinds is ['invoice','credit_note'], Quote Analysis when
  /// ['quote'], Sales Order Analysis when ['sales_order'].
  ///
  /// 2026-08-27, Craig, after Sales Analysis loaded 448 lines in one shot:
  /// "What happens when there 4000 lines? What is considered the norm in
  /// apps like this?" The previous `fetchSalesDocuments` fetched up to 1000
  /// rows in a single plain view query with no pagination and no indication
  /// anything was ever cut off (a filtered set past 1000 lines would
  /// silently lose the tail). This replaces it with `fn_sales_documents_page`
  /// (schema/012) — a real LIMIT/OFFSET page, newest first — via `.rpc(...)`
  /// rather than a plain `.from('v_sales_documents').select()...` query,
  /// since a plain PostgREST view query has no clean way to also apply the
  /// `document` substring filter and page window server-side in one
  /// round trip the way this app's other cross-filter cases already use RPC
  /// functions for (see schema/011's fn_*_filtered — same reasoning: a
  /// `language sql` function with no `security definer` still runs as the
  /// calling role, so RLS applies exactly as it does on a plain view query).
  ///
  /// `document` (2026-08-27, promoted from a screen-local text field to
  /// `GlobalFilters.document`) is now applied HERE, server-side, rather than
  /// client-side against whichever rows happened to already be in memory
  /// (the old `_filterByDocument` in document_analysis_view.dart) — once a
  /// page is a real slice of a larger result set, filtering has to happen on
  /// the same query that produces the page, or it would only ever narrow
  /// the CURRENT page instead of the true result set.
  ///
  /// `sortColumn`/`sortAscending` (2026-08-27, schema/013, Craig: "The
  /// column sorting is a real issue we need to be able to sort on all
  /// columns") are for the SAME reason server-side, not applied to whatever
  /// page came back — sorting only the visible page would be exactly the
  /// same kind of quietly-wrong behaviour the Document filter above already
  /// had to move away from. `sortColumn` must be one of
  /// `_DocumentTable.sortColumnKeys` (document_analysis_view.dart) — see
  /// `fn_sales_documents_page`'s own doc comment for the fixed, hardcoded
  /// list of columns it actually accepts; anything else falls back to
  /// doc_date there, it never reaches raw SQL.
  Future<List<SalesDocument>> fetchSalesDocumentsPage({
    required List<String> documentKinds,
    int? fiscalYear,
    String? fiscalMonth,
    List<String>? fiscalQuarterMonths,
    Map<String, String> filters = const {},
    String? document,
    String sortColumn = 'doc_date',
    bool sortAscending = false,
    int page = 0,
    int pageSize = 100,
  }) async {
    final params = _salesDocumentsFilterParams(
      documentKinds: documentKinds,
      fiscalYear: fiscalYear,
      fiscalMonth: fiscalMonth,
      fiscalQuarterMonths: fiscalQuarterMonths,
      filters: filters,
      document: document,
    )..addAll({
        'p_sort_column': sortColumn,
        'p_sort_ascending': sortAscending,
        'p_limit': pageSize,
        'p_offset': page * pageSize,
      });

    final rows = await supabase.rpc('fn_sales_documents_page', params: params);
    return (rows as List).map<SalesDocument>((r) => SalesDocument.fromMap(r as Map<String, dynamic>)).toList();
  }

  /// COUNT/SUM over EVERY row matching the current filters, ignoring
  /// pagination entirely — `fn_sales_documents_totals` (schema/012). This is
  /// what makes both the Totals row and the "Showing X-Y of Z" indicator
  /// correct regardless of page size or which page is on screen. Kept
  /// entirely separate from `fetchSalesDocumentsPage` above (not called from
  /// it) so a screen turning pages re-fetches just the page — cheap — rather
  /// than re-running this aggregate query on every page turn; only an
  /// actual filter change needs a fresh call here.
  Future<SalesDocumentTotals> fetchSalesDocumentsTotals({
    required List<String> documentKinds,
    int? fiscalYear,
    String? fiscalMonth,
    List<String>? fiscalQuarterMonths,
    Map<String, String> filters = const {},
    String? document,
  }) async {
    final params = _salesDocumentsFilterParams(
      documentKinds: documentKinds,
      fiscalYear: fiscalYear,
      fiscalMonth: fiscalMonth,
      fiscalQuarterMonths: fiscalQuarterMonths,
      filters: filters,
      document: document,
    );
    final rows = await supabase.rpc('fn_sales_documents_totals', params: params);
    return SalesDocumentTotals.fromMap((rows as List).first as Map<String, dynamic>);
  }

  /// `fetchDocumentCounts` (`fn_document_counts`, schema/015) was removed
  /// 2026-09-02, task #93/#103 — its only caller was the Dashboard's Quote →
  /// Order Conversion KPI tile, itself replaced by the Sales Coverage tile
  /// (`fetchSalesHistory` below) for the same reason Quote/Sales Order
  /// Analysis were removed entirely: see Wyzesales_Rebuild_Decisions.md
  /// Section 55. `fn_document_counts` itself is left in place in Supabase —
  /// there's no cost to an unused SQL function, and dropping it isn't
  /// necessary for anything this cleanup needed.

  /// Shared param map for both `fn_sales_documents_page` and
  /// `fn_sales_documents_totals` (schema/012, generalized by migration 050)
  /// — the two functions take identical filter parameters (page adds only
  /// p_limit/p_offset/p_sort_* on top), so this is the one place that maps
  /// GlobalFilters' field names to their `p_*` RPC parameter names.
  /// `fiscalMonth` is passed through as-is now (matched via schema/002's
  /// `fiscal_month_label(doc_date)` inside the SQL function itself) rather
  /// than converted to a calendar doc_date range in Dart the way the old
  /// plain-view query needed to — that conversion existed only because
  /// v_sales_documents has no fiscal_month column of its own; the new SQL
  /// functions can call the same helper function v_sales_cube_monthly
  /// (schema/011) already uses for exactly this.
  ///
  /// 2026-09-07 (migration 050): the five named p_category/p_item/p_rep/
  /// p_branch/p_customer parameters collapsed into one `filters` map, keyed
  /// by dimension_key — the exact same shape GlobalFilters.toFilterParams()
  /// already produces for every other generalized RPC (fn_dimension_
  /// monthly_sales_filtered etc., migration 042/047), so callers just pass
  /// `filters.toFilterParams()` straight through instead of pulling five
  /// individual dimensions out by hand. This is what lets Document Analysis
  /// (Sales/Quote/Sales Order Analysis) filter by ANY of a client's own
  /// configured dimensions, not just WCSA's fixed five.
  Map<String, dynamic> _salesDocumentsFilterParams({
    required List<String> documentKinds,
    int? fiscalYear,
    String? fiscalMonth,
    List<String>? fiscalQuarterMonths,
    Map<String, String> filters = const {},
    String? document,
  }) {
    return {
      'p_document_kinds': documentKinds,
      'p_fiscal_year': fiscalYear,
      'p_fiscal_month': fiscalMonth,
      'p_fiscal_quarter_months': fiscalQuarterMonths,
      'p_filters': filters,
      'p_document': (document == null || document.isEmpty) ? null : document,
    };
  }

  /// The shared tidy rollup — pass entityCode for a single-entity trend
  /// (Sales Analysis Graph tab, YTD Comparative) or leave it null for every
  /// entity in the dimension (Sales by [Dimension]).
  ///
  /// `dimension` is a plain dimension_key string (client_dimensions.
  /// dimension_key, schema/038) rather than the fixed `SalesDimension` enum —
  /// 2026-09-06 (multi-tenant dimension model Step 4): this was the only
  /// thing stopping Sales By/Performance from ever showing a brand-new
  /// client's own dim_1..dim_12 dimension, since both v_dimension_monthly_
  /// sales (schema/039) and fn_dimension_monthly_sales_filtered (schema/042)
  /// already accept any configured dimension_key — this method just forwarded
  /// whichever value it was given either way (`dimension.dbValue` was always
  /// the only thing read off the enum). Every existing caller passes
  /// `SalesDimension.x.dbValue`, so this is a zero-behaviour-change signature
  /// swap for WCSA.
  Future<List<DimensionMonthlySales>> fetchDimensionMonthlySales({
    required String dimension,
    String? entityCode,
    List<int>? fiscalYears,
    GlobalFilters? filters,
  }) async {
    if (!_hasCrossFilters(filters)) {
      // _fetchAllRows, not a bare `await query...` — see that method's own
      // doc comment. 2026-09-08, Craig: "2024 data is missing"... "it works
      // if you call up by customer specific... but not as the entire
      // bunch" — this exact unbounded query, for the one dimension
      // (Customer) with enough distinct entities to actually cross this
      // project's Max Rows API cap.
      final rows = await _fetchAllRows(() {
        var query = supabase.from('v_dimension_monthly_sales').select().eq('dimension', dimension);
        if (entityCode != null) query = query.eq('entity_code', entityCode);
        if (fiscalYears != null && fiscalYears.isNotEmpty) {
          query = query.inFilter('fiscal_year', fiscalYears);
        }
        return query.order('month');
      });
      return rows.map<DimensionMonthlySales>((r) => DimensionMonthlySales.fromMap(r)).toList();
    }

    // Also paginated (see _fetchAllRows) — PostgREST's Max Rows cap applies
    // to a `rpc()` call returning a table/set exactly the same way it does
    // to a plain view query (there's no separate, more generous default for
    // RPC), so this path carried the identical latent bug even though
    // nothing had yet surfaced it live.
    final rows = await _fetchAllRows(() => supabase.rpc('fn_dimension_monthly_sales_filtered', params: {
          'p_dimension': dimension,
          'p_entity_code': entityCode,
          'p_fiscal_years': fiscalYears,
          'p_fiscal_month': filters!.fiscalMonth,
          'p_filters': filters.toFilterParams(),
          // 2026-09-07 (schema/047) — Quarter, resolved to concrete fiscal
          // months once already by GlobalFiltersNotifier.setFiscalQuarter (see
          // GlobalFilters.fiscalQuarterMonths' own doc comment); this repository
          // has no `ref`/startMonth of its own to resolve 'Q1' itself, so it
          // just forwards the already-resolved list, same as it's always just
          // forwarded the already-resolved `fiscalMonth` string above.
          'p_fiscal_quarter_months': filters.fiscalQuarterMonths,
        }));
    return rows.map<DimensionMonthlySales>((r) => DimensionMonthlySales.fromMap(r)).toList();
  }

  /// Whole-company monthly trend — Sales Analysis' Graph tab, and the
  /// Dashboard's KPI row. Used instead of v_dimension_monthly_sales for the
  /// no-filter case because that view only groups by one dimension at a
  /// time; combining several filters (e.g. category AND branch together)
  /// into one trend line isn't something either rollup view supports
  /// without the schema/011 RPC route below.
  Future<List<ConsolidatedSales>> fetchConsolidatedSales({List<int>? fiscalYears, GlobalFilters? filters}) async {
    if (!_hasCrossFilters(filters)) {
      var query = supabase.from('v_consolidated_sales').select();
      if (fiscalYears != null && fiscalYears.isNotEmpty) {
        query = query.inFilter('fiscal_year', fiscalYears);
      }
      final rows = await query.order('month');
      return rows.map<ConsolidatedSales>((r) => ConsolidatedSales.fromMap(r)).toList();
    }

    final rows = await supabase.rpc('fn_consolidated_sales_filtered', params: {
      'p_fiscal_years': fiscalYears,
      'p_fiscal_month': filters!.fiscalMonth,
      'p_filters': filters.toFilterParams(),
      // See fetchDimensionMonthlySales' identical line just above for why
      // this is the already-resolved list, not a raw 'Q1' label.
      'p_fiscal_quarter_months': filters.fiscalQuarterMonths,
    });
    return (rows as List).map<ConsolidatedSales>((r) => ConsolidatedSales.fromMap(r as Map<String, dynamic>)).toList();
  }

  /// Performance screen — actual vs. target vs. forecast, one row per
  /// entity/fiscal month. Leave fiscalYear/fiscalMonth null to pull every
  /// period on record for the dimension (e.g. for a picker's initial load).
  /// fiscalMonth here is Performance's own existing first-class parameter —
  /// the global Month filter reaches this method through it (see
  /// performance_screen.dart, which now sources both its Year and Month
  /// dropdown values directly from GlobalFilters), so only the OTHER 5
  /// dimensions count toward whether this needs the RPC route.
  ///
  /// `dimension` is a plain dimension_key string — see
  /// fetchDimensionMonthlySales' own doc comment (2026-09-06, Step 4) for why.
  Future<List<DimensionPerformance>> fetchDimensionPerformance({
    required String dimension,
    String? entityCode,
    int? fiscalYear,
    String? fiscalMonth,
    // 2026-09-07 (schema/047) — Quarter, resolved to its 3 fiscal months.
    // Explicit param, not read off `filters`, same reasoning as `fiscalMonth`
    // above: Performance screen computes its OWN effective period (merging
    // across years/months when only one of Year/Month is set — see
    // performance_screen.dart's `_effectiveFiscalMonth`/`_effectiveFiscalYear`
    // doc comments) rather than always taking the global filter's raw value,
    // so this needs to be settable independently of `filters.fiscalQuarterMonths`.
    List<String>? fiscalQuarterMonths,
    GlobalFilters? filters,
  }) async {
    final hasDimensionFilters = filters != null && filters.hasAnyDimensionSelected;

    if (!hasDimensionFilters) {
      // _fetchAllRows — same fix, same reason, as fetchDimensionMonthlySales'
      // identical plain-view branch above: Performance is per-entity-per-
      // month too, so a client with a large Customer dimension carries the
      // exact same risk here, even though this specific method hasn't yet
      // been reported broken live.
      final rows = await _fetchAllRows(() {
        var query = supabase.from('v_dimension_performance').select().eq('dimension', dimension);
        if (entityCode != null) query = query.eq('entity_code', entityCode);
        if (fiscalYear != null) query = query.eq('fiscal_year', fiscalYear);
        if (fiscalMonth != null) query = query.eq('fiscal_month', fiscalMonth);
        if (fiscalQuarterMonths != null) query = query.inFilter('fiscal_month', fiscalQuarterMonths);
        return query.order('fiscal_year').order('fiscal_month');
      });
      return rows.map<DimensionPerformance>((r) => DimensionPerformance.fromMap(r)).toList();
    }

    final rows = await _fetchAllRows(() => supabase.rpc('fn_dimension_performance_filtered', params: {
          'p_dimension': dimension,
          'p_entity_code': entityCode,
          'p_fiscal_year': fiscalYear,
          'p_fiscal_month': fiscalMonth,
          'p_filters': filters.toFilterParams(),
          'p_fiscal_quarter_months': fiscalQuarterMonths,
        }));
    return rows.map<DimensionPerformance>((r) => DimensionPerformance.fromMap(r)).toList();
  }

  /// Raw inputs for the "% Coverage Needed" calc (task #93/#101,
  /// core/utils/sales_coverage.dart) — `fn_dimension_sales_history`
  /// (schema/023). Pass `dimension.dbValue` to get every entity's own
  /// trailing-window active-months + total-revenue, or the literal string
  /// `'company'` to get the single company-wide fallback row (entity_code
  /// `'ALL'`) that same function returns for that dimension value (see
  /// v_dimension_monthly_sales' own 'company' branch, schema/002).
  /// `fiscalYears` should be the client's configured trailing history window
  /// (`fiscalYearWindow(currentFy, historyYears)`, fiscal.dart) — this is a
  /// standalone historical baseline, deliberately independent of whatever
  /// period Performance Analysis currently has filtered.
  Future<List<EntitySalesHistory>> fetchSalesHistory({required String dimension, required List<int> fiscalYears}) async {
    // _fetchAllRows — this returns one row per ENTITY (every customer/rep/
    // etc. on record, all at once, for the "% Coverage Needed" calc), so it
    // carries the exact same large-Customer-dimension risk as the two
    // methods above, for the same reason.
    final rows = await _fetchAllRows(() => supabase.rpc('fn_dimension_sales_history', params: {
          'p_dimension': dimension,
          'p_fiscal_years': fiscalYears,
        }));
    return rows.map<EntitySalesHistory>((r) => EntitySalesHistory.fromMap(r)).toList();
  }

  /// True when `filters` carries anything a plain single-dimension rollup
  /// view query can't honour on its own — any of the 5 dimension codes, or
  /// (for the two monthly methods above) the global Month or Quarter filter,
  /// which v_dimension_monthly_sales/v_consolidated_sales could technically
  /// filter by directly, but routing it through the same RPC as the
  /// dimension filters keeps this to one code path instead of two.
  bool _hasCrossFilters(GlobalFilters? filters) {
    if (filters == null) return false;
    return filters.hasAnyDimensionSelected || filters.fiscalMonth != null || filters.fiscalQuarter != null;
  }

  /// A plain `.from(...).select()...` view query — or an `rpc()` call
  /// returning a table/set, which PostgREST treats the same way — with no
  /// explicit `.range()` on it is silently capped at this Supabase
  /// project's own "Max Rows" API setting (Settings > API; 1000 by default
  /// on a new project, admin-configurable). There's no error and no signal
  /// anything was cut off: `await query` looks identical whether the true
  /// result set was 12 rows or 12,000.
  ///
  /// This codebase already hit this once, for a different query — Sales
  /// Analysis' Table tab (2026-08-27, Craig: "What happens when there
  /// [are] 4000 lines?" — see fn_sales_documents_page, schema/012, this
  /// repository's own fetchSalesDocumentsPage). That fix only covered that
  /// one query, via real server-side LIMIT/OFFSET; every other unbounded
  /// query in this class carried the identical latent bug, just waiting for
  /// a result set large enough to actually cross whatever this project's
  /// cap happens to be.
  ///
  /// 2026-09-08, Craig (Sales by Customer): "2024 data is missing"... "it
  /// works if you call up by customer specific... but not as the entire
  /// bunch" — traced to exactly this. Customer is the one dimension with
  /// dramatically more distinct entities than any other WyzeSales client
  /// dimension (Edgetec: ~140 customers vs. a handful of sales reps/
  /// categories/branches/generic dimensions), so its (entity × month) row
  /// count for a multi-fiscal-year window was the first — and, so far,
  /// only — one to actually cross the line. Every other dimension's result
  /// set was small enough to slip under the cap by accident, not because
  /// its own query was actually safe.
  ///
  /// Pages through `buildQuery()` — which MUST build and return a fresh
  /// query each call, not reuse one already awaited — in `_pageSize`-row
  /// windows via `.range()`, advancing by however many rows actually came
  /// back (not by `_pageSize`) and stopping only on a genuinely EMPTY page.
  /// That's the one stop condition that's correct no matter what this
  /// project's own Max Rows setting actually is: if that setting happens to
  /// be smaller than `_pageSize`, every `.range()` request would come back
  /// "short" long before the real end of the data, so "shorter than asked
  /// for" can't be trusted as an end-of-data signal on its own — only an
  /// outright empty page can.
  static const int _pageSize = 1000;

  Future<List<Map<String, dynamic>>> _fetchAllRows(dynamic Function() buildQuery) async {
    final all = <Map<String, dynamic>>[];
    var start = 0;
    while (true) {
      final List page = await buildQuery().range(start, start + _pageSize - 1);
      if (page.isEmpty) break;
      all.addAll(page.cast<Map<String, dynamic>>());
      start += page.length;
    }
    return all;
  }
}
