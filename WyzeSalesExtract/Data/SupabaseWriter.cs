using Npgsql;
using WyzeSalesExtract.Builders;
using WyzeSalesExtract.Domain;

namespace WyzeSalesExtract.Data;

/// <summary>
/// Everything this program writes to Supabase Postgres. Every bulk insert uses the standard
/// Postgres "unnest several equal-length arrays in one SELECT" idiom - one round trip per
/// table instead of one per row, which matters once sales_document_facts is tens of thousands
/// of rows for a multi-fiscal-year window (3 or 5 years, per LoadDataHistoryYearsAsync below).
///
/// Reference-table upserts are written to touch ONLY the columns this program actually knows
/// (name, department, price, etc.) - never a column WCSA staff own directly in Supabase
/// (customers.attribute_to_assigned_rep, items.supplier_suppressed, branches.display_code/
/// name, excluded_customer_accounts). That's what lets those be edited in Supabase without
/// this program silently clobbering the edit on the next run.
///
/// The three raw-fact tables (sales_document_facts, stock_movement_facts, item_stock_snapshot)
/// are fully derived and safe to wipe and reload every run - see each method's remarks for the
/// exact scope of what gets deleted first.
/// </summary>
public sealed class SupabaseWriter : IDisposable
{
    private readonly NpgsqlConnection _conn;

    public SupabaseWriter(string connectionString)
    {
        _conn = new NpgsqlConnection(connectionString);
        _conn.Open();
    }

    /// <summary>Looks up clients.id by code, creating the row (name = code) if this is the
    /// first time this program has ever run against this Supabase project. Client rows beyond
    /// that first bootstrap are expected to be managed in Supabase directly, not by this
    /// program - it never updates an existing client's name.</summary>
    public async Task<Guid> ResolveOrCreateClientIdAsync(string code)
    {
        await using (var cmd = new NpgsqlCommand("select id from clients where code = @code", _conn))
        {
            cmd.Parameters.AddWithValue("code", code);
            var result = await cmd.ExecuteScalarAsync();
            if (result is Guid id) return id;
        }

        await using (var cmd = new NpgsqlCommand(
            "insert into clients (code, name) values (@code, @code) returning id", _conn))
        {
            cmd.Parameters.AddWithValue("code", code);
            return (Guid)(await cmd.ExecuteScalarAsync())!;
        }
    }

    public async Task<HashSet<string>> LoadExcludedAccountsAsync(Guid clientId)
    {
        var result = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        await using var cmd = new NpgsqlCommand(
            "select account_code from excluded_customer_accounts where client_id = @client_id", _conn);
        cmd.Parameters.AddWithValue("client_id", clientId);
        await using var reader = await cmd.ExecuteReaderAsync();
        while (await reader.ReadAsync())
            result.Add(reader.GetString(0));
        return result;
    }

    /// <summary>Reads this client's fiscal_year_settings.history_years - the same column
    /// the Flutter app's Settings &gt; Company screen reads/writes as its "Data history
    /// window" (3 or 5 years; schema/019 + schema/020). Fetched live rather than duplicated
    /// into appsettings.json (same reasoning as LoadExcludedAccountsAsync above) so this
    /// program and the app can never drift apart on how much history to keep. Falls back to
    /// 3 - the original hardcoded default - if the client has no fiscal_year_settings row
    /// yet (a brand-new client, or one that hasn't opened Settings > Company).</summary>
    public async Task<int> LoadDataHistoryYearsAsync(Guid clientId)
    {
        await using var cmd = new NpgsqlCommand(
            "select history_years from fiscal_year_settings where client_id = @client_id", _conn);
        cmd.Parameters.AddWithValue("client_id", clientId);
        var result = await cmd.ExecuteScalarAsync();
        return result is int historyYears ? historyYears : 3;
    }

    // ------------------------------------------------------------------
    // Reference / dimension tables
    // ------------------------------------------------------------------

    public async Task UpsertBranchesAsync(Guid clientId, List<string> codes)
    {
        if (codes.Count == 0) return;
        const string sql = """
            insert into branches (client_id, code)
            select @client_id, unnest(@code::text[])
            on conflict (client_id, code) do nothing
            """;
        await using var cmd = new NpgsqlCommand(sql, _conn);
        cmd.Parameters.AddWithValue("client_id", clientId);
        cmd.Parameters.AddWithValue("code", codes.ToArray());
        await cmd.ExecuteNonQueryAsync();
    }

    public async Task UpsertSalesRepsAsync(Guid clientId, List<(string RepCode, string Name)> reps)
    {
        if (reps.Count == 0) return;
        const string sql = """
            insert into sales_reps (client_id, rep_code, name)
            select @client_id, unnest(@rep_code::text[]), unnest(@name::text[])
            on conflict (client_id, rep_code) do update set name = excluded.name
            """;
        await using var cmd = new NpgsqlCommand(sql, _conn);
        cmd.Parameters.AddWithValue("client_id", clientId);
        cmd.Parameters.AddWithValue("rep_code", reps.Select(r => r.RepCode).ToArray());
        cmd.Parameters.AddWithValue("name", reps.Select(r => r.Name).ToArray());
        await cmd.ExecuteNonQueryAsync();
    }

    /// <summary>Updates name and assigned_rep_code only - never attribute_to_assigned_rep,
    /// which is a flag WCSA staff set directly in Supabase (see class remarks).</summary>
    public async Task UpsertCustomersAsync(Guid clientId, List<(string Code, string Name, string? AssignedRepCode)> customers)
    {
        if (customers.Count == 0) return;
        const string sql = """
            insert into customers (client_id, code, name, assigned_rep_code)
            select @client_id, unnest(@code::text[]), unnest(@name::text[]), unnest(@assigned_rep_code::text[])
            on conflict (client_id, code) do update
              set name = excluded.name, assigned_rep_code = excluded.assigned_rep_code
            """;
        await using var cmd = new NpgsqlCommand(sql, _conn);
        cmd.Parameters.AddWithValue("client_id", clientId);
        cmd.Parameters.AddWithValue("code", customers.Select(c => c.Code).ToArray());
        cmd.Parameters.AddWithValue("name", customers.Select(c => c.Name).ToArray());
        cmd.Parameters.AddWithValue("assigned_rep_code", customers.Select(c => c.AssignedRepCode).ToArray());
        await cmd.ExecuteNonQueryAsync();
    }

    public async Task UpsertCategoriesAsync(Guid clientId, List<(string DepartmentCode, string Name)> categories)
    {
        if (categories.Count == 0) return;
        const string sql = """
            insert into categories (client_id, department_code, name)
            select @client_id, unnest(@department_code::text[]), unnest(@name::text[])
            on conflict (client_id, department_code) do update set name = excluded.name
            """;
        await using var cmd = new NpgsqlCommand(sql, _conn);
        cmd.Parameters.AddWithValue("client_id", clientId);
        cmd.Parameters.AddWithValue("department_code", categories.Select(c => c.DepartmentCode).ToArray());
        cmd.Parameters.AddWithValue("name", categories.Select(c => c.Name).ToArray());
        await cmd.ExecuteNonQueryAsync();
    }

    public async Task UpsertSuppliersAsync(Guid clientId, List<(string AccountCode, string Name)> suppliers)
    {
        if (suppliers.Count == 0) return;
        const string sql = """
            insert into suppliers (client_id, account_code, name)
            select @client_id, unnest(@account_code::text[]), unnest(@name::text[])
            on conflict (client_id, account_code) do update set name = excluded.name
            """;
        await using var cmd = new NpgsqlCommand(sql, _conn);
        cmd.Parameters.AddWithValue("client_id", clientId);
        cmd.Parameters.AddWithValue("account_code", suppliers.Select(s => s.AccountCode).ToArray());
        cmd.Parameters.AddWithValue("name", suppliers.Select(s => s.Name).ToArray());
        await cmd.ExecuteNonQueryAsync();
    }

    /// <summary>Never touches supplier_suppressed - see class remarks. department_code /
    /// supplier_account_code are inserted as-is; a code that doesn't (yet) exist in categories/
    /// suppliers is fine, since sales_document_facts and items carry no FK on those columns
    /// (matching the original script's loose, per-row Mapping-table behaviour).</summary>
    public async Task UpsertItemsAsync(Guid clientId,
        List<(string Code, string Name, string? DepartmentCode, string? SupplierAccountCode, decimal? DefaultCost, decimal? DefaultSellPrice)> items)
    {
        if (items.Count == 0) return;
        const string sql = """
            insert into items (client_id, code, name, department_code, supplier_account_code, default_cost, default_sell_price)
            select @client_id, unnest(@code::text[]), unnest(@name::text[]), unnest(@department_code::text[]),
                   unnest(@supplier_account_code::text[]), unnest(@default_cost::numeric[]), unnest(@default_sell_price::numeric[])
            on conflict (client_id, code) do update
              set name = excluded.name, department_code = excluded.department_code,
                  supplier_account_code = excluded.supplier_account_code,
                  default_cost = excluded.default_cost, default_sell_price = excluded.default_sell_price
            """;
        await using var cmd = new NpgsqlCommand(sql, _conn);
        cmd.Parameters.AddWithValue("client_id", clientId);
        cmd.Parameters.AddWithValue("code", items.Select(i => i.Code).ToArray());
        cmd.Parameters.AddWithValue("name", items.Select(i => i.Name).ToArray());
        cmd.Parameters.AddWithValue("department_code", items.Select(i => i.DepartmentCode).ToArray());
        cmd.Parameters.AddWithValue("supplier_account_code", items.Select(i => i.SupplierAccountCode).ToArray());
        cmd.Parameters.AddWithValue("default_cost", items.Select(i => i.DefaultCost).ToArray());
        cmd.Parameters.AddWithValue("default_sell_price", items.Select(i => i.DefaultSellPrice).ToArray());
        await cmd.ExecuteNonQueryAsync();
    }

    // ------------------------------------------------------------------
    // Run tracking (data_load_runs, schema/033) - 2026-09-04
    // ------------------------------------------------------------------

    /// <summary>Inserts the 'running' row for this attempt and returns its id. Called from
    /// ExtractRunner as early as possible - right after the Supabase connection and client_id
    /// are resolved, BEFORE the WCSA connection is even attempted - so a WCSA failure (the most
    /// common real-world failure mode) always has a row to be reported against. A row left on
    /// 'running' (this call succeeded but CompleteLoadRunAsync below never got called - a crash,
    /// a kill, a power loss) is itself a meaningful signal to the app, not an error state to
    /// avoid; see schema/033's header.</summary>
    public async Task<Guid> StartLoadRunAsync(Guid clientId)
    {
        const string sql = "insert into data_load_runs (client_id, status) values (@client_id, 'running') returning id";
        await using var cmd = new NpgsqlCommand(sql, _conn);
        cmd.Parameters.AddWithValue("client_id", clientId);
        return (Guid)(await cmd.ExecuteScalarAsync())!;
    }

    /// <summary>Updates the run row StartLoadRunAsync created to its final outcome. Row-count
    /// parameters are only meaningful (and only passed) on a successful run - a failed run may
    /// not have gotten far enough to know any of them, so they're left null rather than
    /// misleadingly reported as zero.</summary>
    public async Task CompleteLoadRunAsync(
        Guid runId,
        bool success,
        string? errorMessage,
        double durationSeconds,
        int? salesDocumentFactsRows = null,
        int? stockMovementFactsRows = null,
        int? itemStockSnapshotRows = null)
    {
        const string sql = """
            update data_load_runs
            set status = @status, finished_at = now(), error_message = @error_message,
                duration_seconds = @duration_seconds,
                sales_document_facts_rows = @sales_document_facts_rows,
                stock_movement_facts_rows = @stock_movement_facts_rows,
                item_stock_snapshot_rows = @item_stock_snapshot_rows
            where id = @id
            """;
        await using var cmd = new NpgsqlCommand(sql, _conn);
        cmd.Parameters.AddWithValue("id", runId);
        cmd.Parameters.AddWithValue("status", success ? "success" : "failure");
        cmd.Parameters.AddWithValue("error_message", (object?)errorMessage ?? DBNull.Value);
        cmd.Parameters.AddWithValue("duration_seconds", durationSeconds);
        cmd.Parameters.AddWithValue("sales_document_facts_rows", (object?)salesDocumentFactsRows ?? DBNull.Value);
        cmd.Parameters.AddWithValue("stock_movement_facts_rows", (object?)stockMovementFactsRows ?? DBNull.Value);
        cmd.Parameters.AddWithValue("item_stock_snapshot_rows", (object?)itemStockSnapshotRows ?? DBNull.Value);
        await cmd.ExecuteNonQueryAsync();
    }

    // ------------------------------------------------------------------
    // Raw fact tables - fully derived, wiped and reloaded every run
    // ------------------------------------------------------------------

    /// <summary>Deletes every existing sales_document_facts row for this client, then inserts
    /// the freshly pulled fiscal-year window (3 or 5 years, per LoadDataHistoryYearsAsync). A
    /// full per-client wipe (not just "delete rows
    /// in today's window") because the window itself shifts by a day on every run - the
    /// simplest way to guarantee a row that's aged out is actually gone. Runs inside a
    /// transaction so a failure partway through never leaves the table half-empty.</summary>
    public async Task ReplaceSalesDocumentFactsAsync(Guid clientId, List<SalesDocumentFact> facts)
    {
        await using var tx = await _conn.BeginTransactionAsync();

        await using (var del = new NpgsqlCommand("delete from sales_document_facts where client_id = @client_id", _conn, tx))
        {
            del.Parameters.AddWithValue("client_id", clientId);
            await del.ExecuteNonQueryAsync();
        }

        if (facts.Count > 0)
        {
            const string sql = """
                insert into sales_document_facts
                  (client_id, document_kind, document, account_code, doc_date, invoice_rep_code,
                   item_code, warehouse_code, quantity, value, cost, discount_amount)
                select @client_id,
                       unnest(@document_kind::text[])::document_kind,
                       unnest(@document::text[]), unnest(@account_code::text[]), unnest(@doc_date::date[]),
                       unnest(@invoice_rep_code::text[]), unnest(@item_code::text[]), unnest(@warehouse_code::text[]),
                       unnest(@quantity::numeric[]), unnest(@value::numeric[]), unnest(@cost::numeric[]),
                       unnest(@discount_amount::numeric[])
                """;
            await using var cmd = new NpgsqlCommand(sql, _conn, tx) { CommandTimeout = 600 };
            cmd.Parameters.AddWithValue("client_id", clientId);
            cmd.Parameters.AddWithValue("document_kind", facts.Select(f => f.DocumentKind).ToArray());
            cmd.Parameters.AddWithValue("document", facts.Select(f => f.Document).ToArray());
            cmd.Parameters.AddWithValue("account_code", facts.Select(f => f.AccountCode).ToArray());
            cmd.Parameters.AddWithValue("doc_date", facts.Select(f => DateOnly.FromDateTime(f.DocDate)).ToArray());
            cmd.Parameters.AddWithValue("invoice_rep_code", facts.Select(f => f.InvoiceRepCode).ToArray());
            cmd.Parameters.AddWithValue("item_code", facts.Select(f => f.ItemCode).ToArray());
            cmd.Parameters.AddWithValue("warehouse_code", facts.Select(f => f.WarehouseCode).ToArray());
            cmd.Parameters.AddWithValue("quantity", facts.Select(f => f.Quantity).ToArray());
            cmd.Parameters.AddWithValue("value", facts.Select(f => f.Value).ToArray());
            cmd.Parameters.AddWithValue("cost", facts.Select(f => f.Cost).ToArray());
            cmd.Parameters.AddWithValue("discount_amount", facts.Select(f => f.DiscountAmount).ToArray());
            await cmd.ExecuteNonQueryAsync();
        }

        await tx.CommitAsync();
    }

    /// <summary>Same full-per-client-wipe reasoning as sales_document_facts - the trailing
    /// N-month window (36 or 60, matching the same 3/5-year history setting) also shifts by
    /// a day on every run.</summary>
    public async Task ReplaceStockMovementFactsAsync(Guid clientId, List<StockMovementFact> facts)
    {
        await using var tx = await _conn.BeginTransactionAsync();

        await using (var del = new NpgsqlCommand("delete from stock_movement_facts where client_id = @client_id", _conn, tx))
        {
            del.Parameters.AddWithValue("client_id", clientId);
            await del.ExecuteNonQueryAsync();
        }

        if (facts.Count > 0)
        {
            const string sql = """
                insert into stock_movement_facts (client_id, item_code, location_code, month, quantity, sales_amount, sales_profit)
                select @client_id, unnest(@item_code::text[]), unnest(@location_code::text[]), unnest(@month::date[]),
                       unnest(@quantity::numeric[]), unnest(@sales_amount::numeric[]), unnest(@sales_profit::numeric[])
                """;
            await using var cmd = new NpgsqlCommand(sql, _conn, tx) { CommandTimeout = 600 };
            cmd.Parameters.AddWithValue("client_id", clientId);
            cmd.Parameters.AddWithValue("item_code", facts.Select(f => f.ItemCode).ToArray());
            cmd.Parameters.AddWithValue("location_code", facts.Select(f => f.LocationCode).ToArray());
            cmd.Parameters.AddWithValue("month", facts.Select(f => DateOnly.FromDateTime(f.Month)).ToArray());
            cmd.Parameters.AddWithValue("quantity", facts.Select(f => f.Quantity).ToArray());
            cmd.Parameters.AddWithValue("sales_amount", facts.Select(f => f.SalesAmount).ToArray());
            cmd.Parameters.AddWithValue("sales_profit", facts.Select(f => f.SalesProfit).ToArray());
            await cmd.ExecuteNonQueryAsync();
        }

        await tx.CommitAsync();
    }

    /// <summary>Only deletes THIS run's own snapshot_date first (not the whole table) - unlike
    /// the other two fact tables, item_stock_snapshot is meant to accumulate one dated snapshot
    /// per day it's ever run, so yesterday's (and older) snapshots are left alone. Running
    /// twice in one day (see Schedule.RunTimes) safely replaces just that day's snapshot rather
    /// than duplicating or erroring on the primary key.</summary>
    public async Task ReplaceTodaysItemStockSnapshotAsync(Guid clientId, List<ItemStockSnapshotFact> facts, DateTime snapshotDate)
    {
        var date = DateOnly.FromDateTime(snapshotDate);
        await using var tx = await _conn.BeginTransactionAsync();

        await using (var del = new NpgsqlCommand(
            "delete from item_stock_snapshot where client_id = @client_id and snapshot_date = @snapshot_date", _conn, tx))
        {
            del.Parameters.AddWithValue("client_id", clientId);
            del.Parameters.AddWithValue("snapshot_date", date);
            await del.ExecuteNonQueryAsync();
        }

        if (facts.Count > 0)
        {
            const string sql = """
                insert into item_stock_snapshot
                  (client_id, item_code, location_code, qty_on_hand, on_purchase_order_qty, on_sales_order_qty,
                   calculated_cost, selling_price, avg_supplier_lead_time_days, first_sale_date, last_sale_date,
                   active_months, snapshot_date)
                select @client_id, unnest(@item_code::text[]), unnest(@location_code::text[]),
                       unnest(@qty_on_hand::numeric[]), unnest(@on_purchase_order_qty::numeric[]), unnest(@on_sales_order_qty::numeric[]),
                       unnest(@calculated_cost::numeric[]), unnest(@selling_price::numeric[]), unnest(@avg_supplier_lead_time_days::int[]),
                       unnest(@first_sale_date::date[]), unnest(@last_sale_date::date[]), unnest(@active_months::int[]),
                       @snapshot_date
                """;
            await using var cmd = new NpgsqlCommand(sql, _conn, tx) { CommandTimeout = 600 };
            cmd.Parameters.AddWithValue("client_id", clientId);
            cmd.Parameters.AddWithValue("snapshot_date", date);
            cmd.Parameters.AddWithValue("item_code", facts.Select(f => f.ItemCode).ToArray());
            cmd.Parameters.AddWithValue("location_code", facts.Select(f => f.LocationCode).ToArray());
            cmd.Parameters.AddWithValue("qty_on_hand", facts.Select(f => f.QtyOnHand).ToArray());
            cmd.Parameters.AddWithValue("on_purchase_order_qty", facts.Select(f => f.OnPurchaseOrderQty).ToArray());
            cmd.Parameters.AddWithValue("on_sales_order_qty", facts.Select(f => f.OnSalesOrderQty).ToArray());
            cmd.Parameters.AddWithValue("calculated_cost", facts.Select(f => f.CalculatedCost).ToArray());
            cmd.Parameters.AddWithValue("selling_price", facts.Select(f => f.SellingPrice).ToArray());
            cmd.Parameters.AddWithValue("avg_supplier_lead_time_days", facts.Select(f => f.AvgSupplierLeadTimeDays).ToArray());
            cmd.Parameters.AddWithValue("first_sale_date", facts.Select(f => f.FirstSaleDate.HasValue ? DateOnly.FromDateTime(f.FirstSaleDate.Value) : (DateOnly?)null).ToArray());
            cmd.Parameters.AddWithValue("last_sale_date", facts.Select(f => f.LastSaleDate.HasValue ? DateOnly.FromDateTime(f.LastSaleDate.Value) : (DateOnly?)null).ToArray());
            cmd.Parameters.AddWithValue("active_months", facts.Select(f => f.ActiveMonths).ToArray());
            await cmd.ExecuteNonQueryAsync();
        }

        await tx.CommitAsync();
    }

    public void Dispose() => _conn.Dispose();
}
