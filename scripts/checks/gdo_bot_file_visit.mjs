// Standing check: gdo-bot-file-visit sends a permit to the GDO bot only when it may, and says why when it may not.
//
//   node scripts/checks/gdo_bot_file_visit.mjs
//
// Runs the function offline (esbuild strips the three imports; stubs replace createClient, the staff and access
// checks, Deno.env/serve and fetch, which plays the bot). Scenarios: off, filed, no permit, no ticket, in the bot's
// hands, an older lease, no access, happy path, dry run, the bot refusing, no answer, a missing dry_run. A copy with
// the send guard removed must FAIL: a check that cannot fail proves nothing. Exit 0 = all hold.
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
function build(name, src) {
  for (const line of IMPORTS) {
    if (!src.includes(line)) throw new Error(`${name}: an import line changed, update this check`)
    src = src.replace(line, line.replace(/from '.*'/, "from './stub.mjs'"))
  }
  const ts = path.join(TMP, `${name}.ts`), out = path.join(TMP, `${name}.mjs`)
  fs.writeFileSync(ts, src)
  execFileSync(process.platform === 'win32' ? 'npx.cmd' : 'npx', ['--no-install', 'esbuild@0.24.0', ts, '--format=esm', `--outfile=${out}`, '--log-level=error'], { shell: process.platform === 'win32' })
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
const ROW = { visit_id: 6215, manifest_id: 1700, gdo_id: 51, gdo_number: 'GDO-09853', ticket_number: '830088',
  visit_date: '2026-07-09', dump_ticket_date: '2026-07-14', client_name: 'The fresh Carrot of Surfside',
  client_code: '082-TFC', jurisdiction: 'dade', can_record_manual: true, blocked_reason: null }
const hoursAgo = (h) => new Date(Date.now() - h * 3600e3).toISOString()

function makeSb({ rows = [ROW], leases = [], attempts = [] }) {
  const writes = []
  const table = (name) => {
    const out = name === 'visit_gdo_our_record' ? rows : name === 'derm_portal_leases' ? leases : attempts
    const b = { select: () => b, eq: () => b, not: () => b, then: (res, rej) => Promise.resolve({ data: out, error: null }).then(res, rej),
      upsert: async (v, o) => { writes.push({ table: name, v, o }); return { error: null } } }
    return b
  }
  return { sb: { from: table, schema: () => ({ from: table }) }, writes }
}

async function call(handler, body, db = {}, bot = { status: 202, body: { status: 'accepted' } }) {
  const { sb, writes } = makeSb(db)
  globalThis.__sb = sb
  globalThis.__user = { auth: { getUser: async () => ({ data: { user: { email: 'fred@ayache.com' } }, error: null }) } }
  const fetches = []
  globalThis.fetch = async (url, init) => {
    fetches.push({ url, init })
    if (bot === 'timeout') throw new Error('The operation was aborted due to timeout')
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
      const f = r.fetches[0], b = f && JSON.parse(f.init.body)
      return r.status === 202 && r.out.sent === true && r.fetches.length === 1 && f.url === 'https://bot.example/file'
        && f.init.headers['x-run-key'] === 'k-derm' && b.gdo_number === 'GDO-09853' && b.ticket_number === '830088'
        && b.service_date === '2026-07-09' && b.visit_id === 6215 && b.gdo_id === 51 && b.dry_run === false
        && b.requested_by === 'fred@ayache.com' && r.writes.length === 1 && r.writes[0].v.visit_id === 6215
        && r.writes[0].v.gdo_id === 51 && r.writes[0].o.onConflict === 'visit_id,gdo_id' } },
  { id: 'dry-run', body: send({ dry_run: true }), ok: (r) => r.status === 202 && r.out.dry_run === true && JSON.parse(r.fetches[0].init.body).dry_run === true && r.writes.length === 0 },
  { id: 'bot-refuses', body: send(), bot: { status: 409, body: { detail: 'A run is already in progress' } },
    ok: (r) => r.status === 502 && /A run is already in progress/.test(r.out.message) && r.writes.length === 0 },
  { id: 'bot-no-answer', body: send(), bot: 'timeout', ok: (r) => r.status === 502 && r.out.error === 'bot_no_answer' && r.writes.length === 1 },
  { id: 'dry-run-missing', body: send({ dry_run: undefined }), ok: (r) => r.status === 400 && r.fetches.length === 0 },
]

const quiet = console.error
const src = fs.readFileSync(path.join(REPO, FN), 'utf8')
const guard = "if (!st.can_send) return json({ error: 'not_sendable', message: st.reason, sent_at: st.sent_at }, 409, cors)"
if (!src.includes(guard)) throw new Error('the send guard line changed, update this check')
const work = build('work', src)
const mutant = build('mutant', src.replace(guard, '// guard removed'))
const handlers = {
  work: { on: await load(work, ON, 'w-on'), off: await load(work, BASE, 'w-off') },
  mutant: { on: await load(mutant, ON, 'm-on'), off: await load(mutant, BASE, 'm-off') },
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

fs.rmSync(TMP, { recursive: true, force: true })
console.log(ok ? '\nRESULT: OK' : '\nRESULT: FAILED')
process.exit(ok ? 0 : 1)
