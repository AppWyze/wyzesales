using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using WyzeSalesExtract.Config;
using WyzeSalesExtract.Domain;
using WyzeSalesExtract.Logging;
using WyzeSalesExtract.ServiceInstall;
using WyzeSalesExtract.Worker;

// .NET (unlike the old .NET Framework CLR) doesn't ship legacy Windows code pages built in -
// only Unicode (UTF-8/16/32) and ASCII are available out of the box, specifically to keep the
// runtime's footprint down. Edgetec's STOCK.TXT/ACCOUNTS.TXT are Windows-1252 (the original
// QlikView script's own "codepage is 1252" setting - see Data/DelimitedFile.cs), and
// Encoding.GetEncoding(1252) throws NotSupportedException without this provider registered
// first - confirmed live on Edgetec's own server, 2026-10-01 ("No data is available for
// encoding 1252"), the first real run past the earlier REPS.DBF permissions fix. Must run
// before anything that could call DelimitedFile.ReadWithHeader, so this sits as the very first
// statement in the program, ahead of even --selftest (which doesn't need it, but there's no
// reason to register it any later than "as early as possible, exactly once").
System.Text.Encoding.RegisterProvider(System.Text.CodePagesEncodingProvider.Instance);

// --selftest: proves the date-math cleanup (FiscalDate) is equivalent to the original
// script's nested-If logic. Needs no database and no config file - run this first on a new
// machine / after any date-logic change.
if (args.Contains("--selftest"))
    return SelfTest.Run(Console.Out) ? 0 : 1;

// install / uninstall: registers (or removes) this exe as a Windows Service. Needs an
// elevated (Administrator) prompt - see README "Install as a service".
if (args.Length > 0 && args[0].Equals("install", StringComparison.OrdinalIgnoreCase))
    return ServiceInstaller.Install();
if (args.Length > 0 && args[0].Equals("uninstall", StringComparison.OrdinalIgnoreCase))
    return ServiceInstaller.Uninstall();

string configPath = "appsettings.json";
var configArgIndex = Array.IndexOf(args, "--config");
if (configArgIndex >= 0 && configArgIndex + 1 < args.Length)
    configPath = args[configArgIndex + 1];

// 2026-09-30, Edgetec: installed as a service, then every startup log entry read "Config
// file not found: appsettings.json" even though the file was right there next to the exe -
// interactive `WyzeSalesExtract.exe` runs from that same folder worked fine. Root cause: a
// relative path resolves against the PROCESS's current directory, and the Windows Service
// Control Manager does not launch a service with its cwd set to the exe's own folder - it's
// %SystemRoot%\System32 (a well-known .NET Windows Service pitfall, unrelated to
// UseWindowsService() below, which fixes the *hosting* framework's own ContentRootPath but
// has no effect on a plain File.Exists/File.ReadAllText call like AppSettings.Load's own, or
// ServiceInstaller.TryReadClientCode's). An interactive run (typed from inside
// C:\WyzeSalesExtract, as in every README example, and as `install` itself always is) never
// hits this - which is exactly why it passed manual testing, why the service still got
// registered under the right name at install time, and why it only broke once the service
// was actually started by Windows itself. Log.cs's own fallback-log path already anchors on
// AppContext.BaseDirectory for precisely this reason (see its constructor) - applying the
// same fix here so this resolves the same way regardless of what launched this process or
// what its current directory happens to be. Only rewrites a RELATIVE path (the default
// "appsettings.json", or a relative --config value) - an already-absolute --config path,
// e.g. `--config D:\other\appsettings.json`, is left exactly as given.
if (!Path.IsPathRooted(configPath))
    configPath = Path.Combine(AppContext.BaseDirectory, configPath);

// --run-once: does a single extract-and-write-to-Supabase run and exits, ignoring
// Schedule.RunTimes. This is the manual/validation mode - use this to test config changes
// without waiting for the clock.
if (args.Contains("--run-once"))
{
    AppSettings settings;
    try
    {
        settings = AppSettings.Load(configPath);
    }
    catch (Exception ex)
    {
        Console.Error.WriteLine($"FATAL: could not load config '{configPath}': {ex.Message}");
        return 2;
    }

    using var log = new Log(settings.Logging.LogFolder);
    return await ExtractRunner.RunOnceAsync(settings, log);
}

// Default mode: run persistently and wait for the times configured in Schedule.RunTimes.
// UseWindowsService() makes this behave correctly either way it's launched - as a real
// Windows Service (after `install`, started by Windows itself) or interactively (e.g. run
// from a console while testing) - without any other code here needing to know which. The
// service name matches whatever ServiceInstaller.Install() actually registered (derived from
// appsettings.json's Supabase.ClientCode), not a hardcoded one - see ServiceInstaller's own
// remarks.
//
// Passing the already-resolved (now-absolute) configPath here, not letting
// ResolveServiceIdentity fall back to its own separate relative DefaultConfigPath - that
// fallback is exactly the same relative-path-under-the-wrong-cwd trap as the config-loading
// fix just above, just silent instead of loud: TryReadClientCode swallows a missing-file
// FileNotFoundException entirely and quietly defaults to "WCSA", so under a service's real
// cwd this would silently register/report the WRONG service identity to Windows instead of
// visibly failing - not what broke Edgetec's run (that was AppSettings.Load, above), but the
// same root cause and worth closing at the same time rather than leaving a second latent copy
// of it.
var (serviceName, _) = ServiceInstaller.ResolveServiceIdentity(configPath);
var builder = Host.CreateDefaultBuilder(args)
    .UseWindowsService(options => options.ServiceName = serviceName)
    .ConfigureServices(services =>
    {
        services.AddSingleton(new WorkerOptions(configPath));
        services.AddHostedService<ExtractWorker>();
    });

using var host = builder.Build();
await host.RunAsync();
return 0;
