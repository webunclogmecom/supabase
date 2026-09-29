// intake-submit v20 (2026-09-29): the per-question photo limit and the assignee's name on load, run for real under
// Bun with EVERY network call stubbed (PostgREST and Storage answered below), so nothing touches Prod. The handler
// is the file itself; only its supabase-js import is pointed at the repo's node_modules copy.
//   bun scripts/probes/intake_submit_cap_assignee_stub.mjs [path to index.ts]     (default: the repo file)
// CONTROL: on the pre-change file every [new] check must FAIL; [guard] and [regression] checks PASS on both. Exit 1 on a FAIL.
import fs from 'node:fs'
import path from 'node:path'
import os from 'node:os'
const REPO = 'C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase'
const SRC = process.argv[2] || `${REPO}/supabase/functions/intake-submit/index.ts`
let src = fs.readFileSync(SRC, 'utf8')
const IMP = "import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'"
if (src.split(IMP).length !== 2) throw new Error('the supabase-js import line moved; update IMP')
src = src.replace(IMP, `import { createClient } from ${JSON.stringify(`${REPO}/node_modules/@supabase/supabase-js/dist/index.mjs`)}`)
const COPY = path.join(os.tmpdir(), `is_stub_${process.pid}.ts`)
fs.writeFileSync(COPY, src)
let handler = null
globalThis.Deno = { env: { get: (k) => ({ SUPABASE_URL: 'https://stub.supabase.co', SUPABASE_SERVICE_ROLE_KEY: 'stub-service-key', GOOGLE_MAPS_BROWSER_KEY: '' })[k] }, serve: (h) => { handler = h } }

const TOKEN = 'StubToken_0123456789abcd'
const FUTURE = new Date(Date.now() + 30 * 864e5).toISOString()
const Q = (key, type, extra = {}) => ({ key, type, label: key, ...extra })
const V2 = { version: 2, sections: [{ id: 'access_entry', title: 'Access & entry', questions: [
  Q('access_entry.alarm', 'yes_no'), Q('access_entry.alarm_photos', 'photos', { show_if: 'access_entry.alarm=yes', optional: true, max_photos: 3 }),
  Q('access_entry.gate_photos', 'photos')] }] }
const V1 = { version: 1, sections: [{ id: 'access_entry', title: 'Access & entry', questions: [Q('access_entry.alarm', 'yes_no'), Q('access_entry.gate_photos', 'photos')] }] }
const BASE = () => ({ id: 900, property_id: 1164, form_snapshot: V2, requested: ['access_entry.alarm', 'access_entry.alarm_photos'], expires_at: FUTURE, submitted_at: null, cancelled_at: null, calendar_task_id: null })
let W, calls
function reset(over = {}) {
  calls = []
  W = {
    intake: BASE(),
    assignees: { status: 200, rows: [] }, employees: { 1: 'Grecia', 2: 'Mark' },
    roleCount: { 'access_entry.alarm_photos': 0, 'access_entry.gate_photos': 0 }, total: 0,
    prior: null,               // photo id already stored for the path (a retry), or null
    priorRoles: [],            // live link roles of that photo on this form
    ...over,
  }
}
const J = (b, s = 200, h = {}) => new Response(b === null ? null : JSON.stringify(b), { status: s, headers: { 'content-type': 'application/json', ...h } })
globalThis.fetch = async (url, init = {}) => {
  const u = new URL(String(url)), method = (init.method || 'GET').toUpperCase()
  const headers = Object.fromEntries(new Headers(init.headers || {}).entries())
  let body = null; try { body = init.body ? JSON.parse(String(init.body)) : null } catch {}
  calls.push({ method, path: u.pathname, query: u.search, headers, body })
  const p = u.pathname, g = (k) => (u.searchParams.get(k) || '').replace(/^(eq|is)\./, '')
  if (p === '/rest/v1/property_intakes') return J(g('token') === TOKEN ? [W.intake] : [])
  if (p === '/rest/v1/properties') return J([{ name: 'Test property', address: '650 Northwest 33rd Street', city: 'Miami', client_id: 381, latitude: 25.8, longitude: -80.2 }])
  if (p === '/rest/v1/calendar_task_assignees') return W.assignees.status === 200 ? J(W.assignees.rows.slice(0, Number(u.searchParams.get('limit') || 1000))) : J({ message: 'boom' }, W.assignees.status)
  if (p === '/rest/v1/employees') { const id = Number(g('id')); return J(W.employees[id] ? [{ full_name: W.employees[id] }] : []) }
  if (p === '/rest/v1/property_intake_uploads') return J([{ slot: 1 }])
  if (p === '/storage/v1/object/list/intake-photos') return J([{ id: 'obj', name: body?.search, metadata: { mimetype: 'image/png' } }])
  if (p === '/rest/v1/photos' && method === 'GET') return J(W.prior ? [{ id: W.prior }] : [])
  if (p === '/rest/v1/photos' && method === 'POST') return J({ id: 777 }, 201)
  if (p === '/rest/v1/photo_links' && method === 'HEAD') {
    const role = g('role'); const n = role ? (W.roleCount[role] ?? 0) : W.total
    return new Response(null, { status: 200, headers: { 'content-range': `*/${n}` } })
  }
  if (p === '/rest/v1/photo_links' && method === 'GET') return J(W.priorRoles.map((role) => ({ role })))
  if (p === '/rest/v1/photo_links' && method === 'POST') return J(null, 201)
  return J({ message: 'unrouted ' + method + ' ' + p }, 500)
}
await import(COPY)
fs.unlinkSync(COPY)
if (typeof handler !== 'function') throw new Error('the handler did not register')
const post = async (b) => {
  const r = await handler(new Request('https://stub/functions/v1/intake-submit', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ token: TOKEN, ...b }) }))
  return { status: r.status, json: await r.json() }
}
const PATH = (n) => `900/0000000${n}-0000-4000-8000-000000000000.png`
const inserts = () => calls.filter((c) => ['/rest/v1/photos', '/rest/v1/photo_links'].includes(c.path) && c.method === 'POST').length
let pass = 0, fail = 0
const ok = (cond, name, got) => { cond ? pass++ : fail++; console.log(`${cond ? 'PASS' : 'FAIL'} ${name}${cond ? '' : ' :: ' + String(JSON.stringify(got) ?? got).slice(0, 300)}`) }

// load
reset()
{ const r = await post({ op: 'load' })
  ok(r.status === 200 && r.json.ok === true && r.json.intake_id === 900 && r.json.photo_cap === 40 && Array.isArray(r.json.requested) && r.json.form && r.json.property && !('assignee_name' in r.json),
    '[regression] load without a task: every old key, no assignee_name', r.json) }
reset({ intake: { ...BASE(), calendar_task_id: 55 }, assignees: { status: 200, rows: [{ employee_id: 1 }] } })
{ const r = await post({ op: 'load' })
  const a = calls.find((c) => c.path === '/rest/v1/calendar_task_assignees')
  ok(r.status === 200 && r.json.assignee_name === 'Grecia', '[new] load with a one-assignee task: assignee_name is the stored name', r.json.assignee_name)
  ok(!!a && a.headers['accept-profile'] === 'ops' && /task_id=eq\.55/.test(a.query) && /limit=2/.test(a.query), '[new] ... read from ops.calendar_task_assignees, task_id = the link, limit 2', a && { h: a.headers['accept-profile'], q: a.query }) }
for (const [name, as] of [['two assignees', { status: 200, rows: [{ employee_id: 1 }, { employee_id: 2 }] }], ['no assignee', { status: 200, rows: [] }], ['a failed read', { status: 500, rows: [] }]]) {
  reset({ intake: { ...BASE(), calendar_task_id: 55 }, assignees: as })
  const r = await post({ op: 'load' })
  ok(r.status === 200 && r.json.ok === true && !('assignee_name' in r.json), `[guard] load with ${name}: 200, no assignee_name`, r)
}
reset({ intake: { ...BASE(), calendar_task_id: 55 }, assignees: { status: 200, rows: [{ employee_id: 9 }] }, employees: { 9: '  ' + 'N'.repeat(200) + '  ' } })
{ const r = await post({ op: 'load' })
  ok(r.json.assignee_name === 'N'.repeat(120), '[new] a long stored name is trimmed and cut to 120 characters', (r.json.assignee_name || '').length) }

// attach
reset({ roleCount: { 'access_entry.alarm_photos': 2 }, total: 2 })
{ const r = await post({ op: 'attach', path: PATH(1), role: 'access_entry.alarm_photos' })
  ok(r.status === 200 && r.json.ok === true && inserts() === 2, '[guard] the 3rd alarm photo is attached', r) }
reset({ roleCount: { 'access_entry.alarm_photos': 3 }, total: 3 })
{ const r = await post({ op: 'attach', path: PATH(2), role: 'access_entry.alarm_photos' })
  ok(r.status === 429 && r.json.ok === false && r.json.message === 'This question takes at most 3 photos.', '[new] a 4th alarm photo is refused 429 "This question takes at most 3 photos."', r)
  ok(inserts() === 0, '[new] ... and nothing is written', inserts()) }
reset({ roleCount: { 'access_entry.alarm_photos': 3 }, total: 3, prior: 555, priorRoles: ['access_entry.alarm_photos'] })
{ const r = await post({ op: 'attach', path: PATH(3), role: 'access_entry.alarm_photos' })
  ok(r.status === 200 && r.json.already_attached === true, '[guard] re-sending an attached alarm photo at the limit still answers attached', r) }
reset({ roleCount: { 'access_entry.gate_photos': 3 }, total: 3 })
{ const r = await post({ op: 'attach', path: PATH(4), role: 'access_entry.gate_photos' })
  ok(r.status === 200 && r.json.ok === true, '[guard] a question with no max_photos takes a 4th photo', r) }
reset({ roleCount: { 'access_entry.gate_photos': 10 }, total: 40 })
{ const r = await post({ op: 'attach', path: PATH(5), role: 'access_entry.gate_photos' })
  ok(r.status === 429 && r.json.message === 'That is the maximum of 40 photos for this visit.', '[regression] the 40-photo cap still answers 429', r) }
reset({ intake: { ...BASE(), form_snapshot: V1 }, roleCount: { 'access_entry.alarm_photos': 5 }, total: 5 })
{ const r = await post({ op: 'attach', path: PATH(6), role: 'access_entry.alarm_photos' })
  ok(r.status === 200 && r.json.ok === true, '[guard] a version 1 form (no max_photos anywhere) is not limited', r) }

console.log(`\n${pass} passed, ${fail} failed  (${path.basename(SRC)})`)
process.exit(fail ? 1 : 0)
