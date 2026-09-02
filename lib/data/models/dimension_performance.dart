/// Mirrors one row of v_dimension_performance (schema/002 Section 3) — feeds
/// the Performance screen template directly; no client-side math needed
/// beyond formatting, all three ratios are already computed in SQL.
class DimensionPerformance {
  final String dimension;
  final String entityCode;
  final int fiscalYear;
  final String fiscalMonth;
  final num actualValue;
  final num actualQuantity;
  final num actualProfit;
  final num gpPercent;
  final num? targetValue;
  final num? targetPercent;
  final num? contributionPercent;
  final num? forecastValue;
  final String? forecastConfidence; // full | partial | low

  const DimensionPerformance({
    required this.dimension,
    required this.entityCode,
    required this.fiscalYear,
    required this.fiscalMonth,
    required this.actualValue,
    required this.actualQuantity,
    required this.actualProfit,
    required this.gpPercent,
    this.targetValue,
    this.targetPercent,
    this.contributionPercent,
    this.forecastValue,
    this.forecastConfidence,
  });

  factory DimensionPerformance.fromMap(Map<String, dynamic> map) {
    return DimensionPerformance(
      dimension: map['dimension'] as String,
      // See DimensionMonthlySales.fromMap's matching comment — same
      // defense-in-depth fallback, same 'UNASSIGNED' sentinel schema/024
      // now guarantees at the source (2026-09-02).
      entityCode: (map['entity_code'] as String?) ?? 'UNASSIGNED',
      fiscalYear: map['fiscal_year'] as int,
      fiscalMonth: map['fiscal_month'] as String,
      actualValue: map['actual_value'] as num,
      actualQuantity: map['actual_quantity'] as num,
      actualProfit: map['actual_profit'] as num,
      gpPercent: map['gp_percent'] as num,
      targetValue: map['target_value'] as num?,
      targetPercent: map['target_percent'] as num?,
      contributionPercent: map['contribution_percent'] as num?,
      forecastValue: map['forecast_value'] as num?,
      forecastConfidence: map['forecast_confidence'] as String?,
    );
  }
}
