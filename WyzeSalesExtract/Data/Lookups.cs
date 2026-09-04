using WyzeSalesExtract.Config;
using WyzeSalesExtract.Domain;

namespace WyzeSalesExtract.Data;

/// <summary>One line from INVITEMS joined conceptually to its Invoices header (the QVS "Table_A").</summary>
public sealed record InvoiceItemFact(
    string AccNum, string Document, decimal Cost, decimal Value,
    decimal Qty, decimal LDiscAm, string PartNo, string Warehouse);

/// <summary>One row from STOCKLCNT with every column any lookup in the original script needed from it
/// (the original hits this table with four separate near-identical SELECTs - consolidated into one
/// query here since it's the same table and the same rows; a safe, low-risk cleanup).</summary>
public sealed record StockLcntRow(
    string Code, string Location, DateTime Month,
    decimal QtyOnHand, decimal SalesCost, decimal SalesUnits, decimal SalesAmount);

/// <summary>All of the QVS's ~20 in-memory Mapping tables, built once at startup.</summary>
public sealed class Lookups
{
    public Dictionary<string, string> CustomerName { get; } = new();
    public Dictionary<string, string> DocType { get; } = new();
    public Dictionary<string, DateTime> DocDate { get; } = new();
    public Dictionary<string, string> SalesPersonCodeInv { get; } = new();
    public Dictionary<string, string> SalesPersonCode { get; } = new();
    public Dictionary<string, string> SalesPersonName { get; } = new();
    public Dictionary<string, string> Category { get; } = new();
    public Dictionary<string, string> DepartmentByItemCode { get; } = new();
    public Dictionary<string, string> ItemName { get; } = new();
    public Dictionary<string, string> Supplier { get; } = new();
    public Dictionary<string, string> SupplierCode { get; } = new();
    public Dictionary<ItemLocationKey, decimal> OnPOrderQty { get; } = new();
    public Dictionary<ItemLocationKey, decimal> OnSalOrderQty { get; } = new();
    public Dictionary<ItemLocationKey, DateTime> MaxStockCountDate { get; } = new();
    public Dictionary<ItemLocationKey, decimal> OnHandQty { get; } = new();
    public Dictionary<string, decimal> DefaultCost { get; } = new();
    public Dictionary<ItemLocationKey, decimal> CalculatedCost { get; } = new();
    public Dictionary<string, decimal> DefaultSellPrice { get; } = new();
    public Dictionary<ItemLocationKey, decimal> SellingPrice { get; } = new();
    public Dictionary<SupplierPartKey, int> SupplierAvgLeadTimeDays { get; } = new();
    public Dictionary<string, string> PurchaseOrderNumber { get; } = new(); // POrders.DOCUMENT -> ORDERNUM
    public Dictionary<string, string> OrderDetail { get; } = new(); // ACCNUM+PartNo+Warehouse -> ORDERNUM

    /// <summary>Distinct (ItemCode, Location) combinations that have ever appeared in STOCKLCNT - this is
    /// the base row set the original "ItemExtract" table is built from.</summary>
    public List<ItemLocationKey> ItemLocations { get; } = new();

    public static Lookups Load(Db db, AppSettings settings)
    {
        var lk = new Lookups();

        // Map_CustomerName (QVS lines 3-10): sourced from Invoices header rows, not a customer
        // master - duplicates simply overwrite, last row wins, exactly like a QlikView Mapping load.
        foreach (var r in db.Query($"SELECT ACCNUM, NAME {db.From("Invoices")}",
                     r => (AccNum: r.GetString("ACCNUM"), Name: Row.StripApostrophe(r.GetString("NAME")))))
            lk.CustomerName[r.AccNum] = r.Name;

        // Map_DocType (lines 12-20): 'I' -> SA (invoice), 'C' -> CR (credit note). Anything else is
        // left unmapped, matching the original (no ELSE branch means Null, which later filters drop).
        foreach (var r in db.Query($"SELECT DOCUMENT, DOCTYPE {db.From("Invoices")}",
                     r => (Doc: r.GetString("DOCUMENT"), Type: r.GetString("DOCTYPE"))))
        {
            if (r.Type == "I") lk.DocType[r.Doc] = "SA";
            else if (r.Type == "C") lk.DocType[r.Doc] = "CR";
        }

        // Map_DocDate (lines 22-29)
        foreach (var r in db.Query($"SELECT DOCUMENT, INVDATE {db.From("Invoices")}",
                     r => (Doc: r.GetString("DOCUMENT"), Date: r.GetDate("INVDATE"))))
            lk.DocDate[r.Doc] = r.Date;

        // Map_SalesPersonCodeInv (lines 31-38)
        foreach (var r in db.Query($"SELECT DOCUMENT, REP {db.From("Invoices")}",
                     r => (Doc: r.GetString("DOCUMENT"), Rep: r.GetString("REP"))))
            lk.SalesPersonCodeInv[r.Doc] = r.Rep;

        // Map_SalesPersonCode (lines 40-47) - from DEBTORS, used for the 11 override accounts
        foreach (var r in db.Query($"SELECT ACCOUNT, NORMALREP {db.From("DEBTORS")}",
                     r => (Account: r.GetString("ACCOUNT"), Rep: r.GetString("NORMALREP"))))
            lk.SalesPersonCode[r.Account] = r.Rep;

        // Map_SalesPersonName (lines 49-56)
        foreach (var r in db.Query($"SELECT REPNUM, REPNAME {db.From("REPS")}",
                     r => (RepNum: r.GetString("REPNUM"), RepName: r.GetString("REPNAME"))))
            lk.SalesPersonName[r.RepNum] = r.RepName;

        // Map_Category (lines 58-65)
        foreach (var r in db.Query($"SELECT DEPARTMENT, DESCRIPTIO {db.From("DEPTMNTS")}",
                     r => (Dept: r.GetString("DEPARTMENT"), Desc: r.GetString("DESCRIPTIO"))))
            lk.Category[r.Dept] = r.Desc;

        // Map_Department_Category (lines 67-74)
        foreach (var r in db.Query($"SELECT CODE, DEPARTMENT {db.From("Stock")}",
                     r => (Code: Row.ReplaceQuoteWithIn(r.GetString("CODE")), Dept: r.GetString("DEPARTMENT"))))
            lk.DepartmentByItemCode[r.Code] = r.Dept;

        // Map_ItemName (lines 76-100): two-stage clean - first pass replaces " in DESCRIPT with "in",
        // second pass (against the already-cleaned result) replaces ' with "in".
        foreach (var r in db.Query($"SELECT CODE, DESCRIPT {db.From("Stock")}",
                     r => (Code: Row.ReplaceQuoteWithIn(r.GetString("CODE")),
                           Name: Row.ReplaceApostropheWithIn(Row.ReplaceQuoteWithIn(r.GetString("DESCRIPT"))))))
            lk.ItemName[r.Code] = r.Name;

        // Map_Supplier (lines 470-477)
        foreach (var r in db.Query($"SELECT ACCOUNT, NAME {db.From("CREDITRS")}",
                     r => (Account: r.GetString("ACCOUNT"), Name: r.GetString("NAME"))))
            lk.Supplier[r.Account] = r.Name;

        // Map_SupplierCode (lines 562-569)
        foreach (var r in db.Query($"SELECT StockCode, SupplierAccount {db.From("StockSuppliers")}",
                     r => (Code: Row.ReplaceQuoteWithIn(r.GetString("StockCode")), Supplier: r.GetString("SupplierAccount"))))
            lk.SupplierCode[r.Code] = r.Supplier;

        // Map_OnPOrderQty (lines 479-487): sum ORDERQTY grouped by PartNo+Warehouse
        foreach (var r in db.Query($"SELECT PARTNO, Warehouse, ORDERQTY {db.From("POrdItem")}",
                     r => (Key: new ItemLocationKey(Row.ReplaceQuoteWithIn(r.GetString("PARTNO")), r.GetString("Warehouse")),
                           Qty: r.GetDecimal("ORDERQTY"))))
            lk.OnPOrderQty[r.Key] = lk.OnPOrderQty.GetValueOrDefault(r.Key) + r.Qty;

        // Map_OnSalOrderQty (lines 489-497): sum QTY grouped by PartNo+Warehouse
        foreach (var r in db.Query($"SELECT PARTNO, QTY, Warehouse {db.From("SOrdItem")}",
                     r => (Key: new ItemLocationKey(Row.ReplaceQuoteWithIn(r.GetString("PARTNO")), r.GetString("Warehouse")),
                           Qty: r.GetDecimal("QTY"))))
            lk.OnSalOrderQty[r.Key] = lk.OnSalOrderQty.GetValueOrDefault(r.Key) + r.Qty;

        // STOCKLCNT - one consolidated pull feeds Map_MaxDate / Map_OnHandQty / Map_CalculatedCost /
        // Map_SellingPrice / the distinct ItemLocations list (lines 499-560, 673 base table).
        var stockLcnt = db.Query(
            $"SELECT CODE, LOCATION, MONTH, QTY_ON_HAND, SALES_COST, SALES_UNITS, SALES_AMOUNT {db.From("STOCKLCNT")}",
            r => new StockLcntRow(
                Row.ReplaceQuoteWithIn(r.GetString("CODE")),
                r.GetString("LOCATION"),
                r.GetDate("MONTH"),
                r.GetDecimal("QTY_ON_HAND"),
                r.GetDecimal("SALES_COST"),
                r.GetDecimal("SALES_UNITS"),
                r.GetDecimal("SALES_AMOUNT")));

        // Map_DefaultCost / Map_DefaultSellPrice (lines 520-527, 541-548)
        foreach (var r in db.Query($"SELECT CODE, LTSTCOST {db.From("Stock")}",
                     r => (Code: Row.ReplaceQuoteWithIn(r.GetString("CODE")), Cost: r.GetDecimal("LTSTCOST"))))
            lk.DefaultCost[r.Code] = r.Cost;
        foreach (var r in db.Query($"SELECT CODE, SELLPRICE1 {db.From("Stock")}",
                     r => (Code: Row.ReplaceQuoteWithIn(r.GetString("CODE")), Price: r.GetDecimal("SELLPRICE1"))))
            lk.DefaultSellPrice[r.Code] = r.Price;

        foreach (var group in stockLcnt.GroupBy(r => new ItemLocationKey(r.Code, r.Location)))
        {
            lk.ItemLocations.Add(group.Key);

            // Map_MaxDate: latest stock-count MONTH for this item+location.
            var maxDate = group.Max(g => g.Month);
            lk.MaxStockCountDate[group.Key] = maxDate;

            // The row(s) at the max date - original ApplyMap('Map_MaxDate', ...) filter picks the
            // row(s) whose MONTH equals that max; if more than one somehow matches, take the first
            // (matches QlikView's "last value wins" only when building a Mapping table, but here the
            // original filters to the max-date row(s) with a WHERE, so First() is the safe read here).
            var atMaxDate = group.First(g => g.Month == maxDate);

            // Map_OnHandQty (lines 509-518)
            lk.OnHandQty[group.Key] = atMaxDate.QtyOnHand;

            // Map_CalculatedCost (lines 529-539): SALES_COST/SALES_UNITS if both > 0, else default cost.
            lk.CalculatedCost[group.Key] =
                (atMaxDate.SalesCost > 0 && atMaxDate.SalesUnits > 0)
                    ? atMaxDate.SalesCost / atMaxDate.SalesUnits
                    : lk.DefaultCost.GetValueOrDefault(group.Key.ItemCode, 0m);

            // Map_SellingPrice (lines 550-560): SALES_AMOUNT/SALES_UNITS if both > 0, else default price.
            lk.SellingPrice[group.Key] =
                (atMaxDate.SalesAmount > 0 && atMaxDate.SalesUnits > 0)
                    ? atMaxDate.SalesAmount / atMaxDate.SalesUnits
                    : lk.DefaultSellPrice.GetValueOrDefault(group.Key.ItemCode, 0m);
        }

        // Supplier lead time (lines 599-651): Invoices header (ACCNUM as SUPPLIERCODE, ORDDATE,
        // INVDATE) left-joined to INVITEMS.PARTNO, kept only where ORDDATE >= 2019-01-01 and the
        // computed lead time (INVDATE - ORDDATE) is positive. NOTE: this deliberately does NOT
        // exclude the two accounts excluded elsewhere (DAN0007/EC590) - the original never applies
        // that exclusion here either, since it's a purchasing/supplier stat, not a sales one.
        var leadTimeRows = LoadSupplierLeadTimeRows(db);
        foreach (var group in leadTimeRows.GroupBy(r => new SupplierPartKey(r.SupplierCode, r.PartNo)))
        {
            var numOrders = group.Count();
            var sumDays = group.Sum(g => g.LeadTimeDays);
            lk.SupplierAvgLeadTimeDays[group.Key] = numOrders > 0
                ? (int)Math.Round((decimal)sumDays / numOrders, MidpointRounding.AwayFromZero)
                : 0;
        }

        // Map_ORDERNUM (lines 653-660)
        foreach (var r in db.Query($"SELECT DOCUMENT, ORDERNUM {db.From("POrders")}",
                     r => (Doc: r.GetString("DOCUMENT"), OrderNum: r.GetString("ORDERNUM"))))
            lk.PurchaseOrderNumber[r.Doc] = r.OrderNum;

        // Map_OrderDetail (lines 662-671): ACCNUM+PartNo+Warehouse -> ORDERNUM of the matching PO.
        foreach (var r in db.Query($"SELECT ACCNUM, DOCUMENT, PARTNO, Warehouse {db.From("POrdItem")}",
                     r => (Key: r.GetString("ACCNUM") + Row.ReplaceQuoteWithIn(r.GetString("PARTNO")) + r.GetString("Warehouse"),
                           Doc: r.GetString("DOCUMENT"))))
            lk.OrderDetail[r.Key] = lk.PurchaseOrderNumber.GetValueOrDefault(r.Doc, "");

        return lk;
    }

    private static List<(string SupplierCode, string PartNo, int LeadTimeDays)> LoadSupplierLeadTimeRows(Db db)
    {
        var headers = db.Query(
            $"SELECT ACCNUM, DELNOTENUM, DOCUMENT, INVDATE, ORDDATE {db.From("Invoices")}",
            r => (AccNum: r.GetString("ACCNUM"), Document: r.GetString("DOCUMENT"),
                  InvDate: r.GetDate("INVDATE"), OrdDate: r.GetDate("ORDDATE")));

        var lines = db.Query(
            $"SELECT DOCUMENT, PARTNO {db.From("INVITEMS")}",
            r => (Document: r.GetString("DOCUMENT"), PartNo: Row.ReplaceQuoteWithIn(r.GetString("PARTNO"))));

        var linesByDoc = lines.ToLookup(l => l.Document);
        var cutoff = new DateTime(2019, 1, 1);
        var results = new List<(string, string, int)>();

        foreach (var h in headers)
        {
            if (h.OrdDate < cutoff) continue;
            var leadTime = (h.InvDate.Date - h.OrdDate.Date).Days;
            if (leadTime <= 0) continue;

            foreach (var line in linesByDoc[h.Document])
                results.Add((h.AccNum, line.PartNo, leadTime));
        }

        return results;
    }
}
