/// Mirrors one row of v_active_alerts (schema/034_wyzesales_proactive_alerts.sql,
/// 2026-09-04, Item 3 of the post-forecast-deploy roadmap — Decisions doc
/// Section 74/77). Feeds the top-bar notification bell (Craig's own choice,
/// AskUserQuestion) — every row here is, by construction, a condition that's
/// currently true for the signed-in user's client, right now, for the
/// CURRENT fiscal month; there's no "dismissed"/"read" state in the schema at
/// all, so a resolved condition (budget caught up, GP% back to positive) just
/// stops appearing here on the next read rather than needing to be
/// acknowledged.
///
/// Two `alertType`s, distinguished by which of `budgetValue`/`expectedToDate`
/// are populated (both null for `negative_gp`, both set for
/// `budget_variance` — see the migration's own header for why):
/// - `budget_variance`: month-to-date `actualValue` is `metricPercent`% below
///   the prorated `expectedToDate` slice of `budgetValue` (see the
///   migration's header for the day-of-month proration) — `metricPercent` is
///   always <= 0 here, e.g. -22.5 means "22.5% behind pace."
/// - `negative_gp`: month-to-date GP% (`metricPercent`) is negative —
///   `budgetValue`/`expectedToDate` are always null for this type, since it
///   has no budget comparison at all.
class ActiveAlert {
  final String dimension; // one of SalesDimension's dbValue strings
  final String entityCode;
  final int fiscalYear;
  final String fiscalMonth;
  final String alertType; // 'budget_variance' | 'negative_gp'
  final num actualValue;
  final num? budgetValue;
  final num? expectedToDate;
  final num metricPercent;

  const ActiveAlert({
    required this.dimension,
    required this.entityCode,
    required this.fiscalYear,
    required this.fiscalMonth,
    required this.alertType,
    required this.actualValue,
    this.budgetValue,
    this.expectedToDate,
    required this.metricPercent,
  });

  factory ActiveAlert.fromMap(Map<String, dynamic> map) {
    return ActiveAlert(
      dimension: map['dimension'] as String,
      // Same defense-in-depth fallback DimensionPerformance.fromMap/
      // DimensionMonthlySales.fromMap already use — schema/024's
      // 'UNASSIGNED' sentinel should always be there in practice, but this
      // model shouldn't crash the notification bell if it's ever missing.
      entityCode: (map['entity_code'] as String?) ?? 'UNASSIGNED',
      fiscalYear: map['fiscal_year'] as int,
      fiscalMonth: map['fiscal_month'] as String,
      alertType: map['alert_type'] as String,
      actualValue: map['actual_value'] as num,
      budgetValue: map['budget_value'] as num?,
      expectedToDate: map['expected_to_date'] as num?,
      metricPercent: map['metric_percent'] as num,
    );
  }

  bool get isBudgetVariance => alertType == 'budget_variance';
  bool get isNegativeGp => alertType == 'negative_gp';
}
