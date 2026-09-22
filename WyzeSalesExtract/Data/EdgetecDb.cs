using System.Data.Odbc;
using WyzeSalesExtract.Config;

namespace WyzeSalesExtract.Data;

/// <summary>
/// Thin ODBC access layer for Edgetec, mirroring Db.cs's role for WCSA but NOT sharing its
/// code: Edgetec's ODBC driver (DSN "Edgetec64" in the original QlikView script) expects an
/// UNQUOTED path prefix in FROM clauses - "FROM Z:\GLTRANS" - where WCSA's IQRetail driver
/// requires the quoted form Db.cs's own From() builds ("FROM "C:\...\002"\Invoices"). Two
/// different ODBC drivers with two different SQL dialects is reason enough to keep these
/// separate rather than force a shared abstraction over a difference that's purely cosmetic
/// until it silently isn't - see README "Adding a new client" on why each client's extractor
/// is written as its own class rather than parameterizing WCSA's.
///
/// Same "copy the original script's SQL as literally as possible" discipline as Db.cs: no
/// WHERE clause is added here that the original QlikView script's own SQL didn't have -
/// filtering (date window, GLNO prefix, suspense-account exclusion) is done in C# after the
/// rows land in memory, exactly like WCSA. This also sidesteps needing to know whether
/// Edgetec's ODBC driver even supports parameterized date literals, which was never tested.
/// </summary>
public sealed class EdgetecDb : IDisposable
{
    private readonly OdbcConnection _conn;
    public string BasePath { get; }

    public EdgetecDb(AppSettings settings)
    {
        BasePath = settings.Edgetec.BasePath;
        _conn = new OdbcConnection(settings.Edgetec.GetConnectionString());
        _conn.Open();
    }

    /// <summary>Builds "FROM &lt;BasePath&gt;\TableName" - unquoted, matching the original
    /// script's own "From $(vFINPath)\TableName" exactly (vFINPath had no surrounding quotes
    /// in any of its uses).</summary>
    public string From(string table) => $"FROM {BasePath}\\{table}";

    public List<T> Query<T>(string sql, Func<OdbcDataReader, T> map)
    {
        using var cmd = new OdbcCommand(sql, _conn) { CommandTimeout = 300 };
        using var reader = cmd.ExecuteReader();
        var results = new List<T>();
        while (reader.Read())
            results.Add(map(reader));
        return results;
    }

    public void Dispose() => _conn.Dispose();
}
