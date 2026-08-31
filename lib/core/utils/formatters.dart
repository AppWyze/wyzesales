import 'package:intl/intl.dart';

/// Rand currency, no decimals for large summary figures — matches the "R
/// Value"/"R Gross Profit"/"R Target" labelling seen throughout the old
/// screens (Wyzesales_Screens_and_Recommendations.md Section 1).
///
/// 'en_US', not 'en_ZA' — Craig, 2026-08-26: "All numbers must have a
/// thousand separator." They already did: en_ZA groups thousands with a
/// space (the standard South African convention, e.g. "R 1 234 567"), which
/// IS a real separator, just one that reads as no separator at all next to
/// the space already between the "R" symbol and the digits. Switching the
/// grouping locale to en_US keeps everything else about these formats the
/// same (still "R " prefix, still no decimals for the summary format) but
/// makes the separator an unambiguous comma ("R 1,234,567").
final NumberFormat _randFormat = NumberFormat.currency(locale: 'en_US', symbol: 'R ', decimalDigits: 0);
final NumberFormat _randFormatPrecise = NumberFormat.currency(locale: 'en_US', symbol: 'R ', decimalDigits: 2);
final NumberFormat _qtyFormat = NumberFormat.decimalPattern('en_US');

String formatRand(num? value, {bool precise = false}) {
  if (value == null) return '—';
  return precise ? _randFormatPrecise.format(value) : _randFormat.format(value);
}

String formatQuantity(num? value) {
  if (value == null) return '—';
  return _qtyFormat.format(value);
}

String formatPercent(num? value, {int decimals = 1}) {
  if (value == null) return '—';
  return '${value.toStringAsFixed(decimals)}%';
}

/// Variance % between two comparable period totals — used on YTD Comparative
/// and Sales by [Dimension] (year-over-year and month-over-month columns).
/// Returns null when there's nothing meaningful to divide by, so the UI can
/// render '—' instead of a misleading infinite/undefined swing.
double? variancePercent(num? current, num? previous) {
  if (current == null || previous == null || previous == 0) return null;
  return ((current - previous) / previous.abs()) * 100;
}

/// `numerator / denominator * 100`, or null when there's nothing meaningful
/// to divide by — the same "return null, let the UI render '—'" convention
/// as [variancePercent], reused for straightforward ratio KPIs (GP margin,
/// Quote → Order Conversion, Top 5 Customer Concentration) rather than each
/// call site guarding a zero denominator its own way. 2026-08-27, added for
/// the Dashboard's new KPI tiles — Craig asked directly how these behave at
/// the start of a new month, when the denominator can genuinely be zero
/// (nothing sold/quoted yet): this makes that render as "—", not a
/// misleading 0% or a divide-by-zero.
double? ratioPercent(num? numerator, num? denominator) {
  if (numerator == null || denominator == null || denominator == 0) return null;
  return (numerator / denominator) * 100;
}
