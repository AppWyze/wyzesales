-- ============================================================================
-- Client logo background choice (Wyzesales_Rebuild_Decisions.md Section 84,
-- 2026-09-04) — follow-up to schema/036's client logo feature.
-- ----------------------------------------------------------------------------
-- Craig, after seeing the logo upload live: "what if the colour or their
-- logo is dark? Cannot be seen" — the sidebar is a fixed navy
-- (AppColors.navyDeep), so a dark or richly-coloured logo (the common case
-- for a logo exported assuming a plain white background) could disappear
-- into it with nothing behind it.
--
-- `logo_background` records which of the two ways `ClientLogoMark`
-- (lib/shared/widgets/client_logo_mark.dart) should render a client's logo:
--   'light' (the default) — wrap it in a small white backing chip so a dark
--            or coloured logo stays visible against the navy sidebar.
--   'dark'  — no chip, render directly on the navy — for a client whose logo
--            is itself light/white and was designed to sit on a dark ground
--            (adding a white chip in that case would just recreate the same
--            invisibility problem in the other direction).
-- Defaulting every client (including every one that already uploaded a logo
-- under schema/036, before this column existed) to 'light' directly fixes
-- Craig's own reported case without requiring any of them to configure
-- anything — the 'dark' option exists purely as a self-serve escape hatch
-- for the opposite, less common case.
-- ============================================================================

alter table clients add column logo_background text not null default 'light'
  check (logo_background in ('light', 'dark'));

-- No RLS/grant changes needed — same reasoning as schema/036's own note:
-- `clients_adminuser_update` (schema/008) has no column list and already
-- covers this new column automatically.
