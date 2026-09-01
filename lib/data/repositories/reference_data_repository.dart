import '../../core/constants/fiscal.dart';
import '../../core/filters/global_filters.dart';
import '../../core/supabase/supabase_config.dart';
import '../models/reference_data.dart';

/// Picker/lookup data for the filter bar and the Budgets screen's entity
/// list — schema/001 Section 2. Reads only; these tables are written by
/// WyzeSalesExtract (or directly by WCSA staff for the display_code/name
/// columns), never by this app.
class ReferenceDataRepository {
  Future<List<CodeName>> branches({String? search}) async {
    var query = supabase.from('branches').select('code, display_code, name');
    if (search != null && search.isNotEmpty) {
      query = query.ilike('name', '%$search%');
    }
    final rows = await query.order('code');
    return rows
        .map<CodeName>((r) => CodeName(code: r['code'] as String, name: (r['name'] as String?) ?? (r['display_code'] as String?)))
        .toList();
  }

  Future<List<CodeName>> salesReps({String? search}) async {
    var query = supabase.from('sales_reps').select('rep_code, name');
    if (search != null && search.isNotEmpty) {
      query = query.ilike('name', '%$search%');
    }
    final rows = await query.order('name');
    return rows.map<CodeName>((r) => CodeName.fromMap(r, codeKey: 'rep_code')).toList();
  }

  Future<List<CodeName>> customers({String? search}) async {
    var query = supabase.from('customers').select('code, name');
    if (search != null && search.isNotEmpty) {
      query = query.ilike('name', '%$search%');
    }
    final rows = await query.order('name').limit(200);
    return rows.map<CodeName>((r) => CodeName.fromMap(r, codeKey: 'code')).toList();
  }

  Future<List<CodeName>> categories({String? search}) async {
    var query = supabase.from('categories').select('department_code, name');
    if (search != null && search.isNotEmpty) {
      query = query.ilike('name', '%$search%');
    }
    final rows = await query.order('name');
    return rows.map<CodeName>((r) => CodeName.fromMap(r, codeKey: 'department_code')).toList();
  }

  Future<List<CodeName>> items({String? search}) async {
    var query = supabase.from('items').select('code, name');
    if (search != null && search.isNotEmpty) {
      query = query.ilike('name', '%$search%');
    }
    final rows = await query.order('name').limit(200);
    return rows.map<CodeName>((r) => CodeName.fromMap(r, codeKey: 'code')).toList();
  }

  /// Picker list for a given dimension — used anywhere a screen needs "every
  /// entity for this dimension" (Sales by / Budgets' entity list, Performance's
  /// name lookup), so that switching keeps this one place instead of a
  /// per-screen switch statement.
  Future<List<CodeName>> entitiesFor(SalesDimension dimension, {String? search}) {
    switch (dimension) {
      case SalesDimension.salesPerson:
        return salesReps(search: search);
      case SalesDimension.customer:
        return customers(search: search);
      case SalesDimension.item:
        return items(search: search);
      case SalesDimension.category:
        return categories(search: search);
      case SalesDimension.branch:
        return branches(search: search);
    }
  }

  Future<Map<String, String>> namesFor(SalesDimension dimension) async {
    final list = await entitiesFor(dimension);
    return {for (final c in list) c.code: c.displayLabel};
  }

  /// Which `dimension` entity codes have at least one matching row under
  /// every OTHER currently active global filter — schema/017, Craig
  /// 2026-09-01: "If I filter on an Item and then I look up Customer in the
  /// Customer Filter, I should only be able to select a customer who has
  /// purchased that item... greyed out." Returns null (not an empty set)
  /// when no OTHER filter is active — including `dimension`'s own current
  /// selection, which is deliberately ignored here, same reasoning
  /// fn_dimension_filter_options' own doc comment gives: picking a NEW
  /// Customer shouldn't be constrained by whichever Customer is already
  /// active — so callers can tell "don't grey anything out" apart from "grey
  /// out, but this particular call happened to match everything."
  Future<Set<String>?> filterOptionCodes(SalesDimension dimension, GlobalFilters filters) async {
    final hasOtherEntityFilter = SalesDimension.values.any((d) => d != dimension && filters.forDimension(d) != null);
    if (!hasOtherEntityFilter && filters.fiscalYear == null && filters.fiscalMonth == null) return null;

    final rows = await supabase.rpc('fn_dimension_filter_options', params: {
      'p_dimension': dimension.dbValue,
      'p_fiscal_year': filters.fiscalYear,
      'p_fiscal_month': filters.fiscalMonth,
      'p_filter_sales_person': dimension == SalesDimension.salesPerson ? null : filters.salesPerson?.code,
      'p_filter_customer': dimension == SalesDimension.customer ? null : filters.customer?.code,
      'p_filter_item': dimension == SalesDimension.item ? null : filters.item?.code,
      'p_filter_category': dimension == SalesDimension.category ? null : filters.category?.code,
      'p_filter_branch': dimension == SalesDimension.branch ? null : filters.branch?.code,
    });
    return (rows as List).map<String>((r) => r['entity_code'] as String).toSet();
  }

  /// Top-bar search (Craig, 2026-08-26: "search on the dimensions, then
  /// display the context for the user to choose") — queries every dimension
  /// by name in parallel and returns each match tagged with which dimension
  /// it came from, so the dropdown can show "Acme Corp — Customer" rather
  /// than a bare name a user has no way to disambiguate from an item or
  /// branch that happens to share a word. Capped at 6 per dimension (30
  /// max total) — this is a quick jump-to-entity lookup, not a full search
  /// results page.
  Future<List<DimensionSearchResult>> searchAllDimensions(String query) async {
    if (query.trim().isEmpty) return [];
    final byDimension = await Future.wait(SalesDimension.values.map((d) => entitiesFor(d, search: query)));
    final results = <DimensionSearchResult>[];
    for (var i = 0; i < SalesDimension.values.length; i++) {
      for (final entity in byDimension[i].take(6)) {
        results.add(DimensionSearchResult(dimension: SalesDimension.values[i], entity: entity));
      }
    }
    return results;
  }

  /// Document-number search for the top bar (2026-08-26, Craig: "Include
  /// Document in Top Bar search") — looks up `v_sales_documents` directly
  /// rather than through `entitiesFor`, since a document number isn't one of
  /// the 5 dimension tables that feeds. That view is line-level (one row per
  /// document LINE, not per document — schema/001 Section 9), so a single
  /// document number can come back many times; over-fetches (50) and dedupes
  /// client-side down to 6 distinct documents, matching the per-dimension
  /// cap searchAllDimensions already uses, rather than trying to express
  /// "distinct" in the query itself.
  Future<List<DocumentSearchResult>> searchDocuments(String query) async {
    if (query.trim().isEmpty) return [];
    final rows = await supabase.from('v_sales_documents').select('document, document_kind').ilike('document', '%$query%').limit(50);
    final seen = <String>{};
    final results = <DocumentSearchResult>[];
    for (final r in rows) {
      final document = r['document'] as String;
      final documentKind = r['document_kind'] as String;
      if (!seen.add('$documentKind|$document') || results.length >= 6) continue;
      results.add(DocumentSearchResult(document: document, documentKind: documentKind));
    }
    return results;
  }
}
