using WyzeSalesExtract.Data;
using WyzeSalesExtract.Extraction;
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

        // --- Check 4: string cleaning of fixed-width ODBC values -------------------------
        // Fixed-width source columns come back space- and/or NUL-padded (Morgenster/Pervasive).
        // Row.Clean must reduce every variant to the same canonical value so fact rows and
        // master rows always join by exact match in Supabase.
        var cleanCases = new (string Input, string Expected)[]
        {
            ("SPA001 ", "SPA001"),
            ("AV001  ", "AV001"),
            ("SPA001", "SPA001"),
            ("  Korbicom (Pty) Ltd      ", "Korbicom (Pty) Ltd"),
            ("ABC\0\0\0", "ABC"),
            ("ABC \0 \0", "ABC"),
            ("   ", ""),
            ("", ""),
            ("Wine Flies  PTY Ltd   ", "Wine Flies  PTY Ltd"), // inner spacing left alone
        };
        foreach (var (input, expected) in cleanCases)
        {
            checks++;
            var actual = Row.Clean(input);
            if (actual != expected)
            {
                allPassed = false;
                @out.WriteLine($"MISMATCH Row.Clean for input=[{input.Replace("\0", "\\0")}]: expected=[{expected}] actual=[{actual}]");
            }
        }

        // --- Check 5: Morgenster sales-person codes carry the historical '*' prefix --------
        var starCases = new (string Input, string Expected)[]
        {
            ("R004", "*R004"),
            ("111", "*111"),
            ("*R004", "*R004"), // idempotent - never "**R004"
            ("", ""),
        };
        foreach (var (input, expected) in starCases)
        {
            checks++;
            var actual = MorgensterSourceExtractor.StarRepCode(input);
            if (actual != expected)
            {
                allPassed = false;
                @out.WriteLine($"MISMATCH StarRepCode for input=[{input}]: expected=[{expected}] actual=[{actual}]");
            }
        }

        // --- Check 6: a document with no salesman is the "*" rep (matches history) ----------
        var repCases = new (string Input, string Expected)[]
        {
            ("", "*"),
            ("R004", "*R004"),
            ("*R004", "*R004"),
            ("*", "*"),
        };
        foreach (var (input, expected) in repCases)
        {
            checks++;
            var actual = MorgensterSourceExtractor.InvoiceRepCodeFor(input);
            if (actual != expected)
            {
                allPassed = false;
                @out.WriteLine($"MISMATCH InvoiceRepCodeFor for input=[{input}]: expected=[{expected}] actual=[{actual}]");
            }
        }

        @out.WriteLine(allPassed
            ? $"SelfTest PASSED ({checks} checks) - date-math cleanup, scheduler logic, string cleaning and rep-code prefix all check out."
            : $"SelfTest FAILED - see mismatches above ({checks} checks run).");

        return allPassed;
    }
}
