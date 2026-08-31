import 'package:intl/intl.dart';

/// The five report dimensions collapsed from 15 near-duplicate screens in the
/// old app into 3 parameterized templates (Sales by / Budgets / Performance)
/// — see Wyzesales_Screens_and_Recommendations.md Section 3. 'company' exists
/// in the schema (budget_figures/sales_forecast/v_dimension_monthly_sales all
/// allow it) but isn't wired into a picker here yet — still an open question
/// in Wyzesales_Rebuild_Decisions.md whether it's needed on any screen.
enum SalesDimension {
  salesPerson('sales_person', 'Sales Person'),
  category('category', 'Category'),
  customer('customer', 'Customer'),
  item('item', 'Item'),
  branch('branch', 'Branch');

  const SalesDimension(this.dbValue, this.label);

  /// The exact string stored in budget_figures.dimension / sales_forecast.dimension
  /// / v_dimension_monthly_sales.dimension — must match schema/001 and 002.
  final String dbValue;
  final String label;
}

/// Fiscal year runs March -> February, matching fiscal_year_settings.start_month
/// default (3) and the fiscal_month_label() SQL function in schema/002. Kept
/// as an ordered list (not alphabetical) so the Budgets/Performance screens
/// can lay columns out in fiscal order without re-deriving it in the UI.
const List<String> fiscalMonthOrder = [
  'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec', 'Jan', 'Feb',
];

/// Client-side mirror of the fiscal_year() SQL function (schema/001 Section
/// 8) — used for "which fiscal year is 'today' in" on the Dashboard/filters.
/// Whole-DB fiscal year overrides (fiscal_year_settings.override_year) apply
/// server-side only; this is just for picking sensible default filter values.
int fiscalYearFor(DateTime date, {int startMonth = 3}) {
  return date.month >= startMonth ? date.year + 1 : date.year;
}

DateTime firstOfMonth(DateTime date) => DateTime(date.year, date.month, 1);

/// The calendar first-of-month for a given fiscal year + fiscal month label
/// (e.g. fiscalYear=2026, 'Jun' -> 2025-06-01, since FY2026 runs Mar 2025 ->
/// Feb 2026 under the Mar-start default) — mirrors fiscal_year()/
/// fiscal_month_label()'s mapping (schema/001 Section 8, schema/002 Section
/// 1) used server-side. Needed client-side only for the global Month filter
/// (2026-08-26) on the line-level detail screens (Sales Analysis' Table tab
/// / Quote Analysis / Sales Order Analysis), which read v_sales_documents
/// directly and have no fiscal_month column to filter on — a calendar
/// doc_date range is the only way to narrow those to one fiscal month.
DateTime calendarMonthStartFor(int fiscalYear, String fiscalMonthLabel, {int startMonth = 3}) {
  final index = fiscalMonthOrder.indexOf(fiscalMonthLabel);
  if (index == -1) throw ArgumentError('Unknown fiscal month label: $fiscalMonthLabel');
  final calendarMonth = ((startMonth - 1 + index) % 12) + 1;
  final calendarYear = calendarMonth >= startMonth ? fiscalYear - 1 : fiscalYear;
  return DateTime(calendarYear, calendarMonth, 1);
}

/// The reverse of the mapping above: which `fiscalMonthOrder` label a
/// calendar date falls in. Fiscal months are just calendar months relabelled
/// (fiscal_month_label() in schema/002 stores the 3-letter calendar month
/// abbreviation, e.g. a March 2025 row is labelled 'Mar'), so this is a
/// plain `DateFormat('MMM')` — no fiscal-year arithmetic needed. Added
/// 2026-08-26 for the Dashboard's Sales Target chart, which needs to look up
/// budget_figures rows (keyed by fiscal_month label only, no fiscal_year
/// column) against v_consolidated_sales rows (keyed by calendar month).
String fiscalMonthLabelFor(DateTime date) => DateFormat('MMM').format(date);
