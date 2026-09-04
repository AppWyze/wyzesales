using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using WyzeSalesExtract.Config;
using WyzeSalesExtract.Domain;
using WyzeSalesExtract.Logging;
using WyzeSalesExtract.ServiceInstall;
using WyzeSalesExtract.Worker;

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
// from a console while testing) - without any other code here needing to know which.
var builder = Host.CreateDefaultBuilder(args)
    .UseWindowsService(options => options.ServiceName = ServiceInstaller.ServiceName)
    .ConfigureServices(services =>
    {
        services.AddSingleton(new WorkerOptions(configPath));
        services.AddHostedService<ExtractWorker>();
    });

using var host = builder.Build();
await host.RunAsync();
return 0;
