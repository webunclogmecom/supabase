// save-calendar-task, the 2026-09-29 additions (`app`, `intake_id`, the preflight echo), run for real under Bun with
// EVERY network call stubbed: GoTrue, PostgREST and Jobber GraphQL are answered by the router below, so nothing is
// read from or written to Prod or Jobber. The handler is the file itself (its supabase-js import is pointed at the
// repo's node_modules copy), so this tests the committed source, not a retyped copy.
//   bun scripts/probes/save_calendar_task_intake_stub.mjs [path to index.ts]     (default: the repo file)
// CONTROL: run it on the pre-change file (git show <commit>^:supabase/functions/save-calendar-task/index.ts > old.ts);
// every check marked [new] must FAIL there and every [regression] check must PASS. Exit 1 on any FAIL.
import fs from 'node:fs'
import path from 'node:path'
import os from 'node:os'
const REPO = 'C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase'
const SRC = process.argv[2] || `${REPO}/supabase/functions/save-calendar-task/index.ts`
const SBJS = `${REPO}/node_modules/@supabase/supabase-js/dist/index.mjs`
let src = fs.readFileSync(SRC, 'utf8')
const IMP = 'import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";'
if (src.split(IMP).length !== 2) throw new Error('the supabase-js import line moved; update IMP')
src = src.replace(IMP, `import { createClient } from ${JSON.stringify(SBJS)};`)
const COPY = path.join(os.tmpdir(), `sct_stub_${process.pid}.ts`)
fs.writeFileSync(COPY, src)

const SB = 'https://stub.supabase.co'
let handler = null
globalThis.Deno = { env: { get: (k) => ({ SUPABASE_URL: SB, SUPABASE_SERVICE_ROLE_KEY: 'stub-service-key' })[k] }, serve: (h) => { handler = h } }

// ---- the world the router answers from; reset per case -------------------------------------------------------
const TODAY = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/New_York' }).format(new Date())
const FUTURE = new Date(Date.now() + 30 * 864e5).toISOString()
let W, calls
function reset(over = {}) {
  calls = []
  W = {
    links: { client: { 381: 'GID-CLIENT-381' }, property: { 162: 'GID-PROP-162' }, employee: { 1: 'GID-USER-1' } },
    props: { 162: { id: 162, client_id: 381 } },
    intakes: { 900: { id: 900, property_id: 162, submitted_at: null, cancelled_at: null, expires_at: FUTURE, calendar_task_id: null } },
    rpc: { status: 200, body: 555 },
    patch: { status: 200, body: [{ id: 900 }] },
    readBack: null,            // null = echo what taskCreate was sent (a verified create)
    createReply: null,         // null = taskCreate succeeds; else a function returning the Response Jobber gives
    created: null, deleted: false,
    ...over,
  }
}
const J = (b, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { 'content-type': 'application/json' } })
const param = (u, k) => u.searchParams.get(k)
globalThis.fetch = async (url, init = {}) => {
  const u = new URL(String(url)), method = (init.method || 'GET').toUpperCase()
  const headers = Object.fromEntries(new Headers(init.headers || {}).entries())
  const body = init.body ? JSON.parse(String(init.body)) : null
  calls.push({ method, host: u.host, path: u.pathname, query: u.search, headers, body })
  if (u.host === 'api.getjobber.com') {
    const q = String(body?.query || '')
    if (q.includes('taskCreate')) { W.created = body.variables; if (W.createReply) return W.createReply(); return J({ data: { taskCreate: { task: { id: 'GID-TASK-NEW' }, userErrors: [] } } }) }
    if (q.includes('taskDelete')) { W.deleted = true; return J({ data: { taskDelete: { userErrors: [] } } }) }
    if (q.includes('task(id')) {
      if (W.deleted) return J({ data: { task: null } })
      if (W.readBack) return J({ data: { task: W.readBack } })
      const inp = W.created?.in || {}
      return J({ data: { task: { id: 'GID-TASK-NEW', title: inp.title, instructions: inp.instructions, allDay: inp.allDay, startAt: inp.startAt, endAt: inp.endAt,
        isComplete: false, client: W.created?.clientId ? { id: W.created.clientId } : null, property: W.created?.propertyId ? { id: W.created.propertyId } : null,
        assignedUsers: { nodes: (inp.assignedTo || []).map((id) => ({ id })) } } } })
    }
    return J({ errors: [{ message: 'unrouted GraphQL' }] }, 200)
  }
  if (u.pathname === '/auth/v1/user') return J({ id: 'u-fred', aud: 'authenticated', email: 'fred@ayache.com' })
  const one = /vnd\.pgrst\.object/.test(headers['accept'] || '')
  const rows = (arr) => (one ? (arr.length === 1 ? J(arr[0]) : J({ message: 'not one row' }, 406)) : J(arr))
  const table = u.pathname.replace('/rest/v1/', '')
  if (table === 'webhook_tokens') return rows([{ access_token: 'stub-jobber-token', refresh_token: 'r', client_id: 'c', client_secret: 's', expires_at: FUTURE }])
  if (table === 'entity_source_links') {
    const type = (param(u, 'entity_type') || '').replace('eq.', ''), ids = (param(u, 'entity_id') || '').replace(/^in\.\(|\)$/g, '').split(',').map(Number)
    return rows(ids.filter((id) => W.links[type]?.[id]).map((id) => ({ entity_id: id, source_id: W.links[type][id] })))
  }
  if (table === 'clients') { const id = Number((param(u, 'id') || '').replace('eq.', '')); return rows(W.links.client[id] ? [{ id }] : []) }
  if (table === 'properties') { const id = Number((param(u, 'id') || '').replace('eq.', '')); return rows(W.props[id] ? [W.props[id]] : []) }
  if (table === 'property_intakes' && method === 'GET') { const id = Number((param(u, 'id') || '').replace('eq.', '')); return rows(W.intakes[id] ? [W.intakes[id]] : []) }
  if (table === 'property_intakes' && method === 'PATCH') return J(W.patch.body, W.patch.status)
  if (table === 'rpc/fn_record_calendar_task') return J(W.rpc.body, W.rpc.status)
  return J({ message: 'unrouted ' + method + ' ' + u.pathname }, 500)
}
await import(COPY)
fs.unlinkSync(COPY)
if (typeof handler !== 'function') throw new Error('the handler did not register')

const call = async (b, method = 'POST', extra = {}) => {
  const res = await handler(new Request('https://stub/functions/v1/save-calendar-task', {
    method, headers: { authorization: 'Bearer stub-user-token', 'content-type': 'application/json', ...extra }, body: method === 'POST' ? JSON.stringify(b) : undefined }))
  const text = await res.text()
  let json = null; try { json = JSON.parse(text) } catch {}
  return { status: res.status, json, headers: Object.fromEntries(res.headers.entries()) }
}
const jobber = () => calls.filter((c) => c.host === 'api.getjobber.com')
const intakeReads = () => calls.filter((c) => c.path === '/rest/v1/property_intakes' && c.method === 'GET')
const patches = () => calls.filter((c) => c.path === '/rest/v1/property_intakes' && c.method === 'PATCH')
const rpcs = () => calls.filter((c) => c.path === '/rest/v1/rpc/fn_record_calendar_task')
let pass = 0, fail = 0
const ok = (cond, name, got) => { cond ? pass++ : fail++; console.log(`${cond ? 'PASS' : 'FAIL'} ${name}${cond ? '' : ' :: ' + String(JSON.stringify(got) ?? got).slice(0, 300)}`) }
const CREATE = { op: 'create', app: 'client-app', intake_id: 900, title: 'Intake form: 1745 Cleveland Road', instructions: 'Open this link on site to fill in the site survey form:\nhttps://planner.unclogme.app/intake#code=STUBCODE',
  client_id: 381, property_id: 162, assignee_ids: [1], task_date: TODAY, all_day: true }

// 1. preflight echoes whatever headers the browser asks for
reset()
{ const asked = 'authorization, x-client-info, apikey, content-type, x-supabase-api-version, x-region, x-new-sdk-header'
  const r = await call(null, 'OPTIONS', { 'access-control-request-headers': asked })
  ok(r.status === 200 && r.headers['access-control-allow-headers'] === asked, '[new] OPTIONS echoes the requested headers', r.headers['access-control-allow-headers']) }

// 2. app is allowlisted and checked before anything is read
reset()
{ const r = await call({ ...CREATE, app: 'bogus' })
  ok(r.status === 400 && r.json?.code === 'bad_request' && /app must be one of/.test(r.json?.message || ''), '[new] an unknown app is refused 400 bad_request', r)
  ok(jobber().length === 0 && intakeReads().length === 0, '[new] ... before any read or Jobber call', calls.map((c) => c.path)) }

// 3. intake_id only on create, only a positive whole number
reset()
{ const r = await call({ op: 'edit', task_id: 5, intake_id: 900, title: 'x' })
  ok(r.status === 400 && r.json?.code === 'invalid_input' && /only be sent when a task is created/.test(r.json?.message || ''), '[new] intake_id on an edit is refused', r) }
reset()
{ const r = await call({ ...CREATE, intake_id: 'abc' })
  ok(r.status === 400 && r.json?.code === 'invalid_input' && /positive whole number/.test(r.json?.message || ''), '[new] a non-numeric intake_id is refused', r) }

// 4. the form must exist, be this property's, be open and unlinked; every refusal is before Jobber, no jobber_task
const refusals = [
  ['no property', { property_id: null, client_id: 381 }, {}, 400, 'invalid_input'],
  ['not found', { intake_id: 901 }, {}, 400, 'intake_not_found'],
  ['another property', {}, { intakes: { 900: { id: 900, property_id: 1164, submitted_at: null, cancelled_at: null, expires_at: FUTURE, calendar_task_id: null } } }, 400, 'intake_not_of_property'],
  ['cancelled', {}, { intakes: { 900: { id: 900, property_id: 162, submitted_at: null, cancelled_at: FUTURE, expires_at: FUTURE, calendar_task_id: null } } }, 409, 'intake_closed'],
  ['submitted', {}, { intakes: { 900: { id: 900, property_id: 162, submitted_at: FUTURE, cancelled_at: null, expires_at: FUTURE, calendar_task_id: null } } }, 409, 'intake_closed'],
  ['expired', {}, { intakes: { 900: { id: 900, property_id: 162, submitted_at: null, cancelled_at: null, expires_at: '2020-01-01T00:00:00Z', calendar_task_id: null } } }, 409, 'intake_closed'],
  ['already linked', {}, { intakes: { 900: { id: 900, property_id: 162, submitted_at: null, cancelled_at: null, expires_at: FUTURE, calendar_task_id: 44 } } }, 409, 'intake_already_linked'],
]
for (const [name, bodyOver, worldOver, status, code] of refusals) {
  reset(worldOver)
  const r = await call({ ...CREATE, ...bodyOver })
  ok(r.status === status && r.json?.code === code && r.json?.ok === false && !r.json?.jobber_task && jobber().length === 0 && rpcs().length === 0,
    `[new] form ${name}: ${status} ${code}, no Jobber call, no jobber_task`, { status: r.status, json: r.json, jobber: jobber().length })
}

// 5. a verified create with a form: Jobber, then the RPC, then the guarded link, all labelled client-app
reset()
{ const r = await call(CREATE)
  const rpc = rpcs()[0], p = patches()[0]
  ok(r.status === 200 && r.json?.ok === true && r.json?.task_id === 555 && r.json?.intake_id === 900 && r.json?.intake_linked === true, '[new] create with a form: ok, task 555, intake_linked true', r.json)
  ok(!!rpc && rpc.headers['x-app-source'] === 'client-app' && rpc.headers['x-actor-name'] === 'fred@ayache.com', '[new] the RPC is labelled client-app with the actor', rpc?.headers)
  ok(!!p && /(^|&|\?)id=eq\.900(&|$)/.test(p.query) && /calendar_task_id=is\.null/.test(p.query) && JSON.stringify(p.body) === '{"calendar_task_id":555}' && p.headers['x-app-source'] === 'client-app',
    '[new] the form is linked once, guarded on calendar_task_id is null, labelled client-app', p && { q: p.query, b: p.body, h: p.headers['x-app-source'] })
  const order = calls.map((c) => c.host === 'api.getjobber.com' ? 'jobber' : c.path).filter((x) => ['jobber', '/rest/v1/rpc/fn_record_calendar_task', '/rest/v1/property_intakes'].includes(x))
  ok(JSON.stringify(order) === JSON.stringify(['/rest/v1/property_intakes', 'jobber', 'jobber', '/rest/v1/rpc/fn_record_calendar_task', '/rest/v1/property_intakes']),
    '[new] order: read the form, Jobber create, Jobber read-back, the RPC, link the form', order)
  ok(W.created?.in?.instructions === CREATE.instructions && W.created?.in?.allDay === true && JSON.stringify(W.created?.in?.assignedTo) === '["GID-USER-1"]'
    && W.created?.clientId === 'GID-CLIENT-381' && W.created?.propertyId === 'GID-PROP-162', '[regression] Jobber gets the notes (with the link), all-day, the assignee, client and property', W.created) }

// 6. the task is real but the link fails or finds the form taken: still ok, intake_linked false, nothing undone
for (const [name, patch] of [['0 rows', { status: 200, body: [] }], ['an error', { status: 500, body: { message: 'boom' } }]]) {
  reset({ patch })
  const r = await call(CREATE)
  ok(r.status === 200 && r.json?.ok === true && r.json?.intake_linked === false && !calls.some((c) => /taskDelete/.test(String(c.body?.query || ''))),
    `[new] link finds ${name}: ok, intake_linked false, the task is not deleted`, r.json)
}

// 7. a read-back mismatch rolls the Jobber task back and never links the form (the app then cancels the link)
reset({ readBack: { id: 'GID-TASK-NEW', title: 'something else', instructions: '', allDay: true, startAt: null, endAt: null, isComplete: false, client: null, property: null, assignedUsers: { nodes: [] } } })
{ const r = await call(CREATE)
  ok(r.status === 502 && r.json?.code === 'jobber_unverified' && r.json?.rolled_back === true && patches().length === 0 && rpcs().length === 0,
    '[regression] a mismatched read-back: 502, rolled_back true, no RPC, the form is not linked', r.json) }

// 7b. Jobber's reply to taskCreate is not a clear yes or no: UNKNOWN (maybe_created), never "nothing was saved"; only
// userErrors with no top-level error and no task is a definite refusal (the Client App cancels the link only then)
for (const [name, reply] of [
  ['a top-level error (a 5xx JSON body)', () => J({ errors: [{ message: 'Internal server error' }] }, 500)],
  ['no task id and no error (a body read that failed partway)', () => new Response('{"data":', { status: 200, headers: { 'content-type': 'application/json' } })],
]) {
  reset({ createReply: reply })
  const r = await call(CREATE)
  ok(r.status === 502 && r.json?.code === 'jobber_unknown' && r.json?.maybe_created === true && !r.json?.jobber_task && rpcs().length === 0 && patches().length === 0,
    `[new] taskCreate answers ${name}: 502 jobber_unknown, maybe_created, no RPC, no link`, r.json)
}
reset({ createReply: () => J({ data: { taskCreate: { task: null, userErrors: [{ message: 'Title is too long' }] } } }) })
{ const r = await call(CREATE)
  ok(r.status === 502 && r.json?.code === 'jobber_rejected' && !r.json?.jobber_task && !r.json?.maybe_created && rpcs().length === 0 && patches().length === 0,
    '[regression] userErrors only: 502 jobber_rejected (a definite refusal), no jobber_task, no RPC, no link', r.json) }

// 8. the Calendar's own create (no app, no intake_id) is unchanged: labelled visit-calendar, no form read or link
reset()
{ const { app, intake_id, ...plain } = CREATE
  const r = await call(plain)
  ok(r.status === 200 && r.json?.ok === true && !('intake_id' in (r.json || {})) && !('intake_linked' in (r.json || {})), '[regression] a Calendar create answers as before', r.json)
  ok(intakeReads().length === 0 && patches().length === 0 && rpcs()[0]?.headers['x-app-source'] === 'visit-calendar', '[regression] ... labelled visit-calendar, no form read or link',
    { reads: intakeReads().length, patches: patches().length, h: rpcs()[0]?.headers['x-app-source'] }) }

console.log(`\n${pass} passed, ${fail} failed  (${path.basename(SRC)})`)
process.exit(fail ? 1 : 0)
