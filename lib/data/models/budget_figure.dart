/// Mirrors one row of budget_figures (schema/001 Section 4) — the only
/// user-editable data in this whole app (everything else is extracted or
/// computed). Value-only: BudgetQ/BudgetP in the legacy DB are confirmed
/// unused, per Wyzesales_Rebuild_Decisions.md.
class BudgetFigure {
  final String dimension;
  final String entityCode;
  final String fiscalMonth;
  final num budgetValue;
  final DateTime updatedAt;

  const BudgetFigure({
    required this.dimension,
    required this.entityCode,
    required this.fiscalMonth,
    required this.budgetValue,
    required this.updatedAt,
  });

  factory BudgetFigure.fromMap(Map<String, dynamic> map) {
    return BudgetFigure(
      dimension: map['dimension'] as String,
      entityCode: map['entity_code'] as String,
      fiscalMonth: map['fiscal_month'] as String,
      budgetValue: map['budget_value'] as num,
      updatedAt: DateTime.parse(map['updated_at'] as String),
    );
  }
}
