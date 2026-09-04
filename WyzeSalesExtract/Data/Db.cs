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
        return r.IsDBNull(ord) ? "" : r.GetValue(ord).ToString() ?? "";
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
