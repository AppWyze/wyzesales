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
      // 2026-09-02: `as String?` + fallback, not the bare `as String` this
      // used to be — schema/024 now coalesces a null entity_code (an
      // unattributed sale — no rep, no warehouse, or no category mapped) to
      // the literal 'UNASSIGNED' at the source, so this should never
      // actually see a null any more. Kept as defense in depth regardless: a
      // bare `as String` cast used to mean a single row like that would
      // throw and fail this ENTIRE fetch, not just miscount one row — Craig
      // asked whether Revenue reconciles across every dimension, and
      // checking that surfaced this as a real (if rare) crash risk. Matches
      // schema/024's own sentinel exactly, and `reference_data_repository
      // .dart`'s `namesFor` maps it to the friendlier "Unassigned" label.
      entityCode: (map['entity_code'] as String?) ?? 'UNASSIGNED',
      month: DateTime.parse(map['month'] as String),
      fiscalYear: map['fiscal_year'] as int,
      fiscalMonth: map['fiscal_month'] as String,
      quantity: map['quantity'] as num,
      value: map['value'] as num,
      profit: map['profit'] as num,
    );
  }
}
