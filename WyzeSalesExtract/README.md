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
Config/AppSettings.cs         appsettings.json -> strongly-typed settings (Database, Supabase, FiscalYear, Schedule, Logging)
Data/Db.cs                    WCSA ODBC connection + query helper + the exact text-cleaning rules
Data/Lookups.cs               All ~20 raw dimension pulls (customers, reps, categories, suppliers, stock counts, lead times)
Data/Facts.cs                 The raw invoice/credit-note line facts
Data/SupabaseWriter.cs        Everything written to Supabase - upserts for reference data, full replace for raw facts
Domain/FiscalDate.cs          Date-window math + the CheckYear assumption
Domain/SelfTest.cs            Proves FiscalDate matches the original logic - run with --selftest
Domain/Keys.cs                Composite dictionary keys
Domain/RawFacts.cs            The raw row shapes this program produces (SalesDocumentFact, StockMovementFact, ItemStockSnapshotFact)
Builders/SalesDocumentFactsBuilder.cs   Invoices/credit notes/quotes/sales orders -> sales_document_facts rows
Builders/StockMovementFactsBuilder.cs   36-month item+location net movement -> stock_movement_facts rows
Builders/ItemStockSnapshotBuilder.cs    Point-in-time stock/pricing/lead-time -> item_stock_snapshot rows
Builders/ReferenceDataBuilder.cs        Assembles branches/reps/customers/categories/suppliers/items for upsert
Logging/Log.cs                Minimal file+console logger, safe with or without an attached console
Worker/ExtractRunner.cs       One full extract-and-write run - the pipeline itself
Worker/ExtractWorker.cs       The background scheduler loop - waits for Schedule.RunTimes, then calls ExtractRunner
ServiceInstall/ServiceInstaller.cs   install/uninstall - registers this exe as a Windows Service via sc.exe
Program.cs                    Dispatches to the above based on command-line args (see "Command-line options")
```

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

This registers the service (named `WyzeSalesExtractWCSA`, shown as "WyzeSales
Extract (WCSA)" in services.msc), configures it to auto-start at boot, sets
Windows' own crash-recovery policy (auto-restart up to 3 times if the
process ever dies unexpectedly), and starts it immediately. From this point
on, it runs continuously in the background, waking up at each time in
`Schedule.RunTimes` to do a run, with no user needing to be logged in.

**Before you install it, check one thing**: services registered this way run
under the *Local System* account by default, not your own Windows login. If
your `IQNew` ODBC DSN was set up as a **User DSN** rather than a **System
DSN** (machine-wide), the service won't be able to see it and every run
will fail at the "Connecting to WCSA database..." step. Open ODBC Data
Source Administrator (`odbcad32.exe`) and check the **System DSN** tab has
`IQNew` listed - if it's only under **User DSN**, either recreate it on the
System DSN tab (simplest fix), or reconfigure the service to run under a
specific account instead via `sc config WyzeSalesExtractWCSA obj=
".\<username>" password= "..."` after installing.

To manage it afterward:

- **Check status / start / stop**: open `services.msc`, find "WyzeSales
  Extract (WCSA)", or from an elevated prompt: `net start
  WyzeSalesExtractWCSA` / `net stop WyzeSalesExtractWCSA`.
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
