// WyzeSales — create-client Edge Function
// ============================================================================
// Platform-admin-only. Atomically creates a new client (tenant) + its
// license + its first adminuser + a support+<code>@wyzesales.com
// platform-admin login, the same shape SeaWyze's create-company function
// uses (seawyze/supabase/functions/create-company/index.ts) — adapted to
// WyzeSales' actual tables: clients/license/profiles instead of
// company/license/app_user, and no vessel fields anywhere.
//
// "Atomic" here means best-effort sequential rollback, not a real DB
// transaction — this function makes several separate calls across the Auth
// Admin API and normal table inserts, which can't share one Postgres
// transaction. Every step that can fail after an earlier step already
// succeeded unwinds what came before it, same limitation SeaWyze's own
// function has (see its comments) and same trade-off this project accepted
// per the design doc (Section 1) rather than solving here.
//
// Requires SUPABASE_SERVICE_ROLE_KEY (or the new sb_secret_... key) as an
// Edge Function secret — this is the one place in the whole app allowed to
// use it, since creating an auth.users row needs the Admin API, which the
// Flutter client can never hold (see the security note in
// core/supabase/supabase_config.dart and Craig's own question about the
// sb_secret key — this function is *why* that key exists at all).
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

function slugifyCode(code: string): string {
  const slug = code.toLowerCase().replace(/[^a-z0-9]+/g, '').substring(0, 24)
  return slug || 'client'
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const supabase = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
    )

    const {
      clientCode,
      clientName,
      adminName,
      adminEmail,
      adminPassword,
      supportPassword,
      planId,
      maxUsers,
      discountPercent,
    } = await req.json()

    if (!clientCode || !clientName || !adminName || !adminEmail || !adminPassword || !planId || !supportPassword) {
      return new Response(
        JSON.stringify({ error: 'Missing required fields' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      )
    }

    const supportEmail = `support+${slugifyCode(clientCode)}@wyzesales.com`

    const { data: existingUsers } = await supabase.auth.admin.listUsers()
    const emailExists = existingUsers?.users?.some(
      (u: { email?: string }) => u.email === adminEmail || u.email === supportEmail,
    )
    if (emailExists) {
      return new Response(
        JSON.stringify({ error: `A user with email ${adminEmail} or ${supportEmail} already exists` }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      )
    }

    let clientId: string | null = null
    let adminAuthUserId: string | null = null
    let supportAuthUserId: string | null = null

    // 1. Client
    const { data: clientRow, error: clientError } = await supabase
      .from('clients')
      .insert({ code: clientCode, name: clientName })
      .select()
      .single()
    if (clientError) throw new Error(`Client: ${clientError.message}`)
    clientId = clientRow.id

    // 2. Plan + license
    const { data: plan, error: planError } = await supabase
      .from('pricing_plan')
      .select('base_price, price_per_additional_user, base_users')
      .eq('id', planId)
      .single()
    if (planError) {
      await supabase.from('clients').delete().eq('id', clientId)
      throw new Error(`Plan: ${planError.message}`)
    }

    const seats = maxUsers ?? plan.base_users
    const additionalUsers = Math.max(0, seats - plan.base_users)
    const discount = discountPercent ?? 0
    const monthlyTotal = (plan.base_price + additionalUsers * plan.price_per_additional_user) * (1 - discount / 100)
    const startDate = new Date().toISOString().substring(0, 10)
    const endDate = new Date(new Date().setFullYear(new Date().getFullYear() + 1)).toISOString().substring(0, 10)

    const { error: licenseError } = await supabase
      .from('license')
      .insert({
        client_id: clientId,
        plan_id: planId,
        max_users: seats,
        base_users: plan.base_users,
        start_date: startDate,
        end_date: endDate,
        status: 'active',
        annual_price: monthlyTotal * 12,
        discount_percent: discount,
      })
    if (licenseError) {
      await supabase.from('clients').delete().eq('id', clientId)
      throw new Error(`License: ${licenseError.message}`)
    }

    // 3. First adminuser
    const { data: adminAuth, error: adminAuthError } = await supabase.auth.admin.createUser({
      email: adminEmail,
      password: adminPassword,
      email_confirm: true,
    })
    if (adminAuthError) {
      await supabase.from('clients').delete().eq('id', clientId)
      throw new Error(`Admin auth: ${adminAuthError.message}`)
    }
    adminAuthUserId = adminAuth.user.id

    const { error: adminProfileError } = await supabase
      .from('profiles')
      .insert({
        id: adminAuthUserId,
        client_id: clientId,
        name: adminName,
        email: adminEmail,
        level: 'adminuser',
        is_active: true,
      })
    if (adminProfileError) {
      await supabase.auth.admin.deleteUser(adminAuthUserId)
      await supabase.from('clients').delete().eq('id', clientId)
      throw new Error(`Admin profile: ${adminProfileError.message}`)
    }

    // 4. Platform-admin support login for this client — excluded from the
    // seat count (profiles_seat_limit_check, schema/008, skips
    // is_platform_admin rows), so this insert never competes with the
    // client's own paid seats.
    const { data: supportAuth, error: supportAuthError } = await supabase.auth.admin.createUser({
      email: supportEmail,
      password: supportPassword,
      email_confirm: true,
    })
    if (supportAuthError) {
      await supabase.auth.admin.deleteUser(adminAuthUserId)
      await supabase.from('clients').delete().eq('id', clientId)
      throw new Error(`Support auth: ${supportAuthError.message}`)
    }
    supportAuthUserId = supportAuth.user.id

    const { error: supportProfileError } = await supabase
      .from('profiles')
      .insert({
        id: supportAuthUserId,
        client_id: clientId,
        name: 'WyzeSales Support',
        email: supportEmail,
        level: 'adminuser',
        is_active: true,
        is_platform_admin: true,
      })
    if (supportProfileError) {
      await supabase.auth.admin.deleteUser(supportAuthUserId)
      await supabase.auth.admin.deleteUser(adminAuthUserId)
      await supabase.from('clients').delete().eq('id', clientId)
      throw new Error(`Support profile: ${supportProfileError.message}`)
    }

    return new Response(
      JSON.stringify({ success: true, clientId, supportEmail }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
    )
  } catch (e) {
    return new Response(
      JSON.stringify({ error: e instanceof Error ? e.message : String(e) }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
    )
  }
})
