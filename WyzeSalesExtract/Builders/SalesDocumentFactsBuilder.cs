using WyzeSalesExtract.Data;
using WyzeSalesExtract.Domain;

namespace WyzeSalesExtract.Builders;

/// <summary>
/// Builds the raw sales_document_facts rows for all four document kinds - invoices, credit
/// notes, quotes, and sales orders - with no business-rule resolution applied beyond what's
/// needed to identify the row (document type, the qty/value/cost sign a credit note implies).
/// No rep-override list, no category/name lookups: all of that now lives in Supabase views
/// (resolved_rep_code(), v_sales_documents) so it can be seen and changed without a redeploy.
/// One deliberate exception - see BuildQuotesOrOrders' remarks.
/// </summary>
public static class SalesDocumentFactsBuilder
{
    public static List<SalesDocumentFact> BuildInvoicesAndCreditNotes(
        List<InvoiceItemFact> facts, Lookups lk, DateTime windowStart)
    {
        var results = new List<SalesDocumentFact>();

        foreach (var f in facts)
        {
            if (!lk.DocType.TryGetValue(f.Document, out var docType)) continue; // unmapped doc type -> excluded
            if (docType != "SA" && docType != "CR") continue;
            if (!lk.DocDate.TryGetValue(f.Document, out var docDate)) continue;
            if (docDate < windowStart) continue;

            bool isCreditNote = docType == "CR";
            int sign = isCreditNote ? -1 : 1;

            results.Add(new SalesDocumentFact(
                DocumentKind: isCreditNote ? "credit_note" : "invoice",
                Document: f.Document,
                AccountCode: f.AccNum,
                DocDate: docDate,
                InvoiceRepCode: lk.SalesPersonCodeInv.GetValueOrDefault(f.Document),
                ItemCode: f.PartNo,
                WarehouseCode: f.Warehouse,
                Quantity: f.Qty * sign,
                Value: f.Value * sign,
                Cost: f.Cost * sign,
                DiscountAmount: f.LDiscAm * sign));
        }

        return results;
    }

    /// <summary>
    /// REP ATTRIBUTION - a deliberate faithful-port decision, flagged rather than silently
    /// picked: the original script never used the rep recorded on a quote/sales-order header
    /// at all (QUOTES.REP / SOrders.REP is selected but ignored) - every quote and sales order
    /// was always attributed to the customer's assigned rep (DEBTORS.NORMALREP), for every
    /// account, not just the 11 override accounts that rule applies to on invoices.
    ///
    /// Reproduced exactly here by writing the customer's assigned rep straight into
    /// invoice_rep_code for these two document kinds - which makes Supabase's
    /// resolved_rep_code() override check a no-op for quotes/orders (both sides of that check
    /// end up equal) without needing a document-kind branch in the SQL function itself. If
    /// WCSA would rather quotes/orders used the header's own rep field the same way invoices
    /// do, this is the one place to change - worth confirming, since it affects who a quote
    /// or order counts toward on the Quote/Sales Order Analysis screens.
    ///
    /// Also note: a header with no matching line rows (a quote/order that exists but was never
    /// given any line items) is skipped entirely here. The old QVS kept a single blank-line
    /// placeholder row for these (a LEFT JOIN artifact); the new schema's item_code is NOT
    /// NULL, so there's no meaningful row to write for a header with zero lines. Low-impact -
    /// worth knowing about if a quote count ever looks one or two short of the old app's.
    /// </summary>
    public static List<SalesDocumentFact> BuildQuotesOrOrders(
        Db db, Lookups lk, DateTime windowStart, string headerTable, string lineTable, string documentKind)
    {
        var headers = db.Query(
            $"SELECT ACCNUM, Created, DOCUMENT {db.From(headerTable)}",
            r => (AccNum: r.GetString("ACCNUM"), Document: r.GetString("DOCUMENT"), DocDate: r.GetDate("Created")));

        var lines = db.Query(
            $"""
            SELECT DOCUMENT, PARTNO, LINETOTALEXCL as VALUE, LINECOST * QTY as COST, QTY, Warehouse
            {db.From(lineTable)}
            """,
            r => (
                Document: r.GetString("DOCUMENT"),
                PartNo: Row.ReplaceQuoteWithIn(r.GetString("PARTNO")),
                Value: r.GetDecimal("VALUE"),
                Cost: r.GetDecimal("COST"),
                Qty: r.GetDecimal("QTY"),
                Warehouse: r.GetString("Warehouse")));

        var linesByDoc = lines.ToLookup(l => l.Document);
        var results = new List<SalesDocumentFact>();

        foreach (var h in headers)
        {
            if (h.DocDate < windowStart) continue;

            string assignedRep = lk.SalesPersonCode.GetValueOrDefault(h.AccNum, "");

            foreach (var l in linesByDoc[h.Document])
            {
                results.Add(new SalesDocumentFact(
                    DocumentKind: documentKind,
                    Document: h.Document,
                    AccountCode: h.AccNum,
                    DocDate: h.DocDate,
                    InvoiceRepCode: assignedRep,
                    ItemCode: l.PartNo,
                    WarehouseCode: l.Warehouse,
                    Quantity: l.Qty,
                    Value: l.Value,
                    Cost: l.Cost,
                    DiscountAmount: 0m));
            }
        }

        return results;
    }
}
