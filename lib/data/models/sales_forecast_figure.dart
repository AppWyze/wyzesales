/// Mirrors one row of sales_forecast (schema/001 Section 4) — the fallback
/// figure `core/utils/target_overlay.dart`'s `resolveTarget` reads whenever
/// a real `budget_figures` value doesn't exist for a (dimension,
/// entity_code, fiscal_month), per schema/021's own `coalesce(nullif(
/// budget_value, 0), forecast_value)` definition of "target." Deliberately
/// mirrors `BudgetFigure`'s shape (dimension/entityCode/fiscalMonth/value)
/// — see that model's own doc comment for why sales_forecast, like
/// budget_figures, carries no fiscal_year column at all.
class SalesForecastFigure {
  final String dimension;
  final String entityCode;
  final String fiscalMonth;
  final num forecastValue;

  const SalesForecastFigure({
    required this.dimension,
    required this.entityCode,
    required this.fiscalMonth,
    required this.forecastValue,
  });

  factory SalesForecastFigure.fromMap(Map<String, dynamic> map) {
    return SalesForecastFigure(
      dimension: map['dimension'] as String,
      entityCode: map['entity_code'] as String,
      fiscalMonth: map['fiscal_month'] as String,
      forecastValue: map['forecast_value'] as num,
    );
  }
}
