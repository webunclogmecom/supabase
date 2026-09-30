// intake-submit v21 (2026-09-29): the collector's comment per photo (Fred: "When uploading a photo we need to also have a
// comment for the photo"), run for real under Bun with EVERY network call stubbed (PostgREST, RPC and Storage answered
// below), so nothing touches Prod. The handler is the file itself; only its supabase-js import is pointed at the repo's
// node_modules copy (as intake_submit_cap_assignee_stub.mjs does).
//   bun scripts/probes/intake_submit_notes_stub.mjs [path to index.ts]     (default: the repo file)
// CONTROL: on T1's v20 file (git show 4b2c6f1:supabase/functions/intake-submit/index.ts) every [new] check must FAIL;
// [guard] and [regression] checks PASS on both. Exit 1 on a FAIL.
import fs from 'node:fs'
import path from 'node:path'
import os from 'node:os'
const REPO = 'C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase'
const SRC = process.argv[2] || `${REPO}/supabase/functions/intake-submit/index.ts`
let src = fs.readFileSync(SRC, 'utf8')
const IMP = "import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'"
if (src.split(IMP).length !== 2) throw new Error('the supabase-js import line moved; update IMP')
src = src.replace(IMP, `import { createClient } from ${JSON.stringify(`${REPO}/node_modules/@supabase/supabase-js/dist/index.mjs`)}`)
const COPY = path.join(os.tmpdir(), `is_notes_stub_${process.pid}.ts`)
fs.writeFileSync(COPY, src)
let handler = null
globalThis.Deno = { env: { get: (k) => ({ SUPABASE_URL: 'https://stub.supabase.co', SUPABASE_SERVICE_ROLE_KEY: 'stub-service-key', GOOGLE_MAPS_BROWSER_KEY: '' })[k] }, serve: (h) => { handler = h } }

const TOKEN = 'StubToken_0123456789abcd'
const FUTURE = new Date(Date.now() + 30 * 864e5).toISOString()
const Q = (key, type, extra = {}) => ({ key, type, label: key.split('.').pop(), ...extra })
const FORM = { version: 2, sections: [{ id: 'access_entry', title: 'Access & entry', questions: [
  Q('access_entry.gate', 'yes_no'), Q('access_entry.gate_photos', 'photos'), Q('access_entry.access_photos', 'photos')] }] }
const P1 = '900/00000001-0000-4000-8000-000000000000.png', P2 = '900/00000002-0000-4000-8000-000000000000.png', P3 = '900/00000003-0000-4000-8000-000000000000.png'
let W, calls
function reset(over = {}) {
  calls = []
  W = {
    intake: { id: 900, property_id: 1164, form_snapshot: FORM, requested: ['access_entry.gate', 'access_entry.gate_photos', 'access_entry.access_photos'], expires_at: FUTURE, submitted_at: null, cancelled_at: null, calendar_task_id: null },
    // live links of form 900: id, photo_id, role, caption
    links: [{ id: 11, photo_id: 101, role: 'access_entry.gate_photos', caption: null }, { id: 12, photo_id: 102, role: 'access_entry.gate_photos', caption: null }, { id: 13, photo_id: 103, role: 'access_entry.access_photos', caption: null }],
    paths: { 101: P1, 102: P2, 103: P3 },
    capFail: false, casRows: 1,
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
  if (p === '/rest/v1/property_intakes' && method === 'GET') return J(g('token') === TOKEN ? [W.intake] : [])
  if (p === '/rest/v1/property_intakes' && method === 'PATCH') return J(W.casRows ? [{ id: 900, submitted_at: new Date().toISOString() }] : [])
  if (p === '/rest/v1/photo_links' && method === 'GET') return J(W.links)
  if (p === '/rest/v1/photo_links' && method === 'PATCH') return W.capFail ? J({ message: 'boom' }, 500) : J(null, 204)
  if (p === '/rest/v1/photo_links' && method === 'POST') return J(null, 201)
  if (p === '/rest/v1/photo_links' && method === 'HEAD') return new Response(null, { status: 200, headers: { 'content-range': '*/0' } })
  if (p === '/rest/v1/photos' && method === 'GET' && u.searchParams.has('storage_path')) return J([])   // attach: no prior photo
  if (p === '/rest/v1/photos' && method === 'GET') return J(Object.entries(W.paths).map(([id, sp]) => ({ id: Number(id), storage_path: 'intake-photos/' + sp })))
  if (p === '/rest/v1/photos' && method === 'POST') return J({ id: 777 }, 201)
  if (p === '/rest/v1/rpc/fn_intake_missing') return J([])
  if (p === '/rest/v1/rpc/fn_intake_applicable') return J(true)
  if (p === '/rest/v1/property_intake_uploads') return J([{ slot: 1 }])
  if (p === '/storage/v1/object/list/intake-photos') return J([{ id: 'obj', name: body?.search, metadata: { mimetype: 'image/png' } }])
  return J({ message: 'unrouted ' + method + ' ' + p }, 500)
}
await import(COPY)
fs.unlinkSync(COPY)
if (typeof handler !== 'function') throw new Error('the handler did not register')
const post = async (b) => {
  const r = await handler(new Request('https://stub/functions/v1/intake-submit', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ token: TOKEN, ...b }) }))
  return { status: r.status, json: await r.json() }
}
const ANSWERS = { 'access_entry.gate': 'yes', 'access_entry.gate_photos': [P1, P2], 'access_entry.access_photos': [P3] }
const submit = (extra = {}) => post({ op: 'submit', collector: '[TEST] collector', answers: ANSWERS, ...extra })
const capPatches = () => calls.filter((c) => c.path === '/rest/v1/photo_links' && c.method === 'PATCH').map((c) => ({ id: Number(new URLSearchParams(c.query).get('id').replace('eq.', '')), caption: c.body && c.body.caption }))
const cas = () => calls.filter((c) => c.path === '/rest/v1/property_intakes' && c.method === 'PATCH').length
const firstCas = () => calls.findIndex((c) => c.path === '/rest/v1/property_intakes' && c.method === 'PATCH')
const lastCap = () => calls.map((c, i) => (c.path === '/rest/v1/photo_links' && c.method === 'PATCH' ? i : -1)).filter((i) => i >= 0).pop() ?? -1
let pass = 0, fail = 0
const ok = (cond, name, got) => { cond ? pass++ : fail++; console.log(`${cond ? 'PASS' : 'FAIL'} ${name}${cond ? '' : ' :: ' + String(JSON.stringify(got) ?? got).slice(0, 300)}`) }

// a comment on one photo is written on that link only, BEFORE the save that locks the form
reset()
{ const r = await submit({ notes: { [P1]: '  Alley access, enter here  ' } })
  ok(r.status === 200 && r.json.ok === true, '[guard] a submit with one comment answers 200', r)
  ok(JSON.stringify(capPatches()) === JSON.stringify([{ id: 11, caption: 'Alley access, enter here' }]), '[new] the comment, trimmed, is written on its own photo link (id 11) and nowhere else', capPatches())
  ok(lastCap() >= 0 && lastCap() < firstCas(), '[new] ... before the compare-and-set that locks the form', { cap: lastCap(), cas: firstCas() })
  const sel = calls.find((c) => c.path === '/rest/v1/photo_links' && c.method === 'GET')
  ok(!!sel && /select=id%2Cphoto_id%2Crole%2Ccaption|select=id,photo_id,role,caption/.test(sel.query), '[new] the live links are read with their id and caption', sel && sel.query)
  const cs = calls.find((c) => c.path === '/rest/v1/property_intakes' && c.method === 'PATCH')
  ok(!!cs && JSON.stringify(cs.body.answers['access_entry.gate_photos']) === JSON.stringify({ value: [P1, P2] }) && !('notes' in cs.body) && !JSON.stringify(cs.body).includes('Alley'), '[regression] the answers are stored as before: paths only, no comment in the record', cs && cs.body) }
// an older page: no notes key at all
reset()
{ const r = await submit()
  ok(r.status === 200 && r.json.ok === true && cas() === 1 && capPatches().length === 0, '[guard] a page from before v21 (no notes) submits, and writes no caption', { r, patches: capPatches() }) }
// ... even when the links already carry comments (another phone's v21 submit wrote them and is about to win the lock)
reset({ links: [{ id: 11, photo_id: 101, role: 'access_entry.gate_photos', caption: 'Old text' }, { id: 12, photo_id: 102, role: 'access_entry.gate_photos', caption: 'Keep me' }, { id: 13, photo_id: 103, role: 'access_entry.access_photos', caption: null }] })
{ const r = await submit()
  ok(r.status === 200 && capPatches().length === 0, '[guard] a page from before v21 (no notes) never clears a comment another phone already wrote', { status: r.status, patches: capPatches() }) }
// a comment cleared after a failed first try is cleared on the link; an unchanged one is not rewritten
reset({ links: [{ id: 11, photo_id: 101, role: 'access_entry.gate_photos', caption: 'Old text' }, { id: 12, photo_id: 102, role: 'access_entry.gate_photos', caption: 'Keep me' }, { id: 13, photo_id: 103, role: 'access_entry.access_photos', caption: null }] })
{ const r = await submit({ notes: { [P2]: 'Keep me' } })
  ok(r.status === 200 && JSON.stringify(capPatches()) === JSON.stringify([{ id: 11, caption: null }]), '[new] a comment cleared since a failed try is cleared (id 11 to null); the unchanged one is not rewritten', capPatches()) }
// refusals, each BEFORE anything is written
for (const [name, notes, msg] of [
  ['301 characters', { [P1]: 'x'.repeat(301) }, 'The comment on a photo in "Access & entry: gate_photos" must be on one line, with at most 300 characters.'],
  ['a line break', { [P3]: 'Line one\nline two' }, 'The comment on a photo in "Access & entry: access_photos" must be on one line, with at most 300 characters.'],
  ['a tab (a control character)', { [P3]: 'a\tb' }, 'The comment on a photo in "Access & entry: access_photos" must be on one line, with at most 300 characters.'],
  ['a lone surrogate', { [P1]: 'bad \ud800 text' }, 'A photo comment in "Access & entry: gate_photos" has a character that cannot be saved. Type it again.'],
]) {
  reset()
  const r = await submit({ notes })
  ok(r.status === 400 && r.json.message === msg && capPatches().length === 0 && cas() === 0, `[new] a comment with ${name} is refused in words naming its question, and nothing is written`, { r, patches: capPatches().length, cas: cas() })
}
reset()
{ const r = await submit({ notes: { [P1]: 'x'.repeat(300) } })
  ok(r.status === 200 && capPatches().length === 1 && capPatches()[0].caption.length === 300, '[new] exactly 300 characters is taken and written', { status: r.status, n: capPatches().length }) }
for (const [name, notes] of [['an array', ['x']], ['a number value', { [P1]: 5 }]]) {
  reset()
  const r = await submit({ notes })
  ok(r.status === 400 && r.json.message === 'Could not read the photo comments.' && cas() === 0, `[new] notes as ${name} is refused ("Could not read the photo comments.")`, r)
}
// a key that is not a live photo of this form is ignored
reset()
{ const r = await submit({ notes: { '901/00000009-0000-4000-8000-000000000000.png': 'elsewhere', [P3]: 'Back door' } })
  ok(r.status === 200 && JSON.stringify(capPatches()) === JSON.stringify([{ id: 13, caption: 'Back door' }]), '[new] a comment for a path that is not a live photo of this form is ignored', capPatches()) }
// a failed caption write answers 500 and submits nothing
reset({ capFail: true })
{ const r = await submit({ notes: { [P1]: 'Alley' } })
  ok(r.status === 500 && r.json.message === 'Could not save the photo comments, please try again.' && cas() === 0, '[new] a failed caption write answers 500 and the form is NOT submitted', { r, cas: cas() }) }
// attach no longer stores a caption, even when one is sent
reset()
{ const r = await post({ op: 'attach', path: P1, role: 'access_entry.gate_photos', caption: 'sneaky' })
  const ins = calls.find((c) => c.path === '/rest/v1/photo_links' && c.method === 'POST')
  ok(r.status === 200 && !!ins && ins.body.caption === null, '[new] attach stores no caption, even when the request carries one', { status: r.status, body: ins && ins.body }) }

console.log(`\n${pass} passed, ${fail} failed  (${path.basename(SRC)})`)
process.exit(fail ? 1 : 0)
