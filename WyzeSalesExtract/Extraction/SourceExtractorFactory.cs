namespace WyzeSalesExtract.Extraction;

/// <summary>
/// Picks which client's extractor to run, from Source.Type in appsettings.json. Defaults to
/// "WCSA" (see Config/AppSettings.cs's SourceSettings) so WCSA's existing deployed config -
/// which predates this setting entirely - keeps working with zero changes and no migration.
///
/// Register each new client's extractor here as it's built (Edgetec next, then Morgenster,
/// then whoever follows) - there's nowhere else in the program that needs to know the list.
/// </summary>
public static class SourceExtractorFactory
{
    public static ISourceExtractor Create(string sourceType) => sourceType switch
    {
        "WCSA" => new WcsaSourceExtractor(),
        _ => throw new NotSupportedException(
            $"No extractor registered for Source.Type '{sourceType}'. " +
            "Add one to SourceExtractorFactory.Create once that client's extractor is built - " +
            "see README \"Adding a new client\"."),
    };
}
