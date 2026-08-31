/// Mirrors one row of v_consolidated_sales (schema/001 Section 9) — the
/// simplest possible overall monthly rollup, used by Sales Analysis' Graph
/// tab for the whole-company trend (see that screen for why this is used
/// instead of v_dimension_monthly_sales there).
class ConsolidatedSales {
  final int fiscalYear;
  final DateTime month;
  final num quantity;
  final num value;
  final num profit;

  const ConsolidatedSales({
    required this.fiscalYear,
    required this.month,
    required this.quantity,
    required this.value,
    required this.profit,
  });

  factory ConsolidatedSales.fromMap(Map<String, dynamic> map) {
    return ConsolidatedSales(
      fiscalYear: map['fiscal_year'] as int,
      month: DateTime.parse(map['month'] as String),
      quantity: map['quantity'] as num,
      value: map['value'] as num,
      profit: map['profit'] as num,
    );
  }
}
