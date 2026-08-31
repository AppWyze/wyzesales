/// Mirrors one row of v_dimension_monthly_sales (schema/002 Section 2) — the
/// shared tidy rollup behind Sales Analysis' Graph tab, YTD Comparative, and
/// Sales by [Dimension]. One row per dimension/entity/month.
class DimensionMonthlySales {
  final String dimension;
  final String entityCode;
  final DateTime month;
  final int fiscalYear;
  final String fiscalMonth; // 'Mar'..'Feb'
  final num quantity;
  final num value;
  final num profit;

  const DimensionMonthlySales({
    required this.dimension,
    required this.entityCode,
    required this.month,
    required this.fiscalYear,
    required this.fiscalMonth,
    required this.quantity,
    required this.value,
    required this.profit,
  });

  factory DimensionMonthlySales.fromMap(Map<String, dynamic> map) {
    return DimensionMonthlySales(
      dimension: map['dimension'] as String,
      entityCode: map['entity_code'] as String,
      month: DateTime.parse(map['month'] as String),
      fiscalYear: map['fiscal_year'] as int,
      fiscalMonth: map['fiscal_month'] as String,
      quantity: map['quantity'] as num,
      value: map['value'] as num,
      profit: map['profit'] as num,
    );
  }
}
