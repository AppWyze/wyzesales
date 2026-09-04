namespace WyzeSalesExtract.Worker;

/// <summary>The one thing ExtractWorker needs handed in from Program.cs via dependency injection.</summary>
public sealed record WorkerOptions(string ConfigPath);
