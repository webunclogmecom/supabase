// Standing check: the edge access check (supabase/functions/_shared/access-check.ts) lets the server key through, still
// lets a staff session through, and still refuses a signed-in person with no access. Writes nothing.
//   node scripts/checks/edge_access_check_server_key.mjs            (reads .env at the repo root, or ENV_FILE)
// Found 2026-11-17 testing Trello #198: the helper sent the anon apikey with `Bearer sb_secret_...`; a secret key is not a
// JWT, PostgREST answered 401 PGRST301, and every server-key caller got "Access could not be checked" (503). The fix sends a
// secret key in both headers, so the API gateway checks it is a real key and the RPC runs as service_role.
// Calls only the harmless exits right after the check: save-calendar-visit with an empty patch on a 112-YA visit ("Nothing
// to save."), calculate-driving-time with no legs (400), parse-gdo-permit with no PDF (400). The two sign-ins are minted by
// magic link (no email is sent) and signed out at the end: fred@ayache.com (admin) and fredzerpa2@gmail.com (Fred's own
// field test sign-in, no Visit Calendar Edit). Non-zero exit on any failure; a check that could not run is a failure.
import { readFileSync } from 'node:fs'

const envFile = process.env.ENV_FILE || new URL('../../.env', import.meta.url)
for (const line of readFileSync(envFile, 'utf8').split(/\r?\n/)) {
  const m = line.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/)
  if (m && !(m[1] in process.env)) process.env[m[1]] = m[2].trim().replace(/^(["'])(.*)\1$/, '$2')
}
const U = `https://${process.env.SUPABASE_PROJECT_ID}.supabase.co`
const SECRET = process.env.SUPABASE_SERVICE_ROLE_KEY
const PUB = process.env.SUPABASE_PUBLISHABLE_KEY || process.env.SUPABASE_ANON_KEY
const FAKE = 'sb_secret_madeUpNotARealKey0000000000'
const COULD_NOT = 'Access could not be checked'
let bad = 0
const ok = (cond, label, extra = '') => { console.log(`${cond ? 'ok  ' : 'FAIL'}  ${label}${extra ? `: ${extra}` : ''}`); if (!cond) bad++ }
const post = async (path, apikey, bearer, body) => {
  const r = await fetch(U + path, { method: 'POST', headers: { apikey, Authorization: `Bearer ${bearer}`, 'Content-Type': 'application/json', 'Content-Profile': 'hr' }, body: JSON.stringify(body) })
  const t = await r.text()
  let j = null; try { j = JSON.parse(t) } catch { /* not JSON */ }
  return { status: r.status, j, t: t.slice(0, 200) }
}
const fn = (name, bearer, body) => post(`/functions/v1/${name}`, bearer.startsWith('sb_secret_') ? bearer : PUB, bearer, body)

ok(SECRET?.startsWith('sb_secret_') && PUB?.startsWith('sb_publishable_'), 'the keys this check needs are in the env file')

// 1. The gateway behaviour the fix leans on, measured directly on the RPC the helper calls.
const rpc = (k, b) => post('/rest/v1/rpc/check_app_action', k, b, { p_action: 'save_calendar_visit' })
let r = await rpc(PUB, SECRET)
ok(r.status === 401 && r.j?.code === 'PGRST301', 'control: the OLD header pair (anon apikey + secret bearer) is refused as a bad JWT', `${r.status} ${r.t}`)
r = await rpc(SECRET, SECRET)
ok(r.status === 200 && r.j?.ok === true, 'a secret key in both headers passes the check as service_role', `${r.status} ${r.t}`)
r = await rpc(FAKE, FAKE)
ok(r.status === 401, 'a made-up secret key in both headers is refused by the gateway (the helper reports 503, never allows)', `${r.status} ${r.t}`)

// 2. Sign-ins, minted without an email.
async function session(email) {
  const g = await post('/auth/v1/admin/generate_link', SECRET, SECRET, { type: 'magiclink', email })
  const v = await post('/auth/v1/verify', PUB, PUB, { type: 'magiclink', token_hash: g.j?.hashed_token })
  return v.j?.access_token ?? null
}
const staff = await session('fred@ayache.com')
const field = await session('fredzerpa2@gmail.com')
ok(!!staff && !!field, 'minted a staff session and a no-access session')

const clients = await (await fetch(`${U}/rest/v1/clients?client_code=eq.112-YA&select=id`, { headers: { apikey: SECRET, Authorization: `Bearer ${SECRET}` } })).json()
const visits = await (await fetch(`${U}/rest/v1/visits?client_id=eq.${clients?.[0]?.id}&deleted_at=is.null&select=id&order=id.desc&limit=1`, { headers: { apikey: SECRET, Authorization: `Bearer ${SECRET}` } })).json()
const visitId = visits?.[0]?.id
ok(Number.isInteger(visitId), 'found a 112-YA visit to send an empty patch to', String(visitId))

// 3. The three functions a server key reaches the check in (the other 22 refuse a server key at their own sign-in gate first).
const empty = { visit_id: visitId, patch: {} }
r = await fn('save-calendar-visit', SECRET, empty)
ok(r.j?.code === 'no_changes', 'save-calendar-visit, server key: passes the check ("Nothing to save.")', `${r.status} ${r.t}`)
r = await fn('calculate-driving-time', SECRET, { legs: [] })
ok(r.status === 400 && r.j?.error === 'no legs', 'calculate-driving-time, server key: passes the check (400 no legs)', `${r.status} ${r.t}`)
r = await fn('parse-gdo-permit', SECRET, {})
ok(r.status === 400 && r.j?.error === 'no_file', 'parse-gdo-permit, server key: passes the check (400 no_file)', `${r.status} ${r.t}`)
r = await fn('save-calendar-visit', FAKE, empty)
ok(r.status === 401, 'save-calendar-visit, made-up secret key: the gateway refuses it', `${r.status} ${r.t}`)

// 4. People: unchanged by the fix.
if (staff) {
  r = await fn('save-calendar-visit', staff, empty)
  ok(r.j?.code === 'no_changes', 'save-calendar-visit, staff session (admin): passes', `${r.status} ${r.t}`)
}
if (field) {
  r = await fn('save-calendar-visit', field, empty)
  ok(r.j?.code === 'no_access' && !String(r.j?.message).includes(COULD_NOT) && /do not have access/.test(String(r.j?.message)),
    'save-calendar-visit, signed in with no Visit Calendar Edit: refused with the access sentence', `${r.status} ${r.t}`)
  r = await fn('parse-gdo-permit', field, {})
  ok(r.status === 403 && r.j?.error === 'no_access', 'parse-gdo-permit, signed in with no Client App Edit: 403', `${r.status} ${r.t}`)
}

// 5. Sign the minted sessions out again.
for (const t of [staff, field].filter(Boolean)) {
  const o = await fetch(`${U}/auth/v1/logout?scope=local`, { method: 'POST', headers: { apikey: PUB, Authorization: `Bearer ${t}` } })
  ok(o.status === 204, 'signed a minted session out', String(o.status))
}

console.log(bad ? `\n${bad} FAILED` : '\nALL PASS')
process.exit(bad ? 1 : 0)
