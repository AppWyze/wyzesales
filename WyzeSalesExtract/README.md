# WyzeSalesExtract (WCSA)

A standalone Windows `.exe` that pulls raw sales, quote, sales-order, and
stock-movement data from IQRetail/IQ Enterprise (via ODBC) and writes it
directly into Supabase Postgres - no text files, no SFTP, no QlikView
license, no WinSCP, no Windows Task Scheduler required. Scheduling is built
in: install it once as a genuine Windows Service and it starts automatically
every time the server boots, runs in the background with nobody logged in,
and wakes itself up at whatever times you configure - see "Install as a
Windows Service" below.

**This is a second-generation rewrite of an earlier version of this program**
that wrote pipe-delimited text files and uploaded them over SFTP to a Xojo
cloud server. That version is retired - the architecture changed (see
`Wyzesales_Rebuild_Decisions.md`) so that all aggregation, business-rule
logic, and forecasting live in Supabase instead of in this program, meaning
WCSA staff can change a business rule (an excluded account, which customers
get attributed to their assigned rep, a suppressed supplier name) directly in
Supabase without needing this program rebuilt and redeployed.

## What this program does and doesn't do

**Does**: connects to WCSA's IQRetail database, pulls raw invoice/credit-note/
quote/sales-order line facts and reference data (customers, sales reps,
categories, suppliers, items) for the same windows the business already
agreed on (a rolling 3 fiscal years for sales documents, a trailing 36
months for stock movement), and writes all of it straight into Supabase.

**Does not**: resolve which rep or branch a sale counts toward, compute
category/profit/fiscal-year labels, apply the rep-override or supplier-
suppression business rules, or write anything derived/aggregated. All of
that is now a Postgres view or function in Supabase
(`schema/001_wyzesales_foundation.sql`, `002_wyzesales_rollups.sql`) - this
program's job stops at "raw facts, correctly extracted."

One deliberate exception, flagged in code: quote and sales-order rep
attribution. See the XML doc comment on
`SalesDocumentFactsBuilder.BuildQuotesOrOrders` for what it does and why.

## What changed vs. the original QlikView script

Carried forward from the first C# rewrite - still true:

- The ~24-line nested `If(Month(Today())='Mar',24, If(...='Apr',25, ...`
  chains (used to compute rolling date windows) are replaced with plain
  `DateTime` arithmetic in `Domain/FiscalDate.cs`. `--selftest` proves the
  replacement produces identical results to the original formula for every
  month across five years.
- The four separate `SELECT ... FROM STOCKLCNT` queries in the original were
  consolidated into one (same table, same rows).
- The fragile `CustomerName & ItemName & SalesPersonName & ...` string-concat
  grouping key was replaced with a proper composite key (`Domain/Keys.cs`)
  with real value equality (still used by the stock-movement builder).
- SQL text, table names, column lists, filter conditions, and sign-flip rules
  were ported as literally as possible from the original QVS.

New in this rewrite:

- All output-file generation, the SFTP upload, and every Builder that
  resolved category/rep-name/branch or applied business-rule config are
  gone. Replaced by `Data/SupabaseWriter.cs` and three much simpler builders
  (`SalesDocumentFactsBuilder`, `StockMovementFactsBuilder`,
  `ItemStockSnapshotBuilder`) that assemble raw rows only.
- The excluded-customer-accounts list now lives in Supabase
  (`excluded_customer_accounts`), read fresh at the start of every run,
  instead of `appsettings.json`. The sales-rep-override list and the
  supplier-suppression list are gone from this program entirely - they're
  now `customers.attribute_to_assigned_rep` and `items.supplier_suppressed`,
  flags Supabase resolves per row, editable directly by WCSA staff.
- A schema correction worth knowing about even though it doesn't change this
  program's code: an earlier draft of the Supabase schema tried to resolve
  branch via the selling rep's "assigned branch." That's been corrected -
  branch is resolved from each transaction's own warehouse code, which is
  what this program has always extracted (`Warehouse` off every line). See
  `Wyzesales_Schema_DesignNotes.md` Section 7.

## Two quirks preserved exactly in the source data, not silently fixed

The two bugs previously flagged in this program's Builders (the
`SalesAnalysis` Year1/Year2 profit swap, and the `ItemMaster` dead
lead-time fallback) don't apply to this rewrite - both lived in aggregation
logic that no longer exists in this program at all, and neither is
reproduced in the Supabase schema (see `Wyzesales_Rebuild_Decisions.md`
Section 2 for the full list of bugs fixed rather than preserved in the
rebuild). One small, deliberate cleanup carried into this version instead: a
supplier lead-time with no computable value is now written as `NULL`, not a
misleading `0` - see the XML doc comment on `ItemStockSnapshotBuilder` for
why that's safe (it doesn't change any lead-time figure that was ever
actually computed).

## `$(CheckYear)` assumption - still applies

`Domain/FiscalDate.CurrentFiscalYear()` still assumes the fiscal year is the
Mar-Feb year containing today's date - see `Domain/FiscalDate.cs`'s doc
comment for the full background on this assumption. You can override it for
testing via `appsettings.json` -> `FiscalYear.OverrideYear`.

## Project layout

```
Config/AppSettings.cs         appsettings.json -> strongly-typed settings (Source, Database, Supabase, FiscalYear, Schedule, Logging)
Extraction/ISourceExtractor.cs        The per-client plug-in point - see "Adding a new client" below
Extraction/SourceExtractorFactory.cs  Picks which client's extractor to run, from Source.Type
Extraction/WcsaSourceExtractor.cs     WCSA/IQRetail's extractor - wraps Data/Db+Lookups+Facts and Builders/* below, unchanged
Extraction/EdgetecSourceExtractor.cs  EDGETEC-SPECIFIC: wraps Data/EdgetecDb+EdgetecLookups+EdgetecFacts below - see "Adding a new client"
Data/Db.cs                    WCSA-SPECIFIC: IQRetail ODBC connection + query helper + the exact text-cleaning rules
Data/Lookups.cs                WCSA-SPECIFIC: all ~20 raw dimension pulls (customers, reps, categories, suppliers, stock counts, lead times)
Data/Facts.cs                  WCSA-SPECIFIC: the raw invoice/credit-note line facts
Data/EdgetecDb.cs             EDGETEC-SPECIFIC: Edgetec's own ODBC connection + query helper (unquoted FROM path - a different dialect from Data/Db.cs)
Data/EdgetecLookups.cs        EDGETEC-SPECIFIC: static reference data - REPS/STOCKCAT (ODBC), STOCK.TXT/ACCOUNTS.TXT (flat files), "Edgetec Formats.xlsx" (ClosedXML)
Data/EdgetecFacts.cs          EDGETEC-SPECIFIC: the raw GLTRANS/STTRANS-derived facts (DOCNO- and DOCNO&amp;ACCNO-keyed lookups, GL lines)
Data/DelimitedFile.cs         EDGETEC-SPECIFIC: small RFC4180-ish CSV reader for STOCK.TXT/ACCOUNTS.TXT (no NuGet dependency for two small files)
Data/SupabaseWriter.cs        SHARED by every client: everything written to Supabase - upserts for reference data, full replace for raw facts
Domain/FiscalDate.cs          Date-window math + the CheckYear assumption (WCSA's Mar-Feb fiscal year - see "Adding a new client")
Domain/SelfTest.cs            Proves FiscalDate matches the original logic - run with --selftest
Domain/Keys.cs                Composite dictionary keys
Domain/RawFacts.cs            SHARED: the raw row shapes every client's extractor must produce (SalesDocumentFact, StockMovementFact, ItemStockSnapshotFact) - see ExtractedData in Extraction/ISourceExtractor.cs
Builders/SalesDocumentFactsBuilder.cs   WCSA-SPECIFIC: invoices/credit notes/quotes/sales orders -> sales_document_facts rows
Builders/StockMovementFactsBuilder.cs   WCSA-SPECIFIC: 36/60-month item+location net movement -> stock_movement_facts rows
Builders/ItemStockSnapshotBuilder.cs    WCSA-SPECIFIC: point-in-time stock/pricing/lead-time -> item_stock_snapshot rows
Builders/ReferenceDataBuilder.cs        WCSA-SPECIFIC: assembles branches/reps/customers/categories/suppliers/items for upsert (produces the shared ReferenceData shape)
Logging/Log.cs                SHARED: minimal file+console logger, safe with or without an attached console
Worker/ExtractRunner.cs       SHARED: one full extract-and-write run - calls whichever ISourceExtractor Source.Type selects, then writes to Supabase
Worker/ExtractWorker.cs       SHARED: the background scheduler loop - waits for Schedule.RunTimes, then calls ExtractRunner
ServiceInstall/ServiceInstaller.cs   SHARED: install/uninstall - registers this exe as a Windows Service via sc.exe
Program.cs                    SHARED: dispatches to the above based on command-line args (see "Command-line options")
```

"SHARED" means every client uses this file unchanged. "WCSA-SPECIFIC"/"EDGETEC-SPECIFIC" means the file only exists to serve that one client's extractor - a new client gets its own equivalent files under `Extraction/`/`Data/`, not edits to these. Note Edgetec has no `Builders/*` files of its own: its dimension model (`client_dimensions`/`dim_N_code`) is simple enough that `EdgetecSourceExtractor.cs` builds `SalesDocumentFact` rows directly, without a separate Builders class the way WCSA's `Builders/SalesDocumentFactsBuilder.cs` does - and it writes no stock-movement or stock-snapshot facts at all (Edgetec's `ExtractedData` carries empty lists for both, since the original QlikView script never produced them).

## Adding a new client

Added 2026-09-22 alongside the `Extraction/ISourceExtractor.cs` refactor - Edgetec is the
first client built this way, and its extractor (`Extraction/EdgetecSourceExtractor.cs` and
`Data/EdgetecDb.cs`/`EdgetecLookups.cs`/`EdgetecFacts.cs`/`DelimitedFile.cs`) is now a complete,
real second example alongside WCSA, not just a forward reference to one - built from
`docs/WyzeSalesExtract_Edgetec_DesignNotes.md` and verified field-by-field against the original
QlikView "Edgetec Extract" script and Edgetec's live Supabase `client_dimensions` configuration.
WCSA was retrofitted onto the `ISourceExtractor` shape unchanged in behaviour.

The program is split into two halves. Everything under **SHARED** in "Project layout" above
(SupabaseWriter, the scheduler, run tracking, the Windows Service host, the raw row shapes in
`Domain/RawFacts.cs` and `Builders/ReferenceDataBuilder.cs`'s `ReferenceData`) is already
client-agnostic and needs zero changes for a new client. Everything marked **WCSA-SPECIFIC** or
**EDGETEC-SPECIFIC** is that one client's particular way of populating the shared shape from its
own source system, and neither is a template to copy-paste - each is an example of the *kind* of
code a new client's extractor contains, not content to reuse. In particular, don't reach for
Edgetec's flat-file (`DelimitedFile.cs`) or spreadsheet (ClosedXML) reading just because it's
there - use it only if the new client's own source data genuinely comes that way.

Building a new client means:

1. **A design doc**, written before any code - source ERP/database, connection mechanism (ODBC
   DSN vs. file-based vs. something else), the exact tables/fields needed for each part of
   `ExtractedData` (reference data, sales/quote/order facts, stock movement, stock snapshot),
   business rules (exclusions, rep-code overrides, account/category classification), the
   client's own fiscal year definition, and any file-based fallback sources. `docs/WyzeSalesExtract_Edgetec_DesignNotes.md`
   is the working example of this for Edgetec - expect a first pass to leave some of this open
   (it did for Edgetec) and get resolved through a couple of follow-up rounds, not all at once.

2. **One new class implementing `ISourceExtractor`** (`Extraction/EdgetecSourceExtractor.cs` is
   the real example), built from that design doc, returning the same `ExtractedData` shape
   WCSA's extractor returns - see `Extraction/WcsaSourceExtractor.cs` and
   `Extraction/EdgetecSourceExtractor.cs` side by side for the shape of what one of these looks
   like, not for logic to reuse: the two are deliberately different internally (WCSA groups
   already-shaped invoice/credit-note lines via `Builders/SalesDocumentFactsBuilder.cs`; Edgetec
   groups raw GLTRANS lines into `SalesDocumentFact` rows directly - see `EdgetecFacts.cs`'s own
   remarks on why it needs no separate Builders class). It's free to use whatever mechanism its
   source system needs internally (a different ODBC dialect, flat-file parsing, a spreadsheet, an
   API) - `ExtractRunner` never sees that difference.

3. **A settings section of its own** in `Config/AppSettings.cs` for whatever that client's
   extractor needs to connect (WCSA's is `DatabaseSettings` - Dsn/ConnectionString/BasePath;
   Edgetec's is `EdgetecSettings` - Dsn/ConnectionString/BasePath/FilesPath, the last one because
   Edgetec also reads flat files and a spreadsheet straight off disk, not just ODBC. A new client
   is not obligated to reuse either shape, since each is that source system's own connection
   details, not a generic contract) - plus a new `case` in `Extraction/SourceExtractorFactory.cs`
   and a new value for `Source.Type` in that client's `appsettings.json` (see
   `appsettings.example.json`'s `Edgetec` section for a worked example of this pattern).

4. **A check of the fiscal-year window-start calculation** in `Worker/ExtractRunner.cs` and
   `Domain/FiscalDate.cs` - both currently assume WCSA's Mar-Feb fiscal year (see
   `FiscalDate.FiscalYearWindowStart`'s own remarks). A client with a different fiscal year
   needs this generalised - unless `DataWindow.EarliestLoadDate` (below) applies, in which case
   this step can be skipped entirely for now.

5. **`DataWindow.EarliestLoadDate` (`Config/AppSettings.cs`) - set this when a client is being
   onboarded with an already-verified prior extract**, e.g. Edgetec: "We already have a full set
   of data up until 7 September 2026 which we confirmed balances to the old (current) version of
   wyzesales. So we just need to build from there without duplicating." When set, it's a hard
   floor: `ExtractRunner` uses it as the sales window's start date instead of computing one from
   `FiscalYear`/`historyYears` (so step 4 above can wait), and passes it through to
   `SupabaseWriter.ReplaceSalesDocumentFactsAsync`/`ReplaceStockMovementFactsAsync` as
   `sinceDate`, which narrows their delete-and-replace to that date forward - structurally
   impossible for a run to touch anything earlier. Leave it unset (the default) for a client
   with no separate prior extract to protect, like WCSA - both methods keep their original
   full-per-client-wipe behaviour when `sinceDate` isn't passed.

6. **A `--run-once` test run** against real data before that client goes onto a schedule - the
   design doc and the code built from it are both unproven until data has actually come back
   from the real source system once. Check `data_load_runs` in Supabase for the result. Edgetec's
   extractor has been built and its field-by-field logic verified against the original QlikView
   script and real historical data, but as of this writing it still needs its actual ODBC
   DSN/connection string and `FilesPath` filled into `appsettings.json`'s `Edgetec` section before
   a real `--run-once` against Edgetec's live server is possible - that first real run is the
   only true proof this extractor is correct, design review and code reading aren't a substitute
   for it.

What deliberately does NOT change for a new client: the Supabase schema, the scheduler, the
Windows Service install/uninstall, or anything in the Flutter app that reads this data - all of
it already only knows about the shared `ExtractedData` shape, never about any one client's
source system. `Data/SupabaseWriter.cs`'s row-writing logic doesn't change either, though its
two window-replace methods do take the optional `sinceDate` described in step 5 above.

## Setup

Same two-machine workflow as before: **build** on a machine with the .NET
SDK and internet access, then **copy just the finished exe** to the
production server. The server needs nothing extra installed beyond what it
already has - the IQRetail ODBC driver with the `IQNew` DSN configured. No
WinSCP, no SSH client - this program talks to Supabase over a plain Postgres
connection (SSL), the same way any Postgres client would.

### 1. On your build machine (PC or laptop)

Install the [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0),
then from the project folder:

```
dotnet restore
dotnet publish -c Release -o publish
```

That produces a `publish` folder containing **one file**,
`WyzeSalesExtract.exe`, plus `appsettings.json` next to it.

**Important - this build environment could not reach nuget.org** (a sandbox
network restriction, not a WCSA-side issue), so `Data/SupabaseWriter.cs` -
the one file in this rewrite that calls into a new package (Npgsql) - has
had careful manual review but **no real compiler pass against the actual
Npgsql library**. Everything else (the builders, the date math, the
lookups, `Data/Db.cs`'s `System.Data.Odbc` usage, the
`Microsoft.Extensions.Hosting` worker-service plumbing) is either unchanged
from the previously-verified build or uses only patterns already proven
against a real build before. **Watch `dotnet build`'s output closely on
this first real build and fix anything the compiler flags in
`SupabaseWriter.cs`** - that's genuinely the one place a small mismatch
could exist, most likely in exactly how `NpgsqlParameter`/`AddWithValue`
infers an array's Postgres type from a C# array of nullable values.

### 2. Copy to the production server

Copy `WyzeSalesExtract.exe` and `appsettings.json` from `publish\` to
wherever you want it to live on the server. That's the whole deployment -
no installer, no SDK, no separate runtime.

### 3. Configure `appsettings.json`

2026-09-04: `appsettings.json` is gitignored (it ends up holding a real
Supabase connection string and WCSA DB credentials once filled in) — a fresh
clone of this repo has `appsettings.example.json` instead. Copy it to
`appsettings.json` first (`cp appsettings.example.json appsettings.json` or
just duplicate it in Explorer) - `dotnet publish` copies whichever one
actually exists next to the exe, and silently copies nothing if neither
does, so don't skip this step even though the build itself won't error on a
missing file.

Fill in, at minimum:

- `Database.Dsn` (or `Database.ConnectionString`) and `Database.BasePath` -
  unchanged from before, should already be right.
- `Supabase.ConnectionString` - the **Session mode pooler** connection
  string from Supabase's project settings (Database -> Connection string).
  Session mode, not Transaction mode - this program opens one connection
  and reuses it for a whole run, including multi-statement transactions,
  which transaction-mode pooling doesn't support well.
- `Supabase.ClientCode` - defaults to `"WCSA"`. Matches the `code` column on
  the `clients` row this data belongs to; created automatically on first
  run if it doesn't already exist.
- `Schedule.RunTimes` - the time(s) per day you want it to run, e.g.
  `["06:00", "14:00"]`.
- `Logging.LogFolder` - where run logs go.

Business-rule config that used to live here (excluded accounts, the
rep-override list, the supplier-suppression list) is now edited directly in
Supabase - see "Business rules now live in Supabase" below.

### 4. Business rules now live in Supabase

Nothing to configure in this file for these - edit the data directly in
Supabase (via the table editor or SQL) instead:

- **Excluded customer accounts**: insert a row into
  `excluded_customer_accounts` (`client_id`, `account_code`, optionally
  `reason`). Read fresh from Supabase at the start of every run.
- **Rep-override accounts** (a customer's sales count toward their assigned
  rep, not the invoice's rep): set `customers.attribute_to_assigned_rep =
  true` for that customer.
- **Suppressed supplier names**: set `items.supplier_suppressed = true` for
  items from that supplier.

This program never overwrites any of these when it refreshes reference data
- see `Data/SupabaseWriter.cs`'s class remarks for exactly which columns
each upsert touches.

### 5. Validate before trusting it

1. Run `WyzeSalesExtract.exe --selftest` - no database needed, confirms the
   date-math cleanup and the scheduler's own "next run time" logic are both
   sound on this machine.
2. Point `Supabase.ConnectionString` at a **test/staging Supabase project**
   first, not production, and run `WyzeSalesExtract.exe --run-once`. Check
   the row counts in `sales_document_facts`, `stock_movement_facts`, and
   `item_stock_snapshot` look sane, and spot-check a handful of rows in
   Supabase's table editor against what you'd expect from the source data.
3. Run it a second time back to back and confirm the row counts come out
   the same (proves the delete-and-reinsert replace logic is idempotent,
   not silently accumulating duplicates).
4. Only once satisfied, point `Supabase.ConnectionString` at the real
   project and run `WyzeSalesExtract.exe --run-once` there.

### 6. Install as a Windows Service

This is what makes it start automatically every time the server boots and
run unattended in the background from then on - no Task Scheduler involved.
From an **elevated** (Run as administrator) Command Prompt or PowerShell:

```
WyzeSalesExtract.exe install
```

This registers the service under a name derived from `Supabase.ClientCode` in
`appsettings.json` (e.g. `WyzeSalesExtractEDGE`, shown as "WyzeSales Extract
(EDGE)" in services.msc - or `WyzeSalesExtractWCSA` / "WyzeSales Extract
(WCSA)" for WCSA), configures it to auto-start at boot, sets Windows' own
crash-recovery policy (auto-restart up to 3 times if the process ever dies
unexpectedly), and starts it immediately. From this point on, it runs
continuously in the background, waking up at each time in `Schedule.RunTimes`
to do a run, with no user needing to be logged in. **`appsettings.json` must
already be filled in correctly before you run `install`** - the service name
is read from it at install time (see `ServiceInstall/ServiceInstaller.cs` if
you need the exact rule), so get step 3 (or the Edgetec equivalent) done
first.

**Before you install it, check one thing**: services registered this way run
under the *Local System* account by default, not your own Windows login. If
the ODBC DSN this client's extractor uses (WCSA's `IQNew`, or Edgetec's own
DSN) was set up as a **User DSN** rather than a **System DSN** (machine-wide),
the service won't be able to see it and every run will fail at the
"Connecting to ... database..." step. Open ODBC Data Source Administrator
(`odbcad32.exe`) and check the **System DSN** tab has that DSN listed - if
it's only under **User DSN**, either recreate it on the System DSN tab
(simplest fix), or reconfigure the service to run under a specific account
instead via `sc config <ServiceName> obj= ".\<username>" password= "..."`
after installing (see the service name shown when `install` ran, or
`services.msc`).

To manage it afterward (substitute whichever service name `install` reported
- e.g. `WyzeSalesExtractEDGE`):

- **Check status / start / stop**: open `services.msc`, find "WyzeSales
  Extract (...)", or from an elevated prompt: `net start <ServiceName>` /
  `net stop <ServiceName>`.
- **Watch what it's doing**: log files land in `Logging.LogFolder`, one per
  scheduled run, plus `WyzeSalesExtract_startup.log` next to the exe itself
  for anything that happens before a config file has loaded successfully.
- **Change the schedule**: edit `Schedule.RunTimes` in `appsettings.json` -
  picked up automatically without a restart, except a change only takes
  effect once the run currently being waited for actually fires (restart
  the service via services.msc for an immediate change).
- **Remove it**: `WyzeSalesExtract.exe uninstall` (also needs an elevated
  prompt).
- **Update the exe**: stop the service, replace `WyzeSalesExtract.exe` with
  the newly published one, start the service again.

If you'd rather test the scheduler without installing a service yet, just
run `WyzeSalesExtract.exe` (no arguments) from an ordinary console window -
it runs the exact same background loop in the foreground, so you can watch
it log "next run scheduled for..." and Ctrl+C out of it at any time.

## Command-line options

| Command / flag | Effect |
|---|---|
| *(no arguments)* | Default mode: runs the background scheduler, waiting for each time in `Schedule.RunTimes`. This is what a Windows Service launches; run it this way interactively (no service installed) to watch it work in the foreground. |
| `install` | Registers this exe as a Windows Service (auto-start at boot, auto-restart on crash) and starts it. Needs an elevated prompt. |
| `uninstall` | Stops and removes the Windows Service. Needs an elevated prompt. |
| `--run-once` | Does a single extract-and-write run immediately and exits, ignoring `Schedule.RunTimes`. Use this for manual testing/validation. |
| `--selftest` | Runs the date-math and scheduler equivalence checks and exits. No DB/config needed. |
| `--config <path>` | Use a config file other than `appsettings.json` next to the exe. Applies to `--run-once`; the service always uses the default location next to the exe. |

## Exit codes

Only meaningful for `--run-once` (the service runs indefinitely and doesn't
exit under normal operation): `0` success · `1` extract failed (see log,
and see `data_load_runs` in Supabase - the app's data-load health indicator
reads this table) · `2` config could not be loaded · `3` could not connect
to Supabase at all, so not even a `data_load_runs` failure row could be
written (see log only - added 2026-09-04 alongside real run tracking,
Wyzesales_Rebuild_Decisions.md Section 76).
