using Microsoft.Extensions.Hosting;
using WyzeSalesExtract.Config;
using WyzeSalesExtract.Logging;

namespace WyzeSalesExtract.Worker;

/// <summary>
/// The background scheduler loop: waits until the next configured run time, runs the full
/// extract, then waits for the next one - forever, until the service is stopped. This is
/// what replaces Windows Task Scheduler - the timing logic lives inside this process instead
/// of depending on an external scheduler.
///
/// Runs identically whether launched interactively (Program.cs's default mode when you just
/// run the exe) or as a real Windows Service (after `WyzeSalesExtract.exe install`) - that
/// distinction is handled entirely by Program.cs's UseWindowsService() call, not by this class.
///
/// Resilience: a failure loading config, or a failure during an actual extract run, is
/// caught and logged here rather than allowed to crash the process - the loop always comes
/// back and waits for the next scheduled time. The one thing that DOES stop this loop is the
/// service itself being asked to stop (the CancellationToken), which is the correct behaviour.
/// Windows' own service-failure-recovery (configured by `install`, see ServiceInstaller) is
/// the backstop if the whole process ever dies unexpectedly anyway - it'll be restarted
/// automatically.
/// </summary>
public sealed class ExtractWorker : BackgroundService
{
    private readonly string _configPath;

    public ExtractWorker(WorkerOptions options)
    {
        _configPath = options.ConfigPath;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var bootLog = new Log(null); // console-only until a real config with a LogFolder loads successfully

        AppSettings? settings = TryLoadSettings(_configPath, bootLog);
        while (settings == null)
        {
            bootLog.Error($"Could not start: '{_configPath}' failed to load (see above). Will retry in 5 minutes - fix the config file in the meantime.");
            if (!await Wait(TimeSpan.FromMinutes(5), stoppingToken)) return;
            settings = TryLoadSettings(_configPath, bootLog);
        }

        bootLog.Info("WyzeSalesExtract service starting.");

        if (settings.Schedule.RunOnStartup)
        {
            bootLog.Info("Schedule.RunOnStartup is true - running once immediately before entering the schedule.");
            await RunOnceAndLogAsync(settings, bootLog);
        }

        while (!stoppingToken.IsCancellationRequested)
        {
            // Re-read config at the top of every cycle, so business-rule/path edits (and new
            // Schedule.RunTimes entries) take effect without a service restart.
            settings = TryLoadSettings(_configPath, bootLog) ?? settings;

            var times = ParseRunTimes(settings.Schedule.RunTimes, bootLog);
            if (times.Count == 0)
            {
                bootLog.Warn("Schedule.RunTimes is empty or invalid - nothing to do. Add at least one \"HH:mm\" entry to appsettings.json. Re-checking in 30 minutes.");
                if (!await Wait(TimeSpan.FromMinutes(30), stoppingToken)) return;
                continue;
            }

            var next = NextRunTime(times, DateTime.Now);
            bootLog.Info($"Next run scheduled for {next:yyyy-MM-dd HH:mm}.");

            if (!await Wait(next - DateTime.Now, stoppingToken)) return;

            await RunOnceAndLogAsync(settings, bootLog);
        }
    }

    private static async Task RunOnceAndLogAsync(AppSettings settings, Log bootLog)
    {
        try
        {
            using var runLog = new Log(settings.Logging.LogFolder);
            await ExtractRunner.RunOnceAsync(settings, runLog);
        }
        catch (Exception ex)
        {
            // Only reachable if even creating the per-run log file fails (e.g. LogFolder is
            // on a drive that just went away) - ExtractRunner.RunOnceAsync already catches and
            // logs everything else itself. Either way, the service keeps running.
            bootLog.Error("Scheduled run could not start.", ex);
        }
    }

    /// <summary>Waits, honouring cancellation. Returns false if the service was stopped during the wait.</summary>
    private static async Task<bool> Wait(TimeSpan delay, CancellationToken stoppingToken)
    {
        if (delay < TimeSpan.Zero) delay = TimeSpan.Zero;
        try
        {
            await Task.Delay(delay, stoppingToken);
            return true;
        }
        catch (TaskCanceledException)
        {
            return false;
        }
    }

    private static AppSettings? TryLoadSettings(string configPath, Log log)
    {
        try
        {
            return AppSettings.Load(configPath);
        }
        catch (Exception ex)
        {
            log.Error($"Failed to load '{configPath}'", ex);
            return null;
        }
    }

    internal static List<TimeOnly> ParseRunTimes(List<string> raw, Log log)
    {
        var times = new List<TimeOnly>();
        foreach (var entry in raw)
        {
            if (TimeOnly.TryParse(entry, out var t))
                times.Add(t);
            else
                log.Warn($"Ignoring invalid Schedule.RunTimes entry '{entry}' - expected 24-hour \"HH:mm\" format, e.g. \"06:00\".");
        }
        return times.Distinct().OrderBy(t => t).ToList();
    }

    /// <summary>The next occurrence (today if a time hasn't passed yet, otherwise the earliest
    /// time tomorrow) of any time in <paramref name="times"/>, relative to <paramref name="now"/>.
    /// No catch-up for missed times - matches a cron-like scheduler, not a queue.</summary>
    internal static DateTime NextRunTime(List<TimeOnly> times, DateTime now)
    {
        var today = DateOnly.FromDateTime(now);
        var nowTime = TimeOnly.FromDateTime(now);

        foreach (var t in times)
            if (t > nowTime)
                return today.ToDateTime(t);

        return today.AddDays(1).ToDateTime(times[0]);
    }
}
