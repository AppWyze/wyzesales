using WyzeSalesExtract.Data;
using WyzeSalesExtract.Domain;

namespace WyzeSalesExtract.Builders;

/// <summary>
/// Assembles the reference/dimension rows (branches, sales reps, customers, categories,
/// suppliers, items) that get upserted into Supabase alongside the raw facts each run. These
/// are refreshed in full every run (new codes appear, names/departments/prices can change) -
/// but SupabaseWriter's upserts deliberately never touch the columns WCSA staff own directly
/// in Supabase (customers.attribute_to_assigned_rep, items.supplier_suppressed, branches.
/// display_code/name), so this program can't silently overwrite a setting someone configured
/// there. See SupabaseWriter for exactly which columns each upsert touches.
/// </summary>
public sealed record ReferenceData(
    List<string> BranchCodes,
    List<(string RepCode, string Name)> SalesReps,
    List<(string Code, string Name, string? AssignedRepCode)> Customers,
    List<(string DepartmentCode, string Name)> Categories,
    List<(string AccountCode, string Name)> Suppliers,
    List<(string Code, string Name, string? DepartmentCode, string? SupplierAccountCode, decimal? DefaultCost, decimal? DefaultSellPrice)> Items);

public static class ReferenceDataBuilder
{
    public static ReferenceData Build(
        Lookups lk,
        List<SalesDocumentFact> salesFacts,
        List<StockMovementFact> movementFacts)
    {
        // Branch codes: every distinct warehouse/location code seen anywhere this run - the
        // item master's own location list, plus every sales/movement line's warehouse, so a
        // branch that only ever shows up on a quote (say) still gets registered. New codes
        // land with display_code/name left NULL for someone to fill in in Supabase; existing
        // rows are never touched (see SupabaseWriter.UpsertBranches).
        var branchCodes = lk.ItemLocations.Select(k => k.Location)
            .Concat(salesFacts.Where(f => !string.IsNullOrEmpty(f.WarehouseCode)).Select(f => f.WarehouseCode!))
            .Concat(movementFacts.Select(f => f.LocationCode))
            .Where(c => !string.IsNullOrEmpty(c))
            .Distinct(StringComparer.Ordinal)
            .OrderBy(c => c, StringComparer.Ordinal)
            .ToList();

        var salesReps = lk.SalesPersonName
            .Select(kv => (RepCode: kv.Key, Name: kv.Value))
            .Where(r => !string.IsNullOrEmpty(r.RepCode))
            .ToList();

        var customers = lk.CustomerName
            .Select(kv => (Code: kv.Key, Name: kv.Value, AssignedRepCode: lk.SalesPersonCode.GetValueOrDefault(kv.Key)))
            .Where(c => !string.IsNullOrEmpty(c.Code))
            .ToList();

        var categories = lk.Category
            .Select(kv => (DepartmentCode: kv.Key, Name: kv.Value))
            .Where(c => !string.IsNullOrEmpty(c.DepartmentCode))
            .ToList();

        var suppliers = lk.Supplier
            .Select(kv => (AccountCode: kv.Key, Name: kv.Value))
            .Where(s => !string.IsNullOrEmpty(s.AccountCode))
            .ToList();

        var items = lk.ItemName
            .Select(kv => (
                Code: kv.Key,
                Name: kv.Value,
                DepartmentCode: (string?)lk.DepartmentByItemCode.GetValueOrDefault(kv.Key),
                SupplierAccountCode: (string?)lk.SupplierCode.GetValueOrDefault(kv.Key),
                DefaultCost: (decimal?)lk.DefaultCost.GetValueOrDefault(kv.Key, 0m),
                DefaultSellPrice: (decimal?)lk.DefaultSellPrice.GetValueOrDefault(kv.Key, 0m)))
            .Where(i => !string.IsNullOrEmpty(i.Code))
            .ToList();

        return new ReferenceData(branchCodes, salesReps, customers, categories, suppliers, items);
    }
}
