namespace WyzeSalesExtract.Logging;

/// <summary>
/// Minimal dependency-free logger: writes timestamped lines to the console and to a dated
/// log file. No external logging package is used so this stays lightweight.
///
/// Two things exist here specifically because this can now run as a real Windows Service
/// (no attached console at all): console output is best-effort (wrapped so a missing
/// console can never throw and take the process down), and passing a null/blank
/// <paramref name="logFolder"/> - which happens during startup before a config file has
/// successfully loaded - still writes somewhere durable (next to the exe) instead of
/// vanishing, so a broken appsettings.json is never silently invisible.
/// </summary>
public sealed class Log : IDisposable
{
    private readonly StreamWriter? _file;

    public Log(string? logFolder)
    {
        bool isFallback = string.IsNullOrWhiteSpace(logFolder);
        string folder = isFallback ? AppContext.BaseDirectory : logFolder!;
        string fileName = isFallback
            ? "WyzeSalesExtract_startup.log" // fixed name, appended to, so bootstrap/config failures accumulate rather than each getting silently overwritten
            : $"WyzeSalesExtract_{DateTime.Now:yyyyMMdd_HHmmss}.log";

        try
        {
            Directory.CreateDirectory(folder);
            var path = Path.Combine(folder, fileName);
            _file = new StreamWriter(path, append: isFallback) { AutoFlush = true };
        }
        catch
        {
            // Even the fallback location isn't writable - console (if any) is all that's left.
        }
    }

    public void Info(string message) => Write("INFO", message);
    public void Warn(string message) => Write("WARN", message);
    public void Error(string message) => Write("ERROR", message);

    public void Error(string message, Exception ex) =>
        Write("ERROR", $"{message}: {ex.GetType().Name}: {ex.Message}\n{ex.StackTrace}");

    private void Write(string level, string message)
    {
        var line = $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} [{level}] {message}";

        try
        {
            var color = level switch { "ERROR" => ConsoleColor.Red, "WARN" => ConsoleColor.Yellow, _ => Console.ForegroundColor };
            var prev = Console.ForegroundColor;
            Console.ForegroundColor = color;
            Console.WriteLine(line);
            Console.ForegroundColor = prev;
        }
        catch
        {
            // No console attached - normal when running as a Windows Service. The log file is authoritative.
        }

        _file?.WriteLine(line);
    }

    public void Dispose() => _file?.Dispose();
}
