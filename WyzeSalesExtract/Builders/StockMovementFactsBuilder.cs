using WyzeSalesExtract.Data;
using WyzeSalesExtract.Domain;

namespace WyzeSalesExtract.Builders;

/// <summary>
/// Builds the raw stock_movement_facts rows: net item+location movement, one row per calendar
/// month, over the trailing <paramref name="historyMonths"/> months (36 for the default 3-year
/// history window, 60 for the 5-year option - Settings &gt; Company "Data history window",
/// WCSA 2026-09) - same grouping the old TransactionWyzestock.txt used, minus the name/category
/// resolution and the hardcoded 'SA' TransactionType literal that column carried regardless of
/// whether the underlying rows were invoices or credit notes (credit notes are still folded
/// into the net figure here, same as before - just without a column claiming they're all
/// invoices). Supabase joins item name/category from the items/categories reference tables
/// directly when needed.
/// </summary>
public static class StockMovementFactsBuilder
{
    private sealed record MovementFact(string ItemCode, string Location, DateTime TxDate, decimal Quantity, decimal SalesAmount, decimal SalesProfit);

    public static (List<StockMovementFact> Monthly, Dictionary<ItemLocationKey, ItemActivity> ItemDates) Build(
        List<InvoiceItemFact> facts, Lookups lk, DateTime today, int historyMonths = 36)
    {
        var windowStart = FiscalDate.MonthStart(today, historyMonths);

        var movementFacts = new List<MovementFact>();
        foreach (var f in facts)
        {
            if (!lk.DocType.TryGetValue(f.Document, out var docType)) continue;
            if (docType != "SA" && docType != "CR") continue;
            if (!lk.DocDate.TryGetValue(f.Document, out var docDate)) continue;
            if (docDate < windowStart) continue;

            int sign = docType == "CR" ? -1 : 1;
            movementFacts.Add(new MovementFact(
                f.PartNo, f.Warehouse, docDate, f.Qty * sign, f.Value * sign, (f.Value - f.Cost) * sign));
        }

        // First/last sale date and active-months per item+location - still needed by
        // ItemStockSnapshotFact, so computed here from the same raw movement data rather than
        // making a second pass over the source facts.
        var itemDates = new Dictionary<ItemLocationKey, ItemActivity>();
        foreach (var group in movementFacts.GroupBy(m => new ItemLocationKey(m.ItemCode, m.Location)))
        {
            var first = group.Min(g => g.TxDate);
            var last = group.Max(g => g.TxDate);
            itemDates[group.Key] = new ItemActivity(first, last, FiscalDate.MonthsSince(first, today));
        }

        var monthly = new List<StockMovementFact>();
        for (int monthsBack = historyMonths; monthsBack >= 1; monthsBack--)
        {
            var bucketStart = FiscalDate.MonthStart(today, monthsBack);
            var bucketEnd = FiscalDate.MonthEnd(today, monthsBack);

            var inBucket = movementFacts.Where(m => m.TxDate >= bucketStart && m.TxDate <= bucketEnd);

            foreach (var group in inBucket.GroupBy(m => new { m.ItemCode, m.Location }))
            {
                monthly.Add(new StockMovementFact(
                    ItemCode: group.Key.ItemCode,
                    LocationCode: group.Key.Location,
                    Month: bucketStart,
                    Quantity: group.Sum(g => g.Quantity),
                    SalesAmount: group.Sum(g => g.SalesAmount),
                    SalesProfit: group.Sum(g => g.SalesProfit)));
            }
        }

        return (monthly, itemDates);
    }
}
