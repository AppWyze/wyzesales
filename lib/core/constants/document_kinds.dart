/// Single source of truth for "which document kinds count as revenue" on
/// the Dart side — mirrors `fn_revenue_document_kinds()` (docs/schema/
/// wyzesales_fn_revenue_document_kinds.sql) on both Supabase projects.
///
/// 2026-09-29, Craig, after Sales Analysis' Table and Chart tabs drifted
/// out of agreement because this exact list was independently retyped in
/// two places in sales_analysis_screen.dart (one gained 'journal'/
/// 'adjustment' on 2026-09-22, the other didn't get updated to match until
/// this fix): "nothing can ever be hard coded anywhere." Every screen that
/// needs "every document kind that counts as revenue" imports this
/// constant instead of typing its own list.
///
/// Craig, same day, on the document_kind vocabulary itself: "Wyzesales now
/// needs to cater for Invoice, Credit and Adjustment. That's it... Journals
/// etc. are all just adjustments." 'journal' stays in this list for now,
/// alongside 'adjustment', ONLY until Craig finishes relabelling every
/// existing 'journal' row to 'adjustment' client by client (his own SQL
/// script, run at his own pace, deliberately not applied automatically here
/// — see that script's own header comment) — dropping it before then would
/// under-count revenue for any client with real, not-yet-relabelled journal
/// entries. Once that relabel is confirmed complete (zero rows with
/// document_kind = 'journal' anywhere), remove 'journal' from this list AND
/// update `fn_revenue_document_kinds()` to match in the same change — never
/// one without the other, or Table/Chart/Dashboard drift apart again
/// exactly the way they did today.
///
/// 'quote' and 'sales_order' are deliberately absent — Quote Analysis and
/// Sales Order Analysis were removed from the app on 2026-09-02 (task #93,
/// Wyzesales_Rebuild_Decisions.md Section 55) and are not part of "revenue"
/// under any definition.
const kRevenueDocumentKinds = <String>['invoice', 'credit_note', 'adjustment', 'journal'];
