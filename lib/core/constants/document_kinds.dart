/// Single source of truth for "which document kinds count as revenue" on
/// the Dart side — mirrors `fn_revenue_document_kinds()` (docs/schema/
/// wyzesales_fn_revenue_document_kinds.sql) on both Supabase projects.
/// Every screen that needs "every document kind that counts as revenue"
/// imports this constant instead of typing its own list — see that SQL
/// file's header for the full history of why this exists (2026-09-29,
/// Craig: "nothing can ever be hard coded anywhere").
///
/// Exactly three kinds, per Craig, 2026-09-29: "Wyzesales now needs to
/// cater for Invoice, Credit and Adjustment. That's it." 'journal' was
/// retired the same day — every existing 'journal' row was relabelled to
/// 'adjustment' (Craig's own script, docs/schema/wyzesales_relabel_
/// journal_to_adjustment.sql, confirmed zero rows left on both production
/// and staging) and 'journal' was dropped from this list and from
/// `fn_revenue_document_kinds()` together, same commit.
///
/// 'quote' and 'sales_order' are deliberately absent too — Quote Analysis
/// and Sales Order Analysis were removed from the app on 2026-09-02 (task
/// #93, Wyzesales_Rebuild_Decisions.md Section 55) and are not part of
/// "revenue" under any definition.
///
/// If this ever needs to change again: update this constant AND
/// `fn_revenue_document_kinds()` in the same change, never one without the
/// other — that's what caused the whole Table/Chart/Dashboard mismatch
/// this constant exists to prevent from happening again.
const kRevenueDocumentKinds = <String>['invoice', 'credit_note', 'adjustment'];
