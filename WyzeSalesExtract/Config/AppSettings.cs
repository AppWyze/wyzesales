using System.Text.Json;
using System.Text.Json.Serialization;

namespace WyzeSalesExtract.Config;

// Strongly-typed mirror of appsettings.json. Loaded with System.Text.Json (built into the
// runtime, no package needed) every time settings are (re)read - including once per
// scheduled run from ExtractWorker, so editing this file takes effect from the next run
// without restarting the Windows Service (except a change to Schedule.RunTimes itself,
// which only takes effect once the run currently being waited for fires - see README).
//
// Much shorter than it used to be: Output, BusinessRules, and Sftp are gone entirely - this
// program no longer writes files or uploads anything. Business-rule config (excluded
// accounts, the rep-override list, the supplier-suppression list) now lives as editable data
// in Supabase (excluded_customer_accounts, customers.attribute_to_assigned_rep, items.
// supplier_suppressed) instead of a config file here, so WCSA staff can change it directly
// without asking for a redeploy.

public sealed class AppSettings
{
    public DatabaseSettings Database { get; set; } = new();
    public SupabaseSettings Supabase { get; set; } = new();
    public FiscalYearSettings FiscalYear { get; set; } = new();
    public LoggingSettings Logging { get; set; } = new();
    public ScheduleSettings Schedule { get; set; } = new();

    public static AppSettings Load(string path)
    {
        if (!File.Exists(path))
            throw new FileNotFoundException($"Config file not found: {path}");

        var json = File.ReadAllText(path);
        var options = new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true,
            ReadCommentHandling = JsonCommentHandling.Skip,
            AllowTrailingCommas = true
        };
        var settings = JsonSerializer.Deserialize<AppSettings>(json, options)
            ?? throw new InvalidOperationException("Config file was empty or invalid.");

        settings.Validate();
        return settings;
    }

    private void Validate()
    {
        var problems = new List<string>();

        if (string.IsNullOrWhiteSpace(Database.Dsn) && string.IsNullOrWhiteSpace(Database.ConnectionString))
            problems.Add("Database.Dsn or Database.ConnectionString must be set.");
        if (string.IsNullOrWhiteSpace(Database.BasePath))
            problems.Add("Database.BasePath must be set (the quoted path IQRetail uses in FROM clauses).");
        if (string.IsNullOrWhiteSpace(Supabase.ConnectionString))
            problems.Add("Supabase.ConnectionString must be set - see README \"Supabase connection\".");
        if (string.IsNullOrWhiteSpace(Supabase.ClientCode))
            problems.Add("Supabase.ClientCode must be set (e.g. \"WCSA\") - identifies which clients row this data belongs to.");

        if (problems.Count > 0)
            throw new InvalidOperationException("Config validation failed:\n - " + string.Join("\n - ", problems));
    }

    public string GetConnectionString()
    {
        if (!string.IsNullOrWhiteSpace(Database.ConnectionString))
            return Database.ConnectionString;
        return $"DSN={Database.Dsn};";
    }
}

public sealed class DatabaseSettings
{
    public string Dsn { get; set; } = "IQNew";
    public string? ConnectionString { get; set; }
    // The quoted path IQRetail's ODBC driver expects before the table name, e.g.
    // FROM "C:\IQRetail\IQEnterprise\002"\Invoices
    public string BasePath { get; set; } = "C:\\IQRetail\\IQEnterprise\\002";
}

public sealed class SupabaseSettings
{
    // A standard Postgres connection string to the Supabase project's database - e.g.
    // "Host=aws-0-eu-west-1.pooler.supabase.com;Port=5432;Database=postgres;Username=postgres.xxxx;Password=...;SSL Mode=Require"
    // Use the pooler connection string from Supabase's project settings (Session mode is
    // fine for this program - one connection, opened once per run, not per request).
    public string ConnectionString { get; set; } = "";

    // Identifies which row in the `clients` table this data belongs to (clients.code). Created
    // automatically on first run if it doesn't exist yet - see SupabaseWriter.
    public string ClientCode { get; set; } = "WCSA";
}

public sealed class FiscalYearSettings
{
    public int? OverrideYear { get; set; }
}

public sealed class LoggingSettings
{
    public string LogFolder { get; set; } = "C:\\WyzeSalesExtract\\Logs";
}

public sealed class ScheduleSettings
{
    // 24-hour "HH:mm" times, server local time, e.g. ["06:00", "14:00"]. Checked fresh at
    // the top of every wait cycle, so edits here are picked up without restarting the
    // service - except that a change only takes effect once the run currently being waited
    // for actually fires (the wait itself was already computed from the times in effect
    // when it started). Restart the service for an immediate change.
    public List<string> RunTimes { get; set; } = new();

    // If true, runs once immediately when the service starts, in addition to the configured
    // times - useful to "catch up" a run that was missed while the server was down. Defaults
    // to false (matches a scheduler that doesn't retroactively fire missed triggers).
    public bool RunOnStartup { get; set; } = false;
}
