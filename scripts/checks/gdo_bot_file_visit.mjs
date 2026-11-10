// Standing check: gdo-bot-file-visit sends a permit to the GDO bot only when it may, and says why when it may not.
//
//   node scripts/checks/gdo_bot_file_visit.mjs
//
// Runs the function offline (esbuild strips the three imports; stubs replace createClient, the staff and access
// checks, Deno.env/serve and fetch, which plays the bot). Scenarios: off, filed, no permit, no ticket, in the bot's
// hands, an older lease, no access, happy path, dry run, the bot refusing, no answer, a missing dry_run; since
// 2026-10-29 also the request = the queue's own item (the REAL _shared/rpa-queue-item.ts) + requested_by, the press
// log (gdo_bot_file_requests) and every way it cannot be written. A copy with the send guard removed must FAIL: a
// check that cannot fail proves nothing. Exit 0 = all hold.
// Why: Trello xBCSvP6f, spec Building Apps/DERM Tracker/docs/specs/2026-10-27-file-with-the-bot-button.md.
// Needs node + npx esbuild@0.24.0.
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { execFileSync } from 'node:child_process'
import { pathToFileURL, fileURLToPath } from 'node:url'

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..')
const FN = 'supabase/functions/gdo-bot-file-visit/index.ts'
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'gdo-bot-file-'))

fs.writeFileSync(path.join(TMP, 'stub.mjs'), [
  'export function createClient(_u, key) { return key === "anon" ? globalThis.__user : globalThis.__sb }',
  'export const isStaffEmail = async () => true',
  'export const checkAppAction = async () => globalThis.__denied ?? null',
].join('\n'))

const IMPORTS = [
  "import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'",
  "import { isStaffEmail } from '../_shared/staff.ts'",
  "import { checkAppAction } from '../_shared/access-check.ts'",
]
// The REAL queue-item helper (2026-10-29): compiled next to the function, so the request shape is the queue's own.
const SHARED = "import { toQueueItem } from '../_shared/rpa-queue-item.ts'"
const esbuild = (ts, out) => execFileSync(process.platform === 'win32' ? 'npx.cmd' : 'npx', ['--no-install', 'esbuild@0.24.0', ts, '--format=esm', `--outfile=${out}`, '--log-level=error'], { shell: process.platform === 'win32' })
esbuild(path.join(REPO, 'supabase/functions/_shared/rpa-queue-item.ts'), path.join(TMP, 'rpa-queue-item.mjs'))
function build(name, src) {
  for (const line of IMPORTS) {
    if (!src.includes(line)) throw new Error(`${name}: an import line changed, update this check`)
    src = src.replace(line, line.replace(/from '.*'/, "from './stub.mjs'"))
  }
  if (!src.includes(SHARED)) throw new Error(`${name}: the queue-item import changed, update this check`)
  src = src.replace(SHARED, "import { toQueueItem } from './rpa-queue-item.mjs'")
  const ts = path.join(TMP, `${name}.ts`), out = path.join(TMP, `${name}.mjs`)
  fs.writeFileSync(ts, src)
  esbuild(ts, out)
  return out
}
async function load(file, env, tag) {
  let handler
  globalThis.Deno = { env: { get: (k) => env[k] }, serve: (h) => { handler = h } }
  await import(pathToFileURL(file).href + `?${tag}`)
  return handler
}

const BASE = { SUPABASE_URL: 'http://x', SUPABASE_SERVICE_ROLE_KEY: 'service', SUPABASE_ANON_KEY: 'anon' }
const ON = { ...BASE, GDO_BOT_FILE_URL: 'https://bot.example/file', GDO_BOT_FILE_KEY: 'k-derm' }
// Trello #184: the live address shape, so progress can derive /gdo/status/<run> from it.
const ONP = { ...BASE, GDO_BOT_FILE_URL: 'https://bot.example/gdo/process-one', GDO_BOT_FILE_KEY: 'k-derm' }
const ROW = { visit_id: 6215, manifest_id: 1700, gdo_id: 51, gdo_number: 'GDO-09853', ticket_number: '830088',
  visit_date: '2026-07-09', dump_ticket_date: '2026-07-14', client_name: 'The fresh Carrot of Surfside',
  client_code: '082-TFC', jurisdiction: 'dade', can_record_manual: true, blocked_reason: null }
// A public.v_derm_portal_fields row (what the queue and the button both send from).
const FIELDS = { visit_id: 6215, manifest_id: 1700, gdo_id: 51, client_code: '082-TFC', client_name: 'The fresh Carrot of Surfside',
  client_email: 'owner@example.com', address: '9540 Harding Ave', city: 'Surfside', zip: '33154', county: 'Dade',
  gdo_number: 'GDO-09853', visit_date: '2026-07-09', dump_ticket_date: '2026-07-14', ticket_number: '830088',
  jurisdiction: 'dade', white_manifest_number: '830088', disposal_facility: 'South District WWTP' }
const hoursAgo = (h) => new Date(Date.now() - h * 3600e3).toISOString()

function makeSb({ rows = [ROW], leases = [], attempts = [], fields = [FIELDS], logError = null, presses = [] }) {
  const writes = []
  const table = (name) => {
    const out = name === 'visit_gdo_our_record' ? rows : name === 'derm_portal_leases' ? leases
      : name === 'v_derm_portal_fields' ? fields : name === 'gdo_bot_file_requests' ? presses : attempts
    const b = { select: () => b, eq: () => b, not: () => b, limit: () => b, then: (res, rej) => Promise.resolve({ data: out, error: null }).then(res, rej),
      upsert: async (v, o) => { writes.push({ table: name, v, o }); return { error: null } },
      insert: async (v) => { if (logError) return { error: { message: logError } }; writes.push({ table: name, v }); return { error: null } } }
    return b
  }
  return { sb: { from: table, schema: () => ({ from: table }) }, writes }
}
const leaseW = (r) => r.writes.filter((w) => w.table === 'derm_portal_leases')
const logW = (r) => r.writes.filter((w) => w.table === 'gdo_bot_file_requests')

async function call(handler, body, db = {}, bot = { status: 202, body: { accepted: true, run_id: 'run-7f3a', state: 'running' } }) {
  const { sb, writes } = makeSb(db)
  globalThis.__sb = sb
  globalThis.__user = { auth: { getUser: async () => ({ data: { user: { email: 'fred@ayache.com' } }, error: null }) } }
  const fetches = []
  globalThis.fetch = async (url, init) => {
    fetches.push({ url, init })
    if (bot === 'timeout') throw new Error('The operation was aborted due to timeout')
    if (String(url).includes('/gdo/status/')) {
      if (db.botStatus === 'down') throw new Error('The operation was aborted due to timeout')
      return { ok: true, status: 200, headers: { get: () => 'application/json' }, json: async () => db.botStatus }
    }
    return { ok: bot.status < 300, status: bot.status, text: async () => JSON.stringify(bot.body) }
  }
  const res = await handler(new Request('http://x/', { method: 'POST',
    headers: { Authorization: 'Bearer t', 'content-type': 'application/json', origin: 'https://derm.unclogme.app' }, body: JSON.stringify(body) }))
  return { status: res.status, out: await res.json(), fetches, writes }
}

const status = { action: 'status', visit_id: 6215 }
const send = (o = {}) => ({ action: 'send', visit_id: 6215, gdo_id: 51, dry_run: false, ...o })
const P = (r) => r.out.permits?.[0] ?? {}

const SCENARIOS = [
  { id: 'off-status', env: 'off', body: status, ok: (r) => r.status === 200 && r.out.enabled === false && P(r).can_send === false && /Coming soon/.test(P(r).reason) },
  { id: 'off-send', env: 'off', body: send(), ok: (r) => r.status === 503 && r.fetches.length === 0 && r.writes.length === 0 },
  { id: 'status-ready', body: status, ok: (r) => r.out.enabled === true && P(r).can_send === true && P(r).reason === null },
  { id: 'filed', guard: true, body: send(), db: { rows: [{ ...ROW, can_record_manual: false, blocked_reason: 'This permit already has a report on record.' }] },
    ok: (r) => r.status === 409 && /already has a report/.test(r.out.message) && r.fetches.length === 0 },
  { id: 'no-permit', body: status, db: { rows: [{ ...ROW, gdo_id: null, gdo_number: null }] }, ok: (r) => P(r).can_send === false && /No GDO permit/.test(P(r).reason) },
  { id: 'no-ticket', guard: true, body: send(), db: { rows: [{ ...ROW, ticket_number: null }] }, ok: (r) => r.status === 409 && /dump ticket/.test(r.out.message) && r.fetches.length === 0 },
  { id: 'in-flight', guard: true, body: send(), db: { leases: [{ gdo_id: 51, leased_at: hoursAgo(1) }] },
    ok: (r) => r.status === 409 && /The bot has this permit since/.test(r.out.message) && r.out.sent_at && r.fetches.length === 0 },
  { id: 'legacy-null-lease', guard: true, body: send(), db: { leases: [{ gdo_id: null, leased_at: hoursAgo(2) }] }, ok: (r) => r.status === 409 && r.fetches.length === 0 },
  { id: 'lease-answered', body: status, db: { leases: [{ gdo_id: 51, leased_at: hoursAgo(3) }], attempts: [{ gdo_id: 51, created_at: hoursAgo(2.9) }] },
    ok: (r) => P(r).can_send === true && P(r).sent_at === null },
  { id: 'lease-expired', body: status, db: { leases: [{ gdo_id: 51, leased_at: hoursAgo(21) }] }, ok: (r) => P(r).can_send === true },
  { id: 'other-permit-lease', body: status, db: { leases: [{ gdo_id: 99, leased_at: hoursAgo(1) }] }, ok: (r) => P(r).can_send === true },
  { id: 'no-access-status', denied: { status: 403, message: 'You do not have access to do this.' }, body: status, ok: (r) => P(r).can_send === false && /access/.test(P(r).reason) },
  { id: 'no-access-send', denied: { status: 403, message: 'You do not have access to do this.' }, body: send(), ok: (r) => r.status === 403 && r.fetches.length === 0 },
  { id: 'happy', body: send(), ok: (r) => {
      const f = r.fetches[0], b = f && JSON.parse(f.init.body), l = logW(r)[0]?.v
      return r.status === 202 && r.out.sent === true && r.out.logged === true && r.out.run_id === 'run-7f3a'
        && r.fetches.length === 1 && f.url === 'https://bot.example/file'
        && f.init.headers['x-run-key'] === 'k-derm' && b.gdo_number === 'GDO-09853' && b.ticket_number === '830088'
        && b.service_date === '2026-07-09' && b.visit_id === 6215 && b.gdo_id === 51 && b.dry_run === false
        && b.requested_by === 'fred@ayache.com' && b.client_email === 'owner@example.com' && b.white_manifest_number === '830088'
        && JSON.stringify(Object.keys(b)) === JSON.stringify([...Object.keys(QUEUE_ITEM(FIELDS, false)), 'requested_by'])
        && leaseW(r).length === 1 && leaseW(r)[0].v.visit_id === 6215 && leaseW(r)[0].v.gdo_id === 51
        && leaseW(r)[0].o.onConflict === 'visit_id,gdo_id'
        && logW(r).length === 1 && l.visit_id === 6215 && l.gdo_id === 51 && l.run_id === 'run-7f3a'
        && l.dry_run === false && l.requested_by === 'fred@ayache.com' } },
  { id: 'dry-run', body: send({ dry_run: true }), ok: (r) => r.status === 202 && r.out.dry_run === true && JSON.parse(r.fetches[0].init.body).dry_run === true
      && leaseW(r).length === 0 && logW(r).length === 1 && logW(r)[0].v.dry_run === true },
  { id: 'already-filing', body: send(), bot: { status: 200, body: { accepted: false, run_id: 'run-old', state: 'running', reason: 'That visit is being filed right now.' } },
    ok: (r) => r.status === 200 && r.out.sent === false && /already filing/.test(r.out.message) && logW(r).length === 0 },
  { id: 'no-run-id', body: send(), bot: { status: 202, body: { accepted: true } },
    ok: (r) => r.status === 202 && r.out.logged === false && /tell Fred/.test(r.out.message) && logW(r).length === 0 },
  { id: 'bad-run-id', body: send(), bot: { status: 202, body: { accepted: true, run_id: '../etc' } },
    ok: (r) => r.status === 202 && r.out.logged === false && logW(r).length === 0 },
  { id: 'log-fails', body: send(), db: { logError: 'boom' }, ok: (r) => r.status === 202 && r.out.logged === false && /tell Fred/.test(r.out.message) },
  { id: 'fields-gone', body: send(), db: { fields: [] }, ok: (r) => r.status === 404 && r.fetches.length === 0 && r.writes.length === 0 },
  { id: 'bot-refuses', body: send(), bot: { status: 409, body: { detail: 'A run is already in progress' } },
    ok: (r) => r.status === 502 && /A run is already in progress/.test(r.out.message) && r.writes.length === 0 },
  { id: 'bot-no-answer', body: send(), bot: 'timeout', ok: (r) => r.status === 502 && r.out.error === 'bot_no_answer' && leaseW(r).length === 1 && logW(r).length === 0 },
  { id: 'dry-run-missing', body: send({ dry_run: undefined }), ok: (r) => r.status === 400 && r.fetches.length === 0 },
  // ---- Trello #184: the press in flight, the plain error, the live steps -------------------------------
  { id: 'status-run', body: status, db: { leases: [{ gdo_id: 51, leased_at: hoursAgo(0.05) }],
      presses: [{ run_id: 'run-new', gdo_id: 51, requested_at: hoursAgo(0.04) }, { run_id: 'run-other', gdo_id: 99, requested_at: hoursAgo(0.04) },
                { run_id: 'run-yesterday', gdo_id: 51, requested_at: hoursAgo(26) }] },
    ok: (r) => P(r).run?.run_id === 'run-new' && P(r).can_send === false },
  { id: 'status-no-run-hourly-lease', body: status, db: { leases: [{ gdo_id: 51, leased_at: hoursAgo(1) }] }, ok: (r) => P(r).run === null && !!P(r).sent_at },
  { id: 'last-error-plain', body: status, db: { attempts: [{ gdo_id: 51, created_at: hoursAgo(1), status: 'ERROR_LOGIN_FAILED',
      failure_reason: 'The county turned down both passwords we have for permit 9853. What to do: Reset it. Then press Auto file. Details: Login failed' }] },
    ok: (r) => P(r).last_error?.title === 'The county turned down both passwords we have for permit 9853'
      && P(r).last_error?.what_to_do === 'Reset it. Then press Auto file.' && P(r).can_send === true },
  { id: 'last-error-old-text', body: status, db: { attempts: [{ gdo_id: 51, created_at: hoursAgo(1), status: 'ERROR_LOGIN_FAILED',
      failure_reason: 'Login failed for permit 9853 - portal reported: no' }] },
    ok: (r) => /^Login failed for permit 9853/.test(P(r).last_error?.title ?? '') && P(r).last_error?.what_to_do === null },
  { id: 'last-error-cleared', body: status, db: { attempts: [
      { gdo_id: 51, created_at: hoursAgo(2), status: 'ERROR_LOGIN_FAILED', failure_reason: 'x' },
      { gdo_id: 51, created_at: hoursAgo(1), status: 'SUCCESS', failure_reason: null, portal_confirmation: 'Submitted' }] },
    ok: (r) => P(r).last_error === null },
  { id: 'progress-bad-run', env: 'onp', body: { action: 'progress', visit_id: 6215, run_id: '../x' }, ok: (r) => r.status === 400 },
  { id: 'progress-not-a-press', env: 'onp', body: { action: 'progress', visit_id: 6215, run_id: 'run-1' }, ok: (r) => r.status === 404 && r.fetches.length === 0 },
  { id: 'progress-running', env: 'onp', body: { action: 'progress', visit_id: 6215, run_id: 'run-1' },
    db: { presses: [{ run_id: 'run-1' }], botStatus: { state: 'running', steps: [{ key: 'email' }, { key: 'signin', note: '2nd password' }] } },
    ok: (r) => { const s = r.out.steps ?? [], cur = s.find((x) => x.current)
      return r.status === 200 && r.out.state === 'running' && s.length === 7 && s[0].done && s[1].done && s[2].done
        && s[2].label === 'Signed in (2nd password)' && cur?.key === 'filling' && r.fetches[0]?.url === 'https://bot.example/gdo/status/run-1'
        && r.fetches[0]?.init.headers['x-run-key'] === 'k-derm' } },
  { id: 'progress-bot-done-not-ours', ours: true, env: 'onp', body: { action: 'progress', visit_id: 6215, run_id: 'run-1' },
    db: { presses: [{ run_id: 'run-1' }], botStatus: { state: 'done', steps: ['email', 'signin', 'filling', 'submitting', 'submitted', 'email_wait', 'saving'].map((key) => ({ key })) } },
    ok: (r) => r.out.state === 'running' && r.out.result === null && r.out.steps.find((x) => x.current)?.key === 'saving'
      && r.out.steps.find((x) => x.key === 'saving').done === false },
  { id: 'progress-filed', env: 'onp', body: { action: 'progress', visit_id: 6215, run_id: 'run-1' },
    db: { presses: [{ run_id: 'run-1' }], attempts: [{ status: 'SUCCESS', failure_reason: null, portal_confirmation: 'Submitted - DERM email confirmed' }],
      botStatus: { state: 'running', steps: [{ key: 'email' }] } },
    ok: (r) => r.out.state === 'filed' && r.out.result?.filed === true && r.out.steps.every((x) => x.done && !x.current) },
  { id: 'progress-failed', env: 'onp', body: { action: 'progress', visit_id: 6215, run_id: 'run-1' },
    db: { presses: [{ run_id: 'run-1' }], attempts: [{ status: 'ERROR_LOGIN_FAILED', portal_confirmation: null,
      failure_reason: 'The county turned down both passwords we have for permit 9853. What to do: Reset it. Details: d' }],
      botStatus: { state: 'done', steps: [{ key: 'email' }] } },
    ok: (r) => r.out.state === 'failed' && r.out.steps.find((x) => x.failed)?.key === 'signin'
      && r.out.result?.title === 'The county turned down both passwords we have for permit 9853' && r.out.result?.what_to_do === 'Reset it.' },
  { id: 'progress-old-bot', env: 'onp', body: { action: 'progress', visit_id: 6215, run_id: 'run-1' },
    db: { presses: [{ run_id: 'run-1' }], botStatus: { state: 'running' } },
    ok: (r) => r.out.state === 'running' && r.out.steps.map((x) => x.key).join() === 'sent,working,saving' && r.out.steps[1].current },
  { id: 'progress-bot-down', env: 'onp', body: { action: 'progress', visit_id: 6215, run_id: 'run-1' },
    db: { presses: [{ run_id: 'run-1' }], botStatus: 'down' },
    ok: (r) => r.status === 200 && r.out.bot_answered === false && r.out.steps.length === 3 },
]

const { toQueueItem: QUEUE_ITEM } = await import(pathToFileURL(path.join(TMP, 'rpa-queue-item.mjs')).href)
const quiet = console.error
const src = fs.readFileSync(path.join(REPO, FN), 'utf8')
const guard = "if (!st.can_send) return json({ error: 'not_sendable', message: st.reason, sent_at: st.sent_at }, 409, cors)"
if (!src.includes(guard)) throw new Error('the send guard line changed, update this check')
const work = build('work', src)
const mutant = build('mutant', src.replace(guard, '// guard removed'))
// Trello #184: "finished" only on OUR row. A copy that also trusts the bot's "done" must FAIL the ours-only case.
const finishedLine = 'const finished = ours !== null'
if (!src.includes(finishedLine)) throw new Error('the finished line changed, update this check')
const oursMutant = build('ours', src.replace(finishedLine, "const finished = ours !== null || bot?.state === 'done'"))
const handlers = {
  work: { on: await load(work, ON, 'w-on'), off: await load(work, BASE, 'w-off'), onp: await load(work, ONP, 'w-onp') },
  mutant: { on: await load(mutant, ON, 'm-on'), off: await load(mutant, BASE, 'm-off'), onp: await load(mutant, ONP, 'm-onp') },
  ours: { on: await load(oursMutant, ON, 'o-on'), off: await load(oursMutant, BASE, 'o-off'), onp: await load(oursMutant, ONP, 'o-onp') },
}

let ok = true
const check = (label, cond, extra = '') => { console.log(`${cond ? 'PASS' : 'FAIL'}  ${label}${extra ? '  ' + extra : ''}`); if (!cond) ok = false }
const run = async (h, s) => { globalThis.__denied = s.denied ?? null; console.error = () => {}; try { return await call(h[s.env ?? 'on'], s.body, s.db, s.bot) } finally { console.error = quiet } }

for (const s of SCENARIOS) {
  const r = await run(handlers.work, s)
  check(`${s.id}: working tree`, s.ok(r), `HTTP ${r.status} ${JSON.stringify(r.out).slice(0, 160)}`)
}
for (const s of SCENARIOS.filter((x) => x.guard)) {
  const r = await run(handlers.mutant, s)
  check(`${s.id}: guard removed must FAIL it`, !s.ok(r), `HTTP ${r.status} fetches=${r.fetches.length}`)
}
for (const s of SCENARIOS.filter((x) => x.ours)) {
  // A crash counts as caught: the copy did not pass the case.
  let r = null
  try { r = await run(handlers.ours, s) } catch { r = null }
  check(`${s.id}: trusting the bot's "done" must FAIL it`, r === null || !s.ok(r), r ? `state=${r.out.state}` : 'crashed')
}

fs.rmSync(TMP, { recursive: true, force: true })
console.log(ok ? '\nRESULT: OK' : '\nRESULT: FAILED')
process.exit(ok ? 0 : 1)
