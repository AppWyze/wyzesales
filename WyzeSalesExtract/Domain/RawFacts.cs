namespace WyzeSalesExtract.Domain;

/// <summary>
/// One line destined for the sales_document_facts table in Supabase. Deliberately carries no
/// rep-override resolution, no category/name lookups, and no computed fields (profit,
/// profit%, fiscal year/month labels) - all of that is now a Postgres view
/// (v_sales_documents) over exactly these raw columns, so it can be seen and changed in
/// Supabase directly instead of needing a rebuild of this program. See
/// SalesDocumentFactsBuilder for the one deliberate exception (quote/sales-order rep
/// attribution) and why it's still handled here rather than in Postgres.
///
/// 2026-09-22 (Edgetec): gained <see cref="DimCodes"/> - the twelve generic dim_1_code..
/// dim_12_code columns the multi-tenant dimension model added to sales_document_facts
/// (migration 039/050, applied directly in Supabase - not committed to this repo's
/// docs/schema, see that migration's own header for the client_dimensions/dim_N story).
/// WCSA's five dimensions (rep/customer/item/category/branch) are all still the ORIGINAL
/// fixed columns above (resolution_kind 'existing' in client_dimensions) and this stays null
/// for every WCSA fact - zero behaviour change. A client whose reporting needs dimensions
/// beyond those five (Edgetec: Group/Market/Revenue Split/Category Type/Business Unit) sets
/// whichever of DimCodes[0]..DimCodes[11] that client's own client_dimensions rows expect
/// (index 0 = dim_1_code, same 0-based convention the Flutter side already uses - see
/// lib/data/models/sales_document.dart) and leaves the rest null.
/// </summary>
public sealed record SalesDocumentFact(
    string DocumentKind,     // 'invoice' | 'credit_note' | 'quote' | 'sales_order' | 'journal' | 'adjustment'
    string Document,
    string AccountCode,      // ACCNUM
    DateTime DocDate,
    string? InvoiceRepCode,  // the rep "as recorded on the document" - see builder remarks
    string ItemCode,         // PARTNO (cleaned)
    string? WarehouseCode,   // raw location/warehouse code, straight off the line
    decimal Quantity,
    decimal Value,
    decimal Cost,
    decimal DiscountAmount,
    string?[]? DimCodes = null);

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
