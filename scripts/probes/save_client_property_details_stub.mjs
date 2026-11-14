// save-client-property, the site's own answers (2026-11-14: name, county, zone, map pin), run for real under Bun with
// EVERY network call stubbed: GoTrue, PostgREST, the access check, Jobber GraphQL, the webhook-jobber replay and
// save-client-job are answered by the router below, so nothing is read from or written to Prod or Jobber, and no
// property is created anywhere. The handler is the file itself (its supabase-js import pointed at the repo's
// node_modules copy, its ../_shared imports at the repo folder), so this tests the committed source, not a copy.
//   bun scripts/probes/save_client_property_details_stub.mjs [path to index.ts]     (default: the repo file)
// CONTROL: run it on the body before the change
//   git show 412d33d5:supabase/functions/save-client-property/index.ts > old.ts && bun <this> old.ts
// every check marked [new] must FAIL there and every [regression] check must PASS. Exit 1 on any FAIL.
import fs from 'node:fs'
import path from 'node:path'
import os from 'node:os'

const REPO = 'C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase'
const SRC = process.argv[2] || `${REPO}/supabase/functions/save-client-property/index.ts`
const SBJS = `${REPO}/node_modules/@supabase/supabase-js/dist/index.mjs`
const SHARED = `${REPO}/supabase/functions/_shared/`
let src = fs.readFileSync(SRC, 'utf8')
const IMP = 'import { createClient } from "jsr:@supabase/supabase-js@2";'
if (src.split(IMP).length !== 2) throw new Error('the supabase-js import line moved; update IMP')
src = src.replace(IMP, `import { createClient } from ${JSON.stringify(SBJS)};`).replaceAll('"../_shared/', `"${SHARED}`).replaceAll("'../_shared/", `'${SHARED}`)
const COPY = path.join(os.tmpdir(), `scp_stub_${process.pid}.ts`)
fs.writeFileSync(COPY, src)

const SB = 'https://stub.supabase.co'
let handler = null
globalThis.Deno = { env: { get: (k) => ({ SUPABASE_URL: SB, SUPABASE_SERVICE_ROLE_KEY: 'stub-service-key', SUPABASE_ANON_KEY: 'stub-anon' })[k] }, serve: (h) => { handler = h } }

const FUTURE = new Date(Date.now() + 30 * 864e5).toISOString()
let W, calls
function reset(over = {}) {
  calls = []
  W = { zones: [7], propPatch: { status: 204 }, newPropertyId: 4242, ...over }
}
const J = (b, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { 'content-type': 'application/json' } })
const eqOf = (u, k) => (u.searchParams.get(k) || '').replace(/^eq\./, '')
globalThis.fetch = async (url, init = {}) => {
  const u = new URL(String(url)), method = (init.method || 'GET').toUpperCase()
  const headers = Object.fromEntries(new Headers(init.headers || {}).entries())
  let body = null
  try { body = init.body ? JSON.parse(String(init.body)) : null } catch { body = String(init.body) }
  calls.push({ method, host: u.host, path: u.pathname, query: u.search, headers, body })
  if (u.host === 'api.getjobber.com') {
    const q = String(body?.query || '')
    if (q.includes('propertyCreate')) {
      const street = body.variables.input.properties[0].address.street1
      return J({ data: { propertyCreate: { properties: [{ id: 'GID-PROP-NEW', address: { street1: street, city: 'Miami', postalCode: '33101' } }], userErrors: [] } } })
    }
    return J({ errors: [{ message: 'unrouted GraphQL' }] })
  }
  if (u.pathname === '/auth/v1/user') {
    if (headers.authorization !== 'Bearer staff-token') return J({ message: 'invalid token' }, 401)
    return J({ id: 'u-fred', aud: 'authenticated', email: 'fred@ayache.com' })
  }
  if (u.pathname === '/rest/v1/rpc/check_app_action') return J(null)
  if (u.pathname === '/functions/v1/webhook-jobber') return J({ entity_id: W.newPropertyId })
  if (u.pathname === '/functions/v1/save-client-job') return J({ ok: false, code: 'unrouted', message: 'the stub never creates a job' })
  const one = /vnd\.pgrst\.object/.test(headers['accept'] || '')
  const rows = (arr) => (one ? (arr.length === 1 ? J(arr[0]) : J({ message: 'not one row' }, 406)) : J(arr))
  const table = u.pathname.replace('/rest/v1/', '')
  if (table === 'webhook_tokens') return rows([{ access_token: 'stub-jobber-token', refresh_token: 'r', client_id: 'c', client_secret: 'stub-secret', expires_at: FUTURE }])
  if (table === 'entity_source_links') {
    const type = eqOf(u, 'entity_type')
    if (type === 'client') return rows([{ source_id: 'GID-CLIENT-381' }])
    if (type === 'property') return rows([{ source_id: 'GID-PROP-NEW' }])
    return rows([])
  }
  if (table === 'zones') return rows(W.zones.filter((z) => String(z) === eqOf(u, 'id')).map((id) => ({ id })))
  // The Service Call job already exists: ensureServiceCallJob answers "existing" and never calls save-client-job.
  if (table === 'jobs') return rows([{ id: 77, title: 'Service Call', job_status: 'active', property_id: W.newPropertyId }])
  if (table === 'properties' && method === 'PATCH') {
    if (W.propPatch.status >= 400) return J({ code: 'XX000', message: 'stub refused the update' }, W.propPatch.status)
    return new Response(null, { status: 204 })
  }
  return J({ message: 'unrouted ' + method + ' ' + u.pathname }, 500)
}
await import(COPY)
fs.unlinkSync(COPY)
if (!handler) throw new Error('the function did not call Deno.serve')

const call = async (b, token = 'staff-token') => {
  const res = await handler(new Request(`${SB}/functions/v1/save-client-property`, {
    method: 'POST', headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) }, body: JSON.stringify(b) }))
  return res.json()
}
const BASE = { client_id: 381, street: '1 Test St', city: 'Miami', postal_code: '33101' }
const jobberCalls = () => calls.filter((c) => c.host === 'api.getjobber.com').length
const patches = () => calls.filter((c) => c.method === 'PATCH' && c.path === '/rest/v1/properties')

let fails = 0
const check = (tag, name, ok, detail = '') => { if (!ok) fails++; console.log(`${ok ? 'PASS' : 'FAIL'} [${tag}] ${name}${detail ? '  ' + detail : ''}`) }

// A: all five answers given
reset()
let r = await call({ ...BASE, name: '  North Tower kitchen ', county: 'broward', zone_id: '7', latitude: 25.7617, longitude: -80.1918 })
let p = patches()
check('regression', 'A: the site is created (one propertyCreate, our id back)', r.ok === true && r.property_id === 4242 && jobberCalls() === 1, JSON.stringify(r).slice(0, 160))
check('new', 'A: name, county and zone are written on our row, trimmed and in the stored vocabulary', p.length >= 1 && p[0].query === '?id=eq.4242' && JSON.stringify(p[0].body) === JSON.stringify({ name: 'North Tower kitchen', county: 'Broward', zone_id: 7 }), JSON.stringify(p[0] ?? null))
check('new', 'A: the map pin fills a gap only (latitude is null)', p.length === 2 && JSON.stringify(p[1].body) === JSON.stringify({ latitude: 25.7617, longitude: -80.1918 }) && /latitude=is\.null/.test(p[1].query) && /id=eq\.4242/.test(p[1].query), JSON.stringify(p[1] ?? null))
check('new', 'A: the answer says they were saved', r.details?.saved === true)
const firstPatch = calls.findIndex((c) => c.method === 'PATCH'), replay = calls.findIndex((c) => c.path === '/functions/v1/webhook-jobber')
check('new', 'A: written after the importer made the row', firstPatch > replay && replay > 0)

// B to D, H: a bad answer refuses before anything is created
for (const [tag, bad, words] of [
  ['B', { county: 'Miami-Dade County' }, /Dade, Broward or Palm Beach/],
  ['C', { zone_id: 999 }, /Zone 999 does not exist/],
  ['D', { latitude: 25.7 }, /latitude and a longitude/],
  ['H', { name: 'x'.repeat(121) }, /too long/],
  ['H2', { zone_id: 'north' }, /not a zone id/],
]) {
  reset()
  r = await call({ ...BASE, ...bad })
  check('new', `${tag}: ${JSON.stringify(bad).slice(0, 40)} is refused with nothing made in Jobber`, r.ok === false && r.code === 'bad_request' && words.test(r.message ?? '') && jobberCalls() === 0 && patches().length === 0, JSON.stringify(r).slice(0, 140))
}

// E: no answers at all (today's dialogs): exactly the old behaviour, no write of ours
reset()
r = await call({ ...BASE })
check('regression', 'E: no answers: created, nothing written on our row', r.ok === true && r.property_id === 4242 && patches().length === 0 && jobberCalls() === 1)
check('regression', 'E: blanks count as not given (name "", county "", zone null)', await (async () => { reset(); const x = await call({ ...BASE, name: ' ', county: '', zone_id: null }); return x.ok === true && patches().length === 0 })())

// F: our row refuses the write: the site still exists, so the call is a success that says what was not saved
reset({ propPatch: { status: 500 } })
r = await call({ ...BASE, name: 'Back kitchen', zone_id: 7 })
check('new', 'F: a refused write is reported, never a failure (a retry would make a second site)', r.ok === true && r.property_id === 4242 && r.details?.saved === false && /its name and zone could not be saved/.test(r.details?.message ?? '') && jobberCalls() === 1, JSON.stringify(r.details ?? null))

// G and I: the old refusals hold
reset()
r = await call({ client_id: 381, street: '', city: 'Miami', postal_code: '33101', name: 'x' })
check('regression', 'G: no street is refused before Jobber', r.ok === false && r.code === 'bad_request' && jobberCalls() === 0)
reset()
r = await call({ ...BASE, name: 'x' }, null)
check('regression', 'I: no sign-in is refused', r.ok === false && r.code === 'forbidden' && jobberCalls() === 0)

console.log(fails ? `${fails} FAIL` : 'all PASS')
process.exit(fails ? 1 : 0)
