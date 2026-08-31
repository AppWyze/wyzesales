// WyzeSales — send-upgrade-request Edge Function
// ============================================================================
// Craig's decision 6: "Wyzesales must send an email to support@wyzesales.com
// ... Everything we do going forward must be support@wyzesales.com or refer
// to www.wyzesales.com." Same manual-process shape as SeaWyze's own
// send-upgrade-request function (there's no payment gateway or self-service
// limit change anywhere in this design — see design doc Section 1) — this
// just emails the request; Craig applies the change by hand via the
// Platform Admin screen's Licenses tab.
//
// The domain isn't live yet as of this migration (Craig: "I am going to
// purchase this domain") — this function is written against the intended
// final address now so nothing needs revisiting once it is, but sending
// will fail (or should be pointed at a placeholder Resend sender) until
// support@wyzesales.com actually exists and is verified with Resend.
//
// Requires a RESEND_API_KEY Edge Function secret, same as SeaWyze's
// equivalent function.
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

    // Look the client + license up server-side rather than trusting whatever
    // the request body claims — a "Request upgrade" button only needs to
    // tell this function who the caller is; everything it emails comes from
    // the caller's own profile/client/license rows.
    const { data: callerProfile, error: profileError } = await supabase
      .from('profiles')
      .select('name, email, client_id, clients(name)')
      .eq('id', callingUser.id)
      .single()
    if (profileError || !callerProfile) {
      return new Response(
        JSON.stringify({ error: 'Caller has no profile' }),
        { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      )
    }

    const { data: license } = await supabase
      .from('license')
      .select('max_users, end_date, annual_price')
      .eq('client_id', callerProfile.client_id)
      .maybeSingle()

    const clientName = (callerProfile as { clients?: { name?: string } }).clients?.name ?? 'Unknown client'
    const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY')!

    const emailBody = `
<h2>WyzeSales License Upgrade Request</h2>
<p>A client has requested a license upgrade via the WyzeSales app.</p>

<h3>Client details</h3>
<table>
  <tr><td><strong>Client:</strong></td><td>${clientName}</td></tr>
  <tr><td><strong>Requested by:</strong></td><td>${callerProfile.name}</td></tr>
  <tr><td><strong>Email:</strong></td><td>${callerProfile.email}</td></tr>
</table>

<h3>Current license</h3>
<table>
  <tr><td><strong>Max users:</strong></td><td>${license?.max_users ?? 'Unknown'}</td></tr>
  <tr><td><strong>Expiry date:</strong></td><td>${license?.end_date ?? 'Unknown'}</td></tr>
  <tr><td><strong>Annual price:</strong></td><td>R${license?.annual_price ?? 'N/A'}</td></tr>
</table>

<p>Apply the change via Platform Admin &gt; Licenses.</p>
`

    const response = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${RESEND_API_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        from: 'WyzeSales <support@wyzesales.com>',
        to: ['support@wyzesales.com'],
        subject: `License Upgrade Request — ${clientName}`,
        html: emailBody,
      }),
    })

    if (!response.ok) {
      const error = await response.text()
      return new Response(
        JSON.stringify({ error }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      )
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
