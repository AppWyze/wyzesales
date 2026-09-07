import 'client_dimension_config.dart';

/// Mirrors one row of v_sales_documents (schema/001 Section 9) — feeds the
/// Sales Analysis Table tab, Quote Analysis, and Sales Order Analysis
/// screens (filtered by documentKind).
///
/// 2026-09-07 (migration 050): gained the 24 generic dim_1..dim_12/
/// attr_1..attr_12 passthrough values fn_sales_documents_page now returns
/// alongside the five original named dimensions — see that migration's own
/// header comment for why Document Analysis needed its own follow-up rather
/// than reusing the cube's fn_cube_dimension_value/DimensionMonthlySales
/// generalization directly (this view's five 'existing' dimensions use their
/// own native column names, not the cube's renamed convention). `codeFor`/
/// `displayFor` below are this class's own equivalent of that same
/// resolution, so document_analysis_view.dart's table can render whichever
/// dimensions THIS client actually has configured (client_dimensions),
/// exactly the way Sales By/Performance/Budgets already do via
/// ClientDimensionConfig.asSalesDimension + ReferenceDataRepository.
/// namesForConfig — rather than the previous fixed Sales Person/Branch/
/// Category/Item/Customer column set that only ever matched WCSA.
class SalesDocument {
  final String documentKind; // invoice | credit_note | quote | sales_order
  final String document;
  final DateTime docDate;
  final int fiscalYear;
  final String accountCode;
  final String? customerName;
  final String? resolvedRepCode;
  final String? resolvedRepName;
  final String? branchCode;
  final String? branchDisplayCode;
  final String? branchName;
  final String itemCode;
  final String? itemName;
  final String? departmentCode;
  final String? categoryName;
  final num quantity;
  final num value;
  final num cost;
  final num profit;
  final num profitPercent;

  /// Index 0 = dim_1_code .. index 11 = dim_12_code (migration 039).
  final List<String?> dimCodes;

  /// Index 0 = attr_1_code .. index 11 = attr_12_code (migration 039).
  final List<String?> attrCodes;

  const SalesDocument({
    required this.documentKind,
    required this.document,
    required this.docDate,
    required this.fiscalYear,
    required this.accountCode,
    this.customerName,
    this.resolvedRepCode,
    this.resolvedRepName,
    this.branchCode,
    this.branchDisplayCode,
    this.branchName,
    required this.itemCode,
    this.itemName,
    this.departmentCode,
    this.categoryName,
    required this.quantity,
    required this.value,
    required this.cost,
    required this.profit,
    required this.profitPercent,
    this.dimCodes = const [],
    this.attrCodes = const [],
  });

  factory SalesDocument.fromMap(Map<String, dynamic> map) {
    return SalesDocument(
      documentKind: map['document_kind'] as String,
      document: map['document'] as String,
      docDate: DateTime.parse(map['doc_date'] as String),
      fiscalYear: map['fiscal_year'] as int,
      accountCode: map['account_code'] as String,
      customerName: map['customer_name'] as String?,
      resolvedRepCode: map['resolved_rep_code'] as String?,
      resolvedRepName: map['resolved_rep_name'] as String?,
      branchCode: map['branch_code'] as String?,
      branchDisplayCode: map['branch_display_code'] as String?,
      branchName: map['branch_name'] as String?,
      itemCode: map['item_code'] as String,
      itemName: map['item_name'] as String?,
      departmentCode: map['department_code'] as String?,
      categoryName: map['category_name'] as String?,
      quantity: map['quantity'] as num,
      value: map['value'] as num,
      cost: map['cost'] as num,
      profit: map['profit'] as num,
      profitPercent: map['profit_percent'] as num,
      dimCodes: [for (var i = 1; i <= 12; i++) map['dim_${i}_code'] as String?],
      attrCodes: [for (var i = 1; i <= 12; i++) map['attr_${i}_code'] as String?],
    );
  }

  /// This row's raw code for `dim` — whichever column actually applies for
  /// this client's own resolution_kind, per dimension_key ('sales_person',
  /// 'dim_5', ...). Null when this row has no value for that dimension.
  String? codeFor(ClientDimensionConfig dim) {
    switch (dim.dimensionKey) {
      case 'company':
        return 'ALL';
      case 'sales_person':
        return resolvedRepCode;
      case 'customer':
        return accountCode;
      case 'item':
        return itemCode;
      case 'category':
        return departmentCode;
      case 'branch':
        return branchCode;
      default:
        final index = int.parse(dim.dimensionKey.substring(4)) - 1;
        return dim.resolutionKind == 'customer_attribute' ? attrCodes[index] : dimCodes[index];
    }
  }

  /// This row's best display label for `dim` — the coalesced display name
  /// already carried on the row for one of the five 'existing' dimensions
  /// (matching the Flutter table's pre-existing coalesce('','') convention),
  /// or (for a generic dim_N/attr_N dimension) `names[code]` resolved via
  /// `ReferenceDataRepository.namesForConfig` if the caller has one, falling
  /// back to the raw code — same "don't block on a missing name" convention
  /// Sales By/Performance already use. `null`/`'—'` when this row has no
  /// value for the dimension at all.
  String displayFor(ClientDimensionConfig dim, Map<String, String> names) {
    switch (dim.dimensionKey) {
      case 'sales_person':
        return resolvedRepName ?? resolvedRepCode ?? '—';
      case 'customer':
        return customerName ?? accountCode;
      case 'item':
        return itemName ?? itemCode;
      case 'category':
        return categoryName ?? departmentCode ?? '—';
      case 'branch':
        return branchDisplayCode ?? branchCode ?? '—';
      default:
        final code = codeFor(dim);
        if (code == null) return '—';
        return names[code] ?? code;
    }
  }
}

/// The Totals row's real source of truth once a table is paginated — summed
/// server-side over EVERY row matching the current filters via
/// `fn_sales_documents_totals` (schema/012), not just whichever page is on
/// screen. `gpPercent` isn't returned by that function; callers recompute it
/// as `profit / value * 100` themselves, matching every other totals row in
/// the app (Wyzesales_Rebuild_Decisions.md Section 19e — recompute derived
/// ratios from the summed base figures, never average each row's own
/// ratio).
class SalesDocumentTotals {
  final int count;
  final num quantity;
  final num value;
  final num profit;
  const SalesDocumentTotals({required this.count, required this.quantity, required this.value, required this.profit});

  num? get gpPercent => value == 0 ? null : (profit / value) * 100;

  factory SalesDocumentTotals.fromMap(Map<String, dynamic> map) {
    return SalesDocumentTotals(
      count: map['total_count'] as int,
      quantity: map['total_quantity'] as num,
      value: map['total_value'] as num,
      profit: map['total_profit'] as num,
    );
  }
}
