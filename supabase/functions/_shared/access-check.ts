// Access phase 2 (2026-10-20_1430): ask the database, AS THE CALLER, whether this person may do <action>.
// hr.check_app_action knows each action's app and level; off passes, watch passes and logs, on refuses (42501).
// Returns null when allowed, or { status, message } to send back. Any other failure is reported as 503, never
// treated as allowed, so a broken check can never open an app that is "on".
export async function checkAppAction(token: string, action: string): Promise<{ status: number; message: string } | null> {
  const url = Deno.env.get('SUPABASE_URL') ?? ''
  const anon = Deno.env.get('SUPABASE_ANON_KEY') ?? ''
  try {
    const r = await fetch(`${url}/rest/v1/rpc/check_app_action`, {
      method: 'POST',
      headers: { apikey: anon, Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', 'Content-Profile': 'hr' },
      body: JSON.stringify({ p_action: action }),
    })
    if (r.ok) return null
    const j = await r.json().catch(() => ({} as Record<string, unknown>))
    if (j?.code === '42501') return { status: 403, message: String(j?.message ?? 'You do not have access to do this.') }
    console.error(`access-check ${action}: HTTP ${r.status} ${JSON.stringify(j).slice(0, 300)}`)
    return { status: 503, message: 'Access could not be checked. Try again.' }
  } catch (e) {
    console.error(`access-check ${action}: ${(e as Error).message}`)
    return { status: 503, message: 'Access could not be checked. Try again.' }
  }
}
