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
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
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
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
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
      // profileError.message here is the seat-limit trigger's own message
      // when that's what tripped ("Seat limit reached: ...") — surfaced
      // as-is rather than a generic failure, since it's already written to
      // be shown to whoever's adding the user.
      return new Response(
        JSON.stringify({ error: profileError.message }),
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
