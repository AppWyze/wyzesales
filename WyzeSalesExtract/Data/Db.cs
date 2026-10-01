using System.Data;
using System.Data.Odbc;
using WyzeSalesExtract.Config;

namespace WyzeSalesExtract.Data;

/// <summary>
/// Thin ODBC access layer. Every SQL statement below is copied as literally as possible
/// from the original QlikView script (WCSA_Extract.txt) - same table names, same column
/// lists, no added WHERE clauses - so behaviour against the IQRetail/Pervasive ODBC driver
/// stays identical. Filtering that the original did inside QlikView's LOAD statement is
/// still done in C# after the rows land in memory, for the same reason.
/// </summary>
public sealed class Db : IDisposable
{
    private readonly OdbcConnection _conn;
    public string BasePath { get; }

    public Db(AppSettings settings)
    {
        BasePath = settings.Database.BasePath;
        _conn = new OdbcConnection(settings.GetConnectionString());
        _conn.Open();
    }

    /// <summary>Builds "FROM "&lt;BasePath&gt;"\TableName" exactly like the original script.</summary>
    public string From(string table) => $"FROM \"{BasePath}\"\\{table}";

    public List<T> Query<T>(string sql, Func<OdbcDataReader, T> map)
    {
        using var cmd = new OdbcCommand(sql, _conn) { CommandTimeout = 300 };
        using var reader = cmd.ExecuteReader();
        var results = new List<T>();
        while (reader.Read())
            results.Add(map(reader));
        return results;
    }

    public void Dispose()
    {
        _conn.Dispose();
    }
}

/// <summary>Null-safe column readers plus the exact text-cleaning rules the QVS applies inline.</summary>
public static class Row
{
    public static string GetString(this OdbcDataReader r, string col)
    {
        var ord = r.GetOrdinal(col);
        var value = r.IsDBNull(ord) ? "" : r.GetValue(ord).ToString() ?? "";
        // Postgres' text type flatly rejects an embedded null byte (0x00), regardless of
        // encoding - "invalid byte sequence for encoding UTF8: 0x00" on whatever insert hits
        // it first, the whole batch failing even though every OTHER field in it is fine.
        // Morgenster's driver (Sage Pastel Partner / Pervasive PSQL, fixed-width CHAR columns)
        // pads unused space in some columns with null bytes rather than spaces - confirmed live,
        // 2026-10-01: ReplaceSalesDocumentFactsAsync failed with exactly this error on Craig's
        // first clean run (the earlier FK-violation run never got this far). .NET's ODBC driver
        // passes that padding straight through as literal '\0' characters with no trimming of
        // its own. Stripped here, in the one shared reader every client's Db/EdgetecDb/
        // MorgensterDb funnels every string column through, rather than in each client's own
        // extractor - this is pure defensive sanitization (a null byte is invisible, non-printable
        // padding with no business meaning in any of these fields), not a change to the actual
        // data, so it's correct to apply it everywhere a string comes off any client's ODBC
        // driver, not just Morgenster's.
        return value.IndexOf('\0') >= 0 ? value.Replace("\0", "") : value;
    }

    public static decimal GetDecimal(this OdbcDataReader r, string col)
    {
        var ord = r.GetOrdinal(col);
        if (r.IsDBNull(ord)) return 0m;
        return Convert.ToDecimal(r.GetValue(ord));
    }

    public static DateTime? GetDateOrNull(this OdbcDataReader r, string col)
    {
        var ord = r.GetOrdinal(col);
        if (r.IsDBNull(ord)) return null;
        return Convert.ToDateTime(r.GetValue(ord));
    }

    public static DateTime GetDate(this OdbcDataReader r, string col) =>
        GetDateOrNull(r, col) ?? default;

    // Replace(x, Chr(34), 'in')  -- QVS uses this on item/stock codes so a literal "
    // (inch mark) in a part number doesn't break anything downstream.
    public static string ReplaceQuoteWithIn(string s) => s.Replace("\"", "in");

    // Replace(x, Chr(39), 'in')  -- second-stage cleanup applied to item names.
    public static string ReplaceApostropheWithIn(string s) => s.Replace("'", "in");

    // Replace(NAME, Chr(39), '') -- customer names strip apostrophes entirely (different
    // rule to the item-name one above - kept distinct deliberately, do not merge them).
    public static string StripApostrophe(string s) => s.Replace("'", "");
}
