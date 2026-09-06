-- ============================================================================
-- WyzeSales — Saved Filter Presets become dimension-generic
-- ============================================================================
-- Forty-fifth migration. Design doc Section 4: "Saved Filter Presets store
-- generic dimension_key/value pairs rather than 5 fixed columns — same
-- map-based model as GlobalFilters." schema/035 shipped before the
-- multi-tenant dimension model existed, so it hardcoded exactly WCSA's five
-- filterable dimensions (sales_person/category/customer/item/branch) as ten
-- named columns — the same shape `GlobalFilters` itself used to have before
-- Step 2 rewrote it to a `Map<String, FilterSelection>` keyed by
-- dimension_key. A preset saved for a future client's own new dimension
-- (Market, Area, a future Revenue Split, ...) could never be expressed in
-- the old shape at all.
--
-- Replaced with one `dimensions jsonb` column: `{"<dimension_key>": {"code":
-- "...", "label": "..."}}`, one entry per dimension the preset actually has
-- set — exactly GlobalFilters' own `dimensions` map, serialized. A dimension
-- absent from the object is "not part of this preset" (cleared on apply),
-- matching FilterPreset.forDimension's old null-means-clear behaviour
-- exactly, just generalized to any key instead of five named ones.
--
-- DATA MIGRATION, not just a schema change: every existing preset (private
-- per user, schema/035's own scope decision, so there's no cross-client
-- concern here) has its five old columns folded into the new jsonb column
-- before those columns are dropped — nobody's saved presets silently
-- disappear or go blank the next time they open this dialog.
-- ============================================================================

alter table filter_presets add column dimensions jsonb not null default '{}'::jsonb;

update filter_presets set dimensions = (
  select jsonb_strip_nulls(jsonb_build_object(
    'sales_person', case when sales_person_code is not null
                      then jsonb_build_object('code', sales_person_code, 'label', coalesce(sales_person_label, sales_person_code))
                    end,
    'category', case when category_code is not null
                  then jsonb_build_object('code', category_code, 'label', coalesce(category_label, category_code))
                end,
    'customer', case when customer_code is not null
                  then jsonb_build_object('code', customer_code, 'label', coalesce(customer_label, customer_code))
                end,
    'item', case when item_code is not null
              then jsonb_build_object('code', item_code, 'label', coalesce(item_label, item_code))
            end,
    'branch', case when branch_code is not null
                then jsonb_build_object('code', branch_code, 'label', coalesce(branch_label, branch_code))
              end
  ))
);

alter table filter_presets
  drop column sales_person_code,
  drop column sales_person_label,
  drop column category_code,
  drop column category_label,
  drop column customer_code,
  drop column customer_label,
  drop column item_code,
  drop column item_label,
  drop column branch_code,
  drop column branch_label;
