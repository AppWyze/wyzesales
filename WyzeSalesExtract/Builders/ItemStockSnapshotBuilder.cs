using WyzeSalesExtract.Data;
using WyzeSalesExtract.Domain;

namespace WyzeSalesExtract.Builders;

/// <summary>
/// Builds the raw item_stock_snapshot rows: one per item+location, as of this run - on-hand/
/// on-order quantities, cost, price, and lead time. No supplier-name/suppression or item-name
/// resolution here (Supabase joins those from items/suppliers); no "Each"/ItemType/MinOrderQty
/// literals either, since those were always hardcoded constants in the old output, not real
/// per-item facts.
///
/// One deliberate, safe cleanup versus the old ItemWyzestock.txt: a supplier/item combination
/// with no computable lead time is now written as NULL, not a defaulted 0. The old script's
/// "If(IsNull(LeadTime),60,LeadTime)" fallback could never actually fire (an earlier
/// ApplyMap(...,0) had already turned every null into 0 before that check ran), so its real
/// runtime behaviour was already "0 means unknown" - just represented by a misleading number
/// instead of an honest NULL. This doesn't change any real lead-time figure that was ever
/// actually computed; it only changes how "we don't know" is represented.
/// </summary>
public static class ItemStockSnapshotBuilder
{
    public static List<ItemStockSnapshotFact> Build(
        Lookups lk, Dictionary<ItemLocationKey, ItemActivity> itemDates, DateTime today)
    {
        var results = new List<ItemStockSnapshotFact>();

        foreach (var key in lk.ItemLocations)
        {
            string code = key.ItemCode;
            string location = key.Location;

            string supplierCode = lk.SupplierCode.GetValueOrDefault(code, "");
            int? leadTime = lk.SupplierAvgLeadTimeDays.TryGetValue(new SupplierPartKey(supplierCode, code), out var lt)
                ? lt
                : null;

            var ilKey = new ItemLocationKey(code, location);

            DateTime? firstSale = null, lastSale = null;
            int? activeMonths = null;
            if (itemDates.TryGetValue(ilKey, out var activity))
            {
                firstSale = activity.FirstSaleDate;
                lastSale = activity.LastSaleDate;
                activeMonths = activity.ActiveMonths;
            }

            results.Add(new ItemStockSnapshotFact(
                ItemCode: code,
                LocationCode: location,
                QtyOnHand: lk.OnHandQty.GetValueOrDefault(ilKey, 0m),
                OnPurchaseOrderQty: lk.OnPOrderQty.GetValueOrDefault(ilKey, 0m),
                OnSalesOrderQty: lk.OnSalOrderQty.GetValueOrDefault(ilKey, 0m),
                CalculatedCost: lk.CalculatedCost.GetValueOrDefault(ilKey, 0m),
                SellingPrice: lk.SellingPrice.GetValueOrDefault(ilKey, 0m),
                AvgSupplierLeadTimeDays: leadTime,
                FirstSaleDate: firstSale,
                LastSaleDate: lastSale,
                ActiveMonths: activeMonths,
                SnapshotDate: today));
        }

        return results;
    }
}
