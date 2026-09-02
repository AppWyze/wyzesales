// WyzeSales — full-access Supabase key resolution for Edge Functions
// ============================================================================
// Craig, 2026-09-02: a legacy SUPABASE_SERVICE_ROLE_KEY value turned up
// leaked in a stray local file on his Mac (unrelated to this code) — but
// checking Supabase's current docs while responding turned up that the
// legacy service_role JWT can no longer be rotated in place at all any more.
// The current, correct response to a leaked key is to create a new secret
// key (`sb_secret_...`, Dashboard: Settings > API Keys > "Publishable and
// secret API keys") and move every consumer over to it BEFORE deactivating
// the old one — deactivating first would just break these 4 functions until
// the code change below shipped.
//
// Supabase's new secret keys arrive as a single SUPABASE_SECRET_KEYS env
// var — a JSON object keyed by name (e.g. '{"default":"sb_secret_..."}'),
// not a lone string the way the legacy SUPABASE_SERVICE_ROLE_KEY was. This
// helper prefers that new value, parsing out the 'default' key, and falls
// back to the legacy single-value env var only when SUPABASE_SECRET_KEYS
// isn't set (or fails to parse) — so deploying this change is itself a
// no-op until the new secret key actually exists as an Edge Function
// secret, and once it does, every one of these 4 functions (the only place
// in this app allowed to hold a full-access key — see each function's own
// doc comment) picks it up with no further code change or redeploy needed
// on WyzeSales' side; Craig can then deactivate the legacy key in the
// Dashboard once he's confirmed all four still work.
//
// Single source of truth, not copy-pasted across all 4 functions, for the
// same reason resolved_rep_code() (docs/schema/001) is one SQL function
// rather than a duplicated expression per screen. A leading underscore on
// this folder (`_shared`) is Supabase's own convention for a directory the
// CLI does NOT try to deploy as its own function.
export function getServiceKey(): string {
  const secretKeysRaw = Deno.env.get('SUPABASE_SECRET_KEYS')
  if (secretKeysRaw) {
    try {
      const parsed = JSON.parse(secretKeysRaw)
      if (typeof parsed?.default === 'string' && parsed.default) return parsed.default
    } catch {
      // Malformed SUPABASE_SECRET_KEYS — fall through to the legacy key
      // below rather than throwing, so a bad secret value degrades to the
      // old (still-working, until Craig deactivates it) behaviour instead
      // of breaking every admin action in the app outright.
    }
  }
  return Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
}
