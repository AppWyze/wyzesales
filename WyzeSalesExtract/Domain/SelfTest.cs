using WyzeSalesExtract.Worker;

namespace WyzeSalesExtract.Domain;

/// <summary>
/// Verifies the date-math cleanups in FiscalDate reproduce the original nested-If logic
/// exactly, for every month across several years, and separately sanity-checks the
/// scheduler's own "what's the next run time" logic (ExtractWorker.NextRunTime). Run with
/// "--selftest" (no database connection needed). This is the one piece of the port that can
/// be proven correct without access to the real IQRetail database - everything else needs
/// validation by running both the old QlikView extract and this program side by side and
/// diffing the output files (see README).
/// </summary>
public static class SelfTest
{
    public static bool Run(TextWriter @out)
    {
        bool allPassed = true;
        int checks = 0;

        for (int year = 2023; year <= 2027; year++)
        {
            for (int month = 1; month <= 12; month++)
            {
                var today = new DateTime(year, month, 15); // day-of-month is irrelevant, MonthStart floors it

                // --- Check 1: three-fiscal-year window start -------------------------------
                // Explicit historyYears: 3 - this proves equivalence with the ORIGINAL
                // QVS script's hardcoded 3-year window specifically. The 3/5-year toggle
                // (Settings > Company "Data history window") only changes historyYears at
                // the ExtractRunner call site; it doesn't change what "correct" looks like
                // for this fixed 3-year comparison.
                var originalOffset = FiscalDate.OriginalMonthOffset(month);
                var originalStart = new DateTime(today.Year, today.Month, 1).AddMonths(-originalOffset);
                var newStart = FiscalDate.FiscalYearWindowStart(today, historyYears: 3);
                checks++;
                if (originalStart != newStart)
                {
                    allPassed = false;
                    @out.WriteLine($"MISMATCH window start for {today:yyyy-MM}: original={originalStart:yyyy-MM-dd} new={newStart:yyyy-MM-dd}");
                }

                // --- Check 2: Map_ValMth / Map_PftMth branch equivalence -------------------
                // Original (QVS lines 364-416): Mth1/Mth2 (monthsBack 2 and 1) use
                //   Year = If(Month(AddMonths(Today(),-N)) in {Jan,Feb}, CheckYear-1, CheckYear)
                // but Mth3 (monthsBack 0, "this month") skips the branch entirely and hardcodes
                //   Year = $(CheckYear)
                // MonthlyBucketFiscalYear reproduces this exact branch (deliberately NOT the
                // same as FiscalYearLabel - see that method's XML doc for the one case, running
                // in February, where the two genuinely disagree).
                var checkYear = FiscalDate.CurrentFiscalYear(today);
                foreach (var monthsBack in new[] { 0, 1, 2 })
                {
                    var target = new DateTime(today.Year, today.Month, 1).AddMonths(-monthsBack);
                    var originalBranch = monthsBack == 0
                        ? checkYear
                        : (target.Month == 1 || target.Month == 2) ? checkYear - 1 : checkYear;
                    var newValue = FiscalDate.MonthlyBucketFiscalYear(today, monthsBack);
                    checks++;
                    if (originalBranch != newValue)
                    {
                        allPassed = false;
                        @out.WriteLine($"MISMATCH month-branch for today={today:yyyy-MM} monthsBack={monthsBack}: original={originalBranch} new={newValue}");
                    }
                }
            }
        }

        // --- Check 3: scheduler "next run time" logic ------------------------------------
        var scheduleCases = new (TimeOnly[] Times, DateTime Now, DateTime Expected)[]
        {
            (new[] { new TimeOnly(6, 0), new TimeOnly(14, 0) }, new DateTime(2026, 8, 18, 5, 0, 0), new DateTime(2026, 8, 18, 6, 0, 0)),
            (new[] { new TimeOnly(6, 0), new TimeOnly(14, 0) }, new DateTime(2026, 8, 18, 7, 0, 0), new DateTime(2026, 8, 18, 14, 0, 0)),
            (new[] { new TimeOnly(6, 0), new TimeOnly(14, 0) }, new DateTime(2026, 8, 18, 20, 0, 0), new DateTime(2026, 8, 19, 6, 0, 0)),
            (new[] { new TimeOnly(23, 30) }, new DateTime(2026, 12, 31, 23, 45, 0), new DateTime(2027, 1, 1, 23, 30, 0)),
        };
        foreach (var (times, now, expected) in scheduleCases)
        {
            checks++;
            var actual = ExtractWorker.NextRunTime(times.ToList(), now);
            if (actual != expected)
            {
                allPassed = false;
                @out.WriteLine($"MISMATCH NextRunTime for now={now:yyyy-MM-dd HH:mm}: expected={expected:yyyy-MM-dd HH:mm} actual={actual:yyyy-MM-dd HH:mm}");
            }
        }

        @out.WriteLine(allPassed
            ? $"SelfTest PASSED ({checks} checks) - date-math cleanup and scheduler logic both check out."
            : $"SelfTest FAILED - see mismatches above ({checks} checks run).");

        return allPassed;
    }
}
