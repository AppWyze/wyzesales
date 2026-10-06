using WyzeSalesExtract.Builders;
using WyzeSalesExtract.Data;
using WyzeSalesExtract.Domain;
using WyzeSalesExtract.Logging;

namespace WyzeSalesExtract.Extraction;

/// <summary>
/// Morgenster's <see cref="ISourceExtractor"/> - a faithful C# port of "Morgenster QV
/// Extract.txt" (uploaded by Craig 2026-10-01), the same "copy the original as literally as
/// possible" methodology as WCSA's Db.cs and Edgetec's EdgetecSourceExtractor. Every field
/// below traces back to a specific line of that script, cross-checked against Morgenster's
/// already-live Supabase data (259,119 rows, 2021-01-01 through 2026-09-28, loaded from this
/// same script's own output) - see docs/WyzeSalesExtract_Morgenster_DesignNotes.md for the
/// full write-up this was built from.
///
/// Structurally closer to WCSA than to Edgetec: unlike Edgetec's GLTRANS-line-grouping, the
/// original script's own TransactionWyzesales load has no "group by" at all - it's a straight
/// one-row-per-HistoryLines-row reshape, so this extractor doesn't aggregate either (see
/// BuildSalesDocumentFacts - a plain Select, not a GroupBy).
///
/// Two things the original script does that this port deliberately does NOT replicate:
///   - The "BD" budget block (Table_A/Table_B -> Transactions, FinancialCategory = '90') -
///     confirmed dead in the original (its rows never survive TransactionWyzesales's own date
///     filter - none of Morgenster's three live document_kind values is a fourth "budget"
///     kind) AND Craig confirmed budgets will be built independently, not from this extractor
///     (2026-10-01: "Exclude the budget stuff as well will build this in ourselves").
///   - The Sales1/Sales2/SalesAnalysis/Company multi-year rollup tables the script builds
///     AFTER TransactionWyzesales - same reasoning as Edgetec's equivalent tabs: these re-read
///     TransactionWyzesales's own output purely for the QlikView dashboard, nothing upstream
///     of them, superseded by the app's own dimension model.
///
/// Morgenster's seven dim_N dimensions (Region, Country, Area, Cust. Category, Range, Group,
/// Type) are already configured in Supabase as dim_1..dim_7 (client_dimensions, verified
/// directly against the live database 2026-10-01) - see DimCodes below for exactly which
/// script field feeds which slot. "category" (ItemCategoryDescription) and "company" (the
/// hardcoded "Morgenster Estate" literal, dropped - client_id already scopes every row, same
/// as Edgetec's hardcoded Company literal) use the shared built-in dimension slots instead.
/// </summary>
public sealed class MorgensterSourceExtractor : ISourceExtractor
{
    /// <summary>Sales-person codes are stored in Supabase WITH a leading '*' (e.g. "*R004",
    /// "*111", "*CASH") - the form the original QlikView script produced ('*' &amp; Code), which
    /// every historical sales row, every sales-person budget and forecast, and the hard-coded
    /// "*RES" restaurant rows already use. 2026-10-05: this extractor was writing the plain
    /// Pastel code ("R004") instead, which split each rep in two - history/budgets under "*R004",
    /// everything loaded since 28 Sep under "R004" - duplicating the rep in dropdowns and
    /// understating actual-vs-budget for the current month. Applied to BOTH the rep list and
    /// the per-row invoice rep so they always agree. Idempotent (never double-prefixes), and
    /// blank stays blank.</summary>
    public static string StarRepCode(string code)
    {
        if (string.IsNullOrEmpty(code)) return code;
        return code.StartsWith('*') ? code : "*" + code;
    }

    /// <summary>The rep stored on a sales line. A document with NO salesman in Pastel is the "*"
    /// rep, exactly as the original QlikView script produced it ('*' &amp; blank = "*"): 15,589
    /// historical lines carry rep "*" (name "*"), and the old system's "(*) *" total
    /// (R 7,951,563.32 / 131,361 units, 2026-10-06) equals those PLUS the 65 lines loaded since
    /// 28 Sep that this extractor had written with a null rep (shown as UNASSIGNED).</summary>
    public static string InvoiceRepCodeFor(string salesmanCode)
        => string.IsNullOrEmpty(salesmanCode) ? "*" : StarRepCode(salesmanCode);

    public Task<ExtractedData> ExtractAsync(SourceExtractionContext ctx)
    {
        var log = ctx.Log;
        var settings = ctx.Settings;

        // Same hard-stop convention as Edgetec: Morgenster has no rolling historyYears logic of
        // its own (see FiscalDate remarks - this client is a plain calendar year, so there'd be
        // nothing to generalise even if it were needed), it relies entirely on
        // DataWindow.EarliestLoadDate to bound how far back HistoryLines gets filtered.
        if (settings.DataWindow.EarliestLoadDate is null)
            throw new InvalidOperationException(
                "Morgenster requires DataWindow.EarliestLoadDate to be set - see appsettings.example.json.");
        var sinceDate = ctx.SalesWindowStart;

        log.Info("Connecting to Morgenster database...");
        using var db = new MorgensterDb(settings);

        log.Info("Loading reference/mapping data (customers, items, categories, groups, salesmen)...");
        var lk = MorgensterLookups.Load(db);

        log.Info("Loading history lines (DocumentType 3/4/5)...");
        var rawLines = LoadHistoryLines(db);
        log.Info($"  {rawLines.Count} line(s) loaded (before SearchType/date filtering).");

        log.Info("Building sales document facts...");
        var salesFacts = BuildSalesDocumentFacts(rawLines, lk, sinceDate, log);
        salesFacts.AddRange(BuildRestaurantRevenueFacts(db, sinceDate));
        log.Info($"  {salesFacts.Count} row(s) (after SearchType/date filtering, including the restaurant GL rows).");

        log.Info("Assembling reference data (salesmen, customers, categories, items)...");
        var categories = lk.ItemCategoryDescriptionByCode
            .Where(kv => !string.IsNullOrEmpty(kv.Key))
            .Select(kv => (DepartmentCode: kv.Key, Name: kv.Value))
            .ToList();
        var validCategoryCodes = categories.Select(c => c.DepartmentCode).ToHashSet();
        var refData = new ReferenceData(
            BranchCodes: new List<string>(),
            SalesReps: lk.SalesmanDescriptionByCode.Select(kv => (RepCode: StarRepCode(kv.Key), Name: kv.Value)).ToList(),
            Customers: lk.CustomerDescriptionByCode.Select(kv => (Code: kv.Key, Name: kv.Value, AssignedRepCode: (string?)null)).ToList(),
            Categories: categories,
            Suppliers: new List<(string AccountCode, string Name)>(),
            Items: lk.ItemDescriptionByCode.Select(kv => (
                Code: kv.Key,
                Name: kv.Value,
                // items.department_code is a foreign key into categories(client_id, department_code),
                // and Categories above only contains codes InventoryCategory actually defines. Inventory.Category
                // on the other hand is taken as-is from the source - "" for an uncategorized item (GetString
                // turns a NULL Category into "", not a real code), or occasionally a stale code InventoryCategory
                // no longer has a row for. Either one inserted straight through blew up UpsertItemsAsync with a
                // 23503 FK violation on the first live Morgenster run (Craig, 2026-10-01). Only pass through a
                // code that's actually in Categories; anything else becomes NULL, same "uncategorized" meaning
                // the original QlikView ApplyMap-with-no-match would have shown as a blank category anyway.
                DepartmentCode: lk.ItemCategoryCodeByItemCode.TryGetValue(kv.Key, out var cat) && validCategoryCodes.Contains(cat)
                    ? cat
                    : null,
                SupplierAccountCode: (string?)null,
                DefaultCost: (decimal?)null,
                DefaultSellPrice: (decimal?)null)).ToList(),
            // The app reads Region/Country/Area/Cust. Category (dim_1..dim_4, resolution_kind
            // 'customer_attribute') from the CUSTOMER record (customers.attr_1..4_code), not from the
            // sales line, so they have to be written there every run - otherwise a customer created in
            // Pastel after the one-off backfill shows as UNASSIGNED in those four breakdowns. Same four
            // values, same fallbacks ("No Continent Defined" etc.) as the sales-line DimCodes above.
            CustomerAttributes: lk.CustomerDescriptionByCode.Keys
                .Where(code => !string.IsNullOrEmpty(code))
                .Select(code => (Code: code, Attrs: new string?[]
                {
                    NullIfEmpty(lk.CustomerContinentByCode.GetValueOrDefault(code, "")),
                    NullIfEmpty(lk.CustomerCountryByCode.GetValueOrDefault(code, "")),
                    NullIfEmpty(lk.CustomerAreaByCode.GetValueOrDefault(code, "")),
                    NullIfEmpty(ResolveCustomerCategoryDescription(code, lk)),
                }))
                .ToList());

        return Task.FromResult(new ExtractedData(refData, salesFacts, new List<StockMovementFact>(), new List<ItemStockSnapshotFact>()));
    }

    /// <summary>One row per MORGEN.HistoryLines line, DocumentType 3/4/5 only - the exact SQL
    /// the original script's Table_A/Map_HistoryLines both pull from. No date/SearchType filter
    /// in the SQL itself (same "copy the SQL literally, filter in C#" discipline as Db.cs and
    /// EdgetecDb.cs - the Pervasive ODBC driver's support for parameterized date literals has
    /// never been tested, so this sidesteps needing to know).</summary>
    private static List<RawLine> LoadHistoryLines(MorgensterDb db) => db.Query(
        $"SELECT DocumentType, DocumentNumber, DDate, ItemCode, CustomerCode, SalesmanCode, MultiStore, " +
        $"DiscountAmount, CostPrice, Qty, UnitPrice, SearchType {db.From("HistoryLines")} " +
        $"where DocumentType = '3' or DocumentType = '4' or DocumentType = '5'",
        r => new RawLine(
            DocumentType: r.GetString("DocumentType"),
            DocumentNumber: r.GetString("DocumentNumber"),
            DDate: r.GetDate("DDate"),
            ItemCode: r.GetString("ItemCode"),
            CustomerCode: r.GetString("CustomerCode"),
            MultiStore: r.GetString("MultiStore"),
            DiscountAmount: r.GetDecimal("DiscountAmount"),
            CostPrice: r.GetDecimal("CostPrice"),
            Qty: r.GetDecimal("Qty"),
            SearchType: r.GetString("SearchType")));

    private sealed record RawLine(
        string DocumentType, string DocumentNumber, DateTime DDate, string ItemCode, string CustomerCode,
        string MultiStore, decimal DiscountAmount, decimal CostPrice, decimal Qty, string SearchType);

    /// <summary>
    /// One <see cref="SalesDocumentFact"/> per qualifying HistoryLines row - no aggregation, see
    /// class remarks. "where Year(DDate) >= Year(Today())-6 and SearchType = '4'" from the
    /// original script's own TransactionWyzesales load becomes "SearchType == '4' and DDate >=
    /// sinceDate" here - DataWindow.EarliestLoadDate (narrower, and the actual onboarding floor
    /// Craig confirmed) supersedes the six-year window entirely, same shortcut Edgetec's design
    /// doc documents.
    /// </summary>
    private static List<SalesDocumentFact> BuildSalesDocumentFacts(
        List<RawLine> rawLines, MorgensterLookups lk, DateTime sinceDate, Log log)
    {
        var unrecognizedTypes = new HashSet<string>();

        var facts = rawLines
            .Where(l => l.SearchType == "4" && l.DDate >= sinceDate)
            .Where(l => !IsExcluded(l, lk))
            .Select(l =>
            {
                // DocumentType = '4' sign-flips DiscountAmount/CostPrice/Qty - the script's own
                // credit-note convention. Verified against live data: DocumentType '4' documents
                // carry the "IC" document-number prefix and negative quantity/value in Supabase
                // today (e.g. document IC122783, quantity -4.0) - consistent with this mapping.
                var sign = l.DocumentType == "4" ? -1m : 1m;
                var quantity = l.Qty * sign;
                var value = l.DiscountAmount * sign;
                var cost = l.CostPrice * sign;

                // DocumentKind: DocumentType, direct - 3=invoice, 4=credit_note (confirmed by
                // the sign-flip + "IC" prefix above), 5=adjustment (confirmed by the "ID"
                // prefix on Morgenster's existing adjustment-kind rows). Not explicitly spelled
                // out by Craig the way Edgetec's GLTRANS.ENTRY mapping was - worth a glance at
                // the first real --run-once output to confirm the three counts land in the same
                // rough proportions as the existing data (invoice ~96%, credit_note ~4%,
                // adjustment &lt;1%) before trusting this unattended.
                var documentKind = l.DocumentType switch
                {
                    "3" => "invoice",
                    "4" => "credit_note",
                    "5" => "adjustment",
                    _ => LogUnrecognizedType(l.DocumentType, unrecognizedTypes, log),
                };

                var salesmanCode = lk.SalesmanCodeByDocumentNumber.GetValueOrDefault(l.DocumentNumber, "");
                var itemCategoryCode = lk.ItemCategoryCodeByItemCode.GetValueOrDefault(l.ItemCode, "");
                var itemCategoryDescription = lk.ItemCategoryDescriptionByCode.GetValueOrDefault(itemCategoryCode, "");

                return new SalesDocumentFact(
                    DocumentKind: documentKind,
                    Document: l.DocumentNumber,
                    AccountCode: l.CustomerCode,
                    DocDate: l.DDate,
                    InvoiceRepCode: InvoiceRepCodeFor(salesmanCode),
                    ItemCode: l.ItemCode,
                    // Always null: the 259k rows already loaded (2021 - 27 Sep 2026) carry no warehouse
                    // code, and Morgenster has no branch dimension, so writing MultiStore here only made
                    // rows since 28 Sep disagree with all the history (branch 'UNASSIGNED' vs a store
                    // code that has no branches row). MultiStore is still used below for the Group lookup.
                    WarehouseCode: null,
                    Quantity: quantity,
                    Value: value,
                    Cost: cost,
                    DiscountAmount: 0m, // no separate discount concept in Morgenster's source data.
                    DimCodes: new[]
                    {
                        NullIfEmpty(lk.CustomerContinentByCode.GetValueOrDefault(l.CustomerCode, "")), // dim_1: Region
                        NullIfEmpty(lk.CustomerCountryByCode.GetValueOrDefault(l.CustomerCode, "")),   // dim_2: Country
                        NullIfEmpty(lk.CustomerAreaByCode.GetValueOrDefault(l.CustomerCode, "")),      // dim_3: Area
                        NullIfEmpty(ResolveCustomerCategoryDescription(l.CustomerCode, lk)),           // dim_4: Cust. Category
                        NullIfEmpty(lk.ItemRangeByCode.GetValueOrDefault(l.ItemCode, "")),             // dim_5: Range
                        NullIfEmpty(lk.GroupDescriptionFor(l.ItemCode, l.MultiStore)),                 // dim_6: Group
                        NullIfEmpty(ClassifyItemType(itemCategoryDescription)),                        // dim_7: Type
                        null, null, null, null, null,
                    });
            })
            .ToList();

        return facts;
    }

    /// <summary>Synthetic "Restaurant at Morgenster" revenue rows - GL journal entries, not real
    /// POS sales. Confirmed live in Morgenster's current Supabase data (item_code 'MEAL', 27
    /// rows, real values up to ~R815k) - a genuine, intentional feature of current reporting,
    /// not script debris. Ported as its own small extra query, same as the original script's
    /// own separate LOAD/UNION onto TransactionWyzesales.</summary>
    private static List<SalesDocumentFact> BuildRestaurantRevenueFacts(MorgensterDb db, DateTime sinceDate)
    {
        var rows = db.Query(
            $"SELECT AccNumber, DDate, Refrence, Amount {db.From("LedgerTransactions")} " +
            $"where AccNumber = '1250300' and Refrence = 'TRIDENT'",
            r => (DDate: r.GetDate("DDate"), Amount: r.GetDecimal("Amount")));

        // Monthly aggregation (group by month, Sum(Amount)*-1 - the original script's own "27 &
        // MM & YYYY" DocDate construction), one synthetic row per month this run's window covers.
        return rows
            .Where(r => r.DDate >= sinceDate)
            .GroupBy(r => new DateTime(r.DDate.Year, r.DDate.Month, 1))
            .Select(g => new SalesDocumentFact(
                DocumentKind: "invoice",
                Document: "1250300",
                AccountCode: "MG1711",
                DocDate: g.Key,
                InvoiceRepCode: "*RES",
                ItemCode: "MEAL",
                WarehouseCode: null,
                Quantity: 1m,
                Value: g.Sum(r => r.Amount) * -1m,
                Cost: 0m,
                DiscountAmount: 0m,
                DimCodes: new string?[]
                {
                    "Africa", "South Africa", "Western Cape", "Internal Accounting", // dim_1-4
                    "RESTAURANT", "Meals - Restaurant at Morgenster", "Meals",       // dim_5-7
                    null, null, null, null, null,
                }))
            .ToList();
    }

    /// <summary>The original script's own hardcoded exclusion list, straight off the
    /// Transactions load's WHERE clause - ported verbatim (literal prefix/code matches, not
    /// generalised into config) since these read as deliberate, final business rules rather
    /// than placeholders. Craig's design-doc review (2026-10-01) didn't flag these as wrong or
    /// stale, only confirmed the budget block and salesman-code resolution explicitly - so this
    /// assumes "still wanted" for the category/customer/salesman exclusions too, same as the
    /// rest of the script. Worth a second look if the first --run-once's row count comes out
    /// noticeably different from a proportional slice of the 259,119 already-loaded rows.</summary>
    private static bool IsExcluded(RawLine l, MorgensterLookups lk)
    {
        var itemCategoryCode = lk.ItemCategoryCodeByItemCode.GetValueOrDefault(l.ItemCode, "");
        var itemCategoryDescription = lk.ItemCategoryDescriptionByCode.GetValueOrDefault(itemCategoryCode, "");
        var customerDescription = lk.CustomerDescriptionByCode.GetValueOrDefault(l.CustomerCode, "");
        var salesmanCode = lk.SalesmanCodeByDocumentNumber.GetValueOrDefault(l.DocumentNumber, "");
        var salesmanDescription = lk.SalesmanDescriptionByCode.GetValueOrDefault(salesmanCode, "");

        return StartsWith(itemCategoryDescription, "Olive Trees")
            || StartsWith(itemCategoryDescription, "Other - Sundry")
            || StartsWith(itemCategoryDescription, "Packaging Olive Products")
            || StartsWith(itemCategoryDescription, "Pieralisi")
            || StartsWith(customerDescription, "Rental")
            || StartsWith(customerDescription, "Bad Debts List")
            || StartsWith(customerDescription, "Fishermans Cottage")
            || StartsWith(customerDescription, "COTS01 - RENTAL- Michael Louw")
            || l.CustomerCode == "OS0001"
            || StartsWith(salesmanDescription, "Non Product sales");
    }

    private static bool StartsWith(string s, string prefix) => s.StartsWith(prefix, StringComparison.Ordinal);

    private static string ResolveCustomerCategoryDescription(string customerCode, MorgensterLookups lk)
    {
        var categoryCode = lk.CustomerCategoryCodeByCustomer.GetValueOrDefault(customerCode, "");
        return lk.CustomerCategoryDescriptionByCode.GetValueOrDefault(categoryCode, "");
    }

    /// <summary>ItemType: Wine/Bulk/Olive/Other from the first few characters of
    /// ItemCategoryDescription - the original script's own "Left(x,4)='Wine'" etc chain.</summary>
    private static string ClassifyItemType(string itemCategoryDescription)
    {
        if (itemCategoryDescription.StartsWith("Wine", StringComparison.Ordinal)) return "Wine";
        if (itemCategoryDescription.StartsWith("Bulk", StringComparison.Ordinal)) return "Bulk";
        if (itemCategoryDescription.StartsWith("Olive", StringComparison.Ordinal)) return "Olive";
        return "Other";
    }

    private static string? NullIfEmpty(string s) => string.IsNullOrEmpty(s) ? null : s;

    private static string LogUnrecognizedType(string documentType, HashSet<string> alreadyLogged, Log log)
    {
        if (alreadyLogged.Add(documentType))
            log.Info($"  WARNING: unrecognized HistoryLines.DocumentType value '{documentType}' - treating as 'invoice'. Worth a look.");
        return "invoice";
    }
}
