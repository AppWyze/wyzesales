-- ============================================================================
-- WyzeSales — client contact/address fields (Supabase / Postgres)
-- ============================================================================
-- Sixteenth migration. Craig, 2026-08-28, a batch of Platform Admin/Settings
-- requirements: "Clients: Requirement to edit a client. Same as Seawyze" and
-- "Settings > Company: Requirement to edit a Company. Same as Seawyze with
-- all of the fields as per Seawyze but without the Company Documents
-- function."
--
-- schema/008's own comment on `clients_adminuser_update` flagged this gap
-- explicitly at the time: "clients has no address/contact columns, per the
-- design doc's 'on top of the existing clients/profiles' scope" — this
-- migration is that follow-up, once Craig actually asked for the editing UI
-- those columns are for.
--
-- Columns mirror SeaWyze's CompanyModel (lib/data/models/company_model.dart)
-- one-for-one, MINUS `documents_url` — Craig was explicit that the "Company
-- Documents" feature (an external link + a card on the Settings tab) is not
-- part of this ask, so there's nothing here for it to point at. Every other
-- SeaWyze CompanyModel field is added even though SeaWyze's own edit dialog
-- only ever exposes a subset of them (name/contact name/contact number/
-- contact email/address1/city/country) — "with all of the fields as per
-- Seawyze" reads as an ask for full field parity, not a request to also copy
-- SeaWyze's dialog's own incompleteness, so WyzeSales' Company/Client edit
-- dialogs expose all of them (see platform_admin_screen.dart's
-- _EditClientDialog and settings_screen.dart's _EditCompanyDialog).
--
-- No RLS/grant changes needed: `clients_adminuser_update` (schema/008) is a
-- row-level policy with no column list, and `grant update, insert on clients
-- to authenticated` is table-level — both already cover any column added
-- here automatically.
-- ============================================================================

alter table clients
  add column contact_name   text,
  add column contact_number text,
  add column contact_email  text,
  add column address1       text,
  add column address2       text,
  add column address3       text,
  add column city           text,
  add column country        text,
  add column postal_code    text;
