using WyzeSalesExtract.Builders;
using WyzeSalesExtract.Config;
using WyzeSalesExtract.Domain;
using WyzeSalesExtract.Logging;

namespace WyzeSalesExtract.Extraction;

/// <summary>
/// The pluggable seam between "how do we get data out of THIS client's source system" and
/// everything else in this program, which doesn't need to know or care. Added 2026-09-22
/// (Craig: "let's build these and work through it systematically using Edgetec as the test")
/// as the first of two prerequisites for building a new client's extract program from a
/// design doc rather than forking the whole project - see README "Adding a new client".
///
/// Before this existed, ExtractRunner called WCSA's own Db/Lookups/Facts/Builders classes by
/// name, directly - there was no boundary a second client's logic could plug into without
/// copying and diverging the whole pipeline. This interface IS that boundary: implement it
/// once per client/source-system, and ExtractRunner, SupabaseWriter, the scheduler, and the
/// run-tracking never need a single line changed for a new client - they already only know
/// about the shared <see cref="ExtractedData"/> shape below, never about IQRetail, Fincon, or
/// whatever comes after Edgetec.
///
/// WCSA's existing behaviour was moved behind this interface unchanged - see
/// WcsaSourceExtractor - not rewritten. Nothing about what gets queried, how it's cleaned, or
/// what gets written to Supabase for WCSA is different after this refactor; only where that
/// logic lives changed. See WcsaSourceExtractor's own remarks for the one purely cosmetic
/// exception (a log-line reordering).
/// </summary>
public interface ISourceExtractor
{
    /// <summary>Pulls, cleans, and aggregates this client's source data into the one shape
    /// every client's data has to end up in (<see cref="ExtractedData"/>). Implementations log
    /// their own progress via <paramref name="ctx"/>.Log the same way ExtractRunner used to log
    /// each WCSA step directly - so log output for WCSA is unchanged (bar the one reordering
    /// noted on WcsaSourceExtractor) by this refactor.</summary>
    Task<ExtractedData> ExtractAsync(SourceExtractionContext ctx);
}

/// <summary>
/// Everything a source extractor needs that ISN'T specific to how it talks to its own source
/// system - gathered once by ExtractRunner from config and from Supabase (excluded accounts,
/// the history-window setting, the fiscal-year sales window) before any extractor is invoked,
/// so no per-client implementation has to know how to fetch these itself.
///
/// <paramref name="SalesWindowStart"/> is passed in already computed rather than left for each
/// extractor to derive - but note (see FiscalDate.FiscalYearWindowStart's own remarks) that
/// today's calculation assumes WCSA's own Mar-Feb fiscal year. A client with a different
/// fiscal year (Edgetec's design notes describe Oct-Sep) will need ExtractRunner's window-start
/// calculation generalised when that client's extractor is built - deliberately not guessed at
/// here ahead of that client's actual design doc.
/// </summary>
public sealed record SourceExtractionContext(
    AppSettings Settings,
    HashSet<string> ExcludedAccounts,
    int HistoryYears,
    DateTime Today,
    DateTime SalesWindowStart,
    Log Log);

/// <summary>
/// THE TEMPLATE. Every client's <see cref="ISourceExtractor"/> must hand back exactly this
/// shape - it's the same shape SupabaseWriter has always written, unchanged by this refactor.
/// A new client (Edgetec, Morgenster, ...) never adds a field here or changes what Supabase
/// receives; it only changes how these four things get populated from that client's own ERP.
/// If a genuinely new kind of fact or reference data is ever needed, it has to be added here
/// AND to SupabaseWriter AND to the Supabase schema all together - a deliberate, visible
/// three-place change, not something one client's extractor can quietly do on its own.
/// </summary>
public sealed record ExtractedData(
    ReferenceData ReferenceData,
    List<SalesDocumentFact> SalesDocumentFacts,
    List<StockMovementFact> StockMovementFacts,
    List<ItemStockSnapshotFact> ItemStockSnapshotFacts);
