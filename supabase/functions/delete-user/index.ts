// WyzeSales — delete-user Edge Function
// ============================================================================
// Same defensive shape as SeaWyze's delete-user function (seawyze/supabase/
// functions/delete-user/index.ts), adapted to profiles/clients/level instead
// of app_user/company/role: verify the caller's JWT, require adminuser,
// refuse cross-client deletion, refuse self-deletion, refuse deleting a
// platform-admin (support) account through this path. Per Craig's decision
// 8, any adminuser of the same client can delete a user — not just a single
// top-tier role.
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

    const { userId } = await req.json()
    if (!userId) {
      return new Response(
        JSON.stringify({ error: 'Missing userId' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
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
        JSON.stringify({ error: 'Only adminuser accounts can delete users' }),
        { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      )
    }

    const { data: targetProfile, error: targetError } = await supabase
      .from('profiles')
      .select('client_id, is_platform_admin')
      .eq('id', userId)
      .single()
    if (targetError || !targetProfile) {
      return new Response(
        JSON.stringify({ error: 'User not found' }),
        { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      )
    }

    if (targetProfile.is_platform_admin) {
      return new Response(
        JSON.stringify({ error: 'Cannot delete platform admin accounts' }),
        { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      )
    }
    if (targetProfile.client_id !== callerProfile.client_id) {
      return new Response(
        JSON.stringify({ error: 'Cannot delete users outside your own client' }),
        { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      )
    }
    if (userId === callingUser.id) {
      return new Response(
        JSON.stringify({ error: 'Cannot delete your own account' }),
        { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      )
    }

    const { error: deleteProfileError } = await supabase.from('profiles').delete().eq('id', userId)
    if (deleteProfileError) {
      throw new Error(`Failed to delete profile: ${deleteProfileError.message}`)
    }

    const { error: deleteAuthError } = await supabase.auth.admin.deleteUser(userId)
    if (deleteAuthError) {
      throw new Error(`Failed to delete auth account: ${deleteAuthError.message}`)
    }

    return new Response(
      JSON.stringify({ success: true }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
    )
  } catch (e) {
    return new Response(
      JSON.stringify({ error: e instanceof Error ? e.message : String(e) }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
    )
  }
})
