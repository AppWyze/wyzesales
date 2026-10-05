-- 059: trim leading/trailing whitespace from every code column on insert/update.
--
-- Why: a fixed-width source (Morgenster's Pervasive CHAR columns) returned codes padded with
-- spaces ("R004 "), which created duplicate customers, items and reps and broke every exact-string
-- join (names missing, reps listed twice). The extractor now trims at source (Row.Clean), but any
-- new client or hand-loaded data could repeat the problem. This is the database-side safety net:
-- a BEFORE trigger runs ahead of ON CONFLICT, so a padded key upserts onto the existing clean row
-- instead of creating a twin.
--
-- Safe to re-run. Nothing here changes existing rows.

create or replace function public.trg_trim_fact_codes() returns trigger
language plpgsql as $$
begin
  new.account_code     := btrim(new.account_code);
  new.item_code        := btrim(new.item_code);
  new.invoice_rep_code := nullif(btrim(new.invoice_rep_code), '');
  new.warehouse_code   := nullif(btrim(new.warehouse_code), '');
  return new;
end $$;

-- Per-table functions (explicit is clearer than dynamic jsonb tricks and fast on bulk inserts).
create or replace function public.trg_trim_items() returns trigger language plpgsql as $$
begin new.code := btrim(new.code); new.name := btrim(new.name); return new; end $$;
create or replace function public.trg_trim_customers() returns trigger language plpgsql as $$
begin new.code := btrim(new.code); new.name := btrim(new.name); return new; end $$;
create or replace function public.trg_trim_sales_reps() returns trigger language plpgsql as $$
begin new.rep_code := btrim(new.rep_code); new.name := btrim(new.name); return new; end $$;
create or replace function public.trg_trim_categories() returns trigger language plpgsql as $$
begin new.department_code := btrim(new.department_code); new.name := btrim(new.name); return new; end $$;

drop trigger if exists trim_codes on public.sales_document_facts;
create trigger trim_codes before insert or update on public.sales_document_facts
  for each row execute function public.trg_trim_fact_codes();

drop trigger if exists trim_codes on public.items;
create trigger trim_codes before insert or update on public.items
  for each row execute function public.trg_trim_items();

drop trigger if exists trim_codes on public.customers;
create trigger trim_codes before insert or update on public.customers
  for each row execute function public.trg_trim_customers();

drop trigger if exists trim_codes on public.sales_reps;
create trigger trim_codes before insert or update on public.sales_reps
  for each row execute function public.trg_trim_sales_reps();

drop trigger if exists trim_codes on public.categories;
create trigger trim_codes before insert or update on public.categories
  for each row execute function public.trg_trim_categories();
