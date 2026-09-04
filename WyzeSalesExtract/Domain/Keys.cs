namespace WyzeSalesExtract.Domain;

/// <summary>
/// The original script glues seven fields together with &amp; into a single string to use
/// as a Mapping-table key (e.g. "CustomerName & ItemName & SalesPersonName & Category &
/// SubCategory & Location & SalesPersonCode"). That is fragile - two different rows can
/// produce the same concatenated string if a field boundary happens to line up (e.g.
/// CustomerName="AB", ItemName="C..." collides with CustomerName="A", ItemName="BC...").
/// This record struct is the "safe cleanup" replacement: a real composite key with proper
/// value equality, used identically everywhere the QVS used the concatenated string.
/// </summary>
public readonly record struct SalesGroupKey(
    string CustomerName,
    string ItemName,
    string SalesPersonName,
    string Category,
    string SubCategory,
    string Location,
    string SalesPersonCode);

/// <summary>Composite key for anything keyed by item + location (used throughout the stock side).</summary>
public readonly record struct ItemLocationKey(string ItemCode, string Location);

/// <summary>Composite key for supplier + part number lead-time lookups.</summary>
public readonly record struct SupplierPartKey(string SupplierCode, string PartNo);
