namespace WyzeSalesExtract.Data;

/// <summary>
/// Minimal comma-delimited text file reader for Edgetec's two flat-file sources (STOCK.TXT,
/// ACCOUNTS.TXT) - the QlikView script loads both as "(txt, codepage is 1252, embedded
/// labels, delimiter is ',', msq)". "msq" is QlikView's "multiple single quotes" quoting mode:
/// a field can be wrapped in double quotes to contain a literal comma, with "" inside a quoted
/// field meaning one literal quote character. This is the same shape as a standard RFC 4180
/// CSV, so rather than add a NuGet dependency for two small files, this is a plain, reviewable
/// parser for exactly that shape - no external package, nothing exotic.
/// </summary>
public static class DelimitedFile
{
    /// <summary>Reads a comma-delimited file with an embedded header row (first line = column
    /// names) into a list of column-name-keyed dictionaries, one per data row. Windows-1252
    /// encoded, matching the script's own "codepage is 1252".</summary>
    public static List<Dictionary<string, string>> ReadWithHeader(string path)
    {
        var encoding = System.Text.Encoding.GetEncoding(1252);
        var lines = File.ReadAllLines(path, encoding);
        if (lines.Length == 0) return new List<Dictionary<string, string>>();

        var headers = ParseLine(lines[0]);
        var rows = new List<Dictionary<string, string>>();
        for (var i = 1; i < lines.Length; i++)
        {
            if (string.IsNullOrWhiteSpace(lines[i])) continue;
            var fields = ParseLine(lines[i]);
            var row = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            for (var c = 0; c < headers.Count; c++)
                row[headers[c]] = c < fields.Count ? fields[c] : "";
            rows.Add(row);
        }
        return rows;
    }

    /// <summary>Splits one comma-delimited line, honouring double-quoted fields (a comma inside
    /// quotes is not a delimiter, and "" inside a quoted field is one literal quote).</summary>
    private static List<string> ParseLine(string line)
    {
        var fields = new List<string>();
        var field = new System.Text.StringBuilder();
        var inQuotes = false;
        for (var i = 0; i < line.Length; i++)
        {
            var c = line[i];
            if (inQuotes)
            {
                if (c == '"' && i + 1 < line.Length && line[i + 1] == '"') { field.Append('"'); i++; }
                else if (c == '"') inQuotes = false;
                else field.Append(c);
            }
            else
            {
                if (c == '"') inQuotes = true;
                else if (c == ',') { fields.Add(field.ToString()); field.Clear(); }
                else field.Append(c);
            }
        }
        fields.Add(field.ToString());
        return fields;
    }
}
