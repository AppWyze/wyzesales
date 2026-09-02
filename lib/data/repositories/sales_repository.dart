import '../../core/constants/fiscal.dart';
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
    String? categoryCode,
    String? itemCode,
    String? repCode,
    String? branchCode,
    String? customerCode,
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
      categoryCode: categoryCode,
      itemCode: itemCode,
      repCode: repCode,
      branchCode: branchCode,
      customerCode: customerCode,
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
    String? categoryCode,
    String? itemCode,
    String? repCode,
    String? branchCode,
    String? customerCode,
    String? document,
  }) async {
    final params = _salesDocumentsFilterParams(
      documentKinds: documentKinds,
      fiscalYear: fiscalYear,
      fiscalMonth: fiscalMonth,
      categoryCode: categoryCode,
      itemCode: itemCode,
      repCode: repCode,
      branchCode: branchCode,
      customerCode: customerCode,
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
  /// `fn_sales_documents_totals` (schema/012) — the two functions take
  /// identical filter parameters (page adds only p_limit/p_offset on top),
  /// so this is the one place that maps GlobalFilters' field names to their
  /// `p_*` RPC parameter names. `fiscalMonth` is passed through as-is now
  /// (matched via schema/002's `fiscal_month_label(doc_date)` inside the SQL
  /// function itself) rather than converted to a calendar doc_date range in
  /// Dart the way the old plain-view query needed to — that conversion
  /// existed only because v_sales_documents has no fiscal_month column of
  /// its own; the new SQL functions can call the same helper function
  /// v_sales_cube_monthly (schema/011) already uses for exactly this.
  Map<String, dynamic> _salesDocumentsFilterParams({
    required List<String> documentKinds,
    int? fiscalYear,
    String? fiscalMonth,
    String? categoryCode,
    String? itemCode,
    String? repCode,
    String? branchCode,
    String? customerCode,
    String? document,
  }) {
    return {
      'p_document_kinds': documentKinds,
      'p_fiscal_year': fiscalYear,
      'p_fiscal_month': fiscalMonth,
      'p_category': categoryCode,
      'p_item': itemCode,
      'p_rep': repCode,
      'p_branch': branchCode,
      'p_customer': customerCode,
      'p_document': (document == null || document.isEmpty) ? null : document,
    };
  }

  /// The shared tidy rollup — pass entityCode for a single-entity trend
  /// (Sales Analysis Graph tab, YTD Comparative) or leave it null for every
  /// entity in the dimension (Sales by [Dimension]).
  Future<List<DimensionMonthlySales>> fetchDimensionMonthlySales({
    required SalesDimension dimension,
    String? entityCode,
    List<int>? fiscalYears,
    GlobalFilters? filters,
  }) async {
    if (!_hasCrossFilters(filters)) {
      var query = supabase.from('v_dimension_monthly_sales').select().eq('dimension', dimension.dbValue);
      if (entityCode != null) query = query.eq('entity_code', entityCode);
      if (fiscalYears != null && fiscalYears.isNotEmpty) {
        query = query.inFilter('fiscal_year', fiscalYears);
      }
      final rows = await query.order('month');
      return rows.map<DimensionMonthlySales>((r) => DimensionMonthlySales.fromMap(r)).toList();
    }

    final rows = await supabase.rpc('fn_dimension_monthly_sales_filtered', params: {
      'p_dimension': dimension.dbValue,
      'p_entity_code': entityCode,
      'p_fiscal_years': fiscalYears,
      'p_fiscal_month': filters!.fiscalMonth,
      'p_filter_sales_person': filters.salesPerson?.code,
      'p_filter_customer': filters.customer?.code,
      'p_filter_item': filters.item?.code,
      'p_filter_category': filters.category?.code,
      'p_filter_branch': filters.branch?.code,
    });
    return (rows as List).map<DimensionMonthlySales>((r) => DimensionMonthlySales.fromMap(r as Map<String, dynamic>)).toList();
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
      'p_filter_sales_person': filters.salesPerson?.code,
      'p_filter_customer': filters.customer?.code,
      'p_filter_item': filters.item?.code,
      'p_filter_category': filters.category?.code,
      'p_filter_branch': filters.branch?.code,
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
  Future<List<DimensionPerformance>> fetchDimensionPerformance({
    required SalesDimension dimension,
    String? entityCode,
    int? fiscalYear,
    String? fiscalMonth,
    GlobalFilters? filters,
  }) async {
    final hasDimensionFilters = filters != null &&
        (filters.salesPerson != null ||
            filters.category != null ||
            filters.customer != null ||
            filters.item != null ||
            filters.branch != null);

    if (!hasDimensionFilters) {
      var query = supabase.from('v_dimension_performance').select().eq('dimension', dimension.dbValue);
      if (entityCode != null) query = query.eq('entity_code', entityCode);
      if (fiscalYear != null) query = query.eq('fiscal_year', fiscalYear);
      if (fiscalMonth != null) query = query.eq('fiscal_month', fiscalMonth);
      final rows = await query.order('fiscal_year').order('fiscal_month');
      return rows.map<DimensionPerformance>((r) => DimensionPerformance.fromMap(r)).toList();
    }

    final rows = await supabase.rpc('fn_dimension_performance_filtered', params: {
      'p_dimension': dimension.dbValue,
      'p_entity_code': entityCode,
      'p_fiscal_year': fiscalYear,
      'p_fiscal_month': fiscalMonth,
      'p_filter_sales_person': filters.salesPerson?.code,
      'p_filter_customer': filters.customer?.code,
      'p_filter_item': filters.item?.code,
      'p_filter_category': filters.category?.code,
      'p_filter_branch': filters.branch?.code,
    });
    return (rows as List).map<DimensionPerformance>((r) => DimensionPerformance.fromMap(r as Map<String, dynamic>)).toList();
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
    final rows = await supabase.rpc('fn_dimension_sales_history', params: {
      'p_dimension': dimension,
      'p_fiscal_years': fiscalYears,
    });
    return (rows as List).map<EntitySalesHistory>((r) => EntitySalesHistory.fromMap(r as Map<String, dynamic>)).toList();
  }

  /// True when `filters` carries anything a plain single-dimension rollup
  /// view query can't honour on its own — any of the 5 dimension codes, or
  /// (for the two monthly methods above) the global Month filter, which
  /// v_dimension_monthly_sales/v_consolidated_sales could technically filter
  /// by directly, but routing it through the same RPC as the dimension
  /// filters keeps this to one code path instead of two.
  bool _hasCrossFilters(GlobalFilters? filters) {
    if (filters == null) return false;
    return filters.salesPerson != null ||
        filters.category != null ||
        filters.customer != null ||
        filters.item != null ||
        filters.branch != null ||
        filters.fiscalMonth != null;
  }
}
