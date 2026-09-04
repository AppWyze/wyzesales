using System.Text.RegularExpressions;
using WyzeSalesExtract.Builders;
using WyzeSalesExtract.Config;
using WyzeSalesExtract.Data;
using WyzeSalesExtract.Domain;
using WyzeSalesExtract.Logging;

namespace WyzeSalesExtract.Worker;

/// <summary>
/// The actual "do one full extract, write it to Supabase" run - everything Program.cs used to
/// do directly. Pulled out into its own class so it can be called either once from the command
/// line (--run-once, for manual testing) or repeatedly from the background scheduler
/// (ExtractWorker) without duplicating the pipeline.
///
/// Much shorter than the version that wrote pipe-delimited files and uploaded them via SFTP:
/// no Builders left that resolve category/rep-name/branch or apply business-rule config - this
/// program now pulls raw facts and reference data from WCSA and writes them straight into
/// Supabase, where the aggregation, resolution, and business rules live instead. See
/// Wyzesales_Rebuild_Decisions.md Section 1.
///
/// Exit codes: 0 success, 1 failed (see log for where, and data_load_runs in Supabase), 3
/// could not even open a Supabase connection to report anything (see run-tracking note below).
/// (2 is already used by Program.cs for "config could not be loaded" - kept distinct so the
/// two "couldn't get started at all" cases stay tellable apart from a bare exit code alone.)
///
/// 2026-09-04: connects to Supabase and opens a data_load_runs (schema/033) row BEFORE ever
/// touching WCSA - previously this connected to WCSA first, which meant the single most common
/// real-world failure (WCSA/ODBC unreachable) could never be reported anywhere Supabase-side at
/// all. The one failure mode this still can't report is Supabase itself being unreachable -
/// same inherent, accepted limitation ExtractWorker.cs already has for a config-load failure:
/// nothing to write the failure to without a working connection. That still gets logged locally
/// (Logging.LogFolder) either way.
/// </summary>
public static class ExtractRunner
{
    public static async Task<int> RunOnceAsync(AppSettings settings, Log log)
    {
        var stopwatch = System.Diagnostics.Stopwatch.StartNew();
        var today = DateTime.Now.Date;

        log.Info("WyzeSales extract (WCSA) starting.");
        log.Info($"Run date: {today:yyyy-MM-dd}. Fiscal year in use: {settings.FiscalYear.OverrideYear?.ToString() ?? FiscalDate.CurrentFiscalYear(today) + " (auto-computed)"}");

        SupabaseWriter supa;
        Guid clientId;
        Guid runId;

        try
        {
            log.Info("Connecting to Supabase...");
            supa = new SupabaseWriter(settings.Supabase.ConnectionString);
            clientId = await supa.ResolveOrCreateClientIdAsync(settings.Supabase.ClientCode);
            runId = await supa.StartLoadRunAsync(clientId);
        }
        catch (Exception ex)
        {
            log.Error("Could not connect to Supabase / open a run record - nothing to report this failure to besides this log.", ex);
            return 3;
        }

        using (supa)
        {
            try
            {
                log.Info("Connecting to WCSA database...");
                using var db = new Db(settings);

                log.Info("Loading exclusion list from Supabase (excluded_customer_accounts)...");
                var excludedAccounts = await supa.LoadExcludedAccountsAsync(clientId);
                log.Info($"  {excludedAccounts.Count} account(s) excluded.");

                log.Info("Loading data history window from Supabase (fiscal_year_settings.history_years)...");
                var historyYears = await supa.LoadDataHistoryYearsAsync(clientId);
                log.Info($"  {historyYears}-year history window.");

                log.Info("Loading reference/mapping data (customers, reps, categories, suppliers, stock counts, lead times)...");
                var lookups = Lookups.Load(db, settings);

                log.Info("Loading invoice line facts...");
                var invoiceFacts = Facts.LoadInvoiceItemFacts(db, excludedAccounts);
                log.Info($"  {invoiceFacts.Count} invoice/credit-note lines loaded (before date filtering).");

                var salesWindowStart = settings.FiscalYear.OverrideYear is int overrideYear
                    ? new DateTime(overrideYear - historyYears, 3, 1)
                    : FiscalDate.FiscalYearWindowStart(today, historyYears);

                log.Info("Building invoice/credit-note facts...");
                var salesFacts = SalesDocumentFactsBuilder.BuildInvoicesAndCreditNotes(invoiceFacts, lookups, salesWindowStart);
                log.Info($"  {salesFacts.Count} rows.");

                log.Info("Building quote facts...");
                var quoteFacts = SalesDocumentFactsBuilder.BuildQuotesOrOrders(db, lookups, salesWindowStart, "QUOTES", "QTEItems", "quote");
                salesFacts.AddRange(quoteFacts);
                log.Info($"  {quoteFacts.Count} rows.");

                log.Info("Building sales order facts...");
                var orderFacts = SalesDocumentFactsBuilder.BuildQuotesOrOrders(db, lookups, salesWindowStart, "SOrders", "SOrdItem", "sales_order");
                salesFacts.AddRange(orderFacts);
                log.Info($"  {orderFacts.Count} rows.");

                var historyMonths = historyYears * 12;
                log.Info($"Building {historyMonths}-month stock movement facts...");
                var (movementFacts, itemDates) = StockMovementFactsBuilder.Build(invoiceFacts, lookups, today, historyMonths);
                log.Info($"  {movementFacts.Count} rows.");

                log.Info("Building item stock snapshot...");
                var snapshotFacts = ItemStockSnapshotBuilder.Build(lookups, itemDates, today);
                log.Info($"  {snapshotFacts.Count} rows.");

                log.Info("Assembling reference data (branches, reps, customers, categories, suppliers, items)...");
                var refData = ReferenceDataBuilder.Build(lookups, salesFacts, movementFacts);

                log.Info("Writing reference data to Supabase...");
                await supa.UpsertBranchesAsync(clientId, refData.BranchCodes);
                await supa.UpsertSalesRepsAsync(clientId, refData.SalesReps);
                await supa.UpsertCustomersAsync(clientId, refData.Customers);
                await supa.UpsertCategoriesAsync(clientId, refData.Categories);
                await supa.UpsertSuppliersAsync(clientId, refData.Suppliers);
                await supa.UpsertItemsAsync(clientId, refData.Items);

                log.Info("Writing sales document facts to Supabase (full replace)...");
                await supa.ReplaceSalesDocumentFactsAsync(clientId, salesFacts);

                log.Info("Writing stock movement facts to Supabase (full replace)...");
                await supa.ReplaceStockMovementFactsAsync(clientId, movementFacts);

                log.Info("Writing item stock snapshot to Supabase (today's snapshot replaced)...");
                await supa.ReplaceTodaysItemStockSnapshotAsync(clientId, snapshotFacts, today);

                stopwatch.Stop();
                log.Info($"Done in {stopwatch.Elapsed:mm\\:ss}.");

                await supa.CompleteLoadRunAsync(
                    runId, success: true, errorMessage: null, durationSeconds: stopwatch.Elapsed.TotalSeconds,
                    salesDocumentFactsRows: salesFacts.Count,
                    stockMovementFactsRows: movementFacts.Count,
                    itemStockSnapshotRows: snapshotFacts.Count);

                return 0;
            }
            catch (Exception ex)
            {
                log.Error("Extract failed.", ex);
                stopwatch.Stop();

                try
                {
                    await supa.CompleteLoadRunAsync(
                        runId, success: false, errorMessage: SanitizeErrorMessage(ex),
                        durationSeconds: stopwatch.Elapsed.TotalSeconds);
                }
                catch (Exception reportEx)
                {
                    // The run itself already failed - if reporting that failure back to
                    // Supabase ALSO fails (connection dropped mid-run, etc.), don't let that
                    // mask the original error or throw past this method. The row is left on
                    // 'running', which the app already treats as a failure signal once it's
                    // old enough (see schema/033's header) - not silent, just less precise.
                    log.Error("Additionally failed to report the above failure to Supabase.", reportEx);
                }

                return 1;
            }
        }
    }

    /// <summary>Strips anything that looks like a credential out of an exception's own message
    /// before it's persisted to data_load_runs.error_message, which any signed-in user of the
    /// client can read (schema/033). Some ODBC/Npgsql failure paths echo connection details back
    /// in their message text (e.g. an invalid-DSN or auth failure), so this is a real, not
    /// hypothetical, precaution - not a reason to assume every message is dangerous, just to not
    /// trust that none of them ever are. Deliberately uses only ex.Message, never ex.ToString()
    /// (which would include the full stack trace) - a stack trace isn't useful to a WCSA staff
    /// member glancing at "why did last night's load fail", and is one more thing that could
    /// theoretically echo something sensitive from deep in a driver's internals.</summary>
    internal static string SanitizeErrorMessage(Exception ex)
    {
        var message = ex.Message;

        // key=value connection-string fragments (Password=..., Pwd=..., User Id=..., Uid=...,
        // Api Key=..., Token=...), case-insensitive, value ends at the next ';' or end of string.
        message = Regex.Replace(
            message,
            @"(?i)\b(password|pwd|user id|uid|api[ _]?key|token)\s*=\s*[^;]*",
            "$1=***");

        const int maxLength = 500;
        if (message.Length > maxLength)
            message = message[..maxLength] + "... (truncated)";

        return message;
    }
}
