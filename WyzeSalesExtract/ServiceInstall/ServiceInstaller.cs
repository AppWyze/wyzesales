using System.Diagnostics;
using System.Security.Principal;
using System.Text.Json;

namespace WyzeSalesExtract.ServiceInstall;

/// <summary>
/// Registers/removes this exe as a Windows Service using sc.exe (built into every Windows
/// install - no extra dependency for this piece). This is what makes "install" and
/// "uninstall" work from the command line.
///
/// A registered service is started by Windows itself at boot, before anyone logs in, and
/// - because Install() also configures failure-recovery actions - gets automatically
/// restarted by Windows if the process ever crashes. Both of those are things Task
/// Scheduler does not reliably give you.
///
/// The service name/display name are derived from appsettings.json's Supabase.ClientCode
/// (e.g. "WyzeSalesExtractEDGE" / "WyzeSales Extract (EDGE)") rather than hardcoded to WCSA -
/// added 2026-09-22 when this program first became multi-client (see
/// Extraction/ISourceExtractor.cs). A machine that only ever runs one client only ever needs
/// one of these installed, so there's no need to support several services from one exe at
/// once - just one name that actually matches whichever client this particular machine's
/// appsettings.json is configured for, instead of every installation everywhere saying
/// "WCSA" regardless of what it's actually running.
/// </summary>
public static class ServiceInstaller
{
    /// <summary>The config file every install/uninstall/service-start assumes - always the
    /// one next to the exe, same assumption Program.cs's default (non---run-once) mode
    /// makes. (`--config` only applies to `--run-once` - see README "Command-line options".)</summary>
    public const string DefaultConfigPath = "appsettings.json";

    /// <summary>Reads just Supabase.ClientCode out of appsettings.json (falling back to
    /// "WCSA" - AppSettings' own default - if the file is missing, unreadable, or doesn't
    /// set it) and derives this machine's service name and display name from it. Deliberately
    /// does NOT use AppSettings.Load (which calls Validate() and throws on an incomplete
    /// config) - naming the service shouldn't require every other setting to be filled in
    /// yet, and Install() already surfaces a clear error separately if the service fails to
    /// start because the config isn't ready.</summary>
    public static (string ServiceName, string DisplayName) ResolveServiceIdentity(string configPath = DefaultConfigPath)
    {
        var clientCode = TryReadClientCode(configPath) ?? "WCSA";
        var sanitized = SanitizeForServiceName(clientCode);
        return ($"WyzeSalesExtract{sanitized}", $"WyzeSales Extract ({clientCode})");
    }

    public static int Install()
    {
        if (!OperatingSystem.IsWindows())
        {
            Console.Error.WriteLine("Service install/uninstall only works on Windows.");
            return 2;
        }
        if (!IsElevated())
        {
            Console.Error.WriteLine(
                "Installing a Windows Service requires an elevated (Administrator) command prompt. " +
                "Right-click Command Prompt or PowerShell, choose 'Run as administrator', then run this command again.");
            return 2;
        }

        var (serviceName, displayName) = ResolveServiceIdentity();

        string exePath = Environment.ProcessPath
            ?? throw new InvalidOperationException("Could not determine the running executable's path.");

        int createResult = RunSc($"create \"{serviceName}\" binPath= \"{exePath}\" start= auto DisplayName= \"{displayName}\"");
        if (createResult != 0)
        {
            Console.Error.WriteLine(
                $"sc create failed (exit code {createResult}). If the service already exists, run " +
                "'WyzeSalesExtract.exe uninstall' first, then try installing again.");
            return createResult;
        }

        RunSc($"description \"{serviceName}\" \"Runs the sales/stock extract on the schedule configured in appsettings.json and writes the results directly to Supabase. Installed by WyzeSalesExtract.exe install.\"");

        // Auto-restart on crash: up to 3 restarts (60s apart), then the recovery window
        // resets after 24h with no further failures. This is the safety net Task Scheduler
        // doesn't give you - if the process ever dies unexpectedly, Windows brings it back.
        RunSc($"failure \"{serviceName}\" reset= 86400 actions= restart/60000/restart/60000/restart/60000");

        int startResult = RunSc($"start \"{serviceName}\"");
        if (startResult != 0)
        {
            Console.WriteLine(
                $"Service installed but did not start automatically (exit code {startResult}). Check that " +
                "appsettings.json is next to the exe and correctly filled in, then start it from services.msc " +
                $"or run: net start \"{serviceName}\"");
        }
        else
        {
            Console.WriteLine($"'{displayName}' installed and started. It will now start automatically every time this server boots.");
        }

        return 0;
    }

    public static int Uninstall()
    {
        if (!OperatingSystem.IsWindows())
        {
            Console.Error.WriteLine("Service install/uninstall only works on Windows.");
            return 2;
        }
        if (!IsElevated())
        {
            Console.Error.WriteLine("Uninstalling requires an elevated (Administrator) command prompt.");
            return 2;
        }

        var (serviceName, _) = ResolveServiceIdentity();

        RunSc($"stop \"{serviceName}\""); // fine if it wasn't running - ignore this one's exit code
        int deleteResult = RunSc($"delete \"{serviceName}\"");
        Console.WriteLine(deleteResult == 0
            ? "Service removed."
            : $"sc delete exited with code {deleteResult} - the service may not have been installed.");
        return deleteResult;
    }

    private static string? TryReadClientCode(string configPath)
    {
        try
        {
            if (!File.Exists(configPath)) return null;
            using var doc = JsonDocument.Parse(File.ReadAllText(configPath), new JsonDocumentOptions
            {
                CommentHandling = JsonCommentHandling.Skip,
                AllowTrailingCommas = true,
            });
            if (doc.RootElement.TryGetProperty("Supabase", out var supabase) &&
                supabase.TryGetProperty("ClientCode", out var codeProp) &&
                codeProp.ValueKind == JsonValueKind.String)
            {
                var code = codeProp.GetString();
                return string.IsNullOrWhiteSpace(code) ? null : code;
            }
        }
        catch
        {
            // Malformed/unreadable config - fall back to the default rather than fail
            // install/uninstall over something a config-validation step will catch anyway.
        }
        return null;
    }

    /// <summary>Windows service names can't contain spaces or most punctuation - strips
    /// everything but letters/digits and uppercases what's left, e.g. "EDGE" stays "EDGE",
    /// "Water Components SA" becomes "WATERCOMPONENTSSA". Falls back to "WCSA" if that leaves
    /// nothing (an empty or entirely-punctuation ClientCode).</summary>
    private static string SanitizeForServiceName(string clientCode)
    {
        var cleaned = new string(clientCode.Where(char.IsLetterOrDigit).ToArray()).ToUpperInvariant();
        return string.IsNullOrEmpty(cleaned) ? "WCSA" : cleaned;
    }

    private static int RunSc(string arguments)
    {
        var psi = new ProcessStartInfo("sc.exe", arguments)
        {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true
        };

        using var proc = Process.Start(psi) ?? throw new InvalidOperationException("Failed to start sc.exe.");
        string stdout = proc.StandardOutput.ReadToEnd();
        string stderr = proc.StandardError.ReadToEnd();
        proc.WaitForExit();

        if (!string.IsNullOrWhiteSpace(stdout)) Console.WriteLine(stdout.Trim());
        if (!string.IsNullOrWhiteSpace(stderr)) Console.Error.WriteLine(stderr.Trim());
        return proc.ExitCode;
    }

    private static bool IsElevated()
    {
        using var identity = WindowsIdentity.GetCurrent();
        var principal = new WindowsPrincipal(identity);
        return principal.IsInRole(WindowsBuiltInRole.Administrator);
    }
}
