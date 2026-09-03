-- ============================================================================
-- WyzeSales — a User's own transactions means invoice_rep_code, not "any rep
-- who ever sold into a customer assigned to them"
-- ============================================================================
-- Twenty-ninth migration. Craig, 2026-09-03, after testing as Johan (rep
-- R01) on Sales Analysis' Table tab and Sales By > Sales Person: "A user
-- must only see their transactions. In the case where another user sold
-- into the users account they must still only see theirs... Johan's actual
-- revenue for Sep 2027 is only 7,954.67 and not 8,780.46." Screenshots
-- showed Johan's own login could see a September invoice with Sales Person
-- "R04" on it in the Table tab, and a "Sales By Sales Person" breakdown
-- listing FOUR other reps (R04, 44, R02, R03) as separate rows under his
-- own login, spanning multiple fiscal years.
--
-- ROOT CAUSE: sales_document_facts_select's 'user' branch (schema/001
-- Section 10) has allowed EITHER of two conditions since the very first
-- migration: `p.rep_code = invoice_rep_code` (the rep who actually sold it)
-- OR `p.rep_code = <that row's customer's raw assigned_rep_code>` (the
-- customer happens to be "assigned" to this rep, regardless of who actually
-- processed the sale). The second condition was written to solve a
-- different, real problem (Decisions doc Section 3: a rep's own genuine
-- sale should never be hidden just because the customer is assigned to
-- someone else) — but as written, it ALSO grants visibility the other way
-- round: ANY other rep's invoice into a customer assigned to you becomes
-- visible to you too, with no distinction from your own work. The test seed
-- script (schema/010) makes this obvious on inspection: for any customer
-- with attribute_to_assigned_rep = false (the normal case — Craig: "95% of
-- the time transactions will always be to a rep's allocated customer" is an
-- expectation of how the real business works, not something the RLS rule
-- was actually enforcing), invoice_rep_code is picked at random from every
-- rep on file (schema/010's v_rep selection), completely independent of the
-- customer's own assigned_rep_code — so a customer assigned to Johan
-- naturally accumulates invoices from several different reps over time, and
-- the old policy handed every single one of them to Johan.
--
-- THE FIX: use the schema's own existing single source of truth for "who
-- does this sale count toward" — resolved_rep_code() (schema/001 Section
-- 8), already used by v_sales_documents' own resolved_rep_code column and
-- by every rollup that reports "by rep." resolved_rep_code() returns the
-- customer's assigned_rep_code ONLY when that customer's
-- attribute_to_assigned_rep flag is explicitly true (a genuine
-- house-account policy: this customer's revenue always counts toward its
-- assigned rep, whoever actually keyed the invoice) — otherwise it falls
-- straight back to invoice_rep_code. Replacing the raw, flag-blind "customer
-- assigned_rep_code" check with resolved_rep_code() means:
--   - A User still always sees their own invoice_rep_code rows, regardless
--     of whose customer it was sold into (Section 3's original concern,
--     unchanged and still honoured — nobody's own legitimate work is hidden
--     just because it touched a customer assigned to someone else).
--   - A User additionally sees a row attributed to them via a genuine
--     house-account flag (attribute_to_assigned_rep = true) — the one
--     legitimate case where "the customer is assigned to me" should still
--     grant visibility into someone else's invoice, because the schema's
--     own attribution rule says the revenue is officially theirs.
--   - A User no longer sees another rep's invoice into a customer merely
--     "assigned" to them without that flag — exactly Craig's reported gap.
-- This also keeps a rep's own RLS-visible revenue always exactly equal to
-- what resolved_rep_code-based reporting elsewhere in the app already
-- counts as theirs, rather than the two silently disagreeing (an admin's
-- "by rep" report and the rep's own login would otherwise be able to show
-- two different totals for the same person).
--
-- reguser is UNCHANGED and was never affected by this bug — its branch
-- scoping already keys off warehouse_code directly on the transaction
-- itself (schema/001's own comment: branch resolution has no
-- assignment-based indirection the way rep does, since REPS has no branch
-- column at all), so "their Regional transactions" was already exactly
-- that — confirmed by re-reading the policy below, unchanged from
-- schema/001/018.
--
-- Deliberately NOT touched here: budget_figures_select/sales_forecast_select
-- and customers_select's own use of fn_customer_visible_to_rep (schema/018)
-- — those answer "can this rep see a target for this customer" / "can this
-- rep browse this customer record," different questions from "does this
-- specific transaction's revenue count as theirs," which is what Craig
-- reported. Narrowing those too, if ever wanted, is a separate decision.
--
-- Same drop-and-recreate approach as every prior policy change here
-- (Postgres has no ALTER POLICY ... ADD CONDITION), safe to run regardless
-- of what currently exists.
-- ============================================================================

drop policy if exists sales_document_facts_select on sales_document_facts;

create policy sales_document_facts_select on sales_document_facts
for select using (
  exists (
    select 1 from profiles p
    where p.id = auth.uid()
      and p.client_id = sales_document_facts.client_id
      and (
        p.level in ('adminuser', 'superuser')
        or (
          p.level = 'reguser'
          and p.branch_code = sales_document_facts.warehouse_code
        )
        or (
          p.level = 'user'
          and p.rep_code in (
                sales_document_facts.invoice_rep_code,
                resolved_rep_code(sales_document_facts.client_id, sales_document_facts.account_code, sales_document_facts.invoice_rep_code)
              )
        )
      )
  )
);
