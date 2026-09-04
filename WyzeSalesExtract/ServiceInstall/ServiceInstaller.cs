using System.Diagnostics;
using System.Security.Principal;

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
/// </summary>
public static class ServiceInstaller
{
    public const string ServiceName = "WyzeSalesExtractWCSA";
    public const string DisplayName = "WyzeSales Extract (WCSA)";

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

        string exePath = Environment.ProcessPath
            ?? throw new InvalidOperationException("Could not determine the running executable's path.");

        int createResult = RunSc($"create \"{ServiceName}\" binPath= \"{exePath}\" start= auto DisplayName= \"{DisplayName}\"");
        if (createResult != 0)
        {
            Console.Error.WriteLine(
                $"sc create failed (exit code {createResult}). If the service already exists, run " +
                "'WyzeSalesExtract.exe uninstall' first, then try installing again.");
            return createResult;
        }

        RunSc($"description \"{ServiceName}\" \"Runs the WCSA sales/stock extract on the schedule configured in appsettings.json and writes the results directly to Supabase. Installed by WyzeSalesExtract.exe install.\"");

        // Auto-restart on crash: up to 3 restarts (60s apart), then the recovery window
        // resets after 24h with no further failures. This is the safety net Task Scheduler
        // doesn't give you - if the process ever dies unexpectedly, Windows brings it back.
        RunSc($"failure \"{ServiceName}\" reset= 86400 actions= restart/60000/restart/60000/restart/60000");

        int startResult = RunSc($"start \"{ServiceName}\"");
        if (startResult != 0)
        {
            Console.WriteLine(
                $"Service installed but did not start automatically (exit code {startResult}). Check that " +
                "appsettings.json is next to the exe and correctly filled in, then start it from services.msc " +
                $"or run: net start \"{ServiceName}\"");
        }
        else
        {
            Console.WriteLine($"'{DisplayName}' installed and started. It will now start automatically every time this server boots.");
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

        RunSc($"stop \"{ServiceName}\""); // fine if it wasn't running - ignore this one's exit code
        int deleteResult = RunSc($"delete \"{ServiceName}\"");
        Console.WriteLine(deleteResult == 0
            ? "Service removed."
            : $"sc delete exited with code {deleteResult} - the service may not have been installed.");
        return deleteResult;
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
