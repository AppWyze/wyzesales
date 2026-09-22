using WyzeSalesExtract.Builders;
using WyzeSalesExtract.Data;
using WyzeSalesExtract.Domain;
using WyzeSalesExtract.Logging;

namespace WyzeSalesExtract.Extraction;

/// <summary>
/// Edgetec's <see cref="ISourceExtractor"/> - a faithful C# port of Edgetec's own QlikView
/// extract script (uploaded by Craig 2026-09-22, "Edgetec Extract"), the same "copy the
/// original as literally as possible" methodology WCSA's own Data/Db.cs already documents.
/// Ported deliberately, NOT reinvented: every field below traces back to a specific line of
/// that script, and the historical data already sitting in Supabase (loaded from that same
/// script's own output, TransactionWyzesales.txt) was used to empirically verify the tricky
/// parts - see the remarks on the fields below for exactly what each one checks against.
///
/// Three things the original script did that this port deliberately does NOT replicate,
/// because DataWindow.EarliestLoadDate (Craig, 2026-09-22: "We already have a full set of data
/// up until 7 September 2026... build from there without duplicating") makes them unnecessary:
///   - The 2024SEP archive concatenation (the script stitched a frozen historical snapshot
///     onto the live data with manually shifted PERIOD numbers) - history before the floor is
///     separately protected and never re-extracted, so there's nothing left to stitch.
///   - The PERIOD-to-YEAR/MONTH/Quarter calculation (two competing hand-toggled branches in
///     the original script, one of them commented out and switched depending on the current
///     month - a fragile mechanism no scheduled service could safely replicate). This program
///     only ever needs DocDate right; fiscal year/month/quarter are computed from DocDate in a
///     Postgres view (v_sales_documents), exactly like WCSA - see RawFacts.cs's own remarks on
///     SalesDocumentFact carrying no computed fields.
///   - The Sales1/Sales2/SalesAnalysis multi-year comparison tables the script built AFTER
///     TransactionWyzesales - superseded by Supabase's own multi-tenant dimension model
///     (client_dimensions/dim_N_code, migration 039/050) the same way WCSA's old pre-rewrite
///     comparison mechanism was superseded; not re-implemented here.
///
/// Edgetec's five real reporting dimensions (Group, Market, Revenue Split, Category Type,
/// Business Unit) are already configured in Supabase as dim_1..dim_5 (client_dimensions,
/// verified directly against the live database 2026-09-22) - see the Dim1..Dim5 locals below
/// for exactly which script field feeds which slot.
/// </summary>
public sealed class EdgetecSourceExtractor : ISourceExtractor
{
    public Task<ExtractedData> ExtractAsync(SourceExtractionContext ctx)
    {
        var log = ctx.Log;
        var settings = ctx.Settings;

        // DataWindow.EarliestLoadDate is required for Edgetec (see AppSettings.Validate for
        // WCSA/Edgetec's own settings checks - this one isn't enforced there because it's a
        // property of THIS client's onboarding, not of Source.Type generally, but Edgetec has
        // no other way to bound how far back GLTRANS gets pulled, so treat an unset floor as a
        // hard stop rather than silently pulling all of GLTRANS history on every run). Once
        // confirmed set, ctx.SalesWindowStart (ExtractRunner's own resolved value) is used for
        // the actual query - it already equals this same EarliestLoadDate whenever it's set.
        if (settings.DataWindow.EarliestLoadDate is null)
            throw new InvalidOperationException(
                "Edgetec requires DataWindow.EarliestLoadDate to be set - see appsettings.example.json.");
        var sinceDate = ctx.SalesWindowStart;

        log.Info("Connecting to Edgetec database...");
        using var db = new EdgetecDb(settings);

        log.Info("Loading reference/mapping data (reps, accounts, stock, categories, ledger-to-dimension mapping)...");
        var lk = EdgetecLookups.Load(db, settings);

        log.Info($"Loading GL transactions from {sinceDate:yyyy-MM-dd}...");
        var facts = EdgetecFacts.Load(db, sinceDate);
        log.Info($"  {facts.GlLines.Count} GL line(s) loaded.");

        log.Info("Building sales document facts...");
        var salesFacts = BuildSalesDocumentFacts(facts, lk, log)
            .Where(f => !ctx.ExcludedAccounts.Contains(f.AccountCode))
            .ToList();
        log.Info($"  {salesFacts.Count} rows (after excluded_customer_accounts).");

        log.Info("Assembling reference data (sales reps, customers)...");
        var refData = new ReferenceData(
            BranchCodes: new List<string>(),
            SalesReps: lk.RepNameByCode.Select(kv => (RepCode: kv.Key, Name: kv.Value)).ToList(),
            // AssignedRepCode always null: Edgetec has no source-data equivalent of WCSA's
            // customers.attribute_to_assigned_rep business rule (Edgetec's rep resolution -
            // REP with the REFDOCNO override - is fully captured per-line in InvoiceRepCode
            // already, see BuildSalesDocumentFacts). Passing null here every run is safe
            // (UpsertCustomersAsync sets it unconditionally though, so if anyone ever sets it
            // by hand in Supabase for an Edgetec customer, the next run will clear it back to
            // null - worth knowing, not worth solving until it's an actual need).
            Customers: lk.CustomerNameByAccno.Select(kv => (Code: kv.Key, Name: kv.Value, AssignedRepCode: (string?)null)).ToList(),
            Categories: new List<(string DepartmentCode, string Name)>(),
            Suppliers: new List<(string AccountCode, string Name)>(),
            Items: new List<(string Code, string Name, string? DepartmentCode, string? SupplierAccountCode, decimal? DefaultCost, decimal? DefaultSellPrice)>());

        return Task.FromResult(new ExtractedData(refData, salesFacts, new List<StockMovementFact>(), new List<ItemStockSnapshotFact>()));
    }

    /// <summary>
    /// One row per (Document, DocumentKind, DocDate, Rep, Account, Item, Quantity, dimensions)
    /// combination, Value/Cost summed within each - the same shape the original script's own
    /// group-by produced (Table_A -&gt; TransactionWyzesales: "group by DocNumber, DocType,
    /// DocDate, ..., Quantity" then "Sum(Value) as Value, Sum(Value) - Sum(Profit) as Profit").
    /// This program stores Value and Cost separately rather than netting them into Profit
    /// itself (Postgres computes profit from value/cost the same way it already does for
    /// WCSA - see RawFacts.cs), but the grouping key and what gets summed into each bucket is
    /// identical: it's what lets a sale-side (110) GL line and its matching cost-side (150) GL
    /// line - which normally share the same LEDGER_NO and therefore the same dimensions -
    /// collapse into one output row with both a real Value and a real Cost, exactly like the
    /// original script. Verified empirically against the real historical extract: every one of
    /// its 555 multi-line documents varies by dimension, never by item code - see the
    /// conversation this was designed in for the full analysis.
    /// </summary>
    private static List<SalesDocumentFact> BuildSalesDocumentFacts(EdgetecFacts facts, EdgetecLookups lk, Log log)
    {
        var unrecognizedEntries = new HashSet<string>();

        var lines = facts.GlLines.Select(line =>
        {
            var ledgerNo = line.GlNo.Length >= 3 ? line.GlNo[^3..] : line.GlNo;

            // ACCNO: Table_A's "If(Len(Trim(PROJNO)) = 0,ACCNO, PROJNO) as ACCNO" - PROJNO off
            // this exact GL line overrides whatever STTRANS said for this DOCNO, when present.
            var accno = !string.IsNullOrWhiteSpace(line.Projno)
                ? line.Projno
                : facts.AccnoByDocNo.GetValueOrDefault(line.DocNo, "");
            var docAccno = line.DocNo + accno;

            // REP: Map_RepCode, with the GLTRANS REFDOCNO override (keyed by DOCNO+PROJNO,
            // which equals DOCNO+accno exactly when PROJNO is what set accno above) taking
            // precedence over the STTRANS-sourced value - see EdgetecFacts' remarks.
            var rep = facts.RepOverrideByDocProjno.GetValueOrDefault(line.DocNo + line.Projno)
                ?? facts.RepByDocAccno.GetValueOrDefault(docAccno, "");

            var itemCode = facts.ItemCodeByDocAccno.GetValueOrDefault(docAccno, "");
            var quantity = facts.QuantityByDocNo.GetValueOrDefault(line.DocNo, 0m);

            // dim_2 Market: ApplyMap('Map_AccountTypes', ACCNO, '') - blank (not "OTHER") when
            // this ACCNO has no ACCOUNTS.TXT row at all; "OTHER" only applies to a row that
            // exists but whose INTREF isn't one of the six recognised values (MarketByAccno
            // itself already folds that case in at load time - see EdgetecLookups).
            var market = lk.MarketByAccno.GetValueOrDefault(accno, "");

            // dim_1 Group (the script's own "Category"/DESCRIP) and dim_3/dim_4 (Revenue
            // Split/Category Type) all come off the Edgetec Formats.xlsx row for this ledgerNo.
            lk.FormatByLedgerNo.TryGetValue(ledgerNo, out var format);
            var group = lk.CategoryDescriptionByCode.GetValueOrDefault(format?.CategoryCode ?? "", "");
            var revenueSplit = format?.SalesService ?? "";
            var categoryType = format?.CategoryType ?? "";

            // dim_5 Business Unit: MAP1 (cost side, 150xxx) / MAP2 (sale side, 110xxx) reverse-
            // map ledgerNo to a representative STOCK.TXT item, whose GROUP then resolves to a
            // description via STOCKCAT (TYPE='G') - see EdgetecLookups' class remarks for why
            // this "ledgerStockNo" is a different concept to itemCode above.
            var ledgerStockNo = line.IsSaleLedger
                ? lk.Map2LedgerStockNoBySaleLedgerNo.GetValueOrDefault(ledgerNo, "")
                : lk.Map1LedgerStockNoByCostLedgerNo.GetValueOrDefault(ledgerNo, "");
            var groupCode = lk.GroupCodeByStockNo.GetValueOrDefault(ledgerStockNo, "");
            var businessUnit = lk.GroupDescriptionByCode.GetValueOrDefault(groupCode, "");

            // DocumentKind: GLTRANS.ENTRY, direct - Craig, 2026-09-22: "Invoice = I; Credit
            // note = C; Journal Entry = J and Adjustment = A." An ENTRY value outside those
            // four is unexpected (never seen in the real historical extract) - logged once per
            // distinct value and folded into 'invoice' rather than aborting the run, matching
            // what the very first historical load already did for J/A before this mapping
            // existed.
            var documentKind = line.Entry switch
            {
                "I" => "invoice",
                "C" => "credit_note",
                "J" => "journal",
                "A" => "adjustment",
                _ => LogUnrecognizedEntry(line.Entry, unrecognizedEntries, log),
            };

            // Value/Cost: "SALE_AMOUNT * -1" (sale-side lines only) / "COST_AMOUNT" unflipped
            // (cost-side lines only) - see class remarks on why summing these within the group
            // below reproduces the original script's Sum(Value)/Sum(Profit) netting.
            var value = line.IsSaleLedger ? line.Amount * -1m : 0m;
            var cost = line.IsSaleLedger ? 0m : line.Amount;

            return new
            {
                Document = line.DocNo,
                DocumentKind = documentKind,
                line.Date,
                InvoiceRepCode = string.IsNullOrEmpty(rep) ? null : rep,
                // AccountCode: "UNASSIGNED" when no customer could be resolved at all (blank
                // PROJNO and no matching STTRANS row for this DOCNO) - matches the literal
                // substitution already present in the historical rows already sitting in
                // Supabase (verified against the real data during this build), not a new
                // convention invented here.
                AccountCode = string.IsNullOrEmpty(accno) ? "UNASSIGNED" : accno,
                ItemCode = itemCode,
                Quantity = quantity,
                Value = value,
                Cost = cost,
                Group = group,
                Market = market,
                RevenueSplit = revenueSplit,
                CategoryType = categoryType,
                BusinessUnit = businessUnit,
            };
        });

        var grouped = lines
            .GroupBy(f => (f.Document, f.DocumentKind, f.Date, f.InvoiceRepCode, f.AccountCode, f.ItemCode,
                           f.Quantity, f.Group, f.Market, f.RevenueSplit, f.CategoryType, f.BusinessUnit))
            .Select(g => new SalesDocumentFact(
                DocumentKind: g.Key.DocumentKind,
                Document: g.Key.Document,
                AccountCode: g.Key.AccountCode,
                DocDate: g.Key.Date,
                InvoiceRepCode: g.Key.InvoiceRepCode,
                ItemCode: g.Key.ItemCode,
                WarehouseCode: null, // Edgetec has no branch/location dimension - see README.
                Quantity: g.Key.Quantity,
                Value: g.Sum(x => x.Value),
                Cost: g.Sum(x => x.Cost),
                DiscountAmount: 0m, // no discount concept anywhere in Edgetec's source data.
                DimCodes: new[]
                {
                    NullIfEmpty(g.Key.Group),         // dim_1: Group
                    NullIfEmpty(g.Key.Market),         // dim_2: Market
                    NullIfEmpty(g.Key.RevenueSplit),   // dim_3: Revenue Split
                    NullIfEmpty(g.Key.CategoryType),   // dim_4: Category Type
                    NullIfEmpty(g.Key.BusinessUnit),   // dim_5: Business Unit
                    null, null, null, null, null, null, null,
                }))
            .ToList();

        return grouped;
    }

    private static string? NullIfEmpty(string s) => string.IsNullOrEmpty(s) ? null : s;

    private static string LogUnrecognizedEntry(string entry, HashSet<string> alreadyLogged, Log log)
    {
        if (alreadyLogged.Add(entry))
            log.Info($"  WARNING: unrecognized GLTRANS.ENTRY value '{entry}' - treating as 'invoice'. Worth a look.");
        return "invoice";
    }
}
