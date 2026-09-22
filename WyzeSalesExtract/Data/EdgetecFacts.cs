namespace WyzeSalesExtract.Data;

/// <summary>One GLTRANS row for a '110' (sale) or '150' (cost) ledger account - the raw
/// building block EdgetecSourceExtractor groups and sums into SalesDocumentFact rows. Amount
/// is the raw GLTRANS.AMOUNT, unmodified (sign handling happens where it's turned into
/// Value/Cost, since sale and cost lines are signed differently - see
/// EdgetecSourceExtractor).</summary>
public sealed record EdgetecGlLine(
    string DocNo,
    string Projno,
    string Entry,       // 'I' | 'C' | 'J' | 'A' - see DocumentKind mapping in EdgetecSourceExtractor
    string GlNo,
    DateTime Date,
    decimal Amount,
    bool IsSaleLedger);  // true: GLNO starts '110' (feeds Value); false: '150' (feeds Cost)

/// <summary>
/// Everything built from GLTRANS/STTRANS themselves rather than from static reference data
/// (that's EdgetecLookups) - the C# equivalent of the script's DOCNO/DOCNO&amp;ACCNO-keyed
/// Mapping Loads (Map_DocumentNumber, Map_Quantity, Map_RepCode, Map_SalesStockNo,
/// Map_SalesStockCost, Map_SalesStockAmount).
///
/// STTRANS carries no date column at all (confirmed from the original script's own SELECT
/// list), so it can't be filtered by DataWindow.EarliestLoadDate the way GLTRANS is - it's
/// pulled here in full, same as GLTRANS was in the original script (this program adds the
/// GLTRANS date filter itself; STTRANS stays an unconditional lookup table exactly like the
/// original, just without the 2024SEP archive concatenation, which DataWindow.EarliestLoadDate
/// makes unnecessary - see DataWindowSettings' own remarks).
/// </summary>
public sealed class EdgetecFacts
{
    // Map_DocumentNumber / Map_Quantity - DOCNO alone.
    public Dictionary<string, string> AccnoByDocNo { get; } = new(StringComparer.OrdinalIgnoreCase);
    public Dictionary<string, decimal> QuantityByDocNo { get; } = new(StringComparer.OrdinalIgnoreCase);

    // Map_RepCode / Map_SalesStockNo / Map_SalesStockCost / Map_SalesStockAmount - DOCNO&ACCNO.
    public Dictionary<string, string> RepByDocAccno { get; } = new(StringComparer.OrdinalIgnoreCase);
    public Dictionary<string, string> ItemCodeByDocAccno { get; } = new(StringComparer.OrdinalIgnoreCase);

    // The GLTRANS-sourced rep override: DOCNO&PROJNO -> REFDOCNO, only when REFDOCNO trims to
    // exactly 3 characters - the same "3-character rep code" convention WCSA's own ACCNUM
    // override uses (see SalesDocumentFactsBuilder's remarks on that). Layered ON TOP of
    // RepByDocAccno above (built second, applied second) since a deliberately-entered 3-
    // character correction on the GL line itself reads as an intentional override, not
    // something that should lose to whatever STTRANS happened to say.
    public Dictionary<string, string> RepOverrideByDocProjno { get; } = new(StringComparer.OrdinalIgnoreCase);

    public List<EdgetecGlLine> GlLines { get; } = new();

    public static EdgetecFacts Load(EdgetecDb db, DateTime sinceDate)
    {
        var facts = new EdgetecFacts();

        // STTRANS (SQL Select DOCNO, REP, STOCKNO, QTY, COST, RETAIL, ACCNO From ...\STTRANS) -
        // unconditional, see class remarks. Last row per key wins, matching a plain resident-
        // table Mapping Load with no explicit tie-break rule of its own.
        foreach (var r in db.Query($"SELECT DOCNO, REP, STOCKNO, QTY, COST, RETAIL, ACCNO {db.From("STTRANS")}", r => new
        {
            DocNo = r.GetString("DOCNO"),
            Rep = r.GetString("REP"),
            StockNo = r.GetString("STOCKNO"),
            Qty = r.GetDecimal("QTY"),
            Accno = r.GetString("ACCNO"),
        }))
        {
            if (string.IsNullOrEmpty(r.DocNo)) continue;
            facts.AccnoByDocNo[r.DocNo] = r.Accno;
            facts.QuantityByDocNo[r.DocNo] = r.Qty;

            var docAccno = r.DocNo + r.Accno;
            if (!string.IsNullOrEmpty(r.Rep)) facts.RepByDocAccno[docAccno] = r.Rep;
            if (!string.IsNullOrEmpty(r.StockNo)) facts.ItemCodeByDocAccno[docAccno] = r.StockNo;
        }

        // GLTRANS, the REFDOCNO-as-rep override rows (Concatenate STOCK_TRANSACTIONS: Load
        // DOCNO, PROJNO as ACCNO, REFDOCNO as REP where len(trim(REFDOCNO)) = 3; ... where
        // left(GLNO,3) = '110' or left(GLNO,3) = '150'). Pulled from the same unconditional
        // GLTRANS query below rather than a second round trip - see the main GLTRANS load.

        // GLTRANS - unconditional (same reasoning as STTRANS above: no WHERE clause the
        // original script's own SQL didn't have). GLTRANS carries BOTH a REF column (unused -
        // it never makes it into the script's own final output, confirmed by reading every
        // field the script actually selects into Table_A) and a separate REFDOCNO column (the
        // rep-override source below) - selecting REFDOCNO here, not REF; the two are easy to
        // conflate but are genuinely different columns in the original script.
        // Filtered here in C#: GLNO must start '110' or '150' (the two account prefixes this
        // program cares about at all), the two suspense/contra accounts are dropped, and DATE
        // must be on or after sinceDate (the DataWindow.EarliestLoadDate floor) - this last
        // filter is this program's own addition, replacing the original script's 2024SEP-
        // archive-concatenation + PERIOD-shifting mechanism, which only existed to build a
        // rolling historical window and is unnecessary now that history before sinceDate is
        // separately protected/verified.
        foreach (var r in db.Query($"SELECT AMOUNT, DATE, DOCNO, ENTRY, GLNO, PROJNO, REFDOCNO {db.From("GLTRANS")}", r => new
        {
            Amount = r.GetDecimal("AMOUNT"),
            Date = r.GetDateOrNull("DATE"),
            DocNo = r.GetString("DOCNO"),
            Entry = r.GetString("ENTRY"),
            GlNo = r.GetString("GLNO"),
            Projno = r.GetString("PROJNO"),
            Refdocno = r.GetString("REFDOCNO"),
        }))
        {
            if (string.IsNullOrEmpty(r.DocNo) || string.IsNullOrEmpty(r.GlNo)) continue;
            if (r.GlNo == "110999" || r.GlNo == "150999") continue; // suspense/contra
            var isSale = r.GlNo.StartsWith("110", StringComparison.Ordinal);
            var isCost = r.GlNo.StartsWith("150", StringComparison.Ordinal);
            if (!isSale && !isCost) continue;
            if (r.Date is null || r.Date.Value < sinceDate) continue;

            facts.GlLines.Add(new EdgetecGlLine(r.DocNo, r.Projno, r.Entry, r.GlNo, r.Date.Value, r.Amount, isSale));

            var refdocno = r.Refdocno.Trim();
            if (refdocno.Length == 3 && !string.IsNullOrEmpty(r.Projno))
                facts.RepOverrideByDocProjno[r.DocNo + r.Projno] = refdocno;
        }

        return facts;
    }
}
