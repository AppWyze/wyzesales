using ClosedXML.Excel;
using WyzeSalesExtract.Config;

namespace WyzeSalesExtract.Data;

/// <summary>
/// One ledger account's row from "Edgetec Formats.xlsx" (sheet "Stock") - the file Craig
/// uploaded 2026-09-22 and confirmed against the real Sales Analysis screen ("Individual Items
/// are categorised as per the dimensions that we already know"). Only the four fields the
/// original script's final output actually uses are kept - CATEGORY_DESCRIPTION and SALES_PLAN
/// are in the file but were never selected into the script's own TransactionWyzesales output,
/// so they're dead weight here too.
/// </summary>
public sealed record EdgetecLedgerFormat(string CategoryCode, string CategoryType, string SalesService);

/// <summary>
/// All of Edgetec's reference/mapping data, loaded once per run - the C# equivalent of every
/// Mapping Load in the original QlikView script except the two that are keyed by DOCNO/DOCNO&amp;
/// ACCNO (Map_RepCode, Map_SalesStockNo, Map_SalesStockCost, Map_SalesStockAmount, Map_Quantity,
/// Map_DocumentNumber) - those are built from GLTRANS/STTRANS rows themselves, not static
/// reference data, so they live in EdgetecFacts instead.
///
/// Three distinct "stock number"-shaped concepts appear in the original script and are kept
/// deliberately separate here under different names, because conflating any two of them was
/// the single easiest way to get this wrong:
///   - ledgerNo: Right(GLNO,3) - the 3-digit ledger account suffix straight off a GL line.
///     Used to join Edgetec Formats.xlsx (FormatByLedgerNo below) for Category/CategoryType/
///     SalesService, and to look up MAP1/MAP2.
///   - ledgerStockNo (MAP1/MAP2's own output): a REPRESENTATIVE physical stock item from
///     STOCK.TXT whose CSTACC/SALACC ledger account matches ledgerNo - used ONLY to then find
///     that item's GROUP (via GroupCodeByStockNo) and that group's description (via
///     GroupDescriptionByCode) - i.e. purely a stepping stone to Business Unit (dim_5). Never
///     used as an actual item code anywhere.
///   - the real per-line item code (SALES_STOCKNO in the script) - DOCNO&amp;ACCNO-keyed, built
///     from STTRANS in EdgetecFacts, and the only one of the three that ends up as
///     SalesDocumentFact.ItemCode.
/// </summary>
public sealed class EdgetecLookups
{
    public Dictionary<string, string> RepNameByCode { get; } = new(StringComparer.OrdinalIgnoreCase);

    // ACCOUNTS.TXT (ACCNO, INTREF, NAME) - Market (dim_2) and the customer name, both keyed by
    // the resolved customer ACCNO (see EdgetecSourceExtractor for how ACCNO itself is resolved).
    public Dictionary<string, string> MarketByAccno { get; } = new(StringComparer.OrdinalIgnoreCase);
    public Dictionary<string, string> CustomerNameByAccno { get; } = new(StringComparer.OrdinalIgnoreCase);

    // STOCK.TXT (STOCKNO, DESCRIP, GROUP, CATEGORY, SALACC, CSTACC).
    // MAP1: Right(CSTACC,3) -> STOCKNO (used for a GL line posted to the COST side, GLNO 150xxx).
    // MAP2: Right(SALACC,3) -> STOCKNO (used for a GL line posted to the SALE side, GLNO 110xxx).
    public Dictionary<string, string> Map1LedgerStockNoByCostLedgerNo { get; } = new(StringComparer.OrdinalIgnoreCase);
    public Dictionary<string, string> Map2LedgerStockNoBySaleLedgerNo { get; } = new(StringComparer.OrdinalIgnoreCase);
    public Dictionary<string, string> GroupCodeByStockNo { get; } = new(StringComparer.OrdinalIgnoreCase);

    // STOCKCAT (CATEGORY/GROUP, DESCRIP, TYPE 'C'|'G').
    // "Group" (dim_1, the script's own Category/DESCRIP) is CategoryDescriptionByCode keyed by
    // the Formats.xlsx CATEGORY code (NOT the STOCK.TXT one - see the Category-vs-Group note on
    // EdgetecSourceExtractor). "Business Unit" (dim_5) is GroupDescriptionByCode keyed by
    // STOCK.TXT's own GROUP code, reached via the ledgerStockNo stepping stone above.
    public Dictionary<string, string> CategoryDescriptionByCode { get; } = new(StringComparer.OrdinalIgnoreCase);
    public Dictionary<string, string> GroupDescriptionByCode { get; } = new(StringComparer.OrdinalIgnoreCase);

    // Edgetec Formats.xlsx "Stock" sheet, keyed by LEDGER_NO.
    public Dictionary<string, EdgetecLedgerFormat> FormatByLedgerNo { get; } = new(StringComparer.OrdinalIgnoreCase);

    public static EdgetecLookups Load(EdgetecDb db, AppSettings settings)
    {
        var lk = new EdgetecLookups();
        var filesPath = settings.Edgetec.FilesPath;

        // REPS (SQL Select REPCODE, NAME From $(vFINPath)\REPS)
        foreach (var r in db.Query($"SELECT REPCODE, NAME {db.From("REPS")}", r => (Code: r.GetString("REPCODE"), Name: r.GetString("NAME"))))
            if (!string.IsNullOrEmpty(r.Code))
                lk.RepNameByCode[r.Code] = r.Name;

        // ACCOUNTS.TXT - Map_AccountTypes' exact INTREF cascade, and Map_AccountName.
        foreach (var row in DelimitedFile.ReadWithHeader(Path.Combine(filesPath, "ACCOUNTS.TXT")))
        {
            var accno = row.GetValueOrDefault("ACCNO", "");
            if (string.IsNullOrEmpty(accno)) continue;
            var intref = row.GetValueOrDefault("INTREF", "");
            lk.MarketByAccno[accno] = intref switch
            {
                "ENTERPRISE" => "ENTERPRISE",
                "MID" => "MID MARKET JHB",
                "MID-CPT" => "MID MARKET CPT",
                "MID-DBN" => "MID MARKET DBN",
                "MID-ELS" => "MID MARKET ELS",
                "ENT-CPT" => "ENTERPRISE CPT",
                _ => "OTHER",
            };
            lk.CustomerNameByAccno[accno] = row.GetValueOrDefault("NAME", "");
        }

        // STOCK.TXT - MAP1/MAP2 (reversed CSTACC/SALACC -> STOCKNO) and STOCKNO -> GROUP.
        foreach (var row in DelimitedFile.ReadWithHeader(Path.Combine(filesPath, "STOCK.TXT")))
        {
            var stockNo = row.GetValueOrDefault("STOCKNO", "");
            if (string.IsNullOrEmpty(stockNo)) continue;

            var cstacc = row.GetValueOrDefault("CSTACC", "");
            if (cstacc.Length >= 3)
                lk.Map1LedgerStockNoByCostLedgerNo[cstacc[^3..]] = stockNo;

            var salacc = row.GetValueOrDefault("SALACC", "");
            if (salacc.Length >= 3)
                lk.Map2LedgerStockNoBySaleLedgerNo[salacc[^3..]] = stockNo;

            lk.GroupCodeByStockNo[stockNo] = row.GetValueOrDefault("GROUP", "");
        }

        // STOCKCAT (SQL SELECT CATEGORY, DESCRIP, TYPE From $(vFINPath)\STOCKCAT).
        foreach (var r in db.Query($"SELECT CATEGORY, DESCRIP, TYPE {db.From("STOCKCAT")}",
            r => (Category: r.GetString("CATEGORY"), Descrip: r.GetString("DESCRIP"), Type: r.GetString("TYPE"))))
        {
            if (string.IsNullOrEmpty(r.Category)) continue;
            if (r.Type == "C") lk.CategoryDescriptionByCode[r.Category] = r.Descrip;
            else if (r.Type == "G") lk.GroupDescriptionByCode[r.Category] = r.Descrip;
        }

        // Edgetec Formats.xlsx, sheet "Stock" - LEDGER_NO, CATEGORY, CATEGORY_TYPE, SALES_SERVICE.
        var formatsPath = Path.Combine(filesPath, "Edgetec Formats.xlsx");
        using (var wb = new XLWorkbook(formatsPath))
        {
            var ws = wb.Worksheet("Stock");
            var headerRow = ws.FirstRowUsed();
            var colByName = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
            foreach (var cell in headerRow.CellsUsed())
                colByName[cell.GetString().Trim()] = cell.Address.ColumnNumber;

            string Cell(IXLRow row, string col) =>
                colByName.TryGetValue(col, out var c) ? row.Cell(c).GetString().Trim() : "";

            foreach (var row in ws.RowsUsed().Skip(1))
            {
                var ledgerNo = Cell(row, "LEDGER_NO");
                if (string.IsNullOrEmpty(ledgerNo)) continue;

                // The workbook stores most LEDGER_NO values that need a leading zero (e.g.
                // "010") as Excel text cells, and the rest (100, 150, 160...) as plain numbers -
                // consistent as long as it's read back faithfully, but GLNO's own Right(GLNO,3)
                // is always exactly 3 characters, so pad defensively here too rather than trust
                // that every cell in every future edit of this file keeps following that
                // convention.
                if (ledgerNo.Length < 3 && ledgerNo.All(char.IsDigit))
                    ledgerNo = ledgerNo.PadLeft(3, '0');

                lk.FormatByLedgerNo[ledgerNo] = new EdgetecLedgerFormat(
                    CategoryCode: Cell(row, "CATEGORY"),
                    CategoryType: Cell(row, "CATEGORY_TYPE"),
                    SalesService: Cell(row, "SALES_SERVICE"));
            }
        }

        return lk;
    }
}
