-- ============================================================================
-- WyzeSales — dimension draft/live flag + real-data check
-- ============================================================================
-- Forty-third migration. Craig, checking the new Platform Admin Dimensions
-- tab (schema/038, wired up by the app in this same wave): "How do we make
-- sure that the Client Dimensions and Client WyzeSalesExtract are aligned?
-- e.g. If I added a new Dimension to WCSA now, the WyzeSalesExtract would
-- not know about it??" — confirmed correct: WCSA's WyzeSalesExtract program
-- writes a fixed, hardcoded set of columns (Domain/RawFacts.cs's
-- SalesDocumentFact record) with no awareness at all of client_dimensions/
-- dim_N_code/attr_N_code. A brand-new dimension added in Platform Admin
-- would show up in the app immediately (filter bar, Sales By, Performance,
-- Budgets) while its backing column sits permanently null until that
-- client's extractor is separately rewritten and redeployed to populate it.
--
-- Two independent safeguards against that gap, both requested:
--
-- 1. is_live — a dimension can be entered ahead of time (so the config work
--    doesn't have to be rushed the moment an extractor rewrite lands) but
--    stays completely hidden from every filter/screen until a platform
--    admin confirms real data is flowing and flips it on. Existing rows
--    (WCSA's own six, seeded by migration 038) all default to true — they
--    already work today, so nothing about them should change behaviour.
--    Only NEW rows created going forward through the Dimensions tab start
--    as drafts (the app sends `is_live: false` explicitly on create; the
--    column's own default of `true` is what makes the existing-row backfill
--    safe, not what governs new rows).
--
-- 2. fn_dimension_data_check — lets the Dimensions tab show, per
--    fact_column/customer_attribute dimension, whether its backing column
--    (dim_N_code on sales_document_facts, or attr_N_code on customers) has
--    ANY non-null value yet for that client — a plain, honest "12,403 rows"
--    vs "No data received yet" signal, so drift between config and
--    extractor is visible at a glance rather than assumed. Not offered for
--    `resolution_kind = 'existing'` dimensions — those are backed by
--    sales_reps/customers/items/categories/branches directly, which have no
--    single generic "is this populated" column to check the same way.
--
-- fn_dimension_data_check is SECURITY DEFINER specifically so it CAN read
-- across every client's sales_document_facts/customers rows (needed since a
-- platform admin manages clients other than their own) — gated by an
-- explicit is_platform_admin() check inside the function body, the same
-- "helper bypasses RLS on purpose, but only for who it's meant for" pattern
-- schema/018's own helpers already established. The dynamic column name is
-- built with `format('%I', ...)`, which safely quotes it as an identifier
-- regardless of what string is passed in — an unrecognised dimension_key
-- just fails with "column does not exist," never a SQL injection risk.
-- ============================================================================

alter table client_dimensions add column is_live boolean not null default true;

create or replace function fn_dimension_data_check(
  p_client_id uuid,
  p_dimension_key text,
  p_resolution_kind text
)
returns bigint
language plpgsql security definer stable
set search_path = public
as $$
declare
  v_table  text;
  v_column text;
  v_count  bigint;
begin
  if not is_platform_admin() then
    raise exception 'not authorized';
  end if;

  if p_resolution_kind = 'fact_column' then
    v_table := 'sales_document_facts';
    v_column := p_dimension_key || '_code';
  elsif p_resolution_kind = 'customer_attribute' then
    v_table := 'customers';
    v_column := replace(p_dimension_key, 'dim_', 'attr_') || '_code';
  else
    -- 'existing' dimensions have no single generic column to check this way
    -- (see this migration's own header comment) — null, not zero, so the
    -- app can tell "not applicable" apart from "applicable, but empty."
    return null;
  end if;

  execute format('select count(*) from %I where client_id = $1 and %I is not null', v_table, v_column)
    into v_count
    using p_client_id;

  return v_count;
end;
$$;

grant execute on function fn_dimension_data_check(uuid, text, text) to authenticated;
