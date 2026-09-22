using WyzeSalesExtract.Builders;
using WyzeSalesExtract.Data;

namespace WyzeSalesExtract.Extraction;

/// <summary>
/// WCSA/IQRetail's <see cref="ISourceExtractor"/> implementation - the exact extraction
/// pipeline ExtractRunner used to run inline (Db, Lookups, Facts, and all four Builders),
/// relocated here unchanged by the 2026-09-22 refactor that introduced ISourceExtractor.
/// Every query, every cleaning rule, and every business-rule decision documented in
/// Data/Db.cs, Data/Lookups.cs, Data/Facts.cs, and Builders/*.cs is untouched by this move -
/// only where this code is called from changed, not what it does.
///
/// The one observable difference for WCSA: the "Connecting to WCSA database..." log line now
/// prints after the two generic Supabase-lookup log lines (exclusion list, history window)
/// instead of before, since ExtractRunner now loads those values once, up front, before
/// calling any extractor - a client-agnostic ordering rather than one built around WCSA's own
/// connection step happening first. Purely cosmetic: nothing about what's queried, how it's
/// cleaned, or what's written to Supabase changed.
/// </summary>
public sealed class WcsaSourceExtractor : ISourceExtractor
{
    public Task<ExtractedData> ExtractAsync(SourceExtractionContext ctx)
    {
        var log = ctx.Log;
        var settings = ctx.Settings;

        log.Info("Connecting to WCSA database...");
        using var db = new Db(settings);

        log.Info("Loading reference/mapping data (customers, reps, categories, suppliers, stock counts, lead times)...");
        var lookups = Lookups.Load(db, settings);

        log.Info("Loading invoice line facts...");
        var invoiceFacts = Facts.LoadInvoiceItemFacts(db, ctx.ExcludedAccounts);
        log.Info($"  {invoiceFacts.Count} invoice/credit-note lines loaded (before date filtering).");

        log.Info("Building invoice/credit-note facts...");
        var salesFacts = SalesDocumentFactsBuilder.BuildInvoicesAndCreditNotes(invoiceFacts, lookups, ctx.SalesWindowStart);
        log.Info($"  {salesFacts.Count} rows.");

        log.Info("Building quote facts...");
        var quoteFacts = SalesDocumentFactsBuilder.BuildQuotesOrOrders(db, lookups, ctx.SalesWindowStart, "QUOTES", "QTEItems", "quote");
        salesFacts.AddRange(quoteFacts);
        log.Info($"  {quoteFacts.Count} rows.");

        log.Info("Building sales order facts...");
        var orderFacts = SalesDocumentFactsBuilder.BuildQuotesOrOrders(db, lookups, ctx.SalesWindowStart, "SOrders", "SOrdItem", "sales_order");
        salesFacts.AddRange(orderFacts);
        log.Info($"  {orderFacts.Count} rows.");

        var historyMonths = ctx.HistoryYears * 12;
        log.Info($"Building {historyMonths}-month stock movement facts...");
        var (movementFacts, itemDates) = StockMovementFactsBuilder.Build(invoiceFacts, lookups, ctx.Today, historyMonths);
        log.Info($"  {movementFacts.Count} rows.");

        log.Info("Building item stock snapshot...");
        var snapshotFacts = ItemStockSnapshotBuilder.Build(lookups, itemDates, ctx.Today);
        log.Info($"  {snapshotFacts.Count} rows.");

        log.Info("Assembling reference data (branches, reps, customers, categories, suppliers, items)...");
        var refData = ReferenceDataBuilder.Build(lookups, salesFacts, movementFacts);

        return Task.FromResult(new ExtractedData(refData, salesFacts, movementFacts, snapshotFacts));
    }
}
