-- ============================================================================
-- Client logo branding (Wyzesales_Rebuild_Decisions.md Section 83, 2026-09-04)
-- ----------------------------------------------------------------------------
-- Craig: "Some clients would like their own branding. How do you think could
-- facilitate this without loosing the Wyzesales branding and identity?" —
-- agreed on a co-branding pattern (client logo in the sidebar's primary
-- brand slot, "WyzeSales" kept as a smaller persistent mark in the sidebar
-- footer — see `_ProfileFooter`, app_shell.dart, which already shows that
-- unconditionally and needed no change), logo-only for v1 ("I agree with
-- this. Logo only."), self-serve via Settings > Company > Branding.
--
-- Two new nullable columns on `clients` — nullable so every existing client
-- (the overwhelming majority, indefinitely, since this is opt-in) simply has
-- no logo and the app falls back to the stock WyzeSales mark, same
-- "nullable, must render as absent cleanly" convention schema/016's contact/
-- address fields already established on this same table.
-- ============================================================================

alter table clients add column logo_path text;
alter table clients add column logo_updated_at timestamptz;

-- No RLS/grant changes needed on `clients` itself: `clients_adminuser_update`
-- (schema/008) is a row-level policy with no column list, and `grant update,
-- insert on clients to authenticated` is table-level — both already cover
-- these two new columns automatically, same reasoning as schema/016's own
-- comment on adding the contact/address fields.

-- ============================================================================
-- Storage: one bucket, `client-logos`, holding one object per client at a
-- fixed path (`{client_id}/logo.png`, always PNG regardless of what the
-- admin actually uploaded — the app crops/re-encodes client-side before
-- upload, see `_LogoCropDialog`/settings_repository.dart's `uploadClientLogo`)
-- so a re-upload is a plain overwrite (`upsert: true`) rather than needing to
-- track/clean up a changing filename.
--
-- Public bucket: a company logo isn't sensitive data, and making it public
-- means the sidebar (and, later, anywhere else this logo might be reused —
-- an exported PDF, the login screen) can just build a stable public URL
-- (`getPublicUrl`, no signed-URL refresh logic needed) — the same trade-off
-- most SaaS products make for workspace/org logos. Public read bypasses RLS
-- entirely at Supabase's storage layer (the `/storage/v1/object/public/...`
-- endpoint), so no SELECT policy is strictly required for the app's own
-- reads — the SELECT policy below is defense-in-depth only, scoping any
-- *authenticated* API read (e.g. a future `.list()`/`.download()` call this
-- app doesn't make today) to the caller's own client, same as everywhere
-- else in this schema.
-- ============================================================================

insert into storage.buckets (id, name, public)
values ('client-logos', 'client-logos', true)
on conflict (id) do nothing;

-- Path convention enforced here, not just assumed client-side: every policy
-- below requires the object's first path segment (`storage.foldername(name)`
-- — everything before the final filename) to equal the caller's own
-- client_id, so one client's adminuser can never read/write into another
-- client's folder even if they guessed the object path.

create policy client_logos_select on storage.objects
for select using (
  bucket_id = 'client-logos'
  and (storage.foldername(name))[1] = get_my_client_id()::text
);

create policy client_logos_adminuser_insert on storage.objects
for insert to authenticated
with check (
  bucket_id = 'client-logos'
  and is_adminuser()
  and (storage.foldername(name))[1] = get_my_client_id()::text
);

create policy client_logos_adminuser_update on storage.objects
for update to authenticated
using (
  bucket_id = 'client-logos'
  and is_adminuser()
  and (storage.foldername(name))[1] = get_my_client_id()::text
)
with check (
  bucket_id = 'client-logos'
  and is_adminuser()
  and (storage.foldername(name))[1] = get_my_client_id()::text
);

create policy client_logos_adminuser_delete on storage.objects
for delete to authenticated
using (
  bucket_id = 'client-logos'
  and is_adminuser()
  and (storage.foldername(name))[1] = get_my_client_id()::text
);
