namespace WyzeSalesExtract.Domain;

/// <summary>
/// One line destined for the sales_document_facts table in Supabase. Deliberately carries no
/// rep-override resolution, no category/name lookups, and no computed fields (profit,
/// profit%, fiscal year/month labels) - all of that is now a Postgres view
/// (v_sales_documents) over exactly these raw columns, so it can be seen and changed in
/// Supabase directly instead of needing a rebuild of this program. See
/// SalesDocumentFactsBuilder for the one deliberate exception (quote/sales-order rep
/// attribution) and why it's still handled here rather than in Postgres.
/// </summary>
public sealed record SalesDocumentFact(
    string DocumentKind,     // 'invoice' | 'credit_note' | 'quote' | 'sales_order'
    string Document,
    string AccountCode,      // ACCNUM
    DateTime DocDate,
    string? InvoiceRepCode,  // the rep "as recorded on the document" - see builder remarks
    string ItemCode,         // PARTNO (cleaned)
    string? WarehouseCode,   // raw location/warehouse code, straight off the line
    decimal Quantity,
    decimal Value,
    decimal Cost,
    decimal DiscountAmount);

/// <summary>One item+location's net movement for one calendar month - destined for
/// stock_movement_facts.</summary>
public sealed record StockMovementFact(
    string ItemCode,
    string LocationCode,
    DateTime Month,          // first-of-month
    decimal Quantity,
    decimal SalesAmount,
    decimal SalesProfit);

/// <summary>First/last sale date and months-active for an item at a location, derived from the
/// trailing history-window movement data (36 or 60 months, per historyYears - see
/// StockMovementFactsBuilder.Build) - feeds ItemStockSnapshotFact's FirstSaleDate/LastSaleDate/
/// ActiveMonths.</summary>
public sealed record ItemActivity(DateTime FirstSaleDate, DateTime LastSaleDate, int ActiveMonths);

/// <summary>One item+location's point-in-time stock/pricing/lead-time snapshot as of this run -
/// destined for item_stock_snapshot. No supplier-name/suppression or item-name resolution here;
/// Supabase joins those from the items/suppliers reference tables.</summary>
public sealed record ItemStockSnapshotFact(
    string ItemCode,
    string LocationCode,
    decimal? QtyOnHand,
    decimal? OnPurchaseOrderQty,
    decimal? OnSalesOrderQty,
    decimal? CalculatedCost,
    decimal? SellingPrice,
    int? AvgSupplierLeadTimeDays,
    DateTime? FirstSaleDate,
    DateTime? LastSaleDate,
    int? ActiveMonths,
    DateTime SnapshotDate);
