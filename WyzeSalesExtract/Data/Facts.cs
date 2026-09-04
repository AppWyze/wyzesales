namespace WyzeSalesExtract.Data;

/// <summary>
/// Loads the raw invoice/credit-note line facts (the QVS "Table_A", lines 102-121). Loaded
/// once, unfiltered by date, and reused for both the TransactionWyzesales sales-data window
/// and the trailing stock-movement window - both now sized off the same configurable 3-or-5
/// -year history_years setting (ExtractRunner), but still just one shared in-memory table for
/// both purposes before it's dropped, exactly like the original script.
/// </summary>
public static class Facts
{
    public static List<InvoiceItemFact> LoadInvoiceItemFacts(Db db, IReadOnlyCollection<string> excludedAccounts)
    {
        var excluded = new HashSet<string>(excludedAccounts, StringComparer.OrdinalIgnoreCase);

        var sql = $"""
            SELECT ACCNUM, DOCUMENT, LINECOST * QTY as COST, LINETOTALEXCL as VALUE,
                   QTY, LDISCAM, PARTNO, Warehouse {db.From("INVITEMS")}
            """;

        var rows = db.Query(sql, r => new InvoiceItemFact(
            r.GetString("ACCNUM"),
            r.GetString("DOCUMENT"),
            r.GetDecimal("COST"),
            r.GetDecimal("VALUE"),
            r.GetDecimal("QTY"),
            r.GetDecimal("LDISCAM"),
            Row.ReplaceQuoteWithIn(r.GetString("PARTNO")),
            r.GetString("Warehouse")));

        return rows.Where(r => !excluded.Contains(r.AccNum)).ToList();
    }
}
