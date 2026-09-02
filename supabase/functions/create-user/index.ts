// WyzeSales — create-user Edge Function
// ============================================================================
// Adds one user to an already-existing client. Callable by any adminuser of
// that client (per Craig's decision 8 — "all adminuser's should be able to
// add, delete and edit users", not a single top-tier role) — the caller
// check below mirrors that: JWT identifies the caller, their own profile
// row supplies both their level and their client_id, and the new user is
// forced onto that same client_id regardless of what the request body says,
// so an adminuser can never accidentally (or deliberately) provision a user
// on someone else's tenant.
//
// The schema/008 profiles_seat_limit_check trigger enforces max_users at
// the database level — this function doesn't duplicate that logic, it just
// catches the trigger's exception and returns it as a normal error response
// instead of a raw 500, and cleans up the now-orphaned auth user if the
// profiles insert was the step that failed.
//
// Requires a full-access Supabase key as an Edge Function secret — see
// _shared/service_key.ts's own doc comment (2026-09-02, prompted by a
// leaked legacy service_role key).
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { getServiceKey } from '../_shared/service_key.ts'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

// Craig, 2026-09-02: hit this raw ("insert or update on table \"profiles\"
// violates foreign key constraint \"profiles_client_id_rep_code_fkey\"")
// while testing and rightly pointed out it's meaningless to whoever's
// adding a user. schema/001 ties profiles.rep_code to sales_reps and
// profiles.branch_code to branches, both scoped by client_id — so a typo'd
// or not-yet-synced code trips one of exactly these two named constraints
// (Postgres's own auto-naming: <table>_<fk columns>_fkey). Translate just
// those two into plain language; anything else (e.g. the seat-limit
// trigger's own message, already written to be user-facing) passes through
// unchanged rather than being second-guessed here.
function friendlyProfileInsertError(err: { message: string; code?: string }): string {
  if (err.code === '23503') {
    if (err.message.includes('profiles_client_id_rep_code_fkey')) {
      return 'That rep code does not exist for this client. Check the Sales Reps list and try again.'
    }
    if (err.message.includes('profiles_client_id_branch_code_fkey')) {
      return 'That branch code does not exist for this client. Check the Branches list and try again.'
    }
  }
  return err.message
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const authHeader = req.headers.get('Authorization')
    if (!authHeader) {
      return new Response(
        JSON.stringify({ error: 'Missing authorization' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      )
    }

    const supabase = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      getServiceKey(),
    )

    const jwt = authHeader.replace('Bearer ', '')
    const { data: { user: callingUser }, error: callerError } = await supabase.auth.getUser(jwt)
    if (callerError || !callingUser) {
      return new Response(
        JSON.stringify({ error: 'Invalid session' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      )
    }

    const { data: callerProfile, error: callerProfileError } = await supabase
      .from('profiles')
      .select('client_id, level')
      .eq('id', callingUser.id)
      .single()
    if (callerProfileError || !callerProfile) {
      return new Response(
        JSON.stringify({ error: 'Caller has no profile' }),
        { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      )
    }
    if (callerProfile.level !== 'adminuser') {
      return new Response(
        JSON.stringify({ error: 'Only adminuser accounts can add users' }),
        { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      )
    }

    const { email, password, name, level, contactNumber, repCode, branchCode } = await req.json()
    if (!email || !password || !name || !level) {
      return new Response(
        JSON.stringify({ error: 'Missing required fields' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      )
    }
    if (!['user', 'reguser', 'adminuser'].includes(level)) {
      return new Response(
        JSON.stringify({ error: 'Invalid level' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      )
    }

    const { data: authData, error: authError } = await supabase.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
    })
    if (authError) {
      return new Response(
        JSON.stringify({ error: authError.message }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      )
    }

    const { error: profileError } = await supabase
      .from('profiles')
      .insert({
        id: authData.user.id,
        client_id: callerProfile.client_id, // always the caller's own client — never trust a client_id from the request body
        name,
        email,
        level,
        contact_number: contactNumber ?? null,
        rep_code: repCode ?? null,
        branch_code: branchCode ?? null,
        is_active: true,
      })

    if (profileError) {
      await supabase.auth.admin.deleteUser(authData.user.id)
      // profileError.message is the seat-limit trigger's own message when
      // that's what tripped ("Seat limit reached: ...") — already written
      // to be shown to whoever's adding the user, so it passes through
      // untouched. A rep-code/branch-code foreign key miss instead gets
      // translated to plain language — see friendlyProfileInsertError.
      return new Response(
        JSON.stringify({ error: friendlyProfileInsertError(profileError) }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      )
    }

    return new Response(
      JSON.stringify({ success: true, userId: authData.user.id }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
    )
  } catch (e) {
    return new Response(
      JSON.stringify({ error: e instanceof Error ? e.message : String(e) }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
    )
  }
})
