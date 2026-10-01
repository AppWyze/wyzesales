using System.Data.Odbc;
using WyzeSalesExtract.Config;

namespace WyzeSalesExtract.Data;

/// <summary>
/// Thin ODBC access layer for Morgenster, mirroring Db.cs/EdgetecDb.cs's role for WCSA/Edgetec
/// but NOT sharing their code - same "each client's driver dialect is its own thing" reasoning
/// as EdgetecDb.cs's own remarks. Morgenster's driver (Sage Pastel Partner's Pervasive ODBC
/// Engine Interface, DSN "Morgen") is the simplest of the three so far: every query in the
/// original QlikView script ("Morgenster QV Extract.txt", uploaded by Craig 2026-10-01) is a
/// plain "SQL SELECT ... FROM MORGEN.TableName" - no quoted or unquoted path prefix, no network
/// drive mapping, no file-based fallback source. From() below exists only for consistency with
/// Db.cs/EdgetecDb.cs's shape, not because Morgenster's driver actually needs path-building help.
///
/// Confirmed 32-bit-only (Craig, 2026-10-01 - see Config/AppSettings.cs's MorgensterSettings
/// remarks) - this is why this client's publish step targets win-x86, not win-x64. Nothing in
/// this class itself differs for that reason; System.Data.Odbc works identically regardless of
/// process bitness, as long as the DSN the process is looking for is actually visible to it.
///
/// Same "copy the original script's SQL as literally as possible" discipline as every other
/// client's Db class: no WHERE clause is added here that the original script's own SQL didn't
/// have - filtering (SearchType, the date window, DocumentType-to-document_kind classification)
/// is done in C# after the rows land in memory, exactly like WCSA and Edgetec.
/// </summary>
public sealed class MorgensterDb : IDisposable
{
    private readonly OdbcConnection _conn;

    public MorgensterDb(AppSettings settings)
    {
        _conn = new OdbcConnection(settings.Morgenster.GetConnectionString());
        _conn.Open();
    }

    /// <summary>Builds "FROM MORGEN.TableName" - matching the original script's own
    /// "FROM MORGEN.TableName" exactly (no quoting, no path prefix).</summary>
    public string From(string table) => $"FROM MORGEN.{table}";

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
