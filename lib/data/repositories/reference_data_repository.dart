import '../../core/constants/fiscal.dart';
import '../../core/filters/global_filters.dart';
import '../../core/supabase/supabase_config.dart';
import '../models/client_dimension_config.dart';
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

  /// `assignedRepCode`, when given, narrows this to customers whose
  /// `assigned_rep_code` matches exactly — an additional filter ON TOP of
  /// whatever `customers_select` RLS already allows, never a widening of
  /// it. Added 2026-09-03 (Wyzesales_Rebuild_Decisions.md Section 71) for
  /// Budgets' Customer entity list specifically: a User's RLS-visible
  /// customer set (`fn_customer_visible_to_rep`, "assigned to me OR I've
  /// sold to them") is broader than the set they actually have a Budget
  /// figure for (`fn_customer_allocated_to_rep`, "assigned to me only" —
  /// migration 031), so without this a User could pick a customer here and
  /// see nothing but blank figures. Every other caller leaves this null and
  /// gets the exact same unfiltered-beyond-RLS list as before — this is
  /// additive, not a change to the default.
  Future<List<CodeName>> customers({String? search, String? assignedRepCode}) async {
    var query = supabase.from('customers').select('code, name');
    if (assignedRepCode != null) {
      query = query.eq('assigned_rep_code', assignedRepCode);
    }
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
  ///
  /// `customerAssignedRepCode` only ever affects the `customer` branch — see
  /// `customers()`'s own doc comment. Left null by every caller except
  /// Budgets' entity list, which is the one place the RLS-visible customer
  /// set and the customer's actual assigned rep can legitimately diverge.
  Future<List<CodeName>> entitiesFor(SalesDimension dimension, {String? search, String? customerAssignedRepCode}) {
    switch (dimension) {
      case SalesDimension.salesPerson:
        return salesReps(search: search);
      case SalesDimension.customer:
        return customers(search: search, assignedRepCode: customerAssignedRepCode);
      case SalesDimension.item:
        return items(search: search);
      case SalesDimension.category:
        return categories(search: search);
      case SalesDimension.branch:
        return branches(search: search);
      // 2026-09-02: `company` has no reference-data table of its own (there's
      // only ever one "entity" — the whole company) — so unlike the other 5
      // branches above, this doesn't query anything. Returns the single
      // synthetic row `v_dimension_monthly_sales`/budget_figures/
      // sales_forecast already use for it (schema/002/001: `entity_code =
      // 'ALL'`), letting `namesFor`/Budgets' entity list work for `company`
      // with no special-casing needed at either call site. `search` isn't
      // wired to anything here, but this is harmless in practice —
      // `searchAllDimensions` below deliberately excludes `company` (via
      // `SalesDimension.filterable`) from the only call site that ever
      // passes a real search term.
      case SalesDimension.company:
        return Future.value(const [CodeName(code: 'ALL', name: 'Company')]);
    }
  }

  /// 2026-09-02, schema/024: `v_sales_documents` now coalesces an
  /// unattributed line's Sales Person/Branch/Category code to the literal
  /// 'UNASSIGNED' rather than leaving it null (Craig, checking whether
  /// Revenue reconciles across every dimension: "Yes please" to hardening
  /// this). That sentinel deliberately never appears in `sales_reps`/
  /// `branches`/`categories`, so on its own it would just fall back to
  /// showing the raw code (Sales by/Performance's own `data.names[code] ??
  /// code`) — functional, but a bit rough. Injected here, not in
  /// `entitiesFor` itself, so it shows up wherever a row's own label is
  /// looked up (Sales by, Performance) WITHOUT also appearing as a pickable
  /// entity in Budgets' entity list (`entitiesFor` is what that screen
  /// queries directly) — there's nothing meaningful to set a target against
  /// for "sales with no rep/branch/category attached." Customer and Item are
  /// deliberately excluded: `sales_document_facts.account_code`/`.item_code`
  /// are NOT NULL, so this sentinel can never actually occur on either.
  Future<Map<String, String>> namesFor(SalesDimension dimension) async {
    final list = await entitiesFor(dimension);
    final names = {for (final c in list) c.code: c.displayLabel};
    const canBeUnassigned = {SalesDimension.salesPerson, SalesDimension.branch, SalesDimension.category};
    if (canBeUnassigned.contains(dimension)) names['UNASSIGNED'] = 'Unassigned';
    return names;
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
    final hasOtherEntityFilter = SalesDimension.filterable.any((d) => d != dimension && filters.forDimension(d) != null);
    if (!hasOtherEntityFilter && filters.fiscalYear == null && filters.fiscalMonth == null) return null;

    final rows = await supabase.rpc('fn_dimension_filter_options', params: {
      'p_dimension': dimension.dbValue,
      'p_fiscal_year': filters.fiscalYear,
      'p_fiscal_month': filters.fiscalMonth,
      'p_filters': filters.toFilterParams(excludeDimensionKey: dimension.dbValue),
    });
    return (rows as List).map<String>((r) => r['entity_code'] as String).toSet();
  }

  /// This client's configured Sales Analysis dimensions (client_dimensions,
  /// schema/038) — GlobalFilterBar's chips/"Add filter" dropdown source their
  /// dimension list from here now instead of the hardcoded
  /// `SalesDimension.filterable` (2026-09-05, multi-tenant dimension model
  /// Step 2). Ordered by `sort_order` — WCSA's own seed matches
  /// `SalesDimension.filterable`'s previous declared order exactly, so this
  /// is a zero-behaviour-change swap for WCSA today; RLS (schema/038 Section
  /// 3) already scopes this to the caller's own `client_id` with no filter
  /// needed here.
  Future<List<ClientDimensionConfig>> clientDimensions() async {
    final rows = await supabase.from('client_dimensions').select().order('sort_order');
    return rows.map<ClientDimensionConfig>((r) => ClientDimensionConfig.fromMap(r)).toList();
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
    // `filterable`, not `values` — 2026-09-02, once `company` became a real
    // SalesDimension (Section 57): picking a search result calls
    // `notifier.setDimension(result.dimension.dbValue, ...)` (top_bar_search.dart),
    // the exact same global-filter mechanism GlobalFilterBar's "Add filter"
    // dropdown uses — and `company` is deliberately excluded from that
    // everywhere else (`SalesDimension.filterable`'s own doc comment), so
    // it's excluded from this search too rather than surfacing a result that
    // would silently do nothing when picked.
    const dimensions = SalesDimension.filterable;
    final byDimension = await Future.wait(dimensions.map((d) => entitiesFor(d, search: query)));
    final results = <DimensionSearchResult>[];
    for (var i = 0; i < dimensions.length; i++) {
      for (final entity in byDimension[i].take(6)) {
        results.add(DimensionSearchResult(dimension: dimensions[i], entity: entity));
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
  ///
  /// Scoped to invoice/credit_note — 2026-09-02, task #93: Quote Analysis
  /// and Sales Order Analysis were removed (Wyzesales_Rebuild_Decisions.md
  /// Section 55), and Sales Analysis (the only screen a document result can
  /// still land on) only ever shows those two kinds anyway. Surfacing a
  /// quote/sales-order document match here would route to a screen that
  /// silently shows nothing for it.
  Future<List<DocumentSearchResult>> searchDocuments(String query) async {
    if (query.trim().isEmpty) return [];
    final rows = await supabase
        .from('v_sales_documents')
        .select('document, document_kind')
        .inFilter('document_kind', ['invoice', 'credit_note'])
        .ilike('document', '%$query%')
        .limit(50);
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
