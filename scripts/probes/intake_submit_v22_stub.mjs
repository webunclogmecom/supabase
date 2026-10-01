// intake-submit v22 (2026-09-30): the explanation REQUIRED on every photo of a question list version 3 form (Fred:
// "everytime you add a pic you need to put explaination") and the Remove op (a photo attached before submit can be
// removed by the collector). Run for real under Bun with EVERY network call stubbed (PostgREST, RPC and Storage answered
// below), so nothing touches Prod. The handler is the file itself; only its supabase-js import is pointed at the repo's
// node_modules copy (as intake_submit_notes_stub.mjs does).
//   bun scripts/probes/intake_submit_v22_stub.mjs [path to index.ts]     (default: the repo file)
// CONTROL: on v21 (git show 9e9322e:supabase/functions/intake-submit/index.ts) every [new] check must FAIL (8 passed, 11
// failed); [guard] and [regression] checks PASS on both. Exit 1 on a FAIL. 19 checks.
import fs from 'node:fs'
import path from 'node:path'
import os from 'node:os'
const REPO = 'C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase'
const SRC = process.argv[2] || `${REPO}/supabase/functions/intake-submit/index.ts`
let src = fs.readFileSync(SRC, 'utf8')
const IMP = "import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'"
if (src.split(IMP).length !== 2) throw new Error('the supabase-js import line moved; update IMP')
src = src.replace(IMP, `import { createClient } from ${JSON.stringify(`${REPO}/node_modules/@supabase/supabase-js/dist/index.mjs`)}`)
const COPY = path.join(os.tmpdir(), `is_v22_stub_${process.pid}.ts`)
fs.writeFileSync(COPY, src)
let handler = null
globalThis.Deno = { env: { get: (k) => ({ SUPABASE_URL: 'https://stub.supabase.co', SUPABASE_SERVICE_ROLE_KEY: 'stub-service-key', GOOGLE_MAPS_BROWSER_KEY: '' })[k] }, serve: (h) => { handler = h } }

const TOKEN = 'StubToken_0123456789abcd'
const FUTURE = new Date(Date.now() + 30 * 864e5).toISOString()
const Q = (key, type, label, extra = {}) => ({ key, type, label, ...extra })
const SECTIONS = [
  { id: 'access_entry', title: 'Access & entry', questions: [Q('access_entry.gate', 'yes_no', 'Is there a closed gate?'), Q('access_entry.access_photos', 'photos', 'Photos of the access point')] },
  { id: 'lift_station', title: 'Lift station', questions: [Q('lift_station.count', 'number', 'How many lift stations?')] },
  { id: 'lift_station_photos', title: 'Photos for the lift station', questions: [
    Q('lift_station.access_photos', 'photos', 'Lift station access', { short: 'Access', show_if: 'lift_station.count>0', optional: true, max_photos: 3 }),
    Q('lift_station.photos', 'photos', 'Lift station', { show_if: 'lift_station.count>0' })] },
]
const FORM3 = { version: 3, photo_note_required: true, sections: SECTIONS }
const FORM2 = { version: 2, sections: SECTIONS }
const REQ = ['access_entry.gate', 'access_entry.access_photos', 'lift_station.count', 'lift_station.access_photos', 'lift_station.photos']
const P = (n) => `900/0000000${n}-0000-4000-8000-000000000000.png`
const P1 = P(1), P2 = P(2), P3 = P(3), P4 = P(4), P9 = P(9)
let W, calls
function reset(over = {}) {
  calls = []
  W = {
    intake: { id: 900, property_id: 1164, form_snapshot: FORM3, requested: REQ, expires_at: FUTURE, submitted_at: null, cancelled_at: null, calendar_task_id: null },
    // live links of form 900: id, photo_id, role, caption (deleted ones are not listed: the handler reads live links only)
    links: [{ id: 11, photo_id: 101, role: 'access_entry.access_photos', caption: null }, { id: 12, photo_id: 102, role: 'lift_station.photos', caption: null }, { id: 13, photo_id: 103, role: 'lift_station.photos', caption: null }],
    paths: { 101: P1, 102: P2, 103: P3, 104: P4 },
    capFail: false, rmFail: false, casRows: 1,
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
  if (p === '/rest/v1/photo_links' && method === 'PATCH') {
    if (body && 'deleted_at' in body) {   // remove: the soft delete, answered with the rows it touched
      if (W.rmFail) return J({ message: 'boom' }, 500)
      const pid = Number(g('photo_id')); const hit = W.links.filter((l) => l.photo_id === pid)
      W.links = W.links.filter((l) => l.photo_id !== pid)
      return J(hit.map((l) => ({ id: l.id })))
    }
    return W.capFail ? J({ message: 'boom' }, 500) : J(null, 204)
  }
  if (p === '/rest/v1/photo_links' && method === 'POST') return J(null, 201)
  if (p === '/rest/v1/photo_links' && method === 'HEAD') return new Response(null, { status: 200, headers: { 'content-range': '*/0' } })
  if (p === '/rest/v1/photos' && method === 'GET' && u.searchParams.has('storage_path')) {
    const sp = g('storage_path').replace(/^intake-photos\//, ''); const id = Object.entries(W.paths).find(([, x]) => x === sp)?.[0]
    return J(id ? [{ id: Number(id) }] : [])
  }
  if (p === '/rest/v1/photos' && method === 'GET') return J(Object.entries(W.paths).map(([id, sp]) => ({ id: Number(id), storage_path: 'intake-photos/' + sp })))
  if (p === '/rest/v1/rpc/fn_intake_missing') return J([])
  if (p === '/rest/v1/rpc/fn_intake_applicable') return J(true)
  if (p === '/storage/v1/object/intake-photos' && method === 'DELETE') return J((body?.prefixes || []).map((n) => ({ name: n })))   // v22 never calls it (R1c)
  return J({ message: 'unrouted ' + method + ' ' + p }, 500)
}
await import(COPY)
fs.unlinkSync(COPY)
if (typeof handler !== 'function') throw new Error('the handler did not register')
const post = async (b) => {
  const r = await handler(new Request('https://stub/functions/v1/intake-submit', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ token: TOKEN, ...b }) }))
  return { status: r.status, json: await r.json() }
}
const ANSWERS = { 'access_entry.gate': 'yes', 'access_entry.access_photos': [P1], 'lift_station.count': 1, 'lift_station.photos': [P2, P3] }
const ALL_NOTES = { [P1]: 'Side door, the one with the ramp', [P2]: 'The pump pit, lid open', [P3]: 'The float switch' }
const submit = (extra = {}) => post({ op: 'submit', collector: '[TEST] collector', answers: ANSWERS, ...extra })
const capPatches = () => calls.filter((c) => c.path === '/rest/v1/photo_links' && c.method === 'PATCH' && c.body && 'caption' in c.body).map((c) => ({ id: Number(new URLSearchParams(c.query).get('id').replace('eq.', '')), caption: c.body.caption }))
const rmPatches = () => calls.filter((c) => c.path === '/rest/v1/photo_links' && c.method === 'PATCH' && c.body && 'deleted_at' in c.body)
const deletes = () => calls.filter((c) => c.path.startsWith('/storage/v1/object/') && c.method === 'DELETE')
const cas = () => calls.filter((c) => c.path === '/rest/v1/property_intakes' && c.method === 'PATCH').length
const missingCalls = () => calls.filter((c) => c.path === '/rest/v1/rpc/fn_intake_missing').length
const casBody = () => (calls.find((c) => c.path === '/rest/v1/property_intakes' && c.method === 'PATCH') || {}).body
let pass = 0, fail = 0
const ok = (cond, name, got) => { cond ? pass++ : fail++; console.log(`${cond ? 'PASS' : 'FAIL'} ${name}${cond ? '' : ' :: ' + String(JSON.stringify(got) ?? got).slice(0, 400)}`) }
const MSG3 = '3 photos have no explanation: "Access & entry: Photos of the access point" (1), "Photos for the lift station: Lift station" (2). Write what each photo shows in the box under it.'
const MSG1 = '1 photo has no explanation: "Photos for the lift station: Lift station" (1). Write what each photo shows in the box under it.'

// ---- the explanation rule (version 3 snapshot)
reset()
{ const r = await submit()
  ok(r.status === 400 && r.json.message === MSG3, '[new] N1 v3: three claimed photos with no explanation are refused, each question named with its count, in form order', r)
  ok(r.status === 400 && capPatches().length === 0 && cas() === 0 && missingCalls() === 0, '[new] N1b ... and nothing is written: no caption, no lock, and fn_intake_missing is never called', { status: r.status, caps: capPatches().length, cas: cas(), missing: missingCalls() }) }
reset()
{ const r = await submit({ notes: { ...ALL_NOTES, [P3]: '   ' } })
  ok(r.status === 400 && r.json.message === MSG1 && cas() === 0, '[new] N2 v3: an explanation of spaces only is no explanation (1 photo, its question named)', r) }
reset()
{ const r = await submit({ notes: ALL_NOTES })
  ok(r.status === 200 && r.json.ok === true && cas() === 1, '[guard] N3 v3: every claimed photo explained: 200 and the form is locked', r)
  ok(JSON.stringify(capPatches().sort((a, b) => a.id - b.id)) === JSON.stringify([{ id: 11, caption: ALL_NOTES[P1] }, { id: 12, caption: ALL_NOTES[P2] }, { id: 13, caption: ALL_NOTES[P3] }]), '[guard] N3b ... each explanation written on its own link', capPatches()) }
// a lost attach reply: photo 104 is attached (a live link) but the page never claimed it; the collector had no box for it
reset({ links: [{ id: 11, photo_id: 101, role: 'access_entry.access_photos', caption: null }, { id: 12, photo_id: 102, role: 'lift_station.photos', caption: null }, { id: 13, photo_id: 103, role: 'lift_station.photos', caption: null }, { id: 14, photo_id: 104, role: 'lift_station.photos', caption: null }] })
{ const r = await submit({ notes: ALL_NOTES })
  const lsv = casBody() && casBody().answers['lift_station.photos']
  ok(r.status === 200 && JSON.stringify(lsv) === JSON.stringify({ value: [P2, P3, P4] }) && !capPatches().some((c) => c.id === 14), '[guard] N4 v3: an attached photo the page did not claim (a lost attach reply) is exempt: submitted, in the answer, no caption written', { status: r.status, lsv, caps: capPatches() }) }
// a claimed path with no live link (removed on another phone) is dropped as before and never needs an explanation
reset()
{ const r = await submit({ answers: { ...ANSWERS, 'access_entry.access_photos': [P1, P9] }, notes: ALL_NOTES })
  ok(r.status === 200 && JSON.stringify(casBody().answers['access_entry.access_photos']) === JSON.stringify({ value: [P1] }), '[guard] N5 v3: a claimed photo that is no longer attached is dropped and needs no explanation', { status: r.status, a: casBody() && casBody().answers['access_entry.access_photos'] }) }
reset({ intake: { id: 900, property_id: 1164, form_snapshot: FORM2, requested: REQ, expires_at: FUTURE, submitted_at: null, cancelled_at: null, calendar_task_id: null } })
{ const r = await submit()
  ok(r.status === 200 && cas() === 1 && capPatches().length === 0, '[regression] N6 v2 (no flag): photos without comments submit exactly as v21', { status: r.status, cas: cas(), caps: capPatches().length }) }
reset()
{ const r = await submit({ answers: { 'access_entry.gate': 'yes', 'lift_station.count': 1, 'lift_station.photos': [P2] }, notes: { [P2]: 'x' } })
  ok(r.status === 200, '[guard] N7 v3: a question with no claimed photo (the access photos left for later) never blocks: only claimed photos need one', r) }

// ---- remove
reset()
{ const r = await post({ op: 'remove', path: P2 })
  const pt = rmPatches()[0], q = pt ? new URLSearchParams(pt.query) : null
  ok(r.status === 200 && r.json.ok === true && r.json.removed === true, '[new] R1 remove answers {ok, removed: true}', r)
  ok(!!pt && q.get('photo_id') === 'eq.102' && q.get('entity_type') === 'eq.property_intake' && q.get('entity_id') === 'eq.900' && q.get('deleted_at') === 'is.null' && typeof pt.body.deleted_at === 'string' && pt.body.deleted_reason === 'Removed on the site survey form by the collector, before submit' && Object.keys(pt.body).sort().join() === 'deleted_at,deleted_reason', '[new] R1b the photo\'s live link on THIS form is soft-deleted (deleted_at, deleted_reason, nothing else)', pt && { q: pt.query, body: pt.body })
  const d = deletes()
  ok(r.status === 200 && r.json.removed === true && d.length === 0, '[new] R1c ... and its file is KEPT: no Storage call (soft delete only, the workspace rule)', { status: r.status, deletes: d.map((x) => ({ path: x.path, body: x.body })) })
  ok(!calls.some((c) => c.path === '/rest/v1/photos' && c.method !== 'GET') && cas() === 0, '[guard] R1d the photos row is kept and the form is not touched', calls.map((c) => c.method + ' ' + c.path)) }
reset()
{ const r = await post({ op: 'remove', path: P2 }); const r2 = await post({ op: 'remove', path: P2 })
  ok(r2.status === 200 && r2.json.ok === true && r2.json.removed === false, '[new] R2 a second remove (a retry after a lost reply) answers removed: false', { r, r2 }) }
reset()
{ const r = await post({ op: 'remove', path: '901/00000009-0000-4000-8000-000000000000.png' })
  ok(r.status === 400 && r.json.message === 'That photo does not belong to this form.' && rmPatches().length === 0 && deletes().length === 0, '[new] R3 a path from another form is refused in words and nothing is written', r) }
reset()
{ const r = await post({ op: 'remove', path: P9 })
  ok(r.status === 200 && r.json.removed === false && rmPatches().length === 0 && deletes().length === 0, '[new] R4 a path that was never attached (no photo row) answers removed: false, writes nothing', r) }
reset({ rmFail: true })
{ const r = await post({ op: 'remove', path: P2 })
  ok(r.status === 500 && r.json.message === 'Could not remove the photo, please try again.' && deletes().length === 0, '[new] R5 a failed link write answers 500 and the file is NOT deleted', { r, deletes: deletes().length }) }
reset({ intake: { id: 900, property_id: 1164, form_snapshot: FORM3, requested: REQ, expires_at: FUTURE, submitted_at: new Date().toISOString(), cancelled_at: null, calendar_task_id: null } })
{ const r = await post({ op: 'remove', path: P2 })
  ok(r.status === 409 && rmPatches().length === 0 && deletes().length === 0, '[guard] R7 a submitted form is never touched: remove answers 409', r) }
// after a remove, submit on version 3 no longer asks for the removed photo's explanation (the link is gone)
reset()
{ await post({ op: 'remove', path: P3 }); calls = []
  const r = await submit({ notes: { [P1]: ALL_NOTES[P1], [P2]: ALL_NOTES[P2] } })
  ok(r.status === 200 && JSON.stringify(casBody().answers['lift_station.photos']) === JSON.stringify({ value: [P2] }), '[new] R8 after a remove, submit sends the form without the removed photo and asks no explanation for it', { status: r.status, a: casBody() && casBody().answers['lift_station.photos'] }) }

console.log(`\n${pass} passed, ${fail} failed  (${path.basename(SRC)})`)
process.exit(fail ? 1 : 0)
