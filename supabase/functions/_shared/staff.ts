// staff.ts: the ONE staff-email rule for edge functions (2026-10-26, personal addresses, Trello zRTbWvXn).
// The two company domains are answered here; any other address is asked of public.fn_is_staff_email (Supabase
// 2026-10-26_2000), the database's rule (the email of exactly one Active employee), AS THE CALLER, the way
// access-check.ts asks hr.check_app_action. So a function and the database never disagree. Fails closed: an error,
// a refusal or an unclear reply is "not staff". Import-free so staff.test.mjs runs it under plain Node.

export function isCompanyEmail(email: string): boolean {
  const e = email.trim().toLowerCase()
  return e.endsWith('@ayache.com') || e.endsWith('@unclogme.com')
}

export async function isStaffEmail(token: string, email: string | null | undefined): Promise<boolean> {
  const e = String(email ?? '').trim().toLowerCase()
  if (!e) return false
  if (isCompanyEmail(e)) return true
  const url = Deno.env.get('SUPABASE_URL') ?? ''
  const anon = Deno.env.get('SUPABASE_ANON_KEY') ?? ''
  try {
    const r = await fetch(`${url}/rest/v1/rpc/fn_is_staff_email`, {
      method: 'POST',
      headers: { apikey: anon, Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ p_email: e }),
    })
    if (!r.ok) {
      console.error(`staff check: HTTP ${r.status}`)
      return false
    }
    return (await r.json()) === true
  } catch (err) {
    console.error(`staff check: ${(err as Error).message}`)
    return false
  }
}
