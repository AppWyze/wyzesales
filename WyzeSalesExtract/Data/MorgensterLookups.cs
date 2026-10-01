namespace WyzeSalesExtract.Data;

/// <summary>
/// Every reference/mapping table Morgenster's original QlikView script ("Morgenster QV
/// Extract.txt") pulls before building its real transaction rows - the equivalent of
/// Lookups.cs (WCSA) / EdgetecLookups.cs (Edgetec). Mirrors the script's own `Mapping Load`
/// blocks one-for-one; see each field's remarks for which block it replaces.
///
/// One deliberate consolidation: the original script issues FOUR separate SQL round-trips
/// against MORGEN.CustomerMaster (Map_CustomerCategory, Map_CustomerDescription,
/// Map_CustomerContinent, Map_CustomerCountry, Map_CustomerArea - five, actually, all reading
/// the same table) because QlikView's Mapping Load syntax ties one SQL statement to one map.
/// This class pulls CustomerCode/Category/CustomerDesc/UserDefined01-03 together in a single
/// query and builds all five dictionaries from the one result set - same rows, same values,
/// one round-trip instead of five. Not a behaviour change, just not bound by QVS's own syntax
/// limitation.
///
/// `Map_SalesmanCode` (built from DeliveryAddresses, keyed on CustomerCode + delivery address)
/// is NOT ported - confirmed dead code in the original script (defined via a Mapping Load but
/// never actually referenced by any ApplyMap call anywhere in the script). See the Morgenster
/// design notes doc, Section 3, item 1.
/// </summary>
public sealed class MorgensterLookups
{
    // Map_ItemDescription / Map_ItemCategory - both built from one Inventory pull, same as the
    // original script's single "Inventory" resident load feeding two separate maps.
    public Dictionary<string, string> ItemDescriptionByCode { get; } = new();
    public Dictionary<string, string> ItemCategoryCodeByItemCode { get; } = new();

    // Map_ItemCategoryDescription: ICCode -> ICDesc, from InventoryCategory.
    public Dictionary<string, string> ItemCategoryDescriptionByCode { get; } = new();

    // From one CustomerMaster pull (see class remarks): Map_CustomerCategory,
    // Map_CustomerDescription, Map_CustomerContinent, Map_CustomerCountry, Map_CustomerArea.
    public Dictionary<string, string> CustomerCategoryCodeByCustomer { get; } = new();
    public Dictionary<string, string> CustomerDescriptionByCode { get; } = new();
    public Dictionary<string, string> CustomerContinentByCode { get; } = new();
    public Dictionary<string, string> CustomerCountryByCode { get; } = new();
    public Dictionary<string, string> CustomerAreaByCode { get; } = new();

    // Map_CustomerCategoryDescription: CCCode -> CCDesc, from CustomerCategories.
    public Dictionary<string, string> CustomerCategoryDescriptionByCode { get; } = new();

    // Map_StoreDescription: StoreCode -> Description, from MultiStore.
    public Dictionary<string, string> StoreDescriptionByCode { get; } = new();

    // Map_Group: InvGroup -> Description, from InventoryGroups.
    public Dictionary<string, string> GroupDescriptionByInvGroup { get; } = new();

    // Feeds Map_GroupDescription: (ItemCode, StoreCode) -> InvGroup, from MultiStoreTrn.
    // GroupDescriptionFor() below resolves this straight through to a description, replacing
    // the original script's two-step "ApplyMap('Map_Group', InvGroup)" chain.
    public Dictionary<(string ItemCode, string StoreCode), string> InvGroupByItemStore { get; } = new();

    // Map_ItemRange: ItemCode -> Bin, from MultiStoreTrn, only where Bin isn't blank - same
    // "where Trim(Bin) <> ''" filter the original script applies.
    public Dictionary<string, string> ItemRangeByCode { get; } = new();

    // Map_SalesmanDescription: keyed by plain salesman Code (the original script's own
    // "'*' & Code" prefix exists only to give QlikView's single mapping-key-space a way to
    // tell a salesman code apart from other code types sharing the same map; not needed here
    // since this is a dedicated dictionary).
    public Dictionary<string, string> SalesmanDescriptionByCode { get; } = new();

    // Map_HistoryLines: DocumentNumber -> SalesmanCode, from the same
    // "HistoryLines where DocumentType = '3' or '4' or '5'" filter as the real transaction
    // pull in MorgensterSourceExtractor - a second round-trip against the same table/filter
    // the original script's own Map_HistoryLines SQL uses (that query has no SearchType/date
    // restriction either, matching the original exactly - no narrower than the source script).
    //
    // QUIRK, confirmed by Craig as wanted (2026-10-01, "Salesman code = as you see it in the
    // code is how it is"): this resolves salesman PER DOCUMENT, not per line - every line on a
    // document gets whichever salesman code this map last saw for that DocumentNumber, not
    // necessarily the salesman code on that specific line. QlikView's own Mapping Load keeps
    // the LAST-loaded value for a duplicate key; this dictionary is built the same way (each
    // row processed in fetch order simply overwrites the previous value for that
    // DocumentNumber), so it carries the same pre-existing, not-newly-introduced,
    // row-order-dependent behaviour the original script already had for a document with
    // multiple lines whose raw SalesmanCode values differ.
    public Dictionary<string, string> SalesmanCodeByDocumentNumber { get; } = new();

    /// <summary>Map_GroupDescription, resolved in one step: which InventoryGroups description
    /// applies to this item at this store, or "" if either half of the lookup misses - same
    /// "ApplyMap(..., '')" default-to-blank behaviour as the original script.</summary>
    public string GroupDescriptionFor(string itemCode, string storeCode) =>
        InvGroupByItemStore.TryGetValue((itemCode, storeCode), out var invGroup)
            && GroupDescriptionByInvGroup.TryGetValue(invGroup, out var desc)
            ? desc
            : "";

    public static MorgensterLookups Load(MorgensterDb db)
    {
        var lk = new MorgensterLookups();

        foreach (var row in db.Query(
            $"SELECT ItemCode, Description, Category {db.From("Inventory")}",
            r => (Code: r.GetString("ItemCode"), Desc: r.GetString("Description"), Cat: r.GetString("Category"))))
        {
            lk.ItemDescriptionByCode[row.Code] = row.Desc;
            lk.ItemCategoryCodeByItemCode[row.Code] = row.Cat;
        }

        foreach (var row in db.Query(
            $"SELECT ICCode, ICDesc {db.From("InventoryCategory")}",
            r => (Code: r.GetString("ICCode"), Desc: r.GetString("ICDesc"))))
        {
            lk.ItemCategoryDescriptionByCode[row.Code] = row.Desc;
        }

        // Consolidated CustomerMaster pull - see class remarks.
        foreach (var row in db.Query(
            $"SELECT CustomerCode, Category, CustomerDesc, UserDefined01, UserDefined02, UserDefined03 {db.From("CustomerMaster")}",
            r => (
                Code: r.GetString("CustomerCode"),
                Category: r.GetString("Category"),
                Desc: r.GetString("CustomerDesc"),
                Continent: r.GetString("UserDefined01"),
                Country: r.GetString("UserDefined02"),
                Area: r.GetString("UserDefined03"))))
        {
            lk.CustomerCategoryCodeByCustomer[row.Code] = row.Category;
            lk.CustomerDescriptionByCode[row.Code] = row.Desc;
            // "If(IsNull(UserDefinedNN) or Trim(UserDefinedNN) = '', '<No X Defined>', UserDefinedNN)"
            lk.CustomerContinentByCode[row.Code] = string.IsNullOrWhiteSpace(row.Continent) ? "No Continent Defined" : row.Continent;
            lk.CustomerCountryByCode[row.Code] = string.IsNullOrWhiteSpace(row.Country) ? "No Country Defined" : row.Country;
            lk.CustomerAreaByCode[row.Code] = string.IsNullOrWhiteSpace(row.Area) ? "No Area Defined" : row.Area;
        }

        foreach (var row in db.Query(
            $"SELECT CCCode, CCDesc {db.From("CustomerCategories")}",
            r => (Code: r.GetString("CCCode"), Desc: r.GetString("CCDesc"))))
        {
            lk.CustomerCategoryDescriptionByCode[row.Code] = row.Desc;
        }

        foreach (var row in db.Query(
            $"SELECT StoreCode, Description {db.From("MultiStore")}",
            r => (Code: r.GetString("StoreCode"), Desc: r.GetString("Description"))))
        {
            lk.StoreDescriptionByCode[row.Code] = row.Desc;
        }

        foreach (var row in db.Query(
            $"SELECT InvGroup, Description {db.From("InventoryGroups")}",
            r => (Code: r.GetString("InvGroup"), Desc: r.GetString("Description"))))
        {
            lk.GroupDescriptionByInvGroup[row.Code] = row.Desc;
        }

        foreach (var row in db.Query(
            $"SELECT ItemCode, InvGroup, StoreCode, Bin {db.From("MultiStoreTrn")}",
            r => (ItemCode: r.GetString("ItemCode"), InvGroup: r.GetString("InvGroup"), StoreCode: r.GetString("StoreCode"), Bin: r.GetString("Bin"))))
        {
            lk.InvGroupByItemStore[(row.ItemCode, row.StoreCode)] = row.InvGroup;
            // "SQL SELECT ItemCode, Bin FROM MultiStoreTrn" for Map_ItemRange is the same table -
            // pulled together here instead of twice. "where Trim(Bin) <> ''" preserved.
            if (!string.IsNullOrWhiteSpace(row.Bin))
                lk.ItemRangeByCode[row.ItemCode] = row.Bin;
        }

        foreach (var row in db.Query(
            $"SELECT Code, Description {db.From("SalesmanMaster")}",
            r => (Code: r.GetString("Code"), Desc: r.GetString("Description"))))
        {
            lk.SalesmanDescriptionByCode[row.Code] = row.Desc;
        }

        // Map_HistoryLines - see SalesmanCodeByDocumentNumber's own remarks on why this reuses
        // the same query MorgensterSourceExtractor issues for the real transaction rows rather
        // than querying HistoryLines a second time. Last row wins per DocumentNumber, matching
        // QlikView's own Mapping Load semantics for a duplicate key.
        foreach (var row in db.Query(
            $"SELECT DocumentNumber, SalesmanCode {db.From("HistoryLines")} where DocumentType = '3' or DocumentType = '4' or DocumentType = '5'",
            r => (DocNumber: r.GetString("DocumentNumber"), SalesmanCode: r.GetString("SalesmanCode"))))
        {
            lk.SalesmanCodeByDocumentNumber[row.DocNumber] = row.SalesmanCode;
        }

        return lk;
    }
}
