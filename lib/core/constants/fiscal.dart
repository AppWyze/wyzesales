import 'package:intl/intl.dart';

/// The five report dimensions collapsed from 15 near-duplicate screens in the
/// old app into 3 parameterized templates (Sales by / Budgets / Performance)
/// — see Wyzesales_Screens_and_Recommendations.md Section 3 — plus `company`,
/// a 6th "dimension" wired in 2026-09-02 (Wyzesales_Rebuild_Decisions.md
/// Section 57). Craig, looking at Performance Analysis' dimension switcher:
/// "We can see all Dimensions except a Company wide Dimension???" `company`
/// had already existed at the schema level from day one
/// (budget_figures/sales_forecast/v_dimension_monthly_sales all allow it,
/// producing a single `entity_code = 'ALL'` row — the whole-company total,
/// no further breakdown) but was never exposed as a selectable option
/// anywhere in the UI.
///
/// `company` is deliberately placed LAST, not first — `SalesDimension.values
/// .first` is used a few places (app_shell.dart's nav "quick" routes) to mean
/// "the default/first real breakdown dimension," which must stay
/// `salesPerson`, unchanged from before this was added.
///
/// `company` is ONLY valid as something to VIEW (the Sales by / Budgets /
/// Performance dimension switchers, which all iterate `values` directly) —
/// it is deliberately excluded from anywhere this enum is used as something
/// to FILTER BY or RANK entities within (GlobalFilterBar's chips/"Add
/// filter" dropdown, the top-bar's cross-dimension entity search, the
/// Dashboard's ranking breakdown picker) via `SalesDimension.filterable`
/// below — "Company" isn't one of several entities you could narrow down to,
/// it already means "no narrowing at all," and there's nothing to rank
/// within a single whole-company total.
enum SalesDimension {
  salesPerson('sales_person', 'Sales Person'),
  category('category', 'Category'),
  customer('customer', 'Customer'),
  item('item', 'Item'),
  branch('branch', 'Branch'),
  company('company', 'Company');

  const SalesDimension(this.dbValue, this.label);

  /// The exact string stored in budget_figures.dimension / sales_forecast.dimension
  /// / v_dimension_monthly_sales.dimension — must match schema/001 and 002.
  final String dbValue;
  final String label;

  /// The 5 dimensions that make sense as a global filter TARGET (pick one
  /// specific entity to narrow everything down to) or as something to RANK
  /// entities within — excludes `company`. See this enum's own doc comment
  /// for the full reasoning. Used by GlobalFilterBar (its filter chips and
  /// "Add filter" dropdown), the top-bar's cross-dimension entity search,
  /// and the Dashboard's ranking breakdown picker — everywhere else
  /// (Sales by / Budgets / Performance's own dimension switchers) wants
  /// `values` directly, since those DO want to offer a Company-wide view.
  static const List<SalesDimension> filterable = [salesPerson, category, customer, item, branch];
}

/// All 12 calendar month abbreviations in plain calendar (Jan->Dec) order —
/// the fixed base `fiscalMonthOrderFor` rotates from. Not meant to be used
/// directly outside this file; every caller wants the rotated, fiscal-order
/// list below instead.
const List<String> _calendarMonthAbbreviations = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// Fiscal month labels in fiscal order, rotated to start at `startMonth` —
/// e.g. startMonth=3 (March, the old hardcoded default) gives
/// ['Mar','Apr',...,'Jan','Feb']; startMonth=1 gives the plain calendar year.
/// Replaces the old hardcoded `fiscalMonthOrder` constant now that
/// fiscal_year_settings.start_month is a real, per-client, Settings >
/// Company-editable value (2026-09-01, Craig: "We are assuming that a
/// Client's Financial Year runs from March to February but this will not
/// always be the case") rather than always March. Every call site that used
/// to reference that bare constant now calls this with the client's actual
/// start month — `ref.watch(fiscalYearStartMonthProvider).valueOrNull ?? 3`
/// (app_providers.dart) — falling back to 3 while that provider is still
/// loading, matching `fiscalYearFor`'s own default below and today's
/// pre-feature behaviour exactly.
List<String> fiscalMonthOrderFor({int startMonth = 3}) {
  final zeroBasedStart = startMonth - 1;
  return List<String>.generate(12, (i) => _calendarMonthAbbreviations[(zeroBasedStart + i) % 12]);
}

/// Client-side mirror of the fiscal_year() SQL function (schema/001 Section
/// 8, corrected by schema/022) — used for "which fiscal year is 'today' in"
/// on the Dashboard/filters. Whole-DB fiscal year overrides
/// (fiscal_year_settings.override_year) apply server-side only; this is just
/// for picking sensible default filter values.
///
/// A fiscal year is labelled by the calendar year its LAST month falls in
/// (e.g. a Mar-start fiscal year running Mar 2025 -> Feb 2026 is "FY2026").
/// For any startMonth from 2-12 that's `date.year + 1` once the date reaches
/// startMonth, `date.year` before it — the original, still-correct formula
/// below. startMonth=1 is the one case that formula got wrong: a Jan-start
/// fiscal year runs Jan Y -> Dec Y, ending in the SAME year Y it started in,
/// so it should just be `date.year`, unchanged all the way through. The old
/// unconditional `date.month >= startMonth ? date.year + 1 : date.year`
/// treated `date.month >= 1` as always true (every month is >= 1) and so
/// always took the +1 branch, mislabelling every date under a January fiscal
/// year one year ahead of where it actually falls. 2026-09-02, caught while
/// writing task #92's regression tests, confirmed with Craig before fixing
/// (no client was actually configured with startMonth=1 yet, so nothing live
/// was mislabelled) — fixed here and in fiscal_year() (schema/022) together,
/// since this function exists specifically to mirror that SQL one.
int fiscalYearFor(DateTime date, {int startMonth = 3}) {
  if (startMonth == 1) return date.year;
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
  final index = fiscalMonthOrderFor(startMonth: startMonth).indexOf(fiscalMonthLabel);
  if (index == -1) throw ArgumentError('Unknown fiscal month label: $fiscalMonthLabel');
  final calendarMonth = ((startMonth - 1 + index) % 12) + 1;
  final calendarYear = calendarMonth >= startMonth ? fiscalYear - 1 : fiscalYear;
  return DateTime(calendarYear, calendarMonth, 1);
}

/// The reverse of the mapping above: which fiscal month label (from
/// `fiscalMonthOrderFor`) a calendar date falls in. Fiscal months are just calendar months relabelled
/// (fiscal_month_label() in schema/002 stores the 3-letter calendar month
/// abbreviation, e.g. a March 2025 row is labelled 'Mar'), so this is a
/// plain `DateFormat('MMM')` — no fiscal-year arithmetic needed. Added
/// 2026-08-26 for the Dashboard's Sales Target chart, which needs to look up
/// budget_figures rows (keyed by fiscal_month label only, no fiscal_year
/// column) against v_consolidated_sales rows (keyed by calendar month).
String fiscalMonthLabelFor(DateTime date) => DateFormat('MMM').format(date);

/// Full month name for a 1-12 start-month value (e.g. 3 -> 'March') —
/// Settings > Company's own display/edit of fiscal_year_settings.start_month
/// wants a human label, not a bare number or the 3-letter abbreviation the
/// rest of this file works in.
String fiscalStartMonthName(int startMonth) => DateFormat('MMMM').format(DateTime(2000, startMonth));

/// The client's configured trailing fiscal-year window, oldest year first —
/// e.g. currentFy=2027, historyYears=3 -> [2025, 2026, 2027]. Replaces the
/// hardcoded `[currentFy - 2, currentFy - 1, currentFy]` literal every
/// "trailing N fiscal years" screen (Sales Analysis' Graph tab, Sales By,
/// YTD Comparative, the global filter bar's Year picker) used to build
/// directly, now that fiscal_year_settings.history_years (Settings >
/// Company, 2026-09-01, schema/020, Craig: "either 3 or 5 years of data")
/// can be 3 or 5, not always 3. `ref.watch(fiscalYearHistoryYearsProvider)
/// .valueOrNull ?? 3` (app_providers.dart) is the standard way to get
/// `historyYears` at each of those call sites, same fallback convention
/// `fiscalYearStartMonthProvider` already established.
List<int> fiscalYearWindow(int currentFy, int historyYears) =>
    List<int>.generate(historyYears, (i) => currentFy - (historyYears - 1) + i);
