namespace WyzeSalesExtract.Domain;

/// <summary>
/// Replaces the original script's repeated 12-way nested If(Month(Today())='Mar',24, ...)
/// chains with plain date arithmetic. The QVS uses a Mar-Feb fiscal year (a sale in
/// Mar 2025 through Feb 2026 is all "fiscal year 2026" - labelled by the calendar year
/// its Feb falls in). Wherever the original computed "how many months back from Today()
/// gets me to the start of the fiscal-window", that number was chosen purely so the
/// result always lands on 1 March. This class computes that directly instead.
///
/// IMPORTANT ASSUMPTION: $(CheckYear) is referenced in the SalesAnalysis section of the
/// original script but never defined in WCSA_Extract.txt itself - it must be set by a
/// parent/master QlikView document that includes this file. FiscalYearLabel(DateTime.Today)
/// below is the natural candidate (it's exactly how every transaction's own "Year" field
/// is labelled elsewhere in the same script), and the equivalence has been verified against
/// the original branching logic in SelfTest.Run(). Confirm against the master script if you
/// still have a copy - see README "Assumptions to verify".
/// </summary>
public static class FiscalDate
{
    /// <summary>
    /// The fiscal year label for a given date: Jan/Feb keep the calendar year, Mar-Dec
    /// roll forward to next calendar year. Mirrors Sales1's
    /// "If(Month &lt;&gt; 'Jan' and Month &lt;&gt; 'Feb', Year + 1, Year) as Year".
    /// </summary>
    public static int FiscalYearLabel(DateTime date) =>
        (date.Month == 1 || date.Month == 2) ? date.Year : date.Year + 1;

    /// <summary>
    /// The "current" fiscal year as of <paramref name="today"/> - stands in for the
    /// undefined $(CheckYear) variable (see class remarks / README).
    /// </summary>
    public static int CurrentFiscalYear(DateTime today) => FiscalYearLabel(today);

    /// <summary>
    /// Original nested-If month->N table (Mar=24 ... Dec=33, Jan=34, Feb=35), reproduced
    /// only so SelfTest can prove the replacement formula below is equivalent. Not used
    /// anywhere else in the program.
    /// </summary>
    internal static int OriginalMonthOffset(int month) => month switch
    {
        3 => 24, 4 => 25, 5 => 26, 6 => 27, 7 => 28, 8 => 29,
        9 => 30, 10 => 31, 11 => 32, 12 => 33, 1 => 34, 2 => 35,
        _ => throw new ArgumentOutOfRangeException(nameof(month))
    };

    /// <summary>
    /// The original computes MonthStart(AddMonths(Today(), -N)) using the offset table
    /// above, always exactly 3 fiscal years back. This is the same result when
    /// <paramref name="historyYears"/> is 3, derived directly: 1 March of
    /// (fiscal year - historyYears). Used for the TransactionWyzesales / QuotesAnalysis /
    /// SalesOrderAnalysis rolling sales-data window start date.
    ///
    /// historyYears is configurable (3 or 5) via Settings &gt; Company's "Data history
    /// window" (WCSA, 2026-09 - see fiscal_year_settings.history_years, schema/020, and
    /// SupabaseWriter.LoadDataHistoryYearsAsync, the value ExtractRunner passes in here) -
    /// it defaults to 3 so a caller that doesn't pass it reproduces the original QVS
    /// script's behaviour exactly (see SelfTest, which pins the 3-year default).
    /// </summary>
    public static DateTime FiscalYearWindowStart(DateTime today, int historyYears = 3) =>
        new DateTime(CurrentFiscalYear(today) - historyYears, 3, 1);

    /// <summary>First day of the month, N months before <paramref name="today"/>.</summary>
    public static DateTime MonthStart(DateTime today, int monthsBack) =>
        new DateTime(today.Year, today.Month, 1).AddMonths(-monthsBack);

    /// <summary>Last day of the month, N months before <paramref name="today"/>.</summary>
    public static DateTime MonthEnd(DateTime today, int monthsBack)
    {
        var start = MonthStart(today, monthsBack);
        return start.AddMonths(1).AddDays(-1);
    }

    /// <summary>
    /// Which fiscal year bucket the "N months back from today" figure in SalesAnalysis
    /// belongs to (QVS lines 364-416, Map_ValMth1-3 / Map_PftMth1-3). This is NOT the same
    /// as FiscalYearLabel(MonthStart(today, monthsBack)) - the original hand-writes this as
    /// a branch on CheckYear rather than computing each target month's own fiscal label, and
    /// the two disagree in one specific case: when the run date itself is in February and
    /// monthsBack=1 (i.e. "last month" = January of the same calendar year). The original's
    /// branch treats any Jan/Feb target as "last fiscal year" (CheckYear-1), which is correct
    /// when you've stepped back across a fiscal-year boundary (e.g. today=Mar, last month=Feb
    /// of the prior fiscal year) but wrong in that one case, where January hasn't actually
    /// left the current fiscal year. Reproduced exactly as-is (see SelfTest.Run) because you
    /// asked for identical outputs, not corrected business logic - if WCSA would rather this
    /// one figure was calculated correctly instead of matching the original quirk, replace
    /// the body with `return FiscalYearLabel(MonthStart(today, monthsBack));` and monthsBack
    /// stops needing special-casing at 0 either.
    /// </summary>
    public static int MonthlyBucketFiscalYear(DateTime today, int monthsBack)
    {
        int checkYear = CurrentFiscalYear(today);
        if (monthsBack == 0) return checkYear; // Map_ValMth3/Map_PftMth3: no branch in the original, always CheckYear
        var target = MonthStart(today, monthsBack);
        return (target.Month == 1 || target.Month == 2) ? checkYear - 1 : checkYear;
    }

    /// <summary>
    /// Whole calendar months between <paramref name="startDate"/> and <paramref name="today"/>
    /// - e.g. a first sale in the same month as today scores 0, one 14 months ago scores 14.
    /// Moved here from the old BudgetBuilder (now removed - budget/"SalesMonths" aggregation
    /// lives in Supabase) since it's still needed for item_stock_snapshot's active_months.
    /// </summary>
    public static int MonthsSince(DateTime startDate, DateTime today) =>
        (today.Year * 12 + today.Month) - (startDate.Year * 12 + startDate.Month);
}
