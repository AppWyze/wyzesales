/// Mirrors one row of v_sales_documents (schema/001 Section 9) — feeds the
/// Sales Analysis Table tab, Quote Analysis, and Sales Order Analysis
/// screens (filtered by documentKind).
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
    );
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
